# Canonical Invariants (13)

`Revharness` の正規不変条件。各 invariant は `AGENTS.md` (inline anchor) と
`docs/manual/verification-truth-matrix.md` (row-level enforce) に対応する
表現が存在し、`scripts/`/`scripts/ci/` 配下の deterministic check command で
機械検証される。

本書は AGENTS.md inline section + verification-truth-matrix の散在 row を
**1 箇所に統合する on-disk canonical anchor** であり、reviewer / orchestrator /
adopter が「13 invariant の完全集合」を 1 read で得るための index として機能する。

- 更新方針: 新規 invariant は必ず (1) AGENTS.md inline anchor、
  (2) `docs/manual/verification-truth-matrix.md` row、(3) 本書 section、の 3 か所同時更新。
- どれか欠けた状態は I-9 (dispatch-topology lint) / I-12 (smoke-gated dual-LGTM)
  の双方で reject される構造的不整合とみなす。
- 13 番目以降の invariant が追加された場合、本書 §Index と §Per-invariant detail
  を同 commit で同期する。

## Index

| ID | 名前 | canonical surface | deterministic check | severity |
|---|---|---|---|---|
| I-1 | Privacy hard gate (pre-commit) | `scripts/rev-harness-path-leak-guard.sh` | `bash scripts/rev-harness-path-leak-guard.sh` exit 0 | blocks commit |
| I-2 | Tier 1 capsule byte-stable | `harness-rust/crates/semantic-mcp/src/capsule.rs` | `bash scripts/ci/tier1-scope-guard.sh` exit 0 | blocks release |
| I-2b | Shipped binary privacy stable | `harness-rust/target/release/semantic-mcp` | `bash scripts/ci/release-binary-privacy-scan.sh` exit 0 | blocks release tag |
| I-3 | Dual LGTM on-disk evidence | `.agent/state/dual_lgtm_state.json` | `bash scripts/dual-lgtm-validate.sh --strict` exit 0 | blocks phase_advance |
| I-4 | Graceful-shutdown fail-open | `.claude/hooks/agent-graceful-shutdown.sh` | `bash .claude/hooks/agent-graceful-shutdown.sh --self-test` exit 0 | runtime safety |
| I-5 | Wrapper help / behavior parity | `test/golden/{codex,claude}-wrapper-help.txt` | `bash scripts/ci/check-wrapper-help-parity.sh` exit 0 | blocks tag |
| I-6 | file_owner_token exclusivity | ExecPlan `dispatch_topology` + lint | `bash scripts/ci/check-execplan-topology.sh --strict` exit 0 | blocks dispatch |
| I-7 | PARALLEL_QUIESCE sweep gate | `agent-graceful-shutdown.sh` 6 関数 + janitor + safe-dispatch | hook env-gating test exit 0 | runtime safety |
| I-8 | Pre/Post SHA256 snapshot | `scripts/safe-dispatch.sh` + 3 snapshot hooks | snapshot test exit 0 | runtime safety |
| I-9 | Dispatch-topology lint | `scripts/ci/check-execplan-topology.sh` | (= I-6 と同 command) | blocks dispatch |
| I-10 | Call out, never absorb | `scripts/rev-harness` facade + adopter lifecycle | sha256 immutable check (4 child untouched) | governance |
| I-11 | Destructive opt-in | `--apply --ack-rebuild-cost` 等 explicit flag | janitor build-cleanup test exit 0 | runtime safety |
| I-12 | Smoke-gated dual-LGTM | `scripts/state-transition-guard.sh` joint axis | `phase-done-smoke.sh --phase <X>` exit 0 → `lgtm_stage=final` allow | blocks phase_advance |
| I-13 | Semantic MCP wire contract | `.mcp.json.template` + MCP configs | `bash scripts/ci/mcp-wire-contract-check.sh --strict` exit 0 | blocks release |

## Per-invariant detail

### I-1 Privacy hard gate (pre-commit)
**Surface**: `scripts/rev-harness-path-leak-guard.sh` + `.git/hooks/pre-commit` symlink.
**Trigger**: every `git commit` (pre-commit hook).
**Check**: `bash scripts/rev-harness-path-leak-guard.sh` exit 0
(`scanned_files=N, findings=0`).
**Failure mode**: exit non-zero with literal patterns + line numbers; commit aborted.
**Soft layer companion**: I-12 inferred + `.claude/hooks/path-leak-advise.sh`
(advisory, JSONL row, fail-open).
**Origin**: pre-HSDI baseline; reaffirmed Phase D as the "hard" half of a 2-layer model.
**AC anchor**: AGENTS.md privacy section / verification-truth-matrix.md
"path leak / privacy" rows.

### I-2 Tier 1 capsule byte-stable
**Surface**: `harness-rust/crates/semantic-mcp/src/capsule.rs` (Tier 1 capsule emitter).
**Trigger**: every Rust workspace change that touches semantic-mcp.
**Check**: `bash scripts/ci/tier1-scope-guard.sh` exit 0. The script enforces
byte-stable Tier 1 capsule output and rejects scope creep into Tier 2.
**Failure mode**: any non-additive change to Tier 1 capsule schema, content order,
or formatting fails the gate; release blocked.
**Origin**: Wave 21 Phase F; codified Tier 1 vs Tier 2 boundary.
**AC anchor**: AGENTS.md semantic-mcp section; `docs/sem/tier2-markdown-medium.md` §1.

### I-2b Shipped binary privacy stable
**Surface**: `harness-rust/target/release/semantic-mcp` (compiled artifact),
configured by `harness-rust/Cargo.toml [profile.release]` and
`harness-rust/.cargo/config.toml`.
**Trigger**: every release tag candidate; runs after `cargo build --release`.
**Check**: `bash scripts/ci/release-binary-privacy-scan.sh` exit 0.
Internally: `strings target/release/semantic-mcp | grep -E '/Users/|/home/|contact_dev|.cargo/registry/src|.rustup/toolchains'` = 0 hits.
**Failure mode**: source-level `path-leak-guard` (I-1) does NOT cover compiled
strings, debug symbols, or panic-message line-info. I-2b closes that hole.
**Origin**: HSDI Phase H T-H-4 / T-H-4a / T-H-4b.
**AC anchor**: AGENTS.md §I-2b; `docs/manual/verification-truth-matrix.md` row 1.

### I-3 Dual LGTM on-disk evidence
**Surface**: `.agent/state/dual_lgtm_state.json` (paths-manifest schema,
Phase H T-H-2 update).
**Trigger**: every reviewer verdict submission; every phase advance attempt.
**Check**: `bash scripts/dual-lgtm-validate.sh --strict` exit 0. Validates that
both Opus and Codex artifact files exist, sha256 matches recorded value,
and verdict markdown follows the strict schema.
**Failure mode**: text-only return without artifact pair, sha256 mismatch,
or missing verdict markdown → REJECT.
**Origin**: HSDI Phase E (Dual-LGTM transition guard).
**AC anchor**: `docs/roles/reviewer.md` verdict markdown contract;
verification-truth-matrix "dual LGTM" rows.

### I-4 Graceful-shutdown fail-open
**Surface**: `.claude/hooks/agent-graceful-shutdown.sh` (6 functions covering
PARALLEL_QUIESCE gate, snapshot-stash, owner_agent_id propagation, bail GC).
**Trigger**: every agent shutdown event (Stop hook).
**Check**: `bash .claude/hooks/agent-graceful-shutdown.sh --self-test` exit 0.
**Failure mode**: hook MUST fail open (exit 0 with warning JSONL row) when a
non-critical subsystem errors, so a buggy hook never blocks orchestration.
Critical assertion failures (e.g., quiesce-skip race) emit a `silent_bail.jsonl`
row but still return 0 to the harness.
**Origin**: HSDI Phase A (commit 0042120) restoration + production migration.
**AC anchor**: AGENTS.md graceful-shutdown section.

### I-5 Wrapper help / behavior parity
**Surface**: byte-pinned golden files
`test/golden/{codex,claude}-wrapper-help.txt` + wrappers
`scripts/{codex,claude}-wrapper.sh` + 3 shims
`scripts/codex-wrapper-{xhigh,high,medium}.sh`.
**Trigger**: every wrapper-touching commit and every release tag candidate.
**Check**: `bash scripts/ci/check-wrapper-help-parity.sh` exit 0.
**Failure mode**: any drift in help text, role merge semantics, or shim role-hint
behavior (`CODEX_WRAPPER_SHIM_ROLE` env) fails the gate; tag blocked.
**Origin**: HSDI Phase C (wrapper merge + help parity; commit f8688ef).
**AC anchor**: verification-truth-matrix wrapper-parity rows.

### I-6 file_owner_token exclusivity
**Surface**: ExecPlan `dispatch_topology` block + lint
`scripts/ci/check-execplan-topology.sh`.
**Trigger**: every parallel dispatch ExecPlan.
**Check**: `bash scripts/ci/check-execplan-topology.sh --strict` exit 0.
Enforces that no two concurrent agents declare overlapping
`file_owner_token` values.
**Failure mode**: overlapping tokens → REJECT before dispatch (no agent spawn).
**Origin**: HSDI Phase B Self-Defense Layer (commit d660e2d).
**AC anchor**: AGENTS.md dispatch-topology section.

### I-7 PARALLEL_QUIESCE sweep gate
**Surface**: `agent-graceful-shutdown.sh` 6 functions +
`scripts/rev-harness-janitor.sh` + `scripts/safe-dispatch.sh`.
**Trigger**: every janitor sweep, every shutdown event, every safe-dispatch call.
**Check**: hook env-gating test exit 0 — under `REVHARNESS_PARALLEL_QUIESCE=1`,
the sweep MUST recognize quiesce state and skip destructive actions.
**Failure mode**: ignoring quiesce flag during parallel dispatch can GC a
sibling agent's stash → cascading bail. I-7 prevents that.
**Origin**: HSDI Phase B; reaffirmed Phase A graceful-shutdown integration.

### I-8 Pre/Post SHA256 snapshot
**Surface**: `scripts/safe-dispatch.sh` + 3 hooks
`.claude/hooks/snapshot-{pre,post,stop}.sh` +
`scripts/snapshot-dispatch.sh`.
**Trigger**: every safe-dispatch invocation.
**Check**: snapshot test exit 0 — pre-snapshot sha256 of `file_owner_token`
files must match post-snapshot for agents that declared NO-WRITE; for WRITE
agents the post sha256 must differ in exactly the declared files.
**Failure mode**: snapshot mismatch in non-declared files → emit
`silent_bail.jsonl` row + abort downstream agent.
**Origin**: HSDI Phase B (commit d660e2d).

### I-9 Dispatch-topology lint
**Surface**: `scripts/ci/check-execplan-topology.sh`.
**Trigger**: every ExecPlan commit; runs in CI and pre-dispatch.
**Check**: shares command line with I-6 (same script). Validates structural
shape of `dispatch_topology` block including `file_owner_token`,
`worker_outcome` vocabulary, `evidence_destination` placement.
**Failure mode**: malformed or missing `dispatch_topology` block → REJECT.
**Origin**: HSDI Phase B; complements I-6.

### I-10 Call out, never absorb
**Surface**: `scripts/rev-harness` facade +
`scripts/rev-harness-{install,uninstall,repair,adopter-setup,mcp-wire}.sh` +
adopter lifecycle.
**Trigger**: every adopter setup, every harness facade invocation.
**Check**: sha256 immutable check — the 4 child scripts (`install`, `verify`,
`repair`, `uninstall`) must NOT mutate the adopter project state during
inspect-only modes. Destructive operations require I-11 opt-in.
**Failure mode**: facade absorbing adopter state (e.g., overwriting an existing
project_id, deleting an adopter file without `--apply`) → REJECT.
**Origin**: HSDI Phase G Adopter Lifecycle Manager (commit a0cbba9).

### I-11 Destructive opt-in
**Surface**: every destructive command requires an explicit double-flag pair:
`--apply` + a domain-specific acknowledgement flag (e.g.,
`--ack-rebuild-cost` for `rev-harness clean`).
**Trigger**: every destructive subcommand (clean, uninstall, upgrade).
**Check**: janitor build-cleanup test exit 0 — invoking destructive command
without both flags must dry-run and exit 0; with both flags must apply and
log the action.
**Failure mode**: silent destructive default → REJECT (gate fails).
**Origin**: HSDI Phase G; canonicalised across `rev-harness-janitor.sh`,
`rev-harness-uninstall.sh`, and `rev-harness-upgrade.sh`.

### I-12 Smoke-gated dual-LGTM
**Surface**: `scripts/state-transition-guard.sh` joint axis
`(provisional/confirmed) × (unverified/final)` over
`.agent/state/dual_lgtm_state.json`.
**Trigger**: every phase advance, every `state.json.phase = done` write.
**Check**: `bash scripts/ci/phase-done-smoke.sh --phase <X>` exit 0 →
`lgtm_stage=final` allowed → `state-transition-guard --require-lgtm-final`
exit 0 → phase advance permitted.
**Failure mode**: agent-based 9+/10 dual-LGTM is *provisional* only.
Without a successful `phase-done-smoke.sh` run sourcing
`smoke_evidence_sha256` from a JSONL row, `lgtm_stage` stays `unverified`
and `state.json.phase` cannot advance to `done`.
**Origin**: HSDI Phase H (commit ebab232 + tag `hsdi-final`); closes the
structural gap observed across HSDI Phases A-G where agent dual-LGTM missed
production smoke failures.
**AC anchor**: AGENTS.md §I-12; `docs/manual/verification-truth-matrix.md` row 2.

### I-13 Semantic MCP wire contract

**Required**: Adopter MCP server config (either `.claude/settings.json` or `.mcp.json`) that wires the harness's semantic-mcp MUST use:
- server name (key): `semantic-mcp` (NOT legacy `semantic`)
- command: ABSOLUTE path to harness launcher (`<harness-root>/scripts/launch-semantic-mcp.sh`) substituted from the canonical `.mcp.json.template`
- env: no `SEMANTIC_MCP_PROJECT_ID` sentinel (project_id auto-resolves via adopter-PWD per 0.0.23)

**Escape valve**: If the harness launcher is unavailable as an absolute path (e.g., future `homebrew install rev-harness` exposes `semantic-mcp` on PATH), command MAY be the bare binary name `semantic-mcp` PROVIDED the runtime `which semantic-mcp` resolves to a canonical install. The escape valve is OPT-IN per adopter via `_BARE_BINARY_OK: true` marker in the same `.mcp.json` block. Default contract is absolute path.

**Forbidden**: Legacy `semantic` key, relative `./scripts/launch-semantic-mcp.sh` path, or `SEMANTIC_MCP_PROJECT_ID` env entry MUST NOT appear in adopter MCP config.

**Self-applies**: rev_harness's OWN `.claude/settings.json` and `.codex/config.toml` MUST satisfy this contract on every tagged release.

**Enforcement**: `scripts/ci/mcp-wire-contract-check.sh` (warn-only in 0.0.24, --strict in 0.0.25+).

## Cross-references

- `AGENTS.md` — inline invariant anchors (I-2b §128, I-12 §133).
- `docs/manual/verification-truth-matrix.md` — row-level enforce table
  (I-2b + I-12 rows).
- `scripts/state-transition-guard.sh` — I-3 + I-12 joint enforcement.
- `scripts/ci/release-binary-privacy-scan.sh` — I-2b runtime gate.
- `scripts/ci/phase-done-smoke.sh` — I-12 smoke gate.
- `scripts/ci/mcp-wire-contract-check.sh` — I-13 MCP wire contract gate.
- `scripts/ci/check-execplan-topology.sh` — I-6 + I-9 (shared).
- `scripts/dual-lgtm-validate.sh` — I-3 reviewer artifact validator.
- `.claude/hooks/agent-graceful-shutdown.sh` — I-4 + I-7 runtime hook.
- `.claude/hooks/snapshot-{pre,post,stop}.sh` + `scripts/safe-dispatch.sh` — I-8 snapshot.
- `scripts/rev-harness` facade — I-10 + I-11 adopter lifecycle.
- `scripts/rev-harness-path-leak-guard.sh` + `.claude/hooks/path-leak-advise.sh` —
  I-1 (hard) + soft companion layer.

## Update protocol

新規 invariant を追加するときは、必ず同一 commit 内で:

1. `AGENTS.md` に inline `### I-N (名前)` anchor を追加する。
2. `docs/manual/verification-truth-matrix.md` の Invariant Acceptance Gates
   table に 1 row 追加する。
3. 本書の §Index と §Per-invariant detail に新規 section を追加する。

3 か所の同期は `scripts/ci/check-execplan-topology.sh` 拡張版または専用
lint で自動検知することが推奨される (Wave 22 候補 →
`docs/manual/roadmap-wave-22.md`)。
