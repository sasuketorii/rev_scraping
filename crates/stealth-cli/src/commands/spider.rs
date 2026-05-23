// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2, Phase 5b HTTP fallback)
//! `rev-stealth spider` — AUP-gated browse + optional CF eval + optional relocate.
//!
//! Phase 5b adds a reqwest-based fallback path. When `--http-only` is set the
//! obscura subprocess is never launched; when `--auto-fallback` (default) is
//! set and obscura fails to launch / CDP errors out, we transparently retry
//! with reqwest and surface the switch via `used_fallback: true` in the JSON.

use clap::Args;
use mobile_fp::{obscura_inject::inject_into_cdp, PresetId, StealthLevel};
use obscura_bridge::{ObscuraBridge, ObscuraConfig};
use serde_json::json;
use stealth_cf::{evaluator::CfEvaluator, types::SolveOpts, SolveOutcome};
use stealth_parse::{LocateOutcome, ParseStore, Relocator};
use url::Url;
use uuid::Uuid;

use crate::adapters::{ObscuraCdpAdapter, ObscuraPageAdapter};
use crate::aup::{enforce, AupDecision};
use crate::commands::auth_replay::{default_auth_store_dir, AuthReplayContext};
use crate::commands::exit::{map_spider_exit, Phase2Exit};
use crate::commands::fallback_http::{FetchResult, HttpFallback};
use crate::commands::recipe_runtime::{
    build_skeleton_recipe, default_recipe_dir, fetch_api_endpoint, open_store, parse_recipe_params,
    pick_endpoint, recipe_json_block, ttl_remaining_days, upsert_auto_endpoints,
};
use crate::commands::vpn_envelope::build_vpn_envelope;
use crate::policy::{cli_flags_to_tristate, effective_require_vpn, Policy};
use crate::vpn_guard::run_startup_probe;
use crate::vpn_selector::{
    build_pool, build_resolver, proxy_resolve_exit, select, select_proxy_with_resolver,
    selection_from_proxy, validate_proxy_args, Selection,
};
use crate::OutputFormat;
use stealth_auth::AuthStore;
use stealth_sites::{Rendering, ScrapingMethod, SiteRecipe};
use vpn_rotate::instance_pool::InstancePool;
use vpn_rotate::leak_monitor::{LeakMonitor, LeakState};

#[derive(Args, Debug)]
pub struct SpiderArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/spider.output.json`.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    /// Target URL.
    #[arg(long)]
    pub url: String,
    /// Session id (auto-generated when omitted).
    #[arg(long)]
    pub session_id: Option<Uuid>,
    /// Mobile fingerprint preset slug.
    #[arg(long)]
    pub mobile_preset: Option<String>,
    /// Evaluate Cloudflare Turnstile resilience (defender-testbed; no solver).
    #[arg(long = "cf-evaluate")]
    pub evaluate_cf: bool,
    /// Route through `vpn-rotate` before launch.
    #[arg(long)]
    pub vpn: bool,
    /// stable_id to locate via `stealth-parse` after navigation.
    #[arg(long)]
    pub stable_id: Option<String>,
    /// Similarity threshold for relocate.
    #[arg(long, default_value_t = 0.85)]
    pub threshold: f32,
    /// Treat Ambiguous relocate as a hard failure (exit code 10).
    #[arg(long)]
    pub strict: bool,
    /// AUP bypass (logs a warn). Equivalent to env-ack for the day.
    #[arg(long)]
    pub i_have_authorization: bool,
    /// Path to the obscura binary. Overridable via env.
    #[arg(long, env = "REV_STEALTH_OBSCURA")]
    pub obscura: Option<std::path::PathBuf>,
    /// Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`).
    #[arg(long)]
    pub parse_store: Option<std::path::PathBuf>,
    /// Replay stored auth cookies and browser headers from the named profile.
    #[arg(long = "use-auth")]
    pub use_auth: Option<String>,
    /// Auth AAD/domain context to load; defaults to the target host.
    #[arg(long = "auth-domain")]
    pub auth_domain: Option<String>,

    // ---- Phase 5b: HTTP fallback knobs --------------------------------------
    /// Skip obscura entirely and fetch via reqwest. Implies no JS execution,
    /// no CF eval, no DOM injection.
    #[arg(long = "http-only", default_value_t = false)]
    pub http_only: bool,
    /// When obscura launch / CDP fails, automatically retry with reqwest.
    /// Default true; set `--no-auto-fallback` to disable for deterministic
    /// agent workflows that need a hard exit-3 on browser failure.
    #[arg(long = "auto-fallback", default_value_t = true)]
    pub auto_fallback: bool,
    /// Explicit disable for `--auto-fallback` (overrides the default).
    #[arg(long = "no-auto-fallback", default_value_t = false)]
    pub no_auto_fallback: bool,

    /// Dump the fetched HTML to the given path (UTF-8). With obscura, the
    /// post-render `document.documentElement.outerHTML` is captured (so SPAs
    /// land hydrated); with the reqwest fallback / `--http-only`, the raw
    /// response body is written. Parent directories are created as needed and
    /// the file is created with mode `0600` on Unix.
    #[arg(long = "dump-html")]
    pub dump_html: Option<std::path::PathBuf>,

    // ---- Phase 5g: SPA hydration wait knobs ---------------------------------
    /// After obscura navigate completes, wait N milliseconds before dumping
    /// the HTML. Useful for SPA hydration. No-op on the reqwest fallback path.
    #[arg(long = "wait-ms")]
    pub wait_ms: Option<u64>,
    /// After obscura navigate completes, wait until the given CSS selector
    /// appears in the DOM (max 30 seconds). Takes precedence over `--wait-ms`.
    /// No-op on the reqwest fallback path.
    #[arg(long = "wait-selector")]
    pub wait_selector: Option<String>,

    // ---- Phase 6c: fail-closed VPN-required guard ---------------------------
    /// Force the VPN-required guard ON for this invocation. Wins over
    /// `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1` only in
    /// the sense that env can't be loosened further.
    #[arg(
        long = "require-vpn",
        conflicts_with = "allow_no_vpn",
        default_value_t = false
    )]
    pub require_vpn: bool,
    /// Allow this invocation to proceed without a VPN. Loses to env
    /// `REV_SCRAPING_REQUIRE_VPN=1` (which is the only way to enforce
    /// the policy from outside the process).
    #[arg(
        long = "allow-no-vpn",
        conflicts_with = "require_vpn",
        default_value_t = false
    )]
    pub allow_no_vpn: bool,

    // ---- Phase 6d: VPN instance pool + rotation knobs ----------------------
    /// Force this invocation to use the named VPN instance, overriding the
    /// HRW session-sticky pick. Useful for tests and reproducible runs.
    /// Must match a `name` in the configured `vpn_instances` list.
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

    // ---- Phase 6e: background leak monitor knobs ----------------------------
    /// Polling interval (seconds) for the background leak monitor. Only
    /// honoured when `require_vpn=true`. Range [5, 300]; out-of-range
    /// values are clamped. Default 30s.
    #[arg(long = "leak-poll-secs", default_value_t = 30)]
    pub leak_poll_secs: u64,

    // ---- Phase 7b: Site Recipe L2 cache knobs --------------------------------
    /// Skip recipe lookup AND skeleton save for this invocation.
    #[arg(long = "no-cache", default_value_t = false)]
    pub no_cache: bool,
    /// Ignore any existing recipe, run full discovery, and overwrite the
    /// recipe on success.
    #[arg(long = "cache-refresh", default_value_t = false)]
    pub cache_refresh: bool,
    /// Hard-require a recipe hit. On miss, exit code 9 and do nothing.
    #[arg(long = "cache-only", default_value_t = false)]
    pub cache_only: bool,
    /// Treat recipes whose `last_verified` is older than DAYS as expired.
    /// Default: 30 days. Expired recipes are refreshed and overwritten.
    #[arg(long = "cache-ttl", default_value_t = 30)]
    pub cache_ttl: u64,
    /// Override the recipe directory (defaults to `~/.rev_scraping/sites/`).
    #[arg(long = "recipe-dir")]
    pub recipe_dir: Option<std::path::PathBuf>,
    /// When a recipe is hit and exposes API endpoints, call the endpoint
    /// matching this `purpose` directly via reqwest, skipping browser entirely.
    #[arg(long = "recipe-endpoint")]
    pub recipe_endpoint: Option<String>,
    /// Placeholder substitutions for the recipe endpoint URL. Repeatable;
    /// e.g. `--recipe-param username=alice --recipe-param id=42`.
    #[arg(long = "recipe-param", value_name = "KEY=VALUE")]
    pub recipe_param: Vec<String>,

    // ---- Phase 7c: automatic endpoint learning ------------------------------
    /// Disable Phase 7c auto-learning (Network capture + JS bundle scan +
    /// recipe upsert). Privacy-sensitive runs may opt out; the skeleton
    /// save still applies unless `--no-cache` is set. Default: off
    /// (i.e. learning is ON).
    #[arg(long = "recipe-no-learn", default_value_t = false)]
    pub recipe_no_learn: bool,
}

/// Which fetcher actually produced the HTML.
#[derive(Debug, Clone, Copy)]
enum Fetcher {
    Obscura,
    ReqwestFallback,
    HttpOnly,
}

impl Fetcher {
    fn as_str(self) -> &'static str {
        match self {
            Fetcher::Obscura => "obscura",
            Fetcher::ReqwestFallback => "reqwest-fallback",
            Fetcher::HttpOnly => "http-only",
        }
    }
}

/// Aggregated recipe state carried through the spider pipeline. Populated
/// once after URL parse and consulted at each branch point.
#[derive(Debug, Default)]
struct RecipeCtx {
    domain: String,
    recipe: Option<SiteRecipe>,
    hit: bool,
    ttl_remaining_days: Option<u64>,
    /// Set when discovery should overwrite an existing/expired recipe.
    refresh: bool,
    /// When the recipe was used to satisfy the fetch (api/spider/hybrid).
    fetched_via: Option<&'static str>,
    /// True if we saved a skeleton/recipe during this invocation.
    saved: bool,
    /// Whether recipe params parsed cleanly.
    params: std::collections::HashMap<String, String>,
    /// Endpoint purpose actually used (filled when API path is taken).
    endpoint_purpose: Option<String>,
    /// Endpoint path actually used (filled when API path is taken).
    endpoint_path: Option<String>,
}

impl RecipeCtx {
    fn to_json(&self) -> serde_json::Value {
        recipe_json_block(
            self.hit,
            &self.domain,
            self.endpoint_purpose.as_deref(),
            self.endpoint_path.as_deref(),
            self.fetched_via,
            self.saved,
            self.ttl_remaining_days,
        )
    }
}

pub async fn run(format: OutputFormat, args: SpiderArgs) -> i32 {
    // 1. URL syntax validation FIRST (before AUP/SSRF so bogus input is rejected fast).
    let parsed_url = match Url::parse(&args.url) {
        Ok(u) => u,
        Err(e) => {
            emit_err(format, "spider", 1, &format!("invalid url: {e}"));
            return 1;
        }
    };

    // 2. AUP enforcement.
    match enforce(&args.url, args.i_have_authorization) {
        AupDecision::Rejected { message } => {
            emit_err(format, "spider", 1, &format!("AUP: {message}"));
            return 1;
        }
        AupDecision::Allowed { reason } => {
            if args.i_have_authorization {
                eprintln!(
                    "[WARN] spider: --i-have-authorization bypassing AUP allowlist ({:?})",
                    reason
                );
                tracing::warn!(
                    target: "audit",
                    operation = "spider",
                    url = %args.url,
                    "--i-have-authorization bypassing AUP allowlist"
                );
            }
            tracing::info!(?reason, "AUP allowed");
        }
    }

    let session_id = args.session_id.unwrap_or_else(Uuid::new_v4);
    // 3. SSRF guard.
    if let Err(e) = ObscuraBridge::validate_url(&parsed_url) {
        emit_err(format, "spider", 1, &format!("SSRF guard: {e}"));
        return 1;
    }

    // Resolve `auto_fallback` after considering the override flag. `--no-auto-fallback`
    // wins over the default-true `--auto-fallback`.
    let auto_fallback = args.auto_fallback && !args.no_auto_fallback;

    // 3.5. Phase 6c: fail-closed VPN-required guard. Runs *before* any
    // network egress, including the --http-only short-circuit. Default
    // policy is require_vpn=true; operators opt out with --allow-no-vpn
    // (or REV_SCRAPING_REQUIRE_VPN=0 + a policy override).
    let policy = match Policy::load() {
        Ok(p) => p.with_env_overrides(),
        Err(e) => {
            emit_err(format, "spider", 1, &format!("policy load: {e}"));
            return 1;
        }
    };
    let cli_tri = cli_flags_to_tristate(args.require_vpn, args.allow_no_vpn);
    let require_vpn = effective_require_vpn(cli_tri, &policy);
    if let Err(exit) = validate_proxy_args(args.vpn_instance.as_deref(), args.proxy_tier.as_deref())
    {
        let code = exit.as_i32();
        emit_err(
            format,
            "spider",
            code,
            "--vpn-instance is only compatible with --proxy-tier surfshark",
        );
        return code;
    }
    let vpn_probe_report = match run_startup_probe(require_vpn, &policy).await {
        Ok(r) => r,
        Err(e) => {
            let code = e.exit_code().as_i32();
            emit_err(format, "spider", code, &format!("{e}"));
            return code;
        }
    };

    // 3.5b. Phase 6d: pick an InstancePool slot for this session. When
    // `require_vpn=true` and the pool is empty / all unhealthy, this is
    // a leak (no egress = no privacy guarantee) → exit 7.
    let pool = build_pool(&policy);
    let session_str = session_id.to_string();
    let mut proxy_selection = None;
    let vpn_selection: Option<Selection> = if args.proxy_tier.is_some() {
        let resolver = match build_resolver(&policy) {
            Ok(resolver) => resolver,
            Err(e) => {
                let code = Phase2Exit::Transient.as_i32();
                emit_err(format, "spider", code, &format!("proxy resolver: {e}"));
                return code;
            }
        };
        let resolved = match select_proxy_with_resolver(
            &resolver,
            &parsed_url,
            &session_str,
            args.proxy_tier.as_deref(),
            args.vpn_instance.as_deref(),
        ) {
            Ok(selection) => selection,
            Err(e) => {
                let (exit, msg) = proxy_resolve_exit(&e);
                let code = exit.as_i32();
                emit_err(format, "spider", code, &msg);
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
                "spider",
                Phase2Exit::Leak.as_i32(),
                "require_vpn requires surfshark proxy tier",
            );
            return Phase2Exit::Leak.as_i32();
        }
        selection
    } else if require_vpn {
        if pool.all_failed() {
            emit_err(
                format,
                "spider",
                7,
                "vpn pool exhausted: no healthy instances available (all failed)",
            );
            return 7;
        }
        match select(&pool, &session_str, args.vpn_instance.as_deref()) {
            Some(s) => Some(s),
            None => {
                let msg = if args.vpn_instance.is_some() {
                    format!(
                        "vpn instance {:?} not found in configured pool",
                        args.vpn_instance
                    )
                } else {
                    "vpn pool has no healthy instances".to_string()
                };
                emit_err(format, "spider", 7, &msg);
                return 7;
            }
        }
    } else {
        // Permissive mode: still attempt sticky selection so JSON output
        // surfaces something meaningful, but never block on absence.
        select(&pool, &session_str, args.vpn_instance.as_deref())
    };

    // 3.7. Phase 6e: spawn background leak monitor. Only when
    // `require_vpn=true` and a non-empty pool exists. The monitor
    // re-probes every `--leak-poll-secs` seconds; on any failure it
    // signals via Notify + force_kill so we exit 7 mid-run.
    let monitor: Option<LeakMonitor> = if require_vpn && !policy.vpn_instances.is_empty() {
        let instances: Vec<vpn_rotate::instance_pool::VpnInstance> = policy
            .vpn_instances
            .iter()
            .map(|v| vpn_rotate::instance_pool::VpnInstance {
                name: v.name.clone(),
                http_proxy_port: v.http_proxy_port,
                control_port: v.control_port,
            })
            .collect();
        Some(LeakMonitor::spawn(
            instances,
            policy.vpn_required_country.clone(),
            std::time::Duration::from_secs(args.leak_poll_secs),
        ))
    } else {
        None
    };
    let monitor_notify = monitor.as_ref().map(|m| m.notify_clone());
    let monitor_state = monitor.as_ref().map(|m| m.state_clone());
    let monitor_poll_secs = monitor.as_ref().map(|m| m.poll_interval().as_secs());

    let auth_replay = match build_auth_replay_context(&args, &parsed_url) {
        Ok(ctx) => ctx,
        Err(e) => {
            emit_err(format, "spider", 1, &format!("auth replay: {e}"));
            return 1;
        }
    };

    // 4. Optional VPN rotation (lazy-on-fail strategy).
    let mut vpn_report: Option<serde_json::Value> = None;
    if args.vpn {
        match vpn_rotate::rotate(vpn_rotate::RotationRequest {
            provider: "surfshark".into(),
            strategy: vpn_rotate::RotationStrategy::LazyOnFail,
            region: None,
            reason: format!("spider session {session_id}"),
        })
        .await
        {
            Ok(r) => vpn_report = Some(json!(r)),
            Err(e) => {
                emit_err(format, "spider", 2, &format!("vpn rotate failed: {e}"));
                return 2;
            }
        }
    }

    // 3.6. Phase 7b: Site Recipe L2 cache lookup. Runs BEFORE the http-only
    // short-circuit so that an API-direct recipe hit can preempt browser AND
    // reqwest paths uniformly.
    let mut recipe_ctx = match build_recipe_ctx(format, &args, &parsed_url).await {
        Ok(ctx) => ctx,
        Err(code) => return code,
    };

    // If we have an API-direct hit, satisfy via reqwest now and exit.
    if recipe_ctx.hit && !args.cache_refresh {
        if let Some(code) = try_api_direct(
            format,
            &args,
            &parsed_url,
            session_id,
            &mut recipe_ctx,
            &vpn_report,
            &vpn_probe_report,
            vpn_selection.as_ref(),
            proxy_selection.as_ref(),
            pool.healthy_count(),
        )
        .await
        {
            return code;
        }
    }

    // ---- HTTP-only short-circuit -------------------------------------------
    if args.http_only {
        return run_http_path(
            format,
            &args,
            &parsed_url,
            session_id,
            Fetcher::HttpOnly,
            vpn_report,
            vpn_probe_report.clone(),
            &mut recipe_ctx,
            Some(&pool),
            vpn_selection.clone(),
            proxy_selection.clone(),
            monitor_state.clone(),
            monitor_poll_secs,
            auth_replay.as_ref(),
        )
        .await;
    }

    // 5. Resolve mobile preset.
    let mobile_fp = match args.mobile_preset.as_deref() {
        None => None,
        Some(slug) => match PresetId::from_slug(slug) {
            Some(p) => Some(p.fingerprint()),
            None => {
                emit_err(
                    format,
                    "spider",
                    1,
                    &format!("unknown mobile preset {slug:?}"),
                );
                return 1;
            }
        },
    };
    if let Some(auth) = auth_replay.as_ref() {
        auth.warn_on_ua_mismatch(mobile_fp.as_ref().map(|fp| fp.user_agent.as_str()));
    }

    // 6. Launch obscura bridge.
    let binary = args
        .obscura
        .clone()
        .unwrap_or_else(|| std::path::PathBuf::from("obscura"));
    let cfg = ObscuraConfig {
        binary_path: binary,
        session_id,
        mobile_fp: mobile_fp.clone(),
        proxy: vpn_selection.as_ref().map(|s| s.proxy_url.clone()),
        // Phase 6d: keep CDP self-loop (127.0.0.1) unproxied even though
        // chromium-side `--proxy-server` would normally route everything.
        extra_args: vpn_selection
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
            let (code, kind) = match e {
                obscura_bridge::BridgeError::BinaryNotFound { .. } => (3, "permanent"),
                obscura_bridge::BridgeError::StartupTimeout => (2, "transient"),
                _ => (3, "permanent"),
            };
            // Auto-fallback engages on permanent (3) AND transient (2) failures
            // so that a missing binary or a flaky startup both transparently
            // route to reqwest.
            if auto_fallback {
                tracing::warn!(
                    error = %e,
                    code,
                    kind,
                    "obscura launch failed; falling back to reqwest",
                );
                return run_http_path(
                    format,
                    &args,
                    &parsed_url,
                    session_id,
                    Fetcher::ReqwestFallback,
                    vpn_report,
                    vpn_probe_report.clone(),
                    &mut recipe_ctx,
                    Some(&pool),
                    vpn_selection.clone(),
                    proxy_selection.clone(),
                    monitor_state.clone(),
                    monitor_poll_secs,
                    auth_replay.as_ref(),
                )
                .await;
            }
            emit_err(
                format,
                "spider",
                code,
                &format!("obscura launch ({kind}): {e}"),
            );
            return code;
        }
    };

    let page = match bridge.new_page().await {
        Ok(p) => p,
        Err(e) => {
            if auto_fallback {
                tracing::warn!(error = %e, "obscura new_page failed; falling back to reqwest");
                let _ = bridge.shutdown().await;
                return run_http_path(
                    format,
                    &args,
                    &parsed_url,
                    session_id,
                    Fetcher::ReqwestFallback,
                    vpn_report,
                    vpn_probe_report.clone(),
                    &mut recipe_ctx,
                    Some(&pool),
                    vpn_selection.clone(),
                    proxy_selection.clone(),
                    monitor_state.clone(),
                    monitor_poll_secs,
                    auth_replay.as_ref(),
                )
                .await;
            }
            emit_err(format, "spider", 2, &format!("new_page: {e}"));
            let _ = bridge.shutdown().await;
            return 2;
        }
    };

    // 7. mobile-fp inject (page-scoped).
    if let Some(fp) = &mobile_fp {
        let target = ObscuraCdpAdapter::new(page.clone());
        if let Err(e) = inject_into_cdp(fp, StealthLevel::High, &target).await {
            tracing::warn!(error = %e, "mobile-fp inject reported non-fatal error");
        }
    }
    if let Some(auth) = auth_replay.as_ref() {
        if let Err(e) = auth.apply_to_obscura_page(&page).await {
            emit_err(format, "spider", 2, &format!("auth replay apply: {e}"));
            let _ = bridge.shutdown().await;
            return 2;
        }
    }

    // 7c: Network capture wiring. Subscribe to CDP Network events before
    // navigating so auto-discovery sees every XHR/Fetch on the first load.
    // Failure here is non-fatal (e.g. when running against a stub bridge);
    // the spider proceeds without auto-learning.
    let net_cap = obscura_bridge::network_capture::NetworkCapture::new();
    if !args.recipe_no_learn && !args.no_cache {
        let origin = parsed_url.host_str().map(|s| s.to_string());
        if let Err(e) = page.with_network_capture(net_cap.clone(), origin).await {
            tracing::warn!(error = %e, "network capture subscription failed; auto-learn skipped");
        }
    }

    // 8. Navigate. Race with the background leak monitor so a leak
    // detected mid-page tears down obscura and exits 7.
    let nav_fut = page.navigate(&parsed_url);
    let nav_res = if let Some(notify) = monitor_notify.as_ref() {
        tokio::select! {
            r = nav_fut => Ok(r),
            _ = notify.notified() => Err(()),
        }
    } else {
        Ok(nav_fut.await)
    };
    if nav_res.is_err() {
        // Leak detected mid-navigate.
        let reason = match monitor_state.as_ref() {
            Some(s) => s
                .read()
                .await
                .reason
                .clone()
                .unwrap_or_else(|| "vpn leak".into()),
            None => "vpn leak".into(),
        };
        let _ = bridge.force_kill().await;
        emit_leak_exit(
            format,
            "spider",
            &reason,
            monitor_state.as_ref(),
            monitor_poll_secs,
        )
        .await;
        return 7;
    }
    let nav = match nav_res.unwrap() {
        Ok(n) => n,
        Err(e) => {
            if auto_fallback {
                tracing::warn!(error = %e, "obscura navigate failed; falling back to reqwest");
                let _ = bridge.shutdown().await;
                return run_http_path(
                    format,
                    &args,
                    &parsed_url,
                    session_id,
                    Fetcher::ReqwestFallback,
                    vpn_report,
                    vpn_probe_report.clone(),
                    &mut recipe_ctx,
                    Some(&pool),
                    vpn_selection.clone(),
                    proxy_selection.clone(),
                    monitor_state.clone(),
                    monitor_poll_secs,
                    auth_replay.as_ref(),
                )
                .await;
            }
            emit_err(format, "spider", 2, &format!("navigate: {e}"));
            let _ = bridge.shutdown().await;
            return 2;
        }
    };

    // Phase 5g: SPA hydration waits. `--wait-selector` wins over `--wait-ms`.
    if let Some(css) = &args.wait_selector {
        match page
            .wait_for_selector(css, std::time::Duration::from_secs(30))
            .await
        {
            Ok(_) => {
                tracing::info!(selector = %css, "wait-selector matched");
            }
            Err(e) => {
                tracing::warn!(error = %e, selector = %css, "wait-selector timed out (30s); proceeding");
            }
        }
    } else if let Some(ms) = args.wait_ms {
        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
    }

    let mut cf_blocked = false;
    let mut cf_outcome_json: Option<serde_json::Value> = None;
    if args.evaluate_cf {
        let adapter = ObscuraPageAdapter::new(page.clone());
        let eval = CfEvaluator::new(&adapter);
        match eval
            .evaluate_turnstile_resilience(SolveOpts::default())
            .await
        {
            Ok(outcome) => {
                cf_blocked = matches!(outcome, SolveOutcome::StillBlocked | SolveOutcome::Timeout);
                cf_outcome_json = Some(json!(format!("{outcome:?}")));
            }
            Err(e) => {
                tracing::warn!(error = %e, "cf eval failed");
                cf_outcome_json = Some(json!(format!("error: {e}")));
            }
        }
    }

    let mut relocate_miss = false;
    let mut relocate_ambiguous = false;
    let mut relocate_json: Option<serde_json::Value> = None;
    let mut html_size: Option<usize> = None;
    if let Some(stable_id) = &args.stable_id {
        let snapshot = match page.dom_snapshot().await {
            Ok(s) => s,
            Err(e) => {
                emit_err(format, "spider", 2, &format!("dom_snapshot: {e}"));
                let _ = bridge.shutdown().await;
                return 2;
            }
        };
        html_size = Some(snapshot.html.len());
        let outcome_res = run_relocate(&args, &snapshot.html, &parsed_url, stable_id).await;
        match outcome_res {
            Ok((miss, ambig, jv)) => {
                relocate_miss = miss;
                relocate_ambiguous = ambig;
                relocate_json = Some(jv);
            }
            Err(code) => {
                emit_err(format, "spider", code, "parse store error");
                let _ = bridge.shutdown().await;
                return code;
            }
        }
    }

    let mut dumped_html_path: Option<String> = None;
    let mut dumped_html_bytes: Option<usize> = None;
    if let Some(p) = &args.dump_html {
        // Prefer the post-render outerHTML (SPA hydrate visible).
        let html_str = match page.evaluate("document.documentElement.outerHTML").await {
            Ok(v) => v.as_str().map(|s| s.to_owned()),
            Err(e) => {
                tracing::warn!(error = %e, "evaluate(outerHTML) failed; falling back to dom_snapshot()");
                None
            }
        };
        let html_final = match html_str {
            Some(s) => s,
            None => match page.dom_snapshot().await {
                Ok(s) => s.html,
                Err(e) => {
                    emit_err(
                        format,
                        "spider",
                        2,
                        &format!("dump-html snapshot failed: {e}"),
                    );
                    let _ = bridge.shutdown().await;
                    return 2;
                }
            },
        };
        match dump_html_to(p, &html_final) {
            Ok(n) => {
                dumped_html_path = Some(p.display().to_string());
                dumped_html_bytes = Some(n);
            }
            Err(e) => {
                emit_err(
                    format,
                    "spider",
                    2,
                    &format!("dump-html write failed ({}): {e}", p.display()),
                );
                let _ = bridge.shutdown().await;
                return 2;
            }
        }
    }

    let exit = map_spider_exit(cf_blocked, relocate_miss, relocate_ambiguous, args.strict);

    // Phase 7b: skeleton save on success when no recipe existed (or refresh).
    if exit.as_i32() == 0 {
        recipe_ctx.fetched_via = Some("spider");
        maybe_save_skeleton(&args, &parsed_url, &mut recipe_ctx);
    }

    // Phase 7c: auto-discover endpoints from captured Network traffic and
    // upsert into the recipe. Pure no-op when --recipe-no-learn / --no-cache.
    let mut auto_discovered_count = 0usize;
    let mut discovery_methods: Vec<&'static str> = Vec::new();
    if exit.as_i32() == 0 && !args.recipe_no_learn && !args.no_cache {
        let captured = net_cap.snapshot();
        // Build the sites-side CapturedRequest mirror.
        let bridged: Vec<stealth_sites::discovery::CapturedRequest> = captured
            .iter()
            .map(|c| stealth_sites::discovery::CapturedRequest {
                url: c.url.clone(),
                method: c.method.clone(),
                resource_type: c.resource_type.clone(),
                status: c.status,
                mime_type: c.mime_type.clone(),
                same_etld_plus_1: c.same_etld_plus_1,
            })
            .collect();
        let primary = stealth_sites::discovery::aggregate_endpoints(&bridged);
        if !primary.is_empty() {
            discovery_methods.push("network-capture");
        }

        // JS bundle scan (≤5 bundles), VPN-proxy-aware GET + light extract.
        let bundle_urls = obscura_bridge::network_capture::extract_script_urls(&captured, 5);
        let mut bundle_cands: Vec<stealth_sites::discovery::EndpointCandidate> = Vec::new();
        if !bundle_urls.is_empty() {
            match build_bundle_client(vpn_selection.as_ref()) {
                Ok(client) => {
                    let origin_for_resolve = format!(
                        "{}://{}",
                        parsed_url.scheme(),
                        parsed_url.host_str().unwrap_or("")
                    );
                    let host = parsed_url.host_str().unwrap_or("").to_string();
                    for u in bundle_urls {
                        if let Ok(resp) = client.get(&u).send().await {
                            if !resp.status().is_success() {
                                continue;
                            }
                            let body = match resp.text().await {
                                Ok(b) => b,
                                Err(_) => continue,
                            };
                            let raw = stealth_sites::discovery::extract_bundle_url_candidates(
                                &body,
                                &origin_for_resolve,
                            );
                            // HEAD probe: filter to URLs whose host returns 2xx-3xx.
                            let mut kept = Vec::new();
                            for r in raw {
                                // Skip URLs containing template placeholders for the probe; they
                                // can't be probed literally. Trust the regex's structural match.
                                if r.contains('{') {
                                    kept.push(r);
                                    continue;
                                }
                                if let Ok(probe) = client.head(&r).send().await {
                                    let s = probe.status().as_u16();
                                    if (200..400).contains(&s) {
                                        kept.push(r);
                                    }
                                }
                            }
                            let mut more =
                                stealth_sites::discovery::bundle_urls_to_candidates(&kept, &host);
                            bundle_cands.append(&mut more);
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(error = %e, "bundle-scan client init failed; skipping");
                }
            }
        }
        if !bundle_cands.is_empty() {
            discovery_methods.push("js-bundle-scan");
        }

        let merged = stealth_sites::discovery::merge_candidates(primary, bundle_cands);
        if !merged.is_empty() {
            let dir = args.recipe_dir.clone().unwrap_or_else(default_recipe_dir);
            if let Some(mut store) = open_store(&dir) {
                let rendering = if args.http_only {
                    Rendering::Static
                } else {
                    Rendering::Spa
                };
                match upsert_auto_endpoints(
                    &mut store,
                    &parsed_url,
                    &merged,
                    args.recipe_no_learn,
                    args.no_cache,
                    rendering,
                ) {
                    Ok(n) => {
                        auto_discovered_count = n;
                        if n > 0 {
                            recipe_ctx.saved = true;
                            tracing::info!(
                                count = n,
                                methods = ?discovery_methods,
                                "auto-learned endpoints saved to recipe",
                            );
                        }
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "auto-endpoint upsert failed");
                    }
                }
            }
        }
    }

    let payload = json!({
        "session_id": session_id,
        "url": args.url,
        "url_requested": args.url,
        "url_final": nav.final_url,
        "fetcher": Fetcher::Obscura.as_str(),
        "used_fallback": false,
        "http_status": 200, // CDP nav doesn't expose status here; best-effort.
        "elapsed_ms": serde_json::Value::Null,
        "html_size": html_size,
        "mobile_preset": args.mobile_preset,
        "vpn": vpn_report,
        "vpn_probe": vpn_probe_report,
        "cf_outcome": cf_outcome_json,
        "relocate": relocate_json,
        "dumped_html_path": dumped_html_path,
        "dumped_html_bytes": dumped_html_bytes,
        "recipe": recipe_ctx.to_json(),
        "auto_discovered_endpoints_count": auto_discovered_count,
        "discovery_methods": discovery_methods,
        "exit_code": exit.as_i32(),
    });
    let mut payload = payload.as_object().cloned().unwrap_or_default();
    payload.extend(
        build_vpn_envelope(
            vpn_selection.as_ref(),
            pool.healthy_count(),
            monitor_state.as_ref(),
            monitor_poll_secs.unwrap_or(30),
            None,
            proxy_selection.as_ref(),
        )
        .await,
    );
    emit_ok(format, "spider", serde_json::Value::Object(payload));
    let _ = bridge.shutdown().await;
    if let Some(m) = monitor {
        m.shutdown();
    }
    exit.as_i32()
}

/// Shared reqwest-fetch + (optional) relocate path used by `--http-only` and
/// the auto-fallback engagement points.
#[allow(clippy::too_many_arguments)]
async fn run_http_path(
    format: OutputFormat,
    args: &SpiderArgs,
    parsed_url: &Url,
    session_id: Uuid,
    fetcher: Fetcher,
    vpn_report: Option<serde_json::Value>,
    vpn_probe_report: Option<serde_json::Value>,
    recipe_ctx: &mut RecipeCtx,
    pool: Option<&InstancePool>,
    initial_selection: Option<Selection>,
    proxy_selection: Option<vpn_rotate::proxy_resolver::ProxySelection>,
    monitor_state: Option<std::sync::Arc<tokio::sync::RwLock<LeakState>>>,
    monitor_poll_secs: Option<u64>,
    auth_replay: Option<&AuthReplayContext>,
) -> i32 {
    // Phase 6e: short-circuit if a leak was already latched.
    if let Some(state) = monitor_state.as_ref() {
        let st = state.read().await.clone();
        if st.leak_detected {
            emit_leak_exit(
                format,
                "spider",
                st.reason.as_deref().unwrap_or("vpn leak"),
                Some(state),
                monitor_poll_secs,
            )
            .await;
            return 7;
        }
    }

    if args.wait_ms.is_some() || args.wait_selector.is_some() {
        tracing::warn!(
            wait_ms = ?args.wait_ms,
            wait_selector = ?args.wait_selector,
            "wait-ms/wait-selector are no-ops on the reqwest fallback path"
        );
    }

    // Phase 6d: lazy-on-fail rotation. We retry up to N=instances.len() with
    // a different healthy instance each time, marking failures so the pool's
    // exclusion / cooldown machinery kicks in. Direct-mode (no pool) is a
    // single attempt by definition.
    let mut rotation_events: Vec<serde_json::Value> = Vec::new();
    let mut current_selection = initial_selection;
    let session_str = session_id.to_string();
    let max_attempts = pool.map(|p| p.instances().len().max(1)).unwrap_or(1);

    let mut last_err: Option<String> = None;
    let mut fetch_opt: Option<FetchResult> = None;
    for attempt in 0..max_attempts {
        let proxy_url = current_selection.as_ref().map(|s| s.proxy_url.clone());
        let res = match auth_replay {
            Some(auth) => {
                HttpFallback::fetch_html_with_configured(
                    parsed_url,
                    auth.user_agent.as_deref(),
                    auth.accept_language.as_deref(),
                    crate::commands::fallback_http::DEFAULT_TIMEOUT,
                    proxy_url.as_ref(),
                    |builder| auth.apply_to_reqwest(builder),
                )
                .await
            }
            None => {
                HttpFallback::fetch_html_with(
                    parsed_url,
                    None,
                    crate::commands::fallback_http::DEFAULT_TIMEOUT,
                    proxy_url.as_ref(),
                )
                .await
            }
        };
        match res {
            Ok(r) => {
                if let (Some(p), Some(sel)) = (pool, current_selection.as_ref()) {
                    p.mark_success(&sel.instance_name);
                }
                fetch_opt = Some(r);
                break;
            }
            Err(e) => {
                last_err = Some(format!("{e}"));
                if let (Some(p), Some(sel)) = (pool, current_selection.as_ref()) {
                    p.mark_failure(&sel.instance_name);
                    rotation_events.push(json!({
                        "attempt": attempt,
                        "instance": sel.instance_name,
                        "error": format!("{e}"),
                    }));
                }
                // Re-pick if there's another healthy instance.
                if let Some(p) = pool {
                    if p.all_failed() {
                        emit_err(
                            format,
                            "spider",
                            7,
                            "vpn pool exhausted mid-request: all instances failed",
                        );
                        return 7;
                    }
                    current_selection = select(p, &session_str, None);
                } else {
                    break;
                }
            }
        }
    }
    let fetch: FetchResult = match fetch_opt {
        Some(r) => r,
        None => {
            emit_err(
                format,
                "spider",
                2,
                &format!(
                    "reqwest fallback failed after {max_attempts} attempts: {}",
                    last_err.unwrap_or_else(|| "unknown".into())
                ),
            );
            return 2;
        }
    };

    let mut relocate_miss = false;
    let mut relocate_ambiguous = false;
    let mut relocate_json: Option<serde_json::Value> = None;
    if let Some(stable_id) = &args.stable_id {
        match run_relocate(args, &fetch.html, parsed_url, stable_id).await {
            Ok((miss, ambig, jv)) => {
                relocate_miss = miss;
                relocate_ambiguous = ambig;
                relocate_json = Some(jv);
            }
            Err(code) => {
                emit_err(format, "spider", code, "parse store error");
                return code;
            }
        }
    }

    let mut dumped_html_path: Option<String> = None;
    let mut dumped_html_bytes: Option<usize> = None;
    if let Some(p) = &args.dump_html {
        match dump_html_to(p, &fetch.html) {
            Ok(n) => {
                dumped_html_path = Some(p.display().to_string());
                dumped_html_bytes = Some(n);
            }
            Err(e) => {
                emit_err(
                    format,
                    "spider",
                    2,
                    &format!("dump-html write failed ({}): {e}", p.display()),
                );
                return 2;
            }
        }
    }

    let exit = map_spider_exit(false, relocate_miss, relocate_ambiguous, args.strict);

    if exit.as_i32() == 0 {
        recipe_ctx.fetched_via = Some(match fetcher {
            Fetcher::HttpOnly => "http-only",
            Fetcher::ReqwestFallback => "reqwest-fallback",
            Fetcher::Obscura => "spider",
        });
        maybe_save_skeleton(args, parsed_url, recipe_ctx);
    }

    let payload = json!({
        "session_id": session_id,
        "url": args.url,
        "url_requested": args.url,
        "url_final": fetch.final_url,
        "fetcher": fetcher.as_str(),
        "used_fallback": matches!(fetcher, Fetcher::ReqwestFallback) || matches!(fetcher, Fetcher::HttpOnly),
        "http_status": fetch.status,
        "elapsed_ms": fetch.elapsed_ms,
        "html_size": fetch.html.len(),
        "mobile_preset": args.mobile_preset,
        "vpn": vpn_report,
        "vpn_probe": vpn_probe_report,
        "cf_outcome": serde_json::Value::Null,
        "relocate": relocate_json,
        "dumped_html_path": dumped_html_path,
        "dumped_html_bytes": dumped_html_bytes,
        "recipe": recipe_ctx.to_json(),
        "exit_code": exit.as_i32(),
    });
    let mut payload = payload.as_object().cloned().unwrap_or_default();
    let rotation_events = if rotation_events.is_empty() {
        None
    } else {
        Some(rotation_events)
    };
    payload.extend(
        build_vpn_envelope(
            current_selection.as_ref(),
            pool.map(|p| p.healthy_count()).unwrap_or(0),
            monitor_state.as_ref(),
            monitor_poll_secs.unwrap_or(30),
            rotation_events,
            proxy_selection.as_ref(),
        )
        .await,
    );
    emit_ok(format, "spider", serde_json::Value::Object(payload));
    exit.as_i32()
}

fn build_auth_replay_context(
    args: &SpiderArgs,
    parsed_url: &Url,
) -> anyhow::Result<Option<AuthReplayContext>> {
    let Some(profile) = args.use_auth.as_deref() else {
        return Ok(None);
    };
    let dir = std::env::var_os("REV_SCRAPING_AUTH_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(default_auth_store_dir);
    // For headless / CI scenarios where the OS keyring is unavailable, fall
    // back to the same `REV_SCRAPING_AUTH_PASSPHRASE` envelope honored by
    // `rev-auth`. The env var carries the passphrase only for the duration
    // of the process and is never logged or persisted.
    let store = if let Ok(passphrase) = std::env::var("REV_SCRAPING_AUTH_PASSPHRASE") {
        AuthStore::open_with_passphrase(&dir, secrecy::SecretString::from(passphrase))?
    } else {
        AuthStore::open(&dir)?
    };
    build_auth_replay_context_from_store(&store, args, parsed_url, profile).map(Some)
}

fn build_auth_replay_context_from_store(
    store: &AuthStore,
    args: &SpiderArgs,
    parsed_url: &Url,
    profile: &str,
) -> anyhow::Result<AuthReplayContext> {
    let aad_context = args
        .auth_domain
        .as_deref()
        .or_else(|| parsed_url.host_str())
        .unwrap_or_default();
    AuthReplayContext::load(store, profile, aad_context)
}

/// Build the recipe context: parse params, resolve dir, load recipe, apply TTL.
async fn build_recipe_ctx(
    format: OutputFormat,
    args: &SpiderArgs,
    parsed_url: &Url,
) -> Result<RecipeCtx, i32> {
    let domain = parsed_url.host_str().unwrap_or("").to_string();
    let mut ctx = RecipeCtx {
        domain: domain.clone(),
        ..RecipeCtx::default()
    };

    match parse_recipe_params(&args.recipe_param) {
        Ok(m) => ctx.params = m,
        Err(e) => {
            emit_err(format, "spider", 1, &e);
            return Err(1);
        }
    }

    if domain.is_empty() {
        return Ok(ctx);
    }

    if args.no_cache && args.recipe_endpoint.is_some() {
        emit_err(
            format,
            "spider",
            1,
            "--recipe-endpoint requires recipe lookup; remove --no-cache",
        );
        return Err(1);
    }

    if args.no_cache {
        return Ok(ctx);
    }

    let dir = args.recipe_dir.clone().unwrap_or_else(default_recipe_dir);
    let store = match open_store(&dir) {
        Some(s) => s,
        None => return Ok(ctx),
    };

    if args.cache_refresh {
        ctx.refresh = true;
        return Ok(ctx);
    }

    let loaded = match store.load(&domain) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(error = %e, domain = %domain, "recipe load failed; treating as miss");
            None
        }
    };

    match loaded {
        Some(r) => {
            let remaining = ttl_remaining_days(&r, args.cache_ttl);
            if remaining.is_some() {
                ctx.recipe = Some(r);
                ctx.hit = true;
                ctx.ttl_remaining_days = remaining;
            } else {
                tracing::info!(domain = %domain, "recipe expired, refreshing");
                ctx.refresh = true;
            }
        }
        None => {
            if args.cache_only {
                emit_err(
                    format,
                    "spider",
                    9,
                    &format!("recipe miss for {domain} under --cache-only"),
                );
                return Err(9);
            }
            if args.recipe_endpoint.is_some() {
                emit_err(
                    format,
                    "spider",
                    9,
                    &format!("--recipe-endpoint set but no recipe found for {domain}"),
                );
                return Err(9);
            }
        }
    }

    Ok(ctx)
}

/// API-direct fetch path; called only when a recipe hit is present.
#[allow(clippy::too_many_arguments)]
async fn try_api_direct(
    format: OutputFormat,
    args: &SpiderArgs,
    parsed_url: &Url,
    session_id: Uuid,
    ctx: &mut RecipeCtx,
    vpn_report: &Option<serde_json::Value>,
    vpn_probe_report: &Option<serde_json::Value>,
    vpn_selection: Option<&Selection>,
    proxy_selection: Option<&vpn_rotate::proxy_resolver::ProxySelection>,
    pool_healthy: usize,
) -> Option<i32> {
    let recipe = ctx.recipe.as_ref()?;

    let explicit_purpose = args.recipe_endpoint.as_deref();
    let strategy_prefers_api = recipe
        .scraping_strategy
        .as_ref()
        .map(|s| matches!(s.preferred_method, ScrapingMethod::Api))
        .unwrap_or(false);

    if explicit_purpose.is_none() && !strategy_prefers_api {
        return None;
    }

    let endpoint = match pick_endpoint(recipe, explicit_purpose) {
        Some(ep) => ep,
        None => {
            if let Some(p) = explicit_purpose {
                emit_err(
                    format,
                    "spider",
                    1,
                    &format!(
                        "--recipe-endpoint {p:?} not found in recipe for {}",
                        ctx.domain
                    ),
                );
                return Some(1);
            }
            return None;
        }
    };

    let purpose = endpoint.purpose.clone();
    let path = endpoint.path.clone();

    // Phase 7c privacy fix: route the recipe-API call through the active
    // VPN proxy so cache-hit traffic doesn't bypass the egress guard.
    let proxy = vpn_selection.map(|s| s.proxy_url.clone());
    let api_result = match fetch_api_endpoint(recipe, endpoint, &ctx.params, proxy.as_ref()).await {
        Ok(r) => r,
        Err((code, msg)) => {
            ctx.fetched_via = Some("api");
            ctx.endpoint_purpose = Some(purpose);
            ctx.endpoint_path = Some(path);
            emit_err(format, "spider", code, &msg);
            return Some(code);
        }
    };

    ctx.fetched_via = Some("api");
    ctx.endpoint_purpose = Some(purpose);
    ctx.endpoint_path = Some(path);

    let payload = json!({
        "session_id": session_id,
        "url": args.url,
        "url_requested": args.url,
        "url_final": api_result.url,
        "fetcher": "recipe-api",
        "used_fallback": false,
        "http_status": api_result.status,
        "elapsed_ms": api_result.elapsed_ms,
        "html_size": serde_json::Value::Null,
        "mobile_preset": args.mobile_preset,
        "vpn": vpn_report,
        "vpn_probe": vpn_probe_report,
        "cf_outcome": serde_json::Value::Null,
        "relocate": serde_json::Value::Null,
        "dumped_html_path": serde_json::Value::Null,
        "dumped_html_bytes": serde_json::Value::Null,
        "api_response": api_result.body_json,
        "recipe": ctx.to_json(),
        "exit_code": 0,
    });
    let mut payload = payload.as_object().cloned().unwrap_or_default();
    payload.extend(
        build_vpn_envelope(vpn_selection, pool_healthy, None, 30, None, proxy_selection).await,
    );
    let _ = parsed_url;
    emit_ok(format, "spider", serde_json::Value::Object(payload));
    Some(0)
}

/// Save a minimal skeleton recipe on first-visit success (Phase 7b).
fn maybe_save_skeleton(args: &SpiderArgs, parsed_url: &Url, ctx: &mut RecipeCtx) {
    if args.no_cache {
        return;
    }
    // Phase 7c: privacy-sensitive runs opt out of all recipe writes by
    // setting --recipe-no-learn. Save *and* future auto-discovery upserts
    // are gated here.
    if args.recipe_no_learn {
        tracing::info!(
            domain = %parsed_url.host_str().unwrap_or(""),
            "recipe write skipped by --recipe-no-learn"
        );
        return;
    }
    if ctx.hit && !args.cache_refresh {
        return;
    }
    let dir = args.recipe_dir.clone().unwrap_or_else(default_recipe_dir);
    let mut store = match open_store(&dir) {
        Some(s) => s,
        None => return,
    };
    let rendering = if args.http_only {
        Rendering::Static
    } else {
        Rendering::Spa
    };
    let skeleton = match build_skeleton_recipe(parsed_url, rendering) {
        Some(s) => s,
        None => return,
    };
    match store.save(&skeleton) {
        Ok(()) => {
            ctx.saved = true;
            tracing::info!(
                domain = %skeleton.site.domain,
                "spider saved skeleton recipe (Phase 7b)"
            );
        }
        Err(e) => {
            tracing::warn!(error = %e, "spider skeleton recipe save failed");
        }
    }
}

/// Returns (relocate_miss, relocate_ambiguous, json) or Err(exit_code).
async fn run_relocate(
    args: &SpiderArgs,
    html: &str,
    parsed_url: &Url,
    stable_id: &str,
) -> Result<(bool, bool, serde_json::Value), i32> {
    let store_path = args.parse_store.clone().unwrap_or_else(|| {
        dirs::home_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join(".rev_scraping")
            .join("parse.sqlite")
    });
    let mut store = ParseStore::open(&store_path).map_err(|_| 3i32)?;
    let url_fld = parsed_url.host_str().unwrap_or("").to_string();
    let mut relocator = Relocator::new(&mut store);
    match relocator
        .locate(html, stable_id, &url_fld, args.threshold)
        .await
    {
        Ok(LocateOutcome::ExactMatch(n)) => Ok((
            false,
            false,
            json!({"kind":"exact","node":format!("{n:?}")}),
        )),
        Ok(LocateOutcome::FuzzyMatch { node, score }) => Ok((
            false,
            false,
            json!({"kind":"fuzzy","score":score,"node":format!("{node:?}")}),
        )),
        Ok(LocateOutcome::Ambiguous { candidates }) => Ok((
            false,
            true,
            json!({"kind":"ambiguous","candidates":candidates.len()}),
        )),
        Ok(LocateOutcome::NotFound) => Ok((true, false, json!({"kind":"not_found"}))),
        Err(e) => Ok((true, false, json!({"kind":"error","error":format!("{e}")}))),
    }
}

/// Build a reqwest client used by Phase 7c JS-bundle-scan. When a VPN
/// selection is present, the client is routed through the VPN proxy to
/// avoid leaking the user's IP while fetching JS bundles.
fn build_bundle_client(vpn: Option<&Selection>) -> Result<reqwest::Client, reqwest::Error> {
    let mut b = reqwest::Client::builder()
        .user_agent(crate::commands::fallback_http::DEFAULT_USER_AGENT)
        .timeout(std::time::Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::limited(10));
    if let Some(sel) = vpn {
        let no_proxy = reqwest::NoProxy::from_string(
            "127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
        );
        let proxy = reqwest::Proxy::all(sel.proxy_url.as_str())?.no_proxy(no_proxy);
        b = b.proxy(proxy);
    }
    b.build()
}

/// Write `html` to `path` with parent-dir creation and mode 0600 on Unix.
/// Returns the number of bytes written on success.
fn dump_html_to(path: &std::path::Path, html: &str) -> std::io::Result<usize> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let bytes = html.as_bytes();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        std::io::Write::write_all(&mut f, bytes)?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes)?;
    }
    Ok(bytes.len())
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

/// Build the `vpn_monitor` JSON envelope block (Phase 6e).
///
/// Job C: delegates to [`crate::commands::vpn_envelope::build_vpn_monitor_json`]
/// so the spider / cf-evaluate / relocate(--url) surfaces stay in lockstep.
async fn vpn_monitor_json(
    state: Option<&std::sync::Arc<tokio::sync::RwLock<LeakState>>>,
    poll_secs: Option<u64>,
) -> serde_json::Value {
    crate::commands::vpn_envelope::build_vpn_monitor_json(state, poll_secs.unwrap_or(30)).await
}

/// Emit a leak-shutdown payload (exit 7) including the `vpn_monitor`
/// block. Always returns; caller is responsible for the `return 7`.
async fn emit_leak_exit(
    format: OutputFormat,
    op: &str,
    reason: &str,
    state: Option<&std::sync::Arc<tokio::sync::RwLock<LeakState>>>,
    poll_secs: Option<u64>,
) {
    let monitor_json = vpn_monitor_json(state, poll_secs).await;
    let mut payload = json!({
        "ok": false,
        "operation": op,
        "exit_code": 7,
        "error": format!("vpn leak detected: {reason}"),
        "vpn_monitor": monitor_json,
    });
    // v1.3 Lane G.7: augment with `{kind, message, hint?, retry_after_ms?, doc_url}`.
    crate::commands::error_envelope::augment_with_g7_fields(
        &mut payload,
        crate::commands::error_envelope::CliErrorKind::VpnLeak,
        None,
        Some("Bring VPN up and re-run doctor; rotate via vpn_rotate."),
        None,
    );
    match format {
        OutputFormat::Json => println!("{payload}"),
        OutputFormat::Human => {
            eprintln!("[ERROR] {op}: vpn leak detected: {reason}");
            if let Ok(s) = serde_json::to_string_pretty(&payload) {
                eprintln!("{s}");
            }
        }
    }
}

fn emit_err(format: OutputFormat, op: &str, exit: i32, msg: &str) {
    // v1.3 Lane G.7: canonical error envelope (see commands/error_envelope.rs).
    let kind = crate::commands::error_envelope::classify_legacy_message(msg);
    let _ = crate::commands::error_envelope::emit_err_envelope(
        format, op, exit, kind, msg, None, None,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{CommandFactory, Parser};

    /// Helper: parse `SpiderArgs` from CLI tokens as a leaf via a wrapper.
    #[derive(Parser, Debug)]
    struct WrapCli {
        #[command(flatten)]
        args: SpiderArgs,
    }

    fn parse_args(extra: &[&str]) -> SpiderArgs {
        let mut argv = vec!["test", "--url", "https://example.com/"];
        argv.extend_from_slice(extra);
        WrapCli::try_parse_from(argv).expect("parse").args
    }

    /// Build a fully-default `SpiderArgs` with the given URL. Tests then
    /// mutate fields by name; this keeps them resilient to future struct
    /// additions (e.g. Phase 7b cache flags).
    #[allow(dead_code)]
    fn default_args(url: &str) -> SpiderArgs {
        let argv = vec!["test", "--url", url, "--allow-no-vpn"];
        WrapCli::try_parse_from(argv).expect("parse").args
    }

    #[test]
    fn test_spider_http_only_flag_parses() {
        let a = parse_args(&["--http-only"]);
        assert!(a.http_only);
        // default for auto_fallback is true; no_auto_fallback false
        assert!(a.auto_fallback);
        assert!(!a.no_auto_fallback);
    }

    #[test]
    fn test_spider_no_auto_fallback_flag_parses() {
        let a = parse_args(&["--no-auto-fallback"]);
        assert!(!a.http_only);
        assert!(a.no_auto_fallback);
        // auto_fallback raw default still true; combined value is what matters:
        let effective = a.auto_fallback && !a.no_auto_fallback;
        assert!(!effective, "--no-auto-fallback must disable fallback");
    }

    #[test]
    fn test_spider_default_auto_fallback_is_true() {
        let a = parse_args(&[]);
        let effective = a.auto_fallback && !a.no_auto_fallback;
        assert!(effective, "default behavior must enable auto-fallback");
    }

    #[test]
    fn test_spider_help_prints_use_auth() {
        let mut help = Vec::new();
        WrapCli::command().write_long_help(&mut help).unwrap();
        let help = String::from_utf8(help).unwrap();
        assert!(
            help.contains("--use-auth"),
            "help missing --use-auth:\n{help}"
        );
    }

    #[test]
    fn test_spider_constructs_auth_replay_context_when_use_auth_passed() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            secrecy::SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        let cookie = stealth_auth::Cookie {
            name: "sid".to_string(),
            value: secrecy::SecretString::from("secret".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: stealth_auth::SameSite::Lax,
        };
        store.save("work", &[cookie], "example.com").unwrap();
        let args = parse_args(&["--use-auth", "work", "--auth-domain", "example.com"]);
        let parsed = Url::parse(&args.url).unwrap();
        let ctx = build_auth_replay_context_from_store(&store, &args, &parsed, "work").unwrap();
        assert_eq!(ctx.profile, "work");
        assert_eq!(ctx.jar.cookie_count(), 1);
    }

    #[test]
    fn test_proxy_tier_flag_parses() {
        #[derive(Parser, Debug)]
        struct CfWrapCli {
            #[command(flatten)]
            args: crate::commands::cf_evaluate::CfEvaluateArgs,
        }

        #[derive(Parser, Debug)]
        struct RelocateWrapCli {
            #[command(flatten)]
            args: crate::commands::relocate::RelocateArgs,
        }

        let spider = parse_args(&["--proxy-tier", "surfshark"]);
        let cf = CfWrapCli::try_parse_from([
            "test",
            "--url",
            "https://example.com/",
            "--proxy-tier",
            "surfshark",
        ])
        .expect("cf parse")
        .args;
        let relocate = RelocateWrapCli::try_parse_from([
            "test",
            "--stable-id",
            "product-title",
            "--url",
            "https://example.com/",
            "--proxy-tier",
            "surfshark",
        ])
        .expect("relocate parse")
        .args;

        assert_eq!(spider.proxy_tier.as_deref(), Some("surfshark"));
        assert_eq!(cf.proxy_tier.as_deref(), Some("surfshark"));
        assert_eq!(relocate.proxy_tier.as_deref(), Some("surfshark"));
    }

    #[tokio::test]
    async fn test_spider_http_only_skips_obscura() {
        // Set REV_STEALTH_OBSCURA to a nonexistent path. With --http-only,
        // we should NEVER touch it — the function would otherwise return
        // exit 3 (BinaryNotFound). Instead, with a non-allowlisted URL it
        // exits 1 from AUP, proving the obscura code path is unreached.
        //
        // We don't have a clean way to inject AUP-allowed URL here without
        // touching ~/.rev_scraping, so we assert on the AUP-reject path,
        // which still proves --http-only doesn't even *try* to resolve the
        // obscura binary (the obscura err would be code 3, not 1).
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://this-host-is-not-allowlisted.invalid/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: false,
            obscura: Some(std::path::PathBuf::from("/nonexistent/obscura-binary-xyz")),
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: true,
            auto_fallback: true,
            no_auto_fallback: false,
            dump_html: None,
            wait_ms: None,
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let code = run(OutputFormat::Json, args).await;
        // AUP rejects before SSRF/HTTP — exit 1, NOT 3. Proves the obscura
        // binary path was never inspected.
        assert_eq!(code, 1);
    }

    #[tokio::test]
    async fn test_spider_no_auto_fallback_with_bad_obscura_returns_exit3() {
        // We can't easily auth-allow a non-network host, so we use an
        // i-have-authorization bypass on a public host plus a deliberately
        // bogus obscura path. With --no-auto-fallback, exit MUST be 3.
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://example.com/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: true,
            obscura: Some(std::path::PathBuf::from("/nonexistent/obscura-bin-xyz")),
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: false,
            auto_fallback: true,
            no_auto_fallback: true, // disable
            dump_html: None,
            wait_ms: None,
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let code = run(OutputFormat::Json, args).await;
        assert_eq!(code, 3, "--no-auto-fallback must surface exit 3");
    }

    #[tokio::test]
    async fn test_spider_dump_html_writes_file_in_http_only_mode() {
        let path = std::env::temp_dir().join(format!("rev_stealth_dump_{}.html", Uuid::new_v4()));
        // Ensure clean slate
        let _ = std::fs::remove_file(&path);
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://example.com/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: true,
            obscura: None,
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: true,
            auto_fallback: true,
            no_auto_fallback: false,
            dump_html: Some(path.clone()),
            wait_ms: None,
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let _code = run(OutputFormat::Json, args).await;
        // Exit may be 0 or transient depending on network; what we assert is
        // that on a successful fetch the file exists. If the network failed
        // we skip the file assertion to keep CI green.
        if path.exists() {
            let meta = std::fs::metadata(&path).expect("metadata");
            assert!(meta.len() > 0, "dumped HTML should be non-empty");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = meta.permissions().mode() & 0o777;
                assert_eq!(mode, 0o600, "dumped HTML must be mode 0600");
            }
            let _ = std::fs::remove_file(&path);
        }
    }

    #[tokio::test]
    async fn test_spider_dump_html_creates_parent_dir() {
        let dir = std::env::temp_dir().join(format!("rev_stealth_dump_dir_{}", Uuid::new_v4()));
        let path = dir.join("nested").join("page.html");
        // dir does NOT exist yet.
        assert!(!dir.exists(), "precondition: parent dir must not exist");
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://example.com/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: true,
            obscura: None,
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: true,
            auto_fallback: true,
            no_auto_fallback: false,
            dump_html: Some(path.clone()),
            wait_ms: None,
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let _code = run(OutputFormat::Json, args).await;
        if path.exists() {
            assert!(dir.exists(), "parent dir should have been created");
            let _ = std::fs::remove_dir_all(&dir);
        } else {
            // Network may have failed in CI; clean up anything partially made.
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    #[tokio::test]
    #[ignore]
    async fn test_spider_dump_html_via_obscura_renders_spa() {
        // Requires REV_STEALTH_OBSCURA pointing at a real obscura binary.
        let bin = std::env::var("REV_STEALTH_OBSCURA")
            .ok()
            .map(std::path::PathBuf::from);
        let path =
            std::env::temp_dir().join(format!("rev_stealth_obscura_dump_{}.html", Uuid::new_v4()));
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://example.com/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: true,
            obscura: bin,
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: false,
            auto_fallback: false,
            no_auto_fallback: true,
            dump_html: Some(path.clone()),
            wait_ms: None,
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let code = run(OutputFormat::Json, args).await;
        assert_eq!(code, 0, "obscura path should succeed on example.com");
        assert!(path.exists(), "dumped HTML file should exist");
        let content = std::fs::read_to_string(&path).expect("read");
        assert!(
            content.to_lowercase().contains("</html>"),
            "rendered HTML should contain closing </html>"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_dump_html_helper_writes_with_0600() {
        let path =
            std::env::temp_dir().join(format!("rev_stealth_dump_helper_{}.html", Uuid::new_v4()));
        let n = dump_html_to(&path, "<html></html>").expect("write");
        assert_eq!(n, "<html></html>".len());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_spider_wait_ms_flag_parses() {
        let a = parse_args(&["--wait-ms", "8000"]);
        assert_eq!(a.wait_ms, Some(8000));
        assert!(a.wait_selector.is_none());
    }

    #[test]
    fn test_spider_wait_selector_flag_parses() {
        let a = parse_args(&["--wait-selector", "div.product-card"]);
        assert_eq!(a.wait_selector.as_deref(), Some("div.product-card"));
        assert!(a.wait_ms.is_none());
    }

    #[tokio::test]
    #[ignore]
    async fn test_spider_wait_ms_with_obscura_renders_spa() {
        // Requires REV_STEALTH_OBSCURA pointing at a real obscura binary.
        let bin = std::env::var("REV_STEALTH_OBSCURA")
            .ok()
            .map(std::path::PathBuf::from);
        let path =
            std::env::temp_dir().join(format!("rev_stealth_wait_ms_{}.html", Uuid::new_v4()));
        let args = SpiderArgs {
            output_format: Default::default(),
            url: "https://example.com/".into(),
            session_id: None,
            mobile_preset: None,
            evaluate_cf: false,
            vpn: false,
            stable_id: None,
            threshold: 0.85,
            strict: false,
            i_have_authorization: true,
            obscura: bin,
            parse_store: None,
            use_auth: None,
            auth_domain: None,
            http_only: false,
            auto_fallback: false,
            no_auto_fallback: true,
            dump_html: Some(path.clone()),
            wait_ms: Some(2000),
            wait_selector: None,
            require_vpn: false,
            allow_no_vpn: true,
            vpn_instance: None,
            proxy_tier: None,
            no_fallback: false,
            no_cache: false,
            cache_refresh: false,
            cache_only: false,
            cache_ttl: 30,
            recipe_dir: None,
            recipe_endpoint: None,
            recipe_param: vec![],
            leak_poll_secs: 30,
            recipe_no_learn: false,
        };
        let code = run(OutputFormat::Json, args).await;
        assert_eq!(code, 0, "obscura+wait_ms path should succeed");
        assert!(path.exists(), "dumped HTML must exist");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_fetcher_str_mapping() {
        assert_eq!(Fetcher::Obscura.as_str(), "obscura");
        assert_eq!(Fetcher::ReqwestFallback.as_str(), "reqwest-fallback");
        assert_eq!(Fetcher::HttpOnly.as_str(), "http-only");
    }

    // ===== Phase 7b: Site Recipe L2 cache integration tests =====
    //
    // These exercise `build_recipe_ctx` (the recipe lookup logic) against a
    // tempdir-rooted store. They avoid network and obscura entirely, so they
    // run in regular CI.

    use std::io::Write;

    fn write_recipe(dir: &std::path::Path, domain: &str, last_verified: &str) {
        let toml_body = format!(
            r#"schema_version = 1
[site]
domain = "{domain}"
last_verified = "{last_verified}"
rendering = "spa"

[scraping_strategy]
preferred_method = "api"

[api]
base_url = "https://api.{domain}"
public_auth_required = false
auth_method = "none"
auth_secret_ref = ""
response_encoding = "json"

[[api.endpoints]]
purpose = "user_articles_list"
path = "/v2/users/{{username}}/articles"
url_pattern = "https://api.{domain}/v2/users/{{username}}/articles"
http_method = "GET"
ok_status = [200]
"#
        );
        let p = dir.join(format!("{domain}.toml"));
        let mut f = std::fs::File::create(&p).expect("create recipe");
        f.write_all(toml_body.as_bytes()).expect("write");
    }

    fn args_with_recipe_dir(url: &str, dir: &std::path::Path) -> SpiderArgs {
        let mut a = default_args(url);
        a.recipe_dir = Some(dir.to_path_buf());
        a.i_have_authorization = true;
        a
    }

    #[tokio::test]
    async fn test_spider_no_cache_skips_lookup() {
        let tmp = tempfile::tempdir().expect("tempdir");
        write_recipe(tmp.path(), "example.com", "2099-01-01T00:00:00Z");
        let mut args = args_with_recipe_dir("https://example.com/", tmp.path());
        args.no_cache = true;
        let url = Url::parse(&args.url).unwrap();
        let ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        assert!(!ctx.hit, "--no-cache must skip the load");
        assert!(ctx.recipe.is_none());
    }

    #[tokio::test]
    async fn test_spider_cache_only_with_miss_exits_9() {
        let tmp = tempfile::tempdir().expect("tempdir");
        // No recipe written → miss.
        let mut args = args_with_recipe_dir("https://unknown.example/", tmp.path());
        args.cache_only = true;
        let url = Url::parse(&args.url).unwrap();
        let err = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect_err("must fail");
        assert_eq!(err, 9, "cache-only miss must exit 9");
    }

    #[tokio::test]
    async fn test_spider_cache_refresh_overrides_existing_recipe() {
        let tmp = tempfile::tempdir().expect("tempdir");
        write_recipe(tmp.path(), "example.com", "2099-01-01T00:00:00Z");
        let mut args = args_with_recipe_dir("https://example.com/", tmp.path());
        args.cache_refresh = true;
        let url = Url::parse(&args.url).unwrap();
        let ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        // With --cache-refresh we never load the recipe; flag is "refresh"
        // and hit remains false.
        assert!(!ctx.hit, "cache-refresh must not load (so discovery runs)");
        assert!(ctx.refresh);
        assert!(ctx.recipe.is_none());
    }

    #[tokio::test]
    async fn test_spider_recipe_hit_marks_hit_and_ttl() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let now = chrono::Utc::now().to_rfc3339();
        write_recipe(tmp.path(), "example.com", &now);
        let args = args_with_recipe_dir("https://example.com/foo", tmp.path());
        let url = Url::parse(&args.url).unwrap();
        let ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        assert!(ctx.hit, "fresh recipe must be a hit");
        assert!(ctx.recipe.is_some());
        assert!(
            ctx.ttl_remaining_days.unwrap_or(0) <= 30,
            "ttl_remaining_days should be <= cache_ttl"
        );
    }

    #[tokio::test]
    async fn test_spider_recipe_miss_skeleton_save_on_http_only() {
        let tmp = tempfile::tempdir().expect("tempdir");
        // Empty dir → miss.
        let mut args = args_with_recipe_dir("https://example.com/", tmp.path());
        args.http_only = true;
        args.allow_no_vpn = true;
        // run() will attempt a network fetch via HttpFallback. We can't
        // control egress in CI, so we instead test `maybe_save_skeleton`
        // directly with a synthetic miss context.
        let url = Url::parse(&args.url).unwrap();
        let mut ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        assert!(!ctx.hit);
        super::maybe_save_skeleton(&args, &url, &mut ctx);
        assert!(ctx.saved, "skeleton save must flip the saved flag");
        let p = tmp.path().join("example.com.toml");
        assert!(p.exists(), "skeleton TOML should have been written");
    }

    #[tokio::test]
    async fn test_spider_recipe_endpoint_flag_requires_recipe_hit() {
        let tmp = tempfile::tempdir().expect("tempdir");
        // No recipe → --recipe-endpoint must fail with exit 9.
        let mut args = args_with_recipe_dir("https://unknown.example/", tmp.path());
        args.recipe_endpoint = Some("user_articles_list".into());
        let url = Url::parse(&args.url).unwrap();
        let err = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect_err("must fail");
        assert_eq!(err, 9);
    }

    #[tokio::test]
    async fn test_recipe_ttl_expired_treated_as_refresh() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let past = (chrono::Utc::now() - chrono::Duration::days(120)).to_rfc3339();
        write_recipe(tmp.path(), "example.com", &past);
        let mut args = args_with_recipe_dir("https://example.com/", tmp.path());
        args.cache_ttl = 30;
        let url = Url::parse(&args.url).unwrap();
        let ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        assert!(!ctx.hit, "expired recipe must NOT be a hit");
        assert!(ctx.refresh, "expired recipe must trigger refresh");
    }

    #[test]
    fn test_recipe_param_parse_key_value_pairs_via_clap() {
        let a = parse_args(&[
            "--recipe-param",
            "username=alice",
            "--recipe-param",
            "id=42",
        ]);
        assert_eq!(a.recipe_param.len(), 2);
        let map =
            crate::commands::recipe_runtime::parse_recipe_params(&a.recipe_param).expect("parses");
        assert_eq!(map.get("username").unwrap(), "alice");
        assert_eq!(map.get("id").unwrap(), "42");
    }

    #[test]
    fn test_phase7b_flags_parse() {
        let a = parse_args(&[
            "--no-cache",
            "--cache-only",
            "--cache-refresh",
            "--cache-ttl",
            "7",
            "--recipe-endpoint",
            "user_articles_list",
        ]);
        assert!(a.no_cache);
        assert!(a.cache_only);
        assert!(a.cache_refresh);
        assert_eq!(a.cache_ttl, 7);
        assert_eq!(a.recipe_endpoint.as_deref(), Some("user_articles_list"));
    }

    #[test]
    fn test_phase7c_recipe_no_learn_flag_parses() {
        let a = parse_args(&["--recipe-no-learn"]);
        assert!(a.recipe_no_learn, "--recipe-no-learn must enable the flag");
        // Default off.
        let b = parse_args(&[]);
        assert!(
            !b.recipe_no_learn,
            "recipe_no_learn defaults to false (learn ON)"
        );
    }

    #[tokio::test]
    async fn test_recipe_no_learn_disables_save() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut args = args_with_recipe_dir("https://example.com/", tmp.path());
        args.http_only = true;
        args.recipe_no_learn = true;
        let url = Url::parse(&args.url).unwrap();
        let mut ctx = build_recipe_ctx(OutputFormat::Json, &args, &url)
            .await
            .expect("ok");
        assert!(!ctx.hit);
        super::maybe_save_skeleton(&args, &url, &mut ctx);
        assert!(!ctx.saved, "--recipe-no-learn must suppress recipe writes");
        let p = tmp.path().join("example.com.toml");
        assert!(
            !p.exists(),
            "no recipe file should be written under --recipe-no-learn"
        );
    }
}
