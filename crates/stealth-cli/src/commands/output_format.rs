// SPDX-License-Identifier: MIT
//
// v1.3 Lane G.4: shared `--output-format` flag for per-subcommand override of
// the global `--format`. Flattened into each subcommand's `Args` struct.
//
// Why a per-subcommand override exists at all, given the global `--format`:
//   * Operationally, agents/scripts prefer the canonical name
//     `--output-format` (matches `kubectl`, `gh`, `aws`, `helm`, …) and want
//     to place it *after* the subcommand name. clap's `global = true` flag is
//     positional-order tolerant, but the per-subcommand variant makes the
//     intent obvious at the call site (`rev-stealth spider … --output-format
//     json`) and shows up under the subcommand's `--help` rather than only
//     the root `--help`.
//   * Two subcommands extend the value enum locally (`doctor` adds `text`;
//     `config` adds `text`/`yaml`), so they keep their own `--output-format`
//     definition with a richer enum. Everywhere else uses this shared shim
//     against the same `OutputFormat` enum as the global.
//
// Collision avoidance: clap derives arg ids from field names; the global is
// `format` (id `format`). This struct uses field name `output_format` with an
// explicit unique `id = "<subcmd>_output_format"` per call site (set by the
// caller via the flattened struct), but since each subcommand instantiates
// its own owned copy via `#[command(flatten)]`, clap scopes the arg id to
// the subcommand and there is no collision with the global `--format`.

use clap::Args;

use crate::OutputFormat;

/// Per-subcommand `--output-format` override of the global `--format`.
///
/// `None` means "use the global `--format` value"; `Some(_)` means the user
/// explicitly passed `--output-format` on this subcommand and the local
/// choice wins.
///
/// Resolve via [`OutputFormatOverride::resolve`] in the subcommand's `run`
/// function, passing the global `Cli.format` as the fallback.
#[derive(Args, Debug, Clone, Default)]
pub struct OutputFormatOverride {
    /// Output format for this subcommand: `human` (default) or `json`.
    /// Shadows the global `--format` for this invocation. Same value enum
    /// as the global flag; the JSON output is documented under
    /// `docs/json-schemas/cli/<subcommand>.output.json`.
    #[arg(long = "output-format", value_enum)]
    pub output_format: Option<OutputFormat>,
}

impl OutputFormatOverride {
    /// Resolve the effective output format: the local override if present,
    /// otherwise the global `--format` value.
    pub fn resolve(&self, global: OutputFormat) -> OutputFormat {
        self.output_format.unwrap_or(global)
    }
}
