set -u -o pipefail
source .claude/commands/auto_orchestrate.sh
set +e

SEMANTIC_QUEUE_CLI="$REAL_SEMANTIC_QUEUE_CLI"

state_dir=".claude/tmp/${TEST_TASK_NAME}"
mkdir -p "$state_dir"
state_init "$TEST_PLAN_PATH" "$TEST_TASK_NAME" "$state_dir" >/dev/null
state_upsert_phase "impl" 1
state_set '.status' '"running"'
state_set_phase_status "impl" "running"
state_save

  case "$TEST_SCENARIO" in
  success)
    _run_batch_review_reviewer() {
      local input_file="$1"
      local output_file="$2"
      : "${input_file:?}"
      cat > "$output_file" <<'REVIEW'
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-success
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: queue-runtime
- worker outcome: DIFF
- request objective: Allow the leased queue item to complete when the synthetic reviewer returns canonical LGTM.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: LGTM
- outgoing next status: pending acceptance
- next action: Complete the leased queue item and persist the review run.

## Slice Contract
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-success
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: queue-runtime
- change surface: synthetic queue runtime success fixture
- in-scope: canonical reviewer LGTM path for queue completion
- out-of-scope: real Codex execution
- required checks: bash test/integration/semantic_review_queue_runtime_test.sh
- evidence destination: tmp/queue runtime success assertions
- completion boundary: LGTM verdict may complete the leased queue item
- class closure sheet: tmp/queue runtime success assertions
- sheet status: CLOSED
- owned sink universe: queue runtime completion surface
- closed universe status: YES
- closed universe basis: synthetic success fixture fully traces the leased completion path
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
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-22T00:00:00Z; last-progress=2026-04-22T00:00:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic queue runtime success fixture returns canonical LGTM.
The lease may complete because the reviewer contract is satisfied.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic queue runtime success fixture
- in-scope: canonical reviewer LGTM path for queue completion
- out-of-scope: real Codex execution
- 対象 hunk / ownership: test fixture only
- evidence destination: tmp/queue runtime success assertions
- completion boundary: LGTM verdict may complete the leased queue item

## Class Closure Sheet
- bug class: queue-runtime
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-success
- change surface: synthetic queue runtime success fixture
- owned sink universe: queue runtime completion surface
- closed universe basis: synthetic success fixture fully traces the leased completion path
- closed universe status: YES
- search method / exact commands: rg -n "queue-runtime-success|pending acceptance|artifact integrity" test/integration/semantic_review_queue_runtime_test.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-22T00:00:00Z
- target scope: queue runtime success fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-22T00:00:01Z
- reviewer request target: FINAL
- search commands: rg -n "Review Request|Review Outcome|Verdict" test/integration/semantic_review_queue_runtime_test.sh
- opposite hypothesis checked: success fixture still uses the reduced reviewer schema
- untouched owned surfaces checked: queue runtime success fixture only
- boundary / fallback / alias paths checked: legacy verdict checklist and reduced required verification fields
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/semantic_review_queue_runtime_test.sh
- result: PASS
- covered scope: queue runtime success reviewer fixture
- artifact pointer: /tmp/queue-runtime-success.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: src/success.ts
- evidence pointer: /tmp/queue-runtime-success.log
- next action consistency: complete the leased queue item and persist the run

## Evidence Reviewed
- diff: synthetic success fixture
- change surface declaration: synthetic queue runtime success fixture
- scope declaration: synthetic queue runtime success fixture
- verification result: synthetic queue runtime fixture
- evidence destination: tmp/queue runtime success assertions
- artifact: /tmp/queue-runtime-success.log

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
REVIEW
      return 0
    }
    ;;
  request-changes)
    _run_batch_review_reviewer() {
      local input_file="$1"
      local output_file="$2"
      : "${input_file:?}"
      cat > "$output_file" <<'REVIEW'
# Code Review Report

## Review Request
- incoming request status: pending review
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-request-changes
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: queue-runtime
- worker outcome: DIFF
- request objective: Requeue the leased item when the synthetic reviewer returns Request Changes.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: Request Changes
- outgoing next status: pending review
- next action: Requeue the leased item instead of completing it.

## Slice Contract
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-request-changes
- prior slice id: none
- review request target: INTERMEDIATE
- discovery owner: coder
- bug class candidate: queue-runtime
- change surface: synthetic queue runtime request-changes fixture
- in-scope: canonical Request Changes path for queue requeue
- out-of-scope: real Codex execution
- required checks: bash test/integration/semantic_review_queue_runtime_test.sh
- evidence destination: tmp/queue runtime request-changes assertions
- completion boundary: non-LGTM verdict requeues the leased item
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
- cumulative reviewer requests for task: 2/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-22T00:00:00Z; last-progress=2026-04-22T00:01:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic queue runtime fixture returns Request Changes.
The lease must be requeued rather than completed.

## Findings
### [High] Consistency: Queue item must not complete
- **ファイル:** `src/request-changes.ts`
- **行番号:** L1
- **問題:** Reviewer explicitly requested changes.
- **影響:** Queue completion would hide a blocking review result.
- **修正案:** Honor the verdict before completing the queue item.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic queue runtime request-changes fixture
- in-scope: canonical Request Changes path for queue requeue
- out-of-scope: real Codex execution
- 対象 hunk / ownership: test fixture only
- evidence destination: tmp/queue runtime request-changes assertions
- completion boundary: non-LGTM verdict requeues the leased item

## Class Closure Sheet
- bug class: n/a
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-request-changes
- change surface: synthetic queue runtime request-changes fixture
- owned sink universe: n/a
- closed universe basis: n/a
- closed universe status: n/a
- search method / exact commands: n/a
- sheet status: n/a
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-22T00:01:00Z
- target scope: queue runtime request-changes fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-22T00:01:01Z
- reviewer request target: INTERMEDIATE
- search commands: rg -n "Request Changes|pending review" test/integration/semantic_review_queue_runtime_test.sh
- opposite hypothesis checked: request-changes fixture still bypasses canonical reviewer routing
- untouched owned surfaces checked: queue runtime request-changes fixture only
- boundary / fallback / alias paths checked: legacy reduced reviewer schema and invalid verdict extraction
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/semantic_review_queue_runtime_test.sh
- result: PASS
- covered scope: queue runtime request-changes reviewer fixture
- artifact pointer: /tmp/queue-runtime-request-changes.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: src/request-changes.ts
- evidence pointer: /tmp/queue-runtime-request-changes.log
- next action consistency: requeue the leased item instead of completing it

## Evidence Reviewed
- diff: synthetic request-changes fixture
- change surface declaration: synthetic queue runtime request-changes fixture
- scope declaration: synthetic queue runtime request-changes fixture
- verification result: synthetic queue runtime fixture
- evidence destination: tmp/queue runtime request-changes assertions
- artifact: /tmp/queue-runtime-request-changes.log

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
REVIEW
      return 0
    }
    ;;
  failure)
    _run_batch_review_reviewer() {
      local input_file="$1"
      local output_file="$2"
      : "${input_file:?}"
      cat > "$output_file" <<'RAW'
RAW_TRANSPORT_MARKER failure-payload
REVIEW_BODY_MARKER reviewer failed hard
RAW
      return 42
    }
    ;;
  invalid-format)
    _run_batch_review_reviewer() {
      local input_file="$1"
      local output_file="$2"
      : "${input_file:?}" "${output_file:?}"
      cat > "$output_file" <<'RAW'
RAW_TRANSPORT_MARKER invalid-format
REVIEW_BODY_MARKER synthetic invalid reviewer payload
RAW
      return 0
    }
    ;;
  stale-json)
    _run_batch_review_reviewer() {
      echo "unexpected reviewer execution" >&2
      return 93
    }
    ;;
  partial-lease-loss)
    _run_batch_review_reviewer() {
      local input_file="$1"
      local output_file="$2"
      : "${input_file:?}" "${output_file:?}"

      local project_id=""
      local db_path=""
      project_id="$(bash scripts/project-id.sh read)"
      db_path="$HOME/.semantic-mcp/${project_id}/semantic.db"

      (
        "$REAL_NODE_BIN" --input-type=module - \
          "$db_path" \
          "$project_id" \
          "$REAL_REPO_ROOT/scripts/semantic-mcp-server/dist/db/connection.js" <<'NODE'
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
const dbPath = process.argv[2];
const projectId = process.argv[3];
const resolverPath = process.argv[4];
const require = createRequire(pathToFileURL(resolverPath));
const Database = require("better-sqlite3");
const db = new Database(dbPath);
db.prepare(
  `
    UPDATE review_queue_items
    SET lease_expires_at = '2000-01-01T00:00:00Z'
    WHERE project_id = ? AND file_path = ?
  `
).run(projectId, "src/partial-a.ts");
db.close();
NODE
      ) || return 95

      HOME="$HOME" "$REAL_NODE_BIN" "$REAL_SEMANTIC_QUEUE_CLI" \
        queue lease \
        --project-id "$project_id" \
        --lease-run-id partial-second \
        --lease-seconds 60 >/dev/null || return 96

      cat > "$output_file" <<'REVIEW'
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-partial-lease-loss
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: queue-runtime
- worker outcome: DIFF
- request objective: Reach queue finalize with a canonical LGTM before the partial lease-loss check fails closed.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: LGTM
- outgoing next status: pending acceptance
- next action: Attempt queue finalize and let the lease-loss guard fail closed.

## Slice Contract
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-partial-lease-loss
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: queue-runtime
- change surface: synthetic queue runtime partial lease-loss fixture
- in-scope: canonical LGTM path before finalize detects a lease-loss race
- out-of-scope: real Codex execution
- required checks: bash test/integration/semantic_review_queue_runtime_test.sh
- evidence destination: tmp/queue runtime partial lease-loss assertions
- completion boundary: queue finalize reaches the lease-loss guard
- class closure sheet: tmp/queue runtime partial lease-loss assertions
- sheet status: CLOSED
- owned sink universe: queue runtime finalize lease-loss surface
- closed universe status: YES
- closed universe basis: synthetic partial lease-loss fixture fully traces the finalize guard path
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
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-22T00:00:00Z; last-progress=2026-04-22T00:02:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic queue runtime fixture reaches finalize with canonical LGTM.
The lease-loss guard should block completion after reviewer intake succeeds.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic queue runtime partial lease-loss fixture
- in-scope: canonical LGTM path before finalize detects a lease-loss race
- out-of-scope: real Codex execution
- 対象 hunk / ownership: test fixture only
- evidence destination: tmp/queue runtime partial lease-loss assertions
- completion boundary: queue finalize reaches the lease-loss guard

## Class Closure Sheet
- bug class: queue-runtime
- task id: task-20260422-queue-runtime
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-queue-runtime
- prior task id: none
- slice id: slice-queue-runtime-partial-lease-loss
- change surface: synthetic queue runtime partial lease-loss fixture
- owned sink universe: queue runtime finalize lease-loss surface
- closed universe basis: synthetic partial lease-loss fixture fully traces the finalize guard path
- closed universe status: YES
- search method / exact commands: rg -n "partial-lease-loss|pending acceptance|artifact integrity" test/integration/semantic_review_queue_runtime_test.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: n/a
- basis: n/a
- timestamp: 2026-04-22T00:02:00Z
- target scope: queue runtime partial lease-loss fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-22T00:02:01Z
- reviewer request target: FINAL
- search commands: rg -n "lease-loss|pending acceptance" test/integration/semantic_review_queue_runtime_test.sh
- opposite hypothesis checked: canonical LGTM path still bypasses the finalize lease-loss guard
- untouched owned surfaces checked: queue runtime partial lease-loss fixture only
- boundary / fallback / alias paths checked: reduced reviewer schema and stale finalize assumptions
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/semantic_review_queue_runtime_test.sh
- result: PASS
- covered scope: queue runtime partial lease-loss reviewer fixture
- artifact pointer: /tmp/queue-runtime-partial-lease-loss.log
- no-artifact reason: n/a
- artifact integrity: complete

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: src/partial-a.ts, src/partial-b.ts
- evidence pointer: /tmp/queue-runtime-partial-lease-loss.log
- next action consistency: attempt finalize and let the lease-loss guard own the fail-closed transition

## Evidence Reviewed
- diff: synthetic partial fixture
- change surface declaration: synthetic queue runtime partial lease-loss fixture
- scope declaration: synthetic queue runtime partial lease-loss fixture
- verification result: synthetic queue runtime fixture
- evidence destination: tmp/queue runtime partial lease-loss assertions
- artifact: /tmp/queue-runtime-partial-lease-loss.log

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
REVIEW
      return 0
    }
    ;;
  *)
    echo "unknown scenario: $TEST_SCENARIO" >&2
    exit 94
    ;;
esac

result="$(run_batch_review "$state_dir" "impl")"
rc=$?
printf 'RESULT_PATH=%s\n' "$result"
printf 'RESULT_RC=%s\n' "$rc"
