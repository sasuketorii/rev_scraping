// SPDX-License-Identifier: MIT
//
// v1.3 Lane G.7: unified CLI error template lint.
//
// Spawns the `rev-stealth` binary against a handful of deterministic
// failure paths (no network, no AUP allowlist hit, no keyring access)
// and asserts that every JSON error envelope carries the canonical
// G.7 fields:
//
//   kind            — snake_case wire name (matches Lane I ErrorKind)
//   message         — human-readable string
//   hint            — operator hint or null
//   retry_after_ms  — backoff hint (u64) or null
//   doc_url         — https://.../docs/book/src/en/errors/<PascalCase>.md
//
// The test also walks every one of the 26 `CliErrorKind` variants and
// asserts the `doc_url` it produces points at a real file under
// `docs/book/src/en/errors/` (Lane J). This couples the CLI emitter to
// the documentation surface so adding a 27th variant without authoring
// its page is a hard test failure.
//
// Hermetic: hits no network. The spawned subcommands all fail at
// argv parse / URL validation / SSRF guard, before any side effect.

use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

fn rev_stealth_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

/// Repository root resolved from `CARGO_MANIFEST_DIR`
/// (`crates/stealth-cli/`) → two levels up.
fn repo_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .nth(2)
        .expect("manifest dir must have a great-grandparent")
        .to_path_buf()
}

/// Spawn `rev-stealth` with the given argv and return stdout as JSON.
///
/// Asserts the process exited non-zero (i.e. the failure path actually
/// triggered) and that stdout parsed as a JSON object.
fn spawn_for_error(argv: &[&str]) -> Value {
    let out = Command::new(rev_stealth_bin())
        .args(argv)
        // Belt-and-braces: make sure no ambient env coaxes the CLI into
        // a success branch.
        .env_remove("REV_SCRAPING_AUP_ACK")
        .env_remove("REV_SCRAPING_RUN_LIVE")
        .output()
        .unwrap_or_else(|e| panic!("spawn rev-stealth {argv:?}: {e}"));
    assert_ne!(
        out.status.code(),
        Some(0),
        "expected failure exit for argv={argv:?}\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    // Some commands emit single-line JSON (default `emit_err_envelope`)
    // and others emit pretty-printed multi-line JSON (e.g. `config get`
    // via `serde_json::to_string_pretty`). Try single-line-from-the-end
    // first, then fall back to parsing the entire stdout as one object.
    if let Some(line) = stdout
        .lines()
        .rev()
        .find(|l| l.trim_start().starts_with('{') && l.trim_end().ends_with('}'))
    {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            return v;
        }
    }
    serde_json::from_str::<Value>(stdout.trim()).unwrap_or_else(|e| {
        panic!(
            "non-JSON stdout for argv={argv:?}: {e}\nstdout: {stdout}\nstderr: {}",
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

/// Assert that `env` carries the canonical G.7 fields.
///
/// `kind_field` is `"kind"` for every CLI surface except hermes, which
/// already has a `kind: "hermes"` category tag and uses `error_kind`
/// for the G.7 wire kind.
fn assert_canonical_envelope(env: &Value, kind_field: &str, label: &str) {
    let obj = env
        .as_object()
        .unwrap_or_else(|| panic!("[{label}] envelope must be a JSON object: {env}"));

    for required in [kind_field, "message", "doc_url"] {
        assert!(
            obj.contains_key(required),
            "[{label}] missing required G.7 field `{required}`: {env}"
        );
    }
    // `hint` and `retry_after_ms` are always present (Null when absent)
    // so callers can branch without optional-chaining.
    for nullable in ["hint", "retry_after_ms"] {
        assert!(
            obj.contains_key(nullable),
            "[{label}] missing nullable G.7 field `{nullable}`: {env}"
        );
    }

    let kind = obj[kind_field]
        .as_str()
        .unwrap_or_else(|| panic!("[{label}] `{kind_field}` must be string: {env}"));
    assert!(
        !kind.is_empty()
            && kind
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
        "[{label}] `{kind_field}` must be snake_case: {kind}"
    );

    let message = obj["message"]
        .as_str()
        .unwrap_or_else(|| panic!("[{label}] `message` must be string: {env}"));
    assert!(
        !message.is_empty(),
        "[{label}] `message` must not be empty: {env}"
    );

    let doc_url = obj["doc_url"]
        .as_str()
        .unwrap_or_else(|| panic!("[{label}] `doc_url` must be string: {env}"));
    assert!(
        doc_url.starts_with(
            "https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/"
        ),
        "[{label}] `doc_url` must point at Lane J docs: {doc_url}"
    );
    assert!(
        doc_url.ends_with(".md"),
        "[{label}] `doc_url` must end in .md: {doc_url}"
    );
}

#[test]
fn cf_evaluate_invalid_url_emits_canonical_envelope() {
    let env = spawn_for_error(&[
        "--format",
        "json",
        "cf-evaluate",
        "--url",
        "not-a-valid-url",
        "--i-have-authorization",
    ]);
    assert_canonical_envelope(&env, "kind", "cf-evaluate invalid url");
    // Sanity: legacy fields still present for v1.2.x consumers.
    assert_eq!(env["ok"], Value::Bool(false));
    assert_eq!(env["operation"], Value::String("cf-evaluate".into()));
}

#[test]
fn measure_invalid_url_emits_canonical_envelope() {
    let env = spawn_for_error(&["--format", "json", "measure", "--url", "::not-a-url::"]);
    assert_canonical_envelope(&env, "kind", "measure invalid url");
    assert_eq!(env["ok"], Value::Bool(false));
}

#[test]
fn spider_invalid_url_emits_canonical_envelope() {
    let env = spawn_for_error(&[
        "--format",
        "json",
        "spider",
        "--url",
        "::not-a-url::",
        "--i-have-authorization",
    ]);
    assert_canonical_envelope(&env, "kind", "spider invalid url");
    assert_eq!(env["ok"], Value::Bool(false));
}

#[test]
fn relocate_url_invalid_emits_canonical_envelope() {
    // relocate --url path: invalid URL triggers the validation
    // emit_err before any AUP / SSRF check.
    let env = spawn_for_error(&[
        "--format",
        "json",
        "relocate",
        "--stable-id",
        "test-stable-id",
        "--url",
        "::not-a-url::",
        "--i-have-authorization",
    ]);
    assert_canonical_envelope(&env, "kind", "relocate invalid url");
    assert_eq!(env["ok"], Value::Bool(false));
}

#[test]
fn every_error_kind_doc_url_resolves_on_disk() {
    // Cross-check Lane I (26 ErrorKind) ↔ Lane J (per-variant .md pages).
    // Each `CliErrorKind::doc_url()` must point at a file that exists
    // under `docs/book/src/en/errors/`. Walking the variants here
    // catches both (a) a new variant authored without its page and
    // (b) a stale page that got renamed without updating the emitter.
    use stealth_cli::__error_envelope_for_test::CliErrorKind;

    let errors_dir = repo_root().join("docs/book/src/en/errors");
    assert!(
        errors_dir.is_dir(),
        "Lane J errors dir must exist: {}",
        errors_dir.display()
    );

    let mut missing: Vec<String> = Vec::new();
    for k in CliErrorKind::all().iter().copied() {
        let path = errors_dir.join(format!("{}.md", k.pascal_name()));
        if !path.is_file() {
            missing.push(path.display().to_string());
        }
    }
    assert!(
        missing.is_empty(),
        "missing Lane J doc pages for {} ErrorKind variant(s):\n  {}",
        missing.len(),
        missing.join("\n  ")
    );
}

#[test]
fn config_get_missing_key_emits_canonical_envelope() {
    // `config get` on an unknown key exits 1 with a JSON envelope.
    // Reviewer round-1 finding: this path previously bypassed G.7.
    let env = spawn_for_error(&[
        "--format",
        "json",
        "config",
        "--output-format",
        "json",
        "get",
        "__definitely_missing_key__",
    ]);
    assert_canonical_envelope(&env, "kind", "config get missing key");
    // `kind` should classify as `not_found` (or fall through to internal
    // if the heuristic ever changes — accept either rather than pin).
    let kind = env["kind"].as_str().unwrap();
    assert!(
        matches!(kind, "not_found" | "internal"),
        "unexpected kind={kind}"
    );
}

#[test]
fn config_profile_switch_missing_emits_canonical_envelope() {
    // Round-4 reviewer finding: `config profile switch __missing__`
    // emitted only `{error, message, profile}` without G.7 fields.
    // After the central `emit()` auto-augmentation, every error sink
    // under the config subtree carries the canonical 5 fields.
    let tmp_home = tempfile::tempdir().expect("tempdir");
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "config",
            "profile",
            "switch",
            "__definitely_missing_profile__",
        ])
        .env("REV_SCRAPING_HOME", tmp_home.path())
        .output()
        .expect("spawn rev-stealth");
    assert_ne!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let env_val = serde_json::from_str::<Value>(stdout.trim()).unwrap_or_else(|e| {
        panic!("non-JSON stdout: {e}\n{stdout}");
    });
    assert_canonical_envelope(&env_val, "kind", "config profile switch missing");
}

#[test]
fn config_explicit_local_text_wins_over_global_json() {
    // Round-3 reviewer finding: explicit `--output-format text` must
    // win over global `--format json` (documented precedence rule in
    // `docs/json-schemas/cli/README.md`). The round-2 default-equals
    // check could not distinguish "user typed --output-format text"
    // from "user passed nothing"; the round-3 argv-peek does.
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "config",
            "--output-format",
            "text",
            "get",
            "__definitely_missing_key__",
        ])
        .output()
        .expect("spawn rev-stealth");
    assert_ne!(out.status.code(), Some(0));
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    // Explicit local text → human render on stderr, NO JSON envelope.
    assert!(
        stderr.contains("key not found"),
        "expected human text on stderr, got stderr={stderr} stdout={stdout}"
    );
    assert!(
        !stdout.trim_start().starts_with('{'),
        "stdout must NOT be JSON when local --output-format text is set: {stdout}"
    );
}

#[test]
fn config_get_missing_key_promotes_global_json() {
    // Round-2 reviewer finding: `rev-stealth --format json config get ...`
    // (global flag only, no per-subcommand `--output-format`) previously
    // emitted human text and bypassed G.7. After the JSON-promotion in
    // `config_cli::run`, the global flag now propagates into the subtree.
    let env = spawn_for_error(&[
        "--format",
        "json",
        "config",
        "get",
        "__definitely_missing_key__",
    ]);
    assert_canonical_envelope(&env, "kind", "config get missing key (global json)");
}

#[test]
fn clap_parse_failure_emits_canonical_envelope() {
    // Missing required argument: `measure` requires `--url`. clap rejects
    // at parse time with exit 2. Reviewer round-1 finding: previously
    // bypassed G.7. With `--format json` we now emit the canonical
    // envelope at `operation: "cli.parse"`.
    let env = spawn_for_error(&["--format", "json", "measure"]);
    assert_canonical_envelope(&env, "kind", "clap parse failure");
    assert_eq!(
        env["operation"],
        serde_json::Value::String("cli.parse".into())
    );
    assert_eq!(env["exit_code"], serde_json::json!(2));
}

#[test]
fn clap_parse_failure_combined_arg_form_emits_canonical_envelope() {
    // Round-2 reviewer finding: clap accepts both `--format json` and
    // `--format=json`; the round-1 argv heuristic only matched the split
    // form. After the round-2 fix, both shapes promote to the G.7
    // envelope on parse error.
    let env = spawn_for_error(&["--format=json", "measure"]);
    assert_canonical_envelope(&env, "kind", "clap parse failure (combined arg)");
    assert_eq!(
        env["operation"],
        serde_json::Value::String("cli.parse".into())
    );
    assert_eq!(env["exit_code"], serde_json::json!(2));
}

#[test]
fn config_validate_failure_emits_canonical_envelope() {
    // Round-5 reviewer finding: `config validate` failure path emitted
    // `{ok:false, reports, read_errors}` without G.7 fields because the
    // payload lacked an `error` string and bypassed the central emit()
    // auto-augmentation. Round-6 fix: build the envelope explicitly with
    // `augment_with_g7_fields(Validation, ...)` and retain reports +
    // read_errors so operators can still parse per-file detail.
    let tmp_home = tempfile::tempdir().expect("tempdir");
    // Seed a policy.toml that fails strict validation: `deny_unknown_fields`
    // rejects the `__bogus_field__` key.
    let policy_path = tmp_home.path().join("policy.toml");
    std::fs::write(
        &policy_path,
        "schema_version = 1\n__bogus_field__ = \"trips deny_unknown_fields\"\n",
    )
    .expect("seed policy.toml");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "config",
            "--output-format",
            "json",
            "validate",
        ])
        .env("REV_SCRAPING_HOME", tmp_home.path())
        .output()
        .expect("spawn rev-stealth");
    assert_ne!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let env_val = serde_json::from_str::<Value>(stdout.trim()).unwrap_or_else(|e| {
        panic!("non-JSON stdout: {e}\n{stdout}");
    });
    assert_canonical_envelope(&env_val, "kind", "config validate failure");
    // The diagnostic payload MUST be retained so operators can still parse
    // per-file detail — this is the round-6 "structurally honest" contract.
    let obj = env_val.as_object().expect("object");
    assert!(
        obj.contains_key("reports"),
        "reports payload must be retained alongside G.7 envelope: {env_val}"
    );
    assert!(
        obj.contains_key("read_errors"),
        "read_errors payload must be retained: {env_val}"
    );
    assert_eq!(env_val["ok"], Value::Bool(false));
    assert_eq!(
        env_val["operation"],
        Value::String("config.validate".into())
    );
    assert_eq!(env_val["kind"], Value::String("validation".into()));
}

#[test]
fn config_migrate_failure_emits_canonical_envelope() {
    // Round-5 reviewer finding: `config migrate` failure path emitted
    // `{outcomes:[...]}` without G.7 fields. Round-6 fix: explicit
    // `augment_with_g7_fields(Validation, ...)` while retaining the
    // `outcomes` diagnostic array.
    let tmp_home = tempfile::tempdir().expect("tempdir");
    // schema_version 999 > LATEST_SCHEMA_VERSION triggers an "error"
    // outcome which flips `any_error = true`.
    let policy_path = tmp_home.path().join("policy.toml");
    std::fs::write(&policy_path, "schema_version = 999\nrequire_vpn = true\n")
        .expect("seed policy.toml");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "config",
            "--output-format",
            "json",
            "migrate",
        ])
        .env("REV_SCRAPING_HOME", tmp_home.path())
        .output()
        .expect("spawn rev-stealth");
    assert_ne!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let env_val = serde_json::from_str::<Value>(stdout.trim()).unwrap_or_else(|e| {
        panic!("non-JSON stdout: {e}\n{stdout}");
    });
    assert_canonical_envelope(&env_val, "kind", "config migrate failure");
    let obj = env_val.as_object().expect("object");
    assert!(
        obj.contains_key("outcomes"),
        "outcomes payload must be retained alongside G.7 envelope: {env_val}"
    );
    assert_eq!(env_val["ok"], Value::Bool(false));
    assert_eq!(env_val["operation"], Value::String("config.migrate".into()));
    assert_eq!(env_val["kind"], Value::String("validation".into()));
}

#[test]
fn doc_url_template_is_stable() {
    // Pin the doc_url shape so a future refactor that moves the docs
    // breaks loudly here instead of silently producing 404 links.
    use stealth_cli::__error_envelope_for_test::{CliErrorKind, DOC_URL_BASE};
    assert_eq!(
        DOC_URL_BASE,
        "https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/"
    );
    assert_eq!(
        CliErrorKind::RateLimit.doc_url(),
        "https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/RateLimit.md"
    );
    assert_eq!(
        CliErrorKind::VpnAllInstancesFailed.doc_url(),
        "https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/VpnAllInstancesFailed.md"
    );
}
