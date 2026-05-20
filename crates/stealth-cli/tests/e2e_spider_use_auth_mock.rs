// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.1.0 P4 (B3 mock E2E for `spider --use-auth`)
//
//! Deterministic mock E2E for `rev-stealth spider --use-auth`.
//!
//! NOTE on TLS: the original P4 design called for an `axum + rcgen` self-signed
//! HTTPS server. In practice the `rev-stealth` subprocess uses `reqwest` with
//! the workspace-default `rustls` + bundled root store, which has no portable
//! mechanism to trust a per-test self-signed cert without invasive prod code
//! changes (a `--insecure-tls` knob would be a permanent foot-gun). For
//! deterministic CI we therefore drive an `axum` HTTP fixture on `127.0.0.1`
//! and seed the `AuthStore` with `secure=false` cookies — the Secure-flag
//! enforcement itself is covered by jar.rs unit tests
//! (`auth_jar_respects_secure_flag`).
//!
//! The test exercises the full subprocess path: spider opens the AuthStore via
//! `REV_SCRAPING_AUTH_PASSPHRASE` (no keyring required, deterministic in CI),
//! loads the seeded profile, configures reqwest with the replay jar + UA, and
//! the mock server asserts the inbound `Cookie` header carries the seeded
//! session value.
//!
//! Gated by `REV_SCRAPING_RUN_USE_AUTH_E2E=1`; the test is `#[ignore]` so it
//! is skipped during normal `cargo test` runs.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use chrono::{Duration, Utc};
use secrecy::SecretString;
use stealth_auth::{AuthStore, Cookie, SameSite};
use tempfile::TempDir;
use tokio::task::JoinHandle;

const PASSPHRASE: &str = "rev-scraping-use-auth-mock";
const PROFILE: &str = "fake_profile";
const COOKIE_NAME: &str = "session";
const COOKIE_VALUE: &str = "fake_xxx_session_value_zzz";
const SECRET_BODY: &str =
    "<!doctype html><html><body id=\"members\">MEMBER_AREA_SECRET</body></html>";

fn run_enabled() -> bool {
    std::env::var("REV_SCRAPING_RUN_USE_AUTH_E2E").is_ok()
}

fn rev_stealth_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[derive(Clone)]
struct MockState {
    inbound: Arc<Mutex<Vec<String>>>,
}

async fn members_protected(
    State(state): State<MockState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    // Record raw Cookie header (so tests can assert without leaking secrets in
    // assertion messages; we never log the value).
    let cookie_present = headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .map(|s| {
            state.inbound.lock().expect("rec").push(s.to_string());
            s.contains(&format!("{COOKIE_NAME}={COOKIE_VALUE}"))
        })
        .unwrap_or(false);
    if cookie_present {
        (StatusCode::OK, SECRET_BODY).into_response()
    } else {
        (
            StatusCode::UNAUTHORIZED,
            "<!doctype html><html><body>401</body></html>",
        )
            .into_response()
    }
}

async fn spawn_http_mock() -> std::io::Result<(SocketAddr, JoinHandle<()>, Arc<Mutex<Vec<String>>>)>
{
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let inbound = Arc::new(Mutex::new(Vec::new()));
    let state = MockState {
        inbound: inbound.clone(),
    };
    let app = Router::new()
        .route("/members/protected", get(members_protected))
        .with_state(state);
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Ok((addr, handle, inbound))
}

fn seed_aup(home: &Path) {
    let dir = home.join(".rev_scraping");
    std::fs::create_dir_all(&dir).expect("create .rev_scraping");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let authorized = dir.join("authorized.toml");
    std::fs::write(
        &authorized,
        "[[targets]]\nurl_pattern = \"127\\\\.0\\\\.0\\\\.1\"\nauth_allowed = true\n",
    )
    .expect("write authorized.toml");
    std::fs::write(dir.join("policy.toml"), "require_vpn = false\n").expect("write policy.toml");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&authorized, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::set_permissions(
            dir.join("policy.toml"),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
    }
}

fn seeded_cookie() -> Cookie {
    Cookie {
        name: COOKIE_NAME.to_string(),
        value: SecretString::from(COOKIE_VALUE.to_string()),
        domain: "127.0.0.1".to_string(),
        path: "/".to_string(),
        expires: Some(Utc::now() + Duration::days(1)),
        secure: false, // HTTP fixture; cookie-jar Secure enforcement covered by unit tests.
        http_only: true,
        same_site: SameSite::None,
    }
}

/// Deterministic mock E2E. Drives the rev-stealth subprocess against a local
/// axum HTTP fixture with a passphrase-backed AuthStore (no keyring needed).
///
/// Requires a multi-thread runtime: the test thread blocks on
/// `Command::output()` while the axum server task must continue to accept
/// connections from the subprocess.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn e2e_spider_use_auth_mock_replays_cookie_and_dumps_member_html() {
    if !run_enabled() {
        eprintln!("skipping: REV_SCRAPING_RUN_USE_AUTH_E2E not set");
        return;
    }

    let home = TempDir::new().expect("temp home");
    seed_aup(home.path());
    let auth_dir = home.path().join(".rev_scraping").join("auth");
    std::fs::create_dir_all(&auth_dir).expect("auth dir");

    // Open via passphrase so the test does not depend on an OS keyring.
    let store =
        AuthStore::open_with_passphrase(&auth_dir, SecretString::from(PASSPHRASE.to_string()))
            .expect("open passphrase auth store");
    store
        .save(PROFILE, &[seeded_cookie()], "127.0.0.1")
        .expect("seed profile");

    let (addr, handle, inbound) = match spawn_http_mock().await {
        Ok(v) => v,
        Err(error) => {
            eprintln!("skipping: cannot bind loopback mock server: {error}");
            return;
        }
    };

    let dump_path = home.path().join("members.html");
    let url = format!("http://{addr}/members/protected");
    let output = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            &url,
            "--use-auth",
            PROFILE,
            "--auth-domain",
            "127.0.0.1",
            "--allow-no-vpn",
            "--http-only",
            "--no-cache",
            "--dump-html",
            dump_path.to_str().expect("utf-8 dump path"),
        ])
        .env("HOME", home.path())
        .env("REV_SCRAPING_AUTH_DIR", &auth_dir)
        .env("REV_SCRAPING_AUTH_PASSPHRASE", PASSPHRASE)
        // Allow the bridge SSRF guard to accept loopback for the mock server.
        // This env-var is honoured by `obscura-bridge::ssrf` only and is meant
        // for deterministic test/CI runs against local fixtures.
        .env("REV_SCRAPING_ALLOW_LOOPBACK", "1")
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth spider");

    handle.abort();

    // We intentionally avoid printing stdout/stderr verbatim in the success
    // path to prevent any accidental secret leak. On failure we surface the
    // structured error JSON (which has no secrets, only the operator-facing
    // error message) plus exit code so debugging is possible.
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        panic!(
            "spider exit={:?}\nstdout={}\nstderr={}",
            output.status.code(),
            stdout,
            stderr
        );
    }

    // 1) Server saw exactly the seeded session cookie => use-auth replay
    //    plumbed through reqwest end-to-end.
    let recorded = inbound.lock().expect("rec");
    let saw_cookie = recorded
        .iter()
        .any(|h| h.contains(&format!("{COOKIE_NAME}={COOKIE_VALUE}")));
    assert!(saw_cookie, "mock did not observe replayed session cookie");

    // 2) Dumped HTML contains the protected-area marker (server returned 200
    //    only because the cookie matched).
    let dumped = std::fs::read_to_string(&dump_path).expect("read dump");
    assert!(
        dumped.contains("MEMBER_AREA_SECRET"),
        "dump missing member marker (len={})",
        dumped.len()
    );

    // Cleanup.
    let _ = store.delete(PROFILE);
}

/// Live manifest stub: env-driven, manual-dispatch only. Reads a single target
/// URL + profile name from the environment and verifies that an authorised
/// fetch yields HTTP 200 with the configured selector marker. CI does not set
/// `REV_SCRAPING_E2E_TARGET_URL`, so this is always skipped outside the
/// `e2e-manual.yml` workflow. The matrix dimension (cf-site / spa-site /
/// ssr-site) is realised at the workflow level — this test treats them
/// uniformly.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn e2e_spider_use_auth_live_env_driven() {
    let Ok(url) = std::env::var("REV_SCRAPING_E2E_TARGET_URL") else {
        eprintln!("skipping: REV_SCRAPING_E2E_TARGET_URL not set");
        return;
    };
    let Ok(profile) = std::env::var("REV_SCRAPING_E2E_AUTH_PROFILE") else {
        eprintln!("skipping: REV_SCRAPING_E2E_AUTH_PROFILE not set");
        return;
    };
    let assert_marker = std::env::var("REV_SCRAPING_E2E_ASSERT_MARKER").ok();

    let home = TempDir::new().expect("temp home");
    // For live targets we still seed AUP from env so the test can be granted
    // authorisation explicitly by the operator (URL pattern provided as a
    // regex). Without this, AUP would correctly block the request.
    let allow_pattern =
        std::env::var("REV_SCRAPING_E2E_AUP_PATTERN").unwrap_or_else(|_| "https?://".to_string());
    let dir = home.path().join(".rev_scraping");
    std::fs::create_dir_all(&dir).expect("create cfg dir");
    std::fs::write(
        dir.join("authorized.toml"),
        format!(
            "[[targets]]\nurl_pattern = \"{}\"\nauth_allowed = true\n",
            allow_pattern.replace('\\', "\\\\").replace('"', "\\\"")
        ),
    )
    .expect("write authorized.toml");
    std::fs::write(dir.join("policy.toml"), "require_vpn = false\n").expect("write policy.toml");

    let dump_path = home.path().join("live.html");
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            &url,
            "--use-auth",
            &profile,
            "--allow-no-vpn",
            "--http-only",
            "--no-cache",
            "--dump-html",
            dump_path.to_str().expect("utf-8"),
        ])
        .env("HOME", home.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth (live)");

    assert!(
        out.status.success(),
        "live spider exit={:?}; stderr.len={}",
        out.status.code(),
        out.stderr.len()
    );

    if let Some(marker) = assert_marker {
        let dumped = std::fs::read_to_string(&dump_path).expect("read dump");
        assert!(
            dumped.contains(&marker),
            "live dump missing marker ({} bytes)",
            dumped.len()
        );
    }
}
