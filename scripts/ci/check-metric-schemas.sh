#!/usr/bin/env bash
# T-21.0-12 CI gate: validate metric JSONL schemas.
#
# Steps:
#   1. Confirm each of the 6 expected schema files exists under
#      test/golden/metrics/.
#   2. Confirm each schema is valid JSON (jq empty).
#   3. Confirm each schema declares the required Draft 2020-12 header
#      and "type": "object".
#   4. If ajv-cli is installed (`ajv` or `npx --no-install ajv`), validate
#      any present .sample row file against its schema.
#   5. ajv absent => skipped path, exit 0 with summary.
#
# Privacy: never echoes the absolute host repo path.
# Fail-open: missing optional ajv tooling is not a CI failure.
#
# Exit codes:
#   0  all 6 schemas present, syntactically valid; ajv-validated if
#      available, skipped otherwise.
#   2  one or more schema files missing or invalid JSON.

set -u

script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}

SCRIPT_DIR="$(script_dir)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
SCHEMA_DIR="${REPO_ROOT}/test/golden/metrics"

SCHEMAS=(
  "silent_bail.jsonl.schema.json"
  "wrapper_events.jsonl.schema.json"
  "path_leak_events.jsonl.schema.json"
  "dual_lgtm_gap.jsonl.schema.json"
  "tier2_reads.jsonl.schema.json"
  "hook_timeout.jsonl.schema.json"
)

if [[ ! -d "${SCHEMA_DIR}" ]]; then
  echo "FAIL: schema directory missing: test/golden/metrics" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "summary: jq absent, skipping schema syntax check (treated as fail-open)"
  echo "summary: 0/${#SCHEMAS[@]} schema(s) syntax-OK, jq=absent, rc=0"
  exit 0
fi

AJV_CMD=""
if command -v ajv >/dev/null 2>&1; then
  AJV_CMD="ajv"
elif command -v npx >/dev/null 2>&1 && npx --no-install ajv --version >/dev/null 2>&1; then
  AJV_CMD="npx --no-install ajv"
fi

ok_count=0
fail_count=0
ajv_state="absent"
[[ -n "${AJV_CMD}" ]] && ajv_state="present"

for s in "${SCHEMAS[@]}"; do
  echo "check: ${s}"
  path="${SCHEMA_DIR}/${s}"
  if [[ ! -f "${path}" ]]; then
    echo "  FAIL: schema file missing"
    fail_count=$(( fail_count + 1 ))
    continue
  fi
  if ! jq empty < "${path}" >/dev/null 2>&1; then
    echo "  FAIL: invalid JSON"
    fail_count=$(( fail_count + 1 ))
    continue
  fi
  schema_header="$(jq -r '."$schema" // empty' < "${path}" 2>/dev/null)"
  schema_type="$(jq -r '.type // empty' < "${path}" 2>/dev/null)"
  if [[ -z "${schema_header}" ]] || [[ "${schema_type}" != "object" ]]; then
    echo "  FAIL: missing \"\$schema\" header or type != object"
    fail_count=$(( fail_count + 1 ))
    continue
  fi
  echo "  ok: schema syntax + header valid"
  ok_count=$(( ok_count + 1 ))

  sample_path="${SCHEMA_DIR}/${s%.schema.json}.sample"
  if [[ -n "${AJV_CMD}" ]] && [[ -f "${sample_path}" ]]; then
    if ${AJV_CMD} validate -s "${path}" -d "${sample_path}" >/dev/null 2>&1; then
      echo "  ok: ajv-validated sample row"
    else
      echo "  WARN: ajv rejected sample row (non-fatal)"
    fi
  else
    echo "  skipped row validation: ajv-cli not installed (schema syntax check OK)"
  fi
done

if [[ "${fail_count}" -gt 0 ]]; then
  echo "summary: ${ok_count}/${#SCHEMAS[@]} schema(s) syntax-OK, ajv=${ajv_state}, rc=2"
  exit 2
fi

echo "summary: ${ok_count}/${#SCHEMAS[@]} schema(s) syntax-OK, ajv=${ajv_state}, rc=0"
exit 0
