# HSDI Architecture Overview

> Harness Self-Defense Initiative (8-phase, 2026-05-24 .. 2026-05-26, dual-LGTM 9+/10 with smoke-gated).

This document explains HSDI as architecture, not as a phase diary. The intended
reader is an AI orchestrator that must decide what to trust, what to delegate,
what to verify, and where to stop when the harness itself is part of the failure
surface.

HSDI is four defensive layers around RevHarness: self-defense, wrapper trust,
adopter lifecycle, and smoke verification. The phase history matters as
provenance, but the operational model is functional-area first.

## 1. なぜ HSDI が必要だったか

HSDI became necessary because ordinary "agent succeeded" signals were not
enough. The harness already had deterministic checks, role-specific review, and
evidence conventions, but the incidents showed that the orchestration substrate
can damage the work it is supposed to protect.

The fix was not one more reviewer prompt. The fix was to split trust boundaries
and make each boundary mechanically verifiable.

### G1: Vendor API silent bail

G1 is the silent-bail class where a wrapper, hook, or vendor API edge case exits
in a way that looks graceful but loses work or bypasses evidence. The Phase A
graceful-shutdown self-stash incident is the canonical example.

The wrapper EXIT trap invoked a new shutdown hook before the hook's own safety
boundary was complete. That hook then stashed in-flight production files from
the host checkout, including the files that defined the hook path itself.

The failure looked like cleanup, not deletion. HSDI therefore treats graceful
shutdown, bail handling, and wrapper exit behavior as security-sensitive
surfaces.

### G2: Parallel agent race

G2 is the concurrent-sweep and dispatch-overlap class. In a multi-agent run,
one worker's cleanup, snapshot, or hook can collide with another worker's
declared ownership unless topology is checked before dispatch.

Recovering files from bail stashes is not a safety model. The system must
prevent a sweep from crossing a parallel dispatch window unless the quiesce
contract says it is safe.

That is why `file_owner_token`, PARALLEL_QUIESCE, `owner_agent_id`, and
pre/post SHA256 snapshots became architectural primitives.

### G3: Agent-based reviewer LGTM が production smoke を逃す reviewer-process gap

G3 is the reviewer-process gap. Seven phases received independent agent-based
dual-LGTM scores of 9+/10, yet a fresh-adopter smoke later found six defects.

The reviews were useful hypotheses about static correctness. They were not
proof that `rev-harness install` writes into the adopter target, that
`rev-harness clean` is reachable, or that the shipped binary scans clean.

HSDI therefore demotes agent LGTM to provisional evidence until an end-to-end
smoke gate proves the production path. This is the purpose of I-12.

## 2. 解決した 4 つの architectural layer

HSDI's layers are intentionally functional. An orchestrator should first ask
which trust boundary is being touched, then apply the layer that owns that
boundary.

### Layer 1: Self-Defense Layer (G1 + G2 cover)

The Self-Defense Layer protects the harness while agents are running. It exists
because wrappers, hooks, janitors, snapshotters, and dispatchers all execute
while the worktree may contain uncommitted production changes.

If those components clean, stash, or rewrite without topology awareness, they
become part of the incident. This layer makes runtime mutation explicit, scoped,
and observable.

- `agent-graceful-shutdown.sh`
- 6-function PARALLEL_QUIESCE gate.
- Fail-open behavior for non-critical hook failures.
- Evidence emission instead of orchestration blockage on advisory failure.
- `safe-dispatch.sh`
- Child env injection for dispatch-window safety.
- Pre/post SHA256 snapshot around declared ownership.
- Scoped quiesce injection for wrapper children.
- Detection of unexpected movement before reviewer interpretation.
- `harness-bg-spawn.sh`
- Atomic `owner_agent_id` stamping.
- Durable owner metadata for background work.
- Reduced ambiguity across concurrent agents.
- `snapshot-{pre,post,stop}.sh` hooks
- Pre-dispatch, post-dispatch, and stop-event evidence.
- Hash comparison between declared write intent and actual changes.
- Durable record for silent-bail and no-write investigations.
- `state-transition-guard.sh`
- Atomic transition enforcement.
- Rejection of illegal phase or LGTM-state movement.
- Later enforcement point for I-12 finality.
- New invariants: I-6/I-7/I-8/I-9.
- I-6: `file_owner_token` exclusivity.
- I-7: PARALLEL_QUIESCE sweep gate.
- I-8: pre/post SHA256 snapshot.
- I-9: dispatch-topology lint.

### Layer 2: Wrapper Trust Layer (silent bail 系)

The Wrapper Trust Layer protects the boundary between user intent and the agent
runtime. Wrappers look like launch plumbing, but they control role selection,
shim defaults, logging, help output, and exit behavior.

If wrappers silently reinterpret a role or bail after partial state, the
downstream failure can look like an ordinary agent failure. This layer makes
wrapper behavior byte-pinned and parity-checked.

- `parse_wrapper_args --role` merge-on-equal
- Resolves shim role duplication without dying on equivalent role hints.
- Preserves explicit role intent when shim and user flag agree.
- Keeps role behavior deterministic across wrapper families.
- `CODEX_WRAPPER_SHIM_ROLE` env hint propagation
- Carries shim role intent through the wrapper boundary.
- Lets parity tests compare shim and direct wrapper paths.
- Avoids hidden drift between convenience entrypoints.
- `_shim-log.sh` privacy redact
- Redacts sensitive values before wrapper diagnostics become evidence.
- Keeps debugging useful without leaking secrets or private payloads.
- Supports the I-1 privacy posture.
- Wrapper help golden + parity CI
- Pins Codex and Claude wrapper help output.
- Verifies wrapper and shim behavior parity.
- Converts wrapper drift into deterministic CI failure.

### Layer 3: Adopter Lifecycle Layer (1-step install)

The Adopter Lifecycle Layer protects projects that install RevHarness. Before
this layer, adoption required a sequence of scripts and manual ordering.

That created two risks: adopters could miss a step, and the harness could write
into its own source checkout instead of the target project. This layer makes
install, verify, repair, status, clean, and wire operations flow through one
lifecycle contract.

- `rev-harness` facade + 3 sub-scripts
- Provides the user-facing lifecycle entrypoint.
- Routes install, uninstall checklist, repair, status, clean, and upgrade
  inspection.
- Keeps underlying scripts directly invocable instead of absorbing them.
- `rev-harness-adopter-setup.sh`
- 5-phase FSM with resume and rollback.
- Calls out to existing setup components in order.
- Records durable state for failed or resumed adoption.
- `resolve_target_root()`
- TARGET_ROOT priority: `--target > env > pwd`.
- Separates `HARNESS_ROOT` for source assets from `TARGET_ROOT` for writes.
- Removes the "script location equals project root" assumption.
- Self-install guard
- Refuses to install RevHarness into its own source checkout.
- Uses exit 72 for the canonical self-install refusal.
- Turns a destructive target mistake into a loud stop.
- `rev-harness-mcp-wire.sh`
- jq merge for MCP wiring.
- `.bak` rollback artifacts.
- sha256 conflict refuse unless an explicit escape path is chosen.
- `rev-harness-janitor.sh build-cleanup`
- C-hybrid cleanup model.
- Opt-in destructive behavior.
- `--apply` plus acknowledgement required for delete paths.
- Hook-origin destructive cleanup forbidden.
- `.claude/skills/rev-harness-lifecycle/` skill
- Discoverable install, verify, repair, upgrade, and uninstall prompts.
- Prevents lifecycle requests from being confused with junk cleanup or session
  bootstrap.
- New invariants: I-10/I-11.
- I-10: Call-out, never absorb.
- I-11: Destructive opt-in.

### Layer 4: Smoke Verification Layer (G3 cover)

The Smoke Verification Layer protects the final acceptance boundary. It exists
because static checks and agent review can agree while still missing the real
production path.

The layer forces RevHarness to prove itself against a fresh adopter, not only
against its source tree. It also joins compiled-artifact privacy with phase
finality.

- `phase-done-smoke.sh`
- Runs real install in a mktemp adopter.
- Verifies project identity, hooks, semantic DB placement, status, doctor,
  clean dry-run, and component behavior.
- Confirms canonical source identity is unchanged.
- Emits smoke evidence consumed by final LGTM transition checks.
- `release-binary-privacy-scan.sh`
- Enforces I-2b for the shipped Rust binary.
- Scans compiled strings for developer-home paths, registry source paths,
  toolchain paths, and legacy privacy sentinels.
- Closes the gap source-level path guards cannot cover.
- `state-transition-guard.sh` joint `lgtm_stage` axis
- Models agent LGTM as provisional.
- Allows final only when smoke evidence is valid.
- Rejects final-to-provisional regression.
- Blocks phase `done` while `lgtm_stage` is not final.
- `hsdi-phase-H-done.sh`
- 15-step aggregator with flock.
- Runs component checks before the smoke gate.
- Makes the final gate itself non-racy.
- New invariants: I-2b/I-12.
- I-2b: binary privacy stable.
- I-12: smoke-gated dual-LGTM.

## 3. 13 invariants の関係性 mapping

The invariant set is a dependency map. Earlier invariants establish baseline
fail-closed behavior. HSDI then adds runtime self-defense, adopter lifecycle
governance, and final smoke authority.

| Layer | Invariants | rationale |
|---|---|---|
| 既存 fail-closed | I-1 / I-2 / I-3 / I-4 / I-5 | Pre-HSDI baseline |
| Self-Defense | I-6 / I-7 / I-8 / I-9 | Phase B 追加 |
| Adopter Lifecycle | I-10 / I-11 | Phase G 追加 |
| Smoke Verification | I-2b / I-12 | Phase H 追加 |

Reading notes for orchestrators:

- I-1 protects source and staged output from privacy leaks.
- I-2 keeps Tier 1 capsule output byte-stable.
- I-2b extends privacy to compiled binary artifacts.
- I-3 requires dual-LGTM evidence to exist on disk.
- I-4 keeps graceful shutdown fail-open.
- I-5 pins wrapper help and behavior parity.
- I-6 prevents parallel ownership overlap.
- I-7 scopes PARALLEL_QUIESCE to the dispatch window.
- I-8 makes file movement hash-visible.
- I-9 rejects malformed dispatch topology.
- I-10 prevents facade absorption of child responsibilities.
- I-11 makes destructive behavior opt-in.
- I-12 makes smoke passing mandatory before final acceptance.

The key relationship is I-3 plus I-12. I-3 proves reviewer evidence exists and
is structurally valid. I-12 says that evidence is still provisional until smoke
passes.

The second key relationship is I-1 plus I-2b. I-1 protects source; I-2b
protects what the compiler may embed afterward.

## 4. 設計原則 (= governance pattern)

These principles are governance patterns, not implementation slogans. Use them
when deciding whether to absorb a reviewer suggestion, dispatch parallel
workers, allow destructive actions, or declare acceptance.

### 4.1 Call-out, never absorb (I-10)

Call-out, never absorb means a facade may coordinate lifecycle components, but
it must not silently become their owner.

Phase G kept child scripts directly invocable and made the adopter setup driver
call them in sequence. This preserves review locality: a bug in MCP wiring is
inspected in the wire script, not hidden inside the facade.

It also prevents integration code from overwriting adopter state without the
child component's own contract.

### 4.2 Destructive opt-in (I-11)

Destructive opt-in means cleanup, uninstall, and upgrade apply paths must be
explicitly selected by the caller.

For build cleanup, inspection is default and deletion requires both `--apply`
and a domain acknowledgement such as `--ack-rebuild-cost`.

The principle matters because hooks and janitors run near active agent work. A
silent delete default can turn maintenance into an availability incident.

### 4.3 Smoke-gated dual-LGTM (I-12)

Smoke-gated dual-LGTM means agent review is necessary but not sufficient.
Reviewer verdicts are provisional until `phase-done-smoke.sh` executes the real
install path and records valid smoke evidence.

This prevents a repeat of the G3 gap where dual 9+/10 verdicts missed defects
visible only in a fresh adopter run.

For orchestrators, the rule is simple: do not advance `done` unless the LGTM
stage is final.

### 4.4 Fail-open hooks (I-4)

Fail-open hooks mean advisory shutdown and diagnostic hooks must not block the
core orchestration path when their own internals fail.

The hook may emit JSONL evidence, warn, or skip non-critical cleanup, but it
should not make wrapper exit a single point of failure.

This differs from acceptance gates. Acceptance gates fail closed; runtime hooks
near agent shutdown fail open and record evidence.

### 4.5 Privacy hard + soft 2-layer (I-1 + path-leak-advise)

The privacy model has a hard layer and a soft layer. I-1 is the hard pre-commit
gate that rejects path leaks and sensitive strings before they enter committed
output.

The advisory layer, including path-leak advice hooks, surfaces suspicious
patterns during work without stopping unrelated orchestration.

I-2b completes the model for release binaries, where private paths can appear
after source checks have passed.

## 5. 学んだこと (= governance lessons)

These lessons should change how an orchestrator reads reviewer findings and
phase evidence. The right response to an incident is not only to patch the
failing line.

The right response is to identify which trust boundary was missing a
deterministic guard.

### 5.1 reviewer findings are hypotheses

The Phase G Round 2 F4 incident showed that reviewer suggestions can be
plausible and still break production reachability.

The facade absorbed an unconditional QUIESCE export as defense in depth. That
made `rev-harness clean` 100% unreachable because the janitor correctly
observed PARALLEL_QUIESCE and skipped its work.

The structural fix was to retract the facade export, keep QUIESCE injection in
`safe-dispatch.sh`, and record the erratum instead of rewriting history.

The governance lesson is that reviewer findings are hypotheses. The
orchestrator must test them against the actual command path.

### 5.2 agent-based LGTM ≠ production safety

Phase H proved that seven consecutive phases of agent-based 9+/10 dual-LGTM
did not equal production safety.

The missing dimension was a real fresh-adopter install, including target-root
resolution, facade reachability, state schema alignment, binary privacy, and
CLI help behavior.

Static checks were necessary, but they were scoped to files and scripts rather
than adopter outcome.

The structural fix was I-12: dual-LGTM remains provisional until
`phase-done-smoke.sh` passes and the guard accepts final-stage evidence.

### 5.3 自分自身を傷つける hook

The Phase A graceful-shutdown accident showed that a self-defense hook can
become the attacker when it runs before its own safety boundary exists.

The wrapper EXIT trap invoked the hook during in-flight work, and the hook's
bail-stash behavior stashed the same production files that implemented it.

The root cause was not filesystem randomness. It was a cleanup path with
authority over the host repo and insufficient task-scope gating.

The structural fix was multi-layered: PARALLEL_QUIESCE gates, owner stamping,
safe-dispatch snapshots, fail-open hook behavior, and flock-protected final
smoke aggregation.

## 6. Phase-by-phase summary (commit + tag) table

The table below is chronology for provenance only. Use Section 2 when deciding
which layer owns a current task.

| Phase | Commit | Tag | Layer | invariants |
|---|---|---|---|---|
| A | 0042120 | hsdi-phase-A-done | Foundation | — |
| B | d660e2d | hsdi-phase-B-done | Self-Defense | I-6/7/8/9 |
| C | f8688ef | hsdi-phase-C-done | Wrapper Trust | — |
| D | 2b972ed | hsdi-phase-D-done | Self-Defense extension | — |
| E | 18f8145 | hsdi-phase-E-done | Self-Defense extension | — |
| F | 25fd3d0 | hsdi-phase-F-done | Tier 2 schema-only | — |
| G | a0cbba9 | hsdi-phase-G-done | Adopter Lifecycle | I-10/11 |
| H | ebab232 | hsdi-phase-H-done + hsdi-final | Smoke Verification | I-2b/12 |

## 7. Cross-references

- `docs/canonical-invariants.md`
- `docs/manual/phase-done-smoke.md`
- `docs/manual/release-binary-privacy.md`
- `docs/manual/state-transition-guard.md`
- `docs/manual/safe-dispatch.md`
- `docs/manual/verification-truth-matrix.md`
- `docs/manual/roadmap-wave-22.md`
- `CHANGELOG.md` 0.0.18 entry

Recommended read order for orchestrators:

1. Start with this overview to identify the functional layer.
2. Read `docs/canonical-invariants.md` for the exact invariant contract.
3. Read `docs/manual/verification-truth-matrix.md` before claiming final acceptance.
4. Read the layer-specific manual page for the script or gate being touched.
5. Use `CHANGELOG.md` 0.0.18 for release-level provenance.
