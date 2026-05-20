#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

record_pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

record_fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
}

clean_frontmatter_value() {
  printf '%s' "$1" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^\"//; s/\"$//; s/^'//; s/'$//"
}

frontmatter_field() {
  local field="$1"
  local file="$2"

  awk -v field="${field}" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, field ":") == 1 {
      sub(field ":[[:space:]]*", "")
      print
      exit
    }
  ' "${file}"
}

assert_file_check() {
  local condition="$1"
  local message="$2"

  if [[ "${condition}" == "true" ]]; then
    record_pass "${message}"
  else
    record_fail "${message}"
  fi
}

name_matches_folder_or_compat_alias() {
  local parent="$1"
  local name_value="$2"

  [[ "${name_value}" == "${parent}" ]] && return 0

  case "${parent}:${name_value}" in
    go-skills-knowledge-pack:go-skills-architecture) return 0 ;;
    rust-skills-knowledge-pack:rust-skills-architecture) return 0 ;;
    typescript-skills-knowledge-pack:typescript-skills-architecture) return 0 ;;
    *) return 1 ;;
  esac
}

check_skill_file() {
  local file="$1"
  local parent
  local first_line
  local closing_line
  local name_raw
  local description_raw
  local name_value
  local description_value

  parent="$(basename "$(dirname "${file}")")"
  first_line="$(sed -n '1p' "${file}")"
  closing_line="$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "${file}")"
  name_raw="$(frontmatter_field "name" "${file}")"
  description_raw="$(frontmatter_field "description" "${file}")"
  name_value="$(clean_frontmatter_value "${name_raw}")"
  description_value="$(clean_frontmatter_value "${description_raw}")"

  if [[ "${first_line}" == "---" && -n "${closing_line}" ]]; then
    record_pass "${file}: frontmatter is fenced"
  else
    record_fail "${file}: frontmatter is fenced"
  fi

  [[ -n "${name_raw}" ]] && assert_file_check true "${file}: name field exists" \
    || assert_file_check false "${file}: name field exists"
  [[ -n "${description_raw}" ]] && assert_file_check true "${file}: description field exists" \
    || assert_file_check false "${file}: description field exists"
  name_matches_folder_or_compat_alias "${parent}" "${name_value}" \
    && assert_file_check true "${file}: name matches parent folder or documented compatibility alias" \
    || assert_file_check false "${file}: name matches parent folder or documented compatibility alias"
  [[ "${name_value}" != *[[:upper:]]* ]] && assert_file_check true "${file}: name is lowercase" \
    || assert_file_check false "${file}: name is lowercase"
  [[ -n "${description_value}" ]] && assert_file_check true "${file}: description is non-empty" \
    || assert_file_check false "${file}: description is non-empty"
}

check_provider_dir() {
  local provider_dir="$1"
  local skill_files=()
  local file

  if [[ ! -d "${provider_dir}" ]]; then
    record_fail "${provider_dir}: provider directory exists"
    return
  fi
  record_pass "${provider_dir}: provider directory exists"

  while IFS= read -r file; do
    skill_files+=("${file}")
  done < <(find "${provider_dir}" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | sort)

  if [[ "${#skill_files[@]}" -gt 0 ]]; then
    record_pass "${provider_dir}: has skill files"
  else
    record_fail "${provider_dir}: has skill files"
  fi

  for file in "${skill_files[@]}"; do
    check_skill_file "${file}"
  done
}

assert_sample_skill() {
  local slug="$1"
  local provider_dir="$2"
  local file="${provider_dir}/${slug}/SKILL.md"
  local name_value

  if [[ ! -f "${file}" ]]; then
    record_fail "sample ${provider_dir}/${slug}: SKILL.md exists"
    return
  fi
  name_value="$(clean_frontmatter_value "$(frontmatter_field "name" "${file}")")"
  if [[ "${name_value}" == "${slug}" ]]; then
    record_pass "sample ${provider_dir}/${slug}: precise name compliance"
  else
    record_fail "sample ${provider_dir}/${slug}: precise name compliance"
  fi
}

check_provider_dir "${REPO_ROOT}/.agents/skills"
check_provider_dir "${REPO_ROOT}/.claude/skills"

for slug in cursor-caller production-function-implementer staff-code-reviewer; do
  assert_sample_skill "${slug}" "${REPO_ROOT}/.agents/skills"
  assert_sample_skill "${slug}" "${REPO_ROOT}/.claude/skills"
done

printf '%s\n' "---"
printf 'Result: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == "0" ]]
