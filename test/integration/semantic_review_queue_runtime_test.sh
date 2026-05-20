#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTO_ORCHESTRATE="$REPO_ROOT/.claude/commands/auto_orchestrate.sh"
POLICY_PROJECTION_SOURCE="$REPO_ROOT/.agent/registry/orchestration_policy_projection.json"
LIB_DIR="$REPO_ROOT/.claude/commands/lib"
REAL_SEMANTIC_QUEUE_CLI="$REPO_ROOT/scripts/semantic-mcp-server/dist/cli.js"

TMP_ROOT=""

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

for artifact_path in \
  /tmp/queue-runtime-success.log \
  /tmp/queue-runtime-request-changes.log \
  /tmp/queue-runtime-partial-lease-loss.log; do
  printf '%s\n' "synthetic queue runtime artifact: $artifact_path" > "$artifact_path"
done

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

json_string_literal_for_test() {
  jq -Rn --arg value "${1:-}" '$value'
}

repo_rust_workspace_root() {
  /bin/bash "$REPO_ROOT/scripts/semantic-review-queue.sh" __internal-rust-workspace-root --repo-root "$REPO_ROOT"
}

trim_trailing_slash() {
  local path_value="${1:-}"
  while [[ "$path_value" != "/" && "$path_value" == */ ]]; do
    path_value="${path_value%/}"
  done
  printf '%s\n' "$path_value"
}

canonicalize_dir() {
  local dir_path="${1:-}"
  [[ -n "$dir_path" && -d "$dir_path" ]] || return 1
  (
    cd "$dir_path" && pwd -P
  )
}

trusted_system_binary_path_for_test() {
  local binary_name="${1:-}"
  local candidate=""

  [[ "$binary_name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "trusted system binary name is invalid: $binary_name"

  for candidate in "/usr/bin/$binary_name" "/bin/$binary_name"; do
    [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  fail "trusted system ${binary_name} binary is required for runtime test helpers"
}

trusted_runtime_owner_home_for_test() {
  local user_name=""
  local owner_home=""
  local id_bin=""

  id_bin="$(trusted_system_binary_path_for_test id)"
  user_name="$("$id_bin" -un 2>/dev/null)" || fail "failed to determine runtime owner user"
  [[ "$user_name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "runtime owner user is invalid: $user_name"
  eval "owner_home=~${user_name}"
  [[ -n "$owner_home" && "$owner_home" == /* && -d "$owner_home" ]] \
    || fail "failed to resolve runtime owner home for ${user_name}"
  canonicalize_dir "$owner_home" || fail "failed to canonicalize runtime owner home for ${user_name}"
}

semantic_mcp_server_root_for_test() {
  local root="$REPO_ROOT/scripts/semantic-mcp-server"
  [[ -d "$root" ]] || fail "semantic-mcp-server root not found: $root"
  printf '%s\n' "$root"
}

trusted_runtime_dir_patterns() {
  local home_dir="${HOME:-}"

  printf '%s\n' "/usr/bin"
  printf '%s\n' "/bin"
  printf '%s\n' "/usr/local/bin"
  printf '%s\n' "/opt/homebrew/bin"
  printf '%s\n' "/Applications/Codex.app/Contents/Resources"

  if [[ -n "$home_dir" && "$home_dir" == /* ]]; then
    home_dir="$(trim_trailing_slash "$home_dir")"
    printf '%s\n' "$home_dir/.cargo/bin"
    printf '%s\n' "$home_dir/.rustup/toolchains/*/bin"
    printf '%s\n' "$home_dir/.local/bin"
    printf '%s\n' "$home_dir/.local/share/mise/shims"
    printf '%s\n' "$home_dir/.local/share/mise/installs/*/*/bin"
    printf '%s\n' "$home_dir/.mise/shims"
    printf '%s\n' "$home_dir/.mise/installs/*/*/bin"
  fi
}

runtime_path_matches_trusted_pattern() {
  local candidate_path="${1:-}"
  local pattern=""

  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$candidate_path" == $pattern ]]; then
      return 0
    fi
  done < <(trusted_runtime_dir_patterns)

  return 1
}

runtime_binary_dir() {
  local binary_path="${1:-}"
  [[ -n "$binary_path" && "$binary_path" == */* ]] || return 1
  printf '%s\n' "${binary_path%/*}"
}

is_trusted_runtime_binary() {
  local binary_path="${1:-}"
  local binary_dir=""
  local canonical_dir=""
  local normalized_path=""
  local canonical_path=""

  [[ "$binary_path" == /* && -x "$binary_path" && -f "$binary_path" && ! -L "$binary_path" ]] || return 1
  binary_dir="$(runtime_binary_dir "$binary_path")" || return 1
  canonical_dir="$(canonical_safe_runtime_path_entry "$binary_dir")" || return 1
  normalized_path="$(trim_trailing_slash "$binary_path")"
  canonical_path="${canonical_dir}/${binary_path##*/}"
  [[ "$normalized_path" == "$canonical_path" ]] || return 1
}

looks_like_runtime_shim() {
  local binary_name="${1:-}"
  local candidate="${2:-}"
  case "$candidate" in
    */.local/share/mise/shims/"$binary_name"|*/.mise/shims/"$binary_name")
      return 0
      ;;
    */.cargo/bin/cargo)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_mise_binary_from_shim() {
  local shim_path="${1:-}"
  local binary_name="${2:-}"
  local path_value="${3:-$PATH}"
  local manager_home=""
  local data_root=""
  local preferred_mise_bin=""
  local mise_bin=""
  local resolved=""
  local sanitized_path=""
  local path_dir=""
  local candidate=""

  case "$shim_path" in
    */.local/share/mise/shims/"$binary_name"|*/.mise/shims/"$binary_name")
      data_root="${shim_path%/shims/$binary_name}"
      case "$data_root" in
        */.local/share/mise)
          manager_home="${data_root%/.local/share/mise}"
          ;;
        */.mise)
          manager_home="${data_root%/.mise}"
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac

  preferred_mise_bin="${manager_home}/.local/bin/mise"
  mise_bin="$preferred_mise_bin"
  sanitized_path="$(sanitize_runtime_path "$path_value")"

  if [[ -L "$mise_bin" ]] || ! is_trusted_runtime_binary "$mise_bin"; then
    mise_bin=""
    local IFS=':'
    local -a path_entries=()
    if [[ -n "$sanitized_path" ]]; then
      path_entries=($sanitized_path)
    fi
    for path_dir in "${path_entries[@]}"; do
      candidate="${path_dir%/}/mise"
      [[ -x "$candidate" && ! -d "$candidate" ]] || continue
      if [[ "$candidate" == "$preferred_mise_bin" && -L "$candidate" ]]; then
        continue
      fi
      case "$candidate" in
        */shims/mise)
          continue
          ;;
      esac
      is_trusted_runtime_binary "$candidate" || continue
      mise_bin="$candidate"
      break
    done
  fi

  [[ -x "$mise_bin" && ! -d "$mise_bin" ]] || return 1

  resolved="$(
    HOME="$manager_home" \
    MISE_DATA_DIR="$data_root" \
    PATH="$sanitized_path" \
    "$mise_bin" which "$binary_name" 2>/dev/null
  )" || return 1

  is_trusted_runtime_binary "$resolved" || return 1
  looks_like_runtime_shim "$binary_name" "$resolved" && return 1
  printf '%s\n' "$resolved"
}

resolve_rustup_cargo_from_proxy() {
  local cargo_path="${1:-}"
  local path_value="${2:-$PATH}"
  local manager_home=""
  local cargo_home=""
  local rustup_home=""
  local rustup_bin=""
  local resolved=""

  case "$cargo_path" in
    */.cargo/bin/cargo)
      manager_home="${cargo_path%/.cargo/bin/cargo}"
      cargo_home="${manager_home}/.cargo"
      rustup_home="${manager_home}/.rustup"
      rustup_bin="${cargo_home}/bin/rustup"
      ;;
    *)
      return 1
      ;;
  esac

  [[ -x "$rustup_bin" && ! -d "$rustup_bin" ]] || return 1
  is_trusted_runtime_binary "$rustup_bin" || return 1

  resolved="$(
    HOME="$manager_home" \
    CARGO_HOME="$cargo_home" \
    RUSTUP_HOME="$rustup_home" \
    PATH="$(sanitize_runtime_path "$path_value")" \
    "$rustup_bin" which cargo 2>/dev/null
  )" || return 1

  is_trusted_runtime_binary "$resolved" || return 1
  looks_like_runtime_shim cargo "$resolved" && return 1
  printf '%s\n' "$resolved"
}

canonical_safe_runtime_path_entry() {
  local path_entry="${1:-}"
  local normalized_path=""
  local canonical_path=""

  [[ -n "$path_entry" ]] || return 1
  [[ "$path_entry" == /* ]] || return 1
  if ! canonical_path="$(canonicalize_dir "$path_entry" 2>/dev/null)"; then
    return 1
  fi

  normalized_path="$(trim_trailing_slash "$path_entry")"
  canonical_path="$(trim_trailing_slash "$canonical_path")"
  [[ "$normalized_path" == "$canonical_path" ]] || return 1
  runtime_path_matches_trusted_pattern "$canonical_path" || return 1
  printf '%s\n' "$canonical_path"
}

is_safe_runtime_path_entry() {
  canonical_safe_runtime_path_entry "${1:-}" >/dev/null
}

sanitize_runtime_path() {
  local path_value="${1:-$PATH}"
  local remaining="${path_value}:"
  local path_entry=""
  local canonical_entry=""
  local -a safe_entries=()
  local joined=""
  local existing_entry=""

  while [[ "$remaining" == *:* ]]; do
    path_entry="${remaining%%:*}"
    remaining="${remaining#*:}"
    canonical_entry="$(canonical_safe_runtime_path_entry "$path_entry" 2>/dev/null || true)"
    [[ -n "$canonical_entry" ]] || continue

    if [[ "${#safe_entries[@]}" -gt 0 ]]; then
      for existing_entry in "${safe_entries[@]}"; do
        [[ "$existing_entry" != "$canonical_entry" ]] || continue 2
      done
    fi

    safe_entries+=("$canonical_entry")
  done

  if [[ "${#safe_entries[@]}" -gt 0 ]]; then
    for path_entry in "${safe_entries[@]}"; do
      if [[ -n "$joined" ]]; then
        joined="${joined}:"
      fi
      joined="${joined}${path_entry}"
    done
  fi

  printf '%s\n' "$joined"
}

first_runtime_candidate() {
  local binary_name="${1:-}"
  local path_value="${2:-$PATH}"
  local remaining="${path_value}:"
  local path_dir=""
  local candidate=""
  local canonical_dir=""

  while [[ "$remaining" == *:* ]]; do
    path_dir="${remaining%%:*}"
    remaining="${remaining#*:}"

    case "$path_dir" in
      ""|"." )
        continue
        ;;
    esac
    [[ "$path_dir" == /* ]] || continue

    candidate="${path_dir%/}/${binary_name}"
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue

    canonical_dir="$(canonical_safe_runtime_path_entry "$path_dir" 2>/dev/null || true)"
    [[ -n "$canonical_dir" ]] || return 1

    printf '%s\n' "${canonical_dir}/${binary_name}"
    return 0
  done

  return 1
}

first_runtime_candidate_after() {
  local binary_name="${1:-}"
  local path_value="${2:-$PATH}"
  local after_dir="${3:-}"
  local remaining=""
  local path_dir=""
  local candidate=""
  local canonical_dir=""
  local seen_after=0

  [[ -n "$after_dir" ]] || fail "after_dir is required"
  remaining="$(sanitize_runtime_path "$path_value"):"

  while [[ "$remaining" == *:* ]]; do
    path_dir="${remaining%%:*}"
    remaining="${remaining#*:}"

    case "$path_dir" in
      ""|".")
        continue
        ;;
    esac
    [[ "$path_dir" == /* ]] || continue

    canonical_dir="$(canonical_safe_runtime_path_entry "$path_dir" 2>/dev/null || true)"
    [[ -n "$canonical_dir" ]] || continue

    if [[ "$seen_after" -eq 0 ]]; then
      if [[ "$canonical_dir" == "$after_dir" ]]; then
        seen_after=1
      fi
      continue
    fi

    candidate="${canonical_dir}/${binary_name}"
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

resolve_runtime_candidate() {
  local binary_name="${1:-}"
  local candidate="${2:-}"
  local path_value="${3:-$PATH}"
  local resolved=""

  [[ -n "$candidate" ]] || fail "candidate is required"

  if ! looks_like_runtime_shim "$binary_name" "$candidate"; then
    is_trusted_runtime_binary "$candidate" || fail "failed to resolve ${binary_name} binary"
    printf '%s\n' "$candidate"
    return 0
  fi
  if resolved="$(resolve_mise_binary_from_shim "$candidate" "$binary_name" "$path_value")"; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [[ "$binary_name" == "cargo" ]] && resolved="$(resolve_rustup_cargo_from_proxy "$candidate" "$path_value")"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  fail "failed to resolve ${binary_name} binary"
}

resolve_runtime_binary() {
  local binary_name="${1:-}"
  local path_value="${2:-$PATH}"
  local candidate=""
  candidate="$(first_runtime_candidate "$binary_name" "$path_value")" || fail "failed to resolve ${binary_name} binary"
  resolve_runtime_candidate "$binary_name" "$candidate" "$path_value"
}

node_binary_supports_semantic_queue_for_test() {
  local binary_path="${1:-}"
  local server_root=""
  local runtime_home=""
  local exec_path=""

  [[ -n "$binary_path" && -x "$binary_path" ]] || fail "binary path is invalid"
  server_root="$(semantic_mcp_server_root_for_test)"
  runtime_home="$(trusted_runtime_owner_home_for_test)"
  exec_path="$(runtime_binary_dir "$binary_path"):/usr/bin:/bin"

  (
    cd "$server_root" && \
      /usr/bin/env -i "PATH=$exec_path" "HOME=$runtime_home" "$binary_path" - >/dev/null 2>&1 <<'EOF'
const Database = require("better-sqlite3");
const db = new Database(":memory:");
db.prepare("SELECT 1").get();
db.close();
EOF
  )
}

resolve_compatible_node_binary() {
  local path_value="${1:-$PATH}"
  local candidate=""
  local resolved=""
  local after_dir=""

  candidate="$(first_runtime_candidate node "$path_value")" || fail "failed to resolve node binary"
  resolved="$(resolve_runtime_candidate node "$candidate" "$path_value")" || fail "failed to resolve node binary"
  if node_binary_supports_semantic_queue_for_test "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  after_dir="$(runtime_binary_dir "$candidate")" || fail "failed to resolve node runtime directory"
  while candidate="$(first_runtime_candidate_after node "$path_value" "$after_dir")"; do
    resolved="$(resolve_runtime_candidate node "$candidate" "$path_value")" || fail "failed to resolve node binary"
    if node_binary_supports_semantic_queue_for_test "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
    after_dir="$(runtime_binary_dir "$candidate")" || break
  done

  fail "failed to resolve node binary"
}

resolve_node_binary() {
  local path_value="${1:-$PATH}"
  resolve_compatible_node_binary "$path_value"
}

real_allowlisted_node_binary() {
  resolve_node_binary "$PATH"
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

real_allowlisted_runtime_path() {
  local runtime_name="$1"

  case "$runtime_name" in
    node)
      printf '%s:/usr/bin:/bin\n' "$(real_allowlisted_node_dir)"
      ;;
    cargo)
      printf '%s:/usr/bin:/bin\n' "$(real_allowlisted_cargo_dir)"
      ;;
    *)
      fail "unsupported runtime name: $runtime_name"
      ;;
  esac
}

write_repo_local_queue_rust_fixture_at() {
  local repo_root="$1"
  local relative_root="${2:-harness-rust}"
  local rust_root="$repo_root/$relative_root"

  mkdir -p "$rust_root/crates/semantic-mcp/src"
  cat > "$rust_root/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/semantic-mcp"]
resolver = "2"
EOF

  cat > "$rust_root/crates/semantic-mcp/Cargo.toml" <<'EOF'
[package]
name = "semantic-mcp"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "semantic-mcp"
path = "src/main.rs"
EOF

  /bin/cp \
    "$REPO_ROOT/test/fixtures/semantic_review_queue_runtime/rust_queue_cli_main.rs" \
    "$rust_root/crates/semantic-mcp/src/main.rs"
}

write_repo_local_queue_rust_fixture() {
  local repo_root="$1"
  write_repo_local_queue_rust_fixture_at "$repo_root" "harness-rust"
}

setup_fixture() {
  local name="$1"
  local runtime_mode="${2:-node}"
  local fixture_root=""
  local repo=""
  local home_dir=""

  fixture_root="$(mktemp -d "${TMP_ROOT}/${name}.XXXXXX")"
  repo="$fixture_root/repo"
  home_dir="$fixture_root/home"

  mkdir -p \
    "$repo/.claude/commands/lib" \
    "$repo/.claude/tmp" \
    "$repo/.agent/active" \
    "$repo/.agent/registry" \
    "$repo/docs/prompts" \
    "$repo/scripts" \
    "$repo/scripts/semantic-mcp-server" \
    "$home_dir/.local/bin"

  case "$runtime_mode" in
    rust)
      write_repo_local_queue_rust_fixture "$repo"
      ;;
    rust-legacy-only)
      write_repo_local_queue_rust_fixture_at "$repo" "toRust-Idea/rust"
      ;;
    rust-symlink)
      ln -s "$(repo_rust_workspace_root)" "$repo/harness-rust"
      ;;
  esac

  /bin/cp "$AUTO_ORCHESTRATE" "$repo/.claude/commands/auto_orchestrate.sh"
  /bin/cp "$LIB_DIR/utils.sh" "$repo/.claude/commands/lib/utils.sh"
  /bin/cp "$LIB_DIR/state.sh" "$repo/.claude/commands/lib/state.sh"
  /bin/cp "$LIB_DIR/timeout.sh" "$repo/.claude/commands/lib/timeout.sh"
  /bin/cp "$LIB_DIR/session.sh" "$repo/.claude/commands/lib/session.sh"
  /bin/cp "$LIB_DIR/coder.sh" "$repo/.claude/commands/lib/coder.sh"
  /bin/cp "$LIB_DIR/reviewer.sh" "$repo/.claude/commands/lib/reviewer.sh"
  /bin/cp "$LIB_DIR/orchestration_packet.sh" "$repo/.claude/commands/lib/orchestration_packet.sh"
  /bin/cp "$POLICY_PROJECTION_SOURCE" "$repo/.agent/registry/orchestration_policy_projection.json"
  /bin/cp "$REPO_ROOT/scripts/project-id.sh" "$repo/scripts/project-id.sh"
  /bin/cp "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$repo/scripts/resolve-semantic-project-id.sh"
  /bin/cp "$REPO_ROOT/scripts/semantic-review-queue.sh" "$repo/scripts/semantic-review-queue.sh"
  /bin/cp -R "$REPO_ROOT/scripts/semantic-mcp-server/dist" "$repo/scripts/semantic-mcp-server/dist"
  /bin/cp "$REPO_ROOT/scripts/semantic-mcp-server/package.json" "$repo/scripts/semantic-mcp-server/package.json"
  ln -s "$REPO_ROOT/scripts/semantic-mcp-server/node_modules" "$repo/scripts/semantic-mcp-server/node_modules"

  chmod +x \
    "$repo/.claude/commands/auto_orchestrate.sh" \
    "$repo/scripts/project-id.sh" \
    "$repo/scripts/resolve-semantic-project-id.sh" \
    "$repo/scripts/semantic-review-queue.sh"

  cat > "$repo/docs/prompts/reviewer_batch.md" <<'EOF'
# Batch Review Request
__BATCH_REVIEW_METADATA__

## Diff
__BATCH_REVIEW_DIFF__
EOF

  (
    cd "$repo"
    git init -q
    git config user.email "semantic-queue-runtime@example.com"
    git config user.name "Semantic Queue Runtime Test"
    /bin/bash scripts/project-id.sh bootstrap QueueRuntime >/dev/null
  )

  printf '%s|%s\n' "$repo" "$home_dir"
}

setup_secondary_worktree_fixture() {
  local name="$1"
  local fixture=""
  local primary_repo=""
  local home_dir=""
  local fixture_root=""
  local secondary_repo=""

  fixture="$(setup_fixture "$name")"
  primary_repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  fixture_root="${primary_repo%/repo}"
  secondary_repo="${fixture_root}/secondary"

  (
    cd "$primary_repo"
    git add .claude docs scripts
    git commit -qm "fixture"
    git worktree add -q "$secondary_repo" -b "${name}-branch"
  )

  printf '%s|%s|%s\n' "$primary_repo" "$secondary_repo" "$home_dir"
}

queue_cli() {
  local repo="$1"
  local home_dir="$2"
  shift 2
  local runtime_path=""
  local node_bin=""
  local trusted_home=""
  local -a args=("$@")
  runtime_path="$(real_allowlisted_runtime_path node)"
  node_bin="$(real_allowlisted_node_binary)"
  trusted_home="$(trusted_runtime_owner_home_for_test)"
  if [[ "${args[0]:-}" == "queue" && "${args[1]:-}" == "enqueue" ]]; then
    args+=(--repo-root "$repo")
  fi
  (
    cd "$repo"
    PATH="$runtime_path" HOME="$trusted_home" "$node_bin" "$REAL_SEMANTIC_QUEUE_CLI" "${args[@]}"
  )
}

queue_shell() {
  local repo="$1"
  local home_dir="$2"
  local runtime_path="$3"
  shift 3
  (
    cd "$repo"
    PATH="$runtime_path" \
    HOME="$home_dir" \
    /bin/bash scripts/semantic-review-queue.sh "$@"
  )
}

queue_public_ingress() {
  local repo="$1"
  local home_dir="$2"
  local runtime_path="$3"
  shift 3
  (
    cd "$repo"
    PATH="$runtime_path" \
    HOME="$home_dir" \
    ./scripts/semantic-review-queue.sh "$@"
  )
}

path_without_binary() {
  local binary_name="$1"
  local path_value="${2:-$PATH}"
  local IFS=':'
  local path_entries=($path_value)
  local filtered=()
  local path_dir=""
  local candidate=""

  for path_dir in "${path_entries[@]}"; do
    candidate="${path_dir:-.}/${binary_name}"
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      continue
    fi
    filtered+=("${path_dir:-.}")
  done

  local joined=""
  for path_dir in "${filtered[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="${joined}:"
    fi
    joined="${joined}${path_dir}"
  done
  printf '%s\n' "$joined"
}

project_id_read() {
  local repo="$1"
  (
    cd "$repo"
    /bin/bash scripts/project-id.sh read
  )
}

write_hostile_path_binary() {
  local bin_dir="$1"
  local binary_name="$2"
  local message="$3"
  local marker_path="${bin_dir}/${binary_name}.marker"

  mkdir -p "$bin_dir"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'echo %q >&2\n' "$message"
    printf ': > %q\n' "$marker_path"
    printf '%s\n' 'exit 99'
  } > "$bin_dir/$binary_name"
  chmod +x "$bin_dir/$binary_name"
}

write_rust_runtime_wrapper() {
  local bin_dir="$1"
  local binary_name="$2"
  local marker_path="$3"
  local real_binary="$4"
  local runtime_home=""
  local cargo_home=""
  local rustup_home=""

  case "$real_binary" in
    */.rustup/toolchains/*/bin/*)
      runtime_home="${real_binary%/.rustup/toolchains/*/bin/*}"
      ;;
    */.cargo/bin/*)
      runtime_home="${real_binary%/.cargo/bin/*}"
      ;;
    *)
      fail "unsupported rust runtime wrapper target: $real_binary"
      ;;
  esac

  cargo_home="${runtime_home}/.cargo"
  rustup_home="${runtime_home}/.rustup"

  mkdir -p "$bin_dir"
  {
    printf '%s\n' '#!/bin/bash'
    printf ': > %q\n' "$marker_path"
    printf 'export HOME=%q\n' "$runtime_home"
    printf 'export CARGO_HOME=%q\n' "$cargo_home"
    printf 'export RUSTUP_HOME=%q\n' "$rustup_home"
    printf 'exec %q "$@"\n' "$real_binary"
  } > "$bin_dir/$binary_name"
  chmod +x "$bin_dir/$binary_name"
}

assert_hostile_path_binary_not_executed() {
  local bin_dir="$1"
  local binary_name="$2"
  [[ ! -e "$bin_dir/${binary_name}.marker" ]] || fail "hostile ${binary_name} binary executed unexpectedly"
}

resolve_repo_path() {
  local repo="$1"
  local candidate="$2"

  if [[ "$candidate" == /* ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s/%s\n' "$repo" "$candidate"
}

run_batch_review_shell() {
  local repo="$1"
  local home_dir="$2"
  local scenario="$3"
  local task_name="$4"
  local plan_path="$5"
  local runtime_path=""
  local node_bin=""
  local trusted_home=""
  runtime_path="$(real_allowlisted_runtime_path node)"
  node_bin="$(real_allowlisted_node_binary)"
  trusted_home="$(trusted_runtime_owner_home_for_test)"

  (
    cd "$repo"
    PATH="$runtime_path" \
    HOME="$trusted_home" \
    REAL_SEMANTIC_QUEUE_CLI="$REAL_SEMANTIC_QUEUE_CLI" \
    REAL_NODE_BIN="$node_bin" \
    REAL_REPO_ROOT="$REPO_ROOT" \
    TEST_SCENARIO="$scenario" \
    TEST_TASK_NAME="$task_name" \
    TEST_PLAN_PATH="$plan_path" \
    /bin/bash "$REPO_ROOT/test/fixtures/semantic_review_queue_runtime/run_batch_review_fixture.sh"
  )
}

test_success_complete_path() {
  local fixture repo home_dir project_id plan_path run_out review_output export_path
  fixture="$(setup_fixture success)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  mkdir -p "$repo/src"
  printf 'echo old\n' > "$repo/src/success.ts"
  (
    cd "$repo"
    git add src/success.ts docs/prompts/reviewer_batch.md .claude scripts .agent
    git commit -qm "init"
  )
  printf 'echo new\n' > "$repo/src/success.ts"

  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/success.ts \
    --source hook >/dev/null

  plan_path="$repo/.agent/active/plan_queue_success.md"
  printf '# success plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" success queue_success "$plan_path")"
  assert_contains 'RESULT_RC=0' "$run_out"
  review_output="$(printf '%s\n' "$run_out" | awk -F= '/^RESULT_PATH=/{print $2}' | tail -n 1)"
  review_output="$(resolve_repo_path "$repo" "$review_output")"
  [[ -n "$review_output" && -f "$review_output" ]] || fail "success path did not emit review output"

  export_path="$repo/.claude/tmp/queue_success_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "success path did not complete leased queue items"
  jq -e '
    .phases[0].batch_review_runtime.status == "completed"
    and (.phases[0].batch_review_runtime.lease_owner | length > 0)
    and (.phases[0].batch_review_runtime.lease_run_id | startswith("batch-review-impl-"))
    and .phases[0].batch_review_runtime.expected_files == ["src/success.ts"]
    and .phases[0].batch_review_runtime.finalization.completed_count == 1
  ' "$repo/.claude/tmp/queue_success/state.json" >/dev/null 2>&1 \
    || fail "success path state did not retain completed lease metadata"
}

test_zero_exit_request_changes_requeues() {
  local fixture repo home_dir project_id plan_path run_out review_output export_path queue_last_error runtime_last_error
  fixture="$(setup_fixture request_changes)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  mkdir -p "$repo/src"
  printf 'echo old\n' > "$repo/src/request-changes.ts"
  (
    cd "$repo"
    git add src/request-changes.ts docs/prompts/reviewer_batch.md .claude scripts .agent
    git commit -qm "init"
  )
  printf 'echo changed\n' > "$repo/src/request-changes.ts"

  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/request-changes.ts \
    --source hook >/dev/null

  plan_path="$repo/.agent/active/plan_queue_request_changes.md"
  printf '# request changes plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" request-changes queue_request_changes "$plan_path")"
  assert_contains 'RESULT_RC=0' "$run_out"
  review_output="$(printf '%s\n' "$run_out" | awk -F= '/^RESULT_PATH=/{print $2}' | tail -n 1)"
  review_output="$(resolve_repo_path "$repo" "$review_output")"
  [[ -n "$review_output" && -f "$review_output" ]] || fail "request-changes path did not emit review output"

  export_path="$repo/.claude/tmp/queue_request_changes_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '
    .pending_count == 1
    and .leased_count == 0
    and .items[0].file_path == "src/request-changes.ts"
    and .items[0].retry_count == 1
    and (.items[0].last_error | contains("Request Changes"))
  ' "$export_path" >/dev/null 2>&1 \
    || fail "request-changes path did not requeue with verdict context"
  jq -e '
    .phases[0].batch_review_runtime.status == "requeued"
    and .phases[0].batch_review_runtime.expected_files == ["src/request-changes.ts"]
    and (.phases[0].batch_review_runtime.last_error | contains("Request Changes"))
    and .phases[0].batch_review_runtime.finalization.requeued_count == 1
  ' "$repo/.claude/tmp/queue_request_changes/state.json" >/dev/null 2>&1 \
    || fail "request-changes path state did not retain requeue verdict metadata"
  queue_last_error="$(jq -r '.items[0].last_error' "$export_path")"
  runtime_last_error="$(jq -r '.phases[0].batch_review_runtime.last_error' "$repo/.claude/tmp/queue_request_changes/state.json")"
  assert_not_contains '# Code Review Report' "$queue_last_error"
  assert_not_contains 'incoming request status:' "$queue_last_error"
  assert_not_contains '# Code Review Report' "$runtime_last_error"
  assert_not_contains 'incoming request status:' "$runtime_last_error"
}

test_failure_requeue_path() {
  local fixture repo home_dir project_id plan_path run_out review_output export_path queue_last_error runtime_last_error
  fixture="$(setup_fixture failure)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  mkdir -p "$repo/src"
  printf 'echo old\n' > "$repo/src/failure.ts"
  (
    cd "$repo"
    git add src/failure.ts docs/prompts/reviewer_batch.md .claude scripts .agent
    git commit -qm "init"
  )
  printf 'echo broken\n' > "$repo/src/failure.ts"

  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/failure.ts \
    --source hook >/dev/null

  plan_path="$repo/.agent/active/plan_queue_failure.md"
  printf '# failure plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" failure queue_failure "$plan_path")"
  assert_contains 'RESULT_RC=0' "$run_out"
  review_output="$(printf '%s\n' "$run_out" | awk -F= '/^RESULT_PATH=/{print $2}' | tail -n 1)"
  review_output="$(resolve_repo_path "$repo" "$review_output")"
  [[ -n "$review_output" && -f "$review_output" ]] || fail "failure path did not emit review output"

  export_path="$repo/.claude/tmp/queue_failure_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '
    .pending_count == 1
    and .leased_count == 0
    and .items[0].file_path == "src/failure.ts"
    and .items[0].retry_count == 1
    and (.items[0].last_error | contains("rc=42"))
  ' "$export_path" >/dev/null 2>&1 \
    || fail "failure path did not requeue with retry + error context"
  jq -e '
    .phases[0].batch_review_runtime.status == "requeued"
    and .phases[0].batch_review_runtime.expected_files == ["src/failure.ts"]
    and (.phases[0].batch_review_runtime.last_error | contains("rc=42"))
    and .phases[0].batch_review_runtime.finalization.requeued_count == 1
  ' "$repo/.claude/tmp/queue_failure/state.json" >/dev/null 2>&1 \
    || fail "failure path state did not retain requeue lease metadata"
  queue_last_error="$(jq -r '.items[0].last_error' "$export_path")"
  runtime_last_error="$(jq -r '.phases[0].batch_review_runtime.last_error' "$repo/.claude/tmp/queue_failure/state.json")"
  assert_not_contains 'RAW_TRANSPORT_MARKER' "$queue_last_error"
  assert_not_contains 'REVIEW_BODY_MARKER' "$queue_last_error"
  assert_not_contains 'RAW_TRANSPORT_MARKER' "$runtime_last_error"
  assert_not_contains 'REVIEW_BODY_MARKER' "$runtime_last_error"
}

test_invalid_format_requeues_without_raw_context_leak() {
  local fixture repo home_dir project_id plan_path run_out review_output export_path queue_last_error runtime_last_error
  fixture="$(setup_fixture invalid_format)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  mkdir -p "$repo/src"
  printf 'echo old\n' > "$repo/src/invalid-format.ts"
  (
    cd "$repo"
    git add src/invalid-format.ts docs/prompts/reviewer_batch.md .claude scripts .agent
    git commit -qm "init"
  )
  printf 'echo invalid\n' > "$repo/src/invalid-format.ts"

  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/invalid-format.ts \
    --source hook >/dev/null

  plan_path="$repo/.agent/active/plan_queue_invalid_format.md"
  printf '# invalid format plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" invalid-format queue_invalid_format "$plan_path")"
  assert_contains 'RESULT_RC=0' "$run_out"
  review_output="$(printf '%s\n' "$run_out" | awk -F= '/^RESULT_PATH=/{print $2}' | tail -n 1)"
  review_output="$(resolve_repo_path "$repo" "$review_output")"
  [[ -n "$review_output" && -f "$review_output" ]] || fail "invalid-format path did not emit review output"

  export_path="$repo/.claude/tmp/queue_invalid_format_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '
    .pending_count == 1
    and .leased_count == 0
    and .items[0].file_path == "src/invalid-format.ts"
    and .items[0].retry_count == 1
    and (.items[0].last_error | contains("invalid reviewer output format"))
  ' "$export_path" >/dev/null 2>&1 \
    || fail "invalid-format path did not requeue with invalid-format context"
  jq -e '
    .phases[0].batch_review_runtime.status == "requeued"
    and .phases[0].batch_review_runtime.expected_files == ["src/invalid-format.ts"]
    and (.phases[0].batch_review_runtime.last_error | contains("invalid reviewer output format"))
    and .phases[0].batch_review_runtime.finalization.requeued_count == 1
  ' "$repo/.claude/tmp/queue_invalid_format/state.json" >/dev/null 2>&1 \
    || fail "invalid-format path state did not retain sanitized invalid-format metadata"

  queue_last_error="$(jq -r '.items[0].last_error' "$export_path")"
  runtime_last_error="$(jq -r '.phases[0].batch_review_runtime.last_error' "$repo/.claude/tmp/queue_invalid_format/state.json")"
  assert_not_contains 'RAW_TRANSPORT_MARKER' "$queue_last_error"
  assert_not_contains 'REVIEW_BODY_MARKER' "$queue_last_error"
  assert_not_contains 'RAW_TRANSPORT_MARKER' "$runtime_last_error"
  assert_not_contains 'REVIEW_BODY_MARKER' "$runtime_last_error"
}

test_stale_json_is_not_authority() {
  local fixture repo home_dir plan_path run_out state_file
  fixture="$(setup_fixture stale_json)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"

  cat > "$repo/.claude/tmp/review_queue.json" <<'JSON'
{"pending_review":true,"changed_files":["src/legacy-only.ts"],"last_change":"2026-04-05T00:00:00Z"}
JSON

  plan_path="$repo/.agent/active/plan_queue_stale_json.md"
  printf '# stale json plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" stale-json queue_stale_json "$plan_path")"
  assert_contains 'RESULT_RC=0' "$run_out"
  assert_contains 'RESULT_PATH=' "$run_out"

  state_file="$repo/.claude/tmp/queue_stale_json/state.json"
  [[ -f "$state_file" ]] || fail "stale-json path state file missing"
  if jq -e '.phases[0] | has("batch_review_runtime")' "$state_file" >/dev/null 2>&1; then
    fail "stale JSON should not create batch_review_runtime without a DB lease"
  fi
}

test_partial_lease_loss_fails_closed() {
  local fixture repo home_dir project_id plan_path run_out export_path
  fixture="$(setup_fixture partial_lease_loss)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  mkdir -p "$repo/src"
  printf 'echo old-a\n' > "$repo/src/partial-a.ts"
  printf 'echo old-b\n' > "$repo/src/partial-b.ts"
  (
    cd "$repo"
    git add src/partial-a.ts src/partial-b.ts docs/prompts/reviewer_batch.md .claude scripts .agent
    git commit -qm "init"
  )
  printf 'echo new-a\n' > "$repo/src/partial-a.ts"
  printf 'echo new-b\n' > "$repo/src/partial-b.ts"

  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/partial-a.ts \
    --source hook >/dev/null
  queue_cli "$repo" "$home_dir" \
    queue enqueue \
    --project-id "$project_id" \
    --file-path src/partial-b.ts \
    --source hook >/dev/null

  plan_path="$repo/.agent/active/plan_queue_partial.md"
  printf '# partial lease loss plan\n' > "$plan_path"

  run_out="$(run_batch_review_shell "$repo" "$home_dir" partial-lease-loss queue_partial "$plan_path")"
  assert_contains 'RESULT_RC=1' "$run_out"

  export_path="$repo/.claude/tmp/queue_partial_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '
    .leased_count == 2
    and .pending_count == 0
    and (.changed_files | length) == 2
  ' "$export_path" >/dev/null 2>&1 \
    || fail "partial lease loss should leave queue rows leased for manual recovery"
  jq -e '
    .error.code == "BATCH_REVIEW_QUEUE_LEASE_LOST"
    and .error.phase == "impl"
    and .phases[0].batch_review_runtime.status == "failed_closed"
    and (.phases[0].batch_review_runtime.last_error | contains("lost queue lease ownership"))
  ' "$repo/.claude/tmp/queue_partial/state.json" >/dev/null 2>&1 \
    || fail "partial lease loss did not fail closed in runtime state"
}

test_direct_cli_unknown_token_fails_closed() {
  local fixture repo home_dir project_id output rc
  fixture="$(setup_fixture unknown_token)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  set +e
  output="$(queue_cli "$repo" "$home_dir" bogus cmd --project-id "$project_id" 2>&1)"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "unknown direct CLI token unexpectedly succeeded"
  assert_contains 'unknown command: bogus cmd' "$output"
}

test_direct_cli_blank_explicit_source_is_rejected() {
  local fixture repo home_dir project_id output rc export_path
  fixture="$(setup_fixture blank_source)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  set +e
  output="$(
    queue_cli "$repo" "$home_dir" \
      queue enqueue \
      --project-id "$project_id" \
      --file-path src/blank.ts \
      --source '   ' 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "blank explicit source unexpectedly succeeded"
  assert_contains "source must contain only letters" "$output"

  export_path="$repo/.claude/tmp/blank_source_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "blank explicit source mutated queue state"
}

test_direct_cli_omitted_source_defaults_to_manual() {
  local fixture repo home_dir project_id output export_path
  fixture="$(setup_fixture default_source)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  output="$(
    queue_cli "$repo" "$home_dir" \
      queue enqueue \
      --project-id "$project_id" \
      --file-path src/manual.ts
  )"
  printf '%s\n' "$output" | jq -e '.item.source == "manual"' >/dev/null 2>&1 \
    || fail "omitted source did not default to manual"

  export_path="$repo/.claude/tmp/default_source_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '
    .pending_count == 1
    and .items[0].file_path == "src/manual.ts"
    and .items[0].source == "manual"
  ' "$export_path" >/dev/null 2>&1 \
    || fail "omitted source queue snapshot was not recorded as manual"
}

test_shell_ingress_omitted_source_defaults_to_manual() {
  local fixture repo home_dir project_id runtime_path export_path output
  fixture="$(setup_fixture shell_default_source)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  export_path="$repo/.claude/tmp/shell-default-source-export.json"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path src/manual-shell.ts \
      --export-json "$export_path"
  )"

  printf '%s\n' "$output" | jq -e '.item.source == "manual"' >/dev/null 2>&1 \
    || fail "shell ingress omitted source did not default to manual"

  jq -e \
    --arg project_id "$project_id" \
    '.project_id == $project_id
      and .pending_count == 1
      and .items[0].file_path == "src/manual-shell.ts"
      and .items[0].source == "manual"' \
    "$export_path" >/dev/null 2>&1 \
    || fail "shell ingress omitted source queue snapshot was not recorded as manual"
}

test_public_ingress_rejects_absolute_enqueue_file_path() {
  local fixture repo home_dir project_id runtime_path output rc export_path absolute_path outside_root
  fixture="$(setup_fixture absolute_enqueue_path)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  outside_root="$(mktemp -d "${TMP_ROOT}/outside-absolute.XXXXXX")"
  absolute_path="${outside_root}/proof.txt"
  export_path="$repo/.claude/tmp/absolute_enqueue_export.json"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path "$absolute_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress accepted absolute enqueue path"
  assert_contains "file_path must be repo-relative" "$output"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "absolute enqueue path rejection mutated queue state"
}

test_public_ingress_rejects_traversal_enqueue_file_path() {
  local fixture repo home_dir project_id runtime_path output rc export_path
  fixture="$(setup_fixture traversal_enqueue_path)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  export_path="$repo/.claude/tmp/traversal_enqueue_export.json"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path ../outside/proof.txt 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress accepted traversal enqueue path"
  assert_contains "file_path must not contain traversal components" "$output"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "traversal enqueue path rejection mutated queue state"
}

test_public_ingress_rejects_leading_dash_enqueue_file_path() {
  local fixture repo home_dir project_id runtime_path output rc export_path
  fixture="$(setup_fixture leading_dash_enqueue_path)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  export_path="$repo/.claude/tmp/leading_dash_enqueue_export.json"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path --pathspec-from-file=.claude/tmp/pathspec.txt 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress accepted leading-dash enqueue path"
  assert_contains "file_path must not contain leading-dash components" "$output"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "leading-dash enqueue path rejection mutated queue state"
}

test_public_ingress_rejects_repo_external_symlink_enqueue_file_path() {
  local fixture repo home_dir project_id runtime_path output rc export_path outside_root
  fixture="$(setup_fixture symlink_enqueue_path)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  outside_root="$(mktemp -d "${TMP_ROOT}/outside-symlink.XXXXXX")"
  ln -s "$outside_root" "$repo/outside-link"
  export_path="$repo/.claude/tmp/symlink_enqueue_export.json"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path outside-link/proof.txt 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress accepted repo-external symlink enqueue path"
  assert_contains "file_path resolves through a symlinked path" "$output"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "repo-external symlink rejection mutated queue state"
}

test_public_ingress_persists_canonical_repo_relative_enqueue_file_path() {
  local fixture repo home_dir project_id runtime_path export_path
  fixture="$(setup_fixture canonical_enqueue_path)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  runtime_path="$(real_allowlisted_runtime_path node)"
  export_path="$repo/.claude/tmp/canonical_enqueue_export.json"

  queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
    enqueue \
    --file-path './src\valid.ts' >/dev/null

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null
  jq -e '
    .pending_count == 1
    and .leased_count == 0
    and .items[0].file_path == "src/valid.ts"
    and .items[0].dedupe_key == "src/valid.ts"
  ' "$export_path" >/dev/null 2>&1 \
    || fail "canonical enqueue path was not persisted in repo-relative normalized form"
}

test_public_ingress_enqueue_export_json_uses_single_backend_call() {
  local fixture repo home_dir runtime_path export_path invocation_log output
  fixture="$(setup_fixture public_ingress_single_call)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$(real_allowlisted_runtime_path node)"
  export_path="$repo/.claude/tmp/public_ingress_single_call.json"
  invocation_log="$repo/.claude/tmp/public_ingress_single_call.log"

  {
    printf '%s\n' '#!/usr/bin/env node'
    printf '%s\n' 'import fs from "node:fs";'
    printf '%s\n' 'import path from "node:path";'
    printf '%s\n' ''
    printf '%s\n' 'const args = process.argv.slice(2);'
    printf '%s\n' 'const logPath = "__LOG_PATH__";'
    printf '%s\n' ''
    printf '%s\n' 'const flags = new Map();'
    printf '%s\n' 'for (let index = 2; index < process.argv.length; index += 2) {'
    printf '%s\n' '  const flag = process.argv[index];'
    printf '%s\n' '  const value = process.argv[index + 1];'
    printf '%s\n' '  if (!flag || !flag.startsWith("--")) {'
    printf '%s\n' '    continue;'
    printf '%s\n' '  }'
    printf '%s\n' '  flags.set(flag, value);'
    printf '%s\n' '}'
    printf '%s\n' ''
    printf '%s\n' 'fs.mkdirSync(path.dirname(logPath), { recursive: true });'
    printf '%s\n' 'fs.appendFileSync(logPath, `${JSON.stringify(args)}\n`, "utf8");'
    printf '%s\n' ''
    printf '%s\n' 'if (args[0] !== "queue" || args[1] !== "enqueue") {'
    printf '%s\n' '  throw new Error(`unexpected command: ${args.join(" ")}`);'
    printf '%s\n' '}'
    printf '%s\n' ''
    printf '%s\n' 'const filePath = flags.get("--file-path");'
    printf '%s\n' 'const source = flags.get("--source") ?? "manual";'
    printf '%s\n' 'const projectId = flags.get("--project-id");'
    printf '%s\n' 'const exportJson = flags.get("--export-json");'
    printf '%s\n' 'if (!filePath || !projectId) {'
    printf '%s\n' '  throw new Error("missing required queue enqueue flags");'
    printf '%s\n' '}'
    printf '%s\n' ''
    printf '%s\n' 'if (exportJson) {'
    printf '%s\n' '  fs.mkdirSync(path.dirname(exportJson), { recursive: true });'
    printf '%s\n' '  fs.writeFileSync('
    printf '%s\n' '    exportJson,'
    printf '%s\n' '    `${JSON.stringify('
    printf '%s\n' '      {'
    printf '%s\n' '        project_id: projectId,'
    printf '%s\n' '        pending_count: 1,'
    printf '%s\n' '        leased_count: 0,'
    printf '%s\n' '        pending_review: true,'
    printf '%s\n' '        changed_files: [filePath],'
    printf '%s\n' '        last_change: "2026-04-18T00:00:00Z",'
    printf '%s\n' '        items: ['
    printf '%s\n' '          {'
    printf '%s\n' '            file_path: filePath,'
    printf '%s\n' '            dedupe_key: filePath,'
    printf '%s\n' '            source,'
    printf '%s\n' '            queue_state: "pending",'
    printf '%s\n' '            retry_count: 0,'
    printf '%s\n' '            last_error: null,'
    printf '%s\n' '          },'
    printf '%s\n' '        ],'
    printf '%s\n' '      },'
    printf '%s\n' '      null,'
    printf '%s\n' '      2'
    printf '%s\n' '    )}\n`,'
    printf '%s\n' '    "utf8"'
    printf '%s\n' '  );'
    printf '%s\n' '}'
    printf '%s\n' ''
    printf '%s\n' 'process.stdout.write('
    printf '%s\n' '  `${JSON.stringify('
    printf '%s\n' '    {'
    printf '%s\n' '      queued: true,'
    printf '%s\n' '      duplicate: false,'
    printf '%s\n' '      item: {'
    printf '%s\n' '        file_path: filePath,'
    printf '%s\n' '        dedupe_key: filePath,'
    printf '%s\n' '        source,'
    printf '%s\n' '        queue_state: "pending",'
    printf '%s\n' '        retry_count: 0,'
    printf '%s\n' '        last_error: null,'
    printf '%s\n' '      },'
    printf '%s\n' '    },'
    printf '%s\n' '    null,'
    printf '%s\n' '    2'
    printf '%s\n' '  )}\n`'
    printf '%s\n' ');'
  } > "$repo/scripts/semantic-mcp-server/dist/cli.js"
  /usr/bin/perl -0pi -e "s|__LOG_PATH__|$invocation_log|g" "$repo/scripts/semantic-mcp-server/dist/cli.js"
  chmod +x "$repo/scripts/semantic-mcp-server/dist/cli.js"

  output="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    ./scripts/semantic-review-queue.sh \
      enqueue \
      --file-path './src\single-call.ts' \
      --source hook \
      --export-json "$export_path"
  )"

  printf '%s\n' "$output" | jq -e '
    .queued == true
    and .duplicate == false
    and .item.file_path == "src/single-call.ts"
    and .item.source == "hook"
  ' >/dev/null 2>&1 || fail "single-call public ingress did not return enqueue payload"

  [[ "$(wc -l < "$invocation_log" | tr -d '[:space:]')" == "1" ]] \
    || fail "public enqueue --export-json performed more than one backend invocation"
  jq -e 'length == 12 and .[0] == "queue" and .[1] == "enqueue" and .[4] == "--repo-root" and .[10] == "--export-json"' \
    "$invocation_log" >/dev/null 2>&1 \
    || fail "public enqueue --export-json did not forward a single combined backend command"
  jq -e '
    .pending_count == 1
    and .leased_count == 0
    and .items[0].file_path == "src/single-call.ts"
    and .items[0].dedupe_key == "src/single-call.ts"
    and .items[0].source == "hook"
  ' "$export_path" >/dev/null 2>&1 \
    || fail "single-call public ingress did not write authoritative export payload"
}

test_reviewer_consumer_treats_leading_dash_queued_path_as_literal() {
  local fixture repo home_dir runtime_path trusted_home snapshot_path malicious_path option_value_path
  local snapshot_contents output rc
  fixture="$(setup_fixture reviewer_literal_leading_dash)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$(real_allowlisted_runtime_path node)"
  trusted_home="$(trusted_runtime_owner_home_for_test)"
  snapshot_path="$repo/.claude/tmp/reviewer_literal_leading_dash.patch"
  malicious_path='--pathspec-from-file=.claude/tmp/pathspec.txt'
  option_value_path="$repo/.claude/tmp/pathspec.txt"

  mkdir -p "$repo/src"
  printf 'tracked baseline\n' > "$repo/src/baseline.ts"
  (
    cd "$repo"
    git add src/baseline.ts docs/prompts/reviewer_batch.md
    git commit -qm "fixture"
  )

  mkdir -p -- "$repo/--pathspec-from-file=.claude/tmp"
  printf '%s\n' 'docs/prompts/reviewer_batch.md' > "$option_value_path"
  printf 'literal queued file\n' > "$repo/$malicious_path"

  set +e
  output="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    HOME="$trusted_home" \
    SNAPSHOT_PATH="$snapshot_path" \
    QUEUED_FILES="$malicious_path" \
    /bin/bash <<'EOF'
set -euo pipefail
source .claude/commands/auto_orchestrate.sh
review_create_diff_snapshot "$SNAPSHOT_PATH" "$QUEUED_FILES"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "reviewer diff snapshot rejected a literal leading-dash path: $output"
  [[ -f "$snapshot_path" ]] || fail "reviewer diff snapshot for literal leading-dash path was not created"

  snapshot_contents="$(cat "$snapshot_path")"
  assert_contains "diff --git a/$malicious_path b/$malicious_path" "$snapshot_contents"
  assert_contains "+++ b/$malicious_path" "$snapshot_contents"
  assert_not_contains "+++ b/docs/prompts/reviewer_batch.md" "$snapshot_contents"
}

test_shell_adapter_rejects_incompatible_flags() {
  local fixture repo home_dir project_id output rc export_path
  fixture="$(setup_fixture incompatible_flags)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"

  set +e
  output="$(
    cd "$repo" && \
    PATH="$home_dir/.local/bin:$PATH" \
    HOME="$home_dir" \
    bash scripts/semantic-review-queue.sh enqueue --file-path src/incompatible.ts --lease-run-id bad 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "shell adapter accepted incompatible flags"
  assert_contains 'enqueue does not allow --lease-run-id' "$output"

  export_path="$repo/.claude/tmp/incompatible_flags_export.json"
  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$project_id" \
    --output "$export_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "incompatible shell flags mutated queue state"
}

test_public_ingress_ignores_path_poisoned_bash_on_direct_exec() {
  local fixture repo home_dir output runtime_path hostile_dir
  fixture="$(setup_fixture public_ingress_help)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  runtime_path="$hostile_dir:$PATH"

  write_hostile_path_binary "$hostile_dir" bash "hostile bash should not be executed"

  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" --help 2>&1
  )"

  assert_contains 'semantic-review-queue.sh export-json --output PATH [--project-id ID] [--repo-root PATH]' "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" bash
}

test_public_ingress_ignores_path_poisoned_dirname_and_basename() {
  local fixture repo home_dir output runtime_path hostile_dir export_path
  fixture="$(setup_fixture public_ingress_path_split)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/public_ingress_path_split.json"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"

  write_hostile_path_binary "$hostile_dir" dirname "hostile dirname should not be executed"
  write_hostile_path_binary "$hostile_dir" basename "hostile basename should not be executed"

  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"

  assert_not_contains "hostile dirname should not be executed" "$output"
  assert_not_contains "hostile basename should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" dirname
  assert_hostile_path_binary_not_executed "$hostile_dir" basename
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "dirname/basename poison regression did not export expected queue state"
}

test_public_ingress_fails_closed_on_absolute_path_poisoned_cargo_even_with_trusted_runtime_later() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture public_ingress_poisoned_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/public_ingress_poisoned_cargo.json"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path cargo)"

  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo should not be executed"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly accepted hostile absolute cargo PATH prefix with trusted runtime later"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "hostile cargo should not be executed" "$output"
  [[ ! -e "$export_path" ]] || fail "cargo poison fail-closed path wrote export unexpectedly"
}

test_public_ingress_fails_closed_on_absolute_path_poisoned_cargo_only() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture public_ingress_poisoned_cargo_only rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/public_ingress_poisoned_cargo_only.json"
  runtime_path="$hostile_dir:/usr/bin:/bin"

  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo should not be executed"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly accepted hostile absolute cargo PATH prefix"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "hostile cargo should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  [[ ! -e "$export_path" ]] || fail "cargo poison fail-closed path wrote export unexpectedly"
}

test_public_ingress_ignores_env_trust_widening_for_cargo() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture env_trust_widening_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/env_trust_widening_cargo.json"
  runtime_path="$hostile_dir:/usr/bin:/bin"

  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo from env widening should not be executed"

  set +e
  output="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    SEMANTIC_QUEUE_TRUSTED_RUNTIME_DIRS="$hostile_dir" \
    ./scripts/semantic-review-queue.sh export-json --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly trusted env-widened cargo directory"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "hostile cargo from env widening should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  [[ ! -e "$export_path" ]] || fail "env-widened cargo path wrote export unexpectedly"
}

test_public_ingress_fails_closed_on_absolute_path_poisoned_node_even_with_trusted_runtime_later() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture public_ingress_poisoned_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/public_ingress_poisoned_node.json"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"

  write_hostile_path_binary "$hostile_dir" node "hostile node should not be executed"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly accepted hostile absolute node PATH prefix with trusted runtime later"
  assert_hostile_path_binary_not_executed "$hostile_dir" node
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "hostile node should not be executed" "$output"
  [[ ! -e "$export_path" ]] || fail "node poison fail-closed path wrote export unexpectedly"
}

test_public_ingress_fails_closed_on_absolute_path_poisoned_node_only() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture public_ingress_poisoned_node_only)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/public_ingress_poisoned_node_only.json"
  runtime_path="$hostile_dir:/usr/bin:/bin"

  write_hostile_path_binary "$hostile_dir" node "hostile node should not be executed"

  set +e
  output="$(
    queue_public_ingress "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly accepted hostile absolute node PATH prefix"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "hostile node should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" node
  [[ ! -e "$export_path" ]] || fail "node poison fail-closed path wrote export unexpectedly"
}

test_public_ingress_ignores_env_trust_widening_for_node() {
  local fixture repo home_dir output rc runtime_path hostile_dir export_path
  fixture="$(setup_fixture env_trust_widening_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  export_path="$repo/.claude/tmp/env_trust_widening_node.json"
  runtime_path="$hostile_dir:/usr/bin:/bin"

  write_hostile_path_binary "$hostile_dir" node "hostile node from env widening should not be executed"

  set +e
  output="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    SEMANTIC_QUEUE_TRUSTED_RUNTIME_DIRS="$hostile_dir" \
    ./scripts/semantic-review-queue.sh export-json --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "public ingress unexpectedly trusted env-widened node directory"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "hostile node from env widening should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" node
  [[ ! -e "$export_path" ]] || fail "env-widened node path wrote export unexpectedly"
}

test_shell_adapter_does_not_propagate_node_options_to_trusted_node_runtime() {
  local fixture repo home_dir export_path runtime_path preload_path preload_marker output
  fixture="$(setup_fixture scrubbed_node_options)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  export_path="$repo/.claude/tmp/scrubbed_node_options.json"
  runtime_path="$(real_allowlisted_runtime_path node)"
  preload_path="$TMP_ROOT/node-options-preload.js"
  preload_marker="$TMP_ROOT/node-options-preload.marker"

  {
    printf '%s\n' 'const fs = require("fs");'
    printf 'fs.writeFileSync(%s, "poisoned\\n");\n' "$(json_string_literal_for_test "$preload_marker")"
  } > "$preload_path"

  output="$(
    NODE_OPTIONS="--require $preload_path" \
      queue_shell "$repo" "$home_dir" "$runtime_path" \
        export-json \
        --output "$export_path" 2>&1
  )"

  [[ ! -e "$preload_marker" ]] || fail "queue node runtime must not inherit caller NODE_OPTIONS"
  [[ -f "$export_path" ]] || fail "queue node runtime did not export queue state under scrubbed NODE_OPTIONS"
  assert_not_contains "poisoned" "$output"
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "scrubbed NODE_OPTIONS path did not export expected queue state"
}

test_shell_adapter_pins_node_runtime_home_to_trusted_owner_root() {
  local fixture repo home_dir runtime_path runtime_script runtime_log trusted_home

  fixture="$(setup_fixture pinned_node_runtime_home)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$(real_allowlisted_runtime_path node)"
  runtime_script="$repo/.claude/tmp/node-runtime-home.js"
  runtime_log="$repo/.claude/tmp/node-runtime-home.json"
  trusted_home="$(trusted_runtime_owner_home_for_test)"

  {
    printf '%s\n' 'const fs = require("fs");'
    printf '%s\n' 'const os = require("os");'
    printf '%s\n' 'const path = require("path");'
    printf '%s\n' 'fs.writeFileSync('
    printf '  %s,\n' "$(json_string_literal_for_test "$runtime_log")"
    printf '%s\n' '  JSON.stringify({'
    printf '%s\n' '    envHome: process.env.HOME || "",'
    printf '%s\n' '    homedir: os.homedir(),'
    printf '%s\n' '    dbRoot: path.join(os.homedir(), ".semantic-mcp")'
    printf '%s\n' '  }) + "\n"'
    printf '%s\n' ');'
  } > "$runtime_script"

  (
    cd "$repo"
    PATH="$runtime_path" \
    HOME="$home_dir" \
    /bin/bash scripts/semantic-review-queue.sh __internal-run-runtime --binary node -- "$runtime_script" >/dev/null
  )

  [[ -f "$runtime_log" ]] || fail "trusted node runtime home probe did not produce a log"
  jq -e \
    --arg trusted "$trusted_home" \
    --arg caller "$home_dir" \
    '.envHome == $trusted and .homedir == $trusted and .dbRoot == ($trusted + "/.semantic-mcp") and .envHome != $caller and .homedir != $caller' \
    "$runtime_log" >/dev/null 2>&1 \
    || fail "trusted node runtime HOME was not pinned to the runtime owner root"
}

test_shell_adapter_internal_runtime_env_ignores_path_poisoned_id() {
  local fixture repo home_dir runtime_path hostile_dir output trusted_home

  fixture="$(setup_fixture poisoned_id_internal_env)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$repo/hostile-bin"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"
  trusted_home="$(trusted_runtime_owner_home_for_test)"

  write_hostile_path_binary "$hostile_dir" id "fake id should not be executed"

  output="$(
    cd "$repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    /bin/bash scripts/semantic-review-queue.sh __internal-runtime-env --binary node
  )"

  assert_contains "RUNTIME_HOME=$trusted_home" "$output"
  assert_contains "RUNTIME_BINARY=$(real_allowlisted_node_binary)" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" id
}

test_shell_adapter_does_not_propagate_rustc_wrapper_to_trusted_cargo_runtime() {
  local fixture repo home_dir export_path runtime_path wrapper_path wrapper_marker target_dir output
  fixture="$(setup_fixture scrubbed_rustc_wrapper rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  export_path="$repo/.claude/tmp/scrubbed_rustc_wrapper.json"
  runtime_path="$(real_allowlisted_runtime_path cargo)"
  wrapper_path="$TMP_ROOT/rustc-wrapper.sh"
  wrapper_marker="$TMP_ROOT/rustc-wrapper.marker"
  target_dir="$TMP_ROOT/cargo-target"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$wrapper_marker"
    printf '%s\n' 'exit 97'
  } > "$wrapper_path"
  chmod +x "$wrapper_path"

  output="$(
    RUSTC_WRAPPER="$wrapper_path" \
    CARGO_TARGET_DIR="$target_dir" \
      queue_shell "$repo" "$home_dir" "$runtime_path" \
        export-json \
        --output "$export_path" 2>&1
  )"

  [[ ! -e "$wrapper_marker" ]] || fail "queue cargo runtime must not inherit caller RUSTC_WRAPPER"
  [[ ! -e "$target_dir" ]] || fail "queue cargo runtime must not inherit caller CARGO_TARGET_DIR"
  [[ -f "$export_path" ]] || fail "queue cargo runtime did not export queue state under scrubbed RUSTC_WRAPPER"
  assert_not_contains "rustc-wrapper" "$output"
  jq -e '.pending_count == 0 and .leased_count == 0' "$export_path" >/dev/null 2>&1 \
    || fail "scrubbed RUSTC_WRAPPER path did not export expected queue state"
}

test_shell_adapter_rejects_duplicate_singleton_flags() {
  local fixture repo home_dir output rc first_output second_output runtime_path
  fixture="$(setup_fixture duplicate_singleton_flags)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$(real_allowlisted_runtime_path node)"
  first_output="$repo/.claude/tmp/duplicate-singleton-a.json"
  second_output="$repo/.claude/tmp/duplicate-singleton-b.json"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$first_output" \
      --output "$second_output" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "shell adapter accepted duplicate singleton flags"
  assert_contains 'duplicate flag: --output' "$output"
  [[ ! -e "$first_output" ]] || fail "duplicate singleton flag path wrote first output unexpectedly"
  [[ ! -e "$second_output" ]] || fail "duplicate singleton flag path wrote second output unexpectedly"
}

test_queue_project_id_reads_repo_local_common_root_artifact_via_canonical_helper() {
  local fixture primary_repo secondary_repo home_dir project_id secondary_override_project_id
  local secondary_helper_project_id secondary_resolved_project_id output runtime_path hostile_dir
  fixture="$(setup_secondary_worktree_fixture common_root_project_id)"
  primary_repo="${fixture%%|*}"
  secondary_repo="${fixture#*|}"
  secondary_repo="${secondary_repo%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$primary_repo")"
  secondary_override_project_id="secondary_override_project_id"
  hostile_dir="$secondary_repo/hostile-bin"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"

  mkdir -p "$secondary_repo/.shared"
  printf '%s\n' "$secondary_override_project_id" > "$secondary_repo/.shared/project_id"

  write_hostile_path_binary "$hostile_dir" bash "fake bash should not be executed"
  write_hostile_path_binary "$hostile_dir" cargo "fake cargo should not be executed"
  write_hostile_path_binary "$hostile_dir" git "fake git should not be executed"

  secondary_helper_project_id="$(
    cd "$secondary_repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    /bin/bash scripts/project-id.sh read
  )"
  [[ "$secondary_helper_project_id" == "$project_id" ]] \
    || fail "canonical helper did not resolve the repo-local/common-root authoritative project_id from the secondary worktree"
  secondary_resolved_project_id="$(
    cd "$secondary_repo" && \
    PATH="$runtime_path" \
    HOME="$home_dir" \
    /bin/bash scripts/resolve-semantic-project-id.sh --repo-root "$secondary_repo" --print
  )"
  [[ "$secondary_resolved_project_id" == "$project_id" ]] \
    || fail "canonical resolver did not resolve the repo-local/common-root authoritative project_id from the secondary worktree"

  output="$(
    queue_shell "$secondary_repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$secondary_repo/.claude/tmp/common_root_project_id.json" 2>&1
  )"

  printf '%s\n' "$output" | jq -e \
    --arg project_id "$project_id" \
    --arg secondary_override_project_id "$secondary_override_project_id" \
    '.project_id == $project_id and .project_id != $secondary_override_project_id' >/dev/null 2>&1 \
    || fail "secondary worktree did not preserve the repo-local/common-root authoritative project_id"
  jq -e \
    --arg project_id "$project_id" \
    --arg secondary_override_project_id "$secondary_override_project_id" '
    .project_id == $project_id
    and .project_id != $secondary_override_project_id
    and .pending_count == 0
    and .leased_count == 0
  ' "$secondary_repo/.claude/tmp/common_root_project_id.json" >/dev/null 2>&1 \
    || fail "queue export did not preserve the repo-local/common-root authoritative project_id"

  assert_hostile_path_binary_not_executed "$hostile_dir" bash
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  assert_hostile_path_binary_not_executed "$hostile_dir" git
}

test_queue_project_id_fails_closed_when_repo_local_common_root_artifact_is_missing() {
  local fixture primary_repo secondary_repo home_dir output rc runtime_path hostile_dir
  fixture="$(setup_secondary_worktree_fixture missing_project_id)"
  primary_repo="${fixture%%|*}"
  secondary_repo="${fixture#*|}"
  secondary_repo="${secondary_repo%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$secondary_repo/hostile-bin"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"

  /bin/rm -f "$primary_repo/.shared/project_id" "$secondary_repo/.shared/project_id"

  write_hostile_path_binary "$hostile_dir" bash "fake bash should not be executed"
  write_hostile_path_binary "$hostile_dir" cargo "fake cargo should not be executed"

  set +e
  output="$(
    queue_shell "$secondary_repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$secondary_repo/.claude/tmp/missing_project_id.json" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "queue ingress unexpectedly succeeded without a repo-local/common-root authoritative project_id artifact"
  assert_contains "missing project_id artifact" "$output"

  assert_hostile_path_binary_not_executed "$hostile_dir" bash
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
}

test_queue_project_id_fails_closed_when_repo_local_common_root_authoritative_artifact_is_multiline() {
  local fixture primary_repo secondary_repo home_dir output rc runtime_path hostile_dir project_id
  fixture="$(setup_secondary_worktree_fixture multiline_project_id)"
  primary_repo="${fixture%%|*}"
  secondary_repo="${fixture#*|}"
  secondary_repo="${secondary_repo%%|*}"
  home_dir="${fixture##*|}"
  hostile_dir="$secondary_repo/hostile-bin"
  runtime_path="$hostile_dir:$(real_allowlisted_runtime_path node)"
  project_id="$(project_id_read "$primary_repo")"

  mkdir -p "$primary_repo/.shared" "$secondary_repo/.shared"
  printf '%s\n%s\n' "$project_id" "unexpected-second-line" > "$primary_repo/.shared/project_id"
  printf '%s\n%s\n' "$project_id" "unexpected-second-line" > "$secondary_repo/.shared/project_id"

  write_hostile_path_binary "$hostile_dir" bash "fake bash should not be executed"
  write_hostile_path_binary "$hostile_dir" cargo "fake cargo should not be executed"

  set +e
  output="$(
    queue_shell "$secondary_repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$secondary_repo/.claude/tmp/multiline_project_id.json" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "queue ingress unexpectedly succeeded with a multiline repo-local/common-root authoritative project_id artifact"
  assert_contains "project_id artifact must contain exactly one logical line" "$output"

  assert_hostile_path_binary_not_executed "$hostile_dir" bash
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
}

test_shell_adapter_fails_closed_on_fixture_home_local_bin_cargo_wrapper_even_with_real_trusted_runtime_later() {
  local fixture repo home_dir output rc export_path runtime_path cargo_marker rustc_marker real_cargo real_rustc queue_state_path
  fixture="$(setup_fixture direct_local_bin_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$home_dir/.local/bin:$(real_allowlisted_runtime_path cargo)"
  cargo_marker="$home_dir/direct-cargo.marker"
  rustc_marker="$home_dir/direct-rustc.marker"
  export_path="$repo/.claude/tmp/direct_local_bin_cargo_export.json"
  queue_state_path="$repo/.claude/tmp/direct_local_bin_cargo_state.json"
  real_cargo="$(real_allowlisted_cargo_binary)"
  real_rustc="$(rustup which rustc)"

  write_rust_runtime_wrapper "$home_dir/.local/bin" cargo "$cargo_marker" "$real_cargo"
  write_rust_runtime_wrapper "$home_dir/.local/bin" rustc "$rustc_marker" "$real_rustc"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      enqueue \
      --file-path src/rust-backed.ts 2>&1
  )"
  rc=$?
  set -e

  [[ ! -e "$cargo_marker" ]] || fail "fixture-owned cargo wrapper in temp \$HOME/.local/bin should not be trusted or executed"
  [[ ! -e "$rustc_marker" ]] || fail "fixture-owned rustc wrapper in temp \$HOME/.local/bin should not be trusted or executed"
  [[ "$rc" -ne 0 ]] || fail "queue enqueue unexpectedly accepted temp \$HOME/.local/bin cargo wrapper with a real trusted runtime later"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  [[ ! -e "$export_path" ]] || fail "fail-closed local cargo wrapper path wrote export unexpectedly"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$(project_id_read "$repo")" \
    --output "$queue_state_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$queue_state_path" >/dev/null 2>&1 \
    || fail "fail-closed local cargo wrapper path mutated queue state"
}

test_shell_adapter_fails_closed_on_fixture_home_local_bin_node_symlink_even_with_real_trusted_runtime_later() {
  local fixture repo home_dir output rc export_path runtime_path hostile_dir queue_state_path
  fixture="$(setup_fixture direct_local_bin_node_symlink)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$home_dir/.local/bin:$(real_allowlisted_runtime_path node)"
  hostile_dir="$repo/hostile-node-target"
  export_path="$repo/.claude/tmp/direct_local_bin_node_symlink_export.json"
  queue_state_path="$repo/.claude/tmp/direct_local_bin_node_symlink_state.json"

  write_hostile_path_binary "$hostile_dir" node "hostile symlinked node target should not be executed"
  ln -s "$hostile_dir/node" "$home_dir/.local/bin/node"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "queue export-json unexpectedly accepted temp \$HOME/.local/bin node symlink with a real trusted runtime later"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "hostile symlinked node target should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" node
  [[ ! -e "$export_path" ]] || fail "fail-closed local node symlink path wrote export unexpectedly"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$(project_id_read "$repo")" \
    --output "$queue_state_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$queue_state_path" >/dev/null 2>&1 \
    || fail "fail-closed local node symlink path mutated queue state"
}

test_shell_adapter_fails_closed_on_fixture_home_local_bin_cargo_symlink_even_with_real_trusted_runtime_later() {
  local fixture repo home_dir output rc export_path runtime_path hostile_dir queue_state_path
  fixture="$(setup_fixture direct_local_bin_cargo_symlink rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="$home_dir/.local/bin:$(real_allowlisted_runtime_path cargo)"
  hostile_dir="$repo/hostile-cargo-target"
  export_path="$repo/.claude/tmp/direct_local_bin_cargo_symlink_export.json"
  queue_state_path="$repo/.claude/tmp/direct_local_bin_cargo_symlink_state.json"

  write_hostile_path_binary "$hostile_dir" cargo "hostile symlinked cargo target should not be executed"
  ln -s "$hostile_dir/cargo" "$home_dir/.local/bin/cargo"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "queue export-json unexpectedly accepted temp \$HOME/.local/bin cargo symlink with a real trusted runtime later"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "hostile symlinked cargo target should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  [[ ! -e "$export_path" ]] || fail "fail-closed local cargo symlink path wrote export unexpectedly"

  queue_cli "$repo" "$home_dir" \
    queue export-json \
    --project-id "$(project_id_read "$repo")" \
    --output "$queue_state_path" >/dev/null

  jq -e '.pending_count == 0 and .leased_count == 0' "$queue_state_path" >/dev/null 2>&1 \
    || fail "fail-closed local cargo symlink path mutated queue state"
}

test_shell_adapter_fails_closed_on_symlinked_external_rust_workspace() {
  local fixture repo home_dir project_id output_path runtime_path hostile_dir output rc
  fixture="$(setup_fixture symlinked_external_rust_workspace rust-symlink)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  output_path="$repo/.claude/tmp/symlinked_external_rust_workspace.json"
  hostile_dir="$repo/hostile-cargo-target"
  runtime_path="$hostile_dir:$(path_without_binary cargo "$(real_allowlisted_runtime_path node)")"

  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --project-id "$project_id" \
      --output "$output_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "symlinked external rust workspace should fail closed"
  assert_contains "Rust workspace candidate must not be a symlink" "$output"
  assert_not_contains "hostile cargo should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  [[ ! -e "$output_path" ]] || fail "symlinked external rust workspace should not fall back to node"
}

test_shell_adapter_ignores_legacy_only_rust_root_and_falls_back_to_node() {
  local fixture repo home_dir project_id output_path runtime_path hostile_dir output
  fixture="$(setup_fixture legacy_only_rust_root rust-legacy-only)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  output_path="$repo/.claude/tmp/legacy_only_rust_root.json"
  hostile_dir="$repo/hostile-cargo-target"
  runtime_path="$hostile_dir:$(path_without_binary cargo "$(real_allowlisted_runtime_path node)")"

  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --project-id "$project_id" \
      --output "$output_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "legacy-only Rust root should fall back to node"
  assert_not_contains "multiple valid Rust workspace roots detected" "$output"
  assert_not_contains "hostile cargo should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  [[ -e "$output_path" ]] || fail "legacy-only Rust root should use node fallback"
}

test_shell_adapter_falls_back_to_node_when_no_valid_rust_root_exists() {
  local fixture repo home_dir project_id output_path runtime_path output
  fixture="$(setup_fixture no_valid_rust_root)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  output_path="$repo/.claude/tmp/no_valid_rust_root.json"
  runtime_path="$(real_allowlisted_runtime_path node)"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --project-id "$project_id" \
      --output "$output_path" 2>&1
  )"

  jq -e --arg project_id "$project_id" '
    .project_id == $project_id
    and .pending_count == 0
    and .leased_count == 0
  ' <<<"$output" >/dev/null 2>&1 \
    || fail "no-valid-rust-root fallback returned unexpected CLI summary"
  jq -e --arg project_id "$project_id" '
    .project_id == $project_id
    and .pending_count == 0
    and .leased_count == 0
  ' "$output_path" >/dev/null 2>&1 \
    || fail "missing valid Rust root did not fall back to the node queue export path"
}

test_shell_adapter_fails_closed_on_symlinked_external_node_cli_entrypoint() {
  local fixture repo home_dir fixture_root runtime_path external_dist external_marker output_path output rc
  fixture="$(setup_fixture symlinked_external_node_cli)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  fixture_root="${repo%/repo}"
  runtime_path="$(real_allowlisted_runtime_path node)"
  external_dist="$fixture_root/external-cli-dist"
  external_marker="$fixture_root/external-cli.marker"
  output_path="$repo/.claude/tmp/symlinked_external_node_cli.json"

  mkdir -p "$external_dist"
  {
    printf '%s\n' 'const fs = require("node:fs");'
    printf 'fs.writeFileSync(%s, "");\n' "$(json_string_literal_for_test "$external_marker")"
    printf '%s\n' 'console.error("external symlinked cli should not be executed");'
    printf '%s\n' 'process.exit(91);'
  } > "$external_dist/cli.js"

  rm -rf "$repo/scripts/semantic-mcp-server/dist"
  ln -s "$external_dist" "$repo/scripts/semantic-mcp-server/dist"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$output_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "node fallback unexpectedly accepted a symlinked external CLI entrypoint"
  assert_contains "semantic-review-queue.sh: semantic MCP CLI entrypoint must be a repo-local real file:" "$output"
  assert_not_contains "external symlinked cli should not be executed" "$output"
  [[ ! -e "$external_marker" ]] || fail "symlinked external node CLI entrypoint was executed unexpectedly"
  [[ ! -e "$output_path" ]] || fail "symlinked external node CLI entrypoint wrote export unexpectedly"
}

test_production_helper_fails_closed_when_mise_returns_symlinked_node_binary() {
  local fixture repo home_dir canonical_home_dir shim_dir hostile_dir resolved_dir source_script output rc mise_marker
  fixture="$(setup_fixture mise_symlinked_node_result)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  shim_dir="$canonical_home_dir/.local/share/mise/shims"
  hostile_dir="$repo/hostile-node-target"
  resolved_dir="$canonical_home_dir/.local/share/mise/installs/node/24.14.0/bin"
  source_script="$repo/semantic-review-queue.functions.sh"
  mise_marker="$canonical_home_dir/mise-symlink-result.marker"

  mkdir -p "$shim_dir" "$resolved_dir" "$canonical_home_dir/.local/bin"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"
  write_hostile_path_binary "$shim_dir" node "fake mise node shim should not be executed"
  write_hostile_path_binary "$hostile_dir" node "hostile node resolved by mise should not be executed"
  ln -s "$hostile_dir/node" "$resolved_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf ': > %q\n' "$mise_marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "node" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$resolved_dir/node"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected mise invocation: $*" >&2'
    printf '%s\n' 'exit 91'
  } > "$canonical_home_dir/.local/bin/mise"
  chmod +x "$canonical_home_dir/.local/bin/mise"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    SHIM_PATH="$shim_dir/node" \
    TEST_PATH_VALUE="$canonical_home_dir/.local/bin" \
    SANITIZED_PATH="$canonical_home_dir/.local/bin" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
sanitize_runtime_path() {
  printf '%s\n' "$SANITIZED_PATH"
}
resolve_mise_binary_from_shim "$SHIM_PATH" node "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "mise lookup unexpectedly accepted a symlinked concrete node binary"
  [[ -e "$mise_marker" ]] || fail "trusted mise helper was not executed during symlinked node resolution"
  assert_not_contains "fake mise node shim should not be executed" "$output"
  assert_not_contains "hostile node resolved by mise should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" node
  assert_hostile_path_binary_not_executed "$hostile_dir" node
}

test_production_helper_fails_closed_when_rustup_returns_out_of_allowlist_cargo_binary() {
  local fixture repo home_dir canonical_home_dir shim_dir hostile_dir source_script output rc rustup_marker
  fixture="$(setup_fixture rustup_out_of_allowlist_cargo_result rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  shim_dir="$canonical_home_dir/.cargo/bin"
  hostile_dir="$repo/hostile-cargo-target"
  source_script="$repo/semantic-review-queue.functions.sh"
  rustup_marker="$canonical_home_dir/rustup-out-of-allowlist.marker"

  mkdir -p "$shim_dir"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"
  write_hostile_path_binary "$shim_dir" cargo "fake cargo proxy should not be executed"
  write_hostile_path_binary "$hostile_dir" cargo "hostile cargo resolved by rustup should not be executed"

  {
    printf '%s\n' '#!/bin/bash'
    printf ': > %q\n' "$rustup_marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "cargo" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$hostile_dir/cargo"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected rustup invocation: $*" >&2'
    printf '%s\n' 'exit 92'
  } > "$shim_dir/rustup"
  chmod +x "$shim_dir/rustup"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    CARGO_PATH="$shim_dir/cargo" \
    TEST_PATH_VALUE="$shim_dir" \
    SANITIZED_PATH="$shim_dir" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
sanitize_runtime_path() {
  printf '%s\n' "$SANITIZED_PATH"
}
resolve_rustup_cargo_from_proxy "$CARGO_PATH" "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "rustup lookup unexpectedly accepted an out-of-allowlist concrete cargo binary"
  [[ -e "$rustup_marker" ]] || fail "trusted rustup helper was not executed during out-of-allowlist cargo resolution"
  assert_not_contains "fake cargo proxy should not be executed" "$output"
  assert_not_contains "hostile cargo resolved by rustup should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" cargo
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
}

test_production_helper_resolves_mise_shim_via_allowlisted_path_fallback() {
  local fixture repo home_dir shim_dir data_root fallback_root fallback_mise_dir expected_node_dir
  local expected_node marker source_script output rc

  fixture="$(setup_fixture production_mise_fallback)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.local/share/mise/shims"
  data_root="$home_dir/.local/share/mise"
  fallback_root="$(mktemp -d "${TMP_ROOT}/production_mise_fallback.XXXXXX")"
  fallback_mise_dir="$fallback_root/mise-bin"
  expected_node_dir="$fallback_root/node-bin"
  expected_node="$expected_node_dir/node"
  marker="$fallback_root/mise.marker"
  source_script="$fallback_root/semantic-review-queue.functions.sh"

  mkdir -p "$shim_dir" "$fallback_mise_dir" "$expected_node_dir"
  [[ ! -e "$home_dir/.local/bin/mise" ]] || fail "fixture manager-home mise must be absent for PATH fallback regression"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'echo "fake mise node shim should not be executed" >&2'
    printf '%s\n' 'exit 97'
  } > "$shim_dir/node"
  chmod +x "$shim_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$expected_node"
  chmod +x "$expected_node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '[[ "$HOME" == %q ]] || exit 71\n' "$home_dir"
    printf '[[ "$MISE_DATA_DIR" == %q ]] || exit 72\n' "$data_root"
    printf '[[ "$PATH" == %q ]] || exit 73\n' "$fallback_mise_dir"
    printf ': > %q\n' "$marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "node" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$expected_node"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected mise invocation: $*" >&2'
    printf '%s\n' 'exit 74'
  } > "$fallback_mise_dir/mise"
  chmod +x "$fallback_mise_dir/mise"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    SHIM_PATH="$shim_dir/node" \
    TEST_PATH_VALUE="$fallback_mise_dir" \
    SANITIZED_PATH="$fallback_mise_dir" \
    FALLBACK_MISE="$fallback_mise_dir/mise" \
    EXPECTED_NODE="$expected_node" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
sanitize_runtime_path() {
  printf '%s\n' "$SANITIZED_PATH"
}
is_trusted_runtime_binary() {
  [[ "${1:-}" == "$EXPECTED_NODE" || "${1:-}" == "$FALLBACK_MISE" ]]
}
resolve_mise_binary_from_shim "$SHIM_PATH" node "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "production mise shim fallback did not resolve via allowlisted PATH-backed mise: $output"
  [[ "$output" == "$expected_node" ]] || fail "production mise shim fallback resolved unexpected node binary: $output"
  [[ -e "$marker" ]] || fail "production mise shim fallback did not execute the PATH-backed mise binary"
}

test_production_helper_probes_hoisted_better_sqlite3_resolution() {
  local fixture repo home_dir canonical_home_dir source_script hoisted_root server_root output rc
  fixture="$(setup_fixture production_hoisted_better_sqlite3)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  source_script="$repo/semantic-review-queue.functions.sh"
  hoisted_root="$repo/hoisted-node-root"
  server_root="$hoisted_root/scripts/semantic-mcp-server"

  mkdir -p "$hoisted_root/node_modules/better-sqlite3" "$server_root"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"

  printf '%s\n' 'throw new Error("hoisted better-sqlite3 probe executed");' \
    > "$hoisted_root/node_modules/better-sqlite3/index.js"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    TEST_NODE_BIN="$(real_allowlisted_node_binary)" \
    TEST_SERVER_ROOT="$server_root" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
semantic_mcp_server_root() {
  printf '%s\n' "$TEST_SERVER_ROOT"
}
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
node_binary_supports_semantic_queue "$TEST_NODE_BIN"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "hoisted better-sqlite3 resolution unexpectedly skipped the compatibility probe"
  assert_not_contains "semantic-review-queue.sh: path does not exist" "$output"
}

test_production_helper_fails_closed_when_later_node_candidate_resolution_fails() {
  local fixture repo home_dir canonical_home_dir source_script incompatible_dir shim_dir compatible_dir
  local incompatible_node compatible_node output rc
  fixture="$(setup_fixture production_later_node_resolution_failure)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  source_script="$repo/semantic-review-queue.functions.sh"
  incompatible_dir="$canonical_home_dir/.local/share/mise/installs/node/incompatible/bin"
  shim_dir="$canonical_home_dir/.local/share/mise/shims"
  compatible_dir="$canonical_home_dir/.local/bin"
  incompatible_node="$incompatible_dir/node"
  compatible_node="$compatible_dir/node"

  mkdir -p "$incompatible_dir" "$shim_dir" "$compatible_dir"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$incompatible_dir/node"
  chmod +x "$incompatible_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'echo "fake mise node shim should not be executed" >&2'
    printf '%s\n' 'exit 97'
  } > "$shim_dir/node"
  chmod +x "$shim_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$compatible_dir/node"
  chmod +x "$compatible_dir/node"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    TEST_PATH_VALUE="$incompatible_dir:$shim_dir:$compatible_dir" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    INCOMPATIBLE_NODE="$incompatible_node" \
    COMPATIBLE_NODE="$compatible_node" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
node_semantic_queue_dependency_present() {
  return 0
}
node_binary_supports_semantic_queue() {
  case "${1:-}" in
    "$INCOMPATIBLE_NODE")
      return 1
      ;;
    "$COMPATIBLE_NODE")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
resolve_compatible_node_binary "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "later node candidate resolution failure unexpectedly fell through to a later runtime"
  assert_not_contains "$compatible_node" "$output"
  assert_not_contains "fake mise node shim should not be executed" "$output"
}

test_production_helper_skips_symlinked_manager_home_mise_and_uses_allowlisted_fallback() {
  local fixture repo home_dir canonical_home_dir shim_dir data_root fallback_mise_dir expected_node_dir evil_bin_dir
  local expected_node preferred_marker fallback_marker source_script output rc

  fixture="$(setup_fixture production_mise_symlink_guard)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  shim_dir="$canonical_home_dir/.local/share/mise/shims"
  data_root="$canonical_home_dir/.local/share/mise"
  fallback_mise_dir="$canonical_home_dir/.mise/installs/mise/stable/bin"
  expected_node_dir="$canonical_home_dir/.local/share/mise/installs/node/stable/bin"
  evil_bin_dir="$canonical_home_dir/evil-mise-bin"
  expected_node="$expected_node_dir/node"
  preferred_marker="$canonical_home_dir/preferred-mise.marker"
  fallback_marker="$canonical_home_dir/fallback-mise.marker"
  source_script="$repo/semantic-review-queue.functions.sh"

  mkdir -p "$shim_dir" "$fallback_mise_dir" "$expected_node_dir" "$evil_bin_dir" "$canonical_home_dir/.local"
  rmdir "$canonical_home_dir/.local/bin"
  ln -s "$evil_bin_dir" "$canonical_home_dir/.local/bin"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'echo "fake mise node shim should not be executed" >&2'
    printf '%s\n' 'exit 97'
  } > "$shim_dir/node"
  chmod +x "$shim_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$expected_node"
  chmod +x "$expected_node"

  {
    printf '%s\n' '#!/bin/bash'
    printf ': > %q\n' "$preferred_marker"
    printf '%s\n' 'exit 89'
  } > "$evil_bin_dir/mise"
  chmod +x "$evil_bin_dir/mise"

  {
    printf '%s\n' '#!/bin/bash'
    printf '[[ "$HOME" == %q ]] || exit 71\n' "$canonical_home_dir"
    printf '[[ "$MISE_DATA_DIR" == %q ]] || exit 72\n' "$data_root"
    printf '[[ "$PATH" == %q ]] || exit 73\n' "$fallback_mise_dir"
    printf ': > %q\n' "$fallback_marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "node" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$expected_node"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected mise invocation: $*" >&2'
    printf '%s\n' 'exit 74'
  } > "$fallback_mise_dir/mise"
  chmod +x "$fallback_mise_dir/mise"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    SHIM_PATH="$shim_dir/node" \
    TEST_PATH_VALUE="$canonical_home_dir/.local/bin:$fallback_mise_dir" \
    SANITIZED_PATH="$fallback_mise_dir" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
sanitize_runtime_path() {
  printf '%s\n' "$SANITIZED_PATH"
}
resolve_mise_binary_from_shim "$SHIM_PATH" node "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "symlinked manager-home mise candidate did not fall back to an allowlisted mise binary: $output"
  [[ "$output" == "$expected_node" ]] || fail "symlinked manager-home mise candidate resolved unexpected node binary: $output"
  [[ ! -e "$preferred_marker" ]] || fail "symlinked manager-home mise candidate was executed unexpectedly"
  [[ -e "$fallback_marker" ]] || fail "allowlisted PATH fallback mise was not executed"
}

test_production_helper_skips_symlinked_manager_home_mise_file_and_uses_allowlisted_fallback() {
  local fixture repo home_dir canonical_home_dir shim_dir data_root fallback_mise_dir expected_node_dir evil_bin_dir
  local expected_node preferred_marker fallback_marker source_script output rc sanitized_path

  fixture="$(setup_fixture production_mise_symlink_file_guard)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  canonical_home_dir="$(canonicalize_dir "$home_dir")"
  shim_dir="$canonical_home_dir/.local/share/mise/shims"
  data_root="$canonical_home_dir/.local/share/mise"
  fallback_mise_dir="$canonical_home_dir/.mise/installs/mise/stable/bin"
  expected_node_dir="$canonical_home_dir/.local/share/mise/installs/node/stable/bin"
  evil_bin_dir="$canonical_home_dir/evil-mise-bin"
  expected_node="$expected_node_dir/node"
  preferred_marker="$canonical_home_dir/preferred-mise-file.marker"
  fallback_marker="$canonical_home_dir/fallback-mise-file.marker"
  source_script="$repo/semantic-review-queue.functions.sh"
  sanitized_path="$canonical_home_dir/.local/bin:$fallback_mise_dir"

  mkdir -p "$shim_dir" "$fallback_mise_dir" "$expected_node_dir" "$evil_bin_dir" "$canonical_home_dir/.local/bin"
  sed '$d' "$REPO_ROOT/scripts/semantic-review-queue.sh" > "$source_script"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'echo "fake mise node shim should not be executed" >&2'
    printf '%s\n' 'exit 97'
  } > "$shim_dir/node"
  chmod +x "$shim_dir/node"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$expected_node"
  chmod +x "$expected_node"

  {
    printf '%s\n' '#!/bin/bash'
    printf ': > %q\n' "$preferred_marker"
    printf '%s\n' 'exit 89'
  } > "$evil_bin_dir/mise"
  chmod +x "$evil_bin_dir/mise"
  ln -s "$evil_bin_dir/mise" "$canonical_home_dir/.local/bin/mise"

  {
    printf '%s\n' '#!/bin/bash'
    printf '[[ "$HOME" == %q ]] || exit 71\n' "$canonical_home_dir"
    printf '[[ "$MISE_DATA_DIR" == %q ]] || exit 72\n' "$data_root"
    printf '[[ "$PATH" == %q ]] || exit 73\n' "$sanitized_path"
    printf ': > %q\n' "$fallback_marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "node" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$expected_node"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected mise invocation: $*" >&2'
    printf '%s\n' 'exit 74'
  } > "$fallback_mise_dir/mise"
  chmod +x "$fallback_mise_dir/mise"

  set +e
  output="$(
    SOURCE_SCRIPT="$source_script" \
    SHIM_PATH="$shim_dir/node" \
    TEST_PATH_VALUE="$sanitized_path" \
    SANITIZED_PATH="$sanitized_path" \
    TEST_MANAGER_HOME="$canonical_home_dir" \
    /bin/bash <<'EOF'
set -euo pipefail
source "$SOURCE_SCRIPT"
trusted_runtime_owner_home() {
  printf '%s\n' "$TEST_MANAGER_HOME"
}
sanitize_runtime_path() {
  printf '%s\n' "$SANITIZED_PATH"
}
resolve_mise_binary_from_shim "$SHIM_PATH" node "$TEST_PATH_VALUE"
EOF
  )"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "symlinked manager-home mise file candidate did not fall back to an allowlisted mise binary: $output"
  [[ "$output" == "$expected_node" ]] || fail "symlinked manager-home mise file candidate resolved unexpected node binary: $output"
  [[ ! -e "$preferred_marker" ]] || fail "symlinked manager-home mise file candidate was executed unexpectedly"
  [[ -e "$fallback_marker" ]] || fail "allowlisted PATH fallback mise was not executed after symlinked manager-home mise file rejection"
}

test_shell_adapter_fails_closed_on_fixture_home_mise_roots_for_leading_node_shim() {
  local fixture repo home_dir output rc runtime_path real_node selected_dir found_dir
  local shim_dir selected_marker found_marker mise_marker export_path
  fixture="$(setup_fixture mise_selected_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.local/share/mise/shims"
  runtime_path="$shim_dir:$(real_allowlisted_runtime_path node)"
  real_node="$(real_allowlisted_node_binary)"
  selected_dir="$home_dir/.local/share/mise/installs/node/aaa-selected/bin"
  found_dir="$home_dir/.local/share/mise/installs/node/zzz-found/bin"
  selected_marker="$home_dir/selected-node.marker"
  found_marker="$home_dir/found-node.marker"
  mise_marker="$home_dir/mise.marker"
  export_path="$repo/.claude/tmp/mise_selected_node.json"

  mkdir -p "$selected_dir" "$found_dir"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$selected_marker"
    printf 'exec %q "$@"\n' "$real_node"
  } > "$selected_dir/node"
  chmod +x "$selected_dir/node"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$found_marker"
    printf '%s\n' 'echo "found node should not be selected" >&2'
    printf '%s\n' 'exit 92'
  } > "$found_dir/node"
  chmod +x "$found_dir/node"

  mkdir -p "$shim_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "fake mise node shim should not be executed" >&2'
    printf '%s\n' 'exit 90'
  } > "$shim_dir/node"
  chmod +x "$shim_dir/node"

  mkdir -p "$home_dir/.local/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$mise_marker"
    printf '%s\n' 'if [[ "$#" -eq 2 && "$1" == "which" && "$2" == "node" ]]; then'
    printf '  printf '"'"'%%s\\n'"'"' %q\n' "$selected_dir/node"
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'echo "unexpected mise invocation: $*" >&2'
    printf '%s\n' 'exit 91'
  } > "$home_dir/.local/bin/mise"
  chmod +x "$home_dir/.local/bin/mise"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "leading temp HOME mise shim unexpectedly resolved to a later trusted node runtime"
  [[ ! -e "$mise_marker" ]] || fail "fixture-owned temp HOME mise root should not be consulted after fail-closed shim detection"
  [[ ! -e "$selected_marker" ]] || fail "fixture-owned temp HOME selected node runtime should not be executed after fail-closed shim detection"
  [[ ! -e "$found_marker" ]] || fail "discovered-but-unselected node runtime was executed unexpectedly"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "fake mise node shim should not be executed" "$output"
  [[ ! -e "$export_path" ]] || fail "fail-closed temp HOME mise shim path wrote export unexpectedly"
}

test_shell_adapter_fails_closed_on_fixture_home_cargo_shim_even_with_real_trusted_runtime_later() {
  local fixture repo home_dir output rc runtime_path shim_dir export_path
  fixture="$(setup_fixture leading_cargo_shim rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.cargo/bin"
  export_path="$repo/.claude/tmp/leading_cargo_shim.json"
  runtime_path="$shim_dir:$(real_allowlisted_runtime_path cargo)"

  write_hostile_path_binary "$shim_dir" cargo "fake cargo proxy should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "leading temp HOME cargo shim unexpectedly resolved to a later trusted cargo runtime"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "fake cargo proxy should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" cargo
  [[ ! -e "$export_path" ]] || fail "fail-closed cargo shim path wrote export unexpectedly"
}

test_shell_adapter_skips_cwd_cargo_for_dot_path_entry() {
  local fixture repo home_dir project_id output runtime_path real_cargo_dir
  fixture="$(setup_fixture dot_path_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  real_cargo_dir="$(real_allowlisted_cargo_dir)"
  runtime_path=".:${real_cargo_dir}:/usr/bin:/bin"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "fake cwd cargo should not be executed" >&2'
    printf '%s\n' 'exit 96'
  } > "$repo/cargo"
  chmod +x "$repo/cargo"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --project-id "$project_id" \
      --output "$repo/.claude/tmp/dot_path_cargo.json" 2>&1
  )"

  assert_not_contains "fake cwd cargo should not be executed" "$output"
  jq -e '.pending_count == 0 and .leased_count == 0' "$repo/.claude/tmp/dot_path_cargo.json" >/dev/null 2>&1 \
    || fail "dot-path cargo runtime test did not export expected queue state"
}

test_shell_adapter_skips_relative_cargo_path_entry() {
  local fixture repo home_dir project_id output runtime_path hostile_dir real_cargo_dir
  fixture="$(setup_fixture relative_path_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  project_id="$(project_id_read "$repo")"
  real_cargo_dir="$(real_allowlisted_cargo_dir)"
  runtime_path="rel/bin:${real_cargo_dir}:/usr/bin:/bin"
  hostile_dir="$repo/rel/bin"

  write_hostile_path_binary "$hostile_dir" cargo "fake relative cargo should not be executed"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --project-id "$project_id" \
      --output "$repo/.claude/tmp/relative_path_cargo.json" 2>&1
  )"

  assert_not_contains "fake relative cargo should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" cargo
  jq -e '.pending_count == 0 and .leased_count == 0' "$repo/.claude/tmp/relative_path_cargo.json" >/dev/null 2>&1 \
    || fail "relative cargo PATH entry test did not reject the non-dot relative runtime candidate"
}

test_shell_adapter_fails_closed_on_shim_only_cargo_rust_path() {
  local fixture repo home_dir output rc runtime_path shim_dir export_path
  fixture="$(setup_fixture shim_only_cargo rust)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.cargo/bin"
  export_path="$repo/.claude/tmp/shim_only_cargo.json"
  runtime_path="$shim_dir:$(path_without_binary cargo "$PATH")"

  write_hostile_path_binary "$shim_dir" cargo "fake cargo proxy should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "cargo-backed Rust path unexpectedly succeeded with shim-only PATH"
  assert_contains "semantic-review-queue.sh: cargo runtime not found" "$output"
  assert_not_contains "fake cargo proxy should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" cargo
  [[ ! -e "$export_path" ]] || fail "shim-only cargo fail-closed path wrote export unexpectedly"
}

test_shell_adapter_skips_cwd_node_for_empty_path_entry() {
  local fixture repo home_dir output runtime_path
  fixture="$(setup_fixture empty_path_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path=":$(real_allowlisted_runtime_path node)"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "fake cwd node should not be executed" >&2'
    printf '%s\n' 'exit 95'
  } > "$repo/node"
  chmod +x "$repo/node"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$repo/.claude/tmp/empty_path_node.json" 2>&1
  )"

  assert_not_contains "fake cwd node should not be executed" "$output"
  jq -e '.pending_count == 0 and .leased_count == 0' "$repo/.claude/tmp/empty_path_node.json" >/dev/null 2>&1 \
    || fail "empty-path node runtime test did not export expected queue state"
}

test_shell_adapter_skips_relative_node_path_entry() {
  local fixture repo home_dir output runtime_path hostile_dir
  fixture="$(setup_fixture relative_path_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  runtime_path="rel/bin:$(real_allowlisted_runtime_path node)"
  hostile_dir="$repo/rel/bin"

  write_hostile_path_binary "$hostile_dir" node "fake relative node should not be executed"

  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$repo/.claude/tmp/relative_path_node.json" 2>&1
  )"

  assert_not_contains "fake relative node should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$hostile_dir" node
  jq -e '.pending_count == 0 and .leased_count == 0' "$repo/.claude/tmp/relative_path_node.json" >/dev/null 2>&1 \
    || fail "relative node PATH entry test did not reject the non-dot relative runtime candidate"
}

test_shell_adapter_fails_closed_on_fixture_home_node_shim_even_with_real_trusted_runtime_later() {
  local fixture repo home_dir output rc runtime_path shim_dir export_path
  fixture="$(setup_fixture leading_node_shim)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.local/share/mise/shims"
  export_path="$repo/.claude/tmp/leading_node_shim.json"
  runtime_path="$shim_dir:$(real_allowlisted_runtime_path node)"

  write_hostile_path_binary "$shim_dir" node "fake mise node shim should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "leading temp HOME node shim unexpectedly resolved to a later trusted node runtime"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "fake mise node shim should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" node
  [[ ! -e "$export_path" ]] || fail "fail-closed node shim path wrote export unexpectedly"
}

test_shell_adapter_fails_closed_on_shim_only_node_fallback() {
  local fixture repo home_dir output rc runtime_path shim_dir export_path
  fixture="$(setup_fixture shim_only_node)"
  repo="${fixture%%|*}"
  home_dir="${fixture##*|}"
  shim_dir="$home_dir/.local/share/mise/shims"
  export_path="$repo/.claude/tmp/shim_only_node.json"
  runtime_path="$shim_dir:$(path_without_binary node "$PATH")"

  write_hostile_path_binary "$shim_dir" node "fake mise node shim should not be executed"

  set +e
  output="$(
    queue_shell "$repo" "$home_dir" "$runtime_path" \
      export-json \
      --output "$export_path" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || fail "node fallback unexpectedly succeeded with shim-only PATH"
  assert_contains "semantic-review-queue.sh: node runtime not found" "$output"
  assert_not_contains "fake mise node shim should not be executed" "$output"
  assert_hostile_path_binary_not_executed "$shim_dir" node
  [[ ! -e "$export_path" ]] || fail "shim-only node fail-closed path wrote export unexpectedly"
}

main() {
  require_cmd git
  require_cmd jq
  require_cmd cargo
  require_cmd node
  require_cmd mktemp

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/semantic_review_queue_runtime.XXXXXX")"
  printf 'RUN: semantic_review_queue_runtime_test tmp=%s\n' "$TMP_ROOT"

  test_direct_cli_unknown_token_fails_closed
  test_direct_cli_blank_explicit_source_is_rejected
  test_direct_cli_omitted_source_defaults_to_manual
  test_shell_ingress_omitted_source_defaults_to_manual
  test_public_ingress_rejects_absolute_enqueue_file_path
  test_public_ingress_rejects_traversal_enqueue_file_path
  test_public_ingress_rejects_leading_dash_enqueue_file_path
  test_public_ingress_rejects_repo_external_symlink_enqueue_file_path
  test_public_ingress_persists_canonical_repo_relative_enqueue_file_path
  test_public_ingress_enqueue_export_json_uses_single_backend_call
  test_reviewer_consumer_treats_leading_dash_queued_path_as_literal
  test_shell_adapter_rejects_incompatible_flags
  test_public_ingress_ignores_path_poisoned_bash_on_direct_exec
  test_public_ingress_ignores_path_poisoned_dirname_and_basename
  test_public_ingress_fails_closed_on_absolute_path_poisoned_cargo_even_with_trusted_runtime_later
  test_public_ingress_fails_closed_on_absolute_path_poisoned_cargo_only
  test_public_ingress_ignores_env_trust_widening_for_cargo
  test_public_ingress_fails_closed_on_absolute_path_poisoned_node_even_with_trusted_runtime_later
  test_public_ingress_fails_closed_on_absolute_path_poisoned_node_only
  test_public_ingress_ignores_env_trust_widening_for_node
  test_shell_adapter_does_not_propagate_node_options_to_trusted_node_runtime
  test_shell_adapter_pins_node_runtime_home_to_trusted_owner_root
  test_shell_adapter_internal_runtime_env_ignores_path_poisoned_id
  test_shell_adapter_does_not_propagate_rustc_wrapper_to_trusted_cargo_runtime
  test_shell_adapter_rejects_duplicate_singleton_flags
  test_queue_project_id_reads_repo_local_common_root_artifact_via_canonical_helper
  test_queue_project_id_fails_closed_when_repo_local_common_root_artifact_is_missing
  test_queue_project_id_fails_closed_when_repo_local_common_root_authoritative_artifact_is_multiline
  test_shell_adapter_fails_closed_on_fixture_home_local_bin_cargo_wrapper_even_with_real_trusted_runtime_later
  test_shell_adapter_fails_closed_on_fixture_home_local_bin_node_symlink_even_with_real_trusted_runtime_later
  test_shell_adapter_fails_closed_on_fixture_home_local_bin_cargo_symlink_even_with_real_trusted_runtime_later
  test_shell_adapter_fails_closed_on_symlinked_external_rust_workspace
  test_shell_adapter_ignores_legacy_only_rust_root_and_falls_back_to_node
  test_shell_adapter_falls_back_to_node_when_no_valid_rust_root_exists
  test_shell_adapter_fails_closed_on_symlinked_external_node_cli_entrypoint
  test_production_helper_fails_closed_when_mise_returns_symlinked_node_binary
  test_production_helper_fails_closed_when_rustup_returns_out_of_allowlist_cargo_binary
  test_production_helper_resolves_mise_shim_via_allowlisted_path_fallback
  test_production_helper_probes_hoisted_better_sqlite3_resolution
  test_production_helper_fails_closed_when_later_node_candidate_resolution_fails
  test_production_helper_skips_symlinked_manager_home_mise_and_uses_allowlisted_fallback
  test_production_helper_skips_symlinked_manager_home_mise_file_and_uses_allowlisted_fallback
  test_shell_adapter_fails_closed_on_fixture_home_mise_roots_for_leading_node_shim
  test_shell_adapter_fails_closed_on_fixture_home_cargo_shim_even_with_real_trusted_runtime_later
  test_shell_adapter_skips_cwd_cargo_for_dot_path_entry
  test_shell_adapter_skips_relative_cargo_path_entry
  test_shell_adapter_fails_closed_on_shim_only_cargo_rust_path
  test_shell_adapter_skips_cwd_node_for_empty_path_entry
  test_shell_adapter_skips_relative_node_path_entry
  test_shell_adapter_fails_closed_on_fixture_home_node_shim_even_with_real_trusted_runtime_later
  test_shell_adapter_fails_closed_on_shim_only_node_fallback
  test_success_complete_path
  test_zero_exit_request_changes_requeues
  test_failure_requeue_path
  test_invalid_format_requeues_without_raw_context_leak
  test_stale_json_is_not_authority
  test_partial_lease_loss_fails_closed

  printf 'PASS: semantic_review_queue_runtime_test\n'
}

main "$@"
