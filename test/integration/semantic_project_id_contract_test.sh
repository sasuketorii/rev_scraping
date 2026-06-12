#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/.claude/commands/lib"
AUTO_ORCHESTRATE="$REPO_ROOT/.claude/commands/auto_orchestrate.sh"
TEST_PROMPT_DIR=""

TMP_INIT=""
TMP_RUNTIME=""
TMP_RUNTIME_DIAG=""
TMP_REVIEW=""
TMP_QUEUE=""
TMP_ADDON_OPTIN=""

cleanup() {
  rm -rf -- "${TMP_INIT:-}" "${TMP_RUNTIME:-}" "${TMP_RUNTIME_DIAG:-}" "${TMP_REVIEW:-}" "${TMP_QUEUE:-}" "${TMP_ADDON_OPTIN:-}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

prefer_allowlisted_node_runtime() {
  local candidate=""
  for candidate in \
    "$HOME"/.local/share/mise/installs/node/*/bin \
    "$HOME"/.mise/installs/node/*/bin; do
    [[ -x "$candidate/node" && ! -L "$candidate/node" ]] || continue
    PATH="$candidate:$PATH"
    export PATH
    return 0
  done
  return 0
}

prefer_allowlisted_node_runtime

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "missing expected text: $needle"
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "unexpected text present: $needle"
}

write_literal_file() {
  local path="$1"
  shift

  printf '%s\n' "$@" > "$path" || fail "failed to write fixture file: $path"
}

write_support_contract_fixture() {
  local path="$1"

  jq -n '{
    support_context_freshness: {
      resolver: "slice-b-test-fixture",
      current_plan_path: ".agent/active/plan.md",
      current_sow_path: ".agent/active/sow.md",
      project_context_path: ".agent/PROJECT_CONTEXT.md",
      support_read_order: [
        ".agent/PROJECT_CONTEXT.md"
      ],
      required_current_documents: [
        ".agent/PROJECT_CONTEXT.md"
      ],
      optional_handover: {
        present: false
      },
      freshness_expectations: {
        current_docs_must_match: true
      },
      evidence_only_patterns: [
        ".claude/tmp/**"
      ]
    }
  }' > "$path" || fail "failed to write support-context fixture: $path"
}

run_authoritative_project_id_probe() {
  bash -c 'set -u -o pipefail; source .claude/commands/auto_orchestrate.sh; set +e; _coordination_require_authoritative_project_id'
}

require_cmd git
require_cmd jq
require_cmd cargo
require_cmd node
require_cmd python3

real_allowlisted_node_binary() {
  local env_output=""
  env_output="$(
    /bin/bash "$REPO_ROOT/scripts/semantic-review-queue.sh" \
      __internal-runtime-env \
      --binary node \
      --repo-root "$REPO_ROOT"
  )" || fail "failed to resolve allowlisted node runtime from canonical helper"
  (
    eval "$env_output"
    printf '%s\n' "$RUNTIME_BINARY"
  )
}

real_allowlisted_node_dir() {
  dirname "$(real_allowlisted_node_binary)"
}

real_allowlisted_cargo_binary() {
  rustup which cargo
}

real_allowlisted_cargo_dir() {
  dirname "$(real_allowlisted_cargo_binary)"
}

repo_rust_workspace_root() {
  /bin/bash "$REPO_ROOT/scripts/semantic-review-queue.sh" __internal-rust-workspace-root --repo-root "$REPO_ROOT"
}

agent_core_manifest_path() {
  printf '%s\n' "$(repo_rust_workspace_root)/Cargo.toml"
}

build_agent_core_binary() {
  local target_dir="$1"
  local cargo_bin=""

  cargo_bin="$(command -v cargo)"
  /bin/rm -rf "$target_dir"
  /usr/bin/env -u RUSTC_WRAPPER \
    CARGO_TARGET_DIR="$target_dir" \
    "$cargo_bin" build --quiet --manifest-path "$(agent_core_manifest_path)" -p agent-core >/dev/null
  printf '%s\n' "$target_dir/debug/agent-core"
}

probe_removed_agent_core_project_id_exec_mcp_server_subcommand() {
  local agent_core_bin="$1"
  local repo_root="$2"
  shift 2 || true

  "$agent_core_bin" project-id exec-mcp-server --repo-root "$repo_root" -- "$@"
}

setup_native_layout_repo() {
  local repo_root="$1"

  mkdir -p "$repo_root/apps/web" "$repo_root/.agent"
  /bin/cp "$REPO_ROOT/.agent/PROJECT_CONTEXT.md" "$repo_root/.agent/PROJECT_CONTEXT.md"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name "Test User"
  git -C "$repo_root" config user.email "test@example.com"
  printf '%s\n' 'echo base' > "$repo_root/apps/web/app.sh"
  git -C "$repo_root" add apps/web/app.sh .agent/PROJECT_CONTEXT.md
  git -C "$repo_root" commit -qm "init"
}

copy_runtime_launcher_scripts() {
  local repo_root="$1"

  mkdir -p "$repo_root/scripts"
  /bin/cp "$REPO_ROOT/scripts/project-id.sh" "$repo_root/scripts/project-id.sh"
  /bin/cp "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$repo_root/scripts/resolve-semantic-project-id.sh"
  /bin/cp "$REPO_ROOT/scripts/semantic-review-queue.sh" "$repo_root/scripts/semantic-review-queue.sh"
  /bin/cp "$REPO_ROOT/scripts/launch-semantic-mcp.sh" "$repo_root/scripts/launch-semantic-mcp.sh"
  chmod +x \
    "$repo_root/scripts/project-id.sh" \
    "$repo_root/scripts/resolve-semantic-project-id.sh" \
    "$repo_root/scripts/semantic-review-queue.sh" \
    "$repo_root/scripts/launch-semantic-mcp.sh"
}

# NEGATIVE CONTROL: plant a fake Node entrypoint at the LEGACY location (the
# Node tree was removed in S3-B3). The launcher must NEVER execute it; tests
# assert this log is never written, proving the deleted Node path is dead.
write_runtime_node_entrypoint() {
  local repo_root="$1"
  local log_path="$repo_root/.runtime-node.log"

  mkdir -p "$repo_root/scripts/semantic-mcp-server/dist"
  write_literal_file "$repo_root/scripts/semantic-mcp-server/dist/index.js" \
    'const fs = require("fs");' \
    'const lines = [' \
    '  "args=" + process.argv.slice(1).join(" "),' \
    '  "node_options=" + (process.env.NODE_OPTIONS || ""),' \
    '];' \
    "fs.writeFileSync(\"${log_path}\", lines.join(\"\\\\n\") + \"\\\\n\");"
  printf '%s\n' "$log_path"
}

write_repo_local_rust_bridge_fixture_at() {
  local repo_root="$1"
  local relative_root="${2:-harness-rust}"
  local rust_root="$repo_root/$relative_root"

  mkdir -p "$rust_root/crates/semantic-mcp/src"
  write_literal_file "$rust_root/Cargo.toml" \
    '[workspace]' \
    'members = ["crates/semantic-mcp"]' \
    'resolver = "2"'
  write_literal_file "$rust_root/crates/semantic-mcp/Cargo.toml" \
    '[package]' \
    'name = "semantic-mcp"' \
    'version = "0.1.0"' \
    'edition = "2021"' \
    '' \
    '[[bin]]' \
    'name = "semantic-mcp"' \
    'path = "src/main.rs"'
  write_literal_file "$rust_root/crates/semantic-mcp/src/main.rs" \
    'use std::{env, process};' \
    '' \
    'fn main() {' \
    '    let mut args = env::args().skip(1);' \
    '    let flag = args.next();' \
    '    let project_id = args.next().unwrap_or_default();' \
    '    if flag.as_deref() != Some("--project-id") {' \
    '        eprintln!("[semantic-mcp-server] startup failed: missing --project-id");' \
    '        process::exit(1);' \
    '    }' \
    '' \
    '    eprintln!("[semantic-mcp-server] started project_id={project_id}");' \
    '}'
}

write_repo_local_rust_bridge_fixture() {
  local repo_root="$1"
  write_repo_local_rust_bridge_fixture_at "$repo_root" "harness-rust"
}

write_repo_local_rust_env_probe_fixture_at() {
  local repo_root="$1"
  local relative_root="${2:-harness-rust}"
  local rust_root="$repo_root/$relative_root"
  local log_path="$repo_root/.runtime-rust.log"

  mkdir -p "$rust_root/crates/semantic-mcp/src"
  write_literal_file "$rust_root/Cargo.toml" \
    '[workspace]' \
    'members = ["crates/semantic-mcp"]' \
    'resolver = "2"'
  write_literal_file "$rust_root/crates/semantic-mcp/Cargo.toml" \
    '[package]' \
    'name = "semantic-mcp"' \
    'version = "0.1.0"' \
    'edition = "2021"' \
    '' \
    '[[bin]]' \
    'name = "semantic-mcp"' \
    'path = "src/main.rs"'
  write_literal_file "$rust_root/crates/semantic-mcp/src/main.rs" \
    'use std::{env, fs, process};' \
    '' \
    'fn main() {' \
    '    let mut args = env::args().skip(1);' \
    '    let flag = args.next();' \
    '    let project_id = args.next().unwrap_or_default();' \
    '    if flag.as_deref() != Some("--project-id") {' \
    '        eprintln!("[semantic-mcp-server] startup failed: missing --project-id");' \
    '        process::exit(1);' \
    '    }' \
    '' \
    '    let rustc_wrapper = env::var("RUSTC_WRAPPER").unwrap_or_default();' \
    '    fs::write(' \
    "        \"${log_path}\"," \
    '        format!("project_id={project_id}\nrustc_wrapper={rustc_wrapper}\n"),' \
    '    )' \
    '    .unwrap();' \
    '}'
  printf '%s\n' "$log_path"
}

write_repo_local_rust_env_probe_fixture() {
  local repo_root="$1"
  write_repo_local_rust_env_probe_fixture_at "$repo_root" "harness-rust"
}

path_without_command_dir() {
  local cmd="$1"
  local cmd_path=""
  local cmd_dir=""
  local filtered=""
  local entry=""
  local -a path_entries=()

  cmd_path="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -n "$cmd_path" ]]; then
    cmd_dir="$(dirname "$cmd_path")"
  fi

  IFS=':' read -r -a path_entries < <(printf '%s\n' "$PATH")
  for entry in "${path_entries[@]}"; do
    [[ -n "$entry" ]] || continue
    if [[ -n "$cmd_dir" && "$entry" == "$cmd_dir" ]]; then
      continue
    fi
    filtered="${filtered:+$filtered:}$entry"
  done

  printf '%s\n' "$filtered"
}

write_hostile_path_binary() {
  local bin_dir="$1"
  local binary_name="$2"
  local message="$3"
  local marker_path="${bin_dir}/${binary_name}.marker"

  mkdir -p "$bin_dir"
  write_literal_file "$bin_dir/$binary_name" \
    '#!/bin/bash' \
    "echo \"$message\" >&2" \
    ": > \"$marker_path\"" \
    'exit 99'
  chmod +x "$bin_dir/$binary_name"
}

assert_hostile_path_binary_not_executed() {
  local bin_dir="$1"
  local binary_name="$2"
  [[ ! -e "$bin_dir/${binary_name}.marker" ]] || fail "hostile ${binary_name} binary executed unexpectedly"
}

write_forged_identity_root_fixture() {
  local mode="$1"
  local attacker_repo="$2"
  local victim_repo="$3"

  copy_runtime_launcher_scripts "$attacker_repo"
  case "$mode" in
    gitdir)
      printf 'gitdir: %s\n' "$victim_repo/.git" > "$attacker_repo/.git"
      ;;
    commondir)
      mkdir -p "$attacker_repo/.git"
      printf '%s\n' "$victim_repo/.git" > "$attacker_repo/.git/commondir"
      ;;
    *)
      fail "unsupported forged identity-root fixture mode: $mode"
      ;;
  esac
}

assert_forged_identity_root_rejected_across_surfaces() {
  local mode="$1"
  local tmpdir victim_repo attacker_repo victim_id queue_output_path
  local artifact_stderr read_stderr bootstrap_stderr resolver_stderr queue_stderr

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_forged_${mode}.XXXXXX")"
  victim_repo="$tmpdir/victim"
  attacker_repo="$tmpdir/attacker"
  queue_output_path="$tmpdir/queue.json"

  mkdir -p "$victim_repo" "$attacker_repo"
  copy_runtime_launcher_scripts "$victim_repo"
  setup_native_layout_repo "$victim_repo"
  git -C "$victim_repo" add scripts
  git -C "$victim_repo" commit -qm "add runtime helpers"
  victim_id="$(
    cd "$victim_repo" && \
    /bin/bash scripts/project-id.sh bootstrap VictimRepo
  )"

  write_forged_identity_root_fixture "$mode" "$attacker_repo" "$victim_repo"

  artifact_stderr="$tmpdir/${mode}.artifact-path.stderr"
  if (
    cd "$attacker_repo" && \
    /bin/bash scripts/project-id.sh artifact-path >"$tmpdir/${mode}.artifact-path.stdout" 2>"$artifact_stderr"
  ); then
    fail "forged ${mode} metadata should fail closed for artifact-path"
  fi
  assert_contains "linked worktree" "$(cat "$artifact_stderr")"

  read_stderr="$tmpdir/${mode}.read.stderr"
  if (
    cd "$attacker_repo" && \
    /bin/bash scripts/project-id.sh read >"$tmpdir/${mode}.read.stdout" 2>"$read_stderr"
  ); then
    fail "forged ${mode} metadata should fail closed for read"
  fi
  assert_contains "linked worktree" "$(cat "$read_stderr")"

  bootstrap_stderr="$tmpdir/${mode}.bootstrap.stderr"
  if (
    cd "$attacker_repo" && \
    /bin/bash scripts/project-id.sh bootstrap AttackerRepo >"$tmpdir/${mode}.bootstrap.stdout" 2>"$bootstrap_stderr"
  ); then
    fail "forged ${mode} metadata should fail closed for bootstrap"
  fi
  assert_contains "linked worktree" "$(cat "$bootstrap_stderr")"

  resolver_stderr="$tmpdir/${mode}.resolver.stderr"
  if (
    cd "$attacker_repo" && \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$attacker_repo" --print >"$tmpdir/${mode}.resolver.stdout" 2>"$resolver_stderr"
  ); then
    fail "forged ${mode} metadata should fail closed for resolver"
  fi
  assert_contains "linked worktree" "$(cat "$resolver_stderr")"

  queue_stderr="$tmpdir/${mode}.queue.stderr"
  if (
    cd "$attacker_repo" && \
    /bin/bash scripts/semantic-review-queue.sh export-json --repo-root "$attacker_repo" --output "$queue_output_path" >"$tmpdir/${mode}.queue.stdout" 2>"$queue_stderr"
  ); then
    fail "forged ${mode} metadata should fail closed for queue export-json"
  fi
  assert_contains "failed to resolve effective project_id" "$(cat "$queue_stderr")"
  assert_contains "linked worktree" "$(cat "$queue_stderr")"

  [[ ! -e "$queue_output_path" ]] || fail "queue export-json should not create output for forged ${mode} metadata"
  [[ "$(tr -d '\r\n' < "$victim_repo/.shared/project_id")" == "$victim_id" ]] \
    || fail "forged ${mode} metadata mutated victim project_id artifact"
  [[ ! -e "$attacker_repo/.shared/project_id" ]] \
    || fail "forged ${mode} metadata created attacker project_id artifact unexpectedly"

  /bin/rm -rf "$tmpdir"
}

test_prepare_coordination_blocks_before_native_product_artifacts_on_invalid_project_id() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root run_dir prep_out prep_rc
    local product_freshness_file preflight_file preflight_input_file support_contract_file
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_prepare.XXXXXX")"
    repo_root="$tmpdir/repo"
    run_dir="$tmpdir/run"

    mkdir -p "$repo_root/scripts" "$run_dir"
    /bin/cp "$REPO_ROOT/scripts/project-id.sh" "$repo_root/scripts/project-id.sh"
    /bin/cp "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$repo_root/scripts/resolve-semantic-project-id.sh"
    chmod +x "$repo_root/scripts/project-id.sh" "$repo_root/scripts/resolve-semantic-project-id.sh"

    setup_native_layout_repo "$repo_root"
    printf '%s\n' 'echo changed' > "$repo_root/apps/web/app.sh"
    mkdir -p "$repo_root/.shared"
    printf 'agent_base\n' > "$repo_root/.shared/project_id"

    REPO_ROOT="$repo_root"
    TMP_BASE="$repo_root/.claude/tmp"
    SRC_SYNC_FRESHNESS_FILE="$repo_root/.agent/context/product_surface_sync_freshness.json"
    PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$SRC_SYNC_FRESHNESS_FILE"
    CONTEXT_REPO_ROOT="$repo_root"
    CONTEXT_CONTEXT_DIR="$repo_root/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    CONTEXT_SRC_SYNC_FRESHNESS_FILE="$SRC_SYNC_FRESHNESS_FILE"
    CONTEXT_PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$SRC_SYNC_FRESHNESS_FILE"
    TREE_SITTER_AVAILABLE=false
    TREE_SITTER_CHECKED=true

    product_freshness_file="$SRC_SYNC_FRESHNESS_FILE"
    preflight_file="$run_dir/impl_coord_preflight.json"
    preflight_input_file="$run_dir/impl_coord_preflight_input.json"
    support_contract_file="$repo_root/.claude/tmp/support-green/task-contract.json"

    mkdir -p "$(dirname "$support_contract_file")"
    write_support_contract_fixture "$support_contract_file"

    printf '# plan\n' > "$run_dir/plan.md"
    state_init "$run_dir/plan.md" "semantic_project_id_native_product_guard" "$run_dir/state" >/dev/null
    state_upsert_phase "impl" 1
    state_set '.status' '"running"'
    state_set_phase_status "impl" "running"
    state_save

    prep_out="$(prepare_coordination_context "$run_dir" "impl" "task_semantic_project_id_native_product_guard" 2>&1)"
    prep_rc=$?

    if [[ "$prep_rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded with invalid authoritative project_id" >&2
      failed=1
    fi
    if [[ "$prep_out" != *"project_id"* ]]; then
      echo "detail: project_id block message missing from prepare_coordination_context output" >&2
      failed=1
    fi
    if [[ ! -f "$preflight_file" ]]; then
      echo "detail: fail-closed preflight artifact missing after authoritative project_id block" >&2
      failed=1
    fi
    if [[ -f "$preflight_input_file" ]]; then
      echo "detail: preflight input artifact should not exist when authoritative project_id blocks first" >&2
      failed=1
    fi
    if [[ -f "$product_freshness_file" ]]; then
      echo "detail: product-surface freshness artifact should not be written before authoritative project_id validation" >&2
      failed=1
    fi
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e '.error.code == "PREFLIGHT_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: state did not record PREFLIGHT_BLOCK for invalid authoritative project_id" >&2
      failed=1
    fi
    if [[ ! -f "$support_contract_file" ]]; then
      echo "detail: support-context fixture missing; guard separation assertion is invalid" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_common_root_helper_and_resolver_ignore_path_poisoned_git() {
  local tmpdir primary_repo secondary_repo primary_id helper_id resolver_id hostile_dir runtime_path
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_common_root.XXXXXX")"
  primary_repo="$tmpdir/primary"
  secondary_repo="$tmpdir/secondary"
  hostile_dir="$tmpdir/hostile-bin"
  runtime_path="$hostile_dir:$PATH"

  mkdir -p "$primary_repo"
  copy_runtime_launcher_scripts "$primary_repo"
  setup_native_layout_repo "$primary_repo"
  git -C "$primary_repo" add scripts
  git -C "$primary_repo" commit -qm "add runtime helpers"
  git -C "$primary_repo" worktree add -q "$secondary_repo" -b common-root-secondary

  primary_id="$(
    cd "$primary_repo" && \
    /bin/bash scripts/project-id.sh bootstrap CommonRoot
  )"
  mkdir -p "$secondary_repo/.shared"
  printf 'secondary-override\n' > "$secondary_repo/.shared/project_id"

  write_hostile_path_binary "$hostile_dir" git "fake git should not be executed"

  helper_id="$(
    cd "$secondary_repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$helper_id" == "$primary_id" ]] \
    || fail "project-id helper did not preserve the repo-local/common-root authoritative project_id under PATH-poisoned git"

  resolver_id="$(
    cd "$secondary_repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$secondary_repo" --print
  )"
  [[ "$resolver_id" == "$primary_id" ]] \
    || fail "semantic project_id resolver did not preserve the repo-local/common-root authoritative project_id under PATH-poisoned git"

  assert_hostile_path_binary_not_executed "$hostile_dir" git
  /bin/rm -rf "$tmpdir"
}

test_forged_external_gitdir_cannot_redirect_project_id_surfaces() {
  assert_forged_identity_root_rejected_across_surfaces gitdir
}

test_forged_external_commondir_cannot_redirect_project_id_surfaces() {
  assert_forged_identity_root_rejected_across_surfaces commondir
}

test_linked_worktree_bootstrap_and_read_preserve_common_identity_root() {
  local tmpdir primary_repo secondary_repo linked_id linked_read_id linked_artifact_path resolver_id

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_linked_worktree.XXXXXX")"
  primary_repo="$tmpdir/primary"
  secondary_repo="$tmpdir/secondary"

  mkdir -p "$primary_repo"
  primary_repo="$(cd "$primary_repo" && pwd -P)"
  copy_runtime_launcher_scripts "$primary_repo"
  setup_native_layout_repo "$primary_repo"
  git -C "$primary_repo" add scripts
  git -C "$primary_repo" commit -qm "add runtime helpers"
  git -C "$primary_repo" worktree add -q "$secondary_repo" -b linked-worktree-secondary
  secondary_repo="$(cd "$secondary_repo" && pwd -P)"

  linked_artifact_path="$(
    cd "$secondary_repo" && \
    /bin/bash scripts/project-id.sh artifact-path
  )"
  [[ "$linked_artifact_path" == "$primary_repo/.shared/project_id" ]] \
    || fail "linked worktree artifact-path did not resolve to the common identity root"

  linked_id="$(
    cd "$secondary_repo" && \
    /bin/bash scripts/project-id.sh bootstrap LinkedWorktree
  )"
  [[ "$linked_id" =~ ^linkedworktree-[a-f0-9]{12}$ ]] \
    || fail "linked worktree bootstrap produced unexpected project_id: $linked_id"
  [[ "$(tr -d '\r\n' < "$primary_repo/.shared/project_id")" == "$linked_id" ]] \
    || fail "linked worktree bootstrap did not persist to the common identity root"
  [[ ! -e "$secondary_repo/.shared/project_id" ]] \
    || fail "linked worktree bootstrap must not create a local override artifact"

  linked_read_id="$(
    cd "$secondary_repo" && \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$linked_read_id" == "$linked_id" ]] \
    || fail "linked worktree read did not return the authoritative common-root project_id"

  resolver_id="$(
    cd "$secondary_repo" && \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$secondary_repo" --print
  )"
  [[ "$resolver_id" == "$linked_id" ]] \
    || fail "linked worktree resolver did not preserve the authoritative common-root project_id"

  /bin/rm -rf "$tmpdir"
}

test_authoritative_project_id_read_ignores_path_poisoned_od() {
  local tmpdir repo project_id helper_id resolver_id hostile_dir runtime_path

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_od_guard.XXXXXX")"
  repo="$tmpdir/repo"
  hostile_dir="$tmpdir/hostile-bin"
  runtime_path="$hostile_dir:$PATH"

  mkdir -p "$repo"
  copy_runtime_launcher_scripts "$repo"
  setup_native_layout_repo "$repo"
  git -C "$repo" add scripts
  git -C "$repo" commit -qm "add runtime helpers"

  project_id="$(
    cd "$repo" && \
    /bin/bash scripts/project-id.sh bootstrap OdSafeRead
  )"

  write_hostile_path_binary "$hostile_dir" od "fake od should not be executed"

  helper_id="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$helper_id" == "$project_id" ]] \
    || fail "project-id helper did not preserve the authoritative project_id under PATH-poisoned od"

  resolver_id="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$repo" --print
  )"
  [[ "$resolver_id" == "$project_id" ]] \
    || fail "semantic project_id resolver did not preserve the authoritative project_id under PATH-poisoned od"

  assert_hostile_path_binary_not_executed "$hostile_dir" od
  /bin/rm -rf "$tmpdir"
}

test_authoritative_project_id_read_ignores_path_poisoned_dirname_and_basename() {
  local tmpdir repo project_id helper_id resolver_id hostile_dir runtime_path

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_split_guard.XXXXXX")"
  repo="$tmpdir/repo"
  hostile_dir="$tmpdir/hostile-bin"
  runtime_path="$hostile_dir:$PATH"

  mkdir -p "$repo"
  copy_runtime_launcher_scripts "$repo"
  setup_native_layout_repo "$repo"
  git -C "$repo" add scripts
  git -C "$repo" commit -qm "add runtime helpers"

  project_id="$(
    cd "$repo" && \
    /bin/bash scripts/project-id.sh bootstrap SplitSafeRead
  )"

  write_hostile_path_binary "$hostile_dir" dirname "fake dirname should not be executed"
  write_hostile_path_binary "$hostile_dir" basename "fake basename should not be executed"

  helper_id="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$helper_id" == "$project_id" ]] \
    || fail "project-id helper did not preserve the authoritative project_id under PATH-poisoned dirname/basename"

  resolver_id="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$repo" --print
  )"
  [[ "$resolver_id" == "$project_id" ]] \
    || fail "semantic project_id resolver did not preserve the authoritative project_id under PATH-poisoned dirname/basename"

  assert_hostile_path_binary_not_executed "$hostile_dir" dirname
  assert_hostile_path_binary_not_executed "$hostile_dir" basename
  /bin/rm -rf "$tmpdir"
}

test_bootstrap_write_path_ignores_path_poisoned_sanitize_and_write_helpers() {
  local tmpdir repo hostile_dir runtime_path bootstrap_id readback_id artifact_path binary_name

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_bootstrap_guard.XXXXXX")"
  repo="$tmpdir/repo"
  hostile_dir="$tmpdir/hostile-bin"
  runtime_path="$hostile_dir:$PATH"

  mkdir -p "$repo"
  copy_runtime_launcher_scripts "$repo"
  setup_native_layout_repo "$repo"
  git -C "$repo" add scripts
  git -C "$repo" commit -qm "add runtime helpers"

  for binary_name in tr sed mkdir mktemp chmod mv; do
    write_hostile_path_binary "$hostile_dir" "$binary_name" "fake ${binary_name} should not be executed"
  done

  bootstrap_id="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    /bin/bash scripts/project-id.sh bootstrap PoisonedRepo
  )"
  [[ "$bootstrap_id" =~ ^poisonedrepo-[a-f0-9]{12}$ ]] \
    || fail "project-id bootstrap did not preserve the authoritative project_id contract under PATH-poisoned sanitize/write helpers"

  readback_id="$(
    cd "$repo" && \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$readback_id" == "$bootstrap_id" ]] \
    || fail "project-id bootstrap did not durably persist the authoritative project_id under PATH-poisoned sanitize/write helpers"

  artifact_path="$(
    cd "$repo" && \
    /bin/bash scripts/project-id.sh artifact-path
  )"
  [[ -f "$artifact_path" ]] || fail "project-id bootstrap did not create the authoritative artifact under PATH-poisoned sanitize/write helpers"

  for binary_name in tr sed mkdir mktemp chmod mv; do
    assert_hostile_path_binary_not_executed "$hostile_dir" "$binary_name"
  done

  /bin/rm -rf "$tmpdir"
}

# helper: repo-local auto_orchestrate authority checks
TMP_QUEUE="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_queue.XXXXXX")"
QUEUE_REPO="$TMP_QUEUE/repo"
mkdir -p "$QUEUE_REPO/.claude/commands/lib" "$QUEUE_REPO/scripts" "$QUEUE_REPO/docs/prompts"
/bin/cp "$REPO_ROOT/.claude/commands/auto_orchestrate.sh" "$QUEUE_REPO/.claude/commands/auto_orchestrate.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/utils.sh" "$QUEUE_REPO/.claude/commands/lib/utils.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/state.sh" "$QUEUE_REPO/.claude/commands/lib/state.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/timeout.sh" "$QUEUE_REPO/.claude/commands/lib/timeout.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/session.sh" "$QUEUE_REPO/.claude/commands/lib/session.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/coder.sh" "$QUEUE_REPO/.claude/commands/lib/coder.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/reviewer.sh" "$QUEUE_REPO/.claude/commands/lib/reviewer.sh"
/bin/cp "$REPO_ROOT/.claude/commands/lib/orchestration_packet.sh" "$QUEUE_REPO/.claude/commands/lib/orchestration_packet.sh"
/bin/cp "$REPO_ROOT/scripts/project-id.sh" "$QUEUE_REPO/scripts/project-id.sh"
/bin/cp "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$QUEUE_REPO/scripts/resolve-semantic-project-id.sh"
chmod +x \
  "$QUEUE_REPO/.claude/commands/auto_orchestrate.sh" \
  "$QUEUE_REPO/scripts/project-id.sh" \
  "$QUEUE_REPO/scripts/resolve-semantic-project-id.sh"
printf '# reviewer batch template\n' > "$QUEUE_REPO/docs/prompts/reviewer_batch.md"

(
  cd "$QUEUE_REPO"
  git init -q

  mkdir -p .agent
  printf 'legacy-bypass\n' > .agent/project_id

  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --print \
    >"$TMP_QUEUE/legacy_print.stdout" 2>"$TMP_QUEUE/legacy_print.stderr"; then
    fail "canonical resolver should fail closed when only legacy .agent/project_id exists"
  fi
  assert_contains "missing project_id artifact" "$(cat "$TMP_QUEUE/legacy_print.stderr")"

  QUEUE_ID="$(bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --bootstrap QueueRepo)"
  [[ "$QUEUE_ID" =~ ^queuerepo-[a-f0-9]{12}$ ]] || fail "resolver bootstrap produced unexpected project_id: $QUEUE_ID"
  [[ "$(tr -d '\r\n' < .shared/project_id)" == "$QUEUE_ID" ]] \
    || fail "resolver bootstrap did not create canonical .shared/project_id"
  [[ "$(tr -d '\r\n' < .agent/project_id)" == "legacy-bypass" ]] \
    || fail "resolver bootstrap should not accept or rewrite legacy .agent/project_id"

  QUEUE_RESOLVED="$(
    SEMANTIC_PROJECT_ID="env-bypass" \
    SEMANTIC_MCP_PROJECT_ID="env-bypass-mcp" \
    run_authoritative_project_id_probe
  )"
  [[ "$QUEUE_RESOLVED" == "$QUEUE_ID" ]] || fail "auto_orchestrate queue authority should ignore env and legacy file bypasses"

  printf 'bad/id\n' > .shared/project_id
  if bash scripts/project-id.sh read \
    >"$TMP_QUEUE/invalid_helper.stdout" 2>"$TMP_QUEUE/invalid_helper.stderr"; then
    fail "canonical helper should fail closed for malformed project_id artifact"
  fi
  assert_contains "project_id must contain only letters, numbers, '_' or '-'" "$(cat "$TMP_QUEUE/invalid_helper.stderr")"

  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --print \
    >"$TMP_QUEUE/invalid_resolver.stdout" 2>"$TMP_QUEUE/invalid_resolver.stderr"; then
    fail "canonical resolver should fail closed for malformed project_id artifact"
  fi
  assert_contains "project_id must contain only letters, numbers, '_' or '-'" "$(cat "$TMP_QUEUE/invalid_resolver.stderr")"

  if run_authoritative_project_id_probe >"$TMP_QUEUE/invalid_queue.stdout" 2>"$TMP_QUEUE/invalid_queue.stderr"
  then
    fail "auto_orchestrate queue authority should fail closed for malformed project_id artifact"
  fi
  assert_contains "semantic project_id is unavailable" "$(cat "$TMP_QUEUE/invalid_queue.stderr")"

  printf 'abc\rdef\n' > .shared/project_id
  if bash scripts/project-id.sh read \
    >"$TMP_QUEUE/cr_embedded_helper.stdout" 2>"$TMP_QUEUE/cr_embedded_helper.stderr"; then
    fail "canonical helper should fail closed for embedded CR project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_QUEUE/cr_embedded_helper.stderr")"

  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --print \
    >"$TMP_QUEUE/cr_embedded_resolver.stdout" 2>"$TMP_QUEUE/cr_embedded_resolver.stderr"; then
    fail "canonical resolver should fail closed for embedded CR project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_QUEUE/cr_embedded_resolver.stderr")"

  if run_authoritative_project_id_probe >"$TMP_QUEUE/cr_embedded_queue.stdout" 2>"$TMP_QUEUE/cr_embedded_queue.stderr"
  then
    fail "auto_orchestrate queue authority should fail closed for embedded CR project_id artifact"
  fi
  assert_contains "semantic project_id is unavailable" "$(cat "$TMP_QUEUE/cr_embedded_queue.stderr")"

  printf 'valid-id\r\n' > .shared/project_id
  if bash scripts/project-id.sh read \
    >"$TMP_QUEUE/crlf_helper.stdout" 2>"$TMP_QUEUE/crlf_helper.stderr"; then
    fail "canonical helper should fail closed for CRLF project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_QUEUE/crlf_helper.stderr")"

  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --print \
    >"$TMP_QUEUE/crlf_resolver.stdout" 2>"$TMP_QUEUE/crlf_resolver.stderr"; then
    fail "canonical resolver should fail closed for CRLF project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_QUEUE/crlf_resolver.stderr")"

  if run_authoritative_project_id_probe >"$TMP_QUEUE/crlf_queue.stdout" 2>"$TMP_QUEUE/crlf_queue.stderr"
  then
    fail "auto_orchestrate queue authority should fail closed for CRLF project_id artifact"
  fi
  assert_contains "semantic project_id is unavailable" "$(cat "$TMP_QUEUE/crlf_queue.stderr")"
  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --health \
    >"$TMP_QUEUE/crlf_health.stdout" 2>"$TMP_QUEUE/crlf_health.stderr"; then
    fail "project_id health should fail closed for CRLF project_id artifact"
  fi
  jq -e '.classification == "block-authority-ambiguous" and .canonical.status == "invalid"' "$TMP_QUEUE/crlf_health.stdout" >/dev/null \
    || fail "project_id health should classify CRLF canonical artifact as invalid"

  printf '%s\n%s\n' "$QUEUE_ID" "second-line" > .shared/project_id
  if bash scripts/project-id.sh read \
    >"$TMP_QUEUE/multiline_helper.stdout" 2>"$TMP_QUEUE/multiline_helper.stderr"; then
    fail "canonical helper should fail closed for multiline project_id artifact"
  fi
  assert_contains "project_id artifact must contain exactly one logical line" "$(cat "$TMP_QUEUE/multiline_helper.stderr")"

  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --print \
    >"$TMP_QUEUE/multiline_resolver.stdout" 2>"$TMP_QUEUE/multiline_resolver.stderr"; then
    fail "canonical resolver should fail closed for multiline project_id artifact"
  fi
  assert_contains "project_id artifact must contain exactly one logical line" "$(cat "$TMP_QUEUE/multiline_resolver.stderr")"

  if run_authoritative_project_id_probe >"$TMP_QUEUE/multiline_queue.stdout" 2>"$TMP_QUEUE/multiline_queue.stderr"
  then
    fail "auto_orchestrate queue authority should fail closed for multiline project_id artifact"
  fi
  assert_contains "semantic project_id is unavailable" "$(cat "$TMP_QUEUE/multiline_queue.stderr")"
  if bash scripts/resolve-semantic-project-id.sh --repo-root "$QUEUE_REPO" --health \
    >"$TMP_QUEUE/multiline_health.stdout" 2>"$TMP_QUEUE/multiline_health.stderr"; then
    fail "project_id health should fail closed for multiline project_id artifact"
  fi
  jq -e '.classification == "block-authority-ambiguous" and .canonical.status == "invalid"' "$TMP_QUEUE/multiline_health.stdout" >/dev/null \
    || fail "project_id health should classify multiline canonical artifact as invalid"

  /bin/rm -f .shared/project_id
  if run_authoritative_project_id_probe >"$TMP_QUEUE/missing_queue.stdout" 2>"$TMP_QUEUE/missing_queue.stderr"
  then
    fail "auto_orchestrate queue authority should fail closed when canonical project_id artifact is missing"
  fi
  assert_contains "semantic project_id is unavailable" "$(cat "$TMP_QUEUE/missing_queue.stderr")"
)

test_prepare_coordination_blocks_before_native_product_artifacts_on_invalid_project_id \
  || fail "prepare_coordination_context should block before native-layout product artifacts when authoritative project_id is invalid"
test_common_root_helper_and_resolver_ignore_path_poisoned_git \
  || fail "common-root helper/resolver should ignore PATH-poisoned git and preserve authoritative project_id"
test_forged_external_gitdir_cannot_redirect_project_id_surfaces \
  || fail "forged external gitdir must fail closed across project-id, resolver, and queue surfaces"
test_forged_external_commondir_cannot_redirect_project_id_surfaces \
  || fail "forged external commondir must fail closed across project-id, resolver, and queue surfaces"
test_linked_worktree_bootstrap_and_read_preserve_common_identity_root \
  || fail "legitimate linked worktree must preserve common-root project_id bootstrap/read behavior"
test_authoritative_project_id_read_ignores_path_poisoned_od \
  || fail "authoritative project_id helper/resolver should not execute PATH-poisoned od during validation"
test_authoritative_project_id_read_ignores_path_poisoned_dirname_and_basename \
  || fail "authoritative project_id helper/resolver should not execute PATH-poisoned dirname or basename during validation"
test_bootstrap_write_path_ignores_path_poisoned_sanitize_and_write_helpers \
  || fail "authoritative project_id bootstrap/write should not execute PATH-poisoned tr/sed/mkdir/mktemp/chmod/mv"

# 0. canonical project-id wrapper preserves contract under runtime/env poisoning.
TMP_CANONICAL="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_canonical.XXXXXX")"
CANONICAL_REPO="$TMP_CANONICAL/repo"
mkdir -p "$CANONICAL_REPO"
CANONICAL_REPO="$(cd "$CANONICAL_REPO" && pwd -P)"

(
  cd "$CANONICAL_REPO"
  git init -q

  CANONICAL_ID="$(PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" bootstrap CanonicalRust)"
  [[ "$CANONICAL_ID" =~ ^canonicalrust-[a-f0-9]{12}$ ]] || fail "unexpected canonical wrapper project_id: $CANONICAL_ID"

  CANONICAL_ARTIFACT_PATH="$(PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" artifact-path)"
  [[ "$CANONICAL_ARTIFACT_PATH" == "$CANONICAL_REPO/.shared/project_id" ]] \
    || fail "canonical wrapper artifact path mismatch: $CANONICAL_ARTIFACT_PATH"
  [[ "$(tr -d '\r\n' < "$CANONICAL_ARTIFACT_PATH")" == "$CANONICAL_ID" ]] \
    || fail "canonical wrapper artifact content mismatch"

  CANONICAL_READ_ID="$(PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" read)"
  [[ "$CANONICAL_READ_ID" == "$CANONICAL_ID" ]] \
    || fail "canonical wrapper read did not round-trip project_id"

  CANONICAL_ENV_VICTIM="$TMP_CANONICAL/env-victim"
  mkdir -p "$CANONICAL_ENV_VICTIM"
  (
    cd "$CANONICAL_ENV_VICTIM"
    git init -q
  )
  CANONICAL_ENV_VICTIM_ID="$(
    PROJECT_ID_REPO_ROOT="$CANONICAL_ENV_VICTIM" \
      bash "$REPO_ROOT/scripts/project-id.sh" bootstrap EnvVictim
  )"
  [[ "$CANONICAL_ENV_VICTIM_ID" =~ ^envvictim-[a-f0-9]{12}$ ]] \
    || fail "unexpected env-victim project_id: $CANONICAL_ENV_VICTIM_ID"

  CANONICAL_ENV_ARTIFACT_PATH="$(
    GIT_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_COMMON_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_WORK_TREE="$CANONICAL_ENV_VICTIM" \
    PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" \
      bash "$REPO_ROOT/scripts/project-id.sh" artifact-path
  )"
  [[ "$CANONICAL_ENV_ARTIFACT_PATH" == "$CANONICAL_REPO/.shared/project_id" ]] \
    || fail "canonical wrapper artifact-path must ignore injected GIT_* identity overrides"

  CANONICAL_ENV_READ_ID="$(
    GIT_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_COMMON_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_WORK_TREE="$CANONICAL_ENV_VICTIM" \
    PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" \
      bash "$REPO_ROOT/scripts/project-id.sh" read
  )"
  [[ "$CANONICAL_ENV_READ_ID" == "$CANONICAL_ID" ]] \
    || fail "canonical wrapper read must ignore injected GIT_* identity overrides"

  CANONICAL_ENV_RESOLVER_ID="$(
    GIT_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_COMMON_DIR="$CANONICAL_ENV_VICTIM/.git" \
    GIT_WORK_TREE="$CANONICAL_ENV_VICTIM" \
      bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --print
  )"
  [[ "$CANONICAL_ENV_RESOLVER_ID" == "$CANONICAL_ID" ]] \
    || fail "canonical resolver must ignore injected GIT_* identity overrides"

  if command -v cargo >/dev/null 2>&1; then
    CANONICAL_PATH_POISON_DIR="$TMP_CANONICAL/path-poison-bin"
    CANONICAL_RUSTC_WRAPPER="$TMP_CANONICAL/rustc-wrapper.sh"
    CANONICAL_RUSTC_MARKER="$TMP_CANONICAL/rustc-wrapper.marker"
    CANONICAL_TARGET_DIR="$TMP_CANONICAL/cargo-target"
    mkdir -p "$CANONICAL_PATH_POISON_DIR"
    write_literal_file "$CANONICAL_PATH_POISON_DIR/cargo" \
      '#!/usr/bin/env bash' \
      ": > \"$CANONICAL_PATH_POISON_DIR/cargo.marker\"" \
      'exit 98'
    write_literal_file "$CANONICAL_RUSTC_WRAPPER" \
      '#!/usr/bin/env bash' \
      ": > \"$CANONICAL_RUSTC_MARKER\"" \
      'exit 97'
    chmod +x "$CANONICAL_PATH_POISON_DIR/cargo" "$CANONICAL_RUSTC_WRAPPER"

    PATH="$CANONICAL_PATH_POISON_DIR:$PATH" \
    PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" \
      bash "$REPO_ROOT/scripts/project-id.sh" artifact-path >/dev/null

    [[ ! -e "$CANONICAL_PATH_POISON_DIR/cargo.marker" ]] \
      || fail "canonical wrapper must not execute PATH-first cargo wrapper during artifact-path resolution"

    RUSTC_WRAPPER="$CANONICAL_RUSTC_WRAPPER" \
    CARGO_TARGET_DIR="$CANONICAL_TARGET_DIR" \
    PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" \
      bash "$REPO_ROOT/scripts/project-id.sh" artifact-path >/dev/null

    [[ ! -e "$CANONICAL_RUSTC_MARKER" ]] \
      || fail "canonical wrapper must not inherit caller RUSTC_WRAPPER during agent-core delegation"
    [[ ! -e "$CANONICAL_TARGET_DIR" ]] \
      || fail "canonical wrapper must not inherit caller CARGO_TARGET_DIR during agent-core delegation"
  fi

  printf 'bad/id\n' > "$CANONICAL_ARTIFACT_PATH"
  if PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" read \
    >"$TMP_CANONICAL/invalid_helper.stdout" 2>"$TMP_CANONICAL/invalid_helper.stderr"; then
    fail "canonical wrapper helper should fail closed for malformed project_id artifact"
  fi
  assert_contains "project_id must contain only letters, numbers, '_' or '-'" "$(cat "$TMP_CANONICAL/invalid_helper.stderr")"

  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --print \
    >"$TMP_CANONICAL/invalid_resolver.stdout" 2>"$TMP_CANONICAL/invalid_resolver.stderr"; then
    fail "canonical wrapper resolver should fail closed for malformed project_id artifact"
  fi
  assert_contains "project_id must contain only letters, numbers, '_' or '-'" "$(cat "$TMP_CANONICAL/invalid_resolver.stderr")"

  printf 'abc\rdef\n' > "$CANONICAL_ARTIFACT_PATH"
  if PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" read \
    >"$TMP_CANONICAL/cr_embedded_helper.stdout" 2>"$TMP_CANONICAL/cr_embedded_helper.stderr"; then
    fail "canonical wrapper helper should fail closed for embedded CR project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_CANONICAL/cr_embedded_helper.stderr")"

  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --print \
    >"$TMP_CANONICAL/cr_embedded_resolver.stdout" 2>"$TMP_CANONICAL/cr_embedded_resolver.stderr"; then
    fail "canonical wrapper resolver should fail closed for embedded CR project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_CANONICAL/cr_embedded_resolver.stderr")"

  printf 'valid-id\r\n' > "$CANONICAL_ARTIFACT_PATH"
  if PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" read \
    >"$TMP_CANONICAL/crlf_helper.stdout" 2>"$TMP_CANONICAL/crlf_helper.stderr"; then
    fail "canonical wrapper helper should fail closed for CRLF project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_CANONICAL/crlf_helper.stderr")"

  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --print \
    >"$TMP_CANONICAL/crlf_resolver.stdout" 2>"$TMP_CANONICAL/crlf_resolver.stderr"; then
    fail "canonical wrapper resolver should fail closed for CRLF project_id artifact"
  fi
  assert_contains "project_id artifact must not contain control bytes" "$(cat "$TMP_CANONICAL/crlf_resolver.stderr")"
  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --health \
    >"$TMP_CANONICAL/crlf_health.stdout" 2>"$TMP_CANONICAL/crlf_health.stderr"; then
    fail "canonical wrapper resolver health should fail closed for CRLF project_id artifact"
  fi
  jq -e '.classification == "block-authority-ambiguous" and .canonical.status == "invalid"' "$TMP_CANONICAL/crlf_health.stdout" >/dev/null \
    || fail "canonical wrapper resolver health should classify CRLF canonical artifact as invalid"

  printf '%s\n%s\n' "$CANONICAL_ID" "second-line" > "$CANONICAL_ARTIFACT_PATH"
  if PROJECT_ID_REPO_ROOT="$CANONICAL_REPO" bash "$REPO_ROOT/scripts/project-id.sh" read \
    >"$TMP_CANONICAL/multiline_helper.stdout" 2>"$TMP_CANONICAL/multiline_helper.stderr"; then
    fail "canonical wrapper helper should fail closed for multiline project_id artifact"
  fi
  assert_contains "project_id artifact must contain exactly one logical line" "$(cat "$TMP_CANONICAL/multiline_helper.stderr")"

  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --print \
    >"$TMP_CANONICAL/multiline_resolver.stdout" 2>"$TMP_CANONICAL/multiline_resolver.stderr"; then
    fail "canonical wrapper resolver should fail closed for multiline project_id artifact"
  fi
  assert_contains "project_id artifact must contain exactly one logical line" "$(cat "$TMP_CANONICAL/multiline_resolver.stderr")"
  if bash "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CANONICAL_REPO" --health \
    >"$TMP_CANONICAL/multiline_health.stdout" 2>"$TMP_CANONICAL/multiline_health.stderr"; then
    fail "canonical wrapper resolver health should fail closed for multiline project_id artifact"
  fi
  jq -e '.classification == "block-authority-ambiguous" and .canonical.status == "invalid"' "$TMP_CANONICAL/multiline_health.stdout" >/dev/null \
    || fail "canonical wrapper resolver health should classify multiline canonical artifact as invalid"
)

# 1. init-project bootstraps an immutable repo-local project_id artifact.
TMP_INIT="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_init.XXXXXX")"
INIT_REPO="$TMP_INIT/repo"
mkdir -p "$INIT_REPO/scripts"
/bin/cp "$REPO_ROOT/scripts/init-project.sh" "$INIT_REPO/scripts/init-project.sh"
/bin/cp "$REPO_ROOT/scripts/project-id.sh" "$INIT_REPO/scripts/project-id.sh"
/bin/cp "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$INIT_REPO/scripts/resolve-semantic-project-id.sh"
chmod +x \
  "$INIT_REPO/scripts/init-project.sh" \
  "$INIT_REPO/scripts/project-id.sh" \
  "$INIT_REPO/scripts/resolve-semantic-project-id.sh"

(
  cd "$INIT_REPO"
  git init -q
  bash scripts/init-project.sh DemoRepo >/dev/null
  INIT_ARTIFACT_PATH="$(bash scripts/project-id.sh artifact-path)"
  INIT_FIRST_ID="$(bash scripts/project-id.sh read)"
  [[ -f "$INIT_ARTIFACT_PATH" ]] || fail "project_id artifact was not created: $INIT_ARTIFACT_PATH"
  [[ "$INIT_FIRST_ID" =~ ^demorepo-[a-f0-9]{12}$ ]] || fail "unexpected bootstrap project_id: $INIT_FIRST_ID"

  bash scripts/init-project.sh OtherRepo >/dev/null
  INIT_SECOND_ID="$(bash scripts/project-id.sh read)"
  [[ "$INIT_FIRST_ID" == "$INIT_SECOND_ID" ]] || fail "project_id changed after second bootstrap"

  /bin/rm -rf "$INIT_REPO/.shared"
  mkdir -p "$TMP_INIT/escape-shared"
  ln -s "$TMP_INIT/escape-shared" "$INIT_REPO/.shared"
  if bash scripts/project-id.sh bootstrap EscapeRepo >"$TMP_INIT/symlink.stdout" 2>"$TMP_INIT/symlink.stderr"; then
    fail "project-id bootstrap should fail closed when artifact path contains a symlink"
  fi
  assert_contains "symlink component" "$(cat "$TMP_INIT/symlink.stderr")"
  [[ ! -e "$TMP_INIT/escape-shared/project_id" ]] || fail "project_id bootstrap escaped repo-local identity root via symlink"
)

# 2. runtime launch path derives project_id from the artifact and fails closed when missing.
TMP_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_runtime.XXXXXX")"
AGENT_CORE_BIN="$(build_agent_core_binary "$TMP_RUNTIME/agent-core-target")"
[[ -x "$AGENT_CORE_BIN" ]] || fail "agent-core binary not built: $AGENT_CORE_BIN"
NODE_RUNTIME_REPO="$TMP_RUNTIME/node-repo"
mkdir -p "$NODE_RUNTIME_REPO"
NODE_RUNTIME_REPO="$(cd "$NODE_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$NODE_RUNTIME_REPO"
NODE_RUNTIME_LOG="$(write_runtime_node_entrypoint "$NODE_RUNTIME_REPO")"
NODE_RUNTIME_PRELOAD="$TMP_RUNTIME/node-options-preload.js"
NODE_RUNTIME_PRELOAD_MARKER="$TMP_RUNTIME/node-options-preload.marker"
NODE_RUNTIME_HOSTILE_BIN="$TMP_RUNTIME/node-hostile-bin"
NODE_RUNTIME_ID_HOSTILE_BIN="$TMP_RUNTIME/node-id-hostile-bin"

write_literal_file "$NODE_RUNTIME_PRELOAD" \
  'const fs = require("fs");' \
  "fs.writeFileSync(\"${NODE_RUNTIME_PRELOAD_MARKER}\", \"poisoned\\n\");"
mkdir -p "$NODE_RUNTIME_HOSTILE_BIN"
write_literal_file "$NODE_RUNTIME_HOSTILE_BIN/node" \
  '#!/usr/bin/env bash' \
  ": > \"$NODE_RUNTIME_HOSTILE_BIN/node.marker\"" \
  'exit 99'
chmod +x "$NODE_RUNTIME_HOSTILE_BIN/node"
write_hostile_path_binary "$NODE_RUNTIME_ID_HOSTILE_BIN" id "fake id should not be executed"

HOSTILE_RUNTIME_REPO="$TMP_RUNTIME/hostile-repo"
mkdir -p "$HOSTILE_RUNTIME_REPO"
HOSTILE_RUNTIME_REPO="$(cd "$HOSTILE_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$HOSTILE_RUNTIME_REPO"
HOSTILE_RUNTIME_LOG="$(write_runtime_node_entrypoint "$HOSTILE_RUNTIME_REPO")"

ADOPTER_RUNTIME_HARNESS_REPO="$TMP_RUNTIME/adopter-harness-repo"
mkdir -p "$ADOPTER_RUNTIME_HARNESS_REPO"
ADOPTER_RUNTIME_HARNESS_REPO="$(cd "$ADOPTER_RUNTIME_HARNESS_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$ADOPTER_RUNTIME_HARNESS_REPO"
ADOPTER_RUNTIME_HARNESS_LOG="$(write_runtime_node_entrypoint "$ADOPTER_RUNTIME_HARNESS_REPO")"

ADOPTER_RUNTIME_REPO="$TMP_RUNTIME/adopter-repo"
mkdir -p "$ADOPTER_RUNTIME_REPO"
ADOPTER_RUNTIME_REPO="$(cd "$ADOPTER_RUNTIME_REPO" && pwd -P)"
setup_native_layout_repo "$ADOPTER_RUNTIME_REPO"

ADOPTER_CORRUPT_RUNTIME_REPO="$TMP_RUNTIME/adopter-corrupt-repo"
mkdir -p "$ADOPTER_CORRUPT_RUNTIME_REPO"
ADOPTER_CORRUPT_RUNTIME_REPO="$(cd "$ADOPTER_CORRUPT_RUNTIME_REPO" && pwd -P)"
setup_native_layout_repo "$ADOPTER_CORRUPT_RUNTIME_REPO"

ADOPTER_SAMEID_RUNTIME_REPO="$TMP_RUNTIME/adopter-sameid-repo"
mkdir -p "$ADOPTER_SAMEID_RUNTIME_REPO"
ADOPTER_SAMEID_RUNTIME_REPO="$(cd "$ADOPTER_SAMEID_RUNTIME_REPO" && pwd -P)"
setup_native_layout_repo "$ADOPTER_SAMEID_RUNTIME_REPO"

(
  cd "$NODE_RUNTIME_REPO"
  git init -q

  if bash scripts/project-id.sh read >"$TMP_RUNTIME/missing.stdout" 2>"$TMP_RUNTIME/missing.stderr"; then
    fail "project-id read should fail closed when artifact is missing"
  fi
  assert_contains "missing project_id artifact" "$(cat "$TMP_RUNTIME/missing.stderr")"

  RUNTIME_ID="$(bash scripts/project-id.sh bootstrap SampleRepo)"
  RUNTIME_ARTIFACT_PATH="$(bash scripts/project-id.sh artifact-path)"
  [[ -f "$RUNTIME_ARTIFACT_PATH" ]] || fail "artifact path missing after bootstrap: $RUNTIME_ARTIFACT_PATH"
  [[ "$RUNTIME_ID" =~ ^samplerepo-[a-f0-9]{12}$ ]] || fail "unexpected runtime project_id: $RUNTIME_ID"

  # S3-B3: the Node backend tree is deleted. The escape env
  # REV_HARNESS_ALLOW_NODE_SEMANTIC=1 is now a fail-closed no-op (it can no
  # longer resurrect the Node launcher). With no Rust workspace present, the
  # exec path must fail closed and never execute the planted Node entrypoint.
  set +e
  REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
  PATH="$NODE_RUNTIME_ID_HOSTILE_BIN:$(real_allowlisted_node_dir):/usr/bin:/bin" \
    bash scripts/project-id.sh exec-mcp-server extra --flag \
    >"$TMP_RUNTIME/node_escape_noop.stdout" \
    2>"$TMP_RUNTIME/node_escape_noop.stderr"
  node_escape_noop_rc=$?
  set -e
  [[ "$node_escape_noop_rc" -ne 0 ]] || fail "escape env must remain fail-closed (Node backend removed in S3)"
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/node_escape_noop.stderr")"
  [[ ! -e "$NODE_RUNTIME_LOG" ]] || fail "escape env must not resurrect the removed Node entrypoint"
  assert_hostile_path_binary_not_executed "$NODE_RUNTIME_ID_HOSTILE_BIN" id

  if SEMANTIC_PROJECT_ID_RESOLVER=/tmp/fake-resolver.sh \
    bash scripts/launch-semantic-mcp.sh >"$TMP_RUNTIME/resolver_escape.stdout" 2>"$TMP_RUNTIME/resolver_escape.stderr"; then
    fail "launch-semantic-mcp should reject resolver override env"
  fi
  assert_contains "SEMANTIC_PROJECT_ID_RESOLVER override is forbidden" "$(cat "$TMP_RUNTIME/resolver_escape.stderr")"

  if SEMANTIC_MCP_ENTRYPOINT=/tmp/fake-entry.js \
    bash scripts/launch-semantic-mcp.sh >"$TMP_RUNTIME/entry_escape.stdout" 2>"$TMP_RUNTIME/entry_escape.stderr"; then
    fail "launch-semantic-mcp should reject entrypoint override env"
  fi
  assert_contains "SEMANTIC_MCP_ENTRYPOINT override is forbidden" "$(cat "$TMP_RUNTIME/entry_escape.stderr")"

  if SEMANTIC_MCP_ENTRYPOINT=/tmp/fake-entry.js \
    bash scripts/project-id.sh exec-mcp-server >"$TMP_RUNTIME/helper_escape.stdout" 2>"$TMP_RUNTIME/helper_escape.stderr"; then
    fail "project-id exec-mcp-server should reject entrypoint override env"
  fi
  assert_contains "SEMANTIC_MCP_ENTRYPOINT override is forbidden" "$(cat "$TMP_RUNTIME/helper_escape.stderr")"

  (
    cd "$HOSTILE_RUNTIME_REPO"
    git init -q
    HOSTILE_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap ForeignRepo)"
    [[ "$HOSTILE_RUNTIME_ID" =~ ^foreignrepo-[a-f0-9]{12}$ ]] || fail "unexpected hostile runtime project_id: $HOSTILE_RUNTIME_ID"
  )

  if PROJECT_ID_REPO_ROOT="$HOSTILE_RUNTIME_REPO" \
    bash scripts/project-id.sh exec-mcp-server \
      >"$TMP_RUNTIME/hostile_bypass.stdout" \
      2>"$TMP_RUNTIME/hostile_bypass.stderr"; then
    fail "project-id exec-mcp-server should reject foreign PROJECT_ID_REPO_ROOT override"
  fi
  assert_contains "PROJECT_ID_REPO_ROOT override is forbidden for exec-mcp-server" "$(cat "$TMP_RUNTIME/hostile_bypass.stderr")"
  [[ ! -e "$HOSTILE_RUNTIME_LOG" ]] || fail "foreign runtime entrypoint executed through PROJECT_ID_REPO_ROOT bypass"

  # S3-B3: escape env + caller NODE_OPTIONS must still fail closed (Node tree
  # gone). The caller's NODE_OPTIONS preload must never be evaluated because no
  # node entrypoint is ever launched.
  set +e
  REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
  NODE_OPTIONS="--require $NODE_RUNTIME_PRELOAD" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/node_options_noop.stdout" \
    2>"$TMP_RUNTIME/node_options_noop.stderr"
  node_options_noop_rc=$?
  set -e
  [[ "$node_options_noop_rc" -ne 0 ]] || fail "escape env + NODE_OPTIONS must remain fail-closed (Node backend removed)"
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/node_options_noop.stderr")"
  [[ ! -e "$NODE_RUNTIME_LOG" ]] || fail "escape env must not resurrect the removed Node entrypoint"
  [[ ! -e "$NODE_RUNTIME_PRELOAD_MARKER" ]] || fail "fail-closed path must not evaluate caller NODE_OPTIONS"

  /bin/rm -f "$NODE_RUNTIME_LOG"
  if REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
    PATH="$NODE_RUNTIME_HOSTILE_BIN:$(real_allowlisted_node_dir):/usr/bin:/bin" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
      >"$TMP_RUNTIME/node_path_poison.stdout" \
      2>"$TMP_RUNTIME/node_path_poison.stderr"; then
    fail "escape env must fail closed even with a PATH-first hostile node wrapper"
  fi
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/node_path_poison.stderr")"
  [[ ! -e "$NODE_RUNTIME_LOG" ]] || fail "fail-closed path must not execute a repo-local node entrypoint"
  [[ ! -e "$NODE_RUNTIME_HOSTILE_BIN/node.marker" ]] || fail "fail-closed path must not execute a PATH-first hostile node wrapper"

  if NODE_OPTIONS="--require $NODE_RUNTIME_PRELOAD" \
      PATH="$NODE_RUNTIME_HOSTILE_BIN:$(real_allowlisted_node_dir):/usr/bin:/bin" \
      probe_removed_agent_core_project_id_exec_mcp_server_subcommand "$AGENT_CORE_BIN" "$NODE_RUNTIME_REPO" extra --flag \
      >"$TMP_RUNTIME/direct_cli_node.stdout" \
      2>"$TMP_RUNTIME/direct_cli_node.stderr"; then
    fail "direct Rust CLI exec-mcp-server should no longer be callable"
  fi
  assert_contains "unrecognized subcommand 'exec-mcp-server'" "$(cat "$TMP_RUNTIME/direct_cli_node.stderr")"
  [[ ! -e "$NODE_RUNTIME_LOG" ]] || fail "removed direct Rust CLI surface should not execute repo-local node entrypoint"
  [[ ! -e "$NODE_RUNTIME_PRELOAD_MARKER" ]] || fail "removed direct Rust CLI surface should not evaluate caller NODE_OPTIONS"
  [[ ! -e "$NODE_RUNTIME_HOSTILE_BIN/node.marker" ]] || fail "removed direct Rust CLI surface should not execute PATH-first hostile node wrapper"
)

# S3-B3: with the Rust workspace absent (helper __internal-rust-workspace-root
# returns 3), exec-mcp-server must fail closed in project-id.sh itself. The Node
# backend was removed, so the helper's former Node runtime path is never
# reached — the escape env is a fail-closed no-op with a clear message.
TMP_RUNTIME_DIAG="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_runtime_diag.XXXXXX")"
RUNTIME_DIAG_REPO="$TMP_RUNTIME_DIAG/repo"
mkdir -p "$RUNTIME_DIAG_REPO"
RUNTIME_DIAG_REPO="$(cd "$RUNTIME_DIAG_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$RUNTIME_DIAG_REPO"
write_runtime_node_entrypoint "$RUNTIME_DIAG_REPO" >/dev/null
write_literal_file "$RUNTIME_DIAG_REPO/scripts/semantic-review-queue.sh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  'case "${1:-}" in' \
  '  __internal-rust-workspace-root)' \
  '    exit 3' \
  '    ;;' \
  '  *)' \
  "    printf 'semantic-review-queue.sh: unexpected invocation: %s\\n' \"\$*\" >&2" \
  '    exit 92' \
  '    ;;' \
  'esac'
chmod +x "$RUNTIME_DIAG_REPO/scripts/semantic-review-queue.sh"

(
  cd "$RUNTIME_DIAG_REPO"
  git init -q
  bash scripts/project-id.sh bootstrap SampleRepo >/dev/null

  if REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
    bash scripts/project-id.sh exec-mcp-server \
      >"$TMP_RUNTIME_DIAG/runtime_diag.stdout" \
      2>"$TMP_RUNTIME_DIAG/runtime_diag.stderr"; then
    fail "project-id exec-mcp-server should fail closed when Rust workspace is absent"
  fi
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME_DIAG/runtime_diag.stderr")"
  assert_not_contains "unexpected invocation" "$(cat "$TMP_RUNTIME_DIAG/runtime_diag.stderr")"
)

NO_CARGO_RUNTIME_REPO="$TMP_RUNTIME/no-cargo-repo"
mkdir -p "$NO_CARGO_RUNTIME_REPO"
NO_CARGO_RUNTIME_REPO="$(cd "$NO_CARGO_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$NO_CARGO_RUNTIME_REPO"
NO_CARGO_RUNTIME_LOG="$(write_runtime_node_entrypoint "$NO_CARGO_RUNTIME_REPO")"
write_repo_local_rust_bridge_fixture "$NO_CARGO_RUNTIME_REPO"

PATH_WITHOUT_CARGO="$(real_allowlisted_node_dir):$(path_without_command_dir cargo)"

(
  cd "$NO_CARGO_RUNTIME_REPO"
  git init -q

  NO_CARGO_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap NoCargoRepo)"
  [[ "$NO_CARGO_RUNTIME_ID" =~ ^nocargorepo-[a-f0-9]{12}$ ]] || fail "unexpected no-cargo runtime project_id: $NO_CARGO_RUNTIME_ID"

  set +e
  PATH="$PATH_WITHOUT_CARGO" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/no_cargo_fail_closed.stdout" \
    2>"$TMP_RUNTIME/no_cargo_fail_closed.stderr"
  no_cargo_rc=$?
  set -e

  [[ "$no_cargo_rc" -ne 0 ]] || fail "no-cargo runtime should fail closed (Node backend removed in S3)"
  assert_contains "Rust semantic backend required" "$(cat "$TMP_RUNTIME/no_cargo_fail_closed.stderr")"
  [[ ! -e "$NO_CARGO_RUNTIME_LOG" ]] || fail "no-cargo runtime must not execute a Node entrypoint"

  # S3-B3: the Node tree is deleted; REV_HARNESS_ALLOW_NODE_SEMANTIC is now a
  # no-op and must still fail closed with a clear "Node backend removed" message.
  set +e
  REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
  PATH="$PATH_WITHOUT_CARGO" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/no_cargo_escape.stdout" \
    2>"$TMP_RUNTIME/no_cargo_escape.stderr"
  no_cargo_escape_rc=$?
  set -e
  [[ "$no_cargo_escape_rc" -ne 0 ]] || fail "escape env must remain fail-closed (Node backend removed)"
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/no_cargo_escape.stderr")"
  [[ ! -e "$NO_CARGO_RUNTIME_LOG" ]] || fail "escape env must not resurrect the removed Node entrypoint"
)

NO_RUST_RUNTIME_REPO="$TMP_RUNTIME/no-rust-repo"
mkdir -p "$NO_RUST_RUNTIME_REPO"
NO_RUST_RUNTIME_REPO="$(cd "$NO_RUST_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$NO_RUST_RUNTIME_REPO"
NO_RUST_RUNTIME_LOG="$(write_runtime_node_entrypoint "$NO_RUST_RUNTIME_REPO")"

(
  cd "$NO_RUST_RUNTIME_REPO"
  git init -q

  NO_RUST_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap NoRustRepo)"
  [[ "$NO_RUST_RUNTIME_ID" =~ ^norustrepo-[a-f0-9]{12}$ ]] || fail "unexpected no-rust runtime project_id: $NO_RUST_RUNTIME_ID"

  set +e
  PATH="$(real_allowlisted_node_dir):$(path_without_command_dir cargo)" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/no_rust_fail_closed.stdout" \
    2>"$TMP_RUNTIME/no_rust_fail_closed.stderr"
  no_rust_rc=$?
  set -e

  [[ "$no_rust_rc" -ne 0 ]] || fail "no-rust runtime should fail closed (Node backend removed in S3)"
  assert_contains "Rust semantic backend required" "$(cat "$TMP_RUNTIME/no_rust_fail_closed.stderr")"
  [[ ! -e "$NO_RUST_RUNTIME_LOG" ]] || fail "no-rust runtime must not execute a Node entrypoint"

  # S3-B3: escape env is a fail-closed no-op now that the Node tree is gone.
  set +e
  REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
  PATH="$(real_allowlisted_node_dir):$(path_without_command_dir cargo)" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/no_rust_escape.stdout" \
    2>"$TMP_RUNTIME/no_rust_escape.stderr"
  no_rust_escape_rc=$?
  set -e
  [[ "$no_rust_escape_rc" -ne 0 ]] || fail "escape env must remain fail-closed (Node backend removed)"
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/no_rust_escape.stderr")"
  [[ ! -e "$NO_RUST_RUNTIME_LOG" ]] || fail "escape env must not resurrect the removed Node entrypoint"
)

SYMLINK_RUNTIME_REPO="$TMP_RUNTIME/symlink-repo"
mkdir -p "$SYMLINK_RUNTIME_REPO"
SYMLINK_RUNTIME_REPO="$(cd "$SYMLINK_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$SYMLINK_RUNTIME_REPO"
SYMLINK_RUNTIME_LOG="$(write_runtime_node_entrypoint "$SYMLINK_RUNTIME_REPO")"
ln -s "$(repo_rust_workspace_root)" "$SYMLINK_RUNTIME_REPO/harness-rust"

SYMLINK_RUNTIME_BIN="$TMP_RUNTIME/symlink-bin"
SYMLINK_RUNTIME_CARGO_LOG="$TMP_RUNTIME/symlink_cargo.log"
mkdir -p "$SYMLINK_RUNTIME_BIN"
write_literal_file "$SYMLINK_RUNTIME_BIN/cargo" \
  '#!/usr/bin/env bash' \
  "printf '%s\\n' \"\$*\" >> \"\$SYMLINK_RUNTIME_CARGO_LOG\"" \
  'exit 97'
chmod +x "$SYMLINK_RUNTIME_BIN/cargo"

(
  cd "$SYMLINK_RUNTIME_REPO"
  git init -q

  SYMLINK_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap SymlinkRepo)"
  [[ "$SYMLINK_RUNTIME_ID" =~ ^symlinkrepo-[a-f0-9]{12}$ ]] || fail "unexpected symlink runtime project_id: $SYMLINK_RUNTIME_ID"

  set +e
  SYMLINK_RUNTIME_CARGO_LOG="$SYMLINK_RUNTIME_CARGO_LOG" \
  PATH="$(real_allowlisted_node_dir):$SYMLINK_RUNTIME_BIN:$(path_without_command_dir cargo)" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/symlink_runtime.stdout" \
    2>"$TMP_RUNTIME/symlink_runtime.stderr"
  symlink_rc=$?
  set -e

  [[ "$symlink_rc" -ne 0 ]] || fail "symlinked external rust workspace should fail closed"
  assert_contains "Rust workspace candidate must not be a symlink" "$(cat "$TMP_RUNTIME/symlink_runtime.stderr")"
  [[ ! -e "$SYMLINK_RUNTIME_LOG" ]] || fail "symlinked external rust workspace should not fall back to node"
  [[ ! -e "$SYMLINK_RUNTIME_CARGO_LOG" ]] || fail "symlinked external rust workspace should not execute cargo"
)

LEGACY_ONLY_RUNTIME_REPO="$TMP_RUNTIME/legacy-only-repo"
mkdir -p "$LEGACY_ONLY_RUNTIME_REPO"
LEGACY_ONLY_RUNTIME_REPO="$(cd "$LEGACY_ONLY_RUNTIME_REPO" && pwd -P)"
copy_runtime_launcher_scripts "$LEGACY_ONLY_RUNTIME_REPO"
LEGACY_ONLY_RUNTIME_LOG="$(write_runtime_node_entrypoint "$LEGACY_ONLY_RUNTIME_REPO")"
write_repo_local_rust_bridge_fixture_at "$LEGACY_ONLY_RUNTIME_REPO" "toRust-Idea/rust"

(
  cd "$LEGACY_ONLY_RUNTIME_REPO"
  git init -q

  LEGACY_ONLY_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap LegacyOnlyRepo)"
  [[ "$LEGACY_ONLY_RUNTIME_ID" =~ ^legacyonlyrepo-[a-f0-9]{12}$ ]] || fail "unexpected legacy-only runtime project_id: $LEGACY_ONLY_RUNTIME_ID"

  set +e
  PATH="$(real_allowlisted_node_dir):$(path_without_command_dir cargo)" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/legacy_only_fail_closed.stdout" \
    2>"$TMP_RUNTIME/legacy_only_fail_closed.stderr"
  legacy_only_rc=$?
  set -e

  [[ "$legacy_only_rc" -ne 0 ]] || fail "legacy-only runtime should fail closed (Node backend removed in S3)"
  assert_contains "Rust semantic backend required" "$(cat "$TMP_RUNTIME/legacy_only_fail_closed.stderr")"
  [[ ! -e "$LEGACY_ONLY_RUNTIME_LOG" ]] || fail "legacy-only runtime must not execute a Node entrypoint"

  # S3-B3: escape env is a fail-closed no-op now that the Node tree is gone.
  set +e
  REV_HARNESS_ALLOW_NODE_SEMANTIC=1 \
  PATH="$(real_allowlisted_node_dir):$(path_without_command_dir cargo)" \
    bash scripts/launch-semantic-mcp.sh extra --flag \
    >"$TMP_RUNTIME/legacy_only_escape.stdout" \
    2>"$TMP_RUNTIME/legacy_only_escape.stderr"
  legacy_only_escape_rc=$?
  set -e
  [[ "$legacy_only_escape_rc" -ne 0 ]] || fail "escape env must remain fail-closed (Node backend removed)"
  assert_contains "Node backend removed; Rust required" "$(cat "$TMP_RUNTIME/legacy_only_escape.stderr")"
  [[ ! -e "$LEGACY_ONLY_RUNTIME_LOG" ]] || fail "escape env must not resurrect the removed Node entrypoint"
)

if command -v cargo >/dev/null 2>&1; then
  RUST_RUNTIME_REPO="$TMP_RUNTIME/rust-repo"
  mkdir -p "$RUST_RUNTIME_REPO"
  RUST_RUNTIME_REPO="$(cd "$RUST_RUNTIME_REPO" && pwd -P)"
  copy_runtime_launcher_scripts "$RUST_RUNTIME_REPO"
  RUST_RUNTIME_LOG="$(write_repo_local_rust_env_probe_fixture "$RUST_RUNTIME_REPO")"
  RUST_RUNTIME_WRAPPER="$TMP_RUNTIME/rustc-wrapper.sh"
  RUST_RUNTIME_WRAPPER_MARKER="$TMP_RUNTIME/rustc-wrapper.marker"
  RUST_RUNTIME_HOSTILE_BIN="$TMP_RUNTIME/rust-hostile-bin"

  write_literal_file "$RUST_RUNTIME_WRAPPER" \
    '#!/usr/bin/env bash' \
    ": > \"$RUST_RUNTIME_WRAPPER_MARKER\"" \
    'exit 97'
  chmod +x "$RUST_RUNTIME_WRAPPER"
  mkdir -p "$RUST_RUNTIME_HOSTILE_BIN"
  write_literal_file "$RUST_RUNTIME_HOSTILE_BIN/cargo" \
    '#!/usr/bin/env bash' \
    ": > \"$RUST_RUNTIME_HOSTILE_BIN/cargo.marker\"" \
    'exit 98'
  chmod +x "$RUST_RUNTIME_HOSTILE_BIN/cargo"

  (
    cd "$RUST_RUNTIME_REPO"
    git init -q

    RUST_RUNTIME_ID="$(bash scripts/project-id.sh bootstrap RustPilot)"
    [[ "$RUST_RUNTIME_ID" =~ ^rustpilot-[a-f0-9]{12}$ ]] || fail "unexpected rust runtime project_id: $RUST_RUNTIME_ID"

    if ! RUSTC_WRAPPER="$RUST_RUNTIME_WRAPPER" \
        bash scripts/launch-semantic-mcp.sh \
        </dev/null \
        >"$TMP_RUNTIME/rust.stdout" \
        2>"$TMP_RUNTIME/rust.stderr"; then
      fail "launch-semantic-mcp should cleanly exit after stdin EOF when repo-local Rust semantic-mcp lane is available"
    fi

    RUST_RUNTIME_OUT="$(cat "$RUST_RUNTIME_LOG")"
    assert_contains "project_id=$RUST_RUNTIME_ID" "$RUST_RUNTIME_OUT"
    assert_contains "rustc_wrapper=" "$RUST_RUNTIME_OUT"
    assert_not_contains "rustc_wrapper=$RUST_RUNTIME_WRAPPER" "$RUST_RUNTIME_OUT"
    [[ ! -e "$RUST_RUNTIME_WRAPPER_MARKER" ]] || fail "project-id cargo runtime must not inherit caller RUSTC_WRAPPER"

    /bin/rm -f "$RUST_RUNTIME_LOG"
    if PATH="$RUST_RUNTIME_HOSTILE_BIN:$(real_allowlisted_cargo_dir):$(real_allowlisted_node_dir):/usr/bin:/bin" \
      bash scripts/launch-semantic-mcp.sh \
        >"$TMP_RUNTIME/rust_path_poison.stdout" \
        2>"$TMP_RUNTIME/rust_path_poison.stderr"; then
      fail "project-id cargo runtime unexpectedly accepted PATH-first hostile cargo wrapper"
    fi
    assert_contains "Rust semantic backend required" "$(cat "$TMP_RUNTIME/rust_path_poison.stderr")"
    [[ ! -e "$RUST_RUNTIME_LOG" ]] || fail "project-id cargo runtime should fail closed before repo-local Rust launch"
    [[ ! -e "$RUST_RUNTIME_HOSTILE_BIN/cargo.marker" ]] || fail "project-id cargo runtime must not execute PATH-first hostile cargo wrapper"

    if RUSTC_WRAPPER="$RUST_RUNTIME_WRAPPER" \
        PATH="$RUST_RUNTIME_HOSTILE_BIN:$(real_allowlisted_cargo_dir):$(real_allowlisted_node_dir):/usr/bin:/bin" \
        probe_removed_agent_core_project_id_exec_mcp_server_subcommand "$AGENT_CORE_BIN" "$RUST_RUNTIME_REPO" \
        >"$TMP_RUNTIME/direct_cli_rust.stdout" \
        2>"$TMP_RUNTIME/direct_cli_rust.stderr"; then
      fail "direct Rust CLI exec-mcp-server should no longer be callable"
    fi
    assert_contains "unrecognized subcommand 'exec-mcp-server'" "$(cat "$TMP_RUNTIME/direct_cli_rust.stderr")"
    [[ ! -e "$RUST_RUNTIME_LOG" ]] || fail "removed direct Rust CLI surface should not execute repo-local Rust semantic-mcp"
    [[ ! -e "$RUST_RUNTIME_WRAPPER_MARKER" ]] || fail "removed direct Rust CLI surface should not inherit caller RUSTC_WRAPPER"
    [[ ! -e "$RUST_RUNTIME_HOSTILE_BIN/cargo.marker" ]] || fail "removed direct Rust CLI surface should not execute PATH-first hostile cargo wrapper"
  )
fi

if ! bash "$REPO_ROOT/scripts/ci/addon-absent-or-compliant-check.sh" --semantic --root "$REPO_ROOT" \
    >"$TMP_RUNTIME/addon_absent_or_compliant.root.stdout" \
    2>"$TMP_RUNTIME/addon_absent_or_compliant.root.stderr"; then
  cat "$TMP_RUNTIME/addon_absent_or_compliant.root.stderr" >&2
  fail "root semantic addon config should be absent or compliant"
fi

TMP_ADDON_OPTIN="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_addon_optin.XXXXXX")"
ADDON_OPTIN_ROOT="$TMP_ADDON_OPTIN/repo"
mkdir -p "$ADDON_OPTIN_ROOT/.claude" "$ADDON_OPTIN_ROOT/.codex" "$ADDON_OPTIN_ROOT/scripts"
/bin/cp "$REPO_ROOT/scripts/launch-semantic-mcp.sh" "$ADDON_OPTIN_ROOT/scripts/launch-semantic-mcp.sh"
chmod +x "$ADDON_OPTIN_ROOT/scripts/launch-semantic-mcp.sh"
jq -n '{
  mcpServers: {
    "semantic-mcp": {
      command: "./scripts/launch-semantic-mcp.sh",
      args: [],
      env: {}
    }
  }
}' > "$ADDON_OPTIN_ROOT/.claude/settings.json"
jq -n '{
  mcpServers: {
    "semantic-mcp": {
      command: "./scripts/launch-semantic-mcp.sh",
      args: [],
      env: {}
    }
  }
}' > "$ADDON_OPTIN_ROOT/.mcp.json.template"
cat > "$ADDON_OPTIN_ROOT/.codex/config.toml" <<'TOML'
[mcp_servers.semantic-mcp]
command = "./scripts/launch-semantic-mcp.sh"
args = []
TOML
if ! bash "$REPO_ROOT/scripts/ci/addon-absent-or-compliant-check.sh" --semantic --root "$ADDON_OPTIN_ROOT" \
    >"$TMP_RUNTIME/addon_absent_or_compliant.optin.stdout" \
    2>"$TMP_RUNTIME/addon_absent_or_compliant.optin.stderr"; then
  cat "$TMP_RUNTIME/addon_absent_or_compliant.optin.stderr" >&2
  fail "explicit semantic addon opt-in config should satisfy launcher contract"
fi
grep -q 'compliant enabled_entries=3' "$TMP_RUNTIME/addon_absent_or_compliant.optin.stdout" \
  || fail "explicit semantic addon opt-in should validate all three config surfaces"

# 3. reviewer live state remains scratch only.
TMP_REVIEW="$(mktemp -d "${TMPDIR:-/tmp}/semantic_project_id_review_state.XXXXXX")"
REVIEW_PLAN="$TMP_REVIEW/plan.md"
REVIEW_CODER_OUTPUT="$TMP_REVIEW/coder.md"
REVIEW_OUTDIR="$TMP_REVIEW/out"
REVIEW_PROMPT_DIR="$TMP_REVIEW/prompts"
REVIEW_FILE="$TMP_REVIEW/aggregated.md"
mkdir -p "$REVIEW_OUTDIR" "$REVIEW_PROMPT_DIR"
printf '# plan\n' > "$REVIEW_PLAN"
printf '# coder\n' > "$REVIEW_CODER_OUTPUT"
printf '# reviewer prompt\n' > "$REVIEW_PROMPT_DIR/reviewer_safety.md"
write_literal_file "$REVIEW_FILE" \
  '## impl_review_safety.md' \
  '[Medium] Example: scratch summary only'
TEST_PROMPT_DIR="$REVIEW_PROMPT_DIR"

(
  # shellcheck source=/dev/null
  source "$LIB_DIR/utils.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/state.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/reviewer.sh"

  _get_prompt_dir() { printf '%s\n' "$TEST_PROMPT_DIR"; }
  _ensure_codex_wrapper() { return 0; }
  _reviewer_build_out_of_window_dependency_alert() { return 0; }
  _reviewer_build_packet() { printf '%s\n' "$1"; }
  reviewer_run_single() {
    local reviewer_name="$1"
    local input_file="$2"
    local output_file="$3"
    local timeout_secs="$4"
    : "${reviewer_name:?}" "${input_file:?}" "${timeout_secs:?}"
    printf '# review\n' > "$output_file"
    printf '11111111-1111-4111-8111-111111111111\n'
    return 0
  }

  assert_scrubbed_live_state() {
    local state_path="$1"

    if jq -e '.phases[0] | has("reviews") or has("fixes") or has("session_id") or has("reviewer_sessions")' "$state_path" >/dev/null 2>&1; then
      fail "state scrub should remove durable reviewer payload fields from phases"
    fi
    if jq -e '.phases[0].coder | has("session_id") or has("parent_session_id")' "$state_path" >/dev/null 2>&1; then
      fail "state scrub should remove coder session metadata from phase payload"
    fi
    jq -e '.sessions | keys == ["coder_sessions"]' "$state_path" >/dev/null 2>&1 \
      || fail "state sessions should contract to coder scratch only"
    jq -e '.sessions.coder_sessions | length == 1' "$state_path" >/dev/null 2>&1 \
      || fail "state scrub should preserve only contracted coder session entries"
    jq -e '.sessions.coder_sessions[0].session_id == "22222222-2222-4222-8222-222222222222"' "$state_path" >/dev/null 2>&1 \
      || fail "state scrub should preserve the coder session id"
    if jq -e '.sessions.coder_sessions[0] | has("reviewer") or has("reviews")' "$state_path" >/dev/null 2>&1; then
      fail "state scrub should remove extra reviewer payload from coder_sessions"
    fi
  }

  inject_dirty_live_state() {
    local state_path="$1"
    local tmp_state=""
    tmp_state=$(create_temp_file "semantic_project_id_dirty_state")

    jq -n \
      --arg version "$STATE_SCHEMA_VERSION" \
      --arg task_name "semantic_project_id_state" \
      --arg plan_path "$REVIEW_PLAN" \
      '{
        version: $version,
        task: {
          id: "task-1",
          name: $task_name,
          plan_path: $plan_path
        },
        status: "review",
        current_phase: "impl",
        assignments: {
          reviewer: "safety"
        },
        phases: [
          {
            name: "impl",
            status: "review",
            iteration: 1,
            max_iterations: 1,
            coder: {
              session_id: "33333333-3333-4333-8333-333333333333",
              parent_session_id: "44444444-4444-4444-8444-444444444444",
              output_file: "/tmp/coder-output.md"
            },
            reviews: [
              {
                reviewer: "safety"
              }
            ],
            fixes: [
              {
                summary: "legacy reviewer fix payload"
              }
            ],
            reviewer_sessions: [
              {
                name: "safety",
                session_id: "55555555-5555-4555-8555-555555555555"
              }
            ],
            session_id: "66666666-6666-4666-8666-666666666666",
            started_at: null,
            completed_at: null
          }
        ],
        quality_gate: {
          level: null,
          status: "pending"
        },
        sessions: {
          coder_sessions: [
            {
              session_id: "22222222-2222-4222-8222-222222222222",
              phase: "impl",
              iteration: 1,
              created_at: "2026-04-05T00:00:00Z",
              reviewer: "noise"
            }
          ],
          reviewer_sessions: [
            {
              session_id: "77777777-7777-4777-8777-777777777777"
            }
          ],
          last_session_id: "88888888-8888-4888-8888-888888888888"
        },
        timeouts: {
          codex_secs: 7200,
          claude_secs: 1800
        },
        created_at: "2026-04-05T00:00:00Z",
        updated_at: "2026-04-05T00:00:00Z",
        error: null
      }' > "$tmp_state"
    mv "$tmp_state" "$state_path"
  }

  state_init "$REVIEW_PLAN" "semantic_project_id_state" "$TMP_REVIEW/dirty-state" >/dev/null
  inject_dirty_live_state "$STATE_FILE"
  state_load "$STATE_FILE"
  assert_scrubbed_live_state "$STATE_FILE"

  inject_dirty_live_state "$STATE_FILE"
  state_save
  assert_scrubbed_live_state "$STATE_FILE"

  inject_dirty_live_state "$STATE_FILE"
  state_set '.status' '"running"'
  assert_scrubbed_live_state "$STATE_FILE"

  state_init "$REVIEW_PLAN" "semantic_project_id_state" "$TMP_REVIEW/state" >/dev/null
  state_upsert_phase "impl" 1
  state_set '.phases[0].iteration' '1'

  reviewer_run_parallel "safety" "$REVIEW_CODER_OUTPUT" "$REVIEW_OUTDIR" 5 "impl" "$TMP_REVIEW/state" "impl" >/dev/null

  if jq -e '.phases[0] | has("reviews") or has("fixes")' "$STATE_FILE" >/dev/null 2>&1; then
    fail "reviewer_run_parallel should not create durable reviewer payload fields in state"
  fi
  if grep -q '11111111-1111-4111-8111-111111111111' "$STATE_FILE"; then
    fail "reviewer session id leaked into live state.json"
  fi
  if jq -e '.. | objects | select(has("session_id"))' "$STATE_FILE" >/dev/null 2>&1; then
    fail "reviewer_run_parallel should not persist reviewer session metadata in state"
  fi

  reviewer_record_to_state "impl" 1 "$REVIEW_FILE"

  if jq -e '.phases[0] | has("reviews") or has("fixes")' "$STATE_FILE" >/dev/null 2>&1; then
    fail "reviewer_record_to_state should not append durable reviewer payload to state.json"
  fi
  if jq -e '.. | objects | select(has("session_id"))' "$STATE_FILE" >/dev/null 2>&1; then
    fail "reviewer_record_to_state should not write reviewer session metadata into state.json"
  fi
  jq -e '.sessions | keys == ["coder_sessions"]' "$STATE_FILE" >/dev/null 2>&1 \
    || fail "state sessions should remain coder scratch only"
)

printf 'PASS: semantic_project_id_contract_test\n'
