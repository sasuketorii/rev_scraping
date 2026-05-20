// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9g (E2E auth flow + docs)

use chrono::{Duration, Utc};
use secrecy::SecretString;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use tempfile::TempDir;

use stealth_auth::{AuthStore, Cookie, ProfileStatus, SameSite};

fn run_enabled() -> bool {
    std::env::var("REV_SCRAPING_RUN_AUTH_E2E").is_ok()
}

fn rev_stealth_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

fn rev_auth_bin() -> PathBuf {
    option_env!("CARGO_BIN_EXE_rev-auth")
        .map(PathBuf::from)
        .unwrap_or_else(|| sibling_bin("rev-auth"))
}

fn stealth_mcp_bin() -> PathBuf {
    option_env!("CARGO_BIN_EXE_stealth-mcp")
        .map(PathBuf::from)
        .unwrap_or_else(|| sibling_bin("stealth-mcp"))
}

fn sibling_bin(name: &str) -> PathBuf {
    let mut path = rev_stealth_bin();
    path.set_file_name(name);
    path
}

#[test]
#[ignore]
fn e2e_auth_round_trip() {
    if !run_enabled() {
        return;
    }

    let root = TempDir::new().expect("temp auth root");
    let store = helpers::open_test_authstore(root.path());
    let profile = "round_trip";
    let aad_context = "rev_scraping:stealth-auth:v1:test";
    let cookies = vec![
        helpers::cookie("expired", Utc::now() - Duration::days(1)),
        helpers::cookie("session", Utc::now() + Duration::days(7)),
    ];

    store.save(profile, &cookies, aad_context).expect("save");
    let profiles = store.list_profiles().expect("list profiles");
    assert!(profiles.iter().any(|entry| entry.profile == profile));
    assert_eq!(store.status(profile), ProfileStatus::PartiallyExpired);

    let loaded = store.load(profile, aad_context).expect("load");
    let mut names = loaded
        .iter()
        .map(|cookie| cookie.name.as_str())
        .collect::<Vec<_>>();
    names.sort_unstable();
    assert_eq!(names, ["expired", "session"]);

    store.delete(profile).expect("delete");
    assert_eq!(store.status(profile), ProfileStatus::Missing);
}

#[tokio::test]
#[ignore]
async fn e2e_rev_auth_subprocess_completion_marker() {
    if !run_enabled() {
        return;
    }
    if helpers::resolve_obscura().is_none() {
        eprintln!("skipping: obscura not available");
        return;
    }

    let home = TempDir::new().expect("temp home");
    helpers::seed_aup(home.path(), "127\\.0\\.0\\.1", true);
    let auth_dir = home.path().join(".rev_scraping").join("auth");
    let Ok((addr, handle, _cookies)) = helpers::spawn_mock_login_server().await else {
        eprintln!("skipping: cannot bind loopback mock server");
        return;
    };
    let token = uuid::Uuid::new_v4().to_string();
    let marker = std::env::temp_dir().join(format!("rev-auth-{token}.complete"));
    let _ = std::fs::remove_file(&marker);
    assert!(!marker.exists());

    let mut child = Command::new(rev_auth_bin())
        .args([
            "login",
            "--profile",
            "subprocess",
            "--url",
            &format!("http://{addr}/login"),
            "--domain",
            "127.0.0.1",
            "--completion-pattern",
            ".*/dashboard.*",
            "--mcp-session-token",
            &token,
            "--aad-context",
            "rev_scraping:stealth-auth:v1:test",
        ])
        .env("HOME", home.path())
        .env("REV_SCRAPING_AUTH_DIR", &auth_dir)
        .env("REV_SCRAPING_AUTH_PASSPHRASE", "rev-scraping-test")
        .env("REV_SCRAPING_TEST_SKIP_VPN", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn rev-auth");

    std::thread::sleep(std::time::Duration::from_millis(500));
    match child.try_wait().expect("try wait") {
        Some(status) => {
            assert!(
                matches!(status.code(), Some(1 | 3 | 7)),
                "unexpected early exit: {status:?}"
            );
        }
        None => {
            child.kill().expect("terminate rev-auth");
            let status = child.wait().expect("wait rev-auth");
            assert!(!status.success());
        }
    }
    assert!(!marker.exists());
    let _ = helpers::open_test_authstore(&auth_dir).delete("subprocess");
    handle.abort();
}

#[tokio::test]
#[ignore]
async fn e2e_mcp_auth_login_2stage() {
    if !run_enabled() {
        return;
    }

    let home = TempDir::new().expect("temp home");
    let marker_dir = TempDir::new().expect("marker dir");
    helpers::seed_aup(home.path(), "127\\.0\\.0\\.1", true);
    let auth_dir = home
        .path()
        .join(".config")
        .join("rev_scraping")
        .join("auth");
    if AuthStore::open(&auth_dir).is_err() {
        eprintln!("skipping: keyring-backed AuthStore unavailable");
        return;
    }

    let Ok((addr, handle, _cookies)) = helpers::spawn_mock_login_server().await else {
        eprintln!("skipping: cannot bind loopback mock server");
        return;
    };
    let mut child = match Command::new(stealth_mcp_bin())
        .env("HOME", home.path())
        .env("XDG_CONFIG_HOME", home.path().join(".config"))
        .env("TMPDIR", marker_dir.path())
        .env("REV_AUTH_BIN", rev_auth_bin())
        .env("REV_SCRAPING_TEST_SKIP_VPN", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            eprintln!("skipping: stealth-mcp unavailable: {error}");
            handle.abort();
            return;
        }
    };

    let start = json_rpc(
        &mut child,
        1,
        "tools/call",
        json!({
            "name": "auth_login_start",
            "arguments": {
                "profile": "mcp_profile",
                "url": format!("http://{addr}/login"),
                "domain": "127.0.0.1",
                "auth_domain": "127.0.0.1",
                "completion_pattern": ".*/dashboard.*"
            }
        }),
    )
    .expect("auth_login_start response");
    let Some(result) = start.get("result") else {
        eprintln!("skipping: MCP auth_login_start failed");
        helpers::kill_child(&mut child);
        handle.abort();
        return;
    };
    if result.get("isError").and_then(Value::as_bool) == Some(true) {
        eprintln!("skipping: MCP auth_login_start unavailable");
        helpers::kill_child(&mut child);
        handle.abort();
        return;
    }
    let structured = &result["structuredContent"];
    let token = structured["session_token"]
        .as_str()
        .expect("session token")
        .to_string();
    let marker = marker_dir.path().join(format!("rev-auth-{token}.complete"));
    helpers::seed_keyring_profile(&auth_dir, "mcp_profile", "127.0.0.1");
    let marker_clone = marker.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let _ = std::fs::write(marker_clone, br#"{"ok":true}"#);
    });

    let done = json_rpc(
        &mut child,
        2,
        "tools/call",
        json!({
            "name": "auth_login_complete",
            "arguments": { "session_token": token }
        }),
    )
    .expect("auth_login_complete response");
    let structured = &done["result"]["structuredContent"];
    assert_eq!(structured["ok"], true);
    assert_ne!(structured["cookie_values_returned"], true);

    helpers::kill_child(&mut child);
    let _ = AuthStore::open(&auth_dir).and_then(|store| store.delete("mcp_profile"));
    handle.abort();
}

#[tokio::test]
#[ignore]
async fn e2e_spider_with_use_auth_replays_cookies() {
    if !run_enabled() {
        return;
    }

    let home = TempDir::new().expect("temp home");
    helpers::seed_aup(home.path(), "127\\.0\\.0\\.1", true);
    let auth_dir = home.path().join(".rev_scraping").join("auth");
    let store = match AuthStore::open(&auth_dir) {
        Ok(store) => store,
        Err(error) => {
            eprintln!("skipping: keyring-backed AuthStore unavailable: {error}");
            return;
        }
    };
    let profile = "replay_profile";
    let cookie = Cookie {
        name: "session".to_string(),
        value: SecretString::from("REPLAY-PLACEHOLDER-VALUE".to_string()),
        domain: "127.0.0.1".to_string(),
        path: "/".to_string(),
        expires: Some(Utc::now() + Duration::days(7)),
        secure: false,
        http_only: true,
        same_site: SameSite::None,
    };
    store
        .save(profile, &[cookie], "127.0.0.1")
        .expect("seed auth profile");

    let Ok((addr, handle, recorded)) = helpers::spawn_mock_login_server().await else {
        eprintln!("skipping: cannot bind loopback mock server");
        let _ = store.delete(profile);
        return;
    };
    let output = home.path().join("spider.html");
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            &format!("http://{addr}/page"),
            "--use-auth",
            profile,
            "--auth-domain",
            "127.0.0.1",
            "--allow-no-vpn",
            "--http-only",
            "--dump-html",
            output.to_str().expect("utf-8 output path"),
        ])
        .env("HOME", home.path())
        .env("REV_SCRAPING_AUTH_DIR", &auth_dir)
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn spider");
    assert!(
        out.status.success(),
        "stderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let headers = recorded.lock().expect("cookie recorder");
    assert!(headers.iter().any(|header| header.contains("session=")));
    let _ = store.delete(profile);
    handle.abort();
}

#[test]
#[ignore]
fn e2e_aup_blocks_unauthorized_auth_domain() {
    if !run_enabled() {
        return;
    }

    let home = TempDir::new().expect("temp home");
    helpers::seed_aup(home.path(), "example\\.com", false);
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "auth",
            "login",
            "--profile",
            "foo",
            "--url",
            "http://127.0.0.1/login",
            "--domain",
            "127.0.0.1",
            "--rev-auth-bin",
            rev_auth_bin().to_str().expect("utf-8 rev-auth path"),
        ])
        .env("HOME", home.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth auth login");
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr).to_ascii_lowercase();
    let stdout = String::from_utf8_lossy(&out.stdout).to_ascii_lowercase();
    assert!(stderr.contains("aup") || stdout.contains("aup") || stdout.contains("auth_allowed"));
}

#[test]
#[ignore]
fn e2e_authexpired_propagates_exit_4() {
    if !run_enabled() {
        return;
    }

    let home = TempDir::new().expect("temp home");
    helpers::seed_aup(home.path(), "127\\.0\\.0\\.1", true);
    let auth_dir = home.path().join(".rev_scraping").join("auth");
    let store = match AuthStore::open(&auth_dir) {
        Ok(store) => store,
        Err(error) => {
            eprintln!("skipping: keyring-backed AuthStore unavailable: {error}");
            return;
        }
    };
    let profile = "expired_profile";
    let cookie = helpers::cookie("session", Utc::now() - Duration::days(30));
    store
        .save(profile, &[cookie], "")
        .expect("seed expired profile");

    let out = Command::new(rev_stealth_bin())
        .args(["--format", "json", "auth", "status", "--profile", profile])
        .env("HOME", home.path())
        .env("REV_SCRAPING_AUTH_DIR", &auth_dir)
        .output()
        .expect("spawn auth status");
    assert_eq!(
        out.status.code(),
        Some(4),
        "stderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let stdout: Value = serde_json::from_slice(&out.stdout).expect("status json");
    assert_eq!(stdout["result"]["status"], "AllExpired");
    assert_eq!(stdout["result"]["exit_code"], 4);
    let _ = store.delete(profile);
}

fn json_rpc(child: &mut Child, id: i64, method: &str, params: Value) -> std::io::Result<Value> {
    let stdin = child.stdin.as_mut().expect("child stdin");
    let frame = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    });
    writeln!(stdin, "{frame}")?;
    stdin.flush()?;

    let stdout = child.stdout.as_mut().expect("child stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    serde_json::from_str(&line).map_err(std::io::Error::other)
}

mod helpers {
    use super::*;
    use axum::extract::State;
    use axum::http::HeaderMap;
    use axum::response::Html;
    use axum::routing::get;
    use axum::Router;
    use tokio::task::JoinHandle;

    pub type CookieRecorder = Arc<Mutex<Vec<String>>>;

    #[derive(Clone)]
    struct AppState {
        recorder: CookieRecorder,
        dashboard: String,
    }

    pub fn cookie(name: &str, expires: chrono::DateTime<Utc>) -> Cookie {
        Cookie {
            name: name.to_string(),
            value: SecretString::from("sess-token-PLACEHOLDER".to_string()),
            domain: "127.0.0.1".to_string(),
            path: "/".to_string(),
            expires: Some(expires),
            secure: false,
            http_only: true,
            same_site: SameSite::Lax,
        }
    }

    pub fn seed_aup(home: &Path, allowed_domain: &str, auth_allowed: bool) {
        let dir = home.join(".rev_scraping");
        std::fs::create_dir_all(&dir).expect("create .rev_scraping");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
                .expect("chmod .rev_scraping");
        }
        let authorized = dir.join("authorized.toml");
        std::fs::write(
            &authorized,
            format!(
                "[[targets]]\nurl_pattern = \"{}\"\nauth_allowed = {}\n",
                allowed_domain, auth_allowed
            ),
        )
        .expect("write authorized.toml");
        let policy = dir.join("policy.toml");
        std::fs::write(&policy, "require_vpn = false\n").expect("write policy.toml");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&authorized, std::fs::Permissions::from_mode(0o600))
                .expect("chmod authorized.toml");
            std::fs::set_permissions(&policy, std::fs::Permissions::from_mode(0o600))
                .expect("chmod policy.toml");
        }
    }

    pub async fn spawn_mock_login_server(
    ) -> std::io::Result<(SocketAddr, JoinHandle<()>, CookieRecorder)> {
        let recorder = Arc::new(Mutex::new(Vec::new()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let state = AppState {
            recorder: recorder.clone(),
            dashboard: format!("https://127.0.0.1:{}/dashboard", addr.port()),
        };
        let app = Router::new()
            .route("/login", get(login))
            .route("/page", get(page))
            .with_state(state);
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Ok((addr, handle, recorder))
    }

    async fn login(State(state): State<AppState>, headers: HeaderMap) -> Html<String> {
        record_cookie(&state.recorder, &headers);
        Html(format!(
            "<!doctype html><html><body><a href=\"{}\">dashboard</a></body></html>",
            state.dashboard
        ))
    }

    async fn page(State(state): State<AppState>, headers: HeaderMap) -> Html<&'static str> {
        record_cookie(&state.recorder, &headers);
        Html("<!doctype html><html><body>ok</body></html>")
    }

    fn record_cookie(recorder: &CookieRecorder, headers: &HeaderMap) {
        if let Some(value) = headers.get(axum::http::header::COOKIE) {
            if let Ok(value) = value.to_str() {
                recorder
                    .lock()
                    .expect("cookie recorder")
                    .push(value.to_string());
            }
        }
    }

    pub fn open_test_authstore(dir: &Path) -> AuthStore {
        AuthStore::open_with_passphrase(dir, SecretString::from("rev-scraping-test".to_string()))
            .expect("open test auth store")
    }

    pub fn seed_keyring_profile(dir: &Path, profile: &str, domain: &str) {
        let store = AuthStore::open(dir).expect("open keyring-backed store");
        let mut cookie = cookie("session", Utc::now() + Duration::days(7));
        cookie.domain = domain.to_string();
        store.save(profile, &[cookie], "").expect("save profile");
    }

    pub fn resolve_obscura() -> Option<PathBuf> {
        if let Ok(path) = std::env::var("REV_OBSCURA_BIN") {
            let path = PathBuf::from(path);
            if path.exists() {
                return Some(path);
            }
        }
        let path = std::env::var_os("PATH")?;
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("obscura");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        None
    }

    pub fn kill_child(child: &mut Child) {
        let _ = child.kill();
        let _ = child.wait();
    }
}
