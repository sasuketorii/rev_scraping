# state-transition-guard.sh - Joint State Machine Reference

> dual_lgtm state + lgtm_stage joint axis mechanical enforcement. I-3 + I-12 co-enforcement.

## 1. Purpose

- `scripts/state-transition-guard.sh` is the joint state machine reference for dual-LGTM state.
- It enforces the I-3 state axis and the I-12 smoke-gated stage axis together.
- Operators use it to record state transitions for a plan, round, and reviewer evidence pair.
- Reviewers use it to verify that a phase was not advanced from reviewer confidence alone.
- The default state file is `.agent/state/dual_lgtm_state.json`.
- The default smoke metrics file is `.agent/metrics/phase_done_smoke.jsonl`.
- The smoke metrics path can be overridden with `REV_HARNESS_PHASE_DONE_SMOKE_METRICS`.
- The state axis is named `state`.
- The state axis values are `dual_lgtm_pending`, `dual_lgtm_confirmed`, and `dual_lgtm_blocked`.
- The stage axis is named `lgtm_stage`.
- The stage axis values are `provisional` and `final`.
- The two axes are constrained independently.
- A valid state-axis move can still fail the I-12 stage-axis rules.
- A valid stage-axis move can still fail the I-3 state-axis rules.
- Phase advance means setting `state.json.phase = "done"` in the relevant phase state.
- Phase advance requires `state=dual_lgtm_confirmed`.
- Phase advance also requires `lgtm_stage=final`.
- `lgtm_stage=final` means the dual-LGTM verdict survived the phase-done smoke gate.
- `lgtm_stage=provisional` means the agent verdict is not sufficient for final phase advance.
- `lgtm_stage=final` is only reachable from a confirmed provisional state.
- `lgtm_stage=final` requires a valid `smoke_evidence_sha256`.
- `smoke_evidence_sha256` must be a sha256 hex digest.
- `smoke_evidence_sha256` must appear in the smoke metrics JSONL summary row.
- The matching smoke summary row must have `event=summary`.
- The matching smoke summary row must have `exit_code=0`.
- The guard writes `smoke_evidence_sha256` into state only for final stage transitions.
- The guard rejects final-to-provisional regression.
- The guard permits final-to-final idempotence.
- The guard emits transition metrics for auditability.
- The guard is mechanical acceptance support, not a substitute for reviewer judgment.
- Reviewers should cite the state file, smoke metrics row, and transition command when accepting a phase.

## 2. CLI

| Subcommand | Form | Behavior |
|---|---|---|
| `transition` | `bash scripts/state-transition-guard.sh transition ...` | Default operation. Reads current state, validates I-3 and I-12 axes, writes state atomically, and emits transition JSONL. |
| default transition | `bash scripts/state-transition-guard.sh ...` | Same as `transition` when no explicit subcommand is supplied. |
| `--require-lgtm-final` | `bash scripts/state-transition-guard.sh --require-lgtm-final <state-file>` | Gate command. Exits 1 unless the given state file has `lgtm_stage=final`. |
| `--self-test` | `bash scripts/state-transition-guard.sh --self-test` | Runs built-in transition and gate scenarios. Must exit 0 before relying on changed guard behavior. |
| `--help` | `bash scripts/state-transition-guard.sh --help` | Prints usage, flags, and supported modes. |
| `validate_joint_transition` | internal function | Applies I-12 stage rules after the state-axis pair is checked. Not called directly by operators. |

Transition flags:

- `--plan-id <id>` identifies the plan or slice being advanced.
- `--round <n>` identifies the review or smoke round.
- `--target-state <state>` sets the target I-3 state-axis value.
- `--target-stage <stage>` sets the target I-12 `lgtm_stage` value.
- `--smoke-evidence-sha256 <sha>` supplies the smoke evidence digest required for final stage.
- `--state-file <path>` overrides `.agent/state/dual_lgtm_state.json`.
- `--evidence-paths "opus=...,codex=..."` records reviewer evidence files.
- `--reason <text>` records the transition reason.
- `--allowed-transitions <csv>` overrides the default state-only transition CSV.

Typical provisional confirmation:

```bash
bash scripts/state-transition-guard.sh transition \
  --plan-id phase-h \
  --round 1 \
  --target-state dual_lgtm_confirmed \
  --target-stage provisional \
  --evidence-paths "opus=.agent/active/opus.md,codex=.agent/active/codex.md" \
  --reason "dual reviewer provisional LGTM"
```

Typical final confirmation after smoke:

```bash
bash scripts/state-transition-guard.sh transition \
  --plan-id phase-h \
  --round 2 \
  --target-state dual_lgtm_confirmed \
  --target-stage final \
  --smoke-evidence-sha256 "<sha256-from-summary>" \
  --evidence-paths "opus=.agent/active/opus.md,codex=.agent/active/codex.md" \
  --reason "phase-done smoke passed"
```

Final gate check:

```bash
bash scripts/state-transition-guard.sh --require-lgtm-final .agent/state/dual_lgtm_state.json
```

## 3. Joint transition table

| Current state | Current `lgtm_stage` | Target state | Target `lgtm_stage` | Smoke sha required | Result |
|---|---:|---|---:|---:|---|
| `dual_lgtm_pending` | `provisional` | `dual_lgtm_confirmed` | `provisional` | no | OK if the I-3 state pair is allowed. |
| `dual_lgtm_confirmed` | `provisional` | `dual_lgtm_confirmed` | `final` | yes | OK only when `smoke_evidence_sha256` is valid and sourced from a passing summary row. |
| `dual_lgtm_confirmed` | `final` | `dual_lgtm_confirmed` | `final` | no | OK as an idempotent final-state write. |
| `dual_lgtm_confirmed` | `final` | `dual_lgtm_confirmed` | `provisional` | no | Reject as an I-12 violation because final cannot regress. |
| `dual_lgtm_pending` | `provisional` | `dual_lgtm_pending` | `final` | yes | Reject as an I-12 violation because final is not reachable from an unconfirmed path. |

Default state-only allowed transitions:

| From | To | Meaning |
|---|---|---|
| `dual_lgtm_pending` | `dual_lgtm_confirmed` | Reviewers agree provisionally or final smoke confirmation is being recorded. |
| `dual_lgtm_pending` | `dual_lgtm_blocked` | Review cannot proceed because the slice is blocked. |
| `dual_lgtm_pending` | `dual_lgtm_pending` | Idempotent pending write or metadata refresh. |
| `dual_lgtm_confirmed` | `dual_lgtm_confirmed` | Idempotent confirmed write or stage refinement. |
| `dual_lgtm_blocked` | `dual_lgtm_blocked` | Idempotent blocked write or reason refresh. |
| `dual_lgtm_blocked` | `dual_lgtm_pending` | Reopen after the blocker is addressed. |

State-axis notes:

- `dual_lgtm_confirmed -> dual_lgtm_pending` is not in the default allowed set.
- `dual_lgtm_confirmed -> dual_lgtm_blocked` is not in the default allowed set.
- `dual_lgtm_blocked -> dual_lgtm_confirmed` is not in the default allowed set.
- Operators may override state pairs with `--allowed-transitions` only when a slice contract explicitly allows it.
- Overriding the state pairs does not override I-12 final-stage rules.
- The joint table is representative, not exhaustive.
- The script is the executable source for exact behavior.

## 4. Operation (atomic mv)

1. Read the current state file with `jq`.
2. Treat jq read failure as state corruption.
3. Use `.agent/state/dual_lgtm_state.json` when `--state-file` is not supplied.
4. Extract current `state`.
5. Extract current `lgtm_stage`.
6. Apply defaults when the current file has no prior stage field.
7. Validate the `(from,to)` state pair against the allowed transition CSV.
8. Use the default CSV when `--allowed-transitions` is not supplied.
9. Reject any state-axis move not present in the CSV.
10. Validate the joint `(state,stage)` tuple via `validate_joint_transition`.
11. Reject `final -> provisional` as an I-12 regression.
12. Allow `final -> final` as an idempotent write.
13. For `confirmed/provisional -> confirmed/final`, require `--smoke-evidence-sha256`.
14. Verify that `smoke_evidence_sha256` is sha256 hex.
15. Verify that the same sha appears in the phase-done smoke metrics file.
16. Verify that the matching metrics row has `event=summary`.
17. Verify that the matching metrics row has `exit_code=0`.
18. Reject every other `target_stage=final` path as an I-12 violation.
19. Parse `--evidence-paths` into `opus` and `codex` paths.
20. Compute sha256 for the Opus evidence path when supplied.
21. Compute sha256 for the Codex evidence path when supplied.
22. Preserve evidence path strings in `evidence_paths{opus,codex}`.
23. Preserve evidence digests in `sha256{opus,codex}`.
24. Write the new state with `jq -n` into a temporary file.
25. Include `plan_id`.
26. Include `round`.
27. Include `state`.
28. Include `lgtm_stage`.
29. Include `transitioned_at`.
30. Format `transitioned_at` as UTC ISO time.
31. Include `transition_reason`.
32. Include `evidence_paths`.
33. Include `sha256`.
34. Include optional `smoke_evidence_sha256` only when supplied.
35. Move the temporary file into place with `mv -f`.
36. The `mv -f` step is the atomic state replacement boundary.
37. Emit JSONL to `.agent/metrics/dual_lgtm_state.jsonl`.
38. The JSONL emission records the transition operation for later audit.
39. The state file is the latest state.
40. The metrics file is the append-only transition trail.

## 5. Exit codes

| Exit code | Meaning | Operator response |
|---:|---|---|
| 0 | OK. The requested operation succeeded. | Continue to the next gate or record evidence. |
| 1 | Invalid transition, I-12 violation, or `--require-lgtm-final` gate failure. | Do not advance phase. Inspect state, stage, smoke metrics, and transition arguments. |
| 2 | Usage error. Required flags are missing or malformed. | Fix CLI invocation and retry. |
| 3 | Reserved for state.json corruption. `jq` read failed. | Treat state as unsafe. Preserve evidence and repair through the configured recovery path. |

## 6. I-12 enforcement (smoke gate handshake)

After `phase-done-smoke.sh` exits 0:

1. Read `.agent/metrics/phase_done_smoke.jsonl`.
2. Locate the final summary row.
3. Confirm the row has `event=summary`.
4. Confirm the row has `exit_code=0`.
5. Extract `smoke_evidence_sha256` from that summary row.
6. Call `scripts/state-transition-guard.sh transition`.
7. Set `--target-state dual_lgtm_confirmed`.
8. Set `--target-stage final`.
9. Pass `--smoke-evidence-sha256` with the extracted sha.
10. Preserve Opus and Codex evidence with `--evidence-paths`.
11. Record a concrete `--reason`.
12. On exit 0, the joint state has passed the I-12 smoke gate.
13. On exit 0, phase advance is permitted by the joint axis.
14. Phase advance still must follow the configured phase transition command.

Example:

```bash
SMOKE_SHA="<sha256-from-.agent/metrics/phase_done_smoke.jsonl>"
bash scripts/state-transition-guard.sh transition \
  --plan-id phase-h \
  --round 2 \
  --target-state dual_lgtm_confirmed \
  --target-stage final \
  --smoke-evidence-sha256 "$SMOKE_SHA" \
  --evidence-paths "opus=.agent/active/opus.md,codex=.agent/active/codex.md" \
  --reason "phase-done-smoke summary exit_code=0"
```

Refusal cases:

- The target stage is `final` but no `smoke_evidence_sha256` was supplied.
- The supplied `smoke_evidence_sha256` is not sha256 hex.
- The supplied sha is not present in the smoke metrics file.
- The matching smoke metrics row is not `event=summary`.
- The matching smoke metrics row does not have `exit_code=0`.
- The requested transition would move `lgtm_stage` from `final` to `provisional`.
- The requested final path is not `confirmed/provisional -> confirmed/final`.
- The state-axis pair is not allowed by the active transition CSV.
- The state file cannot be read by `jq`.

Operator checks:

```bash
bash scripts/state-transition-guard.sh --require-lgtm-final .agent/state/dual_lgtm_state.json
```

- Use this check immediately before any `state.json.phase = "done"` advancement.
- Treat nonzero exit as a hard block.
- Do not substitute dual reviewer score, narrative LGTM, or manual confidence for this check.
- I-12 exists because provisional dual-LGTM can miss production smoke failures.
- Final means reviewer agreement plus passing smoke evidence.

## 7. Self-test

`--self-test` exercises representative state-axis and stage-axis behavior.

```bash
bash scripts/state-transition-guard.sh --self-test
```

The command must exit 0.

State-axis scenarios include:

- Allowed `dual_lgtm_pending -> dual_lgtm_confirmed`.
- Allowed `dual_lgtm_pending -> dual_lgtm_blocked`.
- Allowed `dual_lgtm_pending -> dual_lgtm_pending`.
- Allowed `dual_lgtm_confirmed -> dual_lgtm_confirmed`.
- Allowed `dual_lgtm_blocked -> dual_lgtm_blocked`.
- Allowed `dual_lgtm_blocked -> dual_lgtm_pending`.
- Forbidden state-axis moves outside the default CSV.

Stage-axis scenarios include:

- Provisional confirmation without smoke finalization.
- Confirmed provisional to confirmed final with valid smoke evidence.
- Final to final idempotence.
- Final to provisional regression refusal.
- Other target-stage final paths refused as I-12 violations.

Require-final scenarios include:

- `--require-lgtm-final` succeeds when `lgtm_stage=final`.
- `--require-lgtm-final` fails when `lgtm_stage=provisional`.

## 8. Cross-references

- I-3 invariant: `AGENTS.md` for the state axis convention.
- I-3 invariant: `docs/canonical-invariants.md` for canonical invariant context.
- I-12 invariant: `AGENTS.md` section `I-12 (Smoke-gated dual-LGTM)`.
- Phase-done smoke manual: `docs/manual/phase-done-smoke.md`.
- Phase-done smoke command: `scripts/phase-done-smoke.sh`.
- Dual-LGTM validation command: `scripts/dual-lgtm-validate.sh`.
- Implementation: `scripts/state-transition-guard.sh`.
- State file default: `.agent/state/dual_lgtm_state.json`.
- Smoke metrics default: `.agent/metrics/phase_done_smoke.jsonl`.
- Transition metrics default: `.agent/metrics/dual_lgtm_state.jsonl`.
- Smoke metrics override: `REV_HARNESS_PHASE_DONE_SMOKE_METRICS`.
- Required final field: `lgtm_stage`.
- Required final evidence field: `smoke_evidence_sha256`.
- Atomic write method: `jq -n` temporary file followed by `mv -f`.
- Acceptance authority: `docs/manual/verification-truth-matrix.md`.
