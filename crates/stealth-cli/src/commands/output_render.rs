// SPDX-License-Identifier: MIT
//
// v1.3 Lane G fix-up R2: shared OK / structured-envelope rendering helpers
// for the multi-format (`human` / `json` / `yaml`) `--output-format` enum.
//
// Background:
//   Lane G.4 introduced per-subcommand `--output-format` overrides backed by
//   a 2-variant `OutputFormat::{Human, Json}` enum. Each subcommand defined
//   its own `emit_ok` / `emit_err` helper that match'd on this enum and
//   inlined a `serde_json::to_string_pretty` / `println!("[OK] ...")` branch.
//
//   R2 adds two more wire shapes — `text` (alias of `human`) and `yaml` (a
//   serde_yaml re-encoding of the same JSON envelope). To avoid duplicating
//   the yaml branch across ~20 match-sites, this module owns the canonical
//   "given an OK envelope as JSON, print it in the operator's chosen format"
//   helper. Every per-subcommand `emit_ok` now delegates here.
//
//   `emit_err` keeps living in `error_envelope.rs` because the failure
//   envelope carries the unified G.7 fields (`kind`, `doc_url`, etc.) and
//   that helper already routes through a single emit point — this file
//   extends *that* helper with the yaml branch.
//
// Wire contract:
//   * Human/Text — `[OK] <op>\n<pretty-json-payload>` to stdout.
//   * Json       — `{"ok":true,"operation":<op>,"result":<payload>}` to stdout.
//   * Yaml       — the same envelope, re-encoded via `serde_yaml::to_string`.
//
// Yaml is intentionally a re-encoding of the JSON envelope (not a separate
// schema) so the JSON-schema docs under `docs/json-schemas/cli/` remain the
// single source of truth for the field set. Downstream tooling can therefore
// `yq -y < ...` or `yq < ...` interchangeably.

use serde_json::{json, Value};

use crate::OutputFormat;

/// Render and print a successful operation envelope for the given format.
///
/// `op` is the subcommand-scoped operation slug (`captcha.solve`,
/// `vpn.rotate`, etc); `payload` is the structured `result` field. The
/// helper composes the unified envelope `{ok, operation, result}` for the
/// structured formats and a `[OK] <op>` + pretty-json body for human mode.
///
/// Yaml errors (serializer hiccup on unrepresentable JSON values, which
/// should never happen for valid `serde_json::Value`) fall through to the
/// JSON encoding so the caller still gets a usable line — this matches the
/// fallback strategy already used in `commands/config_cli.rs`.
pub fn emit_ok(format: OutputFormat, op: &str, payload: Value) {
    let envelope = json!({
        "ok": true,
        "operation": op,
        "result": payload,
    });
    print_envelope(format, op, &envelope, /*is_err=*/ false);
}

/// Print an already-built envelope (success or failure) in the requested
/// format. Used by `error_envelope::emit_err_envelope` so the yaml branch
/// has exactly one implementation.
pub fn print_envelope(format: OutputFormat, op: &str, envelope: &Value, is_err: bool) {
    match format {
        OutputFormat::Json => {
            println!("{envelope}");
        }
        OutputFormat::Yaml => {
            match serde_yaml::to_string(envelope) {
                Ok(s) => print!("{s}"),
                Err(e) => {
                    // Fail-soft: yaml serializer cannot fail for normal
                    // serde_json::Value, but if it does we still want the
                    // operator to see *something* parseable.
                    eprintln!("# yaml-encode-error: {e}");
                    println!("{envelope}");
                }
            }
        }
        OutputFormat::Human => {
            if is_err {
                // Failure path is handled by the caller (error_envelope.rs);
                // we should not be invoked from there in Human mode. Guard
                // anyway so the helper is total.
                if let Some(msg) = envelope.get("error").and_then(|v| v.as_str()) {
                    eprintln!("[ERROR] {op}: {msg}");
                } else {
                    eprintln!("[ERROR] {op}");
                }
            } else {
                println!("[OK] {op}");
                if let Some(result) = envelope.get("result") {
                    if let Ok(s) = serde_json::to_string_pretty(result) {
                        println!("{s}");
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structured_envelope_has_ok_operation_result() {
        // Sanity: the envelope shape is stable across formats — the
        // serializer choice is purely a wire encoding.
        let payload = json!({"k": "v"});
        let env = json!({"ok": true, "operation": "x.y", "result": payload});
        let yaml = serde_yaml::to_string(&env).unwrap();
        assert!(yaml.contains("ok: true"));
        assert!(yaml.contains("operation: x.y"));
        assert!(yaml.contains("k: v"));
    }

    #[test]
    fn yaml_round_trip_matches_json() {
        let env = json!({"ok": true, "operation": "spider.run", "result": {"n": 1}});
        let yaml = serde_yaml::to_string(&env).unwrap();
        let back: Value = serde_yaml::from_str(&yaml).unwrap();
        assert_eq!(back, env);
    }
}
