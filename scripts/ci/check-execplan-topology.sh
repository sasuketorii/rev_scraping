#!/usr/bin/env bash
# HSDI Phase B T-B-2: lint ExecPlan dispatch_topology owner-token batches.

set -u
set -o pipefail 2>/dev/null || true

DEFAULT_FILE=".agent/active/plan_20260525_hsdi-execplan.md"
TARGET_FILE="${DEFAULT_FILE}"
STRICT=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/ci/check-execplan-topology.sh [--file <path>] [--strict]

Options:
  --file <path>  ExecPlan markdown file to lint.
  --strict       Missing dispatch_topology exits 3 instead of info-skip.
  -h, --help     Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --file requires a path" >&2
        exit 2
      fi
      TARGET_FILE="$2"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

display_path() {
  local p="$1"
  case "${p}" in
    "${REPO_ROOT}"/*) printf '%s\n' "${p#"${REPO_ROOT}/"}" ;;
    *) printf '%s\n' "${p}" ;;
  esac
}

trim_value() {
  local v="$1"
  v="${v%%#*}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "${v}" == \"*\" && "${v}" == *\" ]]; then
    v="${v#\"}"
    v="${v%\"}"
  elif [[ "${v}" == \'*\' && "${v}" == *\' ]]; then
    v="${v#\'}"
    v="${v%\'}"
  fi
  printf '%s\n' "${v}"
}

add_inline_list() {
  local phase="$1" batch="$2" task="$3" raw="$4" out="$5"
  local inner item value
  inner="${raw#*[}"
  inner="${inner%]*}"
  while [[ "${inner}" == *,* ]]; do
    item="${inner%%,*}"
    inner="${inner#*,}"
    value="$(trim_value "${item}")"
    [[ -n "${value}" ]] && printf '%s|%s|%s|%s\n' "${phase}" "${batch}" "${task}" "${value}" >> "${out}"
  done
  value="$(trim_value "${inner}")"
  [[ -n "${value}" ]] && printf '%s|%s|%s|%s\n' "${phase}" "${batch}" "${task}" "${value}" >> "${out}"
}

leading_spaces() {
  local s="$1"
  local rest="${s#"${s%%[! ]*}"}"
  printf '%d\n' "$(( ${#s} - ${#rest} ))"
}

if [[ ! -r "${TARGET_FILE}" ]]; then
  echo "ERROR: file not readable: $(display_path "${TARGET_FILE}")" >&2
  exit 2
fi

SCRATCH="$(mktemp -d -t execplan-topology-XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "${SCRATCH}" 2>/dev/null || true' EXIT

YAML_BLOCK="${SCRATCH}/dispatch_topology.yaml"
RECORDS="${SCRATCH}/records.psv"
: > "${RECORDS}"

awk '
  /^```yaml$/ { in_yaml=1; buf=""; next }
  /^```$/ && in_yaml {
    if (buf ~ /(^|\n)dispatch_topology:[[:space:]]*(\n|$)/) {
      printf "%s", buf
      found=1
      exit
    }
    in_yaml=0
    next
  }
  in_yaml { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "${TARGET_FILE}" > "${YAML_BLOCK}"

if [[ ! -s "${YAML_BLOCK}" ]]; then
  if [[ "${STRICT}" -eq 1 ]]; then
    echo "STRICT: no dispatch_topology block found in $(display_path "${TARGET_FILE}")"
    exit 3
  fi
  echo "INFO: no dispatch_topology block found in $(display_path "${TARGET_FILE}"); lint skipped."
  exit 0
fi

phase=""
batch=""
in_owner=0
current_task=""

while IFS= read -r line || [[ -n "${line}" ]]; do
  indent="$(leading_spaces "${line}")"
  trimmed="$(trim_value "${line}")"

  if [[ "${line}" =~ ^[[:space:]]{4}([^[:space:]:]+):[[:space:]]*$ && "${line}" != *"phases:"* ]]; then
    phase="${BASH_REMATCH[1]}"
    batch=""
    in_owner=0
    current_task=""
    continue
  fi

  if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]id:[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
    batch="${BASH_REMATCH[1]}"
    in_owner=0
    current_task=""
    continue
  fi

  if [[ "${line}" =~ ^[[:space:]]*owner_tokens:[[:space:]]*$ ]]; then
    in_owner=1
    current_task=""
    continue
  fi

  if [[ "${in_owner}" -eq 1 && "${indent}" -le 10 && -n "${trimmed}" ]]; then
    in_owner=0
    current_task=""
  fi

  if [[ "${in_owner}" -eq 1 ]]; then
    if [[ "${line}" =~ ^[[:space:]]{12}([^[:space:]:]+):[[:space:]]*(.*)$ ]]; then
      current_task="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      if [[ "${rest}" == \[*\] ]]; then
        add_inline_list "${phase}" "${batch}" "${current_task}" "${rest}" "${RECORDS}"
        current_task=""
      fi
      continue
    fi

    if [[ -n "${current_task}" && "${indent}" -gt 12 && "${line}" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
      value="$(trim_value "${BASH_REMATCH[1]}")"
      [[ -n "${value}" ]] && printf '%s|%s|%s|%s\n' "${phase}" "${batch}" "${current_task}" "${value}" >> "${RECORDS}"
      continue
    fi
  fi
done < "${YAML_BLOCK}"

if [[ ! -s "${RECORDS}" ]]; then
  if [[ "${STRICT}" -eq 1 ]]; then
    echo "STRICT: no dispatch_topology block found in $(display_path "${TARGET_FILE}")"
    exit 3
  fi
  echo "INFO: no dispatch_topology block found in $(display_path "${TARGET_FILE}"); lint skipped."
  exit 0
fi

TASKS="${SCRATCH}/tasks.psv"
COLLISIONS="${SCRATCH}/collisions.txt"
MISMATCHES="${SCRATCH}/mismatches.txt"
: > "${COLLISIONS}"
: > "${MISMATCHES}"

sort -u "${RECORDS}" > "${SCRATCH}/records.sorted"
awk -F'|' '{ print $1 "|" $2 "|" $4 "|" $3 }' "${SCRATCH}/records.sorted" \
  | sort -u > "${SCRATCH}/by_path.psv"

prev_key=""
tasks=""
while IFS='|' read -r p b path task; do
  key="${p}|${b}|${path}"
  if [[ "${key}" != "${prev_key}" && -n "${prev_key}" ]]; then
    if [[ "${tasks}" == *,* ]]; then
      old_ifs="${IFS}"
      IFS='|'
      set -- ${prev_key}
      IFS="${old_ifs}"
      echo "COLLISION: phase=$1 batch=$2 path=$3 tasks=[${tasks}]" >> "${COLLISIONS}"
    fi
    tasks="${task}"
  elif [[ -z "${prev_key}" ]]; then
    tasks="${task}"
  else
    case ",${tasks}," in
      *,"${task}",*) ;;
      *) tasks="${tasks},${task}" ;;
    esac
  fi
  prev_key="${key}"
done < "${SCRATCH}/by_path.psv"

if [[ -n "${prev_key}" && "${tasks}" == *,* ]]; then
  old_ifs="${IFS}"
  IFS='|'
  set -- ${prev_key}
  IFS="${old_ifs}"
  echo "COLLISION: phase=$1 batch=$2 path=$3 tasks=[${tasks}]" >> "${COLLISIONS}"
fi

extract_task_tokens() {
  local task="$1" file="$2" out="$3"
  : > "${out}"
  awk -v task="${task}" '
    function trim(s) {
      sub(/#.*/, "", s)
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      gsub(/^"|"$/, "", s)
      gsub(/^'\''|'\''$/, "", s)
      return s
    }
    function emit_inline(s,    n,i,a,v) {
      sub(/^[^[]*\[/, "", s)
      sub(/\].*$/, "", s)
      n=split(s, a, ",")
      for (i=1; i<=n; i++) {
        v=trim(a[i])
        if (v != "") print v
      }
    }
    found && /^####[ \t]/ { exit }
    found {
      seen++
      if (seen > 80) exit
      if ($0 ~ /^[ \t]*file_owner_token:[ \t]*\[/) {
        emit_inline($0)
        block=0
        any=1
        next
      }
      if ($0 ~ /^[ \t]*file_owner_token:[ \t]*$/) {
        block=1
        any=1
        next
      }
      if (block && $0 ~ /^[ \t]*-[ \t]*/) {
        v=$0
        sub(/^[ \t]*-[ \t]*/, "", v)
        v=trim(v)
        if (v != "") print v
        next
      }
      if (block && $0 !~ /^[ \t]*$/ && $0 !~ /^[ \t]+/) {
        block=0
      }
    }
    /^####[ \t]/ {
      line=$0
      sub(/^####[ \t]+/, "", line)
      if (line ~ "^" task "([^[:alnum:]_-]|$)") {
        found=1
        seen=0
      }
    }
    END { if (any) exit 0; exit 1 }
  ' "${file}" > "${out}"
}

awk -F'|' '{ print $1 "|" $2 "|" $3 }' "${SCRATCH}/records.sorted" | sort -u > "${TASKS}"

while IFS='|' read -r p b task; do
  topo="${SCRATCH}/topo_${p}_${b}_${task}"
  body="${SCRATCH}/body_${p}_${b}_${task}"
  awk -F'|' -v p="${p}" -v b="${b}" -v t="${task}" \
    '$1 == p && $2 == b && $3 == t { print $4 }' "${SCRATCH}/records.sorted" \
    | sort -u > "${topo}"

  if extract_task_tokens "${task}" "${TARGET_FILE}" "${body}"; then
    sort -u "${body}" > "${body}.sorted"
    if ! cmp -s "${topo}" "${body}.sorted"; then
      echo "owner_tokens_mismatch task=${task} batch=${b}" >> "${MISMATCHES}"
    fi
  fi
done < "${TASKS}"

cat "${COLLISIONS}"
cat "${MISMATCHES}"

if [[ -s "${COLLISIONS}" ]]; then
  exit 1
fi
if [[ -s "${MISMATCHES}" ]]; then
  exit 2
fi
exit 0
