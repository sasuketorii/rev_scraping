// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! `rev-stealth browser ...` subcommand handlers.

use std::time::Duration;

use clap::Subcommand;
use serde_json::json;
use stealth_core::{
    browser::{launch_stealth, StealthBrowser},
    BrowserProfile, ExitCode, StealthLevel, StealthProfile,
};
use tokio::time::sleep;
use tracing::{info, warn};

use crate::OutputFormat;

#[derive(Subcommand, Debug)]
pub(crate) enum BrowserAction {
    /// Launch a stealth browser, navigate to a URL, and emit JSON about
    /// the resulting page (UA / viewport / title / final URL). Useful as
    /// a smoke test that the launcher works on this host.
    #[command(
        long_about = "Launch a chromiumoxide-driven stealth browser with the \
chosen profile and stealth level, navigate to --url, and dump page metadata \
(UA / viewport / title / final URL). Use for launcher smoke tests on a new host.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth browser launch\n  \
$ rev-stealth browser launch --profile desktop --url https://example.com --dwell 3\n  \
$ rev-stealth browser launch --headed --stealth full --chrome /usr/bin/google-chrome\n\n\
EXIT CODES:\n  \
0  Ok               Launch + navigation succeeded.\n  \
1  UserError        Unknown --profile / --stealth slug.\n  \
2  TransientError   Chrome launch/CDP transient failure.\n  \
3  PermanentError   Chrome binary missing or stealth level unsupported.\n\n\
ENV:\n  \
REV_STEALTH_CHROME  Override the chrome executable path (else auto-detect)."
    )]
    Launch {
        /// Profile slug. One of:
        /// `desktop`, `mobile-ios`, `mobile-android`, `ipad`, `galaxy-ultra`.
        #[arg(long, default_value = "mobile-ios")]
        profile: String,
        /// Stealth level: `off`, `basic`, `full`.
        #[arg(long, default_value = "full")]
        stealth: String,
        /// Navigate to this URL after launch. Default: `about:blank`.
        #[arg(long, default_value = "about:blank")]
        url: String,
        /// Run with a visible chrome window instead of new-headless mode.
        #[arg(long)]
        headed: bool,
        /// Override the chrome executable path. By default, chromiumoxide
        /// auto-detects the system chrome.
        #[arg(long, env = "REV_STEALTH_CHROME")]
        chrome: Option<std::path::PathBuf>,
        /// Hold the page for this many seconds after navigation (lets a
        /// detector finish its work). Default 0 = exit as soon as
        /// `document.readyState` settles.
        #[arg(long, default_value_t = 0)]
        dwell: u64,
    },
    /// Run a stealth self-test: launch a stealth browser, navigate to
    /// the target detection page (defaults to bot.sannysoft.com), wait
    /// briefly, then dump UA / viewport / title.
    #[command(
        long_about = "Run a stealth self-test against a detection page \
(default: bot.sannysoft.com). Launches the browser with the chosen profile + \
stealth level, dwells N seconds, then dumps UA / viewport / title for offline \
inspection. AUTHORIZED TARGETS ONLY.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth browser stealth-test\n  \
$ rev-stealth browser stealth-test --profile desktop --dwell 8\n  \
$ rev-stealth browser stealth-test --target https://bot.sannysoft.com/ --headed\n\n\
EXIT CODES:\n  \
0  Ok               Stealth probe completed.\n  \
1  UserError        Unknown --profile / --stealth slug.\n  \
2  TransientError   Chrome launch/CDP transient failure.\n  \
3  PermanentError   Chrome binary missing or unsupported stealth level.\n\n\
ENV:\n  \
REV_STEALTH_CHROME  Override the chrome executable path (else auto-detect)."
    )]
    StealthTest {
        /// Detection page to probe.
        #[arg(long, default_value = "https://bot.sannysoft.com/")]
        target: String,
        #[arg(long, default_value = "mobile-ios")]
        profile: String,
        #[arg(long, default_value = "full")]
        stealth: String,
        #[arg(long, default_value_t = 5)]
        dwell: u64,
        #[arg(long)]
        headed: bool,
        #[arg(long, env = "REV_STEALTH_CHROME")]
        chrome: Option<std::path::PathBuf>,
    },
}

pub(crate) async fn run(format: OutputFormat, action: BrowserAction) -> ExitCode {
    match action {
        BrowserAction::Launch {
            profile,
            stealth,
            url,
            headed,
            chrome,
            dwell,
        } => launch(format, &profile, &stealth, &url, headed, chrome, dwell).await,
        BrowserAction::StealthTest {
            target,
            profile,
            stealth,
            dwell,
            headed,
            chrome,
        } => launch(format, &profile, &stealth, &target, headed, chrome, dwell).await,
    }
}

async fn launch(
    format: OutputFormat,
    profile_slug: &str,
    stealth_slug: &str,
    url: &str,
    headed: bool,
    chrome: Option<std::path::PathBuf>,
    dwell_secs: u64,
) -> ExitCode {
    let profile = match BrowserProfile::from_slug(profile_slug) {
        Some(p) => p,
        None => {
            return emit_error(
                format,
                ExitCode::UserError,
                "browser.launch",
                &format!(
                    "unknown profile {profile_slug:?}; valid: desktop, mobile-ios, mobile-android, ipad, galaxy-ultra"
                ),
            );
        }
    };
    let level = match StealthLevel::from_slug(stealth_slug) {
        Some(s) => s,
        None => {
            return emit_error(
                format,
                ExitCode::UserError,
                "browser.launch",
                &format!("unknown stealth level {stealth_slug:?}; valid: off, basic, full"),
            );
        }
    };

    let stealth_profile = StealthProfile {
        id: format!("{profile_slug}-{stealth_slug}"),
        browser_profile: profile,
        stealth_level: level,
        headless: !headed,
        chrome_executable: chrome,
    };

    info!(profile = ?profile, level = ?level, %url, "browser.launch starting");

    let browser = match launch_stealth(stealth_profile.clone()).await {
        Ok(b) => b,
        Err(e) => {
            let exit = e.exit_code();
            return emit_error(format, exit, "browser.launch", &format!("{e}"));
        }
    };

    let result = navigate_and_inspect(&browser, url, dwell_secs).await;

    if let Err(e) = browser.shutdown().await {
        warn!(?e, "browser shutdown emitted an error");
    }

    match result {
        Ok(report) => {
            emit_ok(format, "browser.launch", report);
            ExitCode::Ok
        }
        Err(e) => emit_error(format, e.exit_code(), "browser.launch", &format!("{e}")),
    }
}

async fn navigate_and_inspect(
    browser: &StealthBrowser,
    url: &str,
    dwell_secs: u64,
) -> stealth_core::Result<serde_json::Value> {
    let page = browser.new_page().await?;

    page.goto(url)
        .await
        .map_err(|e| stealth_core::StealthError::Transient(format!("goto {url}: {e}")))?;
    page.wait_for_navigation()
        .await
        .map_err(|e| stealth_core::StealthError::Transient(format!("wait_for_navigation: {e}")))?;

    if dwell_secs > 0 {
        sleep(Duration::from_secs(dwell_secs)).await;
    }

    let final_url = page
        .url()
        .await
        .map_err(|e| stealth_core::StealthError::Transient(format!("page.url: {e}")))?
        .unwrap_or_else(|| url.to_string());

    let title = page
        .get_title()
        .await
        .map_err(|e| stealth_core::StealthError::Transient(format!("page.get_title: {e}")))?
        .unwrap_or_default();

    let ua = page
        .user_agent()
        .await
        .map_err(|e| stealth_core::StealthError::Transient(format!("page.user_agent: {e}")))?;

    let fp = browser.fingerprint();
    Ok(json!({
        "profile_id": browser.profile().id,
        "browser_profile": browser.profile().browser_profile.as_slug(),
        "stealth_level": format!("{:?}", browser.profile().stealth_level).to_lowercase(),
        "url_requested": url,
        "url_final": final_url,
        "title": title,
        "user_agent": ua,
        "fingerprint": fp.map(|f| json!({
            "preset_id": f.user_agent,
            "viewport": [f.viewport.width, f.viewport.height],
            "device_scale_factor": f.device_scale_factor,
            "device_memory": f.device_memory,
            "hardware_concurrency": f.hardware_concurrency,
            "max_touch_points": f.max_touch_points,
            "webgl_vendor": &f.webgl_vendor,
            "webgl_renderer": &f.webgl_renderer,
        })),
    }))
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

fn emit_error(format: OutputFormat, exit: ExitCode, op: &str, message: &str) -> ExitCode {
    // v1.3 Lane G.7: canonical error envelope (see commands/error_envelope.rs).
    let kind = crate::commands::error_envelope::classify_legacy_message(message);
    let _ = crate::commands::error_envelope::emit_err_envelope(
        format,
        op,
        exit.as_i32(),
        kind,
        message,
        None,
        None,
    );
    exit
}
