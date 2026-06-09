#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_GATE="$PROJECT_ROOT/test/integration/harness_release_gate.sh"
OUT_ROOT="$PROJECT_ROOT/.claude/tmp/harness-release-gate"
BASH_BIN="${HARNESS_RELEASE_GATE_BASH:-/bin/bash}"

if [[ -x "$BASH_BIN" && "${BASH:-}" != "$BASH_BIN" && -z "${HARNESS_RELEASE_GATE_TIERING_TEST_REEXECED:-}" ]]; then
  export HARNESS_RELEASE_GATE_TIERING_TEST_REEXECED=1
  exec "$BASH_BIN" "$0" "$@"
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-release-gate-tiering.XXXXXX")"
trap '/bin/rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

mtime_of() {
  local path="$1"
  if stat -f '%m' "$path" >/dev/null 2>&1; then
    stat -f '%m' "$path"
  else
    stat -c '%Y' "$path"
  fi
}

size_of() {
  local path="$1"
  if stat -f '%z' "$path" >/dev/null 2>&1; then
    stat -f '%z' "$path"
  else
    stat -c '%s' "$path"
  fi
}

snapshot_release_gate_state() {
  local dest="$1"
  local path_count="0"
  local run_dir_count="0"
  local path=""
  local rel=""
  local type=""
  local mtime=""
  local size=""
  local hash=""

  : > "$dest"

  if [[ ! -e "$OUT_ROOT" && ! -L "$OUT_ROOT" ]]; then
    printf 'root\tabsent\n' >> "$dest"
    return 0
  fi

  path_count="$(find "$OUT_ROOT" -print | wc -l | tr -d ' ')"
  if [[ -d "$OUT_ROOT/runs" && ! -L "$OUT_ROOT/runs" ]]; then
    run_dir_count="$(find "$OUT_ROOT/runs" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')"
  fi

  printf 'path_count\t%s\n' "$path_count" >> "$dest"
  printf 'run_dir_count\t%s\n' "$run_dir_count" >> "$dest"

  {
    printf '%s\n' "$OUT_ROOT"
    printf '%s\n' "$OUT_ROOT/runs"
    printf '%s\n' "$OUT_ROOT/latest.json"
    printf '%s\n' "$OUT_ROOT/latest-success.json"
    printf '%s\n' "$OUT_ROOT/latest-failure.json"
    printf '%s\n' "$OUT_ROOT/latest-local.json"
    printf '%s\n' "$OUT_ROOT/latest-local-success.json"
    printf '%s\n' "$OUT_ROOT/latest-local-failure.json"
    if [[ -d "$OUT_ROOT/runs" && ! -L "$OUT_ROOT/runs" ]]; then
      find "$OUT_ROOT/runs" -mindepth 2 -maxdepth 2 -name artifact-lifecycle-manifest.json -type f -print
    fi
  } | LC_ALL=C sort -u | while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] || {
      rel="${path#"$PROJECT_ROOT"/}"
      printf 'selected\t%s\tabsent\t-\t-\t-\n' "$rel" >> "$dest"
      continue
    }
    rel="${path#"$PROJECT_ROOT"/}"
    mtime="$(mtime_of "$path")"
    size="-"
    hash="-"
    if [[ -L "$path" ]]; then
      type="symlink"
    elif [[ -d "$path" ]]; then
      type="dir"
    elif [[ -f "$path" ]]; then
      type="file"
      size="$(size_of "$path")"
      hash="$(shasum "$path" | awk '{print $1}')"
    else
      type="other"
    fi
    printf 'selected\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$type" "$mtime" "$size" "$hash" >> "$dest"
  done
}

assert_snapshot_unchanged() {
  local before="$1"
  local after="$2"
  local label="$3"

  if ! cmp -s "$before" "$after"; then
    diff -u "$before" "$after" >&2 || true
    fail "$label mutated .claude/tmp/harness-release-gate"
  fi
}

assert_quick_dispatch_precedes_run_dir_initialization() {
  local quick_line=""
  local run_id_line=""
  local run_dir_line=""
  local mkdir_line=""

  quick_line="$(awk '/if \[\[ "\$RELEASE_GATE_TIER" == "quick" \]\]/{print NR; exit}' "$RELEASE_GATE")"
  run_id_line="$(awk '/^RUN_ID=/{print NR; exit}' "$RELEASE_GATE")"
  run_dir_line="$(awk '/^RUN_DIR=/{print NR; exit}' "$RELEASE_GATE")"
  mkdir_line="$(awk '/^mkdir -p "\$RUN_DIR\/stderr"/{print NR; exit}' "$RELEASE_GATE")"

  [[ -n "$quick_line" ]] || fail "quick dispatch branch not found"
  [[ -n "$run_id_line" ]] || fail "RUN_ID initialization not found"
  [[ -n "$run_dir_line" ]] || fail "RUN_DIR initialization not found"
  [[ -n "$mkdir_line" ]] || fail "RUN_DIR mkdir initialization not found"

  [[ "$quick_line" -lt "$run_id_line" ]] || fail "quick dispatch must precede RUN_ID initialization"
  [[ "$quick_line" -lt "$run_dir_line" ]] || fail "quick dispatch must precede RUN_DIR initialization"
  [[ "$quick_line" -lt "$mkdir_line" ]] || fail "quick dispatch must precede release-gate mkdir"
}

assert_quick_dry_run_no_mutation() {
  local before="$TMP_ROOT/quick-dry-run.before"
  local after="$TMP_ROOT/quick-dry-run.after"
  local output=""

  snapshot_release_gate_state "$before"
  output="$("$BASH_BIN" "$RELEASE_GATE" --tier quick --dry-run 2>&1)"
  snapshot_release_gate_state "$after"

  contains "$output" "DRY-RUN: tier=quick" || fail "quick dry-run did not identify quick tier"
  contains "$output" "DRY-RUN: would exec scripts/harness-doctor.sh --quick" \
    || fail "quick dry-run did not report doctor quick argv"
  assert_snapshot_unchanged "$before" "$after" "quick dry-run"
}

assert_quick_exec_no_mutation() {
  local before="$TMP_ROOT/quick-exec.before"
  local after="$TMP_ROOT/quick-exec.after"
  local stub="$TMP_ROOT/harness-doctor.sh"
  local output=""

  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub-doctor argv:'
printf ' %s' "$@"
printf '\n'
EOF
  chmod +x "$stub"

  snapshot_release_gate_state "$before"
  output="$(HARNESS_RELEASE_GATE_DOCTOR="$stub" "$BASH_BIN" "$RELEASE_GATE" --tier quick 2>&1)"
  snapshot_release_gate_state "$after"

  contains "$output" "stub-doctor argv: --quick" \
    || fail "quick tier did not exec doctor with --quick"
  assert_snapshot_unchanged "$before" "$after" "quick exec"
}

assert_dry_run_tier_smoke() {
  local tier="$1"
  local before="$TMP_ROOT/$tier-dry-run.before"
  local after="$TMP_ROOT/$tier-dry-run.after"
  local output=""

  snapshot_release_gate_state "$before"
  output="$("$BASH_BIN" "$RELEASE_GATE" --tier "$tier" --dry-run 2>&1)"
  snapshot_release_gate_state "$after"

  contains "$output" "DRY-RUN: tier=$tier" || fail "$tier dry-run did not identify tier"
  contains "$output" "DRY-RUN: step=" || fail "$tier dry-run did not list steps"
  contains "$output" "harness_doctor_quick" || fail "$tier dry-run did not include quick doctor test"
  contains "$output" "harness_release_gate_tiering" || fail "$tier dry-run did not include tiering test"
  assert_snapshot_unchanged "$before" "$after" "$tier dry-run"
}

assert_default_full_dry_run_smoke() {
  local output=""
  output="$("$BASH_BIN" "$RELEASE_GATE" --dry-run 2>&1)"
  contains "$output" "DRY-RUN: tier=full" || fail "default dry-run did not preserve full tier default"
  contains "$output" "semantic_rust_build" || fail "default full dry-run did not include full gate steps"
}

assert_canonical_minimal_full_rejected() {
  assert_minimal_rejected_for_out_root "$PROJECT_ROOT/.claude/tmp/harness-release-gate" "canonical"
  assert_minimal_rejected_for_out_root "$PROJECT_ROOT/.claude/tmp/harness-release-gate/." "pwd-dot-alias"
  assert_minimal_rejected_for_out_root ".claude/tmp/harness-release-gate/../harness-release-gate" "dotdot-alias"
}

assert_minimal_rejected_for_out_root() {
  local out_root="$1"
  local label="$2"
  local output=""
  local status=0

  output="$(
    HARNESS_RELEASE_GATE_OUT_ROOT="$out_root" \
      HARNESS_RELEASE_GATE_TEST_STEPS=minimal \
      "$BASH_BIN" "$RELEASE_GATE" --tier full --dry-run 2>&1
  )" \
    || status=$?

  [[ "$status" -ne 0 ]] || fail "$label full dry-run must reject minimal test steps"
  contains "$output" "requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT" \
    || fail "$label minimal rejection did not explain isolated OUT_ROOT requirement"
  ! contains "$output" "DRY-RUN: step=minimal_probe" \
    || fail "$label minimal rejection must not emit minimal dry-run step evidence"

  status=0
  output="$(
    HARNESS_RELEASE_GATE_OUT_ROOT="$out_root" \
      HARNESS_RELEASE_GATE_TEST_STEPS=minimal \
      "$BASH_BIN" "$RELEASE_GATE" --tier full 2>&1
  )" \
    || status=$?

  [[ "$status" -ne 0 ]] || fail "$label full run must reject minimal test steps"
  contains "$output" "requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT" \
    || fail "$label minimal full run rejection did not explain isolated OUT_ROOT requirement"
}

resolve_pointer_path() {
  local value="$1"
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$PROJECT_ROOT" "$value" ;;
  esac
}

assert_local_run_uses_local_pointers_and_timing() {
  local root="$TMP_ROOT/local-root"
  local output=""
  local run_path=""
  local manifest_path=""

  output="$(
    HARNESS_RELEASE_GATE_OUT_ROOT="$root" \
      HARNESS_RELEASE_GATE_TEST_STEPS=minimal \
      "$BASH_BIN" "$RELEASE_GATE" --tier local 2>&1
  )"

  contains "$output" "PASS: harness_release_gate" || fail "local minimal run did not pass"
  [[ ! -e "$root/latest.json" ]] || fail "local run must not update authoritative latest.json"
  [[ ! -e "$root/latest-success.json" ]] || fail "local run must not update authoritative latest-success.json"
  [[ ! -e "$root/latest-failure.json" ]] || fail "local run must not update authoritative latest-failure.json"
  [[ -f "$root/latest-local.json" ]] || fail "local run did not write latest-local.json"
  [[ -f "$root/latest-local-success.json" ]] || fail "local run did not write latest-local-success.json"

  jq -e '.tier == "local" and .result == "PASS"' "$root/latest-local.json" >/dev/null \
    || fail "local pointer missing tier metadata"
  run_path="$(resolve_pointer_path "$(jq -r '.run_path' "$root/latest-local.json")")"
  manifest_path="$(resolve_pointer_path "$(jq -r '.manifest_path' "$root/latest-local.json")")"

  [[ -d "$run_path" ]] || fail "local run path missing"
  [[ -f "$manifest_path" ]] || fail "local manifest missing"
  jq -e '.tier == "local" and .latest_pointer == "latest-local-success"' "$manifest_path" >/dev/null \
    || fail "local manifest missing local tier metadata"
  [[ -f "$run_path/step-timing.tsv" ]] || fail "local step timing file missing"
  grep -Eq '^minimal_probe	0	[0-9]+$' "$run_path/step-timing.tsv" \
    || fail "local step timing row missing"
  [[ -f "$run_path/minimal_probe/elapsed_ms.txt" ]] || fail "local elapsed_ms artifact missing"
  [[ -f "$run_path/minimal_probe/started_at_utc.txt" ]] || fail "local started_at_utc artifact missing"
  [[ -f "$run_path/minimal_probe/started_ms.txt" ]] || fail "local started_ms artifact missing"
  [[ -f "$run_path/step-events.tsv" ]] || fail "local step events file missing"
  grep -Eq '^minimal_probe	START	[0-9]+	[0-9]+$' "$run_path/step-events.tsv" \
    || fail "local step start event missing"
  grep -Eq '^- Total elapsed ms: `[0-9]+`$' "$run_path/summary.md" \
    || fail "local summary missing total timing"
  grep -Fq -- '- `minimal_probe`: `status=0 elapsed_ms=' "$run_path/summary.md" \
    || fail "local summary missing per-step timing"
}

assert_full_run_uses_authoritative_pointers_and_timing() {
  local root="$TMP_ROOT/full-root"
  local output=""
  local run_path=""
  local manifest_path=""

  output="$(
    HARNESS_RELEASE_GATE_OUT_ROOT="$root" \
      HARNESS_RELEASE_GATE_TEST_STEPS=minimal \
      "$BASH_BIN" "$RELEASE_GATE" --tier full 2>&1
  )"

  contains "$output" "PASS: harness_release_gate" || fail "full minimal run did not pass"
  [[ -f "$root/latest.json" ]] || fail "full run did not write authoritative latest.json"
  [[ -f "$root/latest-success.json" ]] || fail "full run did not write authoritative latest-success.json"
  [[ ! -e "$root/latest-local.json" ]] || fail "full run must not write local latest pointer"

  jq -e '.tier == "full" and .result == "PASS"' "$root/latest.json" >/dev/null \
    || fail "full pointer missing tier metadata"
  run_path="$(resolve_pointer_path "$(jq -r '.run_path' "$root/latest.json")")"
  manifest_path="$(resolve_pointer_path "$(jq -r '.manifest_path' "$root/latest.json")")"

  [[ -d "$run_path" ]] || fail "full run path missing"
  [[ -f "$manifest_path" ]] || fail "full manifest missing"
  jq -e '.tier == "full" and .latest_pointer == "latest-success"' "$manifest_path" >/dev/null \
    || fail "full manifest missing full tier metadata"
  [[ -f "$run_path/step-timing.tsv" ]] || fail "full step timing file missing"
  grep -Eq '^minimal_probe	0	[0-9]+$' "$run_path/step-timing.tsv" \
    || fail "full step timing row missing"
  [[ -f "$run_path/minimal_probe/elapsed_ms.txt" ]] || fail "full elapsed_ms artifact missing"
  [[ -f "$run_path/minimal_probe/started_at_utc.txt" ]] || fail "full started_at_utc artifact missing"
  [[ -f "$run_path/minimal_probe/started_ms.txt" ]] || fail "full started_ms artifact missing"
  [[ -f "$run_path/step-events.tsv" ]] || fail "full step events file missing"
  grep -Eq '^minimal_probe	START	[0-9]+	[0-9]+$' "$run_path/step-events.tsv" \
    || fail "full step start event missing"
  grep -Eq '^- Total elapsed ms: `[0-9]+`$' "$run_path/summary.md" \
    || fail "full summary missing total timing"
  grep -Fq -- '- `minimal_probe`: `status=0 elapsed_ms=' "$run_path/summary.md" \
    || fail "full summary missing per-step timing"
}

assert_stalled_step_fails_closed_with_diagnostics() {
  local root="$TMP_ROOT/stall-root"
  local output=""
  local status=0
  local run_path=""

  output="$(
    HARNESS_RELEASE_GATE_OUT_ROOT="$root" \
      HARNESS_RELEASE_GATE_TEST_STEPS=stall_probe \
      HARNESS_RELEASE_GATE_STEP_TIMEOUT_SECS=1 \
      "$BASH_BIN" "$RELEASE_GATE" --tier full 2>&1
  )" || status=$?

  [[ "$status" -ne 0 ]] || fail "stall probe must fail the gate"
  contains "$output" "FAIL: stall_probe (rc=124 timeout=1s)" \
    || fail "stall probe did not report timeout failure"
  [[ -f "$root/latest.json" ]] || fail "stall probe did not write latest failure pointer"
  jq -e '.tier == "full" and .result == "FAIL"' "$root/latest.json" >/dev/null \
    || fail "stall probe pointer missing failure result"
  run_path="$(resolve_pointer_path "$(jq -r '.run_path' "$root/latest.json")")"

  [[ -d "$run_path" ]] || fail "stall probe run path missing"
  [[ -f "$run_path/step-timing.tsv" ]] || fail "stall probe step timing missing"
  grep -Eq '^stall_probe	124	[0-9]+$' "$run_path/step-timing.tsv" \
    || fail "stall probe timing row missing timeout status"
  [[ "$(cat "$run_path/stall_probe/status.txt")" == "124" ]] \
    || fail "stall probe status did not record timeout rc"
  [[ -f "$run_path/stall_probe/started_at_utc.txt" ]] || fail "stall probe start marker missing"
  [[ -f "$run_path/stall_probe/started_ms.txt" ]] || fail "stall probe start timing missing"
  [[ -f "$run_path/stall_probe/timeout.txt" ]] || fail "stall probe timeout diagnostics missing"
  [[ -f "$run_path/stall_probe/process-snapshot-before-timeout-kill.log" ]] \
    || fail "stall probe process snapshot missing"
  grep -Fq 'timeout_secs=1' "$run_path/stall_probe/timeout.txt" \
    || fail "stall probe timeout diagnostic missing timeout seconds"
  grep -Eq '^stall_probe	START	[0-9]+	1$' "$run_path/step-events.tsv" \
    || fail "stall probe start event missing"
  grep -Eq '^stall_probe	COMPLETE	124	[0-9]+$' "$run_path/step-events.tsv" \
    || fail "stall probe complete event missing"
  grep -Fq -- '- Result: `FAIL`' "$run_path/summary.md" \
    || fail "stall probe summary did not stay failed"
}

assert_quick_dispatch_precedes_run_dir_initialization
assert_quick_dry_run_no_mutation
assert_quick_exec_no_mutation
assert_dry_run_tier_smoke "local"
assert_dry_run_tier_smoke "full"
assert_default_full_dry_run_smoke
assert_canonical_minimal_full_rejected
assert_local_run_uses_local_pointers_and_timing
assert_full_run_uses_authoritative_pointers_and_timing
assert_stalled_step_fails_closed_with_diagnostics

printf 'PASS: harness_release_gate_tiering_test\n'
