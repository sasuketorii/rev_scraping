# `rev-stealth` CLI JSON-Output Schemas (v1.3 Lane G.4)

Draft-07 JSON Schemas for every `--output-format json` payload emitted by the
`rev-stealth` CLI. Lane G.4 of the v1.3 "Black-Belt CLI" ExecPlan elevates
`--output-format` to a first-class flag on every top-level subcommand and
locks the JSON contract via these schemas.

## `--output-format` Matrix

| Subcommand        | Where it lives                | Accepted values        | Default |
|-------------------|-------------------------------|------------------------|---------|
| `captcha *`       | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `browser *`       | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `vpn *`           | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `spider`          | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `relocate`        | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `cf-evaluate`     | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `auth *`          | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `measure`         | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `hermes *`        | Per-subcommand (G.4 shim)     | `human`, `json`        | inherits global |
| `doctor`          | Native (pre-dates G.4)        | `json`, `text`         | `json` |
| `config *`        | Native (pre-dates G.4)        | `text`, `json`, `yaml` | `text` |

The global `--format {human|json}` (positional-tolerant) remains available for
v1.2.x backward compatibility. When both are present, the per-subcommand
`--output-format` wins inside its subtree.

## Why two enum extensions exist

* `doctor --output-format text` predates the unified shim: it was the first
  command to introduce `--output-format` (HANDOFF v0.0.4 → v1.0.0 §2.1).
  `text` is the human-readable variant; `json` is the agent-readable variant.
* `config --output-format yaml` predates the unified shim (P6.1) and is the
  only command whose payload is meaningful as YAML (round-trippable layered
  config). `text` is the human-readable variant; `json` and `yaml` are
  structured.

Everywhere else, `human` is the human-readable variant and `json` is the
structured-agent variant — the same enum as the global `--format` flag.

## Schema layout

Each top-level subcommand owns one schema file `<subcommand>.output.json`,
written as JSON Schema Draft-07. Action-bearing subcommands
(`captcha`/`browser`/`vpn`/`auth`/`hermes`/`config`) describe a `oneOf` over
their actions in a single file rather than fragmenting into per-action files
— this keeps the inventory walkable at the top level.

Spider's payload is large (36 flags x sub-modules); its schema is sectioned
internally via `$defs` (auth / cf / recipe / example) per the G.1 review.

### Envelope contracts (three flavours)

The schemas document what each emitter *actually* writes, not an aspirational
shape. Three envelope flavours exist in the current codebase:

1. **Shared `{ok, operation, result|exit_code+error}` envelope** —
   `captcha`, `browser`, `vpn`, `spider`, `relocate`, `cf-evaluate`, `auth`,
   `measure`. Defined in each subcommand's local `emit_ok` / `emit_err`
   helpers (call signature: `emit_ok(format, operation, payload)`). The
   operation string is `"<noun>.<verb>"` for action-based commands
   (`captcha.solve`, `vpn.rotate`) and just `"<noun>"` for single-shot
   commands (`spider`, `measure`, `relocate`, `cf-evaluate`).

2. **Hermes envelope `{kind, action, status, report|error}`** — pre-G.4
   contract owned by `crates/stealth-cli/src/commands/hermes.rs`. `kind` is
   always `"hermes"`, `status` is `"ok"` / `"error"`. The error envelope is
   written to STDERR, not STDOUT.

3. **No envelope at all** — `doctor` (raw `DoctorReport` / `DeepReport` /
   `Vec<DeepCheck>` depending on flags) and `config` (each `run_*` builds
   its own untagged shape). Additionally, `auth login` / `auth refresh`
   *success* falls into this bucket: the CLI inherits stdout from the
   external `rev-auth` helper, which prints a flat
   `{ok, profile, domain, cookie_count, expires_at, saved_to}` shape (see
   `crates/stealth-auth/src/bin/rev_auth.rs::SuccessJson`). The CLI's
   shared envelope is only used for the `auth login`/`refresh` ERROR paths
   (policy / AUP / VPN-guard / spawn failure before the helper runs).

These mismatches predate Lane G.4. G.4 documents them honestly rather than
forcibly normalising them — a future ExecPlan slice would be required to
collapse all subcommands onto one envelope, and that's not a strict-additive
change.

### `anyOf` vs `oneOf` (round-2 calibration)

Three schemas (`auth`, `doctor`, `config`) use `anyOf` rather than `oneOf` at
the top level because their per-action shapes structurally overlap (e.g.
`auth.delete`'s `{profile, deleted}` payload structurally also matches the
looser `auth.show` payload that only requires `profile`; `config validate`'s
`{ok, reports, read_errors}` payload also matches the write-action fallback
that only requires `{ok}`). Live emission disambiguates via the CLI action
name; the schema's job is to accept any documented branch — not to
distinguish them post-hoc. The remaining envelope-style schemas (`captcha`,
`browser`, `vpn`, `spider`, `relocate`, `cf-evaluate`, `measure`, `hermes`)
keep `oneOf` because the OK and ERR envelopes are disjoint (they differ on
the `ok` discriminator's `const` value).

## CI gate

`crates/stealth-cli/tests/output_format_coverage.rs` programmatically asserts
that every top-level subcommand parses `--output-format json` without panic.
Drift between the CLI surface and these schemas is caught by that test plus
the human-curated `cli-public-api.snapshot.json` snapshot under
`.agent/v1.3/`.

## Schemas in this directory

| File                          | Subcommand    |
|-------------------------------|---------------|
| `captcha.output.json`         | `captcha`     |
| `browser.output.json`         | `browser`     |
| `vpn.output.json`             | `vpn`         |
| `spider.output.json`          | `spider`      |
| `relocate.output.json`        | `relocate`    |
| `cf-evaluate.output.json`     | `cf-evaluate` |
| `auth.output.json`            | `auth`        |
| `measure.output.json`         | `measure`     |
| `hermes.output.json`          | `hermes`      |
| `doctor.output.json`          | `doctor`      |
| `config.output.json`          | `config`      |

Schemas under the older `docs/json-schemas/` root (without the `cli/` prefix)
are MCP-tool output schemas, not CLI output schemas, and remain canonical for
the MCP surface.
