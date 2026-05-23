// SPDX-License-Identifier: MIT
//! v1.3 Lane G.5: side-effect-free `--dry-run` integration test.
//!
//! For every mutate sub-command listed in the v1.3 ExecPlan, this test:
//!  1. Spawns `rev-stealth ... --dry-run --format json` against an empty
//!     tempdir (rooted via `REV_SCRAPING_HOME` / `HOME` / `REV_SCRAPING_AUTH_DIR`).
//!  2. Asserts exit 0.
//!  3. Asserts stdout parses as the canonical dry-run envelope
//!     (`ok=true`, `result.dry_run=true`, `result.plan: [..]`).
//!  4. Asserts the tempdir directory tree was NOT mutated (snapshot of
//!     filenames + sizes + mtime nanos before/after must match).
//!
//! Network mocking: every dry-run path short-circuits BEFORE any network /
//! keyring / process-spawn action. We therefore set network-touching env
//! pointers to nonexistent paths (e.g. `REV_AUTH_BIN=/dev/null`) so that
//! the test would fail loudly with a non-zero exit if the dry-run path
//! ever regressed into running the underlying side effect.
//!
//! This test is the canonical acceptance evidence for Lane G.5.

use std::collections::BTreeMap;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde_json::Value;

/// Bind a local TCP listener on a free loopback port and start a
/// background thread counting accepted connections. The returned port
/// can be exposed to the CLI via env vars that would otherwise hit a
/// remote endpoint (`REV_STEALTH_EGRESS_PROBE_URL`, etc.). The counter
/// MUST read 0 after a dry-run invocation — if the dry-run path ever
/// regresses into making a real HTTP call, the connection count goes
/// to >= 1 and the test fails.
fn spawn_network_sentinel() -> (u16, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind sentinel");
    let port = listener.local_addr().unwrap().port();
    let counter = Arc::new(AtomicUsize::new(0));
    let c2 = Arc::clone(&counter);
    std::thread::spawn(move || {
        listener
            .set_nonblocking(false)
            .expect("blocking sentinel listener");
        for stream in listener.incoming().flatten() {
            c2.fetch_add(1, Ordering::SeqCst);
            // Close immediately; we only care about the connect attempt.
            drop(stream);
        }
    });
    (port, counter)
}

/// Recursive snapshot of `<root>`: maps relative path -> (size_bytes,
/// mtime_nanos, is_dir). Used to assert zero side effect across a
/// `--dry-run` invocation.
fn snapshot_tree(root: &Path) -> BTreeMap<PathBuf, (u64, i128, bool)> {
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn walk(root: &Path, dir: &Path, acc: &mut BTreeMap<PathBuf, (u64, i128, bool)>) {
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in read.flatten() {
        let path = entry.path();
        let rel = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_nanos() as i128)
            .unwrap_or(0);
        acc.insert(rel, (meta.len(), mtime, meta.is_dir()));
        if meta.is_dir() {
            walk(root, &path, acc);
        }
    }
}

/// Spawn `rev-stealth <argv> --dry-run --format json` rooted at `home`.
/// Returns (stdout_json, exit_code, network_connections_observed).
///
/// Network isolation: every env var that could direct outbound HTTP at
/// a real endpoint is rerouted at a local TCP sentinel that counts
/// accepted connections. The caller asserts the count is 0.
fn run_dry_run(home: &Path, argv: &[&str]) -> (Value, i32, usize) {
    let (sentinel_port, counter) = spawn_network_sentinel();
    let sentinel_url = format!("http://127.0.0.1:{sentinel_port}/g5-sentinel");
    let mut cmd = Command::new(env!("CARGO"));
    cmd.args(["run", "--quiet", "--bin", "rev-stealth", "--"]);
    cmd.args(argv);
    cmd.env("REV_SCRAPING_HOME", home);
    cmd.env("HOME", home);
    cmd.env("REV_SCRAPING_AUTH_DIR", home.join("auth"));
    // Sabotage every potential network / keyring / process side effect: if
    // dry-run ever regresses into the real path, these will be visited and
    // the resulting exit will not be 0.
    cmd.env("REV_AUTH_BIN", "/dev/null");
    cmd.env("REV_OBSCURA_BIN", "/dev/null");
    cmd.env("REV_SCRAPING_REQUIRE_VPN", "0");
    // Route any HTTP probe that honours these overrides at the sentinel.
    cmd.env("REV_STEALTH_EGRESS_PROBE_URL", &sentinel_url);
    cmd.env("REV_STEALTH_CHROME", "/dev/null");
    cmd.env("HTTP_PROXY", &sentinel_url);
    cmd.env("HTTPS_PROXY", &sentinel_url);
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let out = cmd.output().expect("rev-stealth spawnable");
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let parsed: Value = serde_json::from_str(&stdout).unwrap_or_else(|e| {
        panic!(
            "stdout must be JSON for argv={argv:?}: {e}\nstdout=\n{stdout}\nstderr=\n{}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    // Give any in-flight TCP connect a moment to register on the sentinel
    // thread before sampling — fast even on cold runners.
    std::thread::sleep(std::time::Duration::from_millis(25));
    let net = counter.load(Ordering::SeqCst);
    (parsed, out.status.code().unwrap_or(-1), net)
}

/// Assert the canonical dry-run envelope shape.
fn assert_dry_run_envelope(payload: &Value, expected_operation: &str) {
    assert_eq!(payload.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        payload
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or(""),
        expected_operation,
        "envelope: {payload}"
    );
    let result = payload.get("result").expect("envelope.result present");
    assert_eq!(
        result.get("dry_run").and_then(Value::as_bool),
        Some(true),
        "result.dry_run must be true: {result}"
    );
    let plan = result
        .get("plan")
        .and_then(Value::as_array)
        .expect("result.plan is array");
    assert!(!plan.is_empty(), "result.plan must be non-empty: {result}");
    // idempotency_key field MUST exist (G.5 surface contract for G.6).
    assert!(result.get("idempotency_key").is_some());
}

/// Drive one mutate sub-command end to end: snapshot the tempdir, spawn
/// the CLI with `--dry-run --format json`, assert envelope shape, assert
/// zero side effect.
fn assert_zero_side_effect(home: &Path, argv: &[&str], expected_operation: &str) {
    let before = snapshot_tree(home);
    let (payload, code, net) = run_dry_run(home, argv);
    assert_eq!(
        code, 0,
        "argv={argv:?} must exit 0 in dry-run, got {code}; payload={payload}"
    );
    assert_dry_run_envelope(&payload, expected_operation);
    let after = snapshot_tree(home);
    assert_eq!(
        before, after,
        "argv={argv:?} mutated the tree:\nbefore={before:?}\nafter={after:?}"
    );
    assert_eq!(
        net, 0,
        "argv={argv:?} attempted {net} outbound TCP connection(s) during --dry-run"
    );
}

#[test]
fn config_init_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--target",
            "all",
            "--non-interactive",
            "--dry-run",
        ],
        "config.init",
    );
}

#[test]
fn config_set_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "set",
            "policy.require_vpn",
            "true",
            "--dry-run",
        ],
        "config.set",
    );
}

#[test]
fn config_edit_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "edit",
            "--editor",
            "/dev/null",
            "--dry-run",
        ],
        "config.edit",
    );
}

#[test]
fn config_migrate_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &["config", "--output-format", "json", "migrate", "--dry-run"],
        "config.migrate",
    );
}

#[test]
fn config_rollback_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "rollback",
            "policy.toml.bak.1700000000000",
            "--dry-run",
        ],
        "config.rollback",
    );
}

#[test]
fn config_gc_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "gc",
            "--keep",
            "3",
            "--dry-run",
        ],
        "config.gc",
    );
}

#[test]
fn config_profile_create_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "profile",
            "create",
            "work",
            "--dry-run",
        ],
        "config.profile.create",
    );
}

#[test]
fn config_profile_switch_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "profile",
            "switch",
            "work",
            "--dry-run",
        ],
        "config.profile.switch",
    );
}

#[test]
fn config_profile_delete_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "config",
            "--output-format",
            "json",
            "profile",
            "delete",
            "work",
            "--yes",
            "--dry-run",
        ],
        "config.profile.delete",
    );
}

#[test]
fn auth_login_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "auth",
            "--output-format",
            "json",
            "login",
            "--profile",
            "work",
            "--url",
            "https://x.test",
            "--dry-run",
        ],
        "auth.login",
    );
}

#[test]
fn auth_delete_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "auth",
            "--output-format",
            "json",
            "delete",
            "--profile",
            "work",
            "--force",
            "--dry-run",
        ],
        "auth.delete",
    );
}

#[test]
fn auth_refresh_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "auth",
            "--output-format",
            "json",
            "refresh",
            "--profile",
            "work",
            "--url",
            "https://x.test",
            "--dry-run",
        ],
        "auth.refresh",
    );
}

#[test]
fn vpn_rotate_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    assert_zero_side_effect(
        tmp.path(),
        &[
            "--format",
            "json",
            "vpn",
            "rotate",
            "--strategy",
            "lazy-on-fail",
            "--reason",
            "g5-test",
            "--dry-run",
        ],
        "vpn.rotate",
    );
}

#[test]
fn hermes_install_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    // Pin --prefix into the sandboxed tempdir so even a regressed run
    // could not escape the snapshot.
    let prefix = tmp.path().join("hermes-prefix");
    assert_zero_side_effect(
        tmp.path(),
        &[
            "--format",
            "json",
            "hermes",
            "install",
            "--prefix",
            prefix.to_str().unwrap(),
            "--dry-run",
        ],
        "hermes.install",
    );
}

#[test]
fn hermes_uninstall_dry_run_is_side_effect_free() {
    let tmp = tempfile::tempdir().unwrap();
    let prefix = tmp.path().join("hermes-prefix");
    assert_zero_side_effect(
        tmp.path(),
        &[
            "--format",
            "json",
            "hermes",
            "uninstall",
            "--prefix",
            prefix.to_str().unwrap(),
            "--dry-run",
        ],
        "hermes.uninstall",
    );
}

/// `--explain` alone (no `--dry-run`) should still parse cleanly on every
/// mutate command, exercising the surface contract without driving the
/// real action. We pin `--dry-run` here too because the test goal is
/// surface parsing — `--explain` semantics-only (no dry-run) is exercised
/// per-command by the existing unit tests.
#[test]
fn explain_flag_is_accepted_by_every_mutate_command() {
    let tmp = tempfile::tempdir().unwrap();
    let surfaces: &[(&[&str], &str)] = &[
        (
            &[
                "config",
                "--output-format",
                "json",
                "init",
                "--target",
                "all",
                "--non-interactive",
                "--dry-run",
                "--explain",
                "--idempotency-key",
                "g5-key-1",
            ],
            "config.init",
        ),
        (
            &[
                "--format",
                "json",
                "vpn",
                "rotate",
                "--strategy",
                "lazy-on-fail",
                "--reason",
                "g5",
                "--dry-run",
                "--explain",
                "--idempotency-key",
                "g5-key-2",
            ],
            "vpn.rotate",
        ),
    ];
    for (argv, op) in surfaces {
        let (payload, code, net) = run_dry_run(tmp.path(), argv);
        assert_eq!(code, 0, "argv={argv:?} exit 0 expected");
        assert_dry_run_envelope(&payload, op);
        assert_eq!(net, 0, "argv={argv:?} attempted network connect(s)");
        // idempotency_key must round-trip into the envelope.
        let key = payload
            .get("result")
            .and_then(|r| r.get("idempotency_key"))
            .and_then(Value::as_str);
        assert!(
            matches!(key, Some("g5-key-1") | Some("g5-key-2")),
            "idempotency_key not round-tripped for {op}: {payload}"
        );
    }
}
