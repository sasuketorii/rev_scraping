#!/usr/bin/env bash
# task_contract.sh - common task contract builder / validator

set -euo pipefail

readonly TASK_CONTRACT_VERSION="1.0.0"
readonly TASK_CONTRACT_OWNER_ROLE="orchestrator"
readonly TASK_CONTRACT_TASK_SEGMENT_PATTERN='^[a-zA-Z0-9._-]+$'

_task_contract_log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

_task_contract_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    printf '[INFO] %s\n' "$*" >&2
  fi
}

_task_contract_require_cmd() {
  local cmd="$1"

  if declare -F ensure_cmd >/dev/null 2>&1; then
    ensure_cmd "$cmd"
  elif ! command -v "$cmd" >/dev/null 2>&1; then
    _task_contract_log_error "Required command not found: $cmd"
    return 1
  fi
}

_task_contract_ensure_dir() {
  local dir="$1"

  if declare -F ensure_dir >/dev/null 2>&1; then
    ensure_dir "$dir"
  else
    mkdir -p "$dir"
  fi
}

_task_contract_slugify() {
  local value="${1:-}"
  local slug=""

  slug=$(printf '%s' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')

  if [[ -z "$slug" ]]; then
    slug="unspecified"
  fi

  printf '%s\n' "$slug"
}

_task_contract_normalize_plan_path() {
  local plan_path="${1:-}"
  local abs_dir=""
  local abs_path=""
  local repo_root=""

  [[ -n "$plan_path" ]] || return 1

  abs_dir="$(cd "$(dirname "$plan_path")" && pwd -P)" || return 1
  abs_path="${abs_dir}/$(basename "$plan_path")"
  repo_root="$(git -C "$abs_dir" rev-parse --show-toplevel 2>/dev/null || true)"

  if [[ -n "$repo_root" ]]; then
    repo_root="$(cd "$repo_root" && pwd -P)" || return 1
    case "$abs_path" in
      "$repo_root"/*)
        printf '%s\n' "${abs_path#"$repo_root"/}"
        return 0
        ;;
    esac
  fi

  printf '%s\n' "$abs_path"
}

_task_contract_strip_wrapping_backticks() {
  local value="${1:-}"

  value=$(_task_contract_trim "$value")
  if [[ "$value" == \`* ]] && [[ "$value" == *\` ]]; then
    value="${value#\`}"
    value="${value%\`}"
  fi

  printf '%s\n' "$(_task_contract_trim "$value")"
}

_task_contract_metadata_value() {
  local doc_path="$1"
  local key="$2"
  local raw_value=""

  raw_value="$(sed -n "s/^${key}:[[:space:]]*//p" "$doc_path" | head -n 1)" || return 1
  [[ -n "$raw_value" ]] || return 1

  _task_contract_strip_wrapping_backticks "$raw_value"
}

_task_contract_is_slice_addendum() {
  local plan_path="$1"
  grep -Eq '^# Slice Addendum:' "$plan_path"
}

_task_contract_resolve_repo_relative_doc_path() {
  local reference_path="$1"
  local doc_path="${2:-}"
  local repo_root=""
  local abs_path=""

  [[ -n "$reference_path" ]] || return 1
  [[ -n "$doc_path" ]] || return 1

  doc_path="$(_task_contract_strip_wrapping_backticks "$doc_path")"
  [[ -n "$doc_path" ]] || return 1

  if [[ "$doc_path" == /* ]]; then
    abs_path="$doc_path"
  else
    repo_root="$(_task_contract_repo_root_for_path "$reference_path" 2>/dev/null || true)"
    [[ -n "$repo_root" ]] || return 1
    abs_path="${repo_root}/${doc_path}"
  fi

  [[ -r "$abs_path" ]] || return 1
  _task_contract_normalize_plan_path "$abs_path"
}

_task_contract_section_lines_by_heading_pattern() {
  local plan_path="$1"
  local heading_pattern="$2"

  awk -v heading_pattern="$heading_pattern" '
    BEGIN {
      capture = 0
    }
    $0 ~ heading_pattern {
      capture = 1
      next
    }
    capture && /^## / {
      exit
    }
    capture {
      print $0
    }
  ' "$plan_path"
}

_task_contract_markdown_section_items() {
  local plan_path="$1"
  local section_title="$2"

  awk -v heading="## ${section_title}" '
    BEGIN {
      capture = 0
    }
    $0 == heading {
      capture = 1
      next
    }
    capture && /^## / {
      exit
    }
    capture {
      if ($0 ~ /^[[:space:]]*$/) {
        next
      }
      if ($0 ~ /^[[:space:]]*### /) {
        next
      }
      if ($0 ~ /^[[:space:]]*[-*][[:space:]]+/) {
        sub(/^[[:space:]]*[-*][[:space:]]+/, "", $0)
        print $0
        next
      }
      if ($0 ~ /^[[:space:]]*[0-9]+\.[[:space:]]+/) {
        sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", $0)
        print $0
      }
    }
  ' "$plan_path"
}

_task_contract_section_lines() {
  local plan_path="$1"
  local section_title="$2"

  awk -v heading="## ${section_title}" '
    BEGIN {
      capture = 0
    }
    $0 == heading {
      capture = 1
      next
    }
    capture && /^## / {
      exit
    }
    capture {
      print $0
    }
  ' "$plan_path"
}

_task_contract_addendum_slice_record_list() {
  local plan_path="$1"
  local label="$2"

  awk -v label="$label" '
    BEGIN {
      in_section = 0
      current_label = ""
    }
    $0 == "## Slice Record" {
      in_section = 1
      next
    }
    in_section && /^## / {
      exit
    }
    !in_section {
      next
    }
    $0 ~ /^- / {
      current_label = $0
      sub(/^- /, "", current_label)
      sub(/:$/, "", current_label)
      next
    }
    current_label == label && $0 ~ /^  - / {
      sub(/^  - /, "", $0)
      print $0
    }
  ' "$plan_path"
}

_task_contract_addendum_change_surface_list() {
  local plan_path="$1"
  local nested_label="$2"

  awk -v nested_label="$nested_label" '
    BEGIN {
      in_section = 0
      in_change_surface = 0
      current_nested = ""
    }
    $0 == "## Slice Record" {
      in_section = 1
      next
    }
    in_section && /^## / {
      exit
    }
    !in_section {
      next
    }
    $0 == "- change surface:" {
      in_change_surface = 1
      current_nested = ""
      next
    }
    in_change_surface && $0 ~ /^- / && $0 != "- change surface:" {
      in_change_surface = 0
      current_nested = ""
    }
    !in_change_surface {
      next
    }
    $0 ~ /^  - / {
      current_nested = $0
      sub(/^  - /, "", current_nested)
      sub(/:$/, "", current_nested)
      next
    }
    current_nested == nested_label && $0 ~ /^    - / {
      sub(/^    - /, "", $0)
      print $0
    }
  ' "$plan_path"
}

_task_contract_required_checks_section_lines() {
  local plan_path="$1"

  if _task_contract_is_slice_addendum "$plan_path"; then
    _task_contract_section_lines_by_heading_pattern "$plan_path" '^## Required Deterministic Checks'
  else
    _task_contract_section_lines "$plan_path" "Required Deterministic Checks"
  fi
}

_task_contract_has_section_heading() {
  local plan_path="$1"
  local section_title="$2"

  grep -Fxq "## ${section_title}" "$plan_path"
}

_task_contract_trim() {
  local value="${1:-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

_task_contract_required_checks_pre_list_line_is_markdown_structure() {
  local raw_line="${1:-}"
  local line=""
  local heading_pattern='^#{1,6}[[:space:]]+'
  local fence_pattern='^(```|~~~)'

  line=$(_task_contract_trim "$raw_line")
  [[ -n "$line" ]] || return 1

  [[ "$line" =~ $heading_pattern ]] && return 0
  [[ "$line" =~ $fence_pattern ]] && return 0
  return 1
}

_task_contract_has_control_characters() {
  local value="${1:-}"

  [[ "$value" =~ [[:cntrl:]] ]]
}

_task_contract_is_canonical_task_segment() {
  local task_segment="${1:-}"

  [[ -n "$task_segment" ]] || return 1
  [[ "$task_segment" =~ $TASK_CONTRACT_TASK_SEGMENT_PATTERN ]] || return 1

  case "$task_segment" in
    .|..) return 1 ;;
  esac

  return 0
}

_task_contract_has_unquoted_shell_metacharacters() {
  local line="${1:-}"
  local idx=0
  local length=${#line}
  local ch=""
  local in_single=0
  local in_double=0
  local escaped=0

  while [[ "$idx" -lt "$length" ]]; do
    ch="${line:$idx:1}"

    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
      idx=$((idx + 1))
      continue
    fi

    if [[ "$in_single" -eq 1 ]]; then
      [[ "$ch" == "'" ]] && in_single=0
      idx=$((idx + 1))
      continue
    fi

    if [[ "$in_double" -eq 1 ]]; then
      case "$ch" in
        '\\') escaped=1 ;;
        '"') in_double=0 ;;
      esac
      idx=$((idx + 1))
      continue
    fi

    case "$ch" in
      '\\') escaped=1 ;;
      "'") in_single=1 ;;
      '"') in_double=1 ;;
      ';'|'|'|'&'|'<'|'>') return 0 ;;
      '$')
        if [[ $((idx + 1)) -lt "$length" ]] && [[ "${line:$((idx + 1)):1}" == "(" ]]; then
          return 0
        fi
        ;;
    esac

    idx=$((idx + 1))
  done

  return 1
}

_task_contract_has_unquoted_shell_comment() {
  local line="${1:-}"
  local idx=0
  local length=${#line}
  local ch=""
  local in_single=0
  local in_double=0
  local escaped=0
  local at_word_start=1

  while [[ "$idx" -lt "$length" ]]; do
    ch="${line:$idx:1}"

    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
      at_word_start=0
      idx=$((idx + 1))
      continue
    fi

    if [[ "$in_single" -eq 1 ]]; then
      [[ "$ch" == "'" ]] && in_single=0
      idx=$((idx + 1))
      continue
    fi

    if [[ "$in_double" -eq 1 ]]; then
      case "$ch" in
        '\\') escaped=1 ;;
        '"') in_double=0 ;;
      esac
      idx=$((idx + 1))
      continue
    fi

    case "$ch" in
      [[:space:]]) at_word_start=1 ;;
      '\\')
        escaped=1
        at_word_start=0
        ;;
      "'")
        in_single=1
        at_word_start=0
        ;;
      '"')
        in_double=1
        at_word_start=0
        ;;
      '#')
        [[ "$at_word_start" -eq 1 ]] && return 0
        at_word_start=0
        ;;
      *)
        at_word_start=0
        ;;
    esac

    idx=$((idx + 1))
  done

  return 1
}

_task_contract_has_variable_expansion() {
  local line="${1:-}"
  local idx=0
  local length=${#line}
  local ch=""
  local next=""
  local escaped=0

  while [[ "$idx" -lt "$length" ]]; do
    ch="${line:$idx:1}"

    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
      idx=$((idx + 1))
      continue
    fi

    if [[ "$ch" == '\' ]]; then
      escaped=1
      idx=$((idx + 1))
      continue
    fi

    if [[ "$ch" == '$' ]] && [[ $((idx + 1)) -lt "$length" ]]; then
      next="${line:$((idx + 1)):1}"
      case "$next" in
        '{'|'('|[A-Za-z_]|[0-9]|'@'|'*'|'#'|'?'|'-'|'$'|'!')
          return 0
          ;;
      esac
    fi

    idx=$((idx + 1))
  done

  return 1
}

_task_contract_normalize_exact_existence_probe_loop() {
  local raw_line="${1:-}"
  local line=""
  local loop_var=""
  local probe_var=""
  local path_words=""
  local -a path_tokens=()
  local path_token=""
  local remaining_path_words=""

  line=$(_task_contract_trim "$raw_line")
  [[ -n "$line" ]] || return 1
  _task_contract_has_control_characters "$line" && return 1

  if [[ "$line" =~ ^for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]]+(.+)\;[[:space:]]+do[[:space:]]+test[[:space:]]+-e[[:space:]]+\"\$([A-Za-z_][A-Za-z0-9_]*)\"[[:space:]]*\;[[:space:]]+done$ ]]; then
    loop_var="${BASH_REMATCH[1]}"
    path_words="${BASH_REMATCH[2]}"
    probe_var="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  [[ -n "$path_words" && -n "$loop_var" && "$loop_var" == "$probe_var" ]] || return 1
  remaining_path_words="$path_words"
  while [[ "$remaining_path_words" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
    path_tokens+=("${BASH_REMATCH[1]}")
    remaining_path_words="${BASH_REMATCH[2]}"
  done
  [[ "${#path_tokens[@]}" -gt 0 ]] || return 1

  for path_token in "${path_tokens[@]}"; do
    [[ -n "$path_token" ]] || return 1
    [[ "$path_token" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    case "$path_token" in
      .|..) return 1 ;;
    esac
  done

  printf '%s\n' "$line"
}

_TASK_CONTRACT_PREFIX_HAS_ASSIGNMENTS=0
_TASK_CONTRACT_PREFIX_USES_ENV=0

_task_contract_detect_prefix_injection() {
  local line="${1:-}"
  local remaining=""
  local token=""
  local assignment_re='^[A-Za-z_][A-Za-z0-9_]*=.*$'

  _TASK_CONTRACT_PREFIX_HAS_ASSIGNMENTS=0
  _TASK_CONTRACT_PREFIX_USES_ENV=0
  remaining="$line"

  while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
    token="${BASH_REMATCH[1]}"
    remaining="${BASH_REMATCH[2]}"

    case "$token" in
      command|builtin)
        continue
        ;;
      env)
        _TASK_CONTRACT_PREFIX_USES_ENV=1
        while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
          token="${BASH_REMATCH[1]}"
          remaining="${BASH_REMATCH[2]}"

          if [[ "$token" == "--" ]]; then
            continue
          fi

          if [[ "$token" =~ $assignment_re ]]; then
            _TASK_CONTRACT_PREFIX_HAS_ASSIGNMENTS=1
            continue
          fi

          if [[ "$token" == -* ]]; then
            continue
          fi

          return 0
        done
        return 0
        ;;
    esac

    if [[ "$token" =~ $assignment_re ]]; then
      _TASK_CONTRACT_PREFIX_HAS_ASSIGNMENTS=1
      continue
    fi

    return 0
  done

  return 1
}

_TASK_CONTRACT_RESOLVED_CMD_NAME=""
_TASK_CONTRACT_RESOLVED_CMD_TOKEN=""
_TASK_CONTRACT_RESOLVED_CMD_MODE=""
_TASK_CONTRACT_RESOLVED_CMD_ARGS=""

_task_contract_resolve_command_target() {
  local line="${1:-}"
  local remaining=""
  local token=""
  local cmd_name=""
  local cmd_token=""
  local resolution_mode="direct"
  local assignment_re='^[A-Za-z_][A-Za-z0-9_]*=.*$'

  _TASK_CONTRACT_RESOLVED_CMD_NAME=""
  _TASK_CONTRACT_RESOLVED_CMD_TOKEN=""
  _TASK_CONTRACT_RESOLVED_CMD_MODE=""
  _TASK_CONTRACT_RESOLVED_CMD_ARGS=""
  remaining="$line"

  while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
    token="${BASH_REMATCH[1]}"
    remaining="${BASH_REMATCH[2]}"

    if [[ "$token" =~ $assignment_re ]]; then
      continue
    fi

    cmd_token="$token"
    cmd_name="${token##*/}"

    case "$cmd_name" in
      env)
        resolution_mode="env"
        while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
          token="${BASH_REMATCH[1]}"
          remaining="${BASH_REMATCH[2]}"

          if [[ "$token" == "--" ]]; then
            continue
          fi

          if [[ "$token" =~ $assignment_re ]] || [[ "$token" == -* ]]; then
            continue
          fi

          cmd_token="$token"
          cmd_name="${token##*/}"
          break
        done
        ;;
      command|builtin)
        resolution_mode="$cmd_name"
        while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
          token="${BASH_REMATCH[1]}"
          remaining="${BASH_REMATCH[2]}"

          if [[ "$token" == "--" ]]; then
            continue
          fi

          if [[ "$token" == -* ]]; then
            continue
          fi

          cmd_token="$token"
          cmd_name="${token##*/}"
          break
        done
        ;;
    esac

    case "$cmd_name" in
      env|command|builtin)
        continue
        ;;
    esac

    _TASK_CONTRACT_RESOLVED_CMD_NAME="$cmd_name"
    _TASK_CONTRACT_RESOLVED_CMD_TOKEN="$cmd_token"
    _TASK_CONTRACT_RESOLVED_CMD_MODE="$resolution_mode"
    _TASK_CONTRACT_RESOLVED_CMD_ARGS="$remaining"
    return 0
  done

  return 1
}

_task_contract_is_explicit_path_command() {
  local cmd_token="${1:-}"

  [[ "$cmd_token" == /* || "$cmd_token" == ./* || "$cmd_token" == ../* ]]
}

_task_contract_requires_external_executable() {
  local cmd_name="${1:-}"
  local cmd_token="${2:-}"
  local cmd_mode="${3:-direct}"
  local cmd_type=""

  [[ -n "$cmd_name" ]] || return 1

  if _task_contract_is_explicit_path_command "$cmd_token"; then
    return 0
  fi

  case "$cmd_mode" in
    env)
      type -P -- "$cmd_name" >/dev/null 2>&1
      return $?
      ;;
    direct|command|builtin)
      cmd_type="$(type -t -- "$cmd_name" 2>/dev/null || true)"
      [[ "$cmd_type" == "file" ]]
      return $?
      ;;
  esac

  return 1
}

_task_contract_validate_artifact_destination() {
  local artifact_destination="${1:-}"
  local task_segment=""

  [[ -n "$artifact_destination" ]] || return 1
  _task_contract_has_control_characters "$artifact_destination" && return 1
  [[ "$artifact_destination" =~ ^\.claude/tmp/([^/]+)/task-contract\.json$ ]] || return 1

  task_segment="${BASH_REMATCH[1]}"
  _task_contract_is_canonical_task_segment "$task_segment"
}

_task_contract_normalize_command_item() {
  local raw_line="${1:-}"
  local line=""
  local cmd_name=""
  local cmd_token=""
  local normalized_loop=""

  line=$(_task_contract_trim "$raw_line")
  [[ -n "$line" ]] || return 1

  if [[ "$line" == \`* ]] && [[ "$line" == *\` ]]; then
    line="${line#\`}"
    line="${line%\`}"
    line=$(_task_contract_trim "$line")
  fi

  [[ -n "$line" ]] || return 1
  if normalized_loop="$(_task_contract_normalize_exact_existence_probe_loop "$line" 2>/dev/null)"; then
    printf '%s\n' "$normalized_loop"
    return 0
  fi
  _task_contract_has_control_characters "$line" && return 1
  [[ "$line" != *\`* ]] || return 1
  _task_contract_has_unquoted_shell_comment "$line" && return 1
  _task_contract_has_variable_expansion "$line" && return 1
  _task_contract_has_unquoted_shell_metacharacters "$line" && return 1
  _task_contract_detect_prefix_injection "$line" || return 1
  [[ "$_TASK_CONTRACT_PREFIX_USES_ENV" -eq 0 ]] || return 1
  [[ "$_TASK_CONTRACT_PREFIX_HAS_ASSIGNMENTS" -eq 0 ]] || return 1
  bash -n -c "$line" >/dev/null 2>&1 || return 1

  _task_contract_resolve_command_target "$line" || return 1
  cmd_name="$_TASK_CONTRACT_RESOLVED_CMD_NAME"
  cmd_token="$_TASK_CONTRACT_RESOLVED_CMD_TOKEN"

  if [[ "$cmd_name" == "bash" || "$cmd_name" == "sh" ]]; then
    while [[ "$_TASK_CONTRACT_RESOLVED_CMD_ARGS" =~ ^[[:space:]]*([^[:space:]]+)(.*)$ ]]; do
      local token="${BASH_REMATCH[1]}"
      _TASK_CONTRACT_RESOLVED_CMD_ARGS="${BASH_REMATCH[2]}"

      case "$token" in
        --) break ;;
        -*)
          [[ "$token" == *c* ]] && return 1
          ;;
        *)
          break
          ;;
      esac
    done
  fi

  if _task_contract_requires_external_executable \
    "$cmd_name" \
    "$cmd_token" \
    "$_TASK_CONTRACT_RESOLVED_CMD_MODE"; then
    printf '%s\n' "$line"
    return 0
  fi

  return 1
}

_task_contract_required_checks_from_plan() {
  local plan_path="$1"
  local raw_line=""
  local line=""
  local candidate=""
  local normalized=""
  local saw_item=0

  while IFS= read -r raw_line; do
    line=$(_task_contract_trim "$raw_line")
    if [[ -z "$line" ]]; then
      continue
    fi

    if [[ "$raw_line" =~ ^[[:space:]]*[-*][[:space:]]+(.*)$ ]]; then
      candidate="${BASH_REMATCH[1]}"
    elif [[ "$raw_line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+(.*)$ ]]; then
      candidate="${BASH_REMATCH[1]}"
    elif [[ "$saw_item" -eq 0 ]]; then
      if _task_contract_required_checks_pre_list_line_is_markdown_structure "$raw_line"; then
        _task_contract_log_error "required_checks section contains markdown structure before list start: Required Deterministic Checks"
        return 1
      fi
      continue
    else
      _task_contract_log_error "required_checks section contains non-list content after list start: Required Deterministic Checks"
      return 1
    fi

    candidate=$(_task_contract_trim "$candidate")
    if [[ -z "$candidate" ]]; then
      _task_contract_log_error "required_checks section contains an empty list item: Required Deterministic Checks"
      return 1
    fi

    saw_item=1
    if normalized=$(_task_contract_normalize_command_item "$candidate"); then
      printf '%s\n' "$normalized"
    else
      _task_contract_log_error "required_checks entry must be an exact command: $candidate"
      return 1
    fi
  done < <(_task_contract_required_checks_section_lines "$plan_path")

  if [[ "$saw_item" -eq 1 ]]; then
    return 0
  fi

  if grep -Eq '^## Required Deterministic Checks' "$plan_path"; then
    _task_contract_log_error "required_checks section is empty: Required Deterministic Checks"
  else
    _task_contract_log_error "required_checks section is missing: Required Deterministic Checks"
  fi

  return 2
}

_task_contract_required_list_items_from_plan() {
  local plan_path="$1"
  local section_title="$2"
  local raw_line=""
  local line=""
  local candidate=""
  local saw_item=0

  while IFS= read -r raw_line; do
    line=$(_task_contract_trim "$raw_line")
    if [[ -z "$line" ]] || [[ "$line" == '### '* ]]; then
      continue
    fi

    if [[ "$raw_line" =~ ^[[:space:]]*[-*][[:space:]]+(.*)$ ]]; then
      candidate="${BASH_REMATCH[1]}"
    elif [[ "$raw_line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+(.*)$ ]]; then
      candidate="${BASH_REMATCH[1]}"
    else
      continue
    fi

    candidate=$(_task_contract_trim "$candidate")
    if [[ -z "$candidate" ]]; then
      _task_contract_log_error "required section contains an empty list item: $section_title"
      return 1
    fi

    saw_item=1
    printf '%s\n' "$candidate"
  done < <(_task_contract_section_lines "$plan_path" "$section_title")

  if [[ "$saw_item" -eq 1 ]]; then
    return 0
  fi

  if _task_contract_has_section_heading "$plan_path" "$section_title"; then
    _task_contract_log_error "required section is empty: $section_title"
  else
    _task_contract_log_error "required section is missing: $section_title"
  fi

  return 2
}

_task_contract_required_list_items_from_addendum() {
  local plan_path="$1"
  local section_title="$2"
  local items=""

  case "$section_title" in
    "In-Scope")
      items="$(_task_contract_addendum_slice_record_list "$plan_path" "in-scope")" || return 1
      ;;
    "Out-Of-Scope")
      items="$(_task_contract_addendum_slice_record_list "$plan_path" "out-of-scope")" || return 1
      ;;
    "Completion Boundary")
      items="$(_task_contract_required_list_items_from_plan "$plan_path" "$section_title")" || return $?
      printf '%s\n' "$items"
      return 0
      ;;
    *)
      _task_contract_log_error "unsupported addendum section request: $section_title"
      return 1
      ;;
  esac

  if [[ -n "$items" ]]; then
    printf '%s\n' "$items"
    return 0
  fi

  _task_contract_log_error "required section is missing: $section_title"
  return 2
}

_task_contract_lines_to_json_array() {
  jq -Rn '[inputs | select(length > 0)]'
}

_task_contract_owner_role_from_plan() {
  local plan_path="$1"
  printf '%s\n' "$TASK_CONTRACT_OWNER_ROLE"
}

_task_contract_slice_id_from_plan() {
  local plan_path="$1"
  local phase="$2"
  local raw_slice=""
  local slice_field=""

  if _task_contract_is_slice_addendum "$plan_path"; then
    slice_field="$(_task_contract_metadata_value "$plan_path" "Slice" 2>/dev/null || true)"
    if [[ "$slice_field" =~ ^([A-Za-z0-9._-]+)[[:space:]]*[-:]?.*$ ]]; then
      printf 'slice-%s\n' "$(_task_contract_slugify "${BASH_REMATCH[1]}")"
      return 0
    fi
  fi

  raw_slice=$(sed -n 's/^### Slice[[:space:]]\([^:][^:]*\):.*$/\1/p' "$plan_path" | head -n 1)
  if [[ -z "$raw_slice" ]]; then
    printf 'phase-%s\n' "$(_task_contract_slugify "$phase")"
    return 0
  fi

  printf 'slice-%s\n' "$(_task_contract_slugify "$raw_slice")"
}

_task_contract_default_in_scope() {
  local phase="$1"
  printf 'orchestrated coder run for phase %s\n' "$phase"
}

_task_contract_default_required_checks() {
  printf '%s\n' \
    'git diff --check' \
    'bash -n .claude/commands/auto_orchestrate.sh' \
    'bash -n .claude/commands/lib/task_contract.sh'
}

_task_contract_default_completion_boundary() {
  printf '%s\n' 'emit a validated task contract before coder launch'
}

_task_contract_default_allowed_capabilities() {
  printf '%s\n' \
    'repo_local_read' \
    'repo_local_write' \
    'state_write' \
    'shell_command' \
    'deterministic_checks'
}

_task_contract_resolve_array_json() {
  local parsed_lines="$1"
  local fallback_lines="${2:-}"
  local array_json="[]"

  if [[ -n "$parsed_lines" ]]; then
    array_json=$(printf '%s\n' "$parsed_lines" | _task_contract_lines_to_json_array)
  elif [[ -n "$fallback_lines" ]]; then
    array_json=$(printf '%s\n' "$fallback_lines" | _task_contract_lines_to_json_array)
  fi

  printf '%s\n' "$array_json"
}

_task_contract_repo_root_for_path() {
  local reference_path="${1:-}"
  local abs_dir=""
  local repo_root=""

  [[ -n "$reference_path" ]] || return 1

  abs_dir="$(cd "$(dirname "$reference_path")" && pwd -P)" || return 1
  repo_root="$(git -C "$abs_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 1

  cd "$repo_root" && pwd -P
}

_task_contract_repo_root_for_cwd() {
  local repo_root=""

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 1

  cd "$repo_root" && pwd -P
}

_task_contract_unique_lines() {
  awk 'length > 0 && !seen[$0]++ { print $0 }'
}

_task_contract_jq_filter_string() {
  local input="${1:-}"
  shift
  local input_file=""
  local status=0

  input_file=$(mktemp "${TMPDIR:-/tmp}/task_contract_jq_input.XXXXXX") || return 1
  trap '/bin/rm -f -- "$input_file"' RETURN
  printf '%s' "$input" > "$input_file" || {
    /bin/rm -f -- "$input_file"
    trap - RETURN
    return 1
  }

  jq "$@" "$input_file" || status=$?
  /bin/rm -f -- "$input_file"
  trap - RETURN
  return "$status"
}

_task_contract_sha256_value() {
  local value="${1:-}"
  local digest=""

  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | openssl dgst -sha256 -r | awk '{print $1}')
  else
    _task_contract_log_error "no SHA-256 tool available"
    return 1
  fi

  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}

_task_contract_sha256_file() {
  local file_path="${1:-}"
  local digest=""

  [[ -r "$file_path" ]] || return 1

  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file_path" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file_path" | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 -r "$file_path" | awk '{print $1}')
  else
    _task_contract_log_error "no SHA-256 tool available"
    return 1
  fi

  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}

_task_contract_active_sow_path_from_plan() {
  local normalized_plan_path="${1:-}"
  local plan_basename=""

  [[ -n "$normalized_plan_path" ]] || return 1
  plan_basename="$(basename "$normalized_plan_path")"

  if [[ "$plan_basename" =~ ^plan_([0-9]{8})_[0-9]{4}_(.+)\.md$ ]]; then
    printf '.agent/active/sow/%s_%s.md\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

_task_contract_current_plan_path() {
  local plan_path="$1"
  local normalized_plan_path="$2"
  local current_plan_path=""

  if _task_contract_is_slice_addendum "$plan_path"; then
    current_plan_path="$(_task_contract_metadata_value "$plan_path" "Plan")" || return 1
    _task_contract_resolve_repo_relative_doc_path "$plan_path" "$current_plan_path"
    return 0
  fi

  printf '%s\n' "$normalized_plan_path"
}

_task_contract_current_sow_path() {
  local plan_path="$1"
  local normalized_plan_path="$2"
  local sow_path=""

  if _task_contract_is_slice_addendum "$plan_path"; then
    sow_path="$(_task_contract_metadata_value "$plan_path" "Parent SOW")" || return 1
    _task_contract_resolve_repo_relative_doc_path "$plan_path" "$sow_path"
    return 0
  fi

  _task_contract_active_sow_path_from_plan "$normalized_plan_path"
}

_task_contract_optional_handover_path_from_sow() {
  local sow_path="${1:-}"
  local sow_basename=""

  [[ -n "$sow_path" ]] || return 1
  sow_basename="$(basename "$sow_path")"

  if [[ "$sow_basename" =~ ^([0-9]{8}_.+)\.md$ ]]; then
    printf '.agent/active/prompts/handover_%s.md\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

_task_contract_is_slice_b_support_context_addendum() {
  local plan_path="${1:-}"
  local slice_field=""

  _task_contract_is_slice_addendum "$plan_path" || return 1
  slice_field="$(_task_contract_metadata_value "$plan_path" "Slice" 2>/dev/null || true)"
  [[ "$slice_field" =~ ^B([[:space:]]*[-:].*)?$ ]]
}

_task_contract_current_slice_closeout_evidence_paths() {
  local sow_path="${1:-}"
  local heading_pattern="${2:-}"

  [[ -n "$sow_path" && -n "$heading_pattern" ]] || return 1

  awk -v heading_pattern="$heading_pattern" '
    function indent_width(line) {
      match(line, /^[ ]*/)
      return RLENGTH
    }
    BEGIN {
      in_section = 0
      in_closeout_paths = 0
      closeout_indent = -1
    }
    $0 ~ heading_pattern {
      in_section = 1
      in_closeout_paths = 0
      closeout_indent = -1
      next
    }
    in_section && /^## / {
      exit
    }
    !in_section {
      next
    }
    $0 ~ /^[[:space:]]*-[[:space:]]+closeout evidence paths:[[:space:]]*$/ {
      in_closeout_paths = 1
      closeout_indent = indent_width($0)
      next
    }
    !in_closeout_paths {
      next
    }
    /^[[:space:]]*$/ {
      next
    }
    indent_width($0) <= closeout_indent {
      in_closeout_paths = 0
      closeout_indent = -1
      next
    }
    $0 ~ /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "", $0)
      print $0
    }
  ' "$sow_path"
}

_task_contract_optional_handover_linked_from_current_slice_sow() {
  local plan_path="${1:-}"
  local sow_path="${2:-}"
  local optional_handover_path="${3:-}"
  local slice_field=""
  local slice_token=""
  local closeout_paths=""
  local evidence_path=""

  [[ -n "$plan_path" && -n "$sow_path" && -n "$optional_handover_path" ]] || return 1
  _task_contract_is_slice_addendum "$plan_path" || return 1

  slice_field="$(_task_contract_metadata_value "$plan_path" "Slice" 2>/dev/null || true)"
  [[ "$slice_field" =~ ^([A-Za-z0-9._-]+)[[:space:]]*[-:].*$ || "$slice_field" =~ ^([A-Za-z0-9._-]+)$ ]] || return 1
  slice_token="${BASH_REMATCH[1]}"
  [[ -n "$slice_token" ]] || return 1

  closeout_paths="$(
    _task_contract_current_slice_closeout_evidence_paths \
      "$sow_path" \
      "^## Runtime Slice ${slice_token} "
  )" || return 1
  [[ -n "$closeout_paths" ]] || return 1

  while IFS= read -r evidence_path; do
    evidence_path="$(_task_contract_strip_wrapping_backticks "$evidence_path")"
    if [[ "$evidence_path" == "$optional_handover_path" ]]; then
      return 0
    fi
  done < <(printf '%s\n' "$closeout_paths")

  return 1
}

_task_contract_resolve_contract_plan_path() {
  local contract_file="${1:-}"
  local contract_plan_path="${2:-}"
  local repo_root=""

  [[ -n "$contract_file" ]] || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  if [[ "$contract_plan_path" == /* ]]; then
    [[ -r "$contract_plan_path" ]] || return 1
    printf '%s\n' "$contract_plan_path"
    return 0
  fi

  repo_root="$(_task_contract_repo_root_for_path "$contract_file" 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(_task_contract_repo_root_for_cwd 2>/dev/null || true)"
  fi
  [[ -n "$repo_root" ]] || return 1
  [[ -r "${repo_root}/${contract_plan_path}" ]] || return 1
  printf '%s\n' "${repo_root}/${contract_plan_path}"
}

_task_contract_expected_support_source_authority_selection_json() {
  local contract_file="${1:-}"
  local contract_plan_path="${2:-}"
  local resolved_plan_path=""
  local normalized_plan_path=""

  [[ -n "$contract_file" ]] || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  resolved_plan_path="$(
    _task_contract_resolve_contract_plan_path "$contract_file" "$contract_plan_path"
  )" || return 1
  normalized_plan_path="$(_task_contract_normalize_plan_path "$resolved_plan_path")" || return 1
  [[ "$normalized_plan_path" == "$contract_plan_path" ]] || return 1

  _task_contract_support_source_authority_selection_json \
    "$resolved_plan_path" \
    "$normalized_plan_path"
}

_task_contract_support_source_authority_selection_json() {
  local plan_path="$1"
  local normalized_plan_path="$2"
  local repo_root=""
  local policy_manifest_path=".agent/registry/policy_sources.json"
  local policy_manifest_abs=""
  local policy_manifest_present="false"
  local stable_authority_paths_json="[]"
  local current_control_lines=""
  local current_control_paths_json="[]"
  local optional_evidence_lines=""
  local optional_evidence_paths_json="[]"
  local authority_read_order_json="[]"
  local current_plan_path=""
  local current_sow_path=""
  local optional_handover_path=""

  current_control_lines="${normalized_plan_path}"$'\n'

  if repo_root=$(_task_contract_repo_root_for_path "$plan_path"); then
    policy_manifest_abs="${repo_root}/${policy_manifest_path}"

    if [[ -r "$policy_manifest_abs" ]]; then
      stable_authority_paths_json="$(
        jq -c '[.[] | select(.stable == true) | .path]' "$policy_manifest_abs"
      )" || return 1
      policy_manifest_present="true"
    fi

    if current_plan_path=$(_task_contract_current_plan_path "$plan_path" "$normalized_plan_path" 2>/dev/null); then
      if [[ -e "${repo_root}/${current_plan_path}" ]]; then
        current_control_lines="${current_control_lines}${current_plan_path}"$'\n'
      fi
    fi

    if current_sow_path=$(_task_contract_current_sow_path "$plan_path" "$normalized_plan_path" 2>/dev/null); then
      if [[ -e "${repo_root}/${current_sow_path}" ]]; then
        current_control_lines="${current_control_lines}${current_sow_path}"$'\n'

        if optional_handover_path=$(_task_contract_optional_handover_path_from_sow "$current_sow_path"); then
          if [[ -e "${repo_root}/${optional_handover_path}" ]]; then
            optional_evidence_lines="${optional_evidence_lines}${optional_handover_path}"$'\n'
          fi
        fi
      fi
    fi
  fi

  current_control_paths_json="$(
    printf '%s' "$current_control_lines" \
      | _task_contract_unique_lines \
      | _task_contract_lines_to_json_array
  )" || return 1

  if [[ -n "$optional_evidence_lines" ]]; then
    optional_evidence_paths_json="$(
      printf '%s' "$optional_evidence_lines" \
        | _task_contract_unique_lines \
        | _task_contract_lines_to_json_array
    )" || return 1
  fi

  authority_read_order_json="$(
    {
      _task_contract_jq_filter_string "$stable_authority_paths_json" -r '.[]'
      printf '%s' "$current_control_lines"
    } \
      | _task_contract_unique_lines \
      | _task_contract_lines_to_json_array
  )" || return 1

  jq -n \
    --arg resolver "bounded_support_source_authority_v1" \
    --arg policy_manifest_path "$policy_manifest_path" \
    --argjson policy_manifest_present "$policy_manifest_present" \
    --argjson stable_authority_paths "$stable_authority_paths_json" \
    --argjson current_control_paths "$current_control_paths_json" \
    --argjson authority_read_order "$authority_read_order_json" \
    --argjson optional_evidence_paths "$optional_evidence_paths_json" \
    '{
      resolver: $resolver,
      policy_manifest_path: $policy_manifest_path,
      policy_manifest_present: $policy_manifest_present,
      stable_authority_paths: $stable_authority_paths,
      current_control_paths: $current_control_paths,
      authority_read_order: $authority_read_order,
      optional_evidence_paths: $optional_evidence_paths,
      evidence_only_patterns: [
        ".agent/archive/**",
        ".claude/tmp/**"
      ]
    }'
}

_task_contract_owned_runtime_surface_json() {
  local plan_path="$1"
  local runtime_files=""
  local closeout_docs=""
  local runtime_files_json="[]"
  local closeout_docs_json="[]"

  _task_contract_is_slice_addendum "$plan_path" || return 1

  runtime_files="$(_task_contract_addendum_change_surface_list "$plan_path" "exact owned runtime files")" || return 1
  closeout_docs="$(_task_contract_addendum_change_surface_list "$plan_path" "exact closeout docs allowed")" || return 1
  [[ -n "$runtime_files" ]] || return 1
  [[ -n "$closeout_docs" ]] || return 1

  runtime_files_json="$(
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      _task_contract_strip_wrapping_backticks "$line"
    done < <(printf '%s\n' "$runtime_files") \
      | _task_contract_unique_lines \
      | _task_contract_lines_to_json_array
  )" || return 1
  closeout_docs_json="$(
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      _task_contract_strip_wrapping_backticks "$line"
    done < <(printf '%s\n' "$closeout_docs") \
      | _task_contract_unique_lines \
      | _task_contract_lines_to_json_array
  )" || return 1

  jq -n \
    --argjson runtime_files "$runtime_files_json" \
    --argjson closeout_docs_allowed "$closeout_docs_json" \
    '{
      runtime_files: $runtime_files,
      closeout_docs_allowed: $closeout_docs_allowed
    }'
}

_task_contract_support_context_freshness_json() {
  local plan_path="$1"
  local normalized_plan_path="$2"
  local repo_root=""
  local current_plan_path=""
  local current_sow_path=""
  local project_context_path=".agent/PROJECT_CONTEXT.md"
  local project_context_abs=""
  local current_plan_abs=""
  local current_sow_abs=""
  local current_plan_sha=""
  local current_sow_sha=""
  local project_context_sha=""
  local support_read_order_json="[]"
  local required_current_documents_json="[]"
  local optional_handover_path=""
  local optional_handover_abs=""
  local optional_handover_present="false"
  local optional_handover_linked_from_sow="false"
  local optional_handover_sha="null"

  _task_contract_is_slice_b_support_context_addendum "$plan_path" || return 1
  repo_root="$(_task_contract_repo_root_for_path "$plan_path" 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 1

  current_plan_path="$(_task_contract_current_plan_path "$plan_path" "$normalized_plan_path")" || return 1
  current_sow_path="$(_task_contract_current_sow_path "$plan_path" "$normalized_plan_path")" || return 1
  current_plan_abs="${repo_root}/${current_plan_path}"
  current_sow_abs="${repo_root}/${current_sow_path}"
  project_context_abs="${repo_root}/${project_context_path}"

  [[ -r "$current_plan_abs" ]] || return 1
  [[ -r "$current_sow_abs" ]] || return 1
  [[ -r "$project_context_abs" ]] || return 1

  current_plan_sha="$(_task_contract_sha256_file "$current_plan_abs")" || return 1
  current_sow_sha="$(_task_contract_sha256_file "$current_sow_abs")" || return 1
  project_context_sha="$(_task_contract_sha256_file "$project_context_abs")" || return 1

  support_read_order_json="$(
    printf '%s\n%s\n%s\n' "$current_plan_path" "$current_sow_path" "$project_context_path" \
      | _task_contract_unique_lines \
      | _task_contract_lines_to_json_array
  )" || return 1

  required_current_documents_json="$(
    jq -n \
      --arg current_plan_path "$current_plan_path" \
      --arg current_plan_sha "$current_plan_sha" \
      --arg current_sow_path "$current_sow_path" \
      --arg current_sow_sha "$current_sow_sha" \
      --arg project_context_path "$project_context_path" \
      --arg project_context_sha "$project_context_sha" \
      '[
        {role: "current_plan", path: $current_plan_path, sha256: $current_plan_sha},
        {role: "current_sow", path: $current_sow_path, sha256: $current_sow_sha},
        {role: "project_context", path: $project_context_path, sha256: $project_context_sha}
      ]'
  )" || return 1

  if optional_handover_path=$(_task_contract_optional_handover_path_from_sow "$current_sow_path" 2>/dev/null); then
    optional_handover_abs="${repo_root}/${optional_handover_path}"
    if _task_contract_optional_handover_linked_from_current_slice_sow \
      "$plan_path" \
      "$current_sow_abs" \
      "$optional_handover_path"; then
      optional_handover_linked_from_sow="true"
    fi

    if [[ -e "$optional_handover_abs" ]]; then
      optional_handover_present="true"
      [[ "$optional_handover_linked_from_sow" == "true" ]] || return 1
      optional_handover_sha="$(_task_contract_sha256_file "$optional_handover_abs" | jq -R .)" || return 1
    fi
  else
    optional_handover_path=""
  fi

  jq -n \
    --arg resolver "bounded_support_context_freshness_v1" \
    --arg current_plan_path "$current_plan_path" \
    --arg current_sow_path "$current_sow_path" \
    --arg project_context_path "$project_context_path" \
    --argjson support_read_order "$support_read_order_json" \
    --argjson required_current_documents "$required_current_documents_json" \
    --arg optional_handover_path "$optional_handover_path" \
    --argjson optional_handover_present "$optional_handover_present" \
    --argjson optional_handover_linked_from_sow "$optional_handover_linked_from_sow" \
    --argjson optional_handover_sha "$optional_handover_sha" \
    '{
      resolver: $resolver,
      current_plan_path: $current_plan_path,
      current_sow_path: $current_sow_path,
      project_context_path: $project_context_path,
      support_read_order: $support_read_order,
      required_current_documents: $required_current_documents,
      optional_handover: {
        path: $optional_handover_path,
        present: $optional_handover_present,
        evidence_only: true,
        linked_from_sow: $optional_handover_linked_from_sow,
        sha256: $optional_handover_sha
      },
      freshness_expectations: {
        current_plan_required: true,
        current_sow_required: true,
        project_context_required: true,
        optional_handover_evidence_only: true,
        optional_handover_linked_from_current_sow: true,
        optional_handover_digest_required_when_present: true
      },
      evidence_only_patterns: [
        ".agent/archive/**",
        ".claude/tmp/**"
      ]
    }'
}

_task_contract_expected_owned_runtime_surface_json() {
  local contract_file="${1:-}"
  local contract_plan_path="${2:-}"
  local resolved_plan_path=""
  local normalized_plan_path=""

  [[ -n "$contract_file" ]] || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  resolved_plan_path="$(
    _task_contract_resolve_contract_plan_path "$contract_file" "$contract_plan_path"
  )" || return 1
  normalized_plan_path="$(_task_contract_normalize_plan_path "$resolved_plan_path")" || return 1
  [[ "$normalized_plan_path" == "$contract_plan_path" ]] || return 1
  _task_contract_owned_runtime_surface_json "$resolved_plan_path"
}

_task_contract_expected_support_context_freshness_json() {
  local contract_file="${1:-}"
  local contract_plan_path="${2:-}"
  local resolved_plan_path=""
  local normalized_plan_path=""

  [[ -n "$contract_file" ]] || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  resolved_plan_path="$(
    _task_contract_resolve_contract_plan_path "$contract_file" "$contract_plan_path"
  )" || return 1
  normalized_plan_path="$(_task_contract_normalize_plan_path "$resolved_plan_path")" || return 1
  [[ "$normalized_plan_path" == "$contract_plan_path" ]] || return 1

  _task_contract_support_context_freshness_json \
    "$resolved_plan_path" \
    "$normalized_plan_path"
}

_task_contract_validate_support_source_authority_selection_against_repo() {
  local contract_file="${1:-}"
  local contract_plan_path=""
  local actual_selection_json=""
  local expected_selection_json=""

  [[ -n "$contract_file" ]] || return 1
  [[ -r "$contract_file" ]] || return 1

  contract_plan_path="$(jq -r '.plan_path // empty' "$contract_file")" || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  expected_selection_json="$(
    _task_contract_expected_support_source_authority_selection_json \
      "$contract_file" \
      "$contract_plan_path"
  )" || return 1
  expected_selection_json="$(_task_contract_jq_filter_string "$expected_selection_json" -cS '.')" || return 1
  actual_selection_json="$(jq -cS '.support_source_authority_selection' "$contract_file")" || return 1

  [[ "$actual_selection_json" == "$expected_selection_json" ]]
}

_task_contract_validate_owned_runtime_surface_against_repo() {
  local contract_file="${1:-}"
  local contract_plan_path=""
  local actual_surface_json=""
  local expected_surface_json=""

  [[ -n "$contract_file" ]] || return 1
  [[ -r "$contract_file" ]] || return 1

  contract_plan_path="$(jq -r '.plan_path // empty' "$contract_file")" || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  expected_surface_json="$(
    _task_contract_expected_owned_runtime_surface_json \
      "$contract_file" \
      "$contract_plan_path"
  )" || return 1
  expected_surface_json="$(_task_contract_jq_filter_string "$expected_surface_json" -cS '.')" || return 1
  actual_surface_json="$(jq -cS '.owned_runtime_surface' "$contract_file")" || return 1

  [[ "$actual_surface_json" == "$expected_surface_json" ]]
}

_task_contract_validate_support_context_freshness_against_repo() {
  local contract_file="${1:-}"
  local contract_plan_path=""
  local actual_freshness_json=""
  local expected_freshness_json=""

  [[ -n "$contract_file" ]] || return 1
  [[ -r "$contract_file" ]] || return 1

  contract_plan_path="$(jq -r '.plan_path // empty' "$contract_file")" || return 1
  [[ -n "$contract_plan_path" ]] || return 1

  expected_freshness_json="$(
    _task_contract_expected_support_context_freshness_json \
      "$contract_file" \
      "$contract_plan_path"
  )" || return 1
  expected_freshness_json="$(_task_contract_jq_filter_string "$expected_freshness_json" -cS '.')" || return 1
  actual_freshness_json="$(jq -cS '.support_context_freshness' "$contract_file")" || return 1

  [[ "$actual_freshness_json" == "$expected_freshness_json" ]]
}

task_contract_build_json() {
  local plan_path=""
  local phase=""
  local task_id=""
  local owner_role=""
  local coder_engine=""
  local artifact_destination=""
  local slice_id=""
  local normalized_plan_path=""
  local parsed_required_checks=""
  local parsed_in_scope=""
  local parsed_out_of_scope=""
  local parsed_completion_boundary=""
  local support_source_authority_selection_json=""
  local support_context_freshness_json=""
  local owned_runtime_surface_json=""
  local plan_uses_addendum="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan) plan_path="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      --task-id) task_id="${2:-}"; shift 2 ;;
      --owner-role) owner_role="${2:-}"; shift 2 ;;
      --coder-engine) coder_engine="${2:-}"; shift 2 ;;
      --artifact-destination) artifact_destination="${2:-}"; shift 2 ;;
      --slice-id) slice_id="${2:-}"; shift 2 ;;
      *)
        _task_contract_log_error "Unknown task_contract_build_json arg: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$plan_path" ]] || { _task_contract_log_error "task_contract_build_json: --plan is required"; return 1; }
  [[ -r "$plan_path" ]] || { _task_contract_log_error "task_contract_build_json: unreadable plan: $plan_path"; return 1; }
  [[ -n "$phase" ]] || { _task_contract_log_error "task_contract_build_json: --phase is required"; return 1; }
  [[ -n "$task_id" ]] || { _task_contract_log_error "task_contract_build_json: --task-id is required"; return 1; }
  [[ -n "$coder_engine" ]] || { _task_contract_log_error "task_contract_build_json: --coder-engine is required"; return 1; }
  [[ -n "$artifact_destination" ]] || { _task_contract_log_error "task_contract_build_json: --artifact-destination is required"; return 1; }
  _task_contract_validate_artifact_destination "$artifact_destination" || {
    _task_contract_log_error "task_contract_build_json: invalid artifact_destination: $artifact_destination"
    return 1
  }
  normalized_plan_path=$(_task_contract_normalize_plan_path "$plan_path") || {
    _task_contract_log_error "task_contract_build_json: failed to normalize plan_path: $plan_path"
    return 1
  }
  if _task_contract_is_slice_addendum "$plan_path"; then
    plan_uses_addendum="true"
  fi

  case "$coder_engine" in
    claude|codex) ;;
    *)
      _task_contract_log_error "task_contract_build_json: unsupported coder engine: $coder_engine"
      return 1
      ;;
  esac

  if [[ -z "$owner_role" ]]; then
    owner_role=$(_task_contract_owner_role_from_plan "$plan_path")
  fi

  if [[ -z "$slice_id" ]]; then
    slice_id=$(_task_contract_slice_id_from_plan "$plan_path" "$phase")
  fi

  local in_scope_json
  local out_of_scope_json
  local required_checks_json
  local completion_boundary_json
  local allowed_capabilities_json

  if [[ "$plan_uses_addendum" == "true" ]]; then
    parsed_in_scope=$(_task_contract_required_list_items_from_addendum "$plan_path" "In-Scope") || {
      _task_contract_log_error "task_contract_build_json: missing or empty required section: In-Scope"
      return 1
    }
  elif parsed_in_scope=$(_task_contract_required_list_items_from_plan "$plan_path" "In-Scope"); then
    in_scope_json=$(_task_contract_resolve_array_json "$parsed_in_scope")
  else
    _task_contract_log_error "task_contract_build_json: missing or empty required section: In-Scope"
    return 1
  fi
  in_scope_json=$(_task_contract_resolve_array_json "$parsed_in_scope")

  if [[ "$plan_uses_addendum" == "true" ]]; then
    parsed_out_of_scope=$(_task_contract_required_list_items_from_addendum "$plan_path" "Out-Of-Scope") || {
      _task_contract_log_error "task_contract_build_json: missing or empty required section: Out-Of-Scope"
      return 1
    }
  elif parsed_out_of_scope=$(_task_contract_required_list_items_from_plan "$plan_path" "Out-Of-Scope"); then
    out_of_scope_json=$(_task_contract_resolve_array_json "$parsed_out_of_scope")
  else
    _task_contract_log_error "task_contract_build_json: missing or empty required section: Out-Of-Scope"
    return 1
  fi
  out_of_scope_json=$(_task_contract_resolve_array_json "$parsed_out_of_scope")

  if parsed_required_checks=$(_task_contract_required_checks_from_plan "$plan_path"); then
    :
  else
    local required_checks_status=$?
    if [[ "$required_checks_status" -eq 2 ]]; then
      _task_contract_log_error "task_contract_build_json: missing or empty Required Deterministic Checks section"
    else
      _task_contract_log_error "task_contract_build_json: failed to extract exact required_checks from plan"
    fi
    return 1
  fi
  required_checks_json=$(_task_contract_resolve_array_json "$parsed_required_checks")

  if [[ "$plan_uses_addendum" == "true" ]]; then
    parsed_completion_boundary=$(_task_contract_required_list_items_from_addendum "$plan_path" "Completion Boundary") || {
      _task_contract_log_error "task_contract_build_json: missing or empty required section: Completion Boundary"
      return 1
    }
  elif parsed_completion_boundary=$(_task_contract_required_list_items_from_plan "$plan_path" "Completion Boundary"); then
    completion_boundary_json=$(_task_contract_resolve_array_json "$parsed_completion_boundary")
  else
    _task_contract_log_error "task_contract_build_json: missing or empty required section: Completion Boundary"
    return 1
  fi
  completion_boundary_json=$(_task_contract_resolve_array_json "$parsed_completion_boundary")

  allowed_capabilities_json=$(_task_contract_resolve_array_json \
    "" \
    "$(_task_contract_default_allowed_capabilities)")
  support_source_authority_selection_json="$(
    _task_contract_support_source_authority_selection_json "$plan_path" "$normalized_plan_path"
  )" || {
    _task_contract_log_error "task_contract_build_json: failed to resolve support-source authority selection"
    return 1
  }
  if support_context_freshness_json="$(
    _task_contract_support_context_freshness_json "$plan_path" "$normalized_plan_path" 2>/dev/null
  )"; then
    :
  elif _task_contract_is_slice_b_support_context_addendum "$plan_path"; then
    _task_contract_log_error "task_contract_build_json: failed to resolve support-context freshness"
    return 1
  else
    support_context_freshness_json=""
  fi
  if [[ "$plan_uses_addendum" == "true" ]]; then
    owned_runtime_surface_json="$(_task_contract_owned_runtime_surface_json "$plan_path")" || {
      _task_contract_log_error "task_contract_build_json: failed to resolve owned runtime surface"
      return 1
    }
  fi

  jq -n \
    --arg contract_version "$TASK_CONTRACT_VERSION" \
    --arg task_id "$task_id" \
    --arg slice_id "$slice_id" \
    --arg plan_path "$normalized_plan_path" \
    --arg phase "$phase" \
    --arg owner_role "$owner_role" \
    --arg coder_engine "$coder_engine" \
    --arg artifact_destination "$artifact_destination" \
    --argjson in_scope "$in_scope_json" \
    --argjson out_of_scope "$out_of_scope_json" \
    --argjson required_checks "$required_checks_json" \
    --argjson completion_boundary "$completion_boundary_json" \
    --argjson allowed_capabilities "$allowed_capabilities_json" \
    --argjson support_source_authority_selection "$support_source_authority_selection_json" \
    --argjson support_context_freshness "${support_context_freshness_json:-null}" \
    --argjson owned_runtime_surface "${owned_runtime_surface_json:-null}" \
    '{
      contract_version: $contract_version,
      task_id: $task_id,
      slice_id: $slice_id,
      plan_path: $plan_path,
      phase: $phase,
      owner_role: $owner_role,
      coder_engine: $coder_engine,
      in_scope: $in_scope,
      out_of_scope: $out_of_scope,
      required_checks: $required_checks,
      artifact_destination: $artifact_destination,
      completion_boundary: $completion_boundary,
      allowed_capabilities: $allowed_capabilities,
      support_source_authority_selection: $support_source_authority_selection
    }
    + (if $support_context_freshness == null then {} else {support_context_freshness: $support_context_freshness} end)
    + (if $owned_runtime_surface == null then {} else {owned_runtime_surface: $owned_runtime_surface} end)'
}

_task_contract_compute_id_assign() {
  local result_var="$1"
  local payload="${2:-}"
  local digest=""
  local payload_file=""
  local canonical_file=""

  [[ -n "$payload" ]] || { _task_contract_log_error "task_contract_compute_id: payload is empty"; return 1; }

  payload_file=$(mktemp "${TMPDIR:-/tmp}/task_contract_payload.XXXXXX") || return 1
  canonical_file=$(mktemp "${TMPDIR:-/tmp}/task_contract_canonical.XXXXXX") || {
    /bin/rm -f -- "$payload_file"
    return 1
  }
  trap '/bin/rm -f -- "$payload_file" "$canonical_file"' RETURN
  printf '%s' "$payload" > "$payload_file" || {
    /bin/rm -f -- "$payload_file" "$canonical_file"
    trap - RETURN
    return 1
  }

  jq -cS 'del(.contract_id)' "$payload_file" | tr -d '\n' > "$canonical_file" || {
    /bin/rm -f -- "$payload_file" "$canonical_file"
    trap - RETURN
    _task_contract_log_error "task_contract_compute_id: failed to canonicalize payload"
    return 1
  }

  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$canonical_file" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$canonical_file" | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 -r "$canonical_file" | awk '{print $1}')
  else
    /bin/rm -f -- "$payload_file" "$canonical_file"
    trap - RETURN
    _task_contract_log_error "task_contract_compute_id: no SHA-256 tool available"
    return 1
  fi
  /bin/rm -f -- "$payload_file" "$canonical_file"
  trap - RETURN

  [[ -n "$digest" ]] || { _task_contract_log_error "task_contract_compute_id: digest is empty"; return 1; }
  printf -v "$result_var" 'task-contract-%s' "$digest"
}

task_contract_compute_id() {
  local payload="${1:-}"
  local contract_id=""

  _task_contract_compute_id_assign contract_id "$payload" || return 1
  printf '%s\n' "$contract_id"
}

task_contract_extract_required_checks() {
  local plan_path="${1:-}"

  [[ -n "$plan_path" ]] || {
    _task_contract_log_error "task_contract_extract_required_checks: <plan_path> is required"
    return 1
  }

  _task_contract_required_checks_from_plan "$plan_path"
}

task_contract_validate_file() {
  local contract_file="${1:-}"
  local actual_id=""
  local expected_id=""
  local contract_payload=""
  local artifact_destination=""
  local required_check=""
  local normalized_required_check=""

  [[ -n "$contract_file" ]] || return 1
  [[ -r "$contract_file" ]] || return 1

  jq -e \
    --arg expected_contract_version "$TASK_CONTRACT_VERSION" \
    --arg task_segment_pattern "$TASK_CONTRACT_TASK_SEGMENT_PATTERN" '
    def non_empty_string:
      type == "string" and length > 0;
    def no_control_string:
      type == "string" and (explode | all(. >= 32 and . != 127));
    def trimmed_non_empty_string:
      no_control_string and ((gsub("^[[:space:]]+|[[:space:]]+$"; "")) | length > 0);
    def string_array:
      type == "array" and all(.[]; trimmed_non_empty_string);
    def unique_string_array:
      string_array and ((unique | length) == length);
    def optional_unique_string_array:
      . == null or unique_string_array;
    def dedupe_preserve_order($items):
      reduce $items[] as $item ([]; if index($item) == null then . + [$item] else . end);
    def is_evidence_only_path:
      startswith(".agent/archive/") or startswith(".claude/tmp/");
    def no_evidence_only_paths:
      all(.[]; (is_evidence_only_path | not));
    def hex_sha256:
      type == "string" and test("^[0-9a-f]{64}$");
    def valid_artifact_destination:
      no_control_string
      and (
        (try capture("^\\.claude/tmp/(?<task>[^/]+)/task-contract\\.json$") catch null) as $capture
        | $capture != null
        and ($capture.task | test($task_segment_pattern))
        and $capture.task != "."
        and $capture.task != ".."
      );

    type == "object"
    and (.contract_version == $expected_contract_version)
    and (.task_id | non_empty_string)
    and (.slice_id | non_empty_string)
    and (.plan_path | non_empty_string)
    and (.phase | non_empty_string)
    and (.owner_role | non_empty_string)
    and (.coder_engine == "claude" or .coder_engine == "codex")
    and (.in_scope | string_array and length > 0)
    and (.out_of_scope | string_array and length > 0)
    and (.required_checks | string_array and length > 0 and all(.[]; contains("`") | not))
    and (.artifact_destination | valid_artifact_destination)
    and (.completion_boundary | string_array and length > 0)
    and (.allowed_capabilities | string_array and length > 0)
    and (
      .support_source_authority_selection as $selection
      | ($selection | type == "object")
      and ($selection.resolver == "bounded_support_source_authority_v1")
      and ($selection.policy_manifest_path | trimmed_non_empty_string)
      and ($selection.policy_manifest_present | type == "boolean")
      and ($selection.stable_authority_paths | unique_string_array)
      and ($selection.current_control_paths | unique_string_array and length > 0)
      and ($selection.authority_read_order | unique_string_array and length > 0)
      and ($selection.optional_evidence_paths | unique_string_array)
      and ($selection.evidence_only_patterns | unique_string_array and length > 0)
      and ($selection.stable_authority_paths | no_evidence_only_paths)
      and ($selection.current_control_paths | no_evidence_only_paths)
      and ($selection.authority_read_order | no_evidence_only_paths)
      and (
        $selection.policy_manifest_present
        or (($selection.stable_authority_paths | length) == 0)
      )
      and (
        $selection.authority_read_order
        == dedupe_preserve_order($selection.stable_authority_paths + $selection.current_control_paths)
      )
      and all(
        $selection.current_control_paths[];
        . as $path | ($selection.authority_read_order | index($path)) != null
      )
      and all(
        $selection.stable_authority_paths[];
        . as $path | ($selection.authority_read_order | index($path)) != null
      )
      and all(
        $selection.optional_evidence_paths[];
        . as $path | ($selection.authority_read_order | index($path)) == null
      )
    )
    and (
      if has("support_context_freshness") then
        .support_context_freshness as $freshness
        | ($freshness | type == "object")
        and has("owned_runtime_surface")
        and ($freshness.resolver == "bounded_support_context_freshness_v1")
        and ($freshness.current_plan_path | trimmed_non_empty_string)
        and ($freshness.current_sow_path | trimmed_non_empty_string)
        and ($freshness.project_context_path | trimmed_non_empty_string)
        and ($freshness.support_read_order | unique_string_array and length == 3)
        and ($freshness.support_read_order | no_evidence_only_paths)
        and ($freshness.support_read_order | index($freshness.current_plan_path) != null)
        and ($freshness.support_read_order | index($freshness.current_sow_path) != null)
        and ($freshness.support_read_order | index($freshness.project_context_path) != null)
        and (
          $freshness.support_read_order
          == dedupe_preserve_order([
            $freshness.current_plan_path,
            $freshness.current_sow_path,
            $freshness.project_context_path
          ])
        )
        and (
          $freshness.required_current_documents
          | type == "array"
          and length == 3
          and all(
            .[];
            (.role == "current_plan" or .role == "current_sow" or .role == "project_context")
            and (.path | trimmed_non_empty_string)
            and (.sha256 | hex_sha256)
          )
        )
        and (
          ($freshness.required_current_documents | map(.role) | unique | sort)
          == ["current_plan", "current_sow", "project_context"]
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "current_plan")) | length) == 1
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "current_sow")) | length) == 1
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "project_context")) | length) == 1
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "current_plan"))[0].path)
          == $freshness.current_plan_path
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "current_sow"))[0].path)
          == $freshness.current_sow_path
        )
        and (
          ($freshness.required_current_documents | map(select(.role == "project_context"))[0].path)
          == $freshness.project_context_path
        )
        and (
          $freshness.optional_handover
          | type == "object"
          and (.path | type == "string")
          and (.present | type == "boolean")
          and (.evidence_only == true)
          and (.linked_from_sow | type == "boolean")
          and (.sha256 == null or (.sha256 | hex_sha256))
          and (.path as $handover_path | ($freshness.support_read_order | index($handover_path)) == null)
          and (
            (.present == true and .sha256 != null)
            or (.present == false and .sha256 == null)
          )
        )
        and (
          $freshness.freshness_expectations
          == {
            current_plan_required: true,
            current_sow_required: true,
            project_context_required: true,
            optional_handover_evidence_only: true,
            optional_handover_linked_from_current_sow: true,
            optional_handover_digest_required_when_present: true
          }
        )
        and ($freshness.evidence_only_patterns | unique_string_array and length > 0)
      else
        true
      end
    )
    and (
      if has("owned_runtime_surface") then
        .owned_runtime_surface as $surface
        | ($surface | type == "object")
        and ($surface.runtime_files | unique_string_array and length > 0)
        and ($surface.closeout_docs_allowed | unique_string_array and length > 0)
      else
        true
      end
    )
    and (.contract_id | non_empty_string)
  ' "$contract_file" >/dev/null 2>&1 || return 1

  actual_id=$(jq -r '.contract_id // empty' "$contract_file") || return 1
  contract_payload="$(cat "$contract_file")" || return 1
  _task_contract_compute_id_assign expected_id "$contract_payload" || return 1
  [[ -n "$actual_id" && "$actual_id" == "$expected_id" ]] || return 1
  artifact_destination=$(jq -r '.artifact_destination // empty' "$contract_file") || return 1
  _task_contract_validate_artifact_destination "$artifact_destination" || return 1
  _task_contract_validate_support_source_authority_selection_against_repo "$contract_file" || return 1
  if jq -e 'has("support_context_freshness")' "$contract_file" >/dev/null 2>&1; then
    _task_contract_validate_support_context_freshness_against_repo "$contract_file" || return 1
  fi
  if jq -e 'has("owned_runtime_surface")' "$contract_file" >/dev/null 2>&1; then
    _task_contract_validate_owned_runtime_surface_against_repo "$contract_file" || return 1
  fi

  while IFS= read -r -d '' required_check; do
    normalized_required_check=$(_task_contract_normalize_command_item "$required_check") || return 1
    [[ "$required_check" == "$normalized_required_check" ]] || return 1
  done < <(jq -jr '.required_checks[] + "\u0000"' "$contract_file")

  return 0
}

task_contract_read_id() {
  local contract_file="${1:-}"

  [[ -r "$contract_file" ]] || return 1
  jq -r '.contract_id // empty' "$contract_file"
}

task_contract_emit() {
  local plan_path=""
  local phase=""
  local task_id=""
  local owner_role=""
  local coder_engine=""
  local artifact_destination=""
  local output_path=""
  local slice_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan) plan_path="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      --task-id) task_id="${2:-}"; shift 2 ;;
      --owner-role) owner_role="${2:-}"; shift 2 ;;
      --coder-engine) coder_engine="${2:-}"; shift 2 ;;
      --artifact-destination) artifact_destination="${2:-}"; shift 2 ;;
      --output) output_path="${2:-}"; shift 2 ;;
      --slice-id) slice_id="${2:-}"; shift 2 ;;
      *)
        _task_contract_log_error "Unknown task_contract_emit arg: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$output_path" ]] || { _task_contract_log_error "task_contract_emit: --output is required"; return 1; }

  _task_contract_require_cmd jq || return 1
  _task_contract_ensure_dir "$(dirname "$output_path")"

  local payload=""
  local contract_id=""
  local tmp_file=""

  payload=$(task_contract_build_json \
    --plan "$plan_path" \
    --phase "$phase" \
    --task-id "$task_id" \
    --owner-role "$owner_role" \
    --coder-engine "$coder_engine" \
    --artifact-destination "$artifact_destination" \
    --slice-id "$slice_id") || return 1

  _task_contract_compute_id_assign contract_id "$payload" || return 1
  payload="$(_task_contract_jq_filter_string "$payload" --arg contract_id "$contract_id" '. + { contract_id: $contract_id }')" || return 1

  tmp_file=$(mktemp "$(dirname "$output_path")/.task_contract.XXXXXX")
  trap '/bin/rm -f -- "$tmp_file"' RETURN
  printf '%s\n' "$payload" > "$tmp_file"

  if ! task_contract_validate_file "$tmp_file"; then
    /bin/rm -f -- "$tmp_file"
    trap - RETURN
    _task_contract_log_error "task_contract_emit: generated contract failed validation"
    return 1
  fi

  mv "$tmp_file" "$output_path"
  trap - RETURN
  if ! task_contract_validate_file "$output_path"; then
    _task_contract_log_error "task_contract_emit: contract became unreadable or invalid after write"
    return 1
  fi

  printf '%s\n' "$contract_id"
}

task_contract_main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    emit)
      task_contract_emit "$@"
      ;;
    validate)
      local contract_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --file) contract_file="${2:-}"; shift 2 ;;
          *)
            _task_contract_log_error "Unknown task_contract validate arg: $1"
            return 1
            ;;
        esac
      done
      task_contract_validate_file "$contract_file"
      ;;
    print-id)
      local contract_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --file) contract_file="${2:-}"; shift 2 ;;
          *)
            _task_contract_log_error "Unknown task_contract print-id arg: $1"
            return 1
            ;;
        esac
      done
      task_contract_read_id "$contract_file"
      ;;
    *)
      cat <<'USAGE' >&2
Usage:
  task_contract.sh emit --plan PATH --phase NAME --task-id ID --coder-engine claude|codex \
    --artifact-destination .claude/tmp/<task>/task-contract.json --output PATH [--owner-role ROLE]
  task_contract.sh validate --file PATH
  task_contract.sh print-id --file PATH
USAGE
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  task_contract_main "$@"
fi
