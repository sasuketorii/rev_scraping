// SPDX-License-Identifier: MIT
//! v1.3 Lane G fix-up R2 — Delta 3: direct verification that
//! `rev-stealth auth login --idempotency-key K` invoked twice with the
//! same key + payload writes the audit-log entry exactly ONCE.
//!
//! Codex R1 finding: `idempotency_replay.rs` proves the wire-level
//! `"replayed": true` marker on the second invocation, but does NOT
//! directly assert that the auditable side effect (the rev-auth child's
//! `audit.jsonl` append) is suppressed. This test closes that gap.
//!
//! Strategy:
//!   1. Drop a tiny shell-script "fake rev-auth" into a tempdir. The
//!      script appends one JSONL line to `$AUDIT_FILE` and exits 0,
//!      simulating the real helper's `auth_login_start` audit emission
//!      without needing chromiumoxide / Xvfb / real cookies.
//!   2. Set `REV_AUTH_BIN` to that script.
//!   3. Run `rev-stealth auth login --idempotency-key K …` twice with
//!      identical arguments under a per-test `REV_SCRAPING_IDEMPOTENCY_DIR`.
//!   4. Assert:
//!      * Both invocations exit 0.
//!      * The audit file has *exactly* 1 line (not 2).
//!      * The second invocation's stdout carries `"replayed": true`.
//!
//! Hermeticity: tempdir for HOME / AuthStore / IdempotencyStore +
//! shell-script helper means no chromiumoxide, no rev-auth Rust crate
//! spawn, no real network. Parallel-test-safe.
//!
//! Why a shell script instead of a Rust mock binary: the existing
//! `e2e_auth_flow.rs` compiles `rev-auth` via cargo (slow + needs a
//! second binary on PATH). For this test, we don't care about the
//! helper's real protocol — we only care that the helper is NOT
//! re-invoked. A 2-line POSIX sh script is the smallest hermetic
//! sentinel.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// Per-test scratch dir; `Drop` reaps it.
struct Scratch {
    dir: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "rev-stealth-auth-idem-{}-{}-{}",
            tag,
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        ));
        fs::create_dir_all(&dir).expect("scratch dir");
        Self { dir }
    }
    fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Write a shell-script fake rev-auth into `scratch/fake-rev-auth.sh`.
///
/// The script appends a JSONL line to `$AUDIT_FILE` (passed via env)
/// and exits 0. It explicitly does NOT parse any of its own arguments;
/// the test only cares about the side-effect count.
fn install_fake_rev_auth(scratch: &Path, audit_file: &Path) -> PathBuf {
    let script_path = scratch.join("fake-rev-auth.sh");
    let body = format!(
        "#!/bin/sh\n\
# v1.3 Lane G fix-up R2 — fake rev-auth helper for the audit-idempotency\n\
# integration test. The body intentionally does not parse arguments: the\n\
# test only verifies that this script is invoked exactly N times by\n\
# counting lines in $AUDIT_FILE.\n\
printf '{{\"action\":\"auth_login_start\",\"profile\":\"%s\"}}\\n' \"${{1:-unknown}}\" >> '{audit}'\n\
exit 0\n",
        audit = audit_file.display(),
    );
    fs::write(&script_path, body).expect("write fake rev-auth");
    let mut perms = fs::metadata(&script_path).expect("stat fake").permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&script_path, perms).expect("chmod fake");
    script_path
}

/// Seed `~/.rev_scraping/authorized.toml` under the test HOME so the AUP
/// allowlist accepts `https://example.test/login`. Without this, the
/// CLI's `auth login` short-circuits with a UserError exit before it
/// reaches the idempotency hook OR the helper spawn, and the audit-line
/// invariant is never exercised. This is the gap Codex flagged at R2
/// round 1 (`auth_login_with_same_idem_key_audits_only_once` silently
/// skipped under sandboxed CI).
fn seed_authorized_toml(home: &Path) {
    let dir = home.join(".rev_scraping");
    fs::create_dir_all(&dir).expect("seed allowlist dir");
    let body = "\
schema_version = 1

[[targets]]
domain = \"example.test\"
url_pattern = \"https://example\\\\.test/.*\"
proof_url = \"https://example.test/.well-known/scraping-authorization.txt\"
auth_allowed = true
expires_at = \"2099-01-01T00:00:00Z\"
";
    fs::write(dir.join("authorized.toml"), body).expect("write authorized.toml");
}

/// Spawn `rev-stealth auth login --idempotency-key …` with the env wired
/// at `scratch`. Returns (stdout-as-json-or-Null, exit_code, raw_stdout).
fn run_auth_login(
    scratch: &Path,
    fake_rev_auth: &Path,
    idem_key: &str,
    extra_args: &[&str],
) -> (Value, i32, String) {
    let home = scratch.join("home");
    let idem_dir = scratch.join("idem");
    let auth_dir = home.join("auth");
    fs::create_dir_all(&auth_dir).ok();
    // AUP allowlist is resolved from `HOME/.rev_scraping/authorized.toml`
    // (see `auth_aup::default_allowlist_path`). Seed it idempotently so
    // both the first and second invocations clear the AUP gate.
    seed_authorized_toml(&home);
    let mut cmd = Command::new(env!("CARGO"));
    cmd.args(["run", "--quiet", "--bin", "rev-stealth", "--"]);
    cmd.args(["--format", "json", "auth", "login"]);
    cmd.args([
        "--profile",
        "work",
        "--url",
        "https://example.test/login",
        "--domain",
        "example.test",
        "--allow-no-vpn",
        "--idempotency-key",
        idem_key,
        "--rev-auth-bin",
    ]);
    cmd.arg(fake_rev_auth);
    for a in extra_args {
        cmd.arg(a);
    }
    cmd.env("HOME", &home);
    cmd.env("REV_SCRAPING_HOME", &home);
    cmd.env("REV_SCRAPING_AUTH_DIR", &auth_dir);
    cmd.env("REV_SCRAPING_IDEMPOTENCY_DIR", &idem_dir);
    cmd.env("REV_SCRAPING_REQUIRE_VPN", "0");
    cmd.env("REV_OBSCURA_BIN", "/dev/null");
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let out = cmd.output().expect("spawn rev-stealth");
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let parsed: Value = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
    (parsed, out.status.code().unwrap_or(-1), stdout)
}

#[test]
fn auth_login_with_same_idem_key_audits_only_once() {
    // Skip when cargo target dir isn't writable / when running under a
    // sandbox that blocks `cargo run`. This mirrors the
    // bind-skip pattern used by `e2e_spider_use_auth_mock.rs`.
    let scratch = Scratch::new("audit-once");
    let audit_file = scratch.path().join("audit.jsonl");
    let fake = install_fake_rev_auth(scratch.path(), &audit_file);

    // First invocation: must spawn the helper (audit gets 1 line).
    //
    // v1.3 Lane G fix-up R2 — Codex review finding #1 follow-up:
    // we no longer silently skip on a non-zero first invocation. The
    // AUP scaffolding is seeded by `seed_authorized_toml` in
    // `run_auth_login`, so anything other than exit 0 here is a real
    // regression that must FAIL the test, not silently green.
    let key = "rev-stealth-fixup-r2-audit-key-1";
    let (env1, exit1, raw1) = run_auth_login(scratch.path(), &fake, key, &[]);
    assert_eq!(
        exit1, 0,
        "first auth login invocation must succeed (AUP allowlist seeded); exit={exit1}; stdout: {raw1}",
    );

    let line_count_after_first = std::fs::read_to_string(&audit_file)
        .map(|s| s.lines().count())
        .unwrap_or(0);
    assert_eq!(
        line_count_after_first, 1,
        "first invocation expected to write exactly 1 audit line; got {line_count_after_first}; stdout: {raw1}",
    );

    // Second invocation: same key + same payload → idempotency hit →
    // helper MUST NOT be re-spawned → audit file stays at 1 line.
    let (env2, exit2, raw2) = run_auth_login(scratch.path(), &fake, key, &[]);
    assert_eq!(exit2, 0, "replay invocation should exit 0; stdout: {raw2}");

    let line_count_after_second = std::fs::read_to_string(&audit_file)
        .map(|s| s.lines().count())
        .unwrap_or(0);
    assert_eq!(
        line_count_after_second, 1,
        "second invocation (same idem key) must NOT add an audit line; got {line_count_after_second} (was {line_count_after_first}); stdout: {raw2}",
    );

    // Wire contract: the replayed envelope carries `replayed: true`.
    assert_eq!(
        env2.get("replayed"),
        Some(&Value::Bool(true)),
        "expected replayed: true marker on second invocation; got envelope: {env2}",
    );
    // First invocation: rev-auth child writes its own envelope to stdout,
    // so we can't reliably parse env1 here; the audit-line count is the
    // load-bearing assertion.
    let _ = env1;
}

#[test]
fn auth_login_with_different_idem_key_audits_twice() {
    // Belt-and-suspenders: different `--idempotency-key` with otherwise
    // identical args MUST NOT replay, because the cache key includes the
    // key-hash. We expect exactly 2 audit lines after 2 calls.
    let scratch = Scratch::new("audit-twice");
    let audit_file = scratch.path().join("audit.jsonl");
    let fake = install_fake_rev_auth(scratch.path(), &audit_file);

    let (_e1, exit1, raw1) = run_auth_login(scratch.path(), &fake, "key-A", &[]);
    assert_eq!(
        exit1, 0,
        "first invocation (key-A) must succeed; exit={exit1}; stdout: {raw1}",
    );
    let (_e2, exit2, raw2) = run_auth_login(scratch.path(), &fake, "key-B", &[]);
    assert_eq!(
        exit2, 0,
        "second invocation (key-B) must succeed; exit={exit2}; stdout: {raw2}",
    );

    let line_count = std::fs::read_to_string(&audit_file)
        .map(|s| s.lines().count())
        .unwrap_or(0);
    assert_eq!(
        line_count, 2,
        "two distinct idempotency keys must produce 2 audit lines; got {line_count}",
    );
}
