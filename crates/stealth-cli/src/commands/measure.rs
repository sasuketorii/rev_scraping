// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.1.0 (P15 SHOULD: measure subcommand)
//! `rev-stealth measure` — local fingerprint diagnostics for monitoring.
//!
//! The subcommand collects observability-grade fingerprint data without
//! touching any third-party SaaS by default. It reports:
//!
//!   * the user-agent / Sec-CH-UA validity (parsed locally)
//!   * a synthetic TLS JA4 placeholder (best-effort; we don't open a real
//!     TLS handshake unless `--enable-external` is set)
//!   * a synthetic Bot Score derived from header consistency
//!
//! Passing `--enable-external` *opts in* to hitting external services such
//! as `https://bot.sannysoft.com` or CreepJS. This must be explicit — the
//! default is **DISABLED** so this command is safe to run in CI.
//!
//! All output is structured JSON (when `--format json` is set globally)
//! and is intentionally side-effect-free on disk.

use clap::Args;
use serde_json::json;

use crate::OutputFormat;

/// Args for `rev-stealth measure`.
#[derive(Args, Debug, Clone)]
pub struct MeasureArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/measure.output.json`.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    /// URL to measure against. The page is not actually fetched unless
    /// `--enable-external` is set; we only validate the URL shape here.
    #[arg(long)]
    pub url: String,

    /// Opt-in to external fingerprint SaaS calls (CreepJS,
    /// bot.sannysoft.com, etc.). Default: disabled.
    #[arg(long, default_value_t = false)]
    pub enable_external: bool,

    /// P10.5: Opt-in to a VPS egress probe (HEAD request against a
    /// minimal endpoint) to measure exit IP / TLS / DNS leak after
    /// deploy. Even with this flag set, the probe is only active when
    /// the binary was built with the `vps-egress-probe` Cargo feature;
    /// otherwise a deterministic `disabled` stub is returned. Default:
    /// disabled.
    #[arg(long, default_value_t = false)]
    pub enable_egress_probe: bool,

    /// Optional override for the User-Agent we attribute the measurement
    /// to. When omitted we use a neutral rev-stealth placeholder.
    #[arg(long)]
    pub user_agent: Option<String>,
}

pub async fn run(format: OutputFormat, args: MeasureArgs) -> i32 {
    // Validate URL locally — never silently coerce.
    let parsed = match url::Url::parse(&args.url) {
        Ok(u) => u,
        Err(e) => {
            emit_err(
                format,
                "measure",
                3,
                &format!("invalid --url {:?}: {e}", args.url),
            );
            return 3;
        }
    };

    let ua = args.user_agent.clone().unwrap_or_else(default_user_agent);
    let measurement = build_local_measurement(&parsed, &ua);
    // P10.5: egress probe is double-opt-in (cli flag + cargo feature).
    let egress = super::egress::run_probe(args.enable_egress_probe).await;

    if args.enable_external {
        // External SaaS calls are explicitly opted into. We never enable
        // them by default to avoid accidental data exfiltration.
        let external = json!({
            "enabled": true,
            "providers": ["creepjs", "bot.sannysoft.com"],
            "note": "external probes are stubbed in v1.1.0 — extend in M5",
        });
        emit_ok(
            format,
            "measure",
            json!({
                "url": parsed.as_str(),
                "user_agent": ua,
                "local": measurement,
                "external": external,
                "egress": egress,
            }),
        );
    } else {
        emit_ok(
            format,
            "measure",
            json!({
                "url": parsed.as_str(),
                "user_agent": ua,
                "local": measurement,
                "external": { "enabled": false },
                "egress": egress,
            }),
        );
    }
    0
}

fn default_user_agent() -> String {
    "rev-stealth/1.1.0 (+measurement)".to_string()
}

/// Local-only, deterministic fingerprint heuristics. Does not perform any
/// network I/O. Returns a JSON object that the caller embeds under
/// `local`.
pub(crate) fn build_local_measurement(url: &url::Url, ua: &str) -> serde_json::Value {
    let scheme = url.scheme();
    let host = url.host_str().unwrap_or("");
    let sec_ch_ua_valid = validate_sec_ch_ua(ua);
    // Trivial deterministic "bot score": higher when the UA looks like an
    // automation placeholder or the URL targets plain http.
    let mut bot_score: u8 = 0;
    if ua.to_ascii_lowercase().contains("headless") || ua.to_ascii_lowercase().contains("bot") {
        bot_score = bot_score.saturating_add(60);
    }
    if scheme != "https" {
        bot_score = bot_score.saturating_add(20);
    }
    if !sec_ch_ua_valid {
        bot_score = bot_score.saturating_add(20);
    }
    json!({
        "scheme": scheme,
        "host": host,
        "sec_ch_ua_valid": sec_ch_ua_valid,
        "ja4_placeholder": synthetic_ja4(ua),
        "bot_score": bot_score,
    })
}

fn validate_sec_ch_ua(ua: &str) -> bool {
    // Very small heuristic: a "valid" UA contains a slash-version and at
    // least one parenthesised platform descriptor. Used as a smoke
    // signal, not a full parser.
    ua.contains('/') && ua.contains('(')
}

fn synthetic_ja4(ua: &str) -> String {
    // Deterministic 8-char checksum-style stub so callers can diff across
    // runs without us shipping an actual JA4 implementation. Real JA4
    // requires a live TLS handshake (deferred to --enable-external).
    let mut h: u32 = 5381;
    for b in ua.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    format!("ja4-stub-{h:08x}")
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
    // v1.3 Lane G.7: canonical error envelope (see commands/error_envelope.rs).
    let kind = crate::commands::error_envelope::classify_legacy_message(msg);
    let _ = crate::commands::error_envelope::emit_err_envelope(
        format, op, exit, kind, msg, None, None,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_local_measurement_flags_headless_ua() {
        let url = url::Url::parse("https://example.com/").unwrap();
        let m = build_local_measurement(&url, "HeadlessChrome/120.0");
        assert!(m["bot_score"].as_u64().unwrap() >= 60);
    }

    #[test]
    fn build_local_measurement_low_score_for_clean_ua() {
        let url = url::Url::parse("https://example.com/").unwrap();
        let m = build_local_measurement(
            &url,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        );
        assert_eq!(m["bot_score"].as_u64().unwrap(), 0);
        assert!(m["sec_ch_ua_valid"].as_bool().unwrap());
    }

    #[test]
    fn build_local_measurement_penalises_plain_http() {
        let url = url::Url::parse("http://example.com/").unwrap();
        let m = build_local_measurement(&url, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
        // http (+20) plus a slightly weak UA stays under headless threshold.
        let score = m["bot_score"].as_u64().unwrap();
        assert!((20..60).contains(&score), "got score {score}");
        assert_eq!(m["scheme"], "http");
    }

    #[test]
    fn synthetic_ja4_is_deterministic_and_shaped() {
        let a = synthetic_ja4("UA-test");
        let b = synthetic_ja4("UA-test");
        assert_eq!(a, b, "must be deterministic");
        assert!(a.starts_with("ja4-stub-"));
        assert_eq!(a.len(), "ja4-stub-".len() + 8);
    }

    #[test]
    fn validate_sec_ch_ua_basic() {
        assert!(validate_sec_ch_ua(
            "Mozilla/5.0 (Macintosh; Intel) Safari/605"
        ));
        assert!(!validate_sec_ch_ua("plaintext-ua"));
    }

    #[test]
    fn measure_args_parse_default_disables_external() {
        use clap::Parser;
        #[derive(clap::Parser)]
        struct W {
            #[command(flatten)]
            m: MeasureArgs,
        }
        let parsed = W::try_parse_from(["measure", "--url", "https://example.com"]).unwrap();
        assert_eq!(parsed.m.url, "https://example.com");
        assert!(
            !parsed.m.enable_external,
            "external SaaS must be DISABLED by default"
        );
    }

    #[test]
    fn measure_args_parse_opt_in_external() {
        use clap::Parser;
        #[derive(clap::Parser)]
        struct W {
            #[command(flatten)]
            m: MeasureArgs,
        }
        let parsed =
            W::try_parse_from(["measure", "--url", "https://x.test", "--enable-external"]).unwrap();
        assert!(parsed.m.enable_external);
    }
}
