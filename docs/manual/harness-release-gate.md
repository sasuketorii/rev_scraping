# Harness Release Gate

Date: `2026-04-06`
Status: `authoritative harness release gate`

## 1. Purpose

This runbook defines the release gate for the current harness plan.

This document defines the stable gate contract only. Dated rerun results, latest artifact paths, and slice-specific closeout evidence belong in the current `.agent/active/sow/*.md`, matching `.agent/active/prompts/*.md`, and `.claude/tmp/harness-release-gate/runs/<run-id>/`.

The authoritative release gate remains `bash test/integration/harness_release_gate.sh`. Benchmark and memory evidence are a separate surface owned by `scripts/harness-benchmark.sh`; inspect `bash scripts/harness-benchmark.sh --help` for required args, then cite the fixed artifact paths from a valid benchmark run rather than inferring them from this runbook.

A boundary can be described as `full gate green` or `test-backed local sign-off` only when the release gate passes and the dated evidence matches the contracts below. Reviewer-accepted completion requires separate reviewer evidence and should not be inferred from this runbook alone.

## 2. Gate Commands

Run the full gate through:

```bash
bash test/integration/harness_release_gate.sh
```

For day-to-day operational visibility, use the tiered entrypoints:

```bash
bash scripts/harness-doctor.sh --quick
bash scripts/harness-doctor.sh --quick --json
bash test/integration/harness_release_gate.sh --tier quick
bash test/integration/harness_release_gate.sh --tier local --dry-run
bash test/integration/harness_release_gate.sh --tier full --dry-run
```

`--tier quick` delegates to `scripts/harness-doctor.sh --quick` before release-gate run initialization. It is read-only and advisory-only: it must not create release-gate run directories, refresh latest pointers, prune artifacts, perform network calls, perform deep scans, or claim acceptance, LGTM, completion, or release readiness. Quick may be cited as the gate tier for `light` tasks only when `scripts/rev-harness-task-classifier.sh` returns `task_class=light` and the light-change-record includes the relevant file-specific deterministic checks such as `git diff --check -- <files>`. Use `local` for `standard` scoped review evidence and `full` for `heavy` release/tag/merge-prep evidence.

`local` and `full` create normal run artifacts. Each step directory includes `elapsed_ms.txt`, the run root includes `step-timing.tsv`, and `summary.md` records `Tier`, `Total elapsed ms`, and per-step timing rows. `full` writes `.claude/tmp/harness-release-gate/latest.json`, `latest-success.json`, and `latest-failure.json`. `local` writes separate local pointers: `.claude/tmp/harness-release-gate/latest-local.json`, `latest-local-success.json`, and `latest-local-failure.json`. Pointer JSON and lifecycle manifests include the `tier` field. Dry-run modes list the planned steps and do not create run artifacts or update pointers.

The script writes artifacts under `.claude/tmp/harness-release-gate/runs/<run-id>/`, writes `artifact-lifecycle-manifest.json` inside each run root, and refreshes `.claude/tmp/harness-release-gate/latest.json`, `.claude/tmp/harness-release-gate/latest-success.json`, or `.claude/tmp/harness-release-gate/latest-failure.json`.

The gate currently executes these commands. `benchmark_surface_contract` is contract-only coverage for the benchmark CLI and artifact contract; it does not execute a full benchmark workload.

| Step | Command | Contract covered |
| --- | --- | --- |
| harness doctor quick | `bash test/integration/harness_doctor_quick_test.sh` | quick doctor JSON/timing/no-mutation/static and PATH-stub forbidden-call contract |
| harness release gate tiering | `HARNESS_RELEASE_GATE_TIERING_NESTED=1 bash test/integration/harness_release_gate_tiering_test.sh` | quick/local/full tier dispatch, no-mutation, and dry-run contract |
| task classifier | `bash test/integration/rev_harness_task_classifier_test.sh` | light/standard/heavy mapping, schema profile selection, and final-gate isolation |
| skill routing | `bash test/integration/rev_harness_skill_routing_test.sh` | class-to-skill matrix, self-growth routing, provenance, and light-path non-escalation invariants |
| self-growth proposal cycle | `bash test/integration/self_growth_proposal_cycle_test.sh` | proposal-driven self-growth promotion cycle, untrusted evidence boundary, no autonomous mutation, and bounded cost contract |
| static asset check | `bash test/integration/rev_harness_static_asset_check_test.sh` | dependency-free static app smoke validation for disposable workspace HTML/CSS/JS/JSON artifacts |
| semantic rust build | `bash -c 'cd harness-rust && cargo check -p semantic-mcp -p tree-sitter-index'` | Rust semantic backend buildability (the Node backend was removed in de-overkill S3-B3) |
| semantic CLI contract | `bash test/integration/semantic_cli_contract_parity_test.sh` | Rust-only CLI contract for `project-id validate` and `unknown command` |
| semantic MCP contract tests | `bash -c 'cd harness-rust && cargo test -p semantic-mcp'` | Rust semantic-mcp tool/registry/search/preflight/capsule contract regression suite |
| native reviewer smoke | `bash test/integration/native_reviewer_surface_smoke.sh` | reviewer packet / prompt rendering / review-report contract, fenced transport-payload rejection, invalid reviewer relay suppression |
| codex MCP zombie cleanup contract | `bash test/integration/codex_mcp_zombie_cleanup_contract_test.sh` | stale Playwright / Computer Use MCP helper detection, semantic-safe dry-run contract, and default age guard |
| codex MCP zombie cleanup live | `bash test/integration/codex_mcp_zombie_cleanup_live_test.sh` | explicit PID-confirmed stale-helper termination and fail-closed live cleanup contract |
| hook ingress smoke | `bash test/integration/hook_ingress_smoke.sh` | ingress hook enforcement and fail-closed runtime smoke |
| model policy validate | `bash scripts/model-policy.sh validate` | release-gate tier step-list coverage for model-policy validation; model-policy implementation remains separate task evidence |
| model policy generate check | `bash scripts/model-policy.sh generate --check` | release-gate tier step-list coverage for generated mirror drift; model-policy implementation remains separate task evidence |
| model policy stale refs | `bash scripts/model-policy.sh stale-refs` | full-tier stale reference visibility; model-policy implementation remains separate task evidence |
| model policy consistency | `bash test/integration/model_policy_consistency_test.sh` | release-gate tier step-list coverage for model-policy consistency; model-policy implementation remains separate task evidence |
| subscription auth guard | `bash test/integration/subscription_auth_guard_test.sh` | subscription-only auth fail-closed boundary and API-key fallback rejection |
| lease guard | `bash test/integration/rev_harness_lease_guard_test.sh` | closed worker lease registry acceptance and malformed / running / missing-artifact block behavior |
| lease lifecycle | `bash test/integration/rev_harness_lease_lifecycle_test.sh` | typed lease open / heartbeat / close / block / reap lifecycle authority |
| wrapper matrix | `bash test/integration/cross_agent_wrapper_matrix_test.sh` | wrapper role matrix and caller-boundary rules |
| cross-family artifact smoke | `bash test/integration/cross_family_artifact_smoke_test.sh` | deterministic Codex worker artifact -> Opus reviewer artifact -> orchestrator acceptance packet -> lease closeout contract; not a live CLI conversation claim |
| cross-family live smoke preflight | `bash test/integration/cross_family_live_smoke_preflight_test.sh` | read-only safety gate for whether a Codex / Opus live smoke may be attempted; it never starts model processes and never permits a completion claim |
| cross-family live artifact smoke | `bash test/integration/cross_family_live_artifact_smoke_test.sh` | stubbed contract test for the opt-in live Codex -> Opus artifact-smoke runner; default CI does not spend subscription quota |
| janitor inspect | `bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == "rev-harness-janitor/v1" and .janitor_command == "inspect" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null` | self-cleaning visibility stays wired into release-gate without deleting or moving evidence |
| semantic coordination | `bash test/integration/semantic_coordination_test.sh` | coordinator fail-closed, direct entrypoints, shadow loop, invalid queue contracts |
| registry export | `bash test/integration/semantic_registry_export_contract_test.sh` | DB authority, stale export rejection, fail-closed merge gate |
| capsule help | `bash .claude/commands/lib/context_capsule.sh --help` | direct CLI entrypoint availability |
| shadow help | `bash .claude/commands/lib/shadow_verify.sh --help` | direct CLI entrypoint availability |
| benchmark surface contract | `bash test/integration/harness_benchmark_contract_test.sh` | benchmark CLI/artifact contract only; not full benchmark execution |
| common task contract smoke | `bash test/integration/common_task_contract_smoke.sh` | stable task-contract emit/validate surface |
| semantic sync freshness | `bash test/integration/semantic_sync_freshness_contract_test.sh` | sync freshness contract and fail-closed stale-state handling |
| semantic project id | `bash test/integration/semantic_project_id_contract_test.sh` | canonical project-id contract across runtime surfaces |
| coder engine truth | `bash test/integration/coder_engine_truth_test.sh` | coder engine selection truth and drift rejection |
| policy source consistency | `bash test/integration/policy_source_consistency_test.sh` | stable policy source manifest contract |
| orchestration packet validator | `bash test/integration/orchestration_packet_validator_test.sh` | compiled policy bundle / packet preflight validator contract |
| auto orchestrate packet preflight | `bash test/integration/auto_orchestrate_packet_preflight_test.sh` | coder-launch packet preflight integration for single explicit packet tuple plans |

The `local` tier is intentionally narrower than `full`: it runs `harness_doctor_quick`, `harness_release_gate_tiering`, `rev_harness_task_classifier`, `rev_harness_skill_routing`, `rev_harness_dual_native`, `self_growth_proposal_cycle`, `rev_harness_static_asset_check`, `model_policy_validate`, `model_policy_generate_check`, `model_policy_consistency`, `subscription_auth_guard`, `rev_harness_lease_guard`, `rev_harness_lease_lifecycle`, `runtime_baseline_contract`, `cross_agent_wrapper_matrix`, `cross_family_artifact_smoke`, `cross_family_live_smoke_preflight`, `cross_family_live_artifact_smoke`, `rev_harness_janitor_inspect`, `coder_engine_truth_test`, and `policy_source_consistency`. The `model_policy_*` entries are included here only as release-gate step-list integration; the model-policy source-of-truth implementation, registry content, generated artifact, and validator behavior are owned by their separate task lineage.

GitHub Actions runs the normal release gate on `main`, `develop`, and `codex/**` branches. A manual `workflow_dispatch` input can run `quick`, `local`, or `full`; `live_cross_family_smoke=true` additionally runs `scripts/cross-family-live-artifact-smoke.sh --json` on that runner. That opt-in step requires local subscription-authenticated Codex and Claude CLI availability and is intentionally not part of default push CI.

## 3. Failure Injection Map

Existing tests already cover the required `ALLOW/WARN/BLOCK` contracts.

| Surface | Evidence | Expected result |
| --- | --- | --- |
| missing `context_analysis.sh` | `semantic_coordination_test.sh` `M7` | `BLOCK` |
| invalid queue `project_id` | `semantic_coordination_test.sh` `M9` | `BLOCK` |
| direct entrypoint regression for capsule/shadow | `semantic_coordination_test.sh` `M10` | `BLOCK` if bootstrap sourcing or routing regresses |
| stale registry export / foreign meta / legacy `project_id` | `semantic_registry_export_contract_test.sh` `R1*`, `R5*`, `R7` | `BLOCK` |
| MCP mutator fallback | `semantic_registry_export_contract_test.sh` `R3`, `R6*` | `BLOCK` |
| queue lease / complete / requeue lifecycle (Rust backend) | `cargo test -p semantic-mcp` (`review_queue` module) | `BLOCK` on lease/finalize regression |
| wrapper role escape or caller-controlled wrapper override | `cross_agent_wrapper_matrix_test.sh` `X1`, `X3`, `X8`, `X10` | `BLOCK` |

## 4. Static Comparison Rules

The release gate may record static comparisons for rollout review, but those comparisons are not the authoritative benchmark or memory surface.

Current comparisons are:

1. wrapper/coordinator inventory context alongside the canonical benchmark artifacts
2. coordinator core-shell delta versus commit `460dd29`

Interpretation:

- wrapper/coordinator totals are release-gate context only; current benchmark/memory evidence must come from `scripts/harness-benchmark.sh`
- coordinator core delta should remain net-negative or neutral

The gate script writes both comparisons into its summary artifact.

## 5. Rollback Rules

Rollback triggers:

- any release-gate command fails
- any failure-injection expectation deviates from its contracted `ALLOW/WARN/BLOCK`
- authority ambiguity reappears between `semantic.db`, JSON, or JSONL
- repo-local identity becomes non-canonical or fail-open

Rollback response:

1. stop rollout immediately
2. do not reopen queue writes by hand
3. revert the current change set or restore the last known-good boundary
4. preserve `semantic.db` as authority; do not revive legacy JSON/JSONL authority during rollback
5. rerun the full release gate before calling the boundary healthy

## 6. Canonical Benchmark Surface

The old Phase 0 benchmark files are historical background only. Do not treat them as the current canonical anchor for benchmark or memory evidence.

Use the benchmark surface this way:

- authoritative release gate: `bash test/integration/harness_release_gate.sh`
- canonical benchmark/memory help: `bash scripts/harness-benchmark.sh --help`
- current benchmark/memory evidence: the fixed artifact paths written by a valid `scripts/harness-benchmark.sh` run

The release gate may echo static totals for rollout context, but benchmark and memory claims are re-established only from the latest canonical benchmark artifacts plus dated provenance in the current SOW / handover.

## 7. Volatile Evidence Placement

Do not update this runbook for each rerun.

When the gate is rerun, record the volatile evidence in the current dated SOW / handover:

- exact commands run
- command results
- latest artifact directory and summary path
- latest benchmark / memory artifact paths from a valid `scripts/harness-benchmark.sh` run
- sign-off level such as `full gate green` or `test-backed local sign-off`
- any reviewer caveat, missing evidence, or residual risk

Artifact layout remains stable:

- gate artifacts: `.claude/tmp/harness-release-gate/runs/<run-id>/`
- gate summary artifact: `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`
- gate latest pointers: `.claude/tmp/harness-release-gate/latest.json`, `.claude/tmp/harness-release-gate/latest-success.json`, `.claude/tmp/harness-release-gate/latest-failure.json`
- benchmark / memory artifacts: `.claude/tmp/benchmarks/<task-id>/<slice-id>/runs/<run-id>/`, with `.claude/tmp/benchmarks/<task-id>/<slice-id>/latest.json` and `.claude/tmp/benchmarks/<task-id>/<slice-id>/baselines/<baseline-id>.json`
- dated provenance: `.agent/active/sow/*.md` and `.agent/active/prompts/*.md`

## 8. Closeout Interpretation

Interpret the gate this way:

- a passing release gate is required for a healthy boundary
- a passing release gate by itself establishes `full gate green` / `test-backed local sign-off`, not reviewer-accepted completion
- any claim about the latest boundary must cite the current dated SOW / handover and current artifact path
- any benchmark or memory claim must cite the latest canonical artifacts from a valid `scripts/harness-benchmark.sh` run
- if the current dated evidence is missing, stale, or contradictory, treat the boundary as not yet re-established
