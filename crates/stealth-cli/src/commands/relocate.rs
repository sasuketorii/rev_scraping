// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! `rev-stealth relocate` — locate a stable-id'd element in a saved HTML or
//! a freshly fetched page. No URL means no AUP check.

use clap::Args;
use obscura_bridge::ObscuraBridge;
use serde_json::json;
use stealth_parse::{LocateOutcome, ParseStore, Relocator};
use url::Url;
use uuid::Uuid;

use crate::aup::{enforce, AupDecision};
use crate::commands::auth_replay::{default_auth_store_dir, AuthReplayContext};
use crate::commands::exit::Phase2Exit;
use crate::commands::vpn_envelope::build_vpn_envelope;
use crate::policy::{cli_flags_to_tristate, effective_require_vpn, Policy};
use crate::vpn_guard::run_startup_probe;
use crate::vpn_selector::{
    build_pool, build_resolver, proxy_resolve_exit, select, select_proxy_with_resolver,
    selection_from_proxy, validate_proxy_args, Selection,
};
use crate::OutputFormat;
use stealth_auth::AuthStore;

#[derive(Args, Debug)]
pub struct RelocateArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/relocate.output.json`.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    /// Session id (informational; not required to open the store).
    #[arg(long)]
    pub session_id: Option<Uuid>,
    /// stable_id of the element to locate.
    #[arg(long)]
    pub stable_id: String,
    /// Local HTML file to scan.
    #[arg(long, conflicts_with = "url")]
    pub html_file: Option<std::path::PathBuf>,
    /// Remote URL to fetch (HTTP-only, no browser launch).
    #[arg(long)]
    pub url: Option<String>,
    /// Similarity threshold.
    #[arg(long, default_value_t = 0.85)]
    pub threshold: f32,
    /// Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`).
    #[arg(long)]
    pub parse_store: Option<std::path::PathBuf>,
    /// Treat Ambiguous as exit 10.
    #[arg(long)]
    pub strict: bool,
    /// AUP bypass (logs a warn). Required when `--url` targets a non-allowlisted host.
    #[arg(long)]
    pub i_have_authorization: bool,

    /// Phase 6c: fail-closed VPN-required guard. Applies to `--url` only;
    /// `--html-file` is a local read.
    #[arg(
        long = "require-vpn",
        conflicts_with = "allow_no_vpn",
        default_value_t = false
    )]
    pub require_vpn: bool,
    #[arg(
        long = "allow-no-vpn",
        conflicts_with = "require_vpn",
        default_value_t = false
    )]
    pub allow_no_vpn: bool,
    /// Phase 6d: force a specific VPN instance from the configured pool.
    #[arg(long = "vpn-instance")]
    pub vpn_instance: Option<String>,
    /// Force a named proxy tier (e.g. "direct", "surfshark", "warp",
    /// "iproyal") or "auto" to use the configured fallback chain.
    /// Mutually exclusive with `--vpn-instance` unless the tier is exactly
    /// "surfshark".
    #[arg(long = "proxy-tier")]
    pub proxy_tier: Option<String>,

    /// Disable the fallback chain; one attempt at the selected tier only.
    #[arg(long = "no-fallback")]
    pub no_fallback: bool,
    /// Replay stored auth cookies and browser headers from the named profile.
    #[arg(long = "use-auth")]
    pub use_auth: Option<String>,
    /// Auth AAD/domain context to load; defaults to the target host.
    #[arg(long = "auth-domain")]
    pub auth_domain: Option<String>,
}

pub async fn run(format: OutputFormat, args: RelocateArgs) -> i32 {
    // Job C: VPN envelope context captured on the `--url` path so the final
    // result JSON carries the same shape as `spider` / `cf-evaluate`. On the
    // `--html-file` path these remain `None` / zero (envelope still emitted,
    // values are `null` / `enabled: false`).
    let mut vpn_selection: Option<Selection> = None;
    let mut vpn_pool_healthy: usize = 0;
    let mut proxy_selection = None;

    let (html, url_fld) = match (&args.html_file, &args.url) {
        (Some(p), None) => match std::fs::read_to_string(p) {
            Ok(b) => (b, String::new()),
            Err(e) => {
                emit_err(format, "relocate", 1, &format!("read html: {e}"));
                return 1;
            }
        },
        (None, Some(u)) => {
            // 1. URL syntax validation FIRST.
            let parsed = match Url::parse(u) {
                Ok(p) => p,
                Err(e) => {
                    emit_err(format, "relocate", 1, &format!("invalid url: {e}"));
                    return 1;
                }
            };
            // 2. AUP enforcement.
            match enforce(u, args.i_have_authorization) {
                AupDecision::Rejected { message } => {
                    emit_err(format, "relocate", 1, &format!("AUP: {message}"));
                    return 1;
                }
                AupDecision::Allowed { reason } => {
                    if args.i_have_authorization {
                        eprintln!(
                            "[WARN] relocate: --i-have-authorization bypassing AUP allowlist ({:?})",
                            reason
                        );
                        tracing::warn!(
                            target: "audit",
                            operation = "relocate",
                            url = %u,
                            "--i-have-authorization bypassing AUP allowlist"
                        );
                    }
                }
            }
            // 3. SSRF guard.
            if let Err(e) = ObscuraBridge::validate_url(&parsed) {
                emit_err(format, "relocate", 1, &format!("SSRF guard: {e}"));
                return 1;
            }
            // 3.5. Phase 6c: fail-closed VPN guard. Applies only on the
            // network-egress (`--url`) branch.
            let policy = match Policy::load() {
                Ok(p) => p.with_env_overrides(),
                Err(e) => {
                    emit_err(format, "relocate", 1, &format!("policy load: {e}"));
                    return 1;
                }
            };
            let tri = cli_flags_to_tristate(args.require_vpn, args.allow_no_vpn);
            let require_vpn = effective_require_vpn(tri, &policy);
            if let Err(exit) =
                validate_proxy_args(args.vpn_instance.as_deref(), args.proxy_tier.as_deref())
            {
                let code = exit.as_i32();
                emit_err(
                    format,
                    "relocate",
                    code,
                    "--vpn-instance is only compatible with --proxy-tier surfshark",
                );
                return code;
            }
            if let Err(e) = run_startup_probe(require_vpn, &policy).await {
                let code = e.exit_code().as_i32();
                emit_err(format, "relocate", code, &format!("{e}"));
                return code;
            }
            // Phase 6d: pick a pool instance and route reqwest through it.
            let sid = args.session_id.unwrap_or_else(Uuid::new_v4);
            let pool = build_pool(&policy);
            let selection = if args.proxy_tier.is_some() {
                let resolver = match build_resolver(&policy) {
                    Ok(resolver) => resolver,
                    Err(e) => {
                        let code = Phase2Exit::Transient.as_i32();
                        emit_err(format, "relocate", code, &format!("proxy resolver: {e}"));
                        return code;
                    }
                };
                let resolved = match select_proxy_with_resolver(
                    &resolver,
                    &parsed,
                    &sid.to_string(),
                    args.proxy_tier.as_deref(),
                    args.vpn_instance.as_deref(),
                ) {
                    Ok(selection) => selection,
                    Err(e) => {
                        let (exit, msg) = proxy_resolve_exit(&e);
                        let code = exit.as_i32();
                        emit_err(format, "relocate", code, &msg);
                        return code;
                    }
                };
                proxy_selection = resolved;
                let selection = selection_from_proxy(proxy_selection.as_ref());
                if require_vpn
                    && proxy_selection
                        .as_ref()
                        .is_none_or(|selection| selection.tier_name != "surfshark")
                {
                    emit_err(
                        format,
                        "relocate",
                        Phase2Exit::Leak.as_i32(),
                        "require_vpn requires surfshark proxy tier",
                    );
                    return Phase2Exit::Leak.as_i32();
                }
                selection
            } else if require_vpn {
                if pool.all_failed() {
                    emit_err(format, "relocate", 7, "vpn pool exhausted");
                    return 7;
                }
                match select(&pool, &sid.to_string(), args.vpn_instance.as_deref()) {
                    Some(s) => Some(s),
                    None => {
                        emit_err(format, "relocate", 7, "vpn pool has no healthy instances");
                        return 7;
                    }
                }
            } else {
                select(&pool, &sid.to_string(), args.vpn_instance.as_deref())
            };
            // 4. Fetch.
            let host = parsed.host_str().unwrap_or("").to_string();
            let auth_replay = match build_auth_replay_context(&args, &parsed) {
                Ok(ctx) => ctx,
                Err(e) => {
                    emit_err(format, "relocate", 1, &format!("auth replay: {e}"));
                    return 1;
                }
            };
            let mut client_builder = reqwest::Client::builder();
            if let Some(sel) = &selection {
                let no_proxy = reqwest::NoProxy::from_string(
                    "127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
                );
                match reqwest::Proxy::all(sel.proxy_url.as_str()) {
                    Ok(p) => client_builder = client_builder.proxy(p.no_proxy(no_proxy)),
                    Err(e) => {
                        emit_err(format, "relocate", 1, &format!("proxy build: {e}"));
                        return 1;
                    }
                }
            }
            if let Some(auth) = auth_replay.as_ref() {
                client_builder = auth.apply_to_reqwest(client_builder);
            }
            vpn_pool_healthy = pool.healthy_count();
            vpn_selection = selection.clone();
            let client = match client_builder.build() {
                Ok(c) => c,
                Err(e) => {
                    emit_err(format, "relocate", 2, &format!("client build: {e}"));
                    return 2;
                }
            };
            match client.get(parsed.as_str()).send().await {
                Ok(resp) => match resp.text().await {
                    Ok(body) => (body, host),
                    Err(e) => {
                        emit_err(format, "relocate", 2, &format!("fetch body: {e}"));
                        return 2;
                    }
                },
                Err(e) => {
                    emit_err(format, "relocate", 2, &format!("fetch: {e}"));
                    return 2;
                }
            }
        }
        _ => {
            emit_err(
                format,
                "relocate",
                1,
                "exactly one of --html-file or --url must be supplied",
            );
            return 1;
        }
    };

    let store_path = args.parse_store.clone().unwrap_or_else(|| {
        dirs::home_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join(".rev_scraping")
            .join("parse.sqlite")
    });
    let mut store = match ParseStore::open(&store_path) {
        Ok(s) => s,
        Err(e) => {
            emit_err(format, "relocate", 3, &format!("open store: {e}"));
            return 3;
        }
    };
    let mut relocator = Relocator::new(&mut store);
    let envelope = build_vpn_envelope(
        vpn_selection.as_ref(),
        vpn_pool_healthy,
        None, // relocate has no background leak monitor wired
        0,
        None,
        proxy_selection.as_ref(),
    )
    .await;
    let emit_ok_with_env = |fields: serde_json::Value| {
        let mut m = serde_json::Map::new();
        if let serde_json::Value::Object(obj) = fields {
            m.extend(obj);
        }
        m.extend(envelope.clone());
        emit_ok(format, "relocate", serde_json::Value::Object(m));
    };
    match relocator
        .locate(&html, &args.stable_id, &url_fld, args.threshold)
        .await
    {
        Ok(LocateOutcome::ExactMatch(n)) => {
            emit_ok_with_env(json!({"kind":"exact","node":format!("{n:?}")}));
            0
        }
        Ok(LocateOutcome::FuzzyMatch { node, score }) => {
            emit_ok_with_env(json!({"kind":"fuzzy","score":score,"node":format!("{node:?}")}));
            0
        }
        Ok(LocateOutcome::Ambiguous { candidates }) => {
            emit_ok_with_env(json!({"kind":"ambiguous","candidates":candidates.len()}));
            if args.strict {
                10
            } else {
                9
            }
        }
        Ok(LocateOutcome::NotFound) => {
            emit_err(format, "relocate", 9, "no match");
            9
        }
        Err(e) => {
            emit_err(format, "relocate", 3, &format!("locate: {e}"));
            3
        }
    }
}

fn build_auth_replay_context(
    args: &RelocateArgs,
    parsed_url: &Url,
) -> anyhow::Result<Option<AuthReplayContext>> {
    let Some(profile) = args.use_auth.as_deref() else {
        return Ok(None);
    };
    let aad_context = args
        .auth_domain
        .as_deref()
        .or_else(|| parsed_url.host_str())
        .unwrap_or_default();
    let store = AuthStore::open(&default_auth_store_dir())?;
    AuthReplayContext::load(&store, profile, aad_context).map(Some)
}

fn emit_ok(format: OutputFormat, op: &str, payload: serde_json::Value) {
    match format {
        OutputFormat::Json => {
            println!(
                "{}",
                json!({ "ok": true, "operation": op, "result": payload })
            );
        }
        OutputFormat::Human => {
            println!("[OK] {op}");
            if let Ok(s) = serde_json::to_string_pretty(&payload) {
                println!("{s}");
            }
        }
    }
}

fn emit_err(format: OutputFormat, op: &str, exit: i32, msg: &str) {
    match format {
        OutputFormat::Json => {
            println!(
                "{}",
                json!({
                    "ok": false,
                    "operation": op,
                    "exit_code": exit,
                    "error": msg,
                })
            );
        }
        OutputFormat::Human => {
            eprintln!("[ERROR] {op}: {msg}");
        }
    }
}

#[cfg(test)]
mod tests {
    //! Job C: structural tests for the unified VPN envelope in relocate.
    //! The `--url` end-to-end path needs network + AUP allowlist hits,
    //! so we exercise the envelope merge logic directly here.
    use super::*;
    use crate::commands::vpn_envelope::build_vpn_envelope;
    use url::Url;

    fn mk_sel() -> Selection {
        Selection {
            instance_name: "vpn-2".to_string(),
            proxy_url: Url::parse("http://127.0.0.1:8002").unwrap(),
            healthy_count: 3,
            from_session_cache: false,
        }
    }

    fn merge_envelope(
        envelope: serde_json::Map<String, serde_json::Value>,
        cmd_fields: serde_json::Value,
    ) -> serde_json::Map<String, serde_json::Value> {
        // Mirrors the closure inside `run()`.
        let mut m = serde_json::Map::new();
        if let serde_json::Value::Object(obj) = cmd_fields {
            m.extend(obj);
        }
        m.extend(envelope);
        m
    }

    #[tokio::test]
    async fn test_relocate_url_json_includes_vpn_envelope() {
        let sel = mk_sel();
        let env = build_vpn_envelope(Some(&sel), 3, None, 30, None, None).await;
        let merged = merge_envelope(env, json!({"kind":"exact","node":"<n>"}));

        for k in [
            "kind",
            "vpn_instance_used",
            "vpn_proxy_url",
            "vpn_pool_healthy_count",
            "vpn_rotation_events",
            "vpn_monitor",
        ] {
            assert!(merged.contains_key(k), "missing field: {k}");
        }
        assert_eq!(merged.get("vpn_instance_used").unwrap(), "vpn-2");
    }

    #[tokio::test]
    async fn test_relocate_html_file_envelope_is_null() {
        // On the --html-file path, `vpn_selection` stays None and
        // `vpn_pool_healthy` stays 0. Envelope shape must still be there.
        let env = build_vpn_envelope(None, 0, None, 0, None, None).await;
        let merged = merge_envelope(env, json!({"kind":"exact","node":"<n>"}));

        assert!(merged.get("vpn_instance_used").unwrap().is_null());
        assert!(merged.get("vpn_proxy_url").unwrap().is_null());
        assert_eq!(merged.get("vpn_pool_healthy_count").unwrap(), 0);
        assert_eq!(
            merged.get("vpn_monitor").unwrap().get("enabled").unwrap(),
            false
        );
    }
}
