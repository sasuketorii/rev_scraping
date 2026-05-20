#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTO_ORCHESTRATE="$REPO_ROOT/.claude/commands/auto_orchestrate.sh"
TEST_BASH="${HARNESS_TEST_BASH:-/bin/bash}"

if [[ -x "$TEST_BASH" && "${BASH:-}" != "$TEST_BASH" && -z "${NATIVE_REVIEWER_SURFACE_SMOKE_REEXECED:-}" ]]; then
  export NATIVE_REVIEWER_SURFACE_SMOKE_REEXECED=1
  exec "$TEST_BASH" "$0" "$@"
fi

repo_rust_workspace_root() {
  /bin/bash "$REPO_ROOT/scripts/semantic-review-queue.sh" __internal-rust-workspace-root --repo-root "$REPO_ROOT"
}

RUST_MANIFEST="$(repo_rust_workspace_root)/Cargo.toml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

current_review_contract_is_valid() {
  local report_file="$1"

  [[ -n "$report_file" && -r "$report_file" ]] || return 1
  run_auto_function 'validate_review_output_format "$1"' "$report_file"
}

# Keep the legacy helper name wired to the runtime validator so test helpers
# cannot drift from the production transport-marker contract.
current_single_review_contract_is_valid() {
  local report_file="$1"

  current_review_contract_is_valid "$report_file"
}

assert_current_review_contract() {
  local report_file="$1"

  current_review_contract_is_valid "$report_file" \
    || fail "report does not satisfy the current reviewer contract: $report_file"
}

run_auto_function() {
  local snippet="$1"
  shift

  set +e
  "$TEST_BASH" -c '
    set -euo pipefail
    snippet="$1"
    auto_orchestrate="$2"
    shift 2
    source "$auto_orchestrate"
    eval "$snippet"
  ' _ "$snippet" "$AUTO_ORCHESTRATE" "$@"
  local status=$?
  set -e
  return "$status"
}

prepare_temp_auto_repo() {
  local repo_dir="$1"
  local projection_source="$2"

  mkdir -p "$repo_dir/.claude/commands" "$repo_dir/.agent/registry"
  /bin/cp "$AUTO_ORCHESTRATE" "$repo_dir/.claude/commands/auto_orchestrate.sh"
  ln -s "$REPO_ROOT/.claude/commands/lib" "$repo_dir/.claude/commands/lib"
  /bin/cp "$projection_source" "$repo_dir/.agent/registry/orchestration_policy_projection.json"
}

run_auto_function_with_script() {
  local auto_orchestrate="$1"
  local snippet="$2"
  shift 2

  set +e
  "$TEST_BASH" -c '
    set -euo pipefail
    snippet="$1"
    auto_orchestrate="$2"
    shift 2
    source "$auto_orchestrate"
    eval "$snippet"
  ' _ "$snippet" "$auto_orchestrate" "$@"
  local status=$?
  set -e
  return "$status"
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/native_reviewer_surface.XXXXXX")
repo_stderr_test_root="$REPO_ROOT/.claude/tmp/native-reviewer-stderr-smoke.$$"
trap '/bin/rm -rf "$tmpdir" "$repo_stderr_test_root"' EXIT

reviewer_artifact_dir="$tmpdir/reviewer-artifacts"
mkdir -p "$reviewer_artifact_dir"

for artifact_path in \
  /tmp/native-reviewer-surface-block.log \
  /tmp/native-reviewer-surface-aggregated-pass.log \
  /tmp/native-reviewer-surface-aggregated-request-changes.log \
  /tmp/native-reviewer-surface-transport-leak.log \
  /tmp/native-reviewer-surface-unknown-verdict.log; do
  printf '%s\n' "synthetic reviewer artifact: $artifact_path" > "$artifact_path"
done

for artifact_path in \
  "$reviewer_artifact_dir/aggregated-pass.log" \
  "$reviewer_artifact_dir/no-change-required-verification.log" \
  "$reviewer_artifact_dir/no-change-reviewed.log" \
  "$reviewer_artifact_dir/no-change-evidence.log"; do
  printf '%s\n' "synthetic reviewer artifact: $artifact_path" > "$artifact_path"
done

no_change_evidence_uri="file://localhost$reviewer_artifact_dir/no-change-evidence.log"

template_file="$tmpdir/reviewer_batch_template.md"
metadata_file="$tmpdir/reviewer_batch_metadata.txt"
diff_file="$tmpdir/reviewer_batch.patch"
rendered_prompt="$tmpdir/reviewer_batch_rendered.md"
missing_metadata="$tmpdir/missing_metadata.txt"
valid_report="$tmpdir/valid_report.md"
aggregated_report="$tmpdir/aggregated_report.md"
invalid_report="$tmpdir/invalid_report.md"
outdated_report="$tmpdir/outdated_report.md"
unknown_verdict_report="$tmpdir/unknown_verdict_report.md"

cat > "$template_file" <<'EOF'
# Batch Code Review Request

## Review Context
__BATCH_REVIEW_METADATA__

## Git Diff
```diff
__BATCH_REVIEW_DIFF__
```
EOF

cat > "$metadata_file" <<'EOF'
- Phase: impl
- Timestamp: 20260404_120000
- Changed files:
  - apps/web/example.ts
EOF

cat > "$diff_file" <<'EOF'
diff --git a/apps/web/example.ts b/apps/web/example.ts
index 1111111..2222222 100644
--- a/apps/web/example.ts
+++ b/apps/web/example.ts
@@ -1 +1 @@
-oldValue();
+newValue();
EOF

run_auto_function 'render_batch_review_prompt "$1" "$2" "$3" "$4"' \
  "$template_file" "$metadata_file" "$diff_file" "$rendered_prompt"

grep -q 'Phase: impl' "$rendered_prompt" || fail "rendered prompt is missing metadata content"
grep -q 'newValue();' "$rendered_prompt" || fail "rendered prompt is missing diff content"

if run_auto_function 'render_batch_review_prompt "$1" "$2" "$3" "$4"' \
  "$template_file" "$missing_metadata" "$diff_file" "$tmpdir/unexpected.md"; then
  fail "render_batch_review_prompt should fail closed when metadata is unreadable"
fi

stderr_capture_file="$tmpdir/reviewer_stderr_capture.log"
stderr_sidecar_file="$tmpdir/reviewer_output.stderr.log"
stderr_pointer_file="$tmpdir/reviewer_output.stderr-pointer.txt"
production_pointer_file="$tmpdir/reviewer_production_output.stderr-pointer.txt"
reviewer_stderr_root="$repo_stderr_test_root/override"
unset REVIEWER_STDERR_ROOT
production_stderr_file="$(run_auto_function '_reviewer_resolve_stderr_dir "$1" "$2"' "$REPO_ROOT" "20260425T000000Z_12345")"
case "$production_stderr_file" in
  "$REPO_ROOT/.claude/tmp/reviewer-stderr/20260425T000000Z_12345/stderr") ;;
  *) fail "production stderr root does not use .claude/tmp/reviewer-stderr/<run-id>/stderr: $production_stderr_file" ;;
esac

default_symlink_repo="$tmpdir/default-symlink-repo"
default_symlink_target="$tmpdir/default-symlink-target"
mkdir -p "$default_symlink_repo/.claude/tmp" "$default_symlink_target"
ln -s "$default_symlink_target" "$default_symlink_repo/.claude/tmp/reviewer-stderr"
unset REVIEWER_STDERR_ROOT
if run_auto_function '_reviewer_resolve_stderr_dir "$1" "$2"' "$default_symlink_repo" "20260425T000001Z_12345" > "$tmpdir/default_symlink_stdout" 2> "$tmpdir/default_symlink_stderr"; then
  fail "reviewer stderr default root symlink escape should fail closed"
fi
grep -q 'REVIEWER_STDERR_ROOT contains symlink component' "$tmpdir/default_symlink_stderr" \
  || fail "reviewer stderr default root symlink escape did not report symlink component"

export REVIEWER_STDERR_ROOT="$reviewer_stderr_root"
printf '[codex-wrapper] INFO: reviewer lane\n' > "$stderr_capture_file"
run_auto_function '_reviewer_finalize_stderr_sidecar "$1" "$2" "$3"' \
  "$stderr_capture_file" "$stderr_sidecar_file" "native reviewer smoke"
[[ ! -e "$stderr_sidecar_file" ]] || fail "stderr helper retained legacy output-adjacent stderr sidecar"
[[ -s "$stderr_pointer_file" ]] || fail "stderr helper did not write pointer metadata"
grep -q '^schema_version=artifact-lifecycle/stderr-pointer/v1$' "$stderr_pointer_file" \
  || fail "stderr pointer is missing schema version"
grep -q '^producer=.claude/commands/lib/reviewer.sh$' "$stderr_pointer_file" \
  || fail "stderr pointer is missing reviewer producer"
stderr_aggregate_file="$(awk -F= '$1 == "stderr_path" { sub(/^[^=]*=/, ""); print; found = 1 } END { exit(found ? 0 : 1) }' "$stderr_pointer_file")" \
  || fail "stderr pointer is missing stderr_path"
case "$stderr_aggregate_file" in
  "$reviewer_stderr_root"/*/stderr/*.stderr.txt) ;;
  *) fail "stderr pointer does not reference reviewer stderr root: $stderr_aggregate_file" ;;
esac
grep -q '\[codex-wrapper\] INFO: reviewer lane' "$stderr_aggregate_file" \
  || fail "stderr helper did not preserve wrapper diagnostics in aggregate stderr"

override_symlink_target="$tmpdir/override-symlink-target"
mkdir -p "$override_symlink_target"
ln -s "$override_symlink_target" "$repo_stderr_test_root/symlinked-override"
export REVIEWER_STDERR_ROOT="$repo_stderr_test_root/symlinked-override/child"
if run_auto_function '_reviewer_resolve_stderr_dir "$1" "$2"' "$REPO_ROOT" "20260425T000002Z_12345" > "$tmpdir/override_symlink_stdout" 2> "$tmpdir/override_symlink_stderr"; then
  fail "reviewer stderr override root symlink escape should fail closed"
fi
grep -q 'REVIEWER_STDERR_ROOT contains symlink component' "$tmpdir/override_symlink_stderr" \
  || fail "reviewer stderr override root symlink escape did not report symlink component"
[[ ! -d "$override_symlink_target/child" ]] \
  || fail "reviewer stderr override symlink escape created a directory outside .claude/tmp"

: > "$stderr_capture_file"
export REVIEWER_STDERR_ROOT="$reviewer_stderr_root"
run_auto_function '_reviewer_finalize_stderr_sidecar "$1" "$2" "$3"' \
  "$stderr_capture_file" "$stderr_sidecar_file" "native reviewer smoke"
[[ ! -e "$stderr_sidecar_file" ]] || fail "stderr sidecar helper did not remove empty sidecar"
[[ ! -e "$stderr_pointer_file" ]] || fail "stderr helper did not remove empty stderr pointer"
unset REVIEWER_STDERR_ROOT

cat > "$valid_report" <<'EOF'
## impl_review_safety.md
# Code Review Report

## Review Request
- incoming request status: pending review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- worker outcome: DIFF
- request objective: Validate the current reviewer report contract in the native smoke fixture.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: Needs verification
- outgoing next status: pending verification
- next action: Refresh deterministic verification evidence before re-running reviewer intake.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- change surface: test/integration/native_reviewer_surface_smoke.sh synthetic reviewer fixture
- in-scope: current reviewer mandatory sections and enum validation
- out-of-scope: queue runtime behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke synthetic assertions
- completion boundary: the fixture satisfies the current reviewer contract assertions
- class closure sheet: tmp/native reviewer smoke aggregated assertions
- sheet status: CLOSED
- owned sink universe: native reviewer aggregated output boundary
- closed universe status: YES
- closed universe basis: aggregated reviewer contract exhaustively checked for the owned surface
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 1/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:05:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic reviewer fixture mirrors the current report schema.
Verification evidence is intentionally incomplete, so the report stays on the non-LGTM path.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic reviewer contract fixture
- in-scope: current reviewer mandatory sections and enum validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke synthetic assertions
- completion boundary: fixture passes current contract assertions

## Class Closure Sheet
- bug class: reviewer-output-hygiene
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- change surface: synthetic reviewer contract fixture
- owned sink universe: native reviewer aggregated output boundary
- closed universe basis: aggregated reviewer contract exhaustively checked for the owned surface
- closed universe status: YES
- search method / exact commands: rg -n "Code Review Report|Worker Outcome Payload Reviewed|artifact integrity" test/integration/native_reviewer_surface_smoke.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: 0
- basis: aggregated reviewer surface fully traced for the owned sink universe
- timestamp: 2026-04-18T09:05:00Z
- target scope: current reviewer contract smoke fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:06:00Z
- reviewer request target: INTERMEDIATE
- search commands: rg -n "## Review Request|## Review Outcome|## Slice Contract|## Loop Budget Ledger" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: the fixture still reflects the reduced legacy report shape
- untouched owned surfaces checked: synthetic reviewer sections in this fixture only
- boundary / fallback / alias paths checked: legacy NOT RUN and reduced-section reviewer fixture forms
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: current reviewer contract validation fixture
- artifact pointer: n/a
- no-artifact reason: synthetic fixture only
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: tmp/native reviewer smoke synthetic assertions
- next action consistency: request additional verification before any final-review claim

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: synthetic reviewer contract fixture
- scope declaration: current reviewer contract smoke coverage
- verification result: synthetic FAIL placeholder for Needs verification path
- evidence destination: tmp/native reviewer smoke synthetic assertions
- artifact: n/a

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [ ] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [x] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

assert_current_review_contract "$valid_report"
run_auto_function 'validate_review_output_format "$1"' "$valid_report"
extracted_verdict="$(run_auto_function '_extract_review_report_verdict "$1"' "$valid_report")"
[[ "$extracted_verdict" == "Needs verification" ]] || fail "expected Needs verification verdict, got: $extracted_verdict"

custom_projection="$tmpdir/custom_projection.json"
custom_projection_report="$tmpdir/custom_projection_report.md"
custom_projection_repo="$tmpdir/custom_projection_repo"
/bin/cp "$REPO_ROOT/.agent/registry/orchestration_policy_projection.json" "$custom_projection"
jq '.reviewer_contract.canonical_worker_outcome_contract_source = "tmp/custom-worker-outcome-contract-source"' \
  "$custom_projection" > "$custom_projection.tmp"
mv "$custom_projection.tmp" "$custom_projection"
/bin/cp "$valid_report" "$custom_projection_report"
/usr/bin/perl -0pi -e '
  s/docs\/manual\/verification-truth-matrix\.md :: Worker Outcome Contract/tmp\/custom-worker-outcome-contract-source/
' "$custom_projection_report"
prepare_temp_auto_repo "$custom_projection_repo" "$custom_projection"
run_auto_function_with_script \
  "$custom_projection_repo/.claude/commands/auto_orchestrate.sh" \
  'validate_review_output_format "$1"' \
  "$custom_projection_report"
if ORCHESTRATION_POLICY_PROJECTION_PATH="$custom_projection" \
  run_auto_function 'validate_review_output_format "$1"' "$valid_report"; then
  fail "default worker-outcome contract source unexpectedly passed under custom projection override"
fi

custom_enum_projection="$tmpdir/custom_enum_projection.json"
custom_enum_report="$tmpdir/custom_enum_report.md"
custom_enum_repo="$tmpdir/custom_enum_repo"
/bin/cp "$REPO_ROOT/.agent/registry/orchestration_policy_projection.json" "$custom_enum_projection"
jq '
  .reviewer_contract.accepted_review_request_targets = ["CUSTOM"]
  | .reviewer_contract.accepted_discovery_owners = ["planner"]
  | .reviewer_contract.accepted_review_verdicts = ["Needs custom proof"]
  | .reviewer_contract.verdict_outgoing_next_status = {"Needs custom proof": "pending review"}
' "$custom_enum_projection" > "$custom_enum_projection.tmp"
mv "$custom_enum_projection.tmp" "$custom_enum_projection"
/bin/cp "$valid_report" "$custom_enum_report"
/usr/bin/perl -0pi -e '
  s/- review request target: INTERMEDIATE/- review request target: CUSTOM/g;
  s/- reviewer request target: INTERMEDIATE/- reviewer request target: CUSTOM/g;
  s/- discovery owner: coder/- discovery owner: planner/g;
  s/- review verdict: Needs verification/- review verdict: Needs custom proof/;
  s/- outgoing next status: pending verification/- outgoing next status: pending review/;
  s/- \[ \] LGTM - 問題なし、マージ可能\n- \[ \] BLOCK - fail-closed\n- \[ \] Request Changes - 修正が必要\n- \[x\] Needs verification - required checks の証跡不足\n- \[ \] Needs Discussion - 議論が必要/- [x] Needs custom proof - custom projection verdict/g;
' "$custom_enum_report"
prepare_temp_auto_repo "$custom_enum_repo" "$custom_enum_projection"
run_auto_function_with_script \
  "$custom_enum_repo/.claude/commands/auto_orchestrate.sh" \
  'validate_review_output_format "$1"' \
  "$custom_enum_report"
if ORCHESTRATION_POLICY_PROJECTION_PATH="$custom_enum_projection" \
  run_auto_function 'validate_review_output_format "$1"' "$valid_report"; then
  fail "default review target and discovery owner unexpectedly passed under custom enum projection override"
fi
if current_review_contract_is_valid "$custom_enum_report"; then
  fail "custom projected verdict unexpectedly passed under the default projection"
fi

missing_mapping_projection="$tmpdir/missing_mapping_projection.json"
missing_mapping_repo="$tmpdir/missing_mapping_repo"
/bin/cp "$REPO_ROOT/.agent/registry/orchestration_policy_projection.json" "$missing_mapping_projection"
jq 'del(.reviewer_contract.verdict_outgoing_next_status["Needs Discussion"])' \
  "$missing_mapping_projection" > "$missing_mapping_projection.tmp"
mv "$missing_mapping_projection.tmp" "$missing_mapping_projection"
prepare_temp_auto_repo "$missing_mapping_repo" "$missing_mapping_projection"
if run_auto_function_with_script \
  "$missing_mapping_repo/.claude/commands/auto_orchestrate.sh" \
  'validate_review_output_format "$1"' \
  "$valid_report"; then
  fail "projection missing an accepted verdict mapping unexpectedly passed validation"
fi

code_fenced_domain_payload_report="$tmpdir/code_fenced_domain_payload_report.md"
cp "$valid_report" "$code_fenced_domain_payload_report"
/usr/bin/perl -0pi -e '
  s/## Findings\n- None\./## Findings\n```json\n{\n  "author": "alice",\n  "recipient": "bob",\n  "content": "hello from the app layer"\n}\n```\n- None./
' "$code_fenced_domain_payload_report"
current_review_contract_is_valid "$code_fenced_domain_payload_report" \
  || fail "code-fenced domain payload JSON unexpectedly failed the current reviewer contract"
run_auto_function 'validate_review_output_format "$1"' "$code_fenced_domain_payload_report" \
  || fail "code-fenced domain payload JSON unexpectedly failed validation"

code_fenced_json_report="$tmpdir/code_fenced_json_report.md"
cp "$valid_report" "$code_fenced_json_report"
/usr/bin/perl -0pi -e '
  s/## Findings\n- None\./## Findings\n```json\n{\n  "author": "alice",\n  "recipient": "bob",\n  "other_recipients": [],\n  "trigger_turn": false\n}\n```\n- None./
' "$code_fenced_json_report"
if current_review_contract_is_valid "$code_fenced_json_report"; then
  fail "code-fenced transport JSON unexpectedly satisfied the current reviewer contract"
fi
if run_auto_function 'validate_review_output_format "$1"' "$code_fenced_json_report"; then
  fail "code-fenced transport JSON unexpectedly passed validation"
fi

inline_transport_json_block_report="$tmpdir/inline_transport_json_block_report.md"
cp "$valid_report" "$inline_transport_json_block_report"
/usr/bin/perl -0pi -e '
  s/- incoming request status: pending review/- incoming request status: pending final review/;
  s/- review request target: INTERMEDIATE/- review request target: FINAL/g;
  s/- reviewer request target: INTERMEDIATE/- reviewer request target: FINAL/;
  s/- review verdict: Needs verification/- review verdict: BLOCK/;
  s/- outgoing next status: pending verification/- outgoing next status: blocked/;
  s/- \[ \] BLOCK - fail-closed/- [x] BLOCK - fail-closed/;
  s/- \[x\] Needs verification - required checks の証跡不足/- [ ] Needs verification - required checks の証跡不足/;
  s/## Findings\n- None\./## Findings\n{"author":"alice","recipient":"bob","content":"domain message payload"}\n- None./
' "$inline_transport_json_block_report"
current_review_contract_is_valid "$inline_transport_json_block_report" \
  || fail "inline domain payload JSON in FINAL BLOCK report unexpectedly failed the current reviewer contract"
run_auto_function 'validate_review_output_format "$1"' "$inline_transport_json_block_report" \
  || fail "inline domain payload JSON in FINAL BLOCK report unexpectedly failed validation"

pretty_transport_json_block_report="$tmpdir/pretty_transport_json_block_report.md"
cp "$valid_report" "$pretty_transport_json_block_report"
/usr/bin/perl -0pi -e '
  s/- incoming request status: pending review/- incoming request status: pending final review/;
  s/- review request target: INTERMEDIATE/- review request target: FINAL/g;
  s/- reviewer request target: INTERMEDIATE/- reviewer request target: FINAL/;
  s/- review verdict: Needs verification/- review verdict: BLOCK/;
  s/- outgoing next status: pending verification/- outgoing next status: blocked/;
  s/- \[ \] BLOCK - fail-closed/- [x] BLOCK - fail-closed/;
  s/- \[x\] Needs verification - required checks の証跡不足/- [ ] Needs verification - required checks の証跡不足/;
  s/## Findings\n- None\./## Findings\n{"author": "alice",\n  "recipient": "bob",\n  "content": "domain message payload"\n}\n- None./
' "$pretty_transport_json_block_report"
current_review_contract_is_valid "$pretty_transport_json_block_report" \
  || fail "partially pretty-printed domain payload JSON in FINAL BLOCK report unexpectedly failed the current reviewer contract"
run_auto_function 'validate_review_output_format "$1"' "$pretty_transport_json_block_report" \
  || fail "partially pretty-printed domain payload JSON in FINAL BLOCK report unexpectedly failed validation"

pretty_transport_envelope_block_report="$tmpdir/pretty_transport_envelope_block_report.md"
cp "$valid_report" "$pretty_transport_envelope_block_report"
/usr/bin/perl -0pi -e '
  s/- incoming request status: pending review/- incoming request status: pending final review/;
  s/- review request target: INTERMEDIATE/- review request target: FINAL/g;
  s/- reviewer request target: INTERMEDIATE/- reviewer request target: FINAL/;
  s/- review verdict: Needs verification/- review verdict: BLOCK/;
  s/- outgoing next status: pending verification/- outgoing next status: blocked/;
  s/- \[ \] BLOCK - fail-closed/- [x] BLOCK - fail-closed/;
  s/- \[x\] Needs verification - required checks の証跡不足/- [ ] Needs verification - required checks の証跡不足/;
  s/## Findings\n- None\./## Findings\n{\n  "author": "alice",\n  "recipient": "bob",\n  "other_recipients": [],\n  "trigger_turn": false,\n  "content": "transport envelope"\n}\n- None./
' "$pretty_transport_envelope_block_report"
if current_review_contract_is_valid "$pretty_transport_envelope_block_report"; then
  fail "pretty-printed harness transport JSON in FINAL BLOCK report unexpectedly satisfied the current reviewer contract"
fi
if run_auto_function 'validate_review_output_format "$1"' "$pretty_transport_envelope_block_report"; then
  fail "pretty-printed harness transport JSON in FINAL BLOCK report unexpectedly passed validation"
fi

intermediate_lgtm_report="$tmpdir/intermediate_lgtm_report.md"
cp "$valid_report" "$intermediate_lgtm_report"
/usr/bin/perl -0pi -e '
  s/- review verdict: Needs verification/- review verdict: LGTM/;
  s/- outgoing next status: pending verification/- outgoing next status: pending acceptance/;
  s/- \[ \] LGTM - 問題なし、マージ可能/- [x] LGTM - 問題なし、マージ可能/;
  s/- \[x\] Needs verification - required checks の証跡不足/- [ ] Needs verification - required checks の証跡不足/;
' "$intermediate_lgtm_report"
if current_review_contract_is_valid "$intermediate_lgtm_report"; then
  fail "INTERMEDIATE LGTM unexpectedly satisfied the current reviewer contract"
fi

missing_artifact_integrity_report="$tmpdir/missing_artifact_integrity_report.md"
cp "$valid_report" "$missing_artifact_integrity_report"
/usr/bin/perl -0pi -e 's/\n- artifact integrity: complete//' "$missing_artifact_integrity_report"
if current_review_contract_is_valid "$missing_artifact_integrity_report"; then
  fail "missing artifact integrity unexpectedly satisfied the current reviewer contract"
fi

lgtm_missing_artifact_pointer_report="$tmpdir/lgtm_missing_artifact_pointer_report.md"
cp "$intermediate_lgtm_report" "$lgtm_missing_artifact_pointer_report"
/usr/bin/perl -0pi -e '
  s/- artifact pointer: .*$/- artifact pointer: n\/a/m;
  s/- no-artifact reason: .*$/- no-artifact reason: n\/a/m;
' "$lgtm_missing_artifact_pointer_report"
if current_review_contract_is_valid "$lgtm_missing_artifact_pointer_report"; then
  fail "LGTM with missing artifact pointer unexpectedly satisfied the current reviewer contract"
fi

failing_lgtm_report="$tmpdir/failing_lgtm_report.md"
cp "$valid_report" "$failing_lgtm_report"
/usr/bin/perl -0pi -e '
  s/- incoming request status: pending review/- incoming request status: pending final review/;
  s/- review request target: INTERMEDIATE/- review request target: FINAL/g;
  s/- reviewer request target: INTERMEDIATE/- reviewer request target: FINAL/;
  s/- review verdict: Needs verification/- review verdict: LGTM/;
  s/- outgoing next status: pending verification/- outgoing next status: pending acceptance/;
  s/- result: PASS\n- covered scope: current reviewer contract validation fixture/- result: FAIL\n- covered scope: current reviewer contract validation fixture/;
  s/- \[ \] LGTM - 問題なし、マージ可能/- [x] LGTM - 問題なし、マージ可能/;
  s/- \[x\] Needs verification - required checks の証跡不足/- [ ] Needs verification - required checks の証跡不足/;
' "$failing_lgtm_report"
if current_review_contract_is_valid "$failing_lgtm_report"; then
  fail "LGTM with failing required verification unexpectedly satisfied the current reviewer contract"
fi

cat > "$tmpdir/block_report.md" <<'EOF'
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-block
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- worker outcome: DIFF
- request objective: Prove that fail-closed BLOCK remains a valid canonical reviewer verdict.
- invalid intake route: worker outcome=BLOCK -> reject and require block report path.

## Review Outcome
- review verdict: BLOCK
- outgoing next status: blocked
- next action: Remove the transport leak and regenerate reviewer output through the canonical template.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-block
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- change surface: synthetic reviewer BLOCK fixture
- in-scope: canonical BLOCK verdict intake and extraction
- out-of-scope: queue runtime behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke block assertions
- completion boundary: canonical BLOCK verdict validates and extracts fail-closed
- class closure sheet: tmp/native reviewer smoke block assertions
- sheet status: OPEN
- owned sink universe: reviewer markdown output boundary
- closed universe status: NO
- closed universe basis: synthetic transport leak remains intentionally unresolved
- scope delta since last review: narrowed to BLOCK verdict handling
- re-slice delta type: blocker resolution
- re-slice delta summary: validate the fail-closed BLOCK path
- delta evidence: tmp/native reviewer smoke block assertions

## Loop Budget Ledger
- fix-review loops used: 2/2 (BLOCK)
- closure resets used: 1/2
- reviewer-found same-class finding count: 1/1 (BLOCK)
- re-slice count for task: 1/2
- cumulative reviewer requests for task: 5/6
- cumulative late same-class findings for task: 1/2
- cumulative closure resets for task: 1/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:18:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic reviewer fixture exercises the canonical BLOCK path.
The verdict remains fail-closed because transport contamination would invalidate acceptance.

## Findings
### [High] Hygiene: Transport envelope leaked into a reviewer-visible artifact
- **ファイル:** `test/integration/native_reviewer_surface_smoke.sh`
- **行番号:** L1-L1
- **問題:** Internal transport metadata was allowed to cross the human-facing report boundary.
- **影響:** Reviewer artifacts can no longer be trusted as canonical human-facing evidence.
- **修正案:**
```suggestion
Emit only `# Code Review Report` and canonical reviewer sections in human-facing output.
```

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic reviewer BLOCK fixture
- in-scope: canonical BLOCK verdict validation and extraction
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke block assertions
- completion boundary: canonical BLOCK verdict validates and extracts

## Class Closure Sheet
- bug class: reviewer-output-hygiene
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-block
- change surface: synthetic reviewer BLOCK fixture
- owned sink universe: reviewer markdown output boundary
- closed universe basis: synthetic transport leak remains unresolved
- closed universe status: NO
- search method / exact commands: rg -n "subagent_notification|codex-wrapper" test/integration/native_reviewer_surface_smoke.sh
- sheet status: OPEN
- last reset trigger: reviewer-found-same-class-finding::transport-envelope
- remaining issues: 1
- basis: synthetic fail-closed BLOCK fixture
- timestamp: 2026-04-18T09:18:00Z
- target scope: canonical reviewer BLOCK path

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:19:00Z
- reviewer request target: FINAL
- search commands: rg -n "BLOCK|trigger_turn|subagent_notification" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: the canonical BLOCK verdict is still rejected by the runtime parser
- untouched owned surfaces checked: synthetic reviewer BLOCK fixture only
- boundary / fallback / alias paths checked: transport envelope markers and wrapper audit lines
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: canonical reviewer BLOCK verdict validation
- artifact pointer: /tmp/native-reviewer-surface-block.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: /tmp/native-reviewer-surface-block.log
- next action consistency: remove the transport leak before re-entering reviewer intake

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: synthetic reviewer BLOCK fixture
- scope declaration: canonical reviewer BLOCK verdict coverage
- verification result: synthetic PASS placeholder for BLOCK path
- evidence destination: tmp/native reviewer smoke block assertions
- artifact: /tmp/native-reviewer-surface-block.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [ ] LGTM - 問題なし、マージ可能
- [x] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

assert_current_review_contract "$tmpdir/block_report.md"
run_auto_function 'validate_review_output_format "$1"' "$tmpdir/block_report.md"
extracted_verdict="$(run_auto_function '_extract_review_report_verdict "$1"' "$tmpdir/block_report.md")"
[[ "$extracted_verdict" == "BLOCK" ]] || fail "expected BLOCK verdict, got: $extracted_verdict"

cat > "$aggregated_report" <<'EOF'
## impl_review_safety.md
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- worker outcome: DIFF
- request objective: Confirm that the aggregated reviewer surface still accepts the current LGTM schema.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: LGTM
- outgoing next status: pending acceptance
- next action: Preserve the current contract fixture and proceed with acceptance handling.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- change surface: aggregated synthetic reviewer contract fixture
- in-scope: final-review contract validation for the native smoke surface
- out-of-scope: queue runtime behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke aggregated assertions
- completion boundary: aggregated report validates with the current reviewer contract
- class closure sheet: tmp/native reviewer smoke aggregated assertions
- sheet status: CLOSED
- owned sink universe: native reviewer aggregated output boundary
- closed universe status: YES
- closed universe basis: aggregated reviewer contract exhaustively checked for the owned surface
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 2/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:10:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic safety review report.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: aggregated synthetic reviewer contract fixture
- in-scope: aggregated review surface validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke aggregated assertions
- completion boundary: aggregated report validates

## Class Closure Sheet
- bug class: reviewer-output-hygiene
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- change surface: aggregated synthetic reviewer contract fixture
- owned sink universe: native reviewer aggregated output boundary
- closed universe basis: aggregated reviewer contract exhaustively checked for the owned surface
- closed universe status: YES
- search method / exact commands: rg -n "Code Review Report|Worker Outcome Payload Reviewed|artifact integrity" test/integration/native_reviewer_surface_smoke.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: 0
- basis: aggregated reviewer surface fully traced for the owned sink universe
- timestamp: 2026-04-18T09:10:00Z
- target scope: aggregated reviewer contract smoke fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:11:00Z
- reviewer request target: FINAL
- search commands: rg -n "Code Review Report" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: the aggregated report still reflects the reduced legacy reviewer schema
- untouched owned surfaces checked: aggregated synthetic reviewer sections only
- boundary / fallback / alias paths checked: legacy NOT RUN and reduced-section reviewer fixture forms
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: aggregated current reviewer contract validation
- artifact pointer: reviewer-artifacts/aggregated-pass.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: reviewer-artifacts/aggregated-pass.log
- next action consistency: proceed to acceptance only because the final-review gate is fully satisfied

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: aggregated synthetic reviewer contract fixture
- scope declaration: aggregated reviewer contract smoke coverage
- verification result: synthetic PASS placeholder for LGTM path
- evidence destination: tmp/native reviewer smoke aggregated assertions
- artifact: reviewer-artifacts/aggregated-pass.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [x] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要

## impl_review_perf.md
# Code Review Report

## Review Request
- incoming request status: pending review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: n/a
- worker outcome: DIFF
- request objective: Confirm that aggregated reports still surface actionable consistency findings with the current schema.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: Request Changes
- outgoing next status: pending review
- next action: Update the stale reviewer field label before re-running the smoke.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: n/a
- change surface: aggregated synthetic reviewer contract fixture
- in-scope: actionable aggregated review surface validation
- out-of-scope: queue runtime behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke aggregated assertions
- completion boundary: aggregated report validates and carries actionable findings
- class closure sheet: n/a
- sheet status: n/a
- owned sink universe: n/a
- closed universe status: n/a
- closed universe basis: n/a
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 3/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:12:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic perf review report.

## Findings
### [Medium] Consistency: Aggregated fixture keeps a stale reviewer field label
- **ファイル:** `test/integration/native_reviewer_surface_smoke.sh`
- **行番号:** L1-L1
- **問題:** The synthetic aggregated report should use the current reviewer field names so the smoke fails on schema drift.
- **影響:** Legacy reviewer shapes can slip through the aggregated smoke without detection.
- **修正案:**
```suggestion
- covered scope: aggregated current reviewer contract validation
```

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: aggregated synthetic reviewer contract fixture
- in-scope: actionable aggregated review surface validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke aggregated assertions
- completion boundary: aggregated report validates

## Class Closure Sheet
- bug class: n/a
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- change surface: aggregated synthetic reviewer contract fixture
- owned sink universe: n/a
- closed universe basis: n/a
- closed universe status: n/a
- search method / exact commands: n/a
- sheet status: n/a
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-18T09:12:00Z
- target scope: aggregated reviewer contract smoke fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:13:00Z
- reviewer request target: INTERMEDIATE
- search commands: rg -n "covered scope|artifact pointer|no-artifact reason" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: the aggregated report still uses legacy required-verification field names
- untouched owned surfaces checked: aggregated synthetic reviewer sections only
- boundary / fallback / alias paths checked: legacy NOT RUN and reduced-section reviewer fixture forms
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: aggregated current reviewer contract validation
- artifact pointer: /tmp/native-reviewer-surface-aggregated-request-changes.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: /tmp/native-reviewer-surface-aggregated-request-changes.log
- next action consistency: keep the review on the actionable rework path

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: aggregated synthetic reviewer contract fixture
- scope declaration: aggregated reviewer contract smoke coverage
- verification result: synthetic PASS placeholder for Request Changes path
- evidence destination: tmp/native reviewer smoke aggregated assertions
- artifact: /tmp/native-reviewer-surface-aggregated-request-changes.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [ ] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [x] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

assert_current_review_contract "$aggregated_report"
run_auto_function 'validate_review_output_format "$1"' "$aggregated_report"

aggregated_remote_url_report="$tmpdir/aggregated_remote_url_report.md"
cp "$aggregated_report" "$aggregated_remote_url_report"
/usr/bin/perl -0pi -e '
  s{- artifact pointer: reviewer-artifacts/aggregated-pass\.log}{- artifact pointer: https://example.com/reviewer-proof.log};
  s{- evidence pointer: reviewer-artifacts/aggregated-pass\.log}{- evidence pointer: https://example.com/reviewer-proof.log};
  s{- artifact: reviewer-artifacts/aggregated-pass\.log}{- artifact: https://example.com/reviewer-proof.log};
' "$aggregated_remote_url_report"
assert_current_review_contract "$aggregated_remote_url_report"
run_auto_function 'validate_review_output_format "$1"' "$aggregated_remote_url_report"

aggregated_missing_required_verification_report="$tmpdir/aggregated_missing_required_verification_report.md"
cp "$aggregated_report" "$aggregated_missing_required_verification_report"
/usr/bin/perl -0pi -e '
  s/- artifact pointer: reviewer-artifacts\/aggregated-pass\.log/- artifact pointer: reviewer-artifacts\/missing-required-verification.log/
' "$aggregated_missing_required_verification_report"
if current_review_contract_is_valid "$aggregated_missing_required_verification_report"; then
  fail "FINAL LGTM with missing Required Verification artifact unexpectedly satisfied the current reviewer contract"
fi

aggregated_missing_diff_evidence_report="$tmpdir/aggregated_missing_diff_evidence_report.md"
cp "$aggregated_report" "$aggregated_missing_diff_evidence_report"
/usr/bin/perl -0pi -e '
  s/- evidence pointer: reviewer-artifacts\/aggregated-pass\.log/- evidence pointer: reviewer-artifacts\/missing-diff-evidence.log/
' "$aggregated_missing_diff_evidence_report"
if current_review_contract_is_valid "$aggregated_missing_diff_evidence_report"; then
  fail "FINAL LGTM with missing DIFF evidence pointer unexpectedly satisfied the current reviewer contract"
fi

aggregated_missing_evidence_reviewed_artifact_report="$tmpdir/aggregated_missing_evidence_reviewed_artifact_report.md"
cp "$aggregated_report" "$aggregated_missing_evidence_reviewed_artifact_report"
/usr/bin/perl -0pi -e '
  s/- artifact: reviewer-artifacts\/aggregated-pass\.log/- artifact: reviewer-artifacts\/missing-evidence-reviewed.log/
' "$aggregated_missing_evidence_reviewed_artifact_report"
if current_review_contract_is_valid "$aggregated_missing_evidence_reviewed_artifact_report"; then
  fail "FINAL LGTM with missing Evidence Reviewed artifact unexpectedly satisfied the current reviewer contract"
fi

aggregated_missing_first_evidence_reviewed_artifact_report="$tmpdir/aggregated_missing_first_evidence_reviewed_artifact_report.md"
cp "$aggregated_report" "$aggregated_missing_first_evidence_reviewed_artifact_report"
/usr/bin/perl -0pi -e '
  s/- artifact: reviewer-artifacts\/aggregated-pass\.log/- artifact: reviewer-artifacts\/missing-first-evidence-reviewed.log\n- artifact: reviewer-artifacts\/aggregated-pass.log/
' "$aggregated_missing_first_evidence_reviewed_artifact_report"
if current_review_contract_is_valid "$aggregated_missing_first_evidence_reviewed_artifact_report"; then
  fail "FINAL LGTM with multiple Evidence Reviewed artifacts unexpectedly ignored an earlier missing local artifact"
fi

no_change_final_report="$tmpdir/no_change_final_report.md"
cat > "$no_change_final_report" <<EOF
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-no-change
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- worker outcome: NO-CHANGE
- request objective: Confirm that final-review NO-CHANGE evidence still validates under the current reviewer contract.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: LGTM
- outgoing next status: pending acceptance
- next action: Preserve the NO-CHANGE evidence packet and proceed with acceptance handling.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-no-change
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- change surface: synthetic NO-CHANGE reviewer contract fixture
- in-scope: final-review NO-CHANGE contract validation for local artifact traceability
- out-of-scope: queue runtime behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke no-change assertions
- completion boundary: final-review NO-CHANGE evidence validates with local artifact traceability enforced
- class closure sheet: tmp/native reviewer smoke no-change assertions
- sheet status: CLOSED
- owned sink universe: native reviewer no-change output boundary
- closed universe status: YES
- closed universe basis: no-change reviewer contract exhaustively checked for the owned surface
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 4/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:14:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic NO-CHANGE review report.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic NO-CHANGE reviewer contract fixture
- in-scope: final-review NO-CHANGE evidence validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke no-change assertions
- completion boundary: final-review NO-CHANGE report validates

## Class Closure Sheet
- bug class: reviewer-output-hygiene
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-no-change
- change surface: synthetic NO-CHANGE reviewer contract fixture
- owned sink universe: native reviewer no-change output boundary
- closed universe basis: no-change reviewer contract exhaustively checked for the owned surface
- closed universe status: YES
- search method / exact commands: rg -n "NO-CHANGE|search / verification evidence|artifact integrity" test/integration/native_reviewer_surface_smoke.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: 0
- basis: no-change reviewer surface fully traced for the owned sink universe
- timestamp: 2026-04-18T09:14:00Z
- target scope: no-change reviewer contract smoke fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:15:00Z
- reviewer request target: FINAL
- search commands: rg -n "NO-CHANGE|search / verification evidence|artifact:" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: the no-change report still relies on reasoning-only evidence
- untouched owned surfaces checked: synthetic NO-CHANGE reviewer sections only
- boundary / fallback / alias paths checked: file://localhost local proof, file:// alias normalization, and relative artifact aliases
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: final-review NO-CHANGE contract validation
- artifact pointer: reviewer-artifacts/no-change-required-verification.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active \`worker outcome\`; \`worker outcome=BLOCK\` intake is invalid and must be rerouted to a block report

### NO-CHANGE Payload Reviewed
- searched surface: native reviewer NO-CHANGE contract fixture
- no-diff reason: no owned reviewer-surface diff remains after the local artifact traceability hardening
- search / verification evidence: $no_change_evidence_uri
- last-reviewed baseline: synthetic reviewer baseline at 2026-04-18T09:00:00Z
- closed-universe claim: YES

## Evidence Reviewed
- diff: synthetic no-diff fixture
- change surface declaration: synthetic NO-CHANGE reviewer contract fixture
- scope declaration: final-review NO-CHANGE smoke coverage
- verification result: synthetic PASS placeholder for NO-CHANGE path
- evidence destination: tmp/native reviewer smoke no-change assertions
- artifact: reviewer-artifacts/no-change-reviewed.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [x] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

assert_current_review_contract "$no_change_final_report"
run_auto_function 'validate_review_output_format "$1"' "$no_change_final_report"

no_change_remote_evidence_report="$tmpdir/no_change_remote_evidence_report.md"
cp "$no_change_final_report" "$no_change_remote_evidence_report"
/usr/bin/perl -0pi -e "s{\\Q$no_change_evidence_uri\\E}{https://example.com/no-change-proof.log}" \
  "$no_change_remote_evidence_report"
assert_current_review_contract "$no_change_remote_evidence_report"
run_auto_function 'validate_review_output_format "$1"' "$no_change_remote_evidence_report"

no_change_missing_evidence_report="$tmpdir/no_change_missing_evidence_report.md"
cp "$no_change_final_report" "$no_change_missing_evidence_report"
/usr/bin/perl -0pi -e "s{\\Q$no_change_evidence_uri\\E}{file://localhost$reviewer_artifact_dir/missing-no-change-evidence.log}" \
  "$no_change_missing_evidence_report"
if current_review_contract_is_valid "$no_change_missing_evidence_report"; then
  fail "FINAL LGTM with missing NO-CHANGE evidence unexpectedly satisfied the current reviewer contract"
fi

cat > "$invalid_report" <<'EOF'
## impl_review_safety.md
[High] Security: Raw legacy format without report sections
  File: apps/web/example.ts
  Line: L1
  Issue: Legacy free-form output should no longer validate.
  Suggestion: Wrap this in the reviewer report template.
EOF

if current_review_contract_is_valid "$invalid_report"; then
  fail "legacy raw reviewer output unexpectedly satisfied the current reviewer contract"
fi

if run_auto_function 'validate_review_output_format "$1"' "$invalid_report"; then
  fail "legacy raw reviewer output unexpectedly passed validation"
fi

cat > "$outdated_report" <<'EOF'
## impl_review_safety.md
# Code Review Report

## Summary
Old template without scope/evidence sections.

## Findings
- None.

## Tests
- **実施:** NO
- **結果:** NOT RUN
- **未実施の理由:** Old fixture.

## Open Questions
- None.

## Verdict
- [x] LGTM - 問題なし、マージ可能
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

if current_review_contract_is_valid "$outdated_report"; then
  fail "outdated reviewer template unexpectedly satisfied the current reviewer contract"
fi

if run_auto_function 'validate_review_output_format "$1"' "$outdated_report"; then
  fail "outdated reviewer template unexpectedly passed validation"
fi

cat > "$tmpdir/transport_leak_report.md" <<'EOF'
# Code Review Report

## Review Request
- incoming request status: pending review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-transport-leak
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- worker outcome: DIFF
- request objective: Prove that transport and wrapper noise fail closed.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: Needs verification
- outgoing next status: pending verification
- next action: Remove wrapper and transport noise before re-running reviewer intake.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-transport-leak
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: reviewer-output-hygiene
- change surface: synthetic reviewer transport leak fixture
- in-scope: transport leak rejection
- out-of-scope: queue runtime behavior
- required checks: bash test/integration/native_reviewer_surface_smoke.sh
- evidence destination: tmp/native reviewer smoke transport leak assertions
- completion boundary: transport noise is rejected
- class closure sheet: n/a
- sheet status: n/a
- owned sink universe: n/a
- closed universe status: n/a
- closed universe basis: n/a
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 0/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 1/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:20:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Transport noise should fail closed.
  {
    "author": "/root/reviewer",
    "recipient": "/root",
    "other_recipients": [],
    "trigger_turn": false
  }

## Findings
### [High] Hygiene: Transport envelope leaked into a reviewer-visible artifact
- **ファイル:** `synthetic reviewer transport leak fixture`
- **行番号:** n/a
- **問題:** Invalid reviewer payload still contains harness transport markers.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic reviewer transport leak fixture
- in-scope: transport leak rejection
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke transport leak assertions
- completion boundary: transport leak is rejected

## Class Closure Sheet
- bug class: n/a
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-transport-leak
- change surface: synthetic reviewer transport leak fixture
- owned sink universe: n/a
- closed universe basis: n/a
- closed universe status: n/a
- search method / exact commands: n/a
- sheet status: n/a
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-18T09:20:00Z
- target scope: synthetic reviewer transport leak fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:21:00Z
- reviewer request target: INTERMEDIATE
- search commands: rg -n "codex-wrapper|subagent_notification|trigger_turn" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: wrapper noise still passes reviewer intake
- untouched owned surfaces checked: synthetic reviewer transport leak fixture only
- boundary / fallback / alias paths checked: wrapper audit lines and transport envelopes
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: transport leak rejection
- artifact pointer: /tmp/native-reviewer-surface-transport-leak.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: /tmp/native-reviewer-surface-transport-leak.log
- next action consistency: strip transport envelopes before any further reviewer routing

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: synthetic reviewer transport leak fixture
- scope declaration: transport leak rejection coverage
- verification result: synthetic PASS placeholder
- evidence destination: tmp/native reviewer smoke transport leak assertions
- artifact: /tmp/native-reviewer-surface-transport-leak.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [ ] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [x] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

if current_review_contract_is_valid "$tmpdir/transport_leak_report.md"; then
  fail "transport leak reviewer output unexpectedly satisfied the current reviewer contract"
fi

if run_auto_function 'validate_review_output_format "$1"' "$tmpdir/transport_leak_report.md"; then
  fail "transport leak reviewer output unexpectedly passed validation"
fi

escalation_report="$(run_auto_function '
  STATE_FILE=".claude/tmp/native-reviewer-surface/state.json"
  PLAN=".agent/active/sow/native-reviewer-surface.md"
  CODER_OUT=".claude/tmp/native-reviewer-surface/impl_coder.md"
  MAX_ITERATIONS=5
  generate_escalation_report "$1" "$2" "$3" "$4"
' "$tmpdir" "impl" "$tmpdir/transport_leak_report.md" "5")"
[[ -n "$escalation_report" && -f "$escalation_report" ]] || fail "escalation report was not created for invalid reviewer payload"
if grep -q '"trigger_turn"' "$escalation_report" \
  || grep -q '"other_recipients"' "$escalation_report" \
  || grep -q '<subagent_notification>' "$escalation_report"; then
  fail "escalation report raw-relayed invalid reviewer transport payload"
fi
grep -Fq '| [High]   | 0' "$escalation_report" \
  || fail "escalation report did not suppress invalid reviewer high severity counts"
grep -Fq '| [Medium] | 0' "$escalation_report" \
  || fail "escalation report did not suppress invalid reviewer medium severity counts"
grep -Fq '| [Low]    | 0' "$escalation_report" \
  || fail "escalation report did not suppress invalid reviewer low severity counts"
grep -q 'Severity Count Source.*suppressed (invalid reviewer payload)' "$escalation_report" \
  || fail "escalation report did not record suppressed severity count source for invalid reviewer payload"
grep -q 'suppressed invalid reviewer payload' "$escalation_report" \
  || fail "escalation report did not record suppressed invalid reviewer payload relay"

suppressed_issue_counts_output="$(
  run_auto_function '
    show_issue_counts "$1"
  ' "$tmpdir/transport_leak_report.md" 2>&1
)"
[[ "$suppressed_issue_counts_output" == *"Issue counts suppressed because reviewer output failed validation"* ]] \
  || fail "show_issue_counts did not suppress invalid reviewer payload counts"
[[ "$suppressed_issue_counts_output" == *"Issue counts: [High]=0 [Medium]=0 [Low]=0"* ]] \
  || fail "show_issue_counts did not zero invalid reviewer payload counts"
[[ "$suppressed_issue_counts_output" != *"Issue counts: [High]=1"* ]] \
  || fail "show_issue_counts still reflected invalid reviewer payload severity counts"

shadow_verify_output_dir="$tmpdir/shadow-verify"
mkdir -p "$shadow_verify_output_dir"
shadow_verify_diagnostics="$shadow_verify_output_dir/diagnostics.log"
cat > "$shadow_verify_diagnostics" <<'EOF'
<subagent_notification>
{"author":"diag-agent","recipient":"reviewer","other_recipients":[]}
"author":"diag-agent"
"trigger_turn":true
DIAGNOSTIC_RAW_SNIPPET_SENTINEL
</subagent_notification>
EOF
cat > "$shadow_verify_output_dir/impl_shadow_verify_iter7.json" <<EOF
{
  "status": "pass",
  "iteration": 7,
  "lint": { "status": "pass" },
  "typecheck": { "status": "pass" },
  "test": { "status": "pass" },
  "quality_gate": { "status": "pass" },
  "sast": {
    "status": "pass",
    "findings": { "high": 0, "critical": 0 }
  },
  "changed_files_count": 1,
  "selected_tests_count": 1,
  "diagnostics": "$shadow_verify_diagnostics"
}
EOF
shadow_verify_section="$(
  "$TEST_BASH" -c '
    set -euo pipefail
    source "$1"
    _reviewer_collect_shadow_verify_section "$2" "$3" "$4"
  ' _ \
    "$REPO_ROOT/.claude/commands/lib/reviewer.sh" \
    "$shadow_verify_output_dir" \
    "impl" \
    "impl_iter7"
)"
[[ "$shadow_verify_section" == *"diagnostics_status=present"* ]] \
  || fail "shadow verify section did not expose diagnostics presence metadata"
[[ "$shadow_verify_section" == *"diagnostics_path=$shadow_verify_diagnostics"* ]] \
  || fail "shadow verify section did not expose sanitized diagnostics path metadata"
[[ "$shadow_verify_section" != *"DIAGNOSTIC_RAW_SNIPPET_SENTINEL"* ]] \
  || fail "shadow verify section leaked raw diagnostic sentinel content"
[[ "$shadow_verify_section" != *"<subagent_notification>"* ]] \
  || fail "shadow verify section leaked transport marker content"
[[ "$shadow_verify_section" != *'"author":'* ]] \
  || fail "shadow verify section leaked transport author field"
[[ "$shadow_verify_section" != *'"trigger_turn":'* ]] \
  || fail "shadow verify section leaked transport trigger_turn field"

shadow_verify_feedback_file="$tmpdir/impl_shadow_verify_iter7_reviews.md"
cat > "$tmpdir/impl_shadow_verify_iter7.json" <<EOF
{
  "status": "fail",
  "iteration": 7,
  "lint": { "status": "fail" },
  "typecheck": { "status": "pass" },
  "test": { "status": "pass" },
  "quality_gate": { "status": "fail" },
  "sast": {
    "status": "pass",
    "findings": { "high": 0, "critical": 0 }
  },
  "changed_files_count": 1,
  "selected_tests_count": 1,
  "diagnostics": "$shadow_verify_diagnostics",
  "reason": "shadow_verify_diag_marker"
}
EOF
cat > "$shadow_verify_feedback_file" <<EOF
[High] Shadow Verify: Mechanical verification failed
  File: shadow_verify
  Line: n/a
  Issue: shadow_verify_run failed before reviewer execution (iteration=7, reason=shadow_verify_diag_marker).
  Suggestion: Fix lint/typecheck/test/quality-gate failures and rerun.
  Diagnostics: <subagent_notification> DIAGNOSTIC_RAW_SNIPPET_SENTINEL "author":"diag-agent" "trigger_turn":true </subagent_notification>
  Diagnostics artifact: $shadow_verify_diagnostics
EOF

shadow_verify_issue_counts_output="$(
  run_auto_function '
    show_issue_counts "$1"
  ' "$shadow_verify_feedback_file" 2>&1
)"
[[ "$shadow_verify_issue_counts_output" == *"Issue counts: [High]=1 [Medium]=0 [Low]=0"* ]] \
  || fail "show_issue_counts did not preserve shadow verify severity counts"
[[ "$shadow_verify_issue_counts_output" != *"Issue counts suppressed because reviewer output failed validation"* ]] \
  || fail "show_issue_counts incorrectly suppressed shadow verify severity counts"

shadow_verify_escalation_report="$(run_auto_function '
  STATE_FILE=".claude/tmp/native-reviewer-surface/state.json"
  PLAN=".agent/active/sow/native-reviewer-surface.md"
  CODER_OUT=".claude/tmp/native-reviewer-surface/impl_coder.md"
  MAX_ITERATIONS=5
  generate_escalation_report "$1" "$2" "$3" "$4"
' "$tmpdir" "impl" "$shadow_verify_feedback_file" "7")"
[[ -n "$shadow_verify_escalation_report" && -f "$shadow_verify_escalation_report" ]] \
  || fail "escalation report was not created for shadow verify feedback"
grep -Fq '| [High]   | 1' "$shadow_verify_escalation_report" \
  || fail "escalation report did not preserve shadow verify high severity counts"
grep -q 'Severity Count Source.*sanitized shadow-verify feedback' "$shadow_verify_escalation_report" \
  || fail "escalation report did not record shadow verify severity count source"
grep -q 'relay mode: sanitized shadow-verify feedback' "$shadow_verify_escalation_report" \
  || fail "escalation report did not use sanitized shadow verify relay mode"
grep -q 'shadow_verify_run failed before reviewer execution (iteration=7, reason=shadow_verify_diag_marker)' "$shadow_verify_escalation_report" \
  || fail "escalation report did not preserve sanitized shadow verify issue content"
grep -Fq "$shadow_verify_diagnostics" "$shadow_verify_escalation_report" \
  || fail "escalation report did not preserve shadow verify diagnostics artifact path"
if grep -q 'DIAGNOSTIC_RAW_SNIPPET_SENTINEL' "$shadow_verify_escalation_report" \
  || grep -q '<subagent_notification>' "$shadow_verify_escalation_report" \
  || grep -q '"author":' "$shadow_verify_escalation_report" \
  || grep -q '"trigger_turn":' "$shadow_verify_escalation_report"; then
  fail "escalation report leaked raw shadow verify transport diagnostics"
fi

cat > "$unknown_verdict_report" <<'EOF'
## impl_review_safety.md
# Code Review Report

## Review Request
- incoming request status: pending review
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: n/a
- worker outcome: DIFF
- request objective: Prove that an unknown verdict label fails closed in the current reviewer schema.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: Maybe
- outgoing next status: pending review
- next action: Replace the unknown verdict with a canonical reviewer outcome.

## Slice Contract
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: n/a
- change surface: synthetic reviewer verdict extraction fixture
- in-scope: verdict extraction validation against the current reviewer schema
- out-of-scope: runtime queue behavior and hook execution path
- required checks: git diff --check on owned files; bash -n; targeted native reviewer smoke
- evidence destination: tmp/native reviewer smoke verdict assertions
- completion boundary: unknown verdict is rejected by both schema assertions and runtime validator
- class closure sheet: n/a
- sheet status: n/a
- owned sink universe: n/a
- closed universe status: n/a
- closed universe basis: n/a
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 4/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:15:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Unknown verdict label should fail closed.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic reviewer verdict extraction fixture
- in-scope: verdict extraction validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- evidence destination: tmp/native reviewer smoke verdict assertions
- completion boundary: invalid verdict blocks

## Class Closure Sheet
- bug class: n/a
- task id: task-20260418-native-reviewer-surface
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260418-native-reviewer-surface
- prior task id: none
- slice id: slice-native-reviewer-surface-smoke
- change surface: synthetic reviewer verdict extraction fixture
- owned sink universe: n/a
- closed universe basis: n/a
- closed universe status: n/a
- search method / exact commands: n/a
- sheet status: n/a
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-18T09:15:00Z
- target scope: reviewer verdict extraction smoke fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-18T09:16:00Z
- reviewer request target: INTERMEDIATE
- search commands: rg -n "## Verdict|review verdict" test/integration/native_reviewer_surface_smoke.sh
- opposite hypothesis checked: an unknown verdict label still slips through the reviewer parser
- untouched owned surfaces checked: synthetic reviewer verdict fixture only
- boundary / fallback / alias paths checked: legacy NOT RUN and non-canonical verdict labels
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: PASS
- covered scope: current reviewer verdict extraction validation
- artifact pointer: /tmp/native-reviewer-surface-unknown-verdict.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: test/integration/native_reviewer_surface_smoke.sh
- evidence pointer: /tmp/native-reviewer-surface-unknown-verdict.log
- next action consistency: replace the verdict label before any routing decision

## Evidence Reviewed
- diff: synthetic diff fixture
- change surface declaration: synthetic reviewer verdict extraction fixture
- scope declaration: reviewer verdict extraction smoke coverage
- verification result: synthetic PASS placeholder prior to verdict parsing
- evidence destination: tmp/native reviewer smoke verdict assertions
- artifact: /tmp/native-reviewer-surface-unknown-verdict.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [x] Maybe - custom verdict should fail
- [ ] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
EOF

if current_review_contract_is_valid "$unknown_verdict_report"; then
  fail "unknown verdict unexpectedly satisfied the current reviewer contract"
fi

if run_auto_function 'validate_review_output_format "$1"' "$unknown_verdict_report"; then
  fail "unknown verdict unexpectedly passed validation"
fi

if run_auto_function '_extract_review_report_verdict "$1"' "$unknown_verdict_report"; then
  fail "unknown verdict unexpectedly extracted"
fi

cargo test -p agent-core --manifest-path "$RUST_MANIFEST" cmd::review::tests::
cargo test -p agent-core --manifest-path "$RUST_MANIFEST" \
  cmd::orchestrate::tests::test_review_verdict_routing_contract
cargo test -p shared --manifest-path "$RUST_MANIFEST" review_verdict_contract_helpers

printf 'PASS: native_reviewer_surface_smoke\n'
