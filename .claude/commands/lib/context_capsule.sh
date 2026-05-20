#!/usr/bin/env bash
# context_capsule.sh - Semantic Context Capsule builder (Phase 2 / Task 2.1)
set -euo pipefail

if [[ -n "${_CONTEXT_CAPSULE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_CONTEXT_CAPSULE_LOADED=1

CONTEXT_CAPSULE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./utils.sh
source "$CONTEXT_CAPSULE_LIB_DIR/utils.sh"

CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$CONTEXT_CAPSULE_LIB_DIR/context_analysis.sh"
CONTEXT_CAPSULE_REPO_ROOT="$(cd "$CONTEXT_CAPSULE_LIB_DIR/../../.." && pwd)"
CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
CONTEXT_CAPSULE_LOCK_TIMEOUT="${CONTEXT_CAPSULE_LOCK_TIMEOUT:-30}"
CONTEXT_CAPSULE_SECURITY_CONFIG="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/security_critical.json"
CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
CONTEXT_CAPSULE_FEEDBACK_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.agent/archive/feedback"
CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE="$CONTEXT_CAPSULE_FEEDBACK_DIR/memory_patterns.jsonl"
CONTEXT_CAPSULE_FILE_HISTORY_FILE="$CONTEXT_CAPSULE_FEEDBACK_DIR/file_history.jsonl"

readonly MEMORY_PATTERNS_SCHEMA_COMMENT='# schema: {"pattern_id":"<category.slug>","category":"high|medium|low","description":"review issue pattern","frequency":0,"last_seen":"YYYY-MM-DDTHH:MM:SSZ"}'
readonly FILE_HISTORY_SCHEMA_COMMENT='# schema: {"file_path":"path/to/file","fix_count":0,"last_fix":"YYYY-MM-DDTHH:MM:SSZ","common_issues":["issue_pattern_id"]}'

readonly MAX_CAPSULE_TOKENS=220
readonly MAX_CONTEXT_LINES=900
# Task 2.1 guard constant (used by downstream reviewer-packet integration).
# shellcheck disable=SC2034
readonly MAX_REVIEW_PACKET_TOKENS=1200
readonly CAPSULE_BODY_TOKEN_BUDGET=200
readonly CAPSULE_META_TOKEN_BUDGET=20

readonly DEFAULT_SECURITY_CONFIG_JSON='{
  "version": "1.0.0",
  "file_path_patterns": [
    "**/auth/**",
    "**/middleware/**",
    "**/security/**",
    "**/crypto/**",
    "**/config/security*",
    "**/config/auth*",
    "**/guard/**",
    "**/permission/**",
    "**/rbac/**",
    "**/acl/**",
    "**/session/**",
    "**/token/**",
    "**/sanitize/**",
    "**/validate/**"
  ],
  "symbol_name_patterns": [
    "authenticate*",
    "authorize*",
    "validateToken*",
    "verifySignature*",
    "hashPassword*",
    "generateToken*",
    "checkPermission*",
    "sanitize*",
    "escape*",
    "encrypt*",
    "decrypt*",
    "sign*",
    "verify*",
    "rateLimit*"
  ],
  "import_from_patterns": [
    "bcrypt",
    "jsonwebtoken",
    "passport",
    "helmet",
    "cors",
    "csurf",
    "express-rate-limit",
    "crypto"
  ],
  "auto_full_context": true
}'

_capsule_sha256() {
  local input="${1:-}"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$input" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
  else
    die "No SHA256 implementation available (shasum/sha256sum/python3)"
  fi
}

# Token estimator (wc -c base):
# - English/ASCII: 1 token ~= 4 chars
# - Japanese/non-ASCII: 1 token ~= 1.5 chars
_estimate_tokens() {
  local text="${1:-}"
  local total_bytes=0
  local ascii_bytes=0
  local non_ascii_bytes=0
  local non_ascii_chars=0

  total_bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  ascii_bytes=$(printf '%s' "$text" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
  [[ -z "$total_bytes" ]] && total_bytes=0
  [[ -z "$ascii_bytes" ]] && ascii_bytes=0

  non_ascii_bytes=$((total_bytes - ascii_bytes))
  if [[ "$non_ascii_bytes" -lt 0 ]]; then
    non_ascii_bytes=0
  fi

  # UTF-8 Japanese chars are typically 3 bytes.
  non_ascii_chars=$(((non_ascii_bytes + 2) / 3))

  awk -v ascii="$ascii_bytes" -v non_ascii="$non_ascii_chars" '
    BEGIN {
      est = (ascii / 4.0) + (non_ascii / 1.5)
      if (est < 0) est = 0
      i = int(est)
      if (est > i) i = i + 1
      print i
    }
  '
}

_capsule_escape_value() {
  local value="${1:-}"
  local max_chars="${2:-240}"

  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\t'/ }"
  value="${value//=/:}"
  value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  if [[ "${#value}" -gt "$max_chars" ]]; then
    value="${value:0:$((max_chars - 3))}..."
  fi

  printf '%s' "$value"
}

_capsule_join_csv() {
  local json_array="${1:-[]}"
  local limit="${2:-10}"

  jq -r --argjson limit "$limit" '
    map(select(type == "string" and length > 0))
    | .[:$limit]
    | join(",")
  ' <<< "$json_array"
}

_capsule_path_matches_pattern() {
  local path="$1"
  local pattern="$2"

  local p="$path"
  local g="$pattern"
  p="${p#./}"
  g="${g#./}"

  shopt -s nocasematch
  # shellcheck disable=SC2053
  if [[ "$p" == $g ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch

  local token=""
  for token in $(printf '%s' "$g" | tr '*./' ' '); do
    [[ ${#token} -lt 3 ]] && continue
    shopt -s nocasematch
    if [[ "$p" == *"$token"* ]]; then
      shopt -u nocasematch
      return 0
    fi
    shopt -u nocasematch
  done

  return 1
}

_capsule_run_context_analysis() {
  local subcommand="${1:-}"
  shift || true

  if [[ -z "$subcommand" ]]; then
    die "_capsule_run_context_analysis: subcommand is required"
  fi

  if [[ ! -f "$CONTEXT_CAPSULE_CONTEXT_ANALYSIS" ]]; then
    die "context_analysis.sh not found: $CONTEXT_CAPSULE_CONTEXT_ANALYSIS"
  fi

  bash "$CONTEXT_CAPSULE_CONTEXT_ANALYSIS" "$subcommand" "$@"
}

_capsule_context_call_json() {
  local fallback_json="${1:-}"
  if [[ -z "$fallback_json" ]]; then
    fallback_json='{}'
  fi
  shift

  local output=""
  if output="$(_capsule_run_context_analysis "$@" 2>/dev/null)"; then
    if jq -e . >/dev/null 2>&1 <<< "$output"; then
      echo "$output"
      return 0
    fi
  fi

  echo "$fallback_json"
}

_CAPSULE_REGISTRY_COMPAT_WARNED="${_CAPSULE_REGISTRY_COMPAT_WARNED:-0}"

_capsule_log_registry_compat_blocked_once() {
  local caller="${1:-capsule_registry_compat}"
  if [[ "${_CAPSULE_REGISTRY_COMPAT_WARNED:-0}" != "1" ]]; then
    log_warn "${caller}: registry export compatibility disabled in Phase 3 partial cutover until explicit DB-backed refresh metadata exists"
    _CAPSULE_REGISTRY_COMPAT_WARNED=1
  fi
}

_capsule_resolve_project_id() {
  local helper="$CONTEXT_CAPSULE_REPO_ROOT/scripts/resolve-semantic-project-id.sh"
  local project_id=""
  [[ -x "$helper" ]] || return 1

  if project_id=$("$helper" --repo-root "$CONTEXT_CAPSULE_REPO_ROOT" --print 2>/dev/null); then
    project_id="$(_capsule_normalize_project_id "$project_id")"
    if [[ -n "$project_id" ]]; then
      printf '%s\n' "$project_id"
      return 0
    fi
  fi

  return 1
}

_capsule_normalize_project_id() {
  local project_id="${1:-}"
  printf '%s' "$project_id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

_capsule_require_project_id() {
  local project_id=""
  if ! project_id=$(_capsule_resolve_project_id); then
    log_error "registry authority blocked: semantic project_id is unavailable"
    return 1
  fi
  project_id="$(_capsule_normalize_project_id "$project_id")"

  if [[ "$project_id" == "agent_base" ]]; then
    log_error "registry authority blocked: legacy project_id 'agent_base' is not allowed on DB-authoritative paths"
    return 1
  fi

  if [[ ! "$project_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    log_error "registry authority blocked: invalid semantic project_id '$project_id'"
    return 1
  fi

  printf '%s\n' "$project_id"
}

_capsule_registry_export_compat_allowed() {
  if [[ "${CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT:-0}" != "1" ]]; then
    return 1
  fi

  local meta_file="${CONTEXT_CAPSULE_REGISTRY_EXPORT_META:-}"
  [[ -n "$meta_file" && -s "$meta_file" ]] || return 1

  local project_id=""
  if ! project_id=$(_capsule_require_project_id); then
    return 1
  fi

  jq -e \
    --arg project_id "$project_id" \
    '
      type == "object"
      and ((.authority // "") == "db")
      and ((.export // "") == "components_jsonl")
      and (.fresh == true)
      and ((.project_id // "") == $project_id)
    ' "$meta_file" >/dev/null 2>&1
}

_capsule_registry_compat_json() {
  # Conservative default: do not read registry export compatibility unless the
  # caller explicitly opts in and an explicit DB-backed refresh truth marker exists.
  if ! _capsule_registry_export_compat_allowed; then
    _capsule_log_registry_compat_blocked_once "capsule_build"
    echo '[]'
    return 0
  fi

  local registry_json=""
  registry_json=$(_capsule_context_call_json '[]' registry-query 'true')
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$registry_json"; then
    _capsule_log_registry_compat_blocked_once "capsule_build"
    echo '[]'
    return 0
  fi

  echo "$registry_json"
}

_memory_ensure_store_files() {
  ensure_dir "$CONTEXT_CAPSULE_FEEDBACK_DIR"

  if [[ ! -s "$CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE" ]]; then
    printf '%s\n' "$MEMORY_PATTERNS_SCHEMA_COMMENT" > "$CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE"
  fi

  if [[ ! -s "$CONTEXT_CAPSULE_FILE_HISTORY_FILE" ]]; then
    printf '%s\n' "$FILE_HISTORY_SCHEMA_COMMENT" > "$CONTEXT_CAPSULE_FILE_HISTORY_FILE"
  fi
}

_memory_read_jsonl_array() {
  local jsonl_file="${1:-}"
  if [[ -z "$jsonl_file" || ! -f "$jsonl_file" ]]; then
    echo '[]'
    return 0
  fi

  local filtered=""
  filtered=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$jsonl_file" 2>/dev/null || true)
  if [[ -z "$filtered" ]]; then
    echo '[]'
    return 0
  fi

  if ! jq -cs '.' >/dev/null 2>&1 <<< "$filtered"; then
    log_warn "memory store parse failed: $jsonl_file (fallback to empty array)"
    echo '[]'
    return 0
  fi

  jq -cs '.' <<< "$filtered"
}

_memory_write_jsonl_array() {
  local jsonl_file="${1:-}"
  local schema_comment="${2:-}"
  local records_json="${3:-[]}"

  if [[ -z "$jsonl_file" || -z "$schema_comment" ]]; then
    return 1
  fi

  local tmp_file=""
  tmp_file=$(create_temp_file "memory_store")

  {
    printf '%s\n' "$schema_comment"
    jq -c '.[]' <<< "$records_json"
  } > "$tmp_file"

  mv "$tmp_file" "$jsonl_file"
}

_memory_slugify() {
  local text="${1:-}"
  local max_len="${2:-42}"

  local slug=""
  slug=$(printf '%s' "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '_' \
    | sed -E 's/^_+//; s/_+$//; s/_+/_/g')

  if [[ -z "$slug" ]]; then
    slug="issue"
  fi

  if [[ ${#slug} -gt "$max_len" ]]; then
    slug="${slug:0:$max_len}"
    slug="${slug%_}"
  fi

  printf '%s\n' "$slug"
}

_memory_extract_review_patterns_json() {
  local reviews_file="${1:-}"
  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    echo '[]'
    return 0
  fi

  local extracted_tsv=""
  extracted_tsv=$(create_temp_file "memory_patterns_extract")
  : > "$extracted_tsv"

  local line=""
  while IFS= read -r line; do
    local severity=""
    if [[ "$line" =~ \[(High|Medium|Low)\] ]]; then
      severity=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    else
      continue
    fi

    local description=""
    description=$(printf '%s' "$line" \
      | sed -E 's/.*\[(High|Medium|Low)\][[:space:]]*[-:：]?[[:space:]]*//I' \
      | sed -E 's/^[[:space:]#>*-]+//; s/^[0-9]+[.):-]?[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')

    if [[ -z "$description" ]]; then
      description="unspecified issue"
    fi
    description=$(_capsule_escape_value "$description" 120)

    local slug=""
    slug=$(_memory_slugify "$description" 42)
    local pattern_id="${severity}.${slug}"
    printf '%s\t%s\t%s\n' "$pattern_id" "$severity" "$description" >> "$extracted_tsv"
  done < "$reviews_file"

  if [[ ! -s "$extracted_tsv" ]]; then
    /bin/rm -f "$extracted_tsv"
    echo '[]'
    return 0
  fi

  local extracted_json=""
  extracted_json=$(sort "$extracted_tsv" | jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map(select(length >= 3) | {pattern_id:.[0], category:.[1], description:.[2]})
    | group_by(.pattern_id)
    | map({
        pattern_id:.[0].pattern_id,
        category:.[0].category,
        description:.[0].description,
        frequency:length
      })
  ')

  /bin/rm -f "$extracted_tsv"
  echo "$extracted_json"
}

# Usage: memory_record_review_pattern <reviews_file>
memory_record_review_pattern() {
  local reviews_file="${1:-}"
  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    log_warn "memory_record_review_pattern: reviews file not found: $reviews_file"
    return 1
  fi

  _memory_ensure_store_files

  local incoming_json=""
  incoming_json=$(_memory_extract_review_patterns_json "$reviews_file")

  local incoming_count=0
  incoming_count=$(jq 'length' <<< "$incoming_json")
  if [[ "$incoming_count" -eq 0 ]]; then
    log_info "memory_record_review_pattern: no [High]/[Medium]/[Low] patterns found"
    return 0
  fi

  local existing_json=""
  existing_json=$(_memory_read_jsonl_array "$CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE")

  local now_ts=""
  now_ts=$(get_timestamp)

  local merged_json=""
  merged_json=$(jq -nc \
    --argjson existing "$existing_json" \
    --argjson incoming "$incoming_json" \
    --arg now "$now_ts" \
    '
      def norm_existing:
        map(
          select(type == "object" and ((.pattern_id // "") | type == "string") and ((.pattern_id // "") | length > 0))
          | {
              pattern_id:(.pattern_id | tostring | ascii_downcase),
              category:((.category // "unknown") | tostring | ascii_downcase),
              description:((.description // "") | tostring),
              frequency:((.frequency // 0) | tonumber? // 0),
              last_seen:((.last_seen // "") | tostring)
            }
        );
      def norm_incoming:
        map(
          select(type == "object" and ((.pattern_id // "") | type == "string") and ((.pattern_id // "") | length > 0))
          | {
              pattern_id:(.pattern_id | tostring | ascii_downcase),
              category:((.category // "unknown") | tostring | ascii_downcase),
              description:((.description // "") | tostring),
              frequency:((.frequency // 1) | tonumber? // 1),
              last_seen:$now
            }
        );

      (($existing | norm_existing) + ($incoming | norm_incoming))
      | sort_by(.pattern_id)
      | group_by(.pattern_id)
      | map(
          reduce .[] as $item (
            {pattern_id:"", category:"unknown", description:"", frequency:0, last_seen:""};
            .pattern_id = (if (.pattern_id | length) == 0 then ($item.pattern_id // "") else .pattern_id end)
            | .frequency += ($item.frequency // 0)
            | .category = (
                if (.category == "unknown" or (.category | length) == 0) and (($item.category // "") | length) > 0
                then $item.category
                else .category
                end
              )
            | .description = (
                if (.description | length) == 0 and (($item.description // "") | length) > 0
                then $item.description
                else .description
                end
              )
            | .last_seen = (
                [ .last_seen, ($item.last_seen // "") ]
                | map(select(type == "string" and length > 0))
                | max // ""
              )
          )
        )
      | sort_by((.last_seen // ""), (.frequency // 0))
      | reverse
    ')

  _memory_write_jsonl_array \
    "$CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE" \
    "$MEMORY_PATTERNS_SCHEMA_COMMENT" \
    "$merged_json"

  log_info "memory_record_review_pattern: recorded ${incoming_count} patterns"
}

_memory_parse_issues_json() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo '[]'
    return 0
  fi

  printf '%s' "$raw" \
    | tr ';,' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sed '/^$/d' \
    | jq -R . \
    | jq -s 'map(select(type == "string" and length > 0)) | unique | .[:10]'
}

# Usage: memory_record_file_fix <file_path> [issue_ids]
# issue_ids format: "issue1;issue2;issue3" or "issue1,issue2"
memory_record_file_fix() {
  local file_path="${1:-}"
  if [[ -z "$file_path" ]]; then
    log_warn "memory_record_file_fix: file_path is required"
    return 1
  fi

  if [[ "$file_path" == "$CONTEXT_CAPSULE_REPO_ROOT/"* ]]; then
    file_path="${file_path#"$CONTEXT_CAPSULE_REPO_ROOT"/}"
  fi
  file_path="${file_path#./}"

  local issues_raw="${2:-}"
  local issues_json='[]'
  issues_json=$(_memory_parse_issues_json "$issues_raw")

  _memory_ensure_store_files

  local existing_json=""
  existing_json=$(_memory_read_jsonl_array "$CONTEXT_CAPSULE_FILE_HISTORY_FILE")

  local now_ts=""
  now_ts=$(get_timestamp)

  local merged_json=""
  merged_json=$(jq -nc \
    --arg file_path "$file_path" \
    --arg now "$now_ts" \
    --argjson issues "$issues_json" \
    --argjson existing "$existing_json" \
    '
      def norm_existing:
        map(
          select(type == "object" and ((.file_path // "") | type == "string") and ((.file_path // "") | length > 0))
          | {
              file_path:(.file_path | tostring),
              fix_count:((.fix_count // 0) | tonumber? // 0),
              last_fix:((.last_fix // "") | tostring),
              common_issues:((.common_issues // []) | map(select(type == "string" and length > 0)))
            }
        );

      (( $existing | norm_existing ) + [{
        file_path:$file_path,
        fix_count:1,
        last_fix:$now,
        common_issues:$issues
      }])
      | sort_by(.file_path)
      | group_by(.file_path)
      | map(
          reduce .[] as $item (
            {file_path:"", fix_count:0, last_fix:"", common_issues:[]};
            .file_path = (if (.file_path | length) == 0 then ($item.file_path // "") else .file_path end)
            | .fix_count += ($item.fix_count // 0)
            | .last_fix = (
                [ .last_fix, ($item.last_fix // "") ]
                | map(select(type == "string" and length > 0))
                | max // ""
              )
            | .common_issues = (
                ((.common_issues // []) + ($item.common_issues // []))
                | map(select(type == "string" and length > 0))
                | unique
                | .[:10]
              )
          )
        )
      | sort_by((.last_fix // ""), (.fix_count // 0))
      | reverse
    ')

  _memory_write_jsonl_array \
    "$CONTEXT_CAPSULE_FILE_HISTORY_FILE" \
    "$FILE_HISTORY_SCHEMA_COMMENT" \
    "$merged_json"

  log_info "memory_record_file_fix: recorded fix history for $file_path"
}

# Usage: memory_get_top_patterns [top_n]
# Output: semicolon-separated pattern IDs (e.g. "high.null_check;medium.error_handling;low.naming")
memory_get_top_patterns() {
  local top_n="${1:-3}"
  if ! [[ "$top_n" =~ ^[0-9]+$ ]] || [[ "$top_n" -le 0 ]]; then
    top_n=3
  fi

  _memory_ensure_store_files

  local patterns_json=""
  patterns_json=$(_memory_read_jsonl_array "$CONTEXT_CAPSULE_MEMORY_PATTERNS_FILE")

  jq -r --argjson limit "$top_n" '
    map(
      select(
        type == "object"
        and ((.pattern_id // "") | type == "string")
        and ((.pattern_id // "") | length > 0)
      )
      | {
          pattern_id:(.pattern_id | tostring),
          frequency:((.frequency // 0) | tonumber? // 0),
          last_seen:((.last_seen // "") | tostring)
        }
    )
    | sort_by((.last_seen // ""), (.frequency // 0))
    | reverse
    | .[:$limit]
    | map(.pattern_id)
    | join(";")
  ' <<< "$patterns_json"
}

_capsule_collect_changed_files_json() {
  local diff_json="${1:-}"
  if [[ -z "$diff_json" ]]; then
    diff_json='{}'
  fi
  local tmp_raw=""
  local tmp_sorted=""
  tmp_raw=$(create_temp_file "capsule_changed_files")
  tmp_sorted=$(create_temp_file "capsule_changed_files_sorted")

  jq -r '.changed_files[]? // empty' <<< "$diff_json" >> "$tmp_raw" || true

  (
    cd "$CONTEXT_CAPSULE_REPO_ROOT"
    {
      git diff --name-only 2>/dev/null || true
      git diff --cached --name-only 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    }
  ) >> "$tmp_raw"

  sed '/^$/d' "$tmp_raw" | sed 's|^\./||' | sort -u > "$tmp_sorted"
  jq -R . "$tmp_sorted" | jq -s 'map(select(length > 0))'

  /bin/rm -f "$tmp_raw" "$tmp_sorted"
}

_capsule_collect_changed_symbols_json() {
  local diff_json="${1:-}"
  local graph_json="${2:-}"
  if [[ -z "$diff_json" ]]; then
    diff_json='{}'
  fi
  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi
  local tmp_raw=""
  local tmp_sorted=""
  tmp_raw=$(create_temp_file "capsule_changed_symbols")
  tmp_sorted=$(create_temp_file "capsule_changed_symbols_sorted")

  jq -r '.changed_symbols[]? | (.logical_id // .name // empty)' <<< "$diff_json" >> "$tmp_raw" || true
  jq -r '.impacted_symbols[]? | (.logical_id // .name // empty)' <<< "$diff_json" >> "$tmp_raw" || true
  jq -r '.ranked_symbols[:8][]? | (.logical_id // .name // empty)' <<< "$graph_json" >> "$tmp_raw" || true

  sed '/^$/d' "$tmp_raw" | sort -u > "$tmp_sorted"
  jq -R . "$tmp_sorted" | jq -s 'map(select(length > 0))'

  /bin/rm -f "$tmp_raw" "$tmp_sorted"
}

# preflight入力の基礎データを構築
# Output JSON:
# {
#   task_id, scope[], proposed_components[],
#   deleted_paths[], removed_symbols[], move_candidates[],
#   _idem_recalc_required, adjacency_path
# }
_capsule_build_preflight_input_json() {
  local task_id="${1:-}"
  local base_ref="${2:-HEAD~1}"
  local head_ref="${3:-HEAD}"
  local scope_json="${4:-[]}"
  local proposed_components_json="${5:-[]}"
  local graph_json="${6:-}"

  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi

  if [[ -z "$task_id" ]]; then
    echo '{"task_id":"","scope":[],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[],"_idem_recalc_required":false,"adjacency_path":""}'
    return 0
  fi

  _validate_identifier "$task_id" "task_id"

  local deletions_json=""
  deletions_json=$(_capsule_context_call_json \
    '{"deleted_paths":[],"deleted_count":0,"removed_symbols":[],"move_candidates":[],"_idem_recalc_required":false}' \
    detect-deletions "$base_ref" "$head_ref")

  local normalized_scope_json='[]'
  normalized_scope_json=$(jq -c 'map(select(type == "string" and length > 0)) | unique | .[:100]' <<< "$scope_json" 2>/dev/null || echo '[]')

  local normalized_components_json='[]'
  normalized_components_json=$(jq -c 'map(select(type == "string" and length > 0)) | unique | .[:200]' <<< "$proposed_components_json" 2>/dev/null || echo '[]')

  local deleted_paths_json='[]'
  deleted_paths_json=$(jq -c '(.deleted_paths // []) | map(select(type == "string" and length > 0)) | unique | .[:200]' <<< "$deletions_json" 2>/dev/null || echo '[]')

  local removed_symbols_json='[]'
  removed_symbols_json=$(jq -c '(.removed_symbols // []) | map(select(type == "string" and length > 0)) | unique | .[:200]' <<< "$deletions_json" 2>/dev/null || echo '[]')

  local move_candidates_json='[]'
  move_candidates_json=$(jq -c '
    (.move_candidates // [])
    | map(
        select(type == "object")
        | {
            old_path: ((.old_path // .from // "") | tostring | gsub("^\\./"; "")),
            new_path: ((.new_path // .to // "") | tostring | gsub("^\\./"; ""))
          }
        | select((.old_path | length) > 0 and (.new_path | length) > 0)
      )
    | unique_by(.old_path + "|" + .new_path)
    | .[:100]
  ' <<< "$deletions_json" 2>/dev/null || echo '[]')

  local idem_recalc_required="false"
  idem_recalc_required=$(jq -r 'if (._idem_recalc_required // false) then "true" else "false" end' <<< "$deletions_json" 2>/dev/null || echo "false")

  local adjacency_path=""
  adjacency_path=$(jq -r '.adjacency_path // empty' <<< "$graph_json" 2>/dev/null || true)
  if [[ -z "$adjacency_path" ]]; then
    adjacency_path="$CONTEXT_CAPSULE_REPO_ROOT/.agent/context/adjacency.jsonl"
  fi

  jq -nc \
    --arg task_id "$task_id" \
    --argjson scope "$normalized_scope_json" \
    --argjson proposed_components "$normalized_components_json" \
    --argjson deleted_paths "$deleted_paths_json" \
    --argjson removed_symbols "$removed_symbols_json" \
    --argjson move_candidates "$move_candidates_json" \
    --arg idem_recalc_required "$idem_recalc_required" \
    --arg adjacency_path "$adjacency_path" \
    '{
      task_id:$task_id,
      scope:$scope,
      proposed_components:$proposed_components,
      deleted_paths:$deleted_paths,
      removed_symbols:$removed_symbols,
      move_candidates:$move_candidates,
      _idem_recalc_required:($idem_recalc_required == "true"),
      adjacency_path:$adjacency_path
    }'
}

_capsule_collect_conflicts_value() {
  local tmp_conflicts=""
  tmp_conflicts=$(create_temp_file "capsule_conflicts")

  (
    cd "$CONTEXT_CAPSULE_REPO_ROOT"
    git diff --name-only --diff-filter=U 2>/dev/null || true
  ) | sed '/^$/d' | sed 's|^\./||' | sort -u > "$tmp_conflicts"

  local count=0
  count=$(wc -l < "$tmp_conflicts" | tr -d ' ')

  local value="none"
  if [[ "$count" -gt 0 ]]; then
    local sample=""
    sample=$(jq -R . "$tmp_conflicts" | jq -s 'map(select(length > 0)) | .[:3] | join(",")')
    value=$(jq -r --arg sample "$sample" --argjson count "$count" '
      if $count > 3 then
        (($sample // "") + ",+" + (($count - 3) | tostring))
      else
        ($sample // "none")
      end
    ')
  fi

  /bin/rm -f "$tmp_conflicts"
  echo "$value"
}

_capsule_security_config_json() {
  if [[ -f "$CONTEXT_CAPSULE_SECURITY_CONFIG" ]]; then
    local cfg=""
    if cfg=$(jq -c '.' "$CONTEXT_CAPSULE_SECURITY_CONFIG" 2>/dev/null); then
      echo "$cfg"
      return 0
    fi
    log_warn "security_critical.json parse failed; using default config"
  fi

  echo "$DEFAULT_SECURITY_CONFIG_JSON"
}

_capsule_collect_security_pins_json() {
  local changed_files_json="${1:-[]}"
  local registry_json="${2:-[]}"
  local security_cfg_json=""
  security_cfg_json=$(_capsule_security_config_json)

  local tmp_pins=""
  tmp_pins=$(create_temp_file "capsule_security_pins")

  local file_path_patterns=""
  file_path_patterns=$(jq -r '(.file_path_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")

  local symbol_patterns=""
  symbol_patterns=$(jq -r '(.symbol_name_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")

  local import_patterns=""
  import_patterns=$(jq -r '(.import_from_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")

  # Axis 1: file_path pattern
  local changed_file=""
  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local pattern=""
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      if _capsule_path_matches_pattern "$changed_file" "$pattern"; then
        jq -r --arg f "$changed_file" '
          .[] | select((.file // "") == $f)
          | (.logical_id // .semantic_id // .name // empty)
        ' <<< "$registry_json" >> "$tmp_pins" || true
      fi
    done <<< "$file_path_patterns"
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  # Axis 2: symbol_name pattern
  local sym_pattern=""
  while IFS= read -r sym_pattern; do
    [[ -n "$sym_pattern" ]] || continue
    local entry_name=""
    local entry_id=""
    while IFS=$'\t' read -r entry_name entry_id; do
      [[ -n "$entry_id" ]] || continue
      shopt -s nocasematch
      # shellcheck disable=SC2053
      if [[ "$entry_name" == $sym_pattern ]]; then
        echo "$entry_id" >> "$tmp_pins"
      fi
      shopt -u nocasematch
    done < <(jq -r '
      .[] | [
        (.name // ""),
        (.logical_id // .semantic_id // .name // "")
      ] | @tsv
    ' <<< "$registry_json")

    local query="${sym_pattern//\*/}"
    query="${query//\?/}"
    if [[ -n "$query" && ${#query} -ge 3 ]]; then
      local search_json=""
      search_json=$(_capsule_context_call_json '{"results":[]}' search "$query" "5")
      jq -r '.results[]? | (.logical_id // .name // empty)' <<< "$search_json" >> "$tmp_pins" || true
    fi
  done <<< "$symbol_patterns"

  # Axis 3: import_from pattern
  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local abs_file="$CONTEXT_CAPSULE_REPO_ROOT/$changed_file"
    [[ -f "$abs_file" ]] || continue

    local imp_pattern=""
    while IFS= read -r imp_pattern; do
      [[ -n "$imp_pattern" ]] || continue
      if grep -qFi "$imp_pattern" "$abs_file" 2>/dev/null; then
        jq -r --arg f "$changed_file" '
          .[] | select((.file // "") == $f)
          | (.logical_id // .semantic_id // .name // empty)
        ' <<< "$registry_json" >> "$tmp_pins" || true

        local search_json=""
        search_json=$(_capsule_context_call_json '{"results":[]}' search "$imp_pattern" "3")
        jq -r '.results[]? | (.logical_id // .name // empty)' <<< "$search_json" >> "$tmp_pins" || true
      fi
    done <<< "$import_patterns"
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  local tmp_sorted=""
  tmp_sorted=$(create_temp_file "capsule_security_pins_sorted")
  sed '/^$/d' "$tmp_pins" | sort -u > "$tmp_sorted"
  jq -R . "$tmp_sorted" | jq -s 'map(select(length > 0))'

  /bin/rm -f "$tmp_pins" "$tmp_sorted"
}

_capsule_is_security_sensitive_json() {
  local changed_files_json="${1:-[]}"
  local changed_symbols_json="${2:-[]}"
  local registry_json="${3:-[]}"
  local security_cfg_json=""
  security_cfg_json=$(_capsule_security_config_json)

  local sensitive="false"
  local reason="none"

  local path_patterns=""
  path_patterns=$(jq -r '(.file_path_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")

  local changed_file=""
  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local pattern=""
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      if _capsule_path_matches_pattern "$changed_file" "$pattern"; then
        sensitive="true"
        reason="path:${pattern}"
        break 2
      fi
    done <<< "$path_patterns"
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  if [[ "$sensitive" != "true" ]]; then
    local symbol=""
    while IFS= read -r symbol; do
      [[ -n "$symbol" ]] || continue
      if grep -qiE '(auth|token|session|jwt|oauth|csrf|permission|rbac|acl|encrypt|decrypt|sanitize|validate|sign|verify)' <<< "$symbol"; then
        sensitive="true"
        reason="symbol:${symbol}"
        break
      fi
    done < <(jq -r '.[]? // empty' <<< "$changed_symbols_json")
  fi

  if [[ "$sensitive" != "true" ]]; then
    if jq -e \
      --argjson changed_files "$changed_files_json" \
      --argjson changed_symbols "$changed_symbols_json" \
      '
        any(
          .[];
          (((._security_level // "") | tostring | length) > 0)
          and (
            ($changed_files | index(.file // "")) != null
            or
            ($changed_symbols | index(.logical_id // .semantic_id // .name // "")) != null
          )
        )
      ' <<< "$registry_json" >/dev/null 2>&1; then
      sensitive="true"
      reason="registry:_security_level"
    fi
  fi

  if [[ "$sensitive" != "true" ]]; then
    local diff_snapshot=""
    diff_snapshot=$(
      cd "$CONTEXT_CAPSULE_REPO_ROOT"
      {
        git diff 2>/dev/null || true
        git diff --cached 2>/dev/null || true
      }
    )

    local keyword=""
    for keyword in "exec(" "eval(" "innerHTML" "dangerouslySetInnerHTML"; do
      if grep -qFi "$keyword" <<< "$diff_snapshot"; then
        sensitive="true"
        reason="literal:${keyword}"
        break
      fi
    done

    if [[ "$sensitive" != "true" ]]; then
      for keyword in password secret token credential api_key private_key authorization authentication; do
        if grep -qEi "$keyword" <<< "$diff_snapshot"; then
          sensitive="true"
          reason="regex:${keyword}"
          break
        fi
      done
    fi
  fi

  jq -nc --argjson sensitive "$sensitive" --arg reason "$reason" '{sensitive:$sensitive, reason:$reason}'
}

_capsule_prepare_figma_summary_ref() {
  local task_id="$1"
  local phase="$2"
  local changed_files_json="${3:-[]}"
  local changed_symbols_json="${4:-[]}"
  local registry_json="${5:-[]}"

  local refs_json=""
  refs_json=$(jq -n \
    --argjson registry "$registry_json" \
    --argjson changed_files "$changed_files_json" \
    --argjson changed_symbols "$changed_symbols_json" \
    '
      $registry
      | map(select((.figma_ref // null) != null and ((.figma_ref | tostring) | length > 0)))
      | map(
          select(
            ($changed_files | index(.file // "")) != null
            or
            ($changed_symbols | index(.logical_id // .semantic_id // .name // "")) != null
          )
        )
      | map({
          logical_id: (.logical_id // .semantic_id // .name // ""),
          file: (.file // ""),
          figma_ref: .figma_ref
        })
      | unique_by(.figma_ref)
    ')

  local ref_count=0
  ref_count=$(jq 'length' <<< "$refs_json")
  if [[ "$ref_count" -eq 0 ]]; then
    echo ""
    return 0
  fi

  ensure_dir "$CONTEXT_CAPSULE_TMP_DIR"

  local summary_json=""
  summary_json=$(jq -nc \
    --arg task_id "$task_id" \
    --arg phase "$phase" \
    --arg generated_at "$(get_timestamp)" \
    --argjson refs "$refs_json" \
    --argjson ref_count "$ref_count" \
    '{
      status: "pending_figma_summary_fetch",
      interface: "figma_summary_injection_v1",
      task_id: $task_id,
      phase: $phase,
      generated_at: $generated_at,
      figma_ref_count: $ref_count,
      refs: $refs
    }')

  local summary_hash=""
  summary_hash=$(_capsule_sha256 "$summary_json")
  local summary_file="$CONTEXT_CAPSULE_TMP_DIR/figma_${summary_hash}.json"
  if [[ ! -f "$summary_file" ]]; then
    printf '%s\n' "$summary_json" > "$summary_file"
  fi

  echo "sha256:${summary_hash}"
}

_capsule_delete_impacts_summary() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"
  local graph_json="${3:-}"
  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi

  local deletions_json=""
  deletions_json=$(_capsule_context_call_json '{"deleted_paths":[],"deleted_count":0,"removed_symbols":[],"move_candidates":[],"_idem_recalc_required":false}' detect-deletions "$base_ref" "$head_ref")

  local deleted_count=0
  deleted_count=$(jq -r '.deleted_count // 0' <<< "$deletions_json")
  if ! [[ "$deleted_count" =~ ^[0-9]+$ ]]; then
    deleted_count=0
  fi
  local removed_count=0
  removed_count=$(jq -r '(.removed_symbols // []) | length' <<< "$deletions_json" 2>/dev/null || echo "0")
  if ! [[ "$removed_count" =~ ^[0-9]+$ ]]; then
    removed_count=0
  fi

  local move_count=0
  move_count=$(jq -r '(.move_candidates // []) | length' <<< "$deletions_json" 2>/dev/null || echo "0")
  if ! [[ "$move_count" =~ ^[0-9]+$ ]]; then
    move_count=0
  fi

  if [[ "$deleted_count" -le 0 && "$removed_count" -le 0 ]]; then
    echo "none"
    return 0
  fi

  local adjacency_path=""
  adjacency_path=$(jq -r '.adjacency_path // empty' <<< "$graph_json")
  if [[ -z "$adjacency_path" ]]; then
    adjacency_path="$CONTEXT_CAPSULE_REPO_ROOT/.agent/context/adjacency.jsonl"
  fi

  local deleted_paths_json="[]"
  deleted_paths_json=$(jq -c '.deleted_paths // []' <<< "$deletions_json")

  local impacts_json=""
  impacts_json=$(_capsule_context_call_json \
    '{"reverse_dep":"unavailable","impact_count":0,"impacted_symbols":[]}' \
    check-delete-impacts "$adjacency_path" "$deleted_paths_json")

  local reverse_dep=""
  reverse_dep=$(jq -r '.reverse_dep // "unavailable"' <<< "$impacts_json")
  local impact_count=0
  impact_count=$(jq -r '.impact_count // (.impacts | length) // 0' <<< "$impacts_json")
  if ! [[ "$impact_count" =~ ^[0-9]+$ ]]; then
    impact_count=0
  fi

  if [[ "$reverse_dep" == "unavailable" ]]; then
    if [[ "$move_count" -gt 0 ]]; then
      echo "deleted:${deleted_count};rm_syms:${removed_count};moves:${move_count};reverse_dep:unavailable"
    else
      echo "deleted:${deleted_count};rm_syms:${removed_count};reverse_dep:unavailable"
    fi
    return 0
  fi

  if [[ "$impact_count" -gt 0 ]]; then
    local impacted_csv=""
    impacted_csv=$(jq -r '
      (.impacted_symbols // [])
      | map(select(type == "string" and length > 0))
      | .[:3]
      | join(",")
    ' <<< "$impacts_json")
    if [[ -z "$impacted_csv" ]]; then
      impacted_csv="n/a"
    fi
    if [[ "$move_count" -gt 0 ]]; then
      echo "deleted:${deleted_count};rm_syms:${removed_count};moves:${move_count};impact:${impact_count};symbols:${impacted_csv}"
    else
      echo "deleted:${deleted_count};rm_syms:${removed_count};impact:${impact_count};symbols:${impacted_csv}"
    fi
    return 0
  fi

  if [[ "$move_count" -gt 0 ]]; then
    echo "deleted:${deleted_count};rm_syms:${removed_count};moves:${move_count};impact:none"
  else
    echo "deleted:${deleted_count};rm_syms:${removed_count};impact:none"
  fi
}

_capsule_compose_scc() {
  local task_id="$1"
  local phase="$2"
  local changed_files="$3"
  local changed_symbols="$4"
  local conflicts="$5"
  local delete_impacts="$6"
  local security_sensitive="$7"
  local policy="$8"
  local context_mode="$9"
  local pinned_symbols="${10:-}"
  local figma_summary_ref="${11:-}"
  local body_ref_hash="${12:-}"
  local reason="${13:-}"
  local memory_hints="${14:-}"

  local body=""
  body+="TASK_ID=$(_capsule_escape_value "$task_id")"$'\n'
  body+="PHASE=$(_capsule_escape_value "$phase")"$'\n'
  body+="CHANGED_FILES=$(_capsule_escape_value "$changed_files")"$'\n'
  body+="CHANGED_SYMBOLS=$(_capsule_escape_value "$changed_symbols")"$'\n'
  body+="CONFLICTS=$(_capsule_escape_value "$conflicts")"$'\n'
  body+="DELETE_IMPACTS=$(_capsule_escape_value "$delete_impacts")"$'\n'
  body+="SECURITY_SENSITIVE=$(_capsule_escape_value "$security_sensitive")"$'\n'
  body+="POLICY=$(_capsule_escape_value "$policy")"$'\n'
  body+="CONTEXT_MODE=$(_capsule_escape_value "$context_mode")"$'\n'
  body+="MEMORY_HINTS=$(_capsule_escape_value "${memory_hints:-none}" 180)"$'\n'

  if [[ -n "$pinned_symbols" ]]; then
    body+="PINNED_SYMBOLS=$(_capsule_escape_value "$pinned_symbols")"$'\n'
  fi

  if [[ -n "$figma_summary_ref" ]]; then
    body+="FIGMA_SUMMARY_REF=$(_capsule_escape_value "$figma_summary_ref")"$'\n'
  fi

  if [[ -n "$body_ref_hash" ]]; then
    body+="BODY_REF=sha256:$(_capsule_escape_value "$body_ref_hash")"$'\n'
  fi

  if [[ -n "$reason" ]]; then
    body+="REASON=$(_capsule_escape_value "$reason")"$'\n'
  fi

  local hash=""
  hash=$(_capsule_sha256 "$body")
  printf '%sHASH=%s\n' "$body" "$hash"
}

_capsule_build_response_json() {
  local capsule="$1"
  local budget="$2"
  local stage="$3"
  local mode="$4"
  local verdict="$5"
  local body_ref_hash="${6:-}"

  local constraints_json=""
  constraints_json=$(jq -nc \
    --arg total "total<=${budget}" \
    --arg body "body<=${CAPSULE_BODY_TOKEN_BUDGET}" \
    --arg stage "stage=${stage}" \
    --arg mode "mode=${mode}" \
    --arg verdict "verdict=${verdict}" \
    '[ $total, $body, $stage, $mode, $verdict ]')

  local hints_json='[]'
  if [[ -n "$body_ref_hash" ]]; then
    hints_json=$(jq -nc --arg hint "BODY_REF=sha256:${body_ref_hash}" '[ $hint ]')
  fi

  while true; do
    local response_json=""
    response_json=$(jq -nc \
      --arg capsule "$capsule" \
      --argjson constraints "$constraints_json" \
      --argjson hints "$hints_json" \
      '{capsule:$capsule, constraints:$constraints, hints:$hints}')

    local body_tokens=0
    body_tokens=$(_estimate_tokens "$capsule")
    local total_tokens=0
    total_tokens=$(_estimate_tokens "$response_json")
    local overhead_tokens=$((total_tokens - body_tokens))

    if [[ "$body_tokens" -le "$CAPSULE_BODY_TOKEN_BUDGET" && "$total_tokens" -le "$budget" && "$overhead_tokens" -le "$CAPSULE_META_TOKEN_BUDGET" ]]; then
      echo "$response_json"
      return 0
    fi

    local hints_len=0
    hints_len=$(jq 'length' <<< "$hints_json")
    if [[ "$hints_len" -gt 0 ]]; then
      hints_json=$(jq '.[0:-1]' <<< "$hints_json")
      continue
    fi

    local constraints_len=0
    constraints_len=$(jq 'length' <<< "$constraints_json")
    if [[ "$constraints_len" -gt 1 ]]; then
      constraints_json=$(jq '.[0:-1]' <<< "$constraints_json")
      continue
    fi

    return 1
  done
}

capsule_budget_check() {
  local token_count="${1:-}"
  local budget="${2:-$MAX_CAPSULE_TOKENS}"

  if [[ -z "$token_count" ]]; then
    die "capsule_budget_check: token_count is required"
  fi

  if ! [[ "$token_count" =~ ^[0-9]+$ ]]; then
    die "capsule_budget_check: token_count must be numeric"
  fi

  if ! [[ "$budget" =~ ^[0-9]+$ ]]; then
    die "capsule_budget_check: budget must be numeric"
  fi

  local verdict="PASS"
  local within_budget=true
  if [[ "$token_count" -gt "$budget" ]]; then
    verdict="BLOCK"
    within_budget=false
  fi

  jq -nc \
    --arg verdict "$verdict" \
    --argjson token_count "$token_count" \
    --argjson budget "$budget" \
    --argjson within_budget "$within_budget" \
    '{verdict:$verdict, token_count:$token_count, budget:$budget, within_budget:$within_budget}'

  [[ "$verdict" == "PASS" ]]
}

_capsule_resolve_path_in_repo() {
  local raw_path="${1:-}"
  [[ -n "$raw_path" ]] || return 1

  local candidate="$raw_path"
  if [[ "$candidate" != /* ]]; then
    candidate="$CONTEXT_CAPSULE_REPO_ROOT/$candidate"
  fi

  local dir=""
  dir="$(dirname "$candidate")"
  local file=""
  file="$(basename "$candidate")"

  [[ -d "$dir" ]] || return 1

  local dir_real=""
  dir_real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  local resolved="$dir_real/$file"

  case "$resolved" in
    "$CONTEXT_CAPSULE_REPO_ROOT"/*)
      printf '%s\n' "$resolved"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

capsule_get_snippet() {
  local path="${1:-}"
  local start="${2:-}"
  local end="${3:-}"

  if [[ -z "$path" || -z "$start" || -z "$end" ]]; then
    die "capsule_get_snippet: <path> <start> <end> are required"
  fi

  if ! [[ "$start" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]]; then
    die "capsule_get_snippet: start/end must be positive integers"
  fi

  if [[ "$start" -le 0 || "$end" -le 0 ]]; then
    die "capsule_get_snippet: start/end must be >= 1"
  fi

  if [[ "$start" -gt "$end" ]]; then
    die "capsule_get_snippet: start must be <= end"
  fi

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    die "capsule_get_snippet: path is outside repository or invalid: $path"
  fi

  if [[ ! -f "$resolved_path" ]]; then
    die "capsule_get_snippet: file not found: $resolved_path"
  fi

  local line_span=$((end - start + 1))
  if [[ "$line_span" -gt "$MAX_CONTEXT_LINES" ]]; then
    log_warn "capsule_get_snippet: line span ${line_span} exceeds MAX_CONTEXT_LINES=${MAX_CONTEXT_LINES}. Clamping."
    end=$((start + MAX_CONTEXT_LINES - 1))
  fi

  awk -v start="$start" -v end="$end" '
    NR >= start && NR <= end {
      printf "%d:%s\n", NR, $0
    }
  ' "$resolved_path"
}

_capsule_file_line_count() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    return 1
  fi
  [[ -f "$resolved_path" ]] || return 1

  local total_lines=0
  total_lines=$(wc -l < "$resolved_path" | tr -d ' ')
  if [[ -z "$total_lines" ]]; then
    total_lines=0
  fi
  printf '%s\n' "$total_lines"
}

_capsule_tree_sitter_available() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "false"
    return 0
  fi

  if python3 - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
ok = importlib.util.find_spec("tree_sitter") is not None and importlib.util.find_spec("tree_sitter_languages") is not None
sys.exit(0 if ok else 1)
PY
  then
    echo "true"
  else
    echo "false"
  fi
}

_capsule_extract_symbols_json() {
  local path="${1:-}"
  local mode="${2:-regex}"

  if [[ -z "$path" ]]; then
    echo '[]'
    return 0
  fi

  local rel_path="$path"
  if [[ "$rel_path" == "$CONTEXT_CAPSULE_REPO_ROOT"/* ]]; then
    rel_path="${rel_path#"$CONTEXT_CAPSULE_REPO_ROOT"/}"
  fi
  rel_path="${rel_path#./}"

  local extractor="extract_symbols_regex"
  if [[ "$mode" == "treesitter" ]]; then
    extractor="extract_symbols_treesitter"
  fi

  local output=""
  if ! output=$(bash -c 'set -euo pipefail; source "$1"; "$2" "$3" 2>/dev/null || true' \
    _ "$CONTEXT_CAPSULE_CONTEXT_ANALYSIS" "$extractor" "$rel_path" 2>/dev/null); then
    echo '[]'
    return 0
  fi

  if [[ -z "$output" ]]; then
    echo '[]'
    return 0
  fi

  printf '%s\n' "$output" \
    | jq -R 'fromjson? | select(type == "object")' \
    | jq -s '
        map(
          select((.file? // "") != "" and (.line? != null))
          | .line = ((.line | tonumber?) // 0)
          | select(.line > 0)
        )
      '
}

_capsule_symbol_ranges_json_for_file() {
  local path="${1:-}"
  local mode="${2:-treesitter}"
  if [[ -z "$path" ]]; then
    echo '[]'
    return 0
  fi

  local total_lines=0
  if ! total_lines=$(_capsule_file_line_count "$path"); then
    echo '[]'
    return 0
  fi
  if [[ "$total_lines" -le 0 ]]; then
    echo '[]'
    return 0
  fi

  local symbols_json='[]'
  symbols_json=$(_capsule_extract_symbols_json "$path" "$mode")

  jq -n \
    --argjson syms "$symbols_json" \
    --argjson total "$total_lines" \
    '
      ($syms | sort_by(.line)) as $ordered
      | [
          range(0; ($ordered | length)) as $i
          | ($ordered[$i]) as $cur
          | ($ordered[$i + 1].line // ($total + 1)) as $next_line
          | ($cur.line | tonumber) as $start
          | ((($next_line | tonumber) - 1)) as $candidate_end
          | {
              file: ($cur.file // ""),
              name: ($cur.name // ""),
              kind: ($cur.kind // ""),
              logical_id: ($cur.logical_id // ""),
              start: $start,
              end: (if $candidate_end < $start then $start else $candidate_end end)
            }
        ]
    '
}

_capsule_extract_import_header_snippet() {
  local path="${1:-}"
  local scan_limit="${2:-120}"
  [[ -n "$path" ]] || return 0

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    return 0
  fi
  [[ -f "$resolved_path" ]] || return 0

  awk -v limit="$scan_limit" '
    NR > limit { exit }
    {
      if ($0 ~ /^[[:space:]]*(import[[:space:]]|from[[:space:]].*[[:space:]]import[[:space:]]|const[[:space:]].*require[[:space:]]*\(|require[[:space:]]*\(|#include[[:space:]]|using[[:space:]]|package[[:space:]])/) {
        print NR ":" $0
        found = 1
        next
      }

      if (found == 1) {
        if ($0 ~ /^[[:space:]]*$/) {
          print NR ":" $0
          next
        }
        exit
      }

      if ($0 !~ /^[[:space:]]*(#|\/\/|\/\*|\*|$)/) {
        exit
      }
    }
  ' "$resolved_path"
}

_capsule_extract_test_setup_teardown_snippet() {
  local path="${1:-}"
  local start="${2:-1}"
  local end="${3:-1}"
  [[ -n "$path" ]] || return 0

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    return 0
  fi
  [[ -f "$resolved_path" ]] || return 0

  if ! [[ "$start" =~ ^[0-9]+$ ]]; then
    start=1
  fi
  if ! [[ "$end" =~ ^[0-9]+$ ]]; then
    end="$start"
  fi
  if [[ "$start" -gt "$end" ]]; then
    local tmp="$start"
    start="$end"
    end="$tmp"
  fi

  local region_start=$((start - 150))
  local region_end=$((end + 150))
  if [[ "$region_start" -lt 1 ]]; then
    region_start=1
  fi

  awk -v min="$region_start" -v max="$region_end" '
    {
      lines[NR] = $0
      if ($0 ~ /(beforeEach|afterEach|beforeAll|afterAll|setUp|tearDown|setup\(|teardown\(|pytest\.fixture|describe\(|it\(|test\()/) {
        hit[NR] = 1
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (hit[i]) {
          for (j = i - 1; j <= i + 3; j++) {
            if (j >= min && j <= max && j >= 1 && j <= NR) {
              keep[j] = 1
            }
          }
        }
      }

      emitted = 0
      for (i = min; i <= max && i <= NR; i++) {
        if (keep[i]) {
          print i ":" lines[i]
          emitted++
          if (emitted >= 80) {
            break
          }
        }
      }
    }
  ' "$resolved_path"
}

_capsule_extract_class_outline_snippet() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 0

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    return 0
  fi
  [[ -f "$resolved_path" ]] || return 0

  awk '
    /^[[:space:]]*(class|interface|enum|struct|type)[[:space:]]+[A-Za-z_]/ \
    || /^[[:space:]]*(def|function|func)[[:space:]]+[A-Za-z_]/ \
    || /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{/ \
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      print NR ":" line
      count++
      if (count >= 80) {
        exit
      }
    }
  ' "$resolved_path"
}

_capsule_build_window_object() {
  local path="${1:-}"
  local start="${2:-}"
  local end="${3:-}"
  local kind="${4:-primary}"
  local reason="${5:-window_selection}"
  local source="${6:-unknown}"
  local line_limit="${7:-250}"

  if [[ -z "$path" || -z "$start" || -z "$end" ]]; then
    return 1
  fi
  if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$line_limit" =~ ^[0-9]+$ ]]; then
    line_limit=250
  fi
  if [[ "$line_limit" -le 0 ]]; then
    line_limit=250
  fi

  local resolved_path=""
  if ! resolved_path=$(_capsule_resolve_path_in_repo "$path"); then
    return 1
  fi
  [[ -f "$resolved_path" ]] || return 1

  local rel_path="$resolved_path"
  if [[ "$rel_path" == "$CONTEXT_CAPSULE_REPO_ROOT"/* ]]; then
    rel_path="${rel_path#"$CONTEXT_CAPSULE_REPO_ROOT"/}"
  fi

  local total_lines=0
  total_lines=$(wc -l < "$resolved_path" | tr -d ' ')
  if [[ -z "$total_lines" || "$total_lines" -le 0 ]]; then
    return 1
  fi

  local s="$start"
  local e="$end"
  if [[ "$s" -lt 1 ]]; then
    s=1
  fi
  if [[ "$e" -lt 1 ]]; then
    e=1
  fi
  if [[ "$s" -gt "$e" ]]; then
    local swap="$s"
    s="$e"
    e="$swap"
  fi
  if [[ "$s" -gt "$total_lines" ]]; then
    s="$total_lines"
  fi
  if [[ "$e" -gt "$total_lines" ]]; then
    e="$total_lines"
  fi

  if [[ $((e - s + 1)) -gt "$line_limit" ]]; then
    e=$((s + line_limit - 1))
  fi
  if [[ "$e" -gt "$total_lines" ]]; then
    e="$total_lines"
    if [[ $((e - line_limit + 1)) -gt 0 ]]; then
      s=$((e - line_limit + 1))
    else
      s=1
    fi
  fi
  if [[ "$s" -lt 1 ]]; then
    s=1
  fi
  if [[ "$e" -lt "$s" ]]; then
    e="$s"
  fi

  local line_count=$((e - s + 1))
  local snippet=""
  snippet=$(capsule_get_snippet "$rel_path" "$s" "$e" 2>/dev/null || true)

  local import_header=""
  import_header=$(_capsule_extract_import_header_snippet "$rel_path" 120)

  local test_setup=""
  test_setup=$(_capsule_extract_test_setup_teardown_snippet "$rel_path" "$s" "$e")

  local class_outline=""
  class_outline=$(_capsule_extract_class_outline_snippet "$rel_path")

  jq -nc \
    --arg path "$rel_path" \
    --argjson start "$s" \
    --argjson end "$e" \
    --argjson line_count "$line_count" \
    --arg kind "$kind" \
    --arg reason "$reason" \
    --arg source "$source" \
    --arg snippet "$snippet" \
    --arg import_header "$import_header" \
    --arg test_setup_teardown "$test_setup" \
    --arg class_outline "$class_outline" \
    '{
      path:$path,
      start:$start,
      end:$end,
      line_count:$line_count,
      kind:$kind,
      reason:$reason,
      source:$source,
      snippet:$snippet,
      import_header:$import_header,
      test_setup_teardown:$test_setup_teardown,
      class_outline:$class_outline
    }'
}

_capsule_emit_centered_window_json() {
  local path="${1:-}"
  local range_start="${2:-}"
  local range_end="${3:-}"
  local padding="${4:-125}"
  local kind="${5:-primary}"
  local reason="${6:-diff_hunk_window}"
  local source="${7:-diff_hunk}"
  local line_limit="${8:-250}"

  if [[ -z "$path" || -z "$range_start" || -z "$range_end" ]]; then
    return 1
  fi
  if ! [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$padding" =~ ^[0-9]+$ ]]; then
    padding=125
  fi
  if ! [[ "$line_limit" =~ ^[0-9]+$ ]] || [[ "$line_limit" -le 0 ]]; then
    line_limit=250
  fi

  local rs="$range_start"
  local re="$range_end"
  if [[ "$rs" -gt "$re" ]]; then
    local swap="$rs"
    rs="$re"
    re="$swap"
  fi

  local center=$(((rs + re) / 2))
  local start=$((center - padding))
  local end=$((center + padding))

  if [[ "$start" -lt 1 ]]; then
    start=1
  fi
  if [[ $((end - start + 1)) -gt "$line_limit" ]]; then
    end=$((start + line_limit - 1))
  fi

  _capsule_build_window_object "$path" "$start" "$end" "$kind" "$reason" "$source" "$line_limit"
}

_capsule_windows_from_diff_hunks() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"
  local padding="${3:-125}"
  local merge_gap="${4:-50}"
  local kind="${5:-primary}"
  local reason="${6:-diff_hunk_window}"
  local source="${7:-diff_hunk}"
  local line_limit="${8:-250}"

  if ! [[ "$padding" =~ ^[0-9]+$ ]]; then
    padding=125
  fi
  if ! [[ "$merge_gap" =~ ^[0-9]+$ ]]; then
    merge_gap=50
  fi
  if ! [[ "$line_limit" =~ ^[0-9]+$ ]] || [[ "$line_limit" -le 0 ]]; then
    line_limit=250
  fi

  local tmp_hunks=""
  local tmp_sorted=""
  local tmp_windows=""
  tmp_hunks=$(create_temp_file "capsule_hunks")
  tmp_sorted=$(create_temp_file "capsule_hunks_sorted")
  tmp_windows=$(create_temp_file "capsule_hunk_windows")
  : > "$tmp_windows"

  local diff_line=""
  local file=""
  while IFS= read -r diff_line; do
    case "$diff_line" in
      "+++ b/"*)
        file="${diff_line#+++ b/}"
        ;;
      "@@ "*)
        if [[ -z "$file" || "$file" == "/dev/null" ]]; then
          continue
        fi

        if ! [[ "$diff_line" =~ ^@@[[:space:]][^+]*\+([0-9]+)(,([0-9]+))?[[:space:]]@@ ]]; then
          continue
        fi

        local start="${BASH_REMATCH[1]}"
        local count="${BASH_REMATCH[3]:-1}"
        if [[ "$count" -le 0 ]]; then
          count=1
        fi

        local end=$((start + count - 1))
        if [[ "$end" -lt "$start" ]]; then
          end="$start"
        fi

        printf '%s\t%s\t%s\n' "$file" "$start" "$end" >> "$tmp_hunks"
        ;;
    esac
  done < <(
    cd "$CONTEXT_CAPSULE_REPO_ROOT"
    git diff --unified=0 --no-color "$base_ref" "$head_ref" 2>/dev/null || true
  )

  if [[ ! -s "$tmp_hunks" ]]; then
    /bin/rm -f "$tmp_hunks" "$tmp_sorted" "$tmp_windows"
    echo '[]'
    return 0
  fi

  sort -t $'\t' -k1,1 -k2,2n "$tmp_hunks" > "$tmp_sorted"

  local current_file=""
  local current_start=0
  local current_end=0

  while IFS=$'\t' read -r file start end; do
    [[ -n "$file" ]] || continue
    if [[ -z "$current_file" ]]; then
      current_file="$file"
      current_start="$start"
      current_end="$end"
      continue
    fi

    if [[ "$file" == "$current_file" && "$start" -le $((current_end + merge_gap)) ]]; then
      if [[ "$end" -gt "$current_end" ]]; then
        current_end="$end"
      fi
      continue
    fi

    local window_obj=""
    if window_obj=$(_capsule_emit_centered_window_json \
      "$current_file" "$current_start" "$current_end" "$padding" "$kind" "$reason" "$source" "$line_limit"); then
      jq -c '.' <<< "$window_obj" >> "$tmp_windows"
    fi

    current_file="$file"
    current_start="$start"
    current_end="$end"
  done < "$tmp_sorted"

  if [[ -n "$current_file" ]]; then
    local last_window=""
    if last_window=$(_capsule_emit_centered_window_json \
      "$current_file" "$current_start" "$current_end" "$padding" "$kind" "$reason" "$source" "$line_limit"); then
      jq -c '.' <<< "$last_window" >> "$tmp_windows"
    fi
  fi

  if [[ ! -s "$tmp_windows" ]]; then
    /bin/rm -f "$tmp_hunks" "$tmp_sorted" "$tmp_windows"
    echo '[]'
    return 0
  fi

  jq -s '
    map(select(type == "object"))
    | reduce .[] as $w (
        [];
        if any(.[]; .path == $w.path and .start == $w.start and .end == $w.end) then
          .
        else
          . + [$w]
        end
      )
  ' "$tmp_windows"

  /bin/rm -f "$tmp_hunks" "$tmp_sorted" "$tmp_windows"
}

_capsule_windows_from_treesitter() {
  local diff_json="${1:-}"
  local graph_json="${2:-}"
  if [[ -z "$diff_json" ]]; then
    diff_json='{}'
  fi
  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi

  local tmp_windows=""
  tmp_windows=$(create_temp_file "capsule_ts_windows")
  : > "$tmp_windows"

  local current_file=""
  local current_ranges='[]'

  while IFS=$'\t' read -r file line logical_id name; do
    [[ -n "$file" ]] || continue
    if ! [[ "$line" =~ ^[0-9]+$ ]] || [[ "$line" -le 0 ]]; then
      line=1
    fi

    if [[ "$file" != "$current_file" ]]; then
      current_ranges=$(_capsule_symbol_ranges_json_for_file "$file" "treesitter")
      current_file="$file"
    fi

    if [[ "$(jq 'length' <<< "$current_ranges" 2>/dev/null || echo 0)" -eq 0 ]]; then
      continue
    fi

    local selected_range=""
    selected_range=$(jq -n \
      --argjson ranges "$current_ranges" \
      --argjson line "$line" \
      --arg logical_id "$logical_id" \
      --arg name "$name" \
      '
        def abs: if . < 0 then -. else . end;
        ($ranges // []) as $r
        | if ($r | length) == 0 then
            null
          else
            (
              $r
              | map(select(($logical_id | length) > 0 and (.logical_id // "") == $logical_id))
            ) as $by_id
            | (
                if ($by_id | length) > 0 then
                  $by_id[0]
                else
                  (
                    $r
                    | map(select(($line >= .start) and ($line <= .end)))
                    | .[0]
                  ) // (
                    $r
                    | map(. + {dist: ((.start - $line) | abs)})
                    | sort_by(.dist, .start)
                    | .[0]
                    | del(.dist)
                  )
                end
              )
          end
      ')

    if [[ "$(jq -r 'if . == null then "null" else "ok" end' <<< "$selected_range")" == "null" ]]; then
      continue
    fi

    local range_start=0
    local range_end=0
    range_start=$(jq -r '.start // 0' <<< "$selected_range")
    range_end=$(jq -r '.end // 0' <<< "$selected_range")
    if [[ "$range_start" -le 0 || "$range_end" -le 0 ]]; then
      continue
    fi
    if [[ "$range_end" -lt "$range_start" ]]; then
      range_end="$range_start"
    fi

    local span=$((range_end - range_start + 1))
    local target_start="$range_start"
    local target_end="$range_end"
    local truncated=false
    local reason="changed_symbol_ast"
    local reconstructed_snippet=""
    local reconstructed_line_count=0
    local reconstructed_start=0
    local reconstructed_end=0
    local signature_start=0
    local signature_end=0
    local body_head_start=0
    local body_head_end=0
    local pagerank_fill_lines=0
    if [[ "$span" -gt 250 ]]; then
      target_end=$((target_start + 249))
      truncated=true
      reason="changed_symbol_ast_truncated"

      local resolved_target_path=""
      if resolved_target_path=$(_capsule_resolve_path_in_repo "$file"); then
        local signature_scan_end=$((target_start + 39))
        if [[ "$signature_scan_end" -gt "$range_end" ]]; then
          signature_scan_end="$range_end"
        fi

        local signature_candidate_start=0
        signature_candidate_start=$(awk -v start="$target_start" -v end="$signature_scan_end" '
          NR < start { next }
          NR > end { exit }
          /^[[:space:]]*(async[[:space:]]+)?(def|class|function|func|interface|struct|enum|type)[[:space:]]+[A-Za-z_]/ {
            print NR
            exit
          }
        ' "$resolved_target_path" 2>/dev/null || true)

        if ! [[ "$signature_candidate_start" =~ ^[0-9]+$ ]] || [[ "$signature_candidate_start" -le 0 ]]; then
          signature_start="$target_start"
        else
          signature_start="$signature_candidate_start"
        fi
        if [[ "$signature_start" -lt "$range_start" ]]; then
          signature_start="$range_start"
        fi
        if [[ "$signature_start" -gt "$range_end" ]]; then
          signature_start="$range_start"
        fi

        signature_end=$((signature_start + 19))
        if [[ "$signature_end" -gt "$range_end" ]]; then
          signature_end="$range_end"
        fi

        body_head_start=$((signature_end + 1))
        if [[ "$body_head_start" -le "$range_end" ]]; then
          body_head_end=$((body_head_start + 99))
          if [[ "$body_head_end" -gt "$range_end" ]]; then
            body_head_end="$range_end"
          fi
        else
          body_head_start=0
          body_head_end=0
        fi

        local seed_lines_json='[]'
        seed_lines_json=$(jq -n \
          --argjson sig_start "$signature_start" \
          --argjson sig_end "$signature_end" \
          --argjson body_start "$body_head_start" \
          --argjson body_end "$body_head_end" \
          '
            [
              (if ($sig_start > 0 and $sig_end >= $sig_start) then range($sig_start; ($sig_end + 1)) else empty end),
              (if ($body_start > 0 and $body_end >= $body_start) then range($body_start; ($body_end + 1)) else empty end)
            ]
            | unique
            | sort
          ')

        local pagerank_lines_json='[]'
        pagerank_lines_json=$(jq -n \
          --argjson graph "$graph_json" \
          --arg file "$file" \
          --arg file_norm "${file#./}" \
          --argjson range_start "$range_start" \
          --argjson range_end "$range_end" \
          '
            ($graph.ranked_symbols // [])
            | map(
                {
                  file: (.file // ""),
                  line: ((.line // 0) | tonumber),
                  score: ((.score // 0) | tonumber)
                }
              )
            | map(
                select(
                  (
                    .file == $file
                    or .file == $file_norm
                    or ((.file | sub("^\\./"; "")) == $file_norm)
                  )
                  and (.line >= $range_start and .line <= $range_end)
                )
              )
            | sort_by(-.score, .line)
            | map(.line)
          ')

        local selected_lines_json='[]'
        selected_lines_json=$(jq -n \
          --argjson seed "$seed_lines_json" \
          --argjson candidates "$pagerank_lines_json" \
          --argjson range_start "$range_start" \
          --argjson range_end "$range_end" \
          --argjson body_end "$body_head_end" \
          --argjson cap 250 \
          '
            def clamp($v; $lo; $hi):
              if $v < $lo then $lo elif $v > $hi then $hi else $v end;
            def append_unique($arr; $line):
              if (($arr | index($line)) == null) and ($line >= $range_start and $line <= $range_end) then
                $arr + [$line]
              else
                $arr
              end;

            ($seed | unique | sort) as $base
            | reduce $candidates[] as $line (
                $base;
                if (length >= $cap) then
                  .
                else
                  reduce [($line - 2), ($line - 1), $line, ($line + 1), ($line + 2)][] as $nearby (.;
                    if length >= $cap then
                      .
                    else
                      append_unique(.; (clamp($nearby; $range_start; $range_end)))
                    end
                  )
                end
              )
            | if length >= $cap then
                .
              else
                reduce range(($body_end + 1); ($range_end + 1)) as $line (.;
                  if length >= $cap then . else append_unique(.; $line) end
                )
              end
            | unique
            | sort
          ')

        reconstructed_line_count=$(jq -r 'length' <<< "$selected_lines_json" 2>/dev/null || echo 0)
        if [[ "$reconstructed_line_count" -gt 0 ]]; then
          reconstructed_start=$(jq -r '.[0] // 0' <<< "$selected_lines_json" 2>/dev/null || echo 0)
          reconstructed_end=$(jq -r 'if length > 0 then .[-1] else 0 end' <<< "$selected_lines_json" 2>/dev/null || echo 0)
          pagerank_fill_lines=$(jq -n \
            --argjson lines "$selected_lines_json" \
            --argjson sig_start "$signature_start" \
            --argjson sig_end "$signature_end" \
            --argjson body_start "$body_head_start" \
            --argjson body_end "$body_head_end" \
            '
              def in_seed($ln):
                (
                  ($sig_start > 0 and $sig_end >= $sig_start and $ln >= $sig_start and $ln <= $sig_end)
                  or ($body_start > 0 and $body_end >= $body_start and $ln >= $body_start and $ln <= $body_end)
                );
              ($lines | map(select(in_seed(.) | not)) | length)
            ' 2>/dev/null || echo 0)

          local selected_csv=""
          selected_csv=$(jq -r 'join(",")' <<< "$selected_lines_json" 2>/dev/null || echo "")
          if [[ -n "$selected_csv" ]]; then
            reconstructed_snippet=$(awk -v line_csv="$selected_csv" '
              BEGIN {
                count = split(line_csv, arr, ",")
                for (i = 1; i <= count; i++) {
                  if (arr[i] ~ /^[0-9]+$/) {
                    keep[arr[i]] = 1
                  }
                }
              }
              {
                if (keep[NR]) {
                  printf "%d:%s\n", NR, $0
                }
              }
            ' "$resolved_target_path")
          fi
        fi
      fi
    fi

    local window_obj=""
    if ! window_obj=$(_capsule_build_window_object \
      "$file" "$target_start" "$target_end" "primary" "$reason" "tree_sitter" 250); then
      continue
    fi

    if [[ "$truncated" == true && -n "$reconstructed_snippet" && "$reconstructed_line_count" -gt 0 ]]; then
      window_obj=$(jq -c \
        --arg snippet "$reconstructed_snippet" \
        --argjson line_count "$reconstructed_line_count" \
        --argjson start "$reconstructed_start" \
        --argjson end "$reconstructed_end" \
        --argjson sig_start "$signature_start" \
        --argjson sig_end "$signature_end" \
        --argjson body_start "$body_head_start" \
        --argjson body_end "$body_head_end" \
        --argjson pagerank_fill "$pagerank_fill_lines" \
        '
          . + {
            start:$start,
            end:$end,
            line_count:$line_count,
            snippet:$snippet,
            truncation_segments:{
              signature:{start:$sig_start, end:$sig_end},
              body_head100:{start:$body_start, end:$body_end},
              pagerank_fill_line_count:$pagerank_fill
            }
          }
        ' <<< "$window_obj")
    fi

    local score=0
    score=$(jq -n \
      --argjson graph "$graph_json" \
      --arg logical_id "$logical_id" \
      --arg file "$file" \
      --argjson line "$line" \
      '
        (
          if ($logical_id | length) > 0 then
            (($graph.ranked_symbols // []) | map(select((.logical_id // "") == $logical_id)) | .[0].score)
          else
            null
          end
        ) as $s1
        | (
            if $s1 == null then
              (($graph.ranked_symbols // []) | map(select((.file // "") == $file and ((.line // 0) | tonumber) == $line)) | .[0].score)
            else
              $s1
            end
          ) as $s2
        | if $s2 == null then 0 else $s2 end
      ')

    window_obj=$(jq -c \
      --argjson score "$score" \
      --argjson truncated "$truncated" \
      --arg logical_id "$logical_id" \
      '
        . + {score:$score, truncated:$truncated, logical_id:$logical_id, pagerank_priority:true}
        + (if $truncated then {truncation_strategy:"signature_plus_head100_pagerank_priority"} else {} end)
      ' <<< "$window_obj")

    printf '%s\n' "$window_obj" >> "$tmp_windows"
  done < <(
    jq -r '.changed_symbols[]? | [.file // "", ((.line // 0) | tonumber), (.logical_id // ""), (.name // "")] | @tsv' <<< "$diff_json" 2>/dev/null || true
  )

  if [[ ! -s "$tmp_windows" ]]; then
    /bin/rm -f "$tmp_windows"
    echo '[]'
    return 0
  fi

  jq -s '
    map(select(type == "object"))
    | sort_by(-(.score // 0), .path, .start, .end)
    | reduce .[] as $w (
        [];
        if any(.[]; .path == $w.path and .start == $w.start and .end == $w.end) then
          .
        else
          . + [$w]
        end
      )
  ' "$tmp_windows"

  /bin/rm -f "$tmp_windows"
}

_capsule_window_from_regex_density_for_file() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1

  local total_lines=0
  if ! total_lines=$(_capsule_file_line_count "$path"); then
    return 1
  fi
  if [[ "$total_lines" -le 0 ]]; then
    return 1
  fi

  local symbols_json='[]'
  symbols_json=$(_capsule_extract_symbols_json "$path" "regex")

  local best_json=""
  best_json=$(jq -n \
    --argjson syms "$symbols_json" \
    --argjson total "$total_lines" \
    '
      def clamp_start($s):
        if $total <= 250 then 1
        else
          if $s < 1 then 1
          elif $s > ($total - 249) then ($total - 249)
          else $s end
        end;

      ($syms | map((.line // 0) | tonumber) | map(select(. > 0)) | unique | sort) as $lines
      | if ($lines | length) == 0 then
          {}
        else
          reduce $lines[] as $ln (
            {start:1, count:-1};
            (clamp_start($ln - 125)) as $s
            | (if $total <= 250 then $total else ($s + 249) end) as $e
            | ($lines | map(select(. >= $s and . <= $e)) | length) as $c
            | if ($c > .count) or ($c == .count and $s < .start) then
                {start:$s, count:$c}
              else
                .
              end
          )
          | if .count < 0 then
              {}
            else
              {
                start: .start,
                end: (if $total <= 250 then $total else (.start + 249) end),
                score: .count
              }
            end
        end
    ')

  local start=0
  local end=0
  local score=0
  start=$(jq -r '.start // 0' <<< "$best_json")
  end=$(jq -r '.end // 0' <<< "$best_json")
  score=$(jq -r '.score // 0' <<< "$best_json")
  if [[ "$start" -le 0 || "$end" -le 0 ]]; then
    return 1
  fi

  local window_obj=""
  if ! window_obj=$(_capsule_build_window_object "$path" "$start" "$end" "primary" "regex_symbol_density" "regex_fallback" 250); then
    return 1
  fi

  jq -c --argjson score "$score" '. + {score:$score}' <<< "$window_obj"
}

_capsule_windows_from_regex_density() {
  local changed_files_json="${1:-[]}"

  local tmp_windows=""
  tmp_windows=$(create_temp_file "capsule_regex_windows")
  : > "$tmp_windows"

  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    local candidate=""
    if candidate=$(_capsule_window_from_regex_density_for_file "$file"); then
      printf '%s\n' "$candidate" >> "$tmp_windows"
    fi
  done < <(jq -r '.[]?' <<< "$changed_files_json" 2>/dev/null || true)

  if [[ ! -s "$tmp_windows" ]]; then
    /bin/rm -f "$tmp_windows"
    echo '[]'
    return 0
  fi

  jq -s '
    map(select(type == "object"))
    | sort_by(-(.score // 0), .path, .start)
    | if length > 0 then [.[0]] else [] end
  ' "$tmp_windows"

  /bin/rm -f "$tmp_windows"
}

_capsule_fallback_first_window() {
  local changed_files_json="${1:-[]}"

  local fallback_path=""
  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if _capsule_resolve_path_in_repo "$file" >/dev/null 2>&1; then
      fallback_path="$file"
      break
    fi
  done < <(jq -r '.[]?' <<< "$changed_files_json" 2>/dev/null || true)

  if [[ -z "$fallback_path" ]]; then
    fallback_path=$(
      cd "$CONTEXT_CAPSULE_REPO_ROOT" && git ls-files 2>/dev/null | head -n 1
    )
  fi

  if [[ -z "$fallback_path" ]]; then
    echo '[]'
    return 0
  fi

  local window_obj=""
  if ! window_obj=$(_capsule_build_window_object "$fallback_path" 1 250 "primary" "first_250_fallback" "fallback" 250); then
    echo '[]'
    return 0
  fi

  jq -nc --argjson window "$window_obj" '[ $window ]'
}

_capsule_dependency_window() {
  local diff_json="${1:-}"
  local graph_json="${2:-}"
  local primary_windows_json="${3:-[]}"
  if [[ -z "$diff_json" ]]; then
    diff_json='{}'
  fi
  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi

  local primary_path=""
  local primary_start=0
  local primary_end=0
  primary_path=$(jq -r '.[0].path // ""' <<< "$primary_windows_json" 2>/dev/null || echo "")
  primary_start=$(jq -r '.[0].start // 0' <<< "$primary_windows_json" 2>/dev/null || echo 0)
  primary_end=$(jq -r '.[0].end // 0' <<< "$primary_windows_json" 2>/dev/null || echo 0)

  local file=""
  local line=0
  local logical_id=""
  local score=0

  while IFS=$'\t' read -r file line logical_id score; do
    [[ -n "$file" ]] || continue
    if ! [[ "$line" =~ ^[0-9]+$ ]] || [[ "$line" -le 0 ]]; then
      continue
    fi

    local start=$((line - 125))
    local end=$((line + 124))
    local window_obj=""
    if ! window_obj=$(_capsule_build_window_object "$file" "$start" "$end" "dependency" "dependency_impact_symbol" "impact_graph" 250); then
      continue
    fi

    local w_path=""
    local w_start=0
    local w_end=0
    w_path=$(jq -r '.path // ""' <<< "$window_obj")
    w_start=$(jq -r '.start // 0' <<< "$window_obj")
    w_end=$(jq -r '.end // 0' <<< "$window_obj")

    if [[ -n "$primary_path" && "$w_path" == "$primary_path" ]]; then
      if [[ "$w_start" -le "$primary_end" && "$w_end" -ge "$primary_start" ]]; then
        continue
      fi
    fi

    window_obj=$(jq -c \
      --argjson score "$score" \
      --arg logical_id "$logical_id" \
      '. + {score:$score, logical_id:$logical_id}' <<< "$window_obj")

    jq -nc --argjson window "$window_obj" '[ $window ]'
    return 0
  done < <(
    jq -r '.impacted_symbols[]? | [.file // "", ((.line // 0) | tonumber), (.logical_id // ""), (.impact_score // 0)] | @tsv' <<< "$diff_json" 2>/dev/null || true
  )

  while IFS=$'\t' read -r file line logical_id score; do
    [[ -n "$file" ]] || continue
    if ! [[ "$line" =~ ^[0-9]+$ ]] || [[ "$line" -le 0 ]]; then
      continue
    fi

    local start=$((line - 125))
    local end=$((line + 124))
    local window_obj=""
    if ! window_obj=$(_capsule_build_window_object "$file" "$start" "$end" "dependency" "dependency_pagerank_symbol" "graph_rank" 250); then
      continue
    fi

    local w_path=""
    local w_start=0
    local w_end=0
    w_path=$(jq -r '.path // ""' <<< "$window_obj")
    w_start=$(jq -r '.start // 0' <<< "$window_obj")
    w_end=$(jq -r '.end // 0' <<< "$window_obj")

    if [[ -n "$primary_path" && "$w_path" == "$primary_path" ]]; then
      if [[ "$w_start" -le "$primary_end" && "$w_end" -ge "$primary_start" ]]; then
        continue
      fi
    fi

    window_obj=$(jq -c \
      --argjson score "$score" \
      --arg logical_id "$logical_id" \
      '. + {score:$score, logical_id:$logical_id}' <<< "$window_obj")

    jq -nc --argjson window "$window_obj" '[ $window ]'
    return 0
  done < <(
    jq -r '.ranked_symbols[]? | [.file // "", ((.line // 0) | tonumber), (.logical_id // ""), (.score // 0)] | @tsv' <<< "$graph_json" 2>/dev/null || true
  )

  echo '[]'
}

_capsule_ranked_symbol_windows() {
  local graph_json="${1:-}"
  local limit="${2:-5}"
  local padding="${3:-100}"
  local line_limit="${4:-201}"
  local kind="${5:-review_ranked}"
  local reason="${6:-reviewer_pagerank}"
  local source="${7:-graph_rank}"
  if [[ -z "$graph_json" ]]; then
    graph_json='{}'
  fi

  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
    echo '[]'
    return 0
  fi
  if ! [[ "$padding" =~ ^[0-9]+$ ]]; then
    padding=100
  fi
  if ! [[ "$line_limit" =~ ^[0-9]+$ ]] || [[ "$line_limit" -le 0 ]]; then
    line_limit=201
  fi

  local tmp_windows=""
  tmp_windows=$(create_temp_file "capsule_ranked_windows")
  : > "$tmp_windows"

  local file=""
  local line=0
  local logical_id=""
  local score=0
  local count=0
  while IFS=$'\t' read -r file line logical_id score; do
    [[ -n "$file" ]] || continue
    if ! [[ "$line" =~ ^[0-9]+$ ]] || [[ "$line" -le 0 ]]; then
      continue
    fi

    local start=$((line - padding))
    local end=$((line + padding))
    local window_obj=""
    if window_obj=$(_capsule_build_window_object "$file" "$start" "$end" "$kind" "$reason" "$source" "$line_limit"); then
      window_obj=$(jq -c \
        --argjson score "$score" \
        --arg logical_id "$logical_id" \
        '. + {score:$score, logical_id:$logical_id}' <<< "$window_obj")
      printf '%s\n' "$window_obj" >> "$tmp_windows"
      count=$((count + 1))
      if [[ "$count" -ge "$limit" ]]; then
        break
      fi
    fi
  done < <(
    jq -r '.ranked_symbols[]? | [.file // "", ((.line // 0) | tonumber), (.logical_id // ""), (.score // 0)] | @tsv' <<< "$graph_json" 2>/dev/null || true
  )

  if [[ ! -s "$tmp_windows" ]]; then
    /bin/rm -f "$tmp_windows"
    echo '[]'
    return 0
  fi

  jq -s '
    map(select(type == "object"))
    | reduce .[] as $w (
        [];
        if any(.[]; .path == $w.path and .start == $w.start and .end == $w.end) then
          .
        else
          . + [$w]
        end
      )
  ' "$tmp_windows"

  /bin/rm -f "$tmp_windows"
}

_capsule_append_windows_with_limit() {
  local base_windows_json="${1:-[]}"
  local add_windows_json="${2:-[]}"
  local limit="${3:-3}"

  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
    limit=3
  fi

  jq -n \
    --argjson base "$base_windows_json" \
    --argjson add "$add_windows_json" \
    --argjson limit "$limit" \
    '
      ([$base[], $add[]] | map(select(type == "object"))) as $merged
      | reduce $merged[] as $w (
          [];
          if any(.[]; .path == $w.path and .start == $w.start and .end == $w.end) then
            .
          else
            . + [$w]
          end
        )
      | .[:$limit]
    '
}

_capsule_window_count() {
  local windows_json="${1:-[]}"
  jq 'length' <<< "$windows_json" 2>/dev/null || echo 0
}

# Usage: select_window [coder|reviewer] [base_ref] [head_ref] [explicit_extra_windows]
# Output JSON:
# {
#   role, base_ref, head_ref,
#   tree_sitter_available, tree_sitter_used,
#   selection_algorithm,
#   windows:[...],
#   diff_u3? (reviewer only)
# }
select_window() {
  local role="${1:-coder}"
  local base_ref="${2:-${CAPSULE_BASE_REF:-HEAD~1}}"
  local head_ref="${3:-${CAPSULE_HEAD_REF:-HEAD}}"
  local explicit_extra_windows="${4:-0}"

  role="$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')"
  case "$role" in
    coder|reviewer)
      ;;
    *)
      die "select_window: role must be coder or reviewer"
      ;;
  esac

  if ! [[ "$explicit_extra_windows" =~ ^[0-9]+$ ]]; then
    explicit_extra_windows=0
  fi
  if [[ "$explicit_extra_windows" -gt 3 ]]; then
    explicit_extra_windows=3
  fi

  ensure_cmd jq
  ensure_cmd git

  local diff_json=""
  diff_json=$(_capsule_context_call_json \
    '{"changed_symbols":[],"impacted_symbols":[],"changed_files":[]}' \
    diff-impact "$base_ref" "$head_ref")

  local graph_json=""
  graph_json=$(_capsule_context_call_json \
    '{"ranked_symbols":[],"adjacency_path":""}' \
    graph-rank --top-k 16)

  local changed_files_json="[]"
  changed_files_json=$(_capsule_collect_changed_files_json "$diff_json")

  local tree_sitter_available_str="false"
  tree_sitter_available_str=$(_capsule_tree_sitter_available)
  local tree_sitter_available=false
  if [[ "$tree_sitter_available_str" == "true" ]]; then
    tree_sitter_available=true
  fi

  local primary_windows='[]'
  local selection_algorithm=""

  if [[ "$tree_sitter_available_str" == "true" ]]; then
    primary_windows=$(_capsule_windows_from_treesitter "$diff_json" "$graph_json")
    if [[ "$(_capsule_window_count "$primary_windows")" -gt 0 ]]; then
      selection_algorithm="tree_sitter_ast"
    fi
  fi

  if [[ -z "$selection_algorithm" ]]; then
    primary_windows=$(_capsule_windows_from_diff_hunks \
      "$base_ref" "$head_ref" 125 50 "primary" "diff_hunk_window" "diff_hunk" 250)
    if [[ "$(_capsule_window_count "$primary_windows")" -gt 0 ]]; then
      selection_algorithm="diff_hunk_u0"
    fi
  fi

  if [[ -z "$selection_algorithm" ]]; then
    primary_windows=$(_capsule_windows_from_regex_density "$changed_files_json")
    if [[ "$(_capsule_window_count "$primary_windows")" -gt 0 ]]; then
      selection_algorithm="regex_symbol_density"
    fi
  fi

  if [[ -z "$selection_algorithm" ]]; then
    primary_windows=$(_capsule_fallback_first_window "$changed_files_json")
    selection_algorithm="first_250_fallback"
    if [[ "$(_capsule_window_count "$primary_windows")" -gt 0 ]]; then
      log_warn "select_window: first-250 fallback activated"
    fi
  fi

  local final_windows='[]'
  local reviewer_diff_u3=""

  if [[ "$role" == "coder" ]]; then
    final_windows=$(jq 'if length > 0 then [.[0]] else [] end' <<< "$primary_windows")

    local dependency_windows='[]'
    dependency_windows=$(_capsule_dependency_window "$diff_json" "$graph_json" "$final_windows")
    final_windows=$(_capsule_append_windows_with_limit "$final_windows" "$dependency_windows" 3)

    if [[ "$explicit_extra_windows" -gt 0 ]]; then
      local current_count=0
      current_count=$(_capsule_window_count "$final_windows")
      local remaining=$((3 - current_count))
      if [[ "$remaining" -gt 0 ]]; then
        local request_count="$explicit_extra_windows"
        if [[ "$request_count" -gt "$remaining" ]]; then
          request_count="$remaining"
        fi

        local extra_windows='[]'
        extra_windows=$(_capsule_ranked_symbol_windows \
          "$graph_json" "$request_count" 125 250 "supplemental" "explicit_window_request" "graph_rank")
        final_windows=$(_capsule_append_windows_with_limit "$final_windows" "$extra_windows" 3)
      fi
    fi
  else
    local reviewer_hunk_windows='[]'
    reviewer_hunk_windows=$(_capsule_windows_from_diff_hunks \
      "$base_ref" "$head_ref" 100 50 "review_hunk" "reviewer_hunk_context" "diff_hunk" 201)

    local reviewer_ranked_windows='[]'
    reviewer_ranked_windows=$(_capsule_ranked_symbol_windows \
      "$graph_json" 5 100 201 "review_ranked" "reviewer_pagerank" "graph_rank")

    final_windows=$(_capsule_append_windows_with_limit \
      "$reviewer_hunk_windows" "$reviewer_ranked_windows" 128)

    if [[ "$(_capsule_window_count "$final_windows")" -eq 0 ]]; then
      final_windows=$(jq 'if length > 0 then [.[0]] else [] end' <<< "$primary_windows")
    fi

    reviewer_diff_u3=$(
      cd "$CONTEXT_CAPSULE_REPO_ROOT" && git diff -U3 --no-color "$base_ref" "$head_ref" 2>/dev/null || true
    )
  fi

  local tree_sitter_used=false
  if [[ "$selection_algorithm" == "tree_sitter_ast" ]]; then
    tree_sitter_used=true
  fi

  local numbered_windows='[]'
  numbered_windows=$(jq '
    to_entries
    | map(.value + {order: (.key + 1)})
  ' <<< "$final_windows")

  log_info "select_window: role=$role algorithm=$selection_algorithm windows=$(_capsule_window_count "$numbered_windows")"

  jq -nc \
    --arg role "$role" \
    --arg base_ref "$base_ref" \
    --arg head_ref "$head_ref" \
    --arg selection_algorithm "$selection_algorithm" \
    --argjson explicit_extra_windows "$explicit_extra_windows" \
    --argjson tree_sitter_available "$tree_sitter_available" \
    --argjson tree_sitter_used "$tree_sitter_used" \
    --argjson windows "$numbered_windows" \
    --arg diff_u3 "$reviewer_diff_u3" \
    '
      {
        role:$role,
        base_ref:$base_ref,
        head_ref:$head_ref,
        tree_sitter_available:$tree_sitter_available,
        tree_sitter_used:$tree_sitter_used,
        selection_algorithm:$selection_algorithm,
        explicit_extra_windows:$explicit_extra_windows,
        windows:$windows
      }
      + (
          if $role == "reviewer" then
            {diff_u3:$diff_u3}
          else
            {}
          end
        )
    '
}

# Usage: capsule_build <task_id> <phase> [--budget N]
capsule_build() {
  local task_id="${1:-}"
  local phase="${2:-}"
  shift 2 || true

  if [[ -z "$task_id" || -z "$phase" ]]; then
    die "capsule_build: <task_id> <phase> are required"
  fi

  _validate_identifier "$task_id" "task_id"
  _validate_identifier "$phase" "phase"

  local budget="$MAX_CAPSULE_TOKENS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --budget)
        shift
        if [[ $# -eq 0 ]]; then
          die "capsule_build: --budget requires value"
        fi
        budget="$1"
        ;;
      --budget=*)
        budget="${1#*=}"
        ;;
      *)
        die "capsule_build: unknown option: $1"
        ;;
    esac
    shift
  done

  if ! [[ "$budget" =~ ^[0-9]+$ ]]; then
    die "capsule_build: budget must be numeric"
  fi
  if [[ "$budget" -le 0 ]]; then
    die "capsule_build: budget must be > 0"
  fi
  if [[ "$budget" -gt "$MAX_CAPSULE_TOKENS" ]]; then
    log_warn "capsule_build: budget=$budget exceeds MAX_CAPSULE_TOKENS=$MAX_CAPSULE_TOKENS; clamped"
    budget="$MAX_CAPSULE_TOKENS"
  fi

  ensure_cmd jq
  ensure_cmd git
  ensure_dir "$CONTEXT_CAPSULE_TMP_DIR"

  if ! lock_acquire "$CONTEXT_CAPSULE_LOCK_DIR" "$CONTEXT_CAPSULE_LOCK_TIMEOUT"; then
    die "capsule_build: failed to acquire lock: $CONTEXT_CAPSULE_LOCK_DIR"
  fi
  trap 'lock_release "'"$CONTEXT_CAPSULE_LOCK_DIR"'" 2>/dev/null' EXIT HUP INT TERM

  local base_ref="${CAPSULE_BASE_REF:-HEAD~1}"
  local head_ref="${CAPSULE_HEAD_REF:-HEAD}"

  local diff_json=""
  diff_json=$(_capsule_context_call_json '{"changed_symbols":[],"impacted_symbols":[],"changed_files":[]}' diff-impact "$base_ref" "$head_ref")

  local graph_json=""
  graph_json=$(_capsule_context_call_json '{"ranked_symbols":[],"adjacency_path":""}' graph-rank --top-k 8)

  local registry_json=""
  registry_json=$(_capsule_registry_compat_json)

  local changed_files_json=""
  changed_files_json=$(_capsule_collect_changed_files_json "$diff_json")

  local changed_symbols_json=""
  changed_symbols_json=$(_capsule_collect_changed_symbols_json "$diff_json" "$graph_json")

  local preflight_input_json='{}'
  preflight_input_json=$(_capsule_build_preflight_input_json \
    "$task_id" \
    "$base_ref" \
    "$head_ref" \
    "$changed_files_json" \
    "$changed_symbols_json" \
    "$graph_json")

  local preflight_move_count=0
  preflight_move_count=$(jq '(.move_candidates // []) | length' <<< "$preflight_input_json" 2>/dev/null || echo "0")
  local preflight_removed_count=0
  preflight_removed_count=$(jq '(.removed_symbols // []) | length' <<< "$preflight_input_json" 2>/dev/null || echo "0")
  local preflight_idem_recalc_required="false"
  preflight_idem_recalc_required=$(jq -r 'if (._idem_recalc_required // false) then "true" else "false" end' <<< "$preflight_input_json" 2>/dev/null || echo "false")
  log_info "capsule_build: preflight_input move_candidates=$preflight_move_count removed_symbols=$preflight_removed_count idem_recalc_required=$preflight_idem_recalc_required"

  local pinned_symbols_json=""
  pinned_symbols_json=$(_capsule_collect_security_pins_json "$changed_files_json" "$registry_json")

  local merged_symbols_json=""
  merged_symbols_json=$(jq -n \
    --argjson changed "$changed_symbols_json" \
    --argjson pinned "$pinned_symbols_json" \
    '[($changed[]?), ($pinned[]?)] | map(select(type == "string" and length > 0)) | unique')

  local security_json=""
  security_json=$(_capsule_is_security_sensitive_json "$changed_files_json" "$merged_symbols_json" "$registry_json")
  local security_sensitive="false"
  security_sensitive=$(jq -r '.sensitive // false' <<< "$security_json")
  local security_reason="none"
  security_reason=$(jq -r '.reason // "none"' <<< "$security_json")

  local context_mode="diff"
  if [[ "$security_sensitive" == "true" ]]; then
    context_mode="full"
  fi

  local conflicts_value=""
  conflicts_value=$(_capsule_collect_conflicts_value)

  local delete_impacts_value=""
  delete_impacts_value=$(_capsule_delete_impacts_summary "$base_ref" "$head_ref" "$graph_json")

  local figma_summary_ref=""
  figma_summary_ref=$(_capsule_prepare_figma_summary_ref "$task_id" "$phase" "$changed_files_json" "$merged_symbols_json" "$registry_json")

  local changed_files_count=0
  changed_files_count=$(jq 'length' <<< "$changed_files_json")
  local changed_symbols_count=0
  changed_symbols_count=$(jq 'length' <<< "$merged_symbols_json")

  local changed_files_csv=""
  changed_files_csv=$(_capsule_join_csv "$changed_files_json" 10)
  [[ -z "$changed_files_csv" ]] && changed_files_csv="none"

  local changed_symbols_csv=""
  changed_symbols_csv=$(_capsule_join_csv "$merged_symbols_json" 12)
  [[ -z "$changed_symbols_csv" ]] && changed_symbols_csv="none"

  local pinned_symbols_csv=""
  pinned_symbols_csv=$(_capsule_join_csv "$pinned_symbols_json" 8)

  local memory_hints_value=""
  memory_hints_value=$(memory_get_top_patterns 3 2>/dev/null || true)
  [[ -z "$memory_hints_value" ]] && memory_hints_value="none"

  local policy="PASS"
  local stage="normal"
  local final_response=""
  local final_status=0
  local body_ref_hash=""

  # Stage 0: full capsule
  local full_capsule=""
  full_capsule=$(_capsule_compose_scc \
    "$task_id" \
    "$phase" \
    "$changed_files_csv" \
    "$changed_symbols_csv" \
    "$conflicts_value" \
    "$delete_impacts_value" \
    "$security_sensitive" \
    "$policy" \
    "$context_mode" \
    "$pinned_symbols_csv" \
    "$figma_summary_ref" \
    "" \
    "" \
    "$memory_hints_value")

  if final_response=$(_capsule_build_response_json "$full_capsule" "$budget" "$stage" "$context_mode" "$policy" ""); then
    final_status=0
  else
    # Stage 1: lightweight capsule
    stage="lightweight"

    local changed_files_hash=""
    changed_files_hash=$(_capsule_sha256 "$(jq -cS '.' <<< "$changed_files_json")")
    local changed_symbols_hash=""
    changed_symbols_hash=$(_capsule_sha256 "$(jq -cS '.' <<< "$merged_symbols_json")")

    local compact_changed_files="count:${changed_files_count};sha256:${changed_files_hash}"
    local compact_changed_symbols="count:${changed_symbols_count};sha256:${changed_symbols_hash}"
    local compact_conflicts="$conflicts_value"
    if [[ "$compact_conflicts" != "none" ]]; then
      compact_conflicts="summary:$(_capsule_sha256 "$compact_conflicts")"
    fi
    local compact_delete="$delete_impacts_value"
    compact_delete=$(_capsule_escape_value "$compact_delete" 80)

    local light_capsule=""
    light_capsule=$(_capsule_compose_scc \
      "$task_id" \
      "$phase" \
      "$compact_changed_files" \
      "$compact_changed_symbols" \
      "$compact_conflicts" \
      "$compact_delete" \
      "$security_sensitive" \
      "$policy" \
      "$context_mode" \
      "" \
      "$figma_summary_ref" \
      "" \
      "" \
      "$memory_hints_value")

    if final_response=$(_capsule_build_response_json "$light_capsule" "$budget" "$stage" "$context_mode" "$policy" ""); then
      final_status=0
    else
      # Stage 2: externalize capsule body, keep reference only.
      stage="externalized"

      local external_payload=""
      external_payload=$(jq -nc \
        --arg capsule "$full_capsule" \
        --arg task_id "$task_id" \
        --arg phase "$phase" \
        --arg context_mode "$context_mode" \
        --arg security_sensitive "$security_sensitive" \
        --arg security_reason "$security_reason" \
        --arg generated_at "$(get_timestamp)" \
        --argjson changed_files "$changed_files_json" \
        --argjson changed_symbols "$merged_symbols_json" \
        --argjson pinned_symbols "$pinned_symbols_json" \
        --argjson preflight_input "$preflight_input_json" \
        --arg delete_impacts "$delete_impacts_value" \
        --arg conflicts "$conflicts_value" \
        '{
          generated_at:$generated_at,
          task_id:$task_id,
          phase:$phase,
          context_mode:$context_mode,
          security_sensitive:$security_sensitive,
          security_reason:$security_reason,
          changed_files:$changed_files,
          changed_symbols:$changed_symbols,
          pinned_symbols:$pinned_symbols,
          preflight_input:$preflight_input,
          conflicts:$conflicts,
          delete_impacts:$delete_impacts,
          capsule:$capsule
        }')

      body_ref_hash=$(_capsule_sha256 "$external_payload")
      local external_file="$CONTEXT_CAPSULE_TMP_DIR/${body_ref_hash}.txt"
      if [[ ! -f "$external_file" ]]; then
        printf '%s\n' "$external_payload" > "$external_file"
      fi

      local ext_capsule=""
      ext_capsule=$(_capsule_compose_scc \
        "$task_id" \
        "$phase" \
        "ref:sha256:${changed_files_hash}" \
        "ref:sha256:${changed_symbols_hash}" \
        "$compact_conflicts" \
        "external_ref" \
        "$security_sensitive" \
        "$policy" \
        "$context_mode" \
        "" \
        "$figma_summary_ref" \
        "$body_ref_hash" \
        "" \
        "$memory_hints_value")

      if final_response=$(_capsule_build_response_json "$ext_capsule" "$budget" "$stage" "$context_mode" "$policy" "$body_ref_hash"); then
        final_status=0
      else
        # Stage 3: fail-closed BLOCK
        stage="block"
        policy="BLOCK"
        final_status=1

        local block_capsule=""
        block_capsule=$(_capsule_compose_scc \
          "$task_id" \
          "$phase" \
          "blocked" \
          "blocked" \
          "none" \
          "blocked" \
          "$security_sensitive" \
          "$policy" \
          "$context_mode" \
          "" \
          "" \
          "$body_ref_hash" \
          "capsule_budget_exceeded" \
          "$memory_hints_value")

        if final_response=$(_capsule_build_response_json "$block_capsule" "$budget" "$stage" "$context_mode" "$policy" "$body_ref_hash"); then
          :
        else
          # Last-resort minimal block response (still fail-closed)
          local minimal_capsule=""
          minimal_capsule=$(_capsule_compose_scc \
            "$task_id" \
            "$phase" \
            "blocked" \
            "blocked" \
            "none" \
            "blocked" \
            "$security_sensitive" \
            "BLOCK" \
            "$context_mode" \
            "" \
            "" \
            "" \
            "capsule_budget_exceeded" \
            "$memory_hints_value")

          final_response=$(jq -nc --arg capsule "$minimal_capsule" '{capsule:$capsule,constraints:[],hints:[]}')
        fi
      fi
    fi
  fi

  echo "$final_response"

  trap - EXIT HUP INT TERM
  lock_release "$CONTEXT_CAPSULE_LOCK_DIR"

  if [[ "$final_status" -ne 0 ]]; then
    log_error "capsule_build: fail-closed (BLOCK) task_id=$task_id phase=$phase budget=$budget"
  else
    log_info "capsule_build: stage=$stage task_id=$task_id phase=$phase budget=$budget"
  fi

  return "$final_status"
}

context_capsule_usage() {
  cat <<'USAGE'
Usage:
  context_capsule.sh build <task_id> <phase> [--budget N]
  context_capsule.sh get-snippet <path> <start> <end>
  context_capsule.sh get_snippet <path> <start> <end>
  context_capsule.sh budget-check <token_count>
  context_capsule.sh budget_check <token_count>
  context_capsule.sh memory-record-review <reviews_file>
  context_capsule.sh memory-record-fix <file_path> [issue_ids]
  context_capsule.sh memory-top-patterns [top_n]
USAGE
}

context_capsule_main() {
  local subcommand="${1:-}"

  case "$subcommand" in
    build)
      shift
      if [[ $# -lt 2 ]]; then
        die "build requires <task_id> <phase>"
      fi
      capsule_build "$@"
      ;;
    get-snippet|get_snippet)
      shift
      capsule_get_snippet "$@"
      ;;
    budget-check|budget_check)
      shift
      capsule_budget_check "$@"
      ;;
    memory-record-review|memory_record_review)
      shift
      if [[ $# -lt 1 ]]; then
        die "memory-record-review requires <reviews_file>"
      fi
      memory_record_review_pattern "$@"
      ;;
    memory-record-fix|memory_record_file_fix)
      shift
      if [[ $# -lt 1 ]]; then
        die "memory-record-fix requires <file_path> [issue_ids]"
      fi
      memory_record_file_fix "$@"
      ;;
    memory-top-patterns|memory_get_top_patterns)
      shift
      memory_get_top_patterns "${1:-3}"
      ;;
    -h|--help|help)
      context_capsule_usage
      ;;
    "")
      context_capsule_usage
      exit 1
      ;;
    *)
      die "Unknown subcommand: $subcommand"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  context_capsule_main "$@"
fi
