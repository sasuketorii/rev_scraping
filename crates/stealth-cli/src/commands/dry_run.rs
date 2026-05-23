// SPDX-License-Identifier: MIT
//
// v1.3 Lane G.5: shared `--dry-run` + `--explain` flag block for every
// mutate subcommand. Flattened into each mutate Args struct alongside
// `OutputFormatOverride` from Lane G.4.
//
// Contract (per ExecPlan):
//   * `--dry-run`     side-effect-free: NO file write / network / keyring
//                     operation may execute. The command computes its
//                     intended action plan and emits it via the standard
//                     `emit_dry_run` envelope, then returns exit 0.
//   * `--explain`     emit the action plan in the result envelope's
//                     `result.plan` field. May be combined with `--dry-run`
//                     (in which case no side effect happens) or run on its
//                     own (in which case the plan is emitted in addition
//                     to the real side effect; useful for audit logs).
//   * `--idempotency-key <KEY>`
//                     reserved for Lane G.6. In G.5 the flag is accepted
//                     and surfaced in the envelope so callers can adopt
//                     the surface today, but the underlying commit
//                     semantics land in G.6.
//
// Output envelope shape (JSON mode):
//   {
//     "ok": true,
//     "operation": "<op>",
//     "result": {
//        "dry_run": true,
//        "plan": ["step 1", "step 2", ...],
//        "idempotency_key": <string|null>
//     }
//   }
//
// Human mode prints a `[DRY-RUN] <op>` header followed by the plan steps.

use clap::Args;
use serde_json::json;

use crate::OutputFormat;

/// Per-mutate-subcommand `--dry-run` / `--explain` / `--idempotency-key`
/// block. Flatten this into the per-subcommand `Args` struct via
/// `#[command(flatten)]`.
#[derive(Args, Debug, Clone, Default)]
pub struct DryRunArgs {
    /// v1.3 Lane G.5: side-effect-free plan emission. No file writes, no
    /// network calls, no keyring operations. Returns exit 0 after emitting
    /// the structured plan envelope.
    #[arg(long, default_value_t = false)]
    pub dry_run: bool,

    /// v1.3 Lane G.5: include the action plan in the result envelope's
    /// `result.plan` field. Can be combined with `--dry-run`. When passed
    /// without `--dry-run`, the plan is emitted alongside the real action.
    #[arg(long, default_value_t = false)]
    pub explain: bool,

    /// v1.3 Lane G.5 / G.6: opaque caller-supplied key for at-most-once
    /// commit semantics. Accepted in G.5; surfaced in the envelope; the
    /// underlying commit replay semantics land in G.6.
    #[arg(long = "idempotency-key")]
    pub idempotency_key: Option<String>,
}

impl DryRunArgs {
    /// Returns `true` when the caller asked for plan-only execution. The
    /// caller's `run_*` function MUST short-circuit at this point and emit
    /// via [`emit_dry_run`] before performing any side effect.
    pub fn is_dry_run(&self) -> bool {
        self.dry_run
    }

    /// Returns `true` when the caller asked for plan emission (with or
    /// without dry-run mode).
    #[allow(dead_code)]
    pub fn is_explain(&self) -> bool {
        self.explain || self.dry_run
    }
}

/// Emit a dry-run plan envelope for `operation`. Returns exit code 0.
///
/// `plan` is an ordered list of human-readable plan steps; this is the
/// canonical side-effect-free surface for `--dry-run`. The envelope
/// schema is documented in `docs/json-schemas/cli/dry-run.output.json`.
pub fn emit_dry_run(
    format: OutputFormat,
    operation: &str,
    plan: &[&str],
    args: &DryRunArgs,
) -> i32 {
    let key_json = args
        .idempotency_key
        .as_deref()
        .map(|k| json!(k))
        .unwrap_or(json!(null));
    let envelope = json!({
        "ok": true,
        "operation": operation,
        "result": {
            "dry_run": true,
            "plan": plan,
            "idempotency_key": key_json,
        },
    });
    match format {
        OutputFormat::Json => {
            println!("{}", envelope);
        }
        OutputFormat::Yaml => {
            // v1.3 Lane G fix-up R2: yaml mirror of the dry-run envelope.
            match serde_yaml::to_string(&envelope) {
                Ok(s) => print!("{s}"),
                Err(e) => {
                    eprintln!("# yaml-encode-error: {e}");
                    println!("{envelope}");
                }
            }
        }
        OutputFormat::Human => {
            println!("[DRY-RUN] {operation}");
            for (i, step) in plan.iter().enumerate() {
                println!("  {idx}. {step}", idx = i + 1, step = step);
            }
            if let Some(k) = args.idempotency_key.as_deref() {
                println!("  idempotency_key: {k}");
            }
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_dry_run_reflects_flag() {
        let a = DryRunArgs {
            dry_run: true,
            ..Default::default()
        };
        assert!(a.is_dry_run());
        assert!(a.is_explain()); // dry_run implies explain
        let b = DryRunArgs::default();
        assert!(!b.is_dry_run());
        assert!(!b.is_explain());
    }

    #[test]
    fn explain_without_dry_run() {
        let a = DryRunArgs {
            explain: true,
            ..Default::default()
        };
        assert!(!a.is_dry_run());
        assert!(a.is_explain());
    }
}
