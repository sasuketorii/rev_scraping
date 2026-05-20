#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-skill-projection.sh"
TMP_ROOT=""

on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local command="${BASH_COMMAND:-unknown}"

  printf 'FAIL: unexpected error at line %s: %s (rc=%s)\n' "$line" "$command" "$rc" >&2
  exit "$rc"
}
trap on_err ERR

cleanup() {
  local rc=$?

  rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]]
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

setup_fixture() {
  local root="$1"
  shift || true
  local skip_claude=false
  local skip_claude_skill_md=false
  local skip_generated=false
  local skip_installed=false
  local option=""

  for option in "$@"; do
    case "$option" in
      skip-claude) skip_claude=true ;;
      skip-claude-skill-md) skip_claude_skill_md=true ;;
      skip-generated) skip_generated=true ;;
      skip-installed) skip_installed=true ;;
      *) fail "unknown setup_fixture option: $option" ;;
    esac
  done

  mkdir -p \
    "$root/.agent/registry" \
    "$root/.agent/skills/example-skill/references" \
    "$root/.claude" \
    "$root/.agent/generated/skills/codex" \
    "$root/codex-home/skills"

  printf '%s\n' '---' 'name: example-skill' 'description: Example loader-compliant skill.' '---' '# Example Skill' \
    >"$root/.agent/skills/example-skill/SKILL.md"
  printf '%s\n' 'reference body' \
    >"$root/.agent/skills/example-skill/references/reference.md"

  if [[ "$skip_claude" != true ]]; then
    mkdir -p "$root/.claude/skills"
    if [[ "$skip_claude_skill_md" == true ]]; then
      mkdir -p "$root/.claude/skills/example-skill/references"
      cp "$root/.agent/skills/example-skill/references/reference.md" \
        "$root/.claude/skills/example-skill/references/reference.md"
    else
      cp -R "$root/.agent/skills/example-skill" "$root/.claude/skills/example-skill"
    fi
  fi
  if [[ "$skip_generated" != true ]]; then
    cp -R "$root/.agent/skills/example-skill" "$root/.agent/generated/skills/codex/example-skill"
  fi
  if [[ "$skip_installed" != true ]]; then
    cp -R "$root/.agent/skills/example-skill" "$root/codex-home/skills/example-skill"
  fi

  printf '%s\n' \
    '{' \
    '  "schema_version": 2,' \
    '  "canonical_root": ".agent/skills",' \
    '  "loader_contract": {' \
    '    "required_file": "SKILL.md",' \
    '    "allowed_frontmatter_keys": ["name", "description"],' \
    '    "allowed_root_entries": ["SKILL.md", "agents", "assets", "references", "scripts"],' \
    '    "install_boundary": "Generated Codex projections are install-required unless installed into $CODEX_HOME/skills/<skill-name>."' \
    '  },' \
    '  "skills": [' \
    '    {' \
    '      "name": "example-skill",' \
    '      "canonical_source": {' \
    '        "path": ".agent/skills/example-skill",' \
    '        "role": "canonical-source"' \
    '      },' \
    '      "projections": [' \
    '        {' \
    '          "provider": "claude",' \
    '          "path": ".claude/skills/example-skill",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {' \
    '            "status": "project-local-active",' \
    '            "auto_discoverable": true,' \
    '            "install_target": ".claude/skills/example-skill",' \
    '            "note": "Claude project-local skill projection."' \
    '          }' \
    '        },' \
    '        {' \
    '          "provider": "codex-generated",' \
    '          "path": ".agent/generated/skills/codex/example-skill",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {' \
    '            "status": "install-required",' \
    '            "auto_discoverable": false,' \
    '            "install_target": "$CODEX_HOME/skills/example-skill",' \
    '            "note": "Generated Codex projection only."' \
    '          }' \
    '        },' \
    '        {' \
    '          "provider": "codex-installed",' \
    '          "path": "$CODEX_HOME/skills/example-skill",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {' \
    '            "status": "installed-active",' \
    '            "auto_discoverable": true,' \
    '            "install_target": "$CODEX_HOME/skills/example-skill",' \
    '            "note": "Actual Codex skill home projection."' \
    '          }' \
    '        }' \
    '      ]' \
    '    }' \
    '  ]' \
    '}' >"$root/.agent/registry/skill_projection_manifest.json"
}

run_checker_for_root() {
  local root="$1"
  shift

  CODEX_HOME="$root/codex-home" bash "$CHECKER" --root "$root" "$@"
}

test_current_rustskills_paths_pass() {
  local output=""

  output="$(cd "$PROJECT_ROOT" && bash "$CHECKER" --check --json)"

  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.mode' "acceptance"
  assert_json_field "$output" '.acceptance_eligible' "true"
  assert_json_field "$output" '.allow_not_installed' "false"
  assert_json_field "$output" '.canonical_root' ".agent/skills"
  assert_json_field "$output" '.sources[0].skill' "rustskills-architecture"
  assert_json_field "$output" '.projections | length' "15"
  assert_json_field "$output" '([.projections[] | select(.skill == "rustskills-architecture") | .provider] | sort | join(","))' "claude,codex-generated,codex-installed"
  assert_json_field "$output" 'all(.projections[]; .projection_kind == "byte-for-byte")' "true"
  assert_json_field "$output" '.projections[] | select(.skill == "rustskills-architecture" and .provider == "codex-generated") | .activation_status' "install-required"
  assert_json_field "$output" '.projections[] | select(.skill == "rustskills-architecture" and .provider == "codex-generated") | .auto_discoverable' "false"
  assert_json_field "$output" 'all(.projections[] | select(.provider == "codex-installed"); .activation_status == "installed-active")' "true"
  assert_json_field "$output" 'all(.projections[] | select(.provider == "codex-installed"); .auto_discoverable == true)' "true"
  assert_json_field "$output" '.warnings | length' "0"
}

test_fixture_passes_with_text_output() {
  local root="$TMP_ROOT/pass"
  local output=""

  setup_fixture "$root"
  output="$(run_checker_for_root "$root" --check)"

  contains "$output" "PASS: skill projection check" \
    || fail "text output should report pass"
  contains "$output" "PASS: example-skill projection claude" \
    || fail "text output should include claude projection"
  contains "$output" "PASS: example-skill projection codex" \
    || fail "text output should include codex projections"
  contains "$output" "PASS: example-skill projection codex-installed" \
    || fail "text output should include installed codex projection"
  [[ "$output" != *"WARN:"* ]] || fail "text output should not warn when installed projection is present"
}

test_fixture_mismatch_fails_closed() {
  local root="$TMP_ROOT/mismatch"
  local stdout_file="$TMP_ROOT/mismatch.out"
  local stderr_file="$TMP_ROOT/mismatch.err"

  setup_fixture "$root"
  printf '%s\n' 'projection drift' >>"$root/.claude/skills/example-skill/SKILL.md"

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "mismatched projection should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "mismatch failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "inventory/hash mismatch" \
    || fail "mismatch failure should explain inventory/hash mismatch"
  contains "$(cat "$stderr_file")" "projection:example-skill:claude" \
    || fail "mismatch failure should name the projection"
}

test_fixture_missing_projection_fails_closed() {
  local root="$TMP_ROOT/missing"
  local stdout_file="$TMP_ROOT/missing.out"
  local stderr_file="$TMP_ROOT/missing.err"

  setup_fixture "$root" skip-generated

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "missing projection should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "missing path failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "missing directory" \
    || fail "missing path failure should explain missing directory"
  contains "$(cat "$stderr_file")" ".agent/generated/skills/codex/example-skill" \
    || fail "missing path failure should name the missing path"
}

test_fixture_missing_skill_md_fails_closed() {
  local root="$TMP_ROOT/missing-skill-md"
  local stdout_file="$TMP_ROOT/missing-skill-md.out"
  local stderr_file="$TMP_ROOT/missing-skill-md.err"

  setup_fixture "$root" skip-claude-skill-md

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "missing SKILL.md should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "missing SKILL.md failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "missing SKILL.md" \
    || fail "missing SKILL.md failure should be explicit"
}

test_fixture_invalid_frontmatter_key_fails_closed() {
  local root="$TMP_ROOT/invalid-frontmatter-key"
  local stdout_file="$TMP_ROOT/invalid-frontmatter-key.out"
  local stderr_file="$TMP_ROOT/invalid-frontmatter-key.err"
  local skill_md=""

  setup_fixture "$root"
  for skill_md in \
    "$root/.agent/skills/example-skill/SKILL.md" \
    "$root/.claude/skills/example-skill/SKILL.md" \
    "$root/.agent/generated/skills/codex/example-skill/SKILL.md" \
    "$root/codex-home/skills/example-skill/SKILL.md"; do
    perl -0pi -e 's/description: Example loader-compliant skill\./description: Example loader-compliant skill.\nmetadata: unsupported/' "$skill_md"
  done

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "unsupported frontmatter key should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "frontmatter key failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "unsupported frontmatter key(s): metadata" \
    || fail "frontmatter key failure should name unsupported key"
}

test_fixture_invalid_frontmatter_yaml_fails_closed() {
  local root="$TMP_ROOT/invalid-frontmatter-yaml"
  local stdout_file="$TMP_ROOT/invalid-frontmatter-yaml.out"
  local stderr_file="$TMP_ROOT/invalid-frontmatter-yaml.err"
  local skill_md=""

  setup_fixture "$root"
  for skill_md in \
    "$root/.agent/skills/example-skill/SKILL.md" \
    "$root/.claude/skills/example-skill/SKILL.md" \
    "$root/.agent/generated/skills/codex/example-skill/SKILL.md" \
    "$root/codex-home/skills/example-skill/SKILL.md"; do
    perl -0pi -e 's/name: example-skill/name [example-skill]/' "$skill_md"
  done

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "invalid frontmatter YAML should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "frontmatter YAML failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "invalid YAML frontmatter entry" \
    || fail "frontmatter YAML failure should be explicit"
}

test_fixture_missing_description_fails_closed() {
  local root="$TMP_ROOT/missing-description"
  local stdout_file="$TMP_ROOT/missing-description.out"
  local stderr_file="$TMP_ROOT/missing-description.err"
  local skill_md=""

  setup_fixture "$root"
  for skill_md in \
    "$root/.agent/skills/example-skill/SKILL.md" \
    "$root/.claude/skills/example-skill/SKILL.md" \
    "$root/.agent/generated/skills/codex/example-skill/SKILL.md" \
    "$root/codex-home/skills/example-skill/SKILL.md"; do
    perl -0pi -e 's/description: Example loader-compliant skill\.\n//' "$skill_md"
  done

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "missing description should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "missing description failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "missing frontmatter key(s): description" \
    || fail "missing description failure should be explicit"
}

test_fixture_folder_name_mismatch_fails_closed() {
  local root="$TMP_ROOT/name-mismatch"
  local stdout_file="$TMP_ROOT/name-mismatch.out"
  local stderr_file="$TMP_ROOT/name-mismatch.err"
  local skill_md=""

  setup_fixture "$root"
  for skill_md in \
    "$root/.agent/skills/example-skill/SKILL.md" \
    "$root/.claude/skills/example-skill/SKILL.md" \
    "$root/.agent/generated/skills/codex/example-skill/SKILL.md" \
    "$root/codex-home/skills/example-skill/SKILL.md"; do
    perl -0pi -e 's/name: example-skill/name: other-skill/' "$skill_md"
  done

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "frontmatter/folder name mismatch should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "name mismatch failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "frontmatter name does not match folder" \
    || fail "name mismatch failure should be explicit"
}

test_fixture_unsupported_root_entry_fails_closed() {
  local root="$TMP_ROOT/unsupported-root-entry"
  local stdout_file="$TMP_ROOT/unsupported-root-entry.out"
  local stderr_file="$TMP_ROOT/unsupported-root-entry.err"
  local dir=""

  setup_fixture "$root"
  for dir in \
    "$root/.agent/skills/example-skill" \
    "$root/.claude/skills/example-skill" \
    "$root/.agent/generated/skills/codex/example-skill" \
    "$root/codex-home/skills/example-skill"; do
    printf '%s\n' '# Unsupported root README' >"$dir/README.md"
  done

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "unsupported skill root entry should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "unsupported root entry failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "unsupported skill root entry" \
    || fail "unsupported root entry failure should be explicit"
}

test_fixture_missing_installed_codex_fails_by_default() {
  local root="$TMP_ROOT/missing-installed-codex"
  local stdout_file="$TMP_ROOT/missing-installed-codex.out"
  local stderr_file="$TMP_ROOT/missing-installed-codex.err"

  setup_fixture "$root" skip-installed

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "missing installed Codex projection should fail by default"
  fi

  [[ ! -s "$stdout_file" ]] || fail "missing installed Codex failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "missing directory" \
    || fail "missing installed Codex failure should explain missing directory"
  contains "$(cat "$stderr_file")" '$CODEX_HOME/skills/example-skill' \
    || fail "missing installed Codex failure should name the install path"
}

test_fixture_missing_installed_codex_allow_mode_passes_with_warning() {
  local root="$TMP_ROOT/missing-installed-codex-allowed"
  local output=""

  setup_fixture "$root" skip-installed

  output="$(run_checker_for_root "$root" --check --allow-not-installed --json)"

  assert_json_field "$output" '.status' "PASS_NON_ACCEPTANCE"
  assert_json_field "$output" '.mode' "non-acceptance"
  assert_json_field "$output" '.acceptance_eligible' "false"
  assert_json_field "$output" '.allow_not_installed' "true"
  assert_json_field "$output" '.projections[] | select(.provider == "codex-installed") | .status' "SKIP_NOT_INSTALLED"
  assert_json_field "$output" '.warnings | length' "1"
}

test_fixture_generated_codex_active_claim_fails_closed() {
  local root="$TMP_ROOT/generated-codex-active"
  local stdout_file="$TMP_ROOT/generated-codex-active.out"
  local stderr_file="$TMP_ROOT/generated-codex-active.err"
  local manifest_tmp="$TMP_ROOT/generated-codex-active-manifest.json"

  setup_fixture "$root"
  jq '
    .skills[0].projections[1].activation.status = "project-local-active"
    | .skills[0].projections[1].activation.auto_discoverable = true
  ' "$root/.agent/registry/skill_projection_manifest.json" >"$manifest_tmp"
  mv "$manifest_tmp" "$root/.agent/registry/skill_projection_manifest.json"

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "generated Codex active claim should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "generated Codex active claim failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "repo-local generated Codex projection must declare install-required activation" \
    || fail "generated Codex active claim failure should be explicit"
}

test_fixture_symlink_component_fails_closed() {
  local root="$TMP_ROOT/symlink"
  local stdout_file="$TMP_ROOT/symlink.out"
  local stderr_file="$TMP_ROOT/symlink.err"

  setup_fixture "$root" skip-claude
  ln -s "$root/.agent/skills" "$root/.claude/skills"

  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "symlink path component should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "symlink failure should not write stdout in text mode"
  contains "$(cat "$stderr_file")" "symlink path component" \
    || fail "symlink failure should explain symlink path component"
}

test_missing_manifest_fails_closed() {
  local root="$TMP_ROOT/no-manifest"
  local stdout_file="$TMP_ROOT/no-manifest.out"
  local stderr_file="$TMP_ROOT/no-manifest.err"

  mkdir -p "$root"
  if run_checker_for_root "$root" --check >"$stdout_file" 2>"$stderr_file"; then
    fail "missing manifest should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "missing manifest should not write stdout"
  contains "$(cat "$stderr_file")" "missing skill projection manifest" \
    || fail "missing manifest failure should be explicit"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-skill-projection-test.XXXXXX")"

test_current_rustskills_paths_pass
test_fixture_passes_with_text_output
test_fixture_mismatch_fails_closed
test_fixture_missing_projection_fails_closed
test_fixture_missing_skill_md_fails_closed
test_fixture_invalid_frontmatter_key_fails_closed
test_fixture_invalid_frontmatter_yaml_fails_closed
test_fixture_missing_description_fails_closed
test_fixture_folder_name_mismatch_fails_closed
test_fixture_unsupported_root_entry_fails_closed
test_fixture_missing_installed_codex_fails_by_default
test_fixture_missing_installed_codex_allow_mode_passes_with_warning
test_fixture_generated_codex_active_claim_fails_closed
test_fixture_symlink_component_fails_closed
test_missing_manifest_fails_closed

printf 'PASS: rev_harness_skill_projection_test\n'
