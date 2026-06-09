#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_MANIFEST_REL=".agent/registry/skill_projection_manifest.json"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/rev-harness-skill-projection.sh --check [--json] [--allow-not-installed] [--manifest <path>] [--root <path>]' \
    '' \
    'Verify shared skill canonical sources and provider projections from the' \
    'skill projection manifest. Manifest paths are repository-root-relative,' \
    'except Codex installed projections which must use $CODEX_HOME/skills/<skill>.' \
    '' \
    '--allow-not-installed is a non-acceptance mode for validating source and' \
    'generated projections before the Codex skill has been installed.'
}

die() {
  printf 'rev-harness-skill-projection: %s\n' "$*" >&2
  exit 1
}

cleanup_tmp_dir() {
  local rc=$?

  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR" || true
  fi
  exit "$rc"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_safe_relative_path() {
  local path="$1"

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *$'\n'* ]] || return 1
  case "/$path/" in
    *"//"*|*"/./"*|*"/../"*) return 1 ;;
  esac
  return 0
}

is_codex_install_manifest_path() {
  local path="$1"
  local suffix=""

  case "$path" in
    '$CODEX_HOME/skills/'*)
      suffix="${path#\$CODEX_HOME/skills/}"
      is_safe_relative_path "$suffix"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_manifest_path() {
  local path="$1"
  local suffix=""

  case "$path" in
    '$CODEX_HOME/skills/'*)
      suffix="${path#\$CODEX_HOME/skills/}"
      printf '%s\n' "$CODEX_SKILLS_ROOT/$suffix"
      ;;
    *)
      printf '%s\n' "$PROJECT_ROOT/$path"
      ;;
  esac
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

line_count() {
  local file="$1"
  wc -l <"$file" | tr -d '[:space:]'
}

relative_to_root() {
  local path="$1"

  case "$path" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${path#$PROJECT_ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

record_failure() {
  local context="$1"
  local message="$2"
  local path="${3:-}"

  jq -nc \
    --arg context "$context" \
    --arg message "$message" \
    --arg path "$path" \
    '{context: $context, message: $message, path: $path}' >>"$FAILURES_JSONL"
}

record_warning() {
  local context="$1"
  local message="$2"
  local path="${3:-}"

  jq -nc \
    --arg context "$context" \
    --arg message "$message" \
    --arg path "$path" \
    '{context: $context, message: $message, path: $path}' >>"$WARNINGS_JSONL"
}

record_source_result() {
  local skill="$1"
  local path="$2"
  local status="$3"
  local file_count="$4"

  jq -nc \
    --arg skill "$skill" \
    --arg path "$path" \
    --arg status "$status" \
    --argjson file_count "$file_count" \
    '{skill: $skill, path: $path, status: $status, file_count: $file_count}' >>"$SOURCES_JSONL"
}

record_projection_result() {
  local skill="$1"
  local provider="$2"
  local path="$3"
  local projection_kind="$4"
  local activation_status="$5"
  local auto_discoverable="$6"
  local install_target="$7"
  local status="$8"
  local file_count="$9"
  local excluded_count="${10}"

  jq -nc \
    --arg skill "$skill" \
    --arg provider "$provider" \
    --arg path "$path" \
    --arg projection_kind "$projection_kind" \
    --arg activation_status "$activation_status" \
    --argjson auto_discoverable "$auto_discoverable" \
    --arg install_target "$install_target" \
    --arg status "$status" \
    --argjson file_count "$file_count" \
    --argjson excluded_generated_metadata_count "$excluded_count" \
    '{
      skill: $skill,
      provider: $provider,
      path: $path,
      projection_kind: $projection_kind,
      activation_status: $activation_status,
      auto_discoverable: $auto_discoverable,
      install_target: $install_target,
      status: $status,
      file_count: $file_count,
      excluded_generated_metadata_count: $excluded_generated_metadata_count
    }' >>"$PROJECTIONS_JSONL"
}

check_no_symlink_path_components() {
  local rel_path="$1"
  local context="$2"
  local current="$PROJECT_ROOT"
  local part=""
  local rest=""

  if ! is_safe_relative_path "$rel_path"; then
    record_failure "$context" "unsafe non-repository-relative path" "$rel_path"
    return 1
  fi

  rest="$rel_path"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    current="$current/$part"
    if [[ -L "$current" ]]; then
      record_failure "$context" "symlink path component" "$(relative_to_root "$current")"
      return 1
    fi
    [[ -e "$current" ]] || break
    [[ "$rest" == "$part" ]] && break
    rest="${rest#*/}"
  done

  return 0
}

check_no_symlink_absolute_path_components() {
  local abs_path="$1"
  local context="$2"
  local display_path="$3"
  local current=""
  local part=""
  local rest=""

  [[ "$abs_path" == /* ]] || {
    record_failure "$context" "unsafe non-absolute installed path" "$display_path"
    return 1
  }
  [[ "$abs_path" != *$'\n'* ]] || {
    record_failure "$context" "unsafe installed path" "$display_path"
    return 1
  }
  case "$abs_path" in
    *"//"*|*"/./"*|*"/../"*)
      record_failure "$context" "unsafe installed path" "$display_path"
      return 1
      ;;
  esac

  rest="${abs_path#/}"
  current=""
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    current="$current/$part"
    if [[ -L "$current" ]]; then
      record_failure "$context" "symlink path component" "$display_path"
      return 1
    fi
    [[ -e "$current" ]] || break
    [[ "$rest" == "$part" ]] && break
    rest="${rest#*/}"
  done

  return 0
}

check_tree_path() {
  local manifest_path="$1"
  local context="$2"
  local abs_path="$3"
  local symlink_path=""
  local file_path=""
  local rel_file=""
  local ok=true

  if is_codex_install_manifest_path "$manifest_path"; then
    check_no_symlink_absolute_path_components "$abs_path" "$context" "$manifest_path" || return 1
  else
    check_no_symlink_path_components "$manifest_path" "$context" || return 1
  fi

  if [[ ! -d "$abs_path" ]]; then
    record_failure "$context" "missing directory" "$manifest_path"
    return 1
  fi

  symlink_path="$(find "$abs_path" -type l -print | sed -n '1p')"
  if [[ -n "$symlink_path" ]]; then
    record_failure "$context" "symlink inside skill tree" "$manifest_path/${symlink_path#$abs_path/}"
    ok=false
  fi

  while IFS= read -r file_path; do
    rel_file="${file_path#$abs_path/}"
    if ! is_safe_relative_path "$rel_file"; then
      record_failure "$context" "unsafe file path inside skill tree" "$manifest_path/$rel_file"
      ok=false
    fi
  done < <(find "$abs_path" -type f -print)

  [[ "$ok" == true ]]
}

validate_skill_frontmatter() {
  local skill_md="$1"
  local expected_name="$2"
  local context="$3"
  local output=""

  if output="$(python3 -c '
import re
import sys
from pathlib import Path

skill_md = Path(sys.argv[1])
expected_name = sys.argv[2]
text = skill_md.read_text(encoding="utf-8")

if not text.startswith("---\n"):
    raise SystemExit("missing YAML frontmatter")

match = re.match(r"^---\n(.*?)\n---(?:\n|$)(.*)$", text, re.DOTALL)
if not match:
    raise SystemExit("invalid frontmatter delimiter format")

frontmatter_text, body = match.groups()
frontmatter = {}
for line_number, line in enumerate(frontmatter_text.splitlines(), start=2):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if line[:1].isspace():
        raise SystemExit(f"unsupported nested or multiline frontmatter at line {line_number}")
    item = re.match(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*))?$", line)
    if not item:
        raise SystemExit(f"invalid YAML frontmatter entry at line {line_number}")
    key, raw_value = item.groups()
    if key in frontmatter:
        raise SystemExit(f"duplicate frontmatter key: {key}")
    value = (raw_value or "").strip()
    if value in {"|", ">"} or value.startswith(("- ", "[", "{")):
        raise SystemExit(f"unsupported non-scalar frontmatter value for {key}")
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith(chr(39)) and value.endswith(chr(39))
    ):
        value = value[1:-1]
    frontmatter[key] = value

allowed = {"name", "description"}
unexpected = sorted(set(frontmatter) - allowed)
if unexpected:
    raise SystemExit("unsupported frontmatter key(s): " + ", ".join(unexpected))

missing = sorted(allowed - set(frontmatter))
if missing:
    raise SystemExit("missing frontmatter key(s): " + ", ".join(missing))

name = frontmatter["name"].strip()
description = frontmatter["description"].strip()
if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?", name):
    raise SystemExit(f"invalid skill name: {name}")
if "--" in name:
    raise SystemExit(f"invalid skill name: {name}")
if name != expected_name:
    raise SystemExit(f"frontmatter name does not match folder: {name} != {expected_name}")
if not description:
    raise SystemExit("description must be non-empty")
if "<" in description or ">" in description:
    raise SystemExit("description cannot contain angle brackets")
if len(description) > 1024:
    raise SystemExit("description is too long")
if not body.strip():
    raise SystemExit("SKILL.md body must be non-empty")
' "$skill_md" "$expected_name" 2>&1)"; then
    return 0
  fi

  record_failure "$context" "$output" "$(relative_to_root "$skill_md")"
  return 1
}

validate_openai_yaml_if_present() {
  local abs_path="$1"
  local context="$2"
  local agents_dir="$abs_path/agents"
  local openai_yaml="$agents_dir/openai.yaml"
  local entry=""
  local output=""
  local ok=true

  [[ -e "$agents_dir" ]] || return 0
  if [[ ! -d "$agents_dir" ]]; then
    record_failure "$context" "agents entry must be a directory" "$(relative_to_root "$agents_dir")"
    return 1
  fi

  while IFS= read -r entry; do
    if [[ "$(basename "$entry")" != "openai.yaml" ]]; then
      record_failure "$context" "unsupported agents metadata file" "$(relative_to_root "$entry")"
      ok=false
    fi
  done < <(find "$agents_dir" -maxdepth 1 -mindepth 1 -type f -print)

  if [[ ! -e "$openai_yaml" ]]; then
    [[ "$ok" == true ]]
    return
  fi

  if ! output="$(python3 -c '
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
allowed_top = {"interface", "dependencies", "policy"}
seen_top = set()
for line_number, line in enumerate(text.splitlines(), start=1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if "\t" in line:
        raise SystemExit(f"tabs are not allowed at line {line_number}")
    if not line.startswith(" "):
        item = re.match(r"^([A-Za-z0-9_-]+):(?:\s.*)?$", line)
        if not item:
            raise SystemExit(f"invalid top-level YAML entry at line {line_number}")
        key = item.group(1)
        if key not in allowed_top:
            raise SystemExit(f"unsupported openai.yaml top-level key: {key}")
        seen_top.add(key)
if not seen_top:
    raise SystemExit("openai.yaml must contain at least one supported top-level section")
' "$openai_yaml" 2>&1)"; then
    record_failure "$context" "$output" "$(relative_to_root "$openai_yaml")"
    ok=false
  fi

  [[ "$ok" == true ]]
}

validate_skill_anatomy() {
  local manifest_path="$1"
  local context="$2"
  local expected_name="$3"
  local abs_path="$4"
  local skill_md="$abs_path/SKILL.md"
  local root_entry=""
  local root_name=""
  local line_total=0
  local ok=true

  if [[ "$(basename "$manifest_path")" != "$expected_name" ]]; then
    record_failure "$context" "folder name does not match manifest skill name" "$manifest_path"
    ok=false
  fi

  if [[ ! -f "$skill_md" ]]; then
    record_failure "$context" "missing SKILL.md" "$manifest_path/SKILL.md"
    return 1
  fi

  line_total="$(line_count "$skill_md")"
  if (( line_total > 500 )); then
    record_failure "$context" "SKILL.md must stay under 500 lines" "$manifest_path/SKILL.md"
    ok=false
  fi

  validate_skill_frontmatter "$skill_md" "$expected_name" "$context" || ok=false
  validate_openai_yaml_if_present "$abs_path" "$context" || ok=false

  while IFS= read -r root_entry; do
    root_name="$(basename "$root_entry")"
    case "$root_name" in
      SKILL.md|agents|assets|references|scripts)
        ;;
      *)
        record_failure "$context" "unsupported skill root entry" "$manifest_path/$root_name"
        ok=false
        ;;
    esac
  done < <(find "$abs_path" -maxdepth 1 -mindepth 1 -print)

  [[ "$ok" == true ]]
}

write_hash_manifest() {
  local abs_dir="$1"
  local excludes_file="$2"
  local output_file="$3"
  local rel_file=""
  local digest=""

  (
    cd "$abs_dir"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r rel_file; do
      [[ -n "$rel_file" ]] || continue
      if grep -Fxq -- "$rel_file" "$excludes_file"; then
        continue
      fi
      digest="$(hash_file "$rel_file")"
      printf '%s  %s\n' "$digest" "$rel_file"
    done
  ) >"$output_file"
}

validate_manifest() {
  [[ -r "$MANIFEST_PATH" ]] || die "missing skill projection manifest: $MANIFEST_PATH"
  jq empty "$MANIFEST_PATH" >/dev/null || die "invalid skill projection manifest JSON: $MANIFEST_PATH"
  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def string_array:
      type == "array" and all(.[]; non_empty_string);
    def unique_array:
      length == (unique | length);
    def safe_relative_path:
      non_empty_string
      and (startswith("/") | not)
      and (contains("\n") | not)
      and (split("/") | all(. != "" and . != "." and . != ".."));
    def codex_install_path($name):
      . == ("$CODEX_HOME/skills/" + $name);
    def safe_projection_path($name):
      safe_relative_path or codex_install_path($name);

    type == "object"
    and (.schema_version == 2)
    and (.canonical_root == ".agent/skills")
    and (.loader_contract | type == "object")
    and (.loader_contract.required_file == "SKILL.md")
    and (.loader_contract.allowed_frontmatter_keys == ["name", "description"])
    and (.loader_contract.allowed_root_entries == ["SKILL.md", "agents", "assets", "references", "scripts"])
    and (.skills | type == "array" and length > 0)
    and ((.skills | map(.name) | unique | length) == (.skills | length))
    and (
      .canonical_root as $canonical_root
      | all(.skills[];
          .name as $skill_name |
          (.name | non_empty_string and test("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$") and (contains("--") | not))
          and (.canonical_source | type == "object")
          and (.canonical_source.path == ($canonical_root + "/" + .name))
          and (.canonical_source.path | safe_relative_path)
          and (.projections | type == "array" and length > 0)
          and ((.projections | map(.provider) | unique | length) == (.projections | length))
          and ((.projections | map(.provider) | sort) == ["claude", "codex-generated", "codex-installed"])
          and all(.projections[];
              (.provider | non_empty_string and test("^[A-Za-z0-9._-]+$"))
              and (.path | safe_projection_path($skill_name))
              and (.projection_kind == "byte-for-byte")
              and (.excluded_generated_metadata | string_array and unique_array)
              and all(.excluded_generated_metadata[]; safe_relative_path)
              and (.activation | type == "object")
              and (.activation.status | IN("project-local-active", "install-required", "installed-active"))
              and (.activation.auto_discoverable | type == "boolean")
              and (.activation.install_target | non_empty_string)
              and (.activation.note | non_empty_string)
              and (
                if .provider == "claude" then
                  (.path == (".claude/skills/" + $skill_name))
                elif .provider == "codex-generated" then
                  (.path == (".agent/generated/skills/codex/" + $skill_name))
                elif .provider == "codex-installed" then
                  (.path == ("$CODEX_HOME/skills/" + $skill_name))
                  and (.activation.install_target == .path)
                else false end
              )
          )
      )
    )
  ' "$MANIFEST_PATH" >/dev/null || die "invalid skill projection manifest schema: $MANIFEST_PATH"
}

validate_shared_sync_manifest() {
  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def string_array:
      type == "array" and all(.[]; non_empty_string);
    def unique_array:
      length == (unique | length);
    def safe_relative_path:
      non_empty_string
      and (startswith("/") | not)
      and (contains("\n") | not)
      and (split("/") | all(. != "" and . != "." and . != ".."));
    def codex_install_path($package):
      . == ("$CODEX_HOME/skills/" + $package);

    (.shared_skill_sync // []) as $sync |
    ($sync | type == "array")
    and (($sync | map(.package) | unique | length) == ($sync | length))
    and all($sync[];
      . as $entry |
      ($entry.package | non_empty_string and test("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$") and (contains("--") | not))
      and ($entry.skill_name | non_empty_string and test("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$") and (contains("--") | not))
      and ($entry.source_path | safe_relative_path)
      and ($entry.source_path == (".claude/skills/" + $entry.package))
      and ($entry.projections | type == "array" and length > 0)
      and (($entry.projections | map(.provider) | unique | length) == ($entry.projections | length))
      and all($entry.projections[];
        (.provider == "codex-installed")
        and (.path | codex_install_path($entry.package))
        and (.projection_kind == "byte-for-byte")
        and (.excluded_generated_metadata | string_array and unique_array)
        and all(.excluded_generated_metadata[]; safe_relative_path)
      )
    )
  ' "$MANIFEST_PATH" >/dev/null || die "invalid shared skill sync manifest schema: $MANIFEST_PATH"
}

check_activation_contract() {
  local skill="$1"
  local provider="$2"
  local projection_rel="$3"
  local activation_status="$4"
  local auto_discoverable="$5"
  local install_target="$6"
  local context="projection:$skill:$provider"

  if [[ "$activation_status" == "install-required" ]]; then
    if [[ "$auto_discoverable" != "false" ]]; then
      record_failure "$context" "install-required projection cannot be auto-discoverable" "$projection_rel"
      return 1
    fi
  fi

  if [[ "$provider" == "codex-generated" && "$projection_rel" == .agent/generated/skills/codex/* && "$activation_status" != "install-required" ]]; then
    record_failure "$context" "repo-local generated Codex projection must declare install-required activation" "$projection_rel"
    return 1
  fi

  if [[ "$projection_rel" == .agent/generated/* && "$auto_discoverable" == "true" ]]; then
    record_failure "$context" "generated projection path cannot claim auto-discovery" "$projection_rel"
    return 1
  fi

  if [[ "$activation_status" == "project-local-active" && "$auto_discoverable" != "true" ]]; then
    record_failure "$context" "project-local-active projection must be auto-discoverable" "$projection_rel"
    return 1
  fi

  if [[ "$activation_status" == "installed-active" && "$auto_discoverable" != "true" ]]; then
    record_failure "$context" "installed-active projection must be auto-discoverable" "$projection_rel"
    return 1
  fi

  return 0
}

validate_shared_skill_tree() {
  local manifest_path="$1"
  local context="$2"
  local expected_skill_name="$3"
  local abs_path="$4"
  local skill_md="$abs_path/SKILL.md"
  local output=""

  check_tree_path "$manifest_path" "$context" "$abs_path" || return 1

  if [[ ! -f "$skill_md" ]]; then
    record_failure "$context" "missing SKILL.md" "$manifest_path/SKILL.md"
    return 1
  fi

  if output="$(python3 -c '
import re
import sys
from pathlib import Path

skill_md = Path(sys.argv[1])
expected_name = sys.argv[2]
text = skill_md.read_text(encoding="utf-8")
match = re.match(r"^---\n(.*?)\n---(?:\n|$)(.*)$", text, re.DOTALL)
if not match:
    raise SystemExit("missing or invalid YAML frontmatter")
frontmatter_text, body = match.groups()
frontmatter = {}
for line in frontmatter_text.splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line[:1].isspace():
        continue
    item = re.match(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*))?$", line)
    if item:
        frontmatter[item.group(1)] = (item.group(2) or "").strip().strip("\"").strip(chr(39))
actual_name = frontmatter.get("name")
if actual_name != expected_name:
    raise SystemExit(f"frontmatter name does not match expected skill: {actual_name} != {expected_name}")
if not frontmatter.get("description"):
    raise SystemExit("description must be non-empty")
if not body.strip():
    raise SystemExit("SKILL.md body must be non-empty")
' "$skill_md" "$expected_skill_name" 2>&1)"; then
    return 0
  fi

  record_failure "$context" "$output" "$(relative_to_root "$skill_md")"
  return 1
}

emit_json_report() {
  local status="$1"
  local manifest_display="$2"

  jq -n \
    --arg status "$status" \
    --arg manifest "$manifest_display" \
    --arg canonical_root "$CANONICAL_ROOT" \
    --slurpfile sources "$SOURCES_JSONL" \
    --slurpfile projections "$PROJECTIONS_JSONL" \
    --slurpfile failures "$FAILURES_JSONL" \
    --slurpfile warnings "$WARNINGS_JSONL" \
    --argjson allow_not_installed "$ALLOW_NOT_INSTALLED" \
    '{
      status: $status,
      mode: (if $allow_not_installed then "non-acceptance" else "acceptance" end),
      acceptance_eligible: (($status == "PASS") and ($allow_not_installed | not)),
      allow_not_installed: $allow_not_installed,
      manifest: $manifest,
      canonical_root: $canonical_root,
      sources: $sources,
      projections: $projections,
      failures: $failures,
      warnings: $warnings
    }'
}

emit_text_report() {
  local status="$1"

  if [[ "$status" == "PASS" || "$status" == "PASS_NON_ACCEPTANCE" ]]; then
    printf '%s: skill projection manifest schema\n' "$status"
    jq -r '"PASS: \(.skill) source \(.path) (\(.file_count) files)"' "$SOURCES_JSONL"
    jq -r '
      if .status == "SKIP_NOT_INSTALLED" then
        "SKIP: \(.skill) projection \(.provider) \(.path) not installed (non-acceptance mode)"
      else
        "PASS: \(.skill) projection \(.provider) \(.path) matches source (\(.file_count) files; kind=\(.projection_kind))"
      end
    ' "$PROJECTIONS_JSONL"
    jq -r '"WARN: \(.context): \(.message) \(.path)"' "$WARNINGS_JSONL"
    if [[ "$status" == "PASS_NON_ACCEPTANCE" ]]; then
      printf 'PASS_NON_ACCEPTANCE: skill projection check (--allow-not-installed; not acceptance eligible)\n'
    else
      printf 'PASS: skill projection check\n'
    fi
    return 0
  fi

  jq -r '"FAIL: \(.context): \(.message) \(.path)"' "$FAILURES_JSONL" >&2
}

run_check() {
  local manifest_display=""
  local skill_count=""
  local skill_index=""
  local projection_count=""
  local projection_index=""
  local skill_name=""
  local source_rel=""
  local source_abs=""
  local source_manifest=""
  local empty_excludes="$TMP_DIR/empty-excludes.txt"
  local source_ok=false
  local source_file_count=0
  local provider=""
  local projection_rel=""
  local projection_abs=""
  local projection_kind=""
  local activation_status=""
  local auto_discoverable=""
  local install_target=""
  local projection_manifest=""
  local excludes_file=""
  local excluded_count=0
  local projection_file_count=0
  local diff_file=""
  local projection_ok=false
  local status="PASS"
  local report_status="PASS"
  local sync_count=""
  local sync_index=""
  local sync_package=""
  local sync_skill_name=""
  local sync_source_rel=""
  local sync_source_abs=""
  local sync_source_manifest=""
  local sync_projection_count=""
  local sync_projection_index=""

  : >"$empty_excludes"
  manifest_display="$(relative_to_root "$MANIFEST_PATH")"
  skill_count="$(jq -r '.skills | length' "$MANIFEST_PATH")"

  for ((skill_index = 0; skill_index < skill_count; skill_index++)); do
    skill_name="$(jq -r ".skills[$skill_index].name" "$MANIFEST_PATH")"
    source_rel="$(jq -r ".skills[$skill_index].canonical_source.path" "$MANIFEST_PATH")"
    source_abs="$PROJECT_ROOT/$source_rel"
    source_manifest="$TMP_DIR/source-$skill_index.sha256"
    source_ok=false
    source_file_count=0

    if check_tree_path "$source_rel" "source:$skill_name" "$source_abs" \
      && validate_skill_anatomy "$source_rel" "source:$skill_name" "$skill_name" "$source_abs"; then
      write_hash_manifest "$source_abs" "$empty_excludes" "$source_manifest"
      source_file_count="$(line_count "$source_manifest")"
      record_source_result "$skill_name" "$source_rel" "PASS" "$source_file_count"
      source_ok=true
    else
      record_source_result "$skill_name" "$source_rel" "FAIL" 0
    fi

    projection_count="$(jq -r ".skills[$skill_index].projections | length" "$MANIFEST_PATH")"
    for ((projection_index = 0; projection_index < projection_count; projection_index++)); do
      provider="$(jq -r ".skills[$skill_index].projections[$projection_index].provider" "$MANIFEST_PATH")"
      projection_rel="$(jq -r ".skills[$skill_index].projections[$projection_index].path" "$MANIFEST_PATH")"
      projection_abs="$(resolve_manifest_path "$projection_rel")"
      projection_kind="$(jq -r ".skills[$skill_index].projections[$projection_index].projection_kind" "$MANIFEST_PATH")"
      activation_status="$(jq -r ".skills[$skill_index].projections[$projection_index].activation.status" "$MANIFEST_PATH")"
      auto_discoverable="$(jq -r ".skills[$skill_index].projections[$projection_index].activation.auto_discoverable" "$MANIFEST_PATH")"
      install_target="$(jq -r ".skills[$skill_index].projections[$projection_index].activation.install_target" "$MANIFEST_PATH")"
      projection_manifest="$TMP_DIR/projection-$skill_index-$projection_index.sha256"
      excludes_file="$TMP_DIR/excludes-$skill_index-$projection_index.txt"
      diff_file="$TMP_DIR/diff-$skill_index-$projection_index.txt"
      projection_file_count=0
      projection_ok=true

      jq -r ".skills[$skill_index].projections[$projection_index].excluded_generated_metadata[]" "$MANIFEST_PATH" >"$excludes_file"
      excluded_count="$(line_count "$excludes_file")"

      check_activation_contract "$skill_name" "$provider" "$projection_rel" "$activation_status" "$auto_discoverable" "$install_target" || projection_ok=false

      if [[ "$activation_status" == "installed-active" && ! -d "$projection_abs" && "$ALLOW_NOT_INSTALLED" == true ]]; then
        record_warning "projection:$skill_name:$provider" "installed Codex skill missing in non-acceptance allow-not-installed mode" "$projection_rel"
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "SKIP_NOT_INSTALLED" 0 "$excluded_count"
        continue
      fi

      if ! check_tree_path "$projection_rel" "projection:$skill_name:$provider" "$projection_abs"; then
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "FAIL" 0 "$excluded_count"
        continue
      fi

      validate_skill_anatomy "$projection_rel" "projection:$skill_name:$provider" "$skill_name" "$projection_abs" || projection_ok=false

      if [[ "$projection_ok" != true ]]; then
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "FAIL" 0 "$excluded_count"
        continue
      fi

      write_hash_manifest "$projection_abs" "$excludes_file" "$projection_manifest"
      projection_file_count="$(line_count "$projection_manifest")"

      if [[ "$source_ok" != true ]]; then
        record_failure "projection:$skill_name:$provider" "source unavailable for equivalence check" "$source_rel"
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "FAIL" "$projection_file_count" "$excluded_count"
        continue
      fi

      if diff -u "$source_manifest" "$projection_manifest" >"$diff_file"; then
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "PASS" "$projection_file_count" "$excluded_count"
      else
        record_failure "projection:$skill_name:$provider" "inventory/hash mismatch" "$projection_rel"
        record_projection_result "$skill_name" "$provider" "$projection_rel" "$projection_kind" "$activation_status" "$auto_discoverable" "$install_target" "FAIL" "$projection_file_count" "$excluded_count"
      fi
    done
  done

  sync_count="$(jq -r '(.shared_skill_sync // []) | length' "$MANIFEST_PATH")"
  for ((sync_index = 0; sync_index < sync_count; sync_index++)); do
    sync_package="$(jq -r ".shared_skill_sync[$sync_index].package" "$MANIFEST_PATH")"
    sync_skill_name="$(jq -r ".shared_skill_sync[$sync_index].skill_name" "$MANIFEST_PATH")"
    sync_source_rel="$(jq -r ".shared_skill_sync[$sync_index].source_path" "$MANIFEST_PATH")"
    sync_source_abs="$PROJECT_ROOT/$sync_source_rel"
    sync_source_manifest="$TMP_DIR/shared-source-$sync_index.sha256"
    source_ok=false
    source_file_count=0

    excludes_file="$TMP_DIR/shared-excludes-$sync_index.txt"
    jq -r ".shared_skill_sync[$sync_index].projections[0].excluded_generated_metadata[]" "$MANIFEST_PATH" >"$excludes_file"
    excluded_count="$(line_count "$excludes_file")"

    if validate_shared_skill_tree "$sync_source_rel" "shared-source:$sync_package" "$sync_skill_name" "$sync_source_abs"; then
      write_hash_manifest "$sync_source_abs" "$excludes_file" "$sync_source_manifest"
      source_file_count="$(line_count "$sync_source_manifest")"
      record_source_result "$sync_package" "$sync_source_rel" "PASS" "$source_file_count"
      source_ok=true
    else
      record_source_result "$sync_package" "$sync_source_rel" "FAIL" 0
    fi

    sync_projection_count="$(jq -r ".shared_skill_sync[$sync_index].projections | length" "$MANIFEST_PATH")"
    for ((sync_projection_index = 0; sync_projection_index < sync_projection_count; sync_projection_index++)); do
      provider="$(jq -r ".shared_skill_sync[$sync_index].projections[$sync_projection_index].provider" "$MANIFEST_PATH")"
      projection_rel="$(jq -r ".shared_skill_sync[$sync_index].projections[$sync_projection_index].path" "$MANIFEST_PATH")"
      projection_abs="$(resolve_manifest_path "$projection_rel")"
      projection_kind="$(jq -r ".shared_skill_sync[$sync_index].projections[$sync_projection_index].projection_kind" "$MANIFEST_PATH")"
      projection_manifest="$TMP_DIR/shared-projection-$sync_index-$sync_projection_index.sha256"
      diff_file="$TMP_DIR/shared-diff-$sync_index-$sync_projection_index.txt"

      if [[ ! -d "$projection_abs" && "$ALLOW_NOT_INSTALLED" == true ]]; then
        record_warning "shared-projection:$sync_package:$provider" "installed Codex skill missing in non-acceptance allow-not-installed mode" "$projection_rel"
        record_projection_result "$sync_package" "$provider" "$projection_rel" "$projection_kind" "installed-active" true "$projection_rel" "SKIP_NOT_INSTALLED" 0 "$excluded_count"
        continue
      fi

      if ! validate_shared_skill_tree "$projection_rel" "shared-projection:$sync_package:$provider" "$sync_skill_name" "$projection_abs"; then
        record_projection_result "$sync_package" "$provider" "$projection_rel" "$projection_kind" "installed-active" true "$projection_rel" "FAIL" 0 "$excluded_count"
        continue
      fi

      write_hash_manifest "$projection_abs" "$excludes_file" "$projection_manifest"
      projection_file_count="$(line_count "$projection_manifest")"

      if [[ "$source_ok" != true ]]; then
        record_failure "shared-projection:$sync_package:$provider" "source unavailable for equivalence check" "$sync_source_rel"
        record_projection_result "$sync_package" "$provider" "$projection_rel" "$projection_kind" "installed-active" true "$projection_rel" "FAIL" "$projection_file_count" "$excluded_count"
        continue
      fi

      if diff -u "$sync_source_manifest" "$projection_manifest" >"$diff_file"; then
        record_projection_result "$sync_package" "$provider" "$projection_rel" "$projection_kind" "installed-active" true "$projection_rel" "PASS" "$projection_file_count" "$excluded_count"
      else
        record_failure "shared-projection:$sync_package:$provider" "inventory/hash mismatch" "$projection_rel"
        record_projection_result "$sync_package" "$provider" "$projection_rel" "$projection_kind" "installed-active" true "$projection_rel" "FAIL" "$projection_file_count" "$excluded_count"
      fi
    done
  done

  if [[ -s "$FAILURES_JSONL" ]]; then
    status="FAIL"
  fi

  report_status="$status"
  if [[ "$status" == "PASS" && "$ALLOW_NOT_INSTALLED" == true ]]; then
    report_status="PASS_NON_ACCEPTANCE"
  fi

  if [[ "$OUTPUT_JSON" == true ]]; then
    emit_json_report "$report_status" "$manifest_display"
  else
    emit_text_report "$report_status"
  fi

  if [[ "$status" == "PASS" ]]; then
    return 0
  fi
  return 1
}

CHECK=false
OUTPUT_JSON=false
ALLOW_NOT_INSTALLED=false
PROJECT_ROOT="$DEFAULT_PROJECT_ROOT"
CODEX_SKILLS_ROOT="${CODEX_HOME:-$HOME/.codex}/skills"
MANIFEST_ARG=""
TMP_DIR=""
SOURCES_JSONL=""
PROJECTIONS_JSONL=""
FAILURES_JSONL=""
WARNINGS_JSONL=""
CANONICAL_ROOT=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=true
      shift
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --allow-not-installed)
      ALLOW_NOT_INSTALLED=true
      shift
      ;;
    --manifest)
      [[ "$#" -ge 2 ]] || die "--manifest requires a value"
      MANIFEST_ARG="$2"
      shift 2
      ;;
    --root)
      [[ "$#" -ge 2 ]] || die "--root requires a value"
      PROJECT_ROOT="$(cd "$2" && pwd -P)"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$CHECK" == true ]] || die "--check is required"
require_cmd jq
require_cmd find
require_cmd sed
require_cmd awk
require_cmd python3

if [[ -d "$CODEX_SKILLS_ROOT" ]]; then
  CODEX_SKILLS_ROOT="$(cd "$CODEX_SKILLS_ROOT" && pwd -P)"
fi

if [[ -z "$MANIFEST_ARG" ]]; then
  MANIFEST_PATH="$PROJECT_ROOT/$DEFAULT_MANIFEST_REL"
else
  case "$MANIFEST_ARG" in
    /*) MANIFEST_PATH="$MANIFEST_ARG" ;;
    *) MANIFEST_PATH="$PROJECT_ROOT/$MANIFEST_ARG" ;;
  esac
fi

validate_manifest
validate_shared_sync_manifest
CANONICAL_ROOT="$(jq -r '.canonical_root' "$MANIFEST_PATH")"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-skill-projection.XXXXXX")"
SOURCES_JSONL="$TMP_DIR/sources.jsonl"
PROJECTIONS_JSONL="$TMP_DIR/projections.jsonl"
FAILURES_JSONL="$TMP_DIR/failures.jsonl"
WARNINGS_JSONL="$TMP_DIR/warnings.jsonl"
: >"$SOURCES_JSONL"
: >"$PROJECTIONS_JSONL"
: >"$FAILURES_JSONL"
: >"$WARNINGS_JSONL"
trap cleanup_tmp_dir EXIT

run_check
