// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! `rev-stealth cf-evaluate` — defender-testbed CF Turnstile resilience probe.

use clap::Args;
use obscura_bridge::{ObscuraBridge, ObscuraConfig};
use serde_json::json;
use stealth_cf::{evaluator::CfEvaluator, types::SolveOpts, SolveOutcome};
use url::Url;
use uuid::Uuid;

use crate::adapters::ObscuraPageAdapter;
use crate::aup::{enforce, AupDecision};
use crate::commands::auth_replay::{default_auth_store_dir, AuthReplayContext};
use crate::commands::exit::Phase2Exit;
use crate::commands::vpn_envelope::build_vpn_envelope;
use crate::policy::{cli_flags_to_tristate, effective_require_vpn, Policy};
use crate::vpn_guard::run_startup_probe;
use crate::vpn_selector::{
    build_pool, build_resolver, proxy_resolve_exit, select, select_proxy_with_resolver,
    selection_from_proxy, validate_proxy_args,
};
use crate::OutputFormat;
use stealth_auth::AuthStore;

#[derive(Args, Debug)]
pub struct CfEvaluateArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/cf-evaluate.output.json`.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    #[arg(long)]
    pub url: String,
    #[arg(long)]
    pub session_id: Option<Uuid>,
    #[arg(long)]
    pub i_have_authorization: bool,
    #[arg(long, env = "REV_STEALTH_OBSCURA")]
    pub obscura: Option<std::path::PathBuf>,

    /// Phase 6c: fail-closed VPN-required guard. See spider --require-vpn.
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

    /// Phase 6e: background leak monitor poll interval (seconds).
    #[arg(long = "leak-poll-secs", default_value_t = 30)]
    pub leak_poll_secs: u64,
    /// Replay stored auth cookies and browser headers from the named profile.
    #[arg(long = "use-auth")]
    pub use_auth: Option<String>,
    /// Auth AAD/domain context to load; defaults to the target host.
    #[arg(long = "auth-domain")]
    pub auth_domain: Option<String>,
}

pub async fn run(format: OutputFormat, args: CfEvaluateArgs) -> i32 {
    // 1. URL syntax validation FIRST.
    let parsed = match Url::parse(&args.url) {
        Ok(u) => u,
        Err(e) => {
            emit_err(format, "cf-evaluate", 1, &format!("invalid url: {e}"));
            return 1;
        }
    };

    // 2. AUP enforcement.
    match enforce(&args.url, args.i_have_authorization) {
        AupDecision::Rejected { message } => {
            emit_err(format, "cf-evaluate", 1, &format!("AUP: {message}"));
            return 1;
        }
        AupDecision::Allowed { reason } => {
            if args.i_have_authorization {
                eprintln!(
                    "[WARN] cf-evaluate: --i-have-authorization bypassing AUP allowlist ({:?})",
                    reason
                );
                tracing::warn!(
                    target: "audit",
                    operation = "cf-evaluate",
                    url = %args.url,
                    "--i-have-authorization bypassing AUP allowlist"
                );
            }
        }
    }

    // 3. SSRF guard.
    if let Err(e) = ObscuraBridge::validate_url(&parsed) {
        emit_err(format, "cf-evaluate", 1, &format!("SSRF guard: {e}"));
        return 1;
    }

    // 3.5. Phase 6c: fail-closed VPN probe.
    let policy = match Policy::load() {
        Ok(p) => p.with_env_overrides(),
        Err(e) => {
            emit_err(format, "cf-evaluate", 1, &format!("policy load: {e}"));
            return 1;
        }
    };
    let tri = cli_flags_to_tristate(args.require_vpn, args.allow_no_vpn);
    let require_vpn = effective_require_vpn(tri, &policy);
    if let Err(exit) = validate_proxy_args(args.vpn_instance.as_deref(), args.proxy_tier.as_deref())
    {
        let code = exit.as_i32();
        emit_err(
            format,
            "cf-evaluate",
            code,
            "--vpn-instance is only compatible with --proxy-tier surfshark",
        );
        return code;
    }
    if let Err(e) = run_startup_probe(require_vpn, &policy).await {
        let code = e.exit_code().as_i32();
        emit_err(format, "cf-evaluate", code, &format!("{e}"));
        return code;
    }

    // Phase 6d: pick an InstancePool slot for this session.
    let session_id = args.session_id.unwrap_or_else(Uuid::new_v4);
    let pool = build_pool(&policy);
    let mut proxy_selection = None;
    let selection = if args.proxy_tier.is_some() {
        let resolver = match build_resolver(&policy) {
            Ok(resolver) => resolver,
            Err(e) => {
                let code = Phase2Exit::Transient.as_i32();
                emit_err(format, "cf-evaluate", code, &format!("proxy resolver: {e}"));
                return code;
            }
        };
        let resolved = match select_proxy_with_resolver(
            &resolver,
            &parsed,
            &session_id.to_string(),
            args.proxy_tier.as_deref(),
            args.vpn_instance.as_deref(),
        ) {
            Ok(selection) => selection,
            Err(e) => {
                let (exit, msg) = proxy_resolve_exit(&e);
                let code = exit.as_i32();
                emit_err(format, "cf-evaluate", code, &msg);
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
                "cf-evaluate",
                Phase2Exit::Leak.as_i32(),
                "require_vpn requires surfshark proxy tier",
            );
            return Phase2Exit::Leak.as_i32();
        }
        selection
    } else if require_vpn {
        if pool.all_failed() {
            emit_err(format, "cf-evaluate", 7, "vpn pool exhausted");
            return 7;
        }
        match select(&pool, &session_id.to_string(), args.vpn_instance.as_deref()) {
            Some(s) => Some(s),
            None => {
                emit_err(
                    format,
                    "cf-evaluate",
                    7,
                    "vpn pool has no healthy instances",
                );
                return 7;
            }
        }
    } else {
        select(&pool, &session_id.to_string(), args.vpn_instance.as_deref())
    };

    // Phase 6e: spawn background leak monitor when require_vpn=true.
    let monitor: Option<vpn_rotate::leak_monitor::LeakMonitor> =
        if require_vpn && !policy.vpn_instances.is_empty() {
            let instances: Vec<vpn_rotate::instance_pool::VpnInstance> = policy
                .vpn_instances
                .iter()
                .map(|v| vpn_rotate::instance_pool::VpnInstance {
                    name: v.name.clone(),
                    http_proxy_port: v.http_proxy_port,
                    control_port: v.control_port,
                })
                .collect();
            Some(vpn_rotate::leak_monitor::LeakMonitor::spawn(
                instances,
                policy.vpn_required_country.clone(),
                std::time::Duration::from_secs(args.leak_poll_secs),
            ))
        } else {
            None
        };
    let monitor_notify = monitor.as_ref().map(|m| m.notify_clone());
    let monitor_state = monitor.as_ref().map(|m| m.state_clone());
    let monitor_poll_secs = monitor
        .as_ref()
        .map(|m| m.poll_interval().as_secs())
        .unwrap_or(args.leak_poll_secs);

    let auth_replay = match build_auth_replay_context(&args, &parsed) {
        Ok(ctx) => ctx,
        Err(e) => {
            emit_err(format, "cf-evaluate", 1, &format!("auth replay: {e}"));
            return 1;
        }
    };

    let binary = args
        .obscura
        .clone()
        .unwrap_or_else(|| std::path::PathBuf::from("obscura"));
    let cfg = ObscuraConfig {
        binary_path: binary,
        session_id,
        proxy: selection.as_ref().map(|s| s.proxy_url.clone()),
        extra_args: selection
            .as_ref()
            .map(|_| {
                vec![
                    "--proxy-bypass-list".to_string(),
                    "127.0.0.1;localhost".to_string(),
                ]
            })
            .unwrap_or_default(),
        ..ObscuraConfig::default()
    };
    let bridge = match ObscuraBridge::launch(cfg).await {
        Ok(b) => b,
        Err(e) => {
            let code = match e {
                obscura_bridge::BridgeError::StartupTimeout => 2,
                _ => 3,
            };
            emit_err(format, "cf-evaluate", code, &format!("obscura launch: {e}"));
            return code;
        }
    };
    let page = match bridge.new_page().await {
        Ok(p) => p,
        Err(e) => {
            emit_err(format, "cf-evaluate", 2, &format!("new_page: {e}"));
            let _ = bridge.shutdown().await;
            return 2;
        }
    };
    if let Some(auth) = auth_replay.as_ref() {
        if let Err(e) = auth.apply_to_obscura_page(&page).await {
            emit_err(format, "cf-evaluate", 2, &format!("auth replay apply: {e}"));
            let _ = bridge.shutdown().await;
            return 2;
        }
    }
    let nav_fut = page.navigate(&parsed);
    let nav_res = if let Some(notify) = monitor_notify.as_ref() {
        tokio::select! {
            r = nav_fut => Ok(r),
            _ = notify.notified() => Err(()),
        }
    } else {
        Ok(nav_fut.await)
    };
    if nav_res.is_err() {
        let _ = bridge.force_kill().await;
        emit_err(format, "cf-evaluate", 7, "vpn leak detected mid-navigate");
        if let Some(m) = monitor {
            m.shutdown();
        }
        return 7;
    }
    if let Err(e) = nav_res.unwrap() {
        emit_err(format, "cf-evaluate", 2, &format!("navigate: {e}"));
        let _ = bridge.shutdown().await;
        if let Some(m) = monitor {
            m.shutdown();
        }
        return 2;
    }

    let adapter = ObscuraPageAdapter::new(page);
    let eval = CfEvaluator::new(&adapter);
    let outcome = match eval
        .evaluate_turnstile_resilience(SolveOpts::default())
        .await
    {
        Ok(o) => o,
        Err(e) => {
            emit_err(format, "cf-evaluate", 3, &format!("eval: {e}"));
            let _ = bridge.shutdown().await;
            return 3;
        }
    };
    let code = match outcome {
        SolveOutcome::Cleared | SolveOutcome::NonTurnstile => 0,
        SolveOutcome::StillBlocked | SolveOutcome::Timeout => 8,
    };
    let mut payload = serde_json::Map::new();
    payload.insert("url".to_string(), json!(args.url));
    payload.insert("outcome".to_string(), json!(format!("{outcome:?}")));
    payload.extend(
        build_vpn_envelope(
            selection.as_ref(),
            pool.healthy_count(),
            monitor_state.as_ref(),
            monitor_poll_secs,
            None,
            proxy_selection.as_ref(),
        )
        .await,
    );
    payload.insert("exit_code".to_string(), json!(code));
    emit_ok(format, "cf-evaluate", serde_json::Value::Object(payload));
    let _ = bridge.shutdown().await;
    if let Some(m) = monitor {
        m.shutdown();
    }
    code
}

fn build_auth_replay_context(
    args: &CfEvaluateArgs,
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
    //! Job C: structural tests for the unified VPN envelope. We don't drive
    //! `run()` end-to-end here — those paths require obscura and a live
    //! network. Instead we verify that the helper that `run()` calls
    //! produces an object containing every field the spider also emits.
    use super::*;
    use crate::commands::vpn_envelope::build_vpn_envelope;
    use crate::vpn_selector::Selection;
    use url::Url;

    fn mk_sel() -> Selection {
        Selection {
            instance_name: "vpn-2".to_string(),
            proxy_url: Url::parse("http://127.0.0.1:8002").unwrap(),
            healthy_count: 3,
            from_session_cache: false,
        }
    }

    #[tokio::test]
    async fn test_cf_evaluate_json_includes_vpn_envelope() {
        // Simulate the `payload` builder block in `run()`.
        let sel = mk_sel();
        let mut payload = serde_json::Map::new();
        payload.insert("url".to_string(), json!("https://example.com/"));
        payload.insert("outcome".to_string(), json!("Cleared"));
        payload.extend(build_vpn_envelope(Some(&sel), 3, None, 30, None, None).await);
        payload.insert("exit_code".to_string(), json!(0));

        // Spider-equivalent envelope fields must be present.
        for k in [
            "vpn_instance_used",
            "vpn_proxy_url",
            "vpn_pool_healthy_count",
            "vpn_rotation_events",
            "vpn_monitor",
        ] {
            assert!(payload.contains_key(k), "missing field: {k}");
        }
        assert_eq!(payload.get("vpn_instance_used").unwrap(), "vpn-2");
    }
}
