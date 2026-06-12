# Canonical Invariants

`Revharness` の正規不変条件。各 invariant は `AGENTS.md` (inline anchor) と
`docs/manual/verification-truth-matrix.md` (row-level enforce) に対応する
表現が存在し、`scripts/`/`scripts/ci/` 配下の deterministic check command で
機械検証される。

本書は AGENTS.md inline section + verification-truth-matrix の散在 row を
**1 箇所に統合する on-disk canonical anchor** であり、reviewer / orchestrator /
adopter が canonical invariant set を 1 read で得るための index として機能する。

- Numbering policy: retired core IDs are tombstoned and never reused.
- Cross-references to retired IDs keep resolving to tombstone sections.
- New, retired, and addon invariants update (1) AGENTS.md invariant index,
  (2) `docs/manual/verification-truth-matrix.md` row, and (3) this document in
  one slice.
- Missing synchronization is a structural inconsistency rejected by
  `scripts/ci/invariant-sync-check.sh --strict`.
- Transitional clause: the existing I-2, I-2b, and I-13 gate scripts remain
  blocking until the P7/P8 slices land.

## Index

| ID | 名前 | canonical surface | deterministic check | severity |
|---|---|---|---|---|
| I-1 | Privacy hard gate (pre-commit) | `scripts/rev-harness-path-leak-guard.sh` | `bash scripts/rev-harness-path-leak-guard.sh` exit 0 | blocks commit |
| I-2 | Tombstone: retired semantic capsule core invariant | tombstone section below | `bash scripts/ci/tier1-scope-guard.sh` remains transitional blocker until P7/P8 | blocks release during transition |
| I-2b | Shipped-artifact privacy stable | `docs/SHIPPED_ARTIFACTS.md` | `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md` exit 0 | blocks release tag |
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
| I-13 | Tombstone: retired mandatory semantic MCP core wiring | tombstone section below | `bash scripts/ci/mcp-wire-contract-check.sh --strict` remains transitional blocker until P7/P8 | blocks release during transition |

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

### I-2 Tombstone: retired semantic capsule core invariant
**State**: retired from the core invariant set; ID is tombstoned and never reused.
**Core replacement**: INDEX validation plus source reads and deterministic-check
evidence. Core acceptance must never depend on semantic capsule output.
**Cross-reference behavior**: existing references to I-2 resolve here.
**Transitional check**: `bash scripts/ci/tier1-scope-guard.sh` remains blocking
until the P7/P8 slices land, because the current release gate still enforces it.
**Addon successor**: `Addon-I-2` preserves semantic capsule byte-stability for
the opt-in semantic addon.
**Origin**: Wave 21 Phase F; retired from core by the index-first migration.

### I-2b Shipped-artifact privacy stable
**Surface**: every shipped core executable/archive listed in
`docs/SHIPPED_ARTIFACTS.md`.
**Trigger**: every release tag candidate.
**Check**: `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md`
exit 0. The scan uses the same leak pattern class as
`scripts/ci/release-binary-privacy-scan.sh`: `/Users/`, `/home/`,
`contact_dev`, `.cargo/registry/src/`, and `.rustup/toolchains/`.
**Conditional activation**: if a release ships no core executable/archive, this
gate fails unless the manifest records `no shipped core artifact` with reviewer
evidence. Empty implicit success is forbidden.
**Failure mode**: source-level `path-leak-guard` (I-1) does NOT cover compiled
strings, debug symbols, panic-message line-info, or packaged archive contents.
I-2b closes that hole for shipped artifacts.
**Transitional check**: the current `semantic-mcp` scan via
`bash scripts/ci/release-binary-privacy-scan.sh` remains blocking until addon CI
has an equally blocking gate; this split does not weaken the release tag gate.
**Addon companion**: `Addon-I-2b` keeps the semantic-mcp binary scan while the
semantic binary is addon-pending or addon-shipped.
**Origin**: HSDI Phase H T-H-4 / T-H-4a / T-H-4b; generalized by the
index-first migration.

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

### I-13 Tombstone: retired mandatory semantic MCP core wiring

**State**: retired from the core invariant set; ID is tombstoned and never reused.
**Core rule**: normal core operation requires no mandatory semantic autostart,
launcher path, MCP server config, semantic-mcp key, or project_id sentinel.
**Core proof direction**: core-only smoke coverage must prove representative
docs, wrapper, and gate tasks can run with semantic MCP absent or disabled.
**Cross-reference behavior**: existing references to I-13 resolve here.
**Transitional check**: `bash scripts/ci/mcp-wire-contract-check.sh --strict`
remains blocking until the P7/P8 slices land, because current configs and
release gates still enforce semantic MCP wiring.
**Addon successor**: `Addon-I-13` governs opt-in semantic addon wiring.

## Addon invariants (semantic addon)

Addon invariants are not core requirements. They are authoritative when the
semantic addon is enabled, shipped, or release-gated.

### Addon-I-2 Semantic capsule byte-stability
**Surface**: `harness-rust/crates/semantic-mcp/src/capsule.rs` and semantic
capsule golden output.
**Check**: `bash scripts/ci/tier1-scope-guard.sh` exit 0 until replaced by an
addon gate with equal blocking strength.
**Rule**: the semantic addon preserves byte-stable Tier 1 capsule output and
keeps Tier 2 scope creep out of Tier 1 payloads.
**Non-core boundary**: semantic capsule output is discovery acceleration only
and is never core acceptance evidence.

### Addon-I-2b Semantic-mcp binary privacy stable
**Surface**: `harness-rust/target/release/semantic-mcp` while it is
addon-pending or addon-shipped.
**Check**: `bash scripts/ci/release-binary-privacy-scan.sh` exit 0 until
`semantic-addon-gate.sh --strict` or an equivalent addon release gate supersedes
it.
**Rule**: shipped semantic addon binaries must scan clean for the same leak
pattern class as I-2b.

### Addon-I-13 Opt-in semantic MCP wiring governance
**Surface**: opt-in semantic MCP config in `.claude/settings.json`,
`.codex/config.toml`, `.mcp.json.template`, and adopter MCP config when the
addon is enabled.
**Rule**: enabled semantic addon wiring must use the `semantic-mcp` key, a valid
launcher/binary contract, no `SEMANTIC_MCP_PROJECT_ID` legacy sentinel, and
explicit legacy key detection.
**Planned check**: `scripts/ci/addon-absent-or-compliant-check.sh --semantic`
is the P8 deliverable. Do not create it before P8.
**Transitional check**: `bash scripts/ci/mcp-wire-contract-check.sh --strict`
remains blocking until the P7/P8 slices land.

## Cross-references

- `AGENTS.md` — invariant index and addon invariant reference table.
- `docs/manual/verification-truth-matrix.md` — row-level enforce table.
- `scripts/state-transition-guard.sh` — I-3 + I-12 joint enforcement.
- `scripts/ci/shipped-artifact-privacy-scan.sh` — I-2b shipped-artifact gate.
- `scripts/ci/release-binary-privacy-scan.sh` — Addon-I-2b transitional gate.
- `scripts/ci/phase-done-smoke.sh` — I-12 smoke gate.
- `scripts/ci/tier1-scope-guard.sh` — Addon-I-2 transitional gate.
- `scripts/ci/mcp-wire-contract-check.sh` — I-13 / Addon-I-13 transitional gate.
- `scripts/ci/check-execplan-topology.sh` — I-6 + I-9 (shared).
- `scripts/dual-lgtm-validate.sh` — I-3 reviewer artifact validator.
- `.claude/hooks/agent-graceful-shutdown.sh` — I-4 + I-7 runtime hook.
- `.claude/hooks/snapshot-{pre,post,stop}.sh` + `scripts/safe-dispatch.sh` — I-8 snapshot.
- `scripts/rev-harness` facade — I-10 + I-11 adopter lifecycle.
- `scripts/rev-harness-path-leak-guard.sh` + `.claude/hooks/path-leak-advise.sh` —
  I-1 (hard) + soft companion layer.

## Update protocol

新規 invariant、addon invariant、または tombstone を追加するときは、必ず同一
commit 内で:

1. `AGENTS.md` の invariant index または addon invariant reference table を更新する。
2. `docs/manual/verification-truth-matrix.md` の Invariant Acceptance Gates
   table に対応 row を追加する。
3. 本書の §Index と §Per-invariant detail に新規 section を追加する。

3 か所の同期は `scripts/ci/invariant-sync-check.sh --strict` で検知する。
