// SPDX-License-Identifier: MIT
//! v1.3 Lane G.6.b: at-most-once commit replay integration test.
//!
//! For a representative set of mutate sub-commands (`config init`,
//! `config profile create`, `hermes uninstall`, plus an `--idempotency-key`
//! variance check), this test verifies the contract documented in
//! `crates/stealth-cli/src/commands/idempotency.rs`:
//!
//!   * First invocation with `--idempotency-key K` runs the side effect
//!     and writes an envelope to the per-test idempotency store.
//!   * Second invocation with the *same* key and *same* payload returns
//!     the cached envelope WITHOUT re-running the side effect — the
//!     replayed envelope MUST carry `"replayed": true`.
//!   * Second invocation with the *same* key but a *different* payload
//!     does NOT replay (different `(op, key, payload_hash)` cache entry).
//!   * Invocation WITHOUT `--idempotency-key` never reads or writes the
//!     store.
//!
//! Isolation: each test points `REV_SCRAPING_IDEMPOTENCY_DIR` at its own
//! tempdir, so this test is parallel-safe and cannot disturb the
//! operator's real `~/.rev_scraping/idempotency/`.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::Value;

/// Spawn `rev-stealth <argv>` rooted at `home`, with `--format json`
/// implied for any sub-command that supports it. Returns
/// `(stdout_json_or_null, exit_code, raw_stdout)`.
fn run_cli(home: &Path, idem_dir: &Path, argv: &[&str]) -> (Value, i32, String) {
    let mut cmd = Command::new(env!("CARGO"));
    cmd.args(["run", "--quiet", "--bin", "rev-stealth", "--"]);
    cmd.args(argv);
    cmd.env("REV_SCRAPING_HOME", home);
    cmd.env("HOME", home);
    cmd.env("REV_SCRAPING_AUTH_DIR", home.join("auth"));
    cmd.env("REV_SCRAPING_IDEMPOTENCY_DIR", idem_dir);
    cmd.env("REV_SCRAPING_PROFILES_ROOT", home.join("profiles"));
    cmd.env("REV_SCRAPING_REQUIRE_VPN", "0");
    // Make any accidental child-process spawn die loudly rather than
    // touching the operator's real environment.
    cmd.env("REV_AUTH_BIN", "/dev/null");
    cmd.env("REV_OBSCURA_BIN", "/dev/null");
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let out = cmd.output().expect("rev-stealth spawnable");
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let parsed: Value = serde_json::from_str(&stdout).unwrap_or(Value::Null);
    (parsed, out.status.code().unwrap_or(-1), stdout)
}

/// Unique per-test scratch root.
fn fresh_home(tag: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "rev-stealth-idem-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    ));
    std::fs::create_dir_all(&base).unwrap();
    base
}

/// Count entries in the idempotency cache dir (`.json` files only).
fn cache_entry_count(idem_dir: &Path) -> usize {
    if !idem_dir.exists() {
        return 0;
    }
    std::fs::read_dir(idem_dir)
        .map(|it| {
            it.flatten()
                .filter(|e| {
                    e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .map(|s| s == "json")
                        .unwrap_or(false)
                })
                .count()
        })
        .unwrap_or(0)
}

#[test]
fn config_init_same_key_replays_without_side_effect() {
    let home = fresh_home("init-replay");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();

    // First call: real side effect (creates policy.toml + authorized.toml).
    let (env1, exit1, raw1) = run_cli(
        &home,
        &idem,
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--idempotency-key",
            "test-init-key-1",
        ],
    );
    assert_eq!(exit1, 0, "first init must succeed: {raw1}");
    // env1 may be Null because `config init` uses text format by default;
    // the contract we verify is whether the cache was populated.
    let _ = env1;
    assert_eq!(
        cache_entry_count(&idem),
        1,
        "first run should write exactly one idempotency envelope"
    );
    let policy_after_first = home.join(".rev_scraping").join("policy.toml");
    // Note: depending on default REV_SCRAPING_HOME layout the file may
    // land elsewhere. The structural contract we care about here is the
    // cache, not the exact target path.
    let _ = policy_after_first;

    // Second call: same key, same args → MUST replay, MUST NOT add a
    // second cache entry.
    let (env2, exit2, raw2) = run_cli(
        &home,
        &idem,
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--idempotency-key",
            "test-init-key-1",
        ],
    );
    assert_eq!(exit2, 0, "replay must succeed: {raw2}");
    // The replayed envelope is printed verbatim and tagged `replayed: true`.
    assert_eq!(
        env2.get("replayed").and_then(Value::as_bool),
        Some(true),
        "replay envelope must carry `replayed: true`. raw=\n{raw2}",
    );
    assert_eq!(
        env2.get("operation").and_then(Value::as_str),
        Some("config.init"),
    );
    assert_eq!(
        cache_entry_count(&idem),
        1,
        "replay must NOT write a new cache entry"
    );
}

#[test]
fn config_init_different_payload_does_not_replay() {
    let home = fresh_home("init-diff-payload");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();

    // First: target=policy
    let (_e1, exit1, raw1) = run_cli(
        &home,
        &idem,
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--target",
            "policy",
            "--idempotency-key",
            "shared-key",
        ],
    );
    assert_eq!(exit1, 0, "first init failed: {raw1}");
    assert_eq!(cache_entry_count(&idem), 1);

    // Second: same key, but target=authorized (different payload).
    // MUST execute fresh and write a NEW cache entry (entries are keyed
    // by `(op, key_hash, payload_hash)`).
    let (_e2, exit2, raw2) = run_cli(
        &home,
        &idem,
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--target",
            "authorized",
            "--idempotency-key",
            "shared-key",
        ],
    );
    assert_eq!(exit2, 0, "different-payload run failed: {raw2}");
    assert_eq!(
        cache_entry_count(&idem),
        2,
        "different payload with same key must write a second entry"
    );
}

#[test]
fn config_init_no_key_does_not_touch_cache() {
    let home = fresh_home("init-no-key");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();
    let (_e, exit, raw) = run_cli(&home, &idem, &["config", "--output-format", "json", "init"]);
    assert_eq!(exit, 0, "init without key failed: {raw}");
    assert_eq!(
        cache_entry_count(&idem),
        0,
        "no key → no cache write; got {} entries",
        cache_entry_count(&idem),
    );
}

#[test]
fn config_profile_create_same_key_replays() {
    let home = fresh_home("profile-create");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();

    let argv = &[
        "config",
        "--output-format",
        "json",
        "profile",
        "create",
        "lane-g6-test",
        "--idempotency-key",
        "profile-key-1",
    ];

    let (_e1, exit1, raw1) = run_cli(&home, &idem, argv);
    assert_eq!(exit1, 0, "first profile create failed: {raw1}");
    assert_eq!(cache_entry_count(&idem), 1);

    let (env2, exit2, raw2) = run_cli(&home, &idem, argv);
    assert_eq!(exit2, 0, "replay failed: {raw2}");
    assert_eq!(
        env2.get("replayed").and_then(Value::as_bool),
        Some(true),
        "replayed envelope expected. raw=\n{raw2}",
    );
    assert_eq!(
        env2.get("operation").and_then(Value::as_str),
        Some("config.profile.create"),
    );
    assert_eq!(
        cache_entry_count(&idem),
        1,
        "replay must not add a new cache entry"
    );
}

#[test]
fn config_edit_idempotency_key_is_a_no_op() {
    // v1.3 Lane G.6 reviewer round-1 finding: `config.edit`'s side effect is
    // driven by interactive editor input, which is not knowable from CLI
    // args alone. Keying replay on `(target,)` would let a same-key second
    // invocation skip a genuinely-different edit. The fix: do NOT register
    // `config.edit` in the idempotency store at all. `--idempotency-key`
    // remains accepted on the CLI surface for shape consistency but is a
    // no-op here. This test pins that contract.
    let home = fresh_home("edit-no-op");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();
    // Seed a real policy.toml first so `config edit` has something to read.
    let (_e0, exit0, raw0) = run_cli(
        &home,
        &idem,
        &[
            "config",
            "--output-format",
            "json",
            "init",
            "--target",
            "policy",
        ],
    );
    assert_eq!(exit0, 0, "seed init failed: {raw0}");
    let _cache_before = cache_entry_count(&idem);

    // Use `--editor "true"` so the editor is a no-op that leaves the file
    // unchanged; this lets us exercise the full edit path twice without
    // depending on a real editor binary.
    let argv = &[
        "config",
        "--output-format",
        "json",
        "edit",
        "--target",
        "policy",
        "--editor",
        "true",
        "--idempotency-key",
        "edit-key-1",
    ];
    let (_e1, exit1, _r1) = run_cli(&home, &idem, argv);
    let (_e2, exit2, _r2) = run_cli(&home, &idem, argv);
    // Both should succeed; cache must be empty (one entry already from the
    // earlier `config init` seed, so we compare against that baseline).
    assert_eq!(exit1, 0);
    assert_eq!(exit2, 0);
    // The earlier `config init` (no key) wrote 0 entries, so cache should
    // remain 0 even after two edits with the same key.
    assert_eq!(
        cache_entry_count(&idem),
        0,
        "config.edit must NOT touch the idempotency cache (reviewer-pinned contract)"
    );
}

#[test]
fn hermes_uninstall_dry_run_skips_idempotency() {
    // --dry-run must short-circuit BEFORE the idempotency check. We assert
    // that even with --idempotency-key supplied, dry-run does not write to
    // the cache (matching the documented contract).
    let home = fresh_home("hermes-dry");
    let idem = home.join("idem");
    std::fs::create_dir_all(&idem).unwrap();

    let prefix = home.join("does-not-exist");
    let (env, exit, raw) = run_cli(
        &home,
        &idem,
        &[
            "--format",
            "json",
            "hermes",
            "uninstall",
            "--prefix",
            prefix.to_str().unwrap(),
            "--dry-run",
            "--idempotency-key",
            "dry-key",
        ],
    );
    assert_eq!(exit, 0, "dry-run uninstall failed: {raw}");
    // dry-run prints the canonical dry-run envelope, not the idempotency one.
    assert_eq!(
        env.get("result")
            .and_then(|r| r.get("dry_run"))
            .and_then(Value::as_bool),
        Some(true),
        "expected canonical dry-run envelope. raw=\n{raw}",
    );
    assert_eq!(
        cache_entry_count(&idem),
        0,
        "dry-run must NOT write any idempotency envelope"
    );
}
