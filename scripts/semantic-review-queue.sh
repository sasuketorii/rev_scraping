#!/bin/bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  semantic-review-queue.sh enqueue --file-path PATH [--source SOURCE] [--repo-root PATH] [--export-json PATH]' \
    '  semantic-review-queue.sh lease --lease-run-id ID [--lease-seconds SECONDS] [--repo-root PATH]' \
    '  semantic-review-queue.sh drain --lease-run-id ID [--lease-seconds SECONDS] [--repo-root PATH]' \
    '  semantic-review-queue.sh complete --lease-owner OWNER --expected-file PATH [--expected-file PATH ...] [--lease-run-id ID] [--project-id ID] [--repo-root PATH]' \
    '  semantic-review-queue.sh requeue --lease-owner OWNER --expected-file PATH [--expected-file PATH ...] [--lease-run-id ID] --error MESSAGE [--project-id ID] [--repo-root PATH]' \
    '  semantic-review-queue.sh export-json --output PATH [--project-id ID] [--repo-root PATH]'
}

die() {
  printf 'semantic-review-queue.sh: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'semantic-review-queue.sh: WARN: %s\n' "$*" >&2
}

TRUSTED_RUNTIME_PASSTHROUGH_ENV_NAMES=(
  LANG
  LC_ALL
  LC_CTYPE
  TMPDIR
  TMP
  TEMP
  TERM
  CI
  NO_COLOR
  FORCE_COLOR
  COLORTERM
)
TRUSTED_RUNTIME_ENV_ASSIGNMENTS=()
RUST_WORKSPACE_RESOLUTION_STATE=""
RUST_WORKSPACE_RESOLUTION_ROOT=""
RUST_WORKSPACE_RESOLUTION_ERROR=""
RUST_SEMANTIC_BACKEND_ROOT=""
RUST_SEMANTIC_BACKEND_MANIFEST=""
RUST_SEMANTIC_BACKEND_MAIN=""

script_dir() {
  local source_path="${BASH_SOURCE[0]}"
  case "$source_path" in
    */*)
      cd "${source_path%/*}" && pwd -P
      ;;
    *)
      pwd -P
      ;;
  esac
}

canonicalize_dir() {
  local dir_path="${1:-}"
  [[ -n "$dir_path" ]] || die "directory path is required"
  [[ -d "$dir_path" ]] || die "directory does not exist: $dir_path"
  (
    cd "$dir_path" && pwd -P
  )
}

resolve_existing_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" ]] || die "path is required"

  local parent_dir=""
  local base_name=""
  local canonical_parent=""

  parent_dir="$(path_parent_dir "$path_value")"
  base_name="$(path_leaf_name "$path_value")"
  canonical_parent="$(canonicalize_dir "$parent_dir")"

  [[ -e "$canonical_parent/$base_name" ]] || die "path does not exist: $path_value"
  printf '%s/%s\n' "$canonical_parent" "$base_name"
}

path_within_root() {
  local candidate="${1:-}"
  local root="${2:-}"
  [[ -n "$candidate" && -n "$root" ]] || return 1
  [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
}

assert_no_symlink_components() {
  local root="${1:-}"
  local path_value="${2:-}"
  [[ -n "$root" && -n "$path_value" ]] || die "root and path are required"

  local normalized_root=""
  local relative_path=""
  local current=""
  local component=""
  local -a path_components=()

  normalized_root="$(canonicalize_dir "$root")"
  [[ "$path_value" == "$normalized_root" || "$path_value" == "$normalized_root/"* ]] \
    || die "path escapes repo-local identity root: $path_value"

  relative_path="${path_value#$normalized_root}"
  relative_path="${relative_path#/}"

  current="$normalized_root"
  IFS='/' read -r -a path_components < <(printf '%s\n' "$relative_path")
  for component in "${path_components[@]}"; do
    [[ -n "$component" ]] || continue
    [[ "$component" != "." && "$component" != ".." ]] \
      || die "path must not contain traversal components: $path_value"
    current="$current/$component"
    if [[ -L "$current" ]]; then
      die "path contains symlink component: $current"
    fi
  done
}

trim_trailing_slash() {
  local path_value="${1:-}"
  while [[ "$path_value" != "/" && "$path_value" == */ ]]; do
    path_value="${path_value%/}"
  done
  printf '%s\n' "$path_value"
}

trim_ascii_whitespace() {
  local value="${1-}"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s\n' "$value"
}

path_parent_dir() {
  local path_value="${1:-}"
  local parent_dir=""

  [[ -n "$path_value" ]] || die "path is required"
  path_value="$(trim_trailing_slash "$path_value")"
  if [[ "$path_value" == "/" ]]; then
    printf '/\n'
    return 0
  fi

  case "$path_value" in
    */*)
      parent_dir="${path_value%/*}"
      [[ -n "$parent_dir" ]] || parent_dir="/"
      printf '%s\n' "$parent_dir"
      ;;
    *)
      printf '.\n'
      ;;
  esac
}

path_leaf_name() {
  local path_value="${1:-}"

  [[ -n "$path_value" ]] || die "path is required"
  path_value="$(trim_trailing_slash "$path_value")"
  if [[ "$path_value" == "/" ]]; then
    printf '/\n'
    return 0
  fi

  case "$path_value" in
    */*)
      printf '%s\n' "${path_value##*/}"
      ;;
    *)
      printf '%s\n' "$path_value"
      ;;
  esac
}

canonicalize_queue_enqueue_file_path() {
  local repo_root="${1:-}"
  local raw_path="${2:-}"
  local normalized_root=""
  local normalized_path=""
  local current_path=""
  local component=""
  local candidate=""
  local canonical_relative=""
  local -a components=()

  [[ -n "$repo_root" ]] || die "repo root is required"
  [[ -n "$raw_path" ]] || die "file_path must not be empty"
  [[ ! "$raw_path" =~ [[:cntrl:]] ]] || die "file_path must not contain control bytes"

  normalized_root="$(canonicalize_dir "$repo_root")" || die "repo root must exist: $repo_root"
  normalized_path="$(trim_ascii_whitespace "$raw_path")"
  [[ -n "$normalized_path" ]] || die "file_path must not be empty"

  case "$normalized_path" in
    /*|[A-Za-z]:/*)
      die "file_path must be repo-relative"
      ;;
  esac

  normalized_path="${normalized_path//\\//}"
  while [[ "$normalized_path" == ./* ]]; do
    normalized_path="${normalized_path#./}"
  done
  normalized_path="$(trim_trailing_slash "$normalized_path")"
  [[ -n "$normalized_path" ]] || die "file_path must not be empty"

  current_path="$normalized_root"
  IFS='/' read -r -a components < <(printf '%s\n' "$normalized_path")
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    case "$component" in
      .)
        continue
        ;;
      ..)
        die "file_path must not contain traversal components: $raw_path"
        ;;
      -*)
        die "file_path must not contain leading-dash components: $raw_path"
        ;;
    esac
    if [[ -n "$canonical_relative" ]]; then
      canonical_relative="${canonical_relative}/"
    fi
    canonical_relative="${canonical_relative}${component}"
    current_path="${current_path}/${component}"
    if [[ -L "$current_path" ]]; then
      die "file_path resolves through a symlinked path: $raw_path"
    fi
  done

  [[ -n "$canonical_relative" ]] || die "file_path must not be empty"
  candidate="${normalized_root}/${canonical_relative}"
  path_within_root "$candidate" "$normalized_root" \
    || die "file_path resolves outside repo_root: $raw_path"

  printf '%s\n' "$canonical_relative"
}

trusted_system_binary_path() {
  local binary_name="${1:-}"
  local candidate=""

  [[ "$binary_name" =~ ^[A-Za-z0-9._+-]+$ ]] || die "trusted system binary name is invalid: $binary_name"

  for candidate in "/usr/bin/$binary_name" "/bin/$binary_name"; do
    [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

trusted_runtime_owner_user() {
  local user_name=""
  local id_bin=""

  id_bin="$(trusted_system_binary_path id || true)"
  [[ -n "$id_bin" ]] || die "trusted system id binary is required to determine runtime owner user"
  user_name="$("$id_bin" -un 2>/dev/null)" || die "failed to determine runtime owner user"
  [[ "$user_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "runtime owner user is invalid: $user_name"
  printf '%s\n' "$user_name"
}

trusted_runtime_owner_home() {
  local user_name=""
  local owner_home=""

  user_name="$(trusted_runtime_owner_user)"
  eval "owner_home=~${user_name}"
  [[ -n "$owner_home" && "$owner_home" == /* ]] || die "failed to resolve runtime owner home for ${user_name}"
  canonicalize_dir "$owner_home"
}

resolve_node_runtime_home() {
  trusted_runtime_owner_home
}

semantic_mcp_server_root() {
  local repo_root="${1:-}"
  local root=""

  if [[ -n "$repo_root" ]]; then
    root="$(cd "$repo_root/scripts/semantic-mcp-server" && pwd -P)" || return 1
  else
    root="$(cd "$(script_dir)/semantic-mcp-server" && pwd -P)" || return 1
  fi
  [[ -d "$root" ]] || return 1
  printf '%s\n' "$root"
}

trusted_runtime_dir_patterns() {
  local home_dir=""
  home_dir="$(trim_trailing_slash "$(trusted_runtime_owner_home)")"

  printf '%s\n' "/usr/bin"
  printf '%s\n' "/bin"
  printf '%s\n' "/usr/local/bin"
  printf '%s\n' "/opt/homebrew/bin"
  printf '%s\n' "/Applications/Codex.app/Contents/Resources"

  printf '%s\n' "$home_dir/.cargo/bin"
  printf '%s\n' "$home_dir/.rustup/toolchains/*/bin"
  printf '%s\n' "$home_dir/.local/bin"
  printf '%s\n' "$home_dir/.local/share/mise/shims"
  printf '%s\n' "$home_dir/.local/share/mise/installs/*/*/bin"
  printf '%s\n' "$home_dir/.mise/shims"
  printf '%s\n' "$home_dir/.mise/installs/*/*/bin"
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

is_likely_runtime_shim() {
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
  is_likely_runtime_shim "$binary_name" "$resolved" && return 1
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
  is_trusted_runtime_binary "$rustup_bin" >/dev/null || return 1

  resolved="$(
    HOME="$manager_home" \
    CARGO_HOME="$cargo_home" \
    RUSTUP_HOME="$rustup_home" \
    PATH="$(sanitize_runtime_path "$path_value")" \
    "$rustup_bin" which cargo 2>/dev/null
  )" || return 1

  is_trusted_runtime_binary "$resolved" || return 1
  is_likely_runtime_shim cargo "$resolved" && return 1
  printf '%s\n' "$resolved"
}

resolve_rust_toolchain_bin() {
  local cargo_path="${1:-}"
  case "$cargo_path" in
    */.rustup/toolchains/*/bin/cargo)
      printf '%s\n' "${cargo_path%/cargo}"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_cargo_runtime_home() {
  local cargo_path="${1:-}"
  is_trusted_runtime_binary "$cargo_path" || return 1
  trusted_runtime_owner_home
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

  [[ -n "$after_dir" ]] || return 1
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

path_contains_runtime_executable() {
  local binary_name="${1:-}"
  local path_value="${2:-$PATH}"
  local remaining="${path_value}:"
  local path_dir=""

  while [[ "$remaining" == *:* ]]; do
    path_dir="${remaining%%:*}"
    remaining="${remaining#*:}"
    [[ -n "$path_dir" && "$path_dir" == /* ]] || continue
    [[ -x "${path_dir%/}/${binary_name}" && ! -d "${path_dir%/}/${binary_name}" ]] || continue
    return 0
  done

  return 1
}

resolve_runtime_candidate() {
  local binary_name="${1:-}"
  local candidate="${2:-}"
  local path_value="${3:-$PATH}"
  local resolved=""

  [[ -n "$candidate" ]] || return 1

  if ! is_likely_runtime_shim "$binary_name" "$candidate"; then
    is_trusted_runtime_binary "$candidate" >/dev/null || return 1
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

  return 1
}

resolve_runtime_binary() {
  local binary_name="${1:-}"
  local path_value="${2:-$PATH}"
  local candidate=""
  candidate="$(first_runtime_candidate "$binary_name" "$path_value")" || return 1
  resolve_runtime_candidate "$binary_name" "$candidate" "$path_value"
}

is_skippable_symlinked_node_runtime_candidate() {
  local candidate="${1:-}"
  [[ -L "$candidate" ]] || return 1
  case "$candidate" in
    /opt/homebrew/bin/node|/usr/local/bin/node)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

node_binary_supports_semantic_queue() {
  local binary_path="${1:-}"
  local repo_root="${2:-}"
  local server_root=""
  local runtime_home=""
  local exec_path=""

  [[ -n "$binary_path" && -x "$binary_path" ]] || return 1
  server_root="$(semantic_mcp_server_root "$repo_root")" || return 1
  runtime_home="$(trusted_runtime_owner_home)" || return 1
  exec_path="$(runtime_binary_dir "$binary_path"):/usr/bin:/bin"

  (
    cd "$server_root" && \
      printf '%s\n' \
        'const Database = require("better-sqlite3");' \
        'const db = new Database(":memory:");' \
        'db.prepare("SELECT 1").get();' \
        'db.close();' \
        | /usr/bin/env -i "PATH=$exec_path" "HOME=$runtime_home" "$binary_path" - >/dev/null 2>&1
  )
}

node_semantic_queue_dependency_present() {
  local repo_root="${1:-}"
  local server_root=""
  server_root="$(semantic_mcp_server_root "$repo_root")" || return 1
  [[ -e "$server_root/node_modules/better-sqlite3" ]]
}

node_runtime_fallback_candidates() {
  local home_dir=""
  local candidate_dir=""
  local canonical_dir=""

  home_dir="$(trim_trailing_slash "$(trusted_runtime_owner_home)")" || return 1
  for candidate_dir in \
    "$home_dir"/.local/share/mise/installs/node/*/bin \
    "$home_dir"/.mise/installs/node/*/bin; do
    [[ -x "$candidate_dir/node" && ! -d "$candidate_dir/node" ]] || continue
    canonical_dir="$(canonical_safe_runtime_path_entry "$candidate_dir" 2>/dev/null || true)"
    [[ -n "$canonical_dir" ]] || continue
    printf '%s/node\n' "$canonical_dir"
  done
}

node_runtime_candidates() {
  local path_value="${1:-$PATH}"
  local candidate=""
  local after_dir=""

  if candidate="$(first_runtime_candidate node "$path_value")"; then
    printf '%s\n' "$candidate"
    after_dir="$(runtime_binary_dir "$candidate")" || after_dir=""
    while [[ -n "$after_dir" ]] && candidate="$(first_runtime_candidate_after node "$path_value" "$after_dir")"; do
      printf '%s\n' "$candidate"
      after_dir="$(runtime_binary_dir "$candidate")" || break
    done
  elif path_contains_runtime_executable node "$path_value"; then
    return 0
  fi
  node_runtime_fallback_candidates
}

resolve_compatible_node_binary() {
  local path_value="${1:-$PATH}"
  local repo_root="${2:-}"
  local candidate=""
  local resolved=""
  local last_probe_error=""
  local saw_candidate=0
  local seen_candidates=$'\n'

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    saw_candidate=1
    case "$seen_candidates" in
      *$'\n'"$candidate"$'\n'*) continue ;;
    esac
    seen_candidates+="$candidate"$'\n'
    if ! resolved="$(resolve_runtime_candidate node "$candidate" "$path_value")"; then
      last_probe_error="trusted node runtime candidate rejected before compatibility probe: $candidate"
      is_skippable_symlinked_node_runtime_candidate "$candidate" || return 1
      continue
    fi
    if ! node_semantic_queue_dependency_present "$repo_root"; then
      printf '%s\n' "$resolved"
      return 0
    fi
    if node_binary_supports_semantic_queue "$resolved" "$repo_root"; then
      printf '%s\n' "$resolved"
      return 0
    fi
    last_probe_error="trusted node runtime is incompatible with semantic queue backend: $resolved"
  done < <(node_runtime_candidates "$path_value")

  if [[ -n "$last_probe_error" ]]; then
    printf '%s\n' "$last_probe_error" >&2
  elif [[ "$saw_candidate" -eq 0 ]]; then
    printf '%s\n' "no trusted node runtime candidates found in PATH or mise installs" >&2
  fi
  return 1
}

resolve_node_binary() {
  resolve_compatible_node_binary "${1:-$PATH}" "${2:-}"
}

resolve_cargo_binary() {
  resolve_runtime_binary cargo "${1:-$PATH}"
}

emit_runtime_env() {
  local binary_name="${1:-}"
  local runtime_path="${2:-$PATH}"
  local repo_root="${3:-}"

  resolve_runtime_env_values "$binary_name" "$runtime_path" "$repo_root"
  printf 'RUNTIME_BINARY=%q\n' "$RUNTIME_BINARY"
  printf 'RUNTIME_PATH=%q\n' "$RUNTIME_PATH"
  printf 'RUNTIME_TOOLCHAIN_BIN=%q\n' "${RUNTIME_TOOLCHAIN_BIN:-}"
  printf 'RUNTIME_HOME=%q\n' "$RUNTIME_HOME"
  printf 'RUNTIME_CARGO_HOME=%q\n' "${RUNTIME_CARGO_HOME:-}"
  printf 'RUNTIME_RUSTUP_HOME=%q\n' "${RUNTIME_RUSTUP_HOME:-}"
}

emit_runtime_env_json() {
  local binary_name="${1:-}"
  local runtime_path="${2:-$PATH}"
  local repo_root="${3:-}"

  resolve_runtime_env_values "$binary_name" "$runtime_path" "$repo_root"
  jq -n \
    --arg runtime_binary "$RUNTIME_BINARY" \
    --arg runtime_path "$RUNTIME_PATH" \
    --arg runtime_toolchain_bin "${RUNTIME_TOOLCHAIN_BIN:-}" \
    --arg runtime_home "$RUNTIME_HOME" \
    --arg runtime_cargo_home "${RUNTIME_CARGO_HOME:-}" \
    --arg runtime_rustup_home "${RUNTIME_RUSTUP_HOME:-}" \
    '{
      runtime_binary: $runtime_binary,
      runtime_path: $runtime_path,
      runtime_toolchain_bin: $runtime_toolchain_bin,
      runtime_home: $runtime_home,
      runtime_cargo_home: $runtime_cargo_home,
      runtime_rustup_home: $runtime_rustup_home
    }'
}

resolve_runtime_env_values() {
  local binary_name="${1:-}"
  local runtime_path="${2:-$PATH}"
  local repo_root="${3:-}"
  local raw_runtime_path="$runtime_path"
  local runtime_binary=""
  local runtime_home=""
  local runtime_cargo_home=""
  local runtime_rustup_home=""
  local runtime_toolchain_bin=""

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || die "unsupported runtime binary: $binary_name"

  runtime_path="$(sanitize_runtime_path "$runtime_path")"
  if [[ "$binary_name" == "cargo" ]]; then
    runtime_binary="$(resolve_cargo_binary "$raw_runtime_path")" || die "cargo runtime not found"
    runtime_home="$(resolve_cargo_runtime_home "$runtime_binary")" || die "cargo runtime home not trusted"
    runtime_cargo_home="${runtime_home}/.cargo"
    runtime_rustup_home="${runtime_home}/.rustup"
    runtime_toolchain_bin="$(resolve_rust_toolchain_bin "$runtime_binary" || true)"
  else
    runtime_binary="$(resolve_node_binary "$raw_runtime_path" "$repo_root")" || die "node runtime not found"
    runtime_home="$(resolve_node_runtime_home)" || die "node runtime home not trusted"
  fi

  RUNTIME_BINARY="$runtime_binary"
  RUNTIME_PATH="$runtime_path"
  RUNTIME_TOOLCHAIN_BIN="$runtime_toolchain_bin"
  RUNTIME_HOME="$runtime_home"
  RUNTIME_CARGO_HOME="$runtime_cargo_home"
  RUNTIME_RUSTUP_HOME="$runtime_rustup_home"
}

load_runtime_env() {
  local binary_name="${1:-}"
  local raw_runtime_path="${2:-$PATH}"
  local repo_root="${3:-}"

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || die "unsupported runtime binary: $binary_name"
  resolve_runtime_env_values "$binary_name" "$raw_runtime_path" "$repo_root"
}

trusted_runtime_exec_path() {
  local binary_name="${1:-}"
  local exec_path="${RUNTIME_PATH:-}"

  if [[ "$binary_name" == "cargo" && -n "${RUNTIME_TOOLCHAIN_BIN:-}" ]]; then
    exec_path="${RUNTIME_TOOLCHAIN_BIN}${exec_path:+:${exec_path}}"
  fi

  printf '%s\n' "$exec_path"
}

append_trusted_runtime_passthrough_env() {
  local env_name="${1:-}"
  local env_value=""

  [[ -n "$env_name" ]] || die "trusted runtime passthrough env name is required"
  eval "env_value=\${${env_name}:-}"
  [[ -n "$env_value" ]] || return 0
  TRUSTED_RUNTIME_ENV_ASSIGNMENTS+=("${env_name}=${env_value}")
}

trusted_runtime_override_allowed() {
  local env_name="${1:-}"

  case "$env_name" in
    RUSTFLAGS)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_trusted_runtime_override_env() {
  local assignment="${1:-}"
  local env_name=""

  [[ "$assignment" == *=* ]] || die "trusted runtime env override must be NAME=VALUE: $assignment"
  env_name="${assignment%%=*}"
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "trusted runtime env override name is invalid: $env_name"
  trusted_runtime_override_allowed "$env_name" \
    || die "trusted runtime env override is not allowed: $env_name"
  TRUSTED_RUNTIME_ENV_ASSIGNMENTS+=("$assignment")
}

build_trusted_runtime_env_assignments() {
  local binary_name="${1:-}"
  shift || true
  local exec_path=""
  local passthrough_name=""

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || die "unsupported runtime binary: $binary_name"
  [[ -n "${RUNTIME_BINARY:-}" ]] || die "trusted runtime binary is required"

  exec_path="$(trusted_runtime_exec_path "$binary_name")"
  [[ -n "$exec_path" ]] || die "trusted runtime PATH is required"
  [[ -n "${RUNTIME_HOME:-}" ]] || die "trusted runtime HOME is required"

  TRUSTED_RUNTIME_ENV_ASSIGNMENTS=(
    "PATH=$exec_path"
    "HOME=$RUNTIME_HOME"
  )

  if [[ "$binary_name" == "cargo" ]]; then
    [[ -n "${RUNTIME_CARGO_HOME:-}" ]] || die "trusted cargo CARGO_HOME is required"
    [[ -n "${RUNTIME_RUSTUP_HOME:-}" ]] || die "trusted cargo RUSTUP_HOME is required"
    TRUSTED_RUNTIME_ENV_ASSIGNMENTS+=(
      "CARGO_HOME=$RUNTIME_CARGO_HOME"
      "RUSTUP_HOME=$RUNTIME_RUSTUP_HOME"
    )
  fi

  for passthrough_name in "${TRUSTED_RUNTIME_PASSTHROUGH_ENV_NAMES[@]}"; do
    append_trusted_runtime_passthrough_env "$passthrough_name"
  done

  while [[ $# -gt 0 ]]; do
    append_trusted_runtime_override_env "$1"
    shift
  done
}

run_trusted_runtime() {
  local binary_name="${1:-}"
  shift || true
  local repo_root=""
  local override_assignments=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || die "trusted runtime --repo-root requires a value"
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --env)
        [[ $# -ge 2 ]] || die "trusted runtime --env requires NAME=VALUE"
        override_assignments+=("$2")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  [[ $# -gt 0 ]] || die "trusted runtime command arguments are required"
  load_runtime_env "$binary_name" "$PATH" "$repo_root"
  if [[ ${#override_assignments[@]} -gt 0 ]]; then
    build_trusted_runtime_env_assignments "$binary_name" "${override_assignments[@]}"
  else
    build_trusted_runtime_env_assignments "$binary_name"
  fi
  /usr/bin/env -i "${TRUSTED_RUNTIME_ENV_ASSIGNMENTS[@]}" "$RUNTIME_BINARY" "$@"
}

exec_trusted_runtime() {
  local binary_name="${1:-}"
  shift || true
  local repo_root=""
  local override_assignments=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || die "trusted runtime --repo-root requires a value"
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --env)
        [[ $# -ge 2 ]] || die "trusted runtime --env requires NAME=VALUE"
        override_assignments+=("$2")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  [[ $# -gt 0 ]] || die "trusted runtime command arguments are required"
  load_runtime_env "$binary_name" "$PATH" "$repo_root"
  if [[ ${#override_assignments[@]} -gt 0 ]]; then
    build_trusted_runtime_env_assignments "$binary_name" "${override_assignments[@]}"
  else
    build_trusted_runtime_env_assignments "$binary_name"
  fi
  exec /usr/bin/env -i "${TRUSTED_RUNTIME_ENV_ASSIGNMENTS[@]}" "$RUNTIME_BINARY" "$@"
}

trusted_runtime_available() {
  local binary_name="${1:-}"
  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || return 1
  load_runtime_env "$binary_name" "$PATH" >/dev/null 2>&1
}

rust_workspace_candidate_roots() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"
  printf '%s\n' "$root/harness-rust"
}

reset_rust_workspace_resolution() {
  RUST_WORKSPACE_RESOLUTION_STATE=""
  RUST_WORKSPACE_RESOLUTION_ROOT=""
  RUST_WORKSPACE_RESOLUTION_ERROR=""
}

append_rust_workspace_resolution_error() {
  local message="${1:-}"
  [[ -n "$message" ]] || return 0
  if [[ -n "$RUST_WORKSPACE_RESOLUTION_ERROR" ]]; then
    RUST_WORKSPACE_RESOLUTION_ERROR="${RUST_WORKSPACE_RESOLUTION_ERROR}; ${message}"
  else
    RUST_WORKSPACE_RESOLUTION_ERROR="$message"
  fi
}

probe_rust_workspace_root() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"

  reset_rust_workspace_resolution

  local normalized_root=""
  local candidate=""
  local resolved_candidate=""
  local manifest_path=""
  local resolved_manifest_parent=""
  local valid_count=0
  local -a valid_candidates=()

  normalized_root="$(canonicalize_dir "$root")" || die "repo root must exist: $root"

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ ! -e "$candidate" ]]; then
      continue
    fi
    if [[ -L "$candidate" ]]; then
      append_rust_workspace_resolution_error \
        "Rust workspace candidate must not be a symlink: $candidate"
      continue
    fi
    if ! (assert_no_symlink_components "$normalized_root" "$candidate") >/dev/null 2>&1; then
      append_rust_workspace_resolution_error \
        "Rust workspace candidate contains a symlink component: $candidate"
      continue
    fi
    if [[ ! -d "$candidate" ]]; then
      append_rust_workspace_resolution_error \
        "Rust workspace candidate is not a directory: $candidate"
      continue
    fi

    resolved_candidate="$(
      cd "$candidate" && pwd -P
    )" || {
      append_rust_workspace_resolution_error \
        "Rust workspace candidate could not be canonicalized: $candidate"
      continue
    }
    if ! path_within_root "$resolved_candidate" "$normalized_root"; then
      append_rust_workspace_resolution_error \
        "Rust workspace candidate resolves outside repo root: $candidate -> $resolved_candidate"
      continue
    fi

    manifest_path="${candidate}/Cargo.toml"
    if [[ -L "$manifest_path" ]]; then
      append_rust_workspace_resolution_error \
        "Rust workspace manifest must not be a symlink: $manifest_path"
      continue
    fi
    if [[ ! -f "$manifest_path" ]]; then
      append_rust_workspace_resolution_error \
        "Rust workspace candidate is missing Cargo.toml: $candidate"
      continue
    fi
    if ! (assert_no_symlink_components "$normalized_root" "$manifest_path") >/dev/null 2>&1; then
      append_rust_workspace_resolution_error \
        "Rust workspace manifest contains a symlink component: $manifest_path"
      continue
    fi
    resolved_manifest_parent="$(
      cd "${manifest_path%/*}" && pwd -P
    )" || {
      append_rust_workspace_resolution_error \
        "Rust workspace manifest parent could not be canonicalized: $manifest_path"
      continue
    }
    if ! path_within_root "$resolved_manifest_parent/${manifest_path##*/}" "$normalized_root"; then
      append_rust_workspace_resolution_error \
        "Rust workspace manifest resolves outside repo root: $manifest_path"
      continue
    fi

    valid_candidates+=("$candidate")
    valid_count=$((valid_count + 1))
  done < <(rust_workspace_candidate_roots "$normalized_root")

  if [[ -n "$RUST_WORKSPACE_RESOLUTION_ERROR" ]]; then
    RUST_WORKSPACE_RESOLUTION_STATE="invalid"
    return 1
  fi
  if [[ "$valid_count" -eq 0 ]]; then
    RUST_WORKSPACE_RESOLUTION_STATE="absent"
    return 3
  fi
  if [[ "$valid_count" -gt 1 ]]; then
    RUST_WORKSPACE_RESOLUTION_STATE="ambiguous"
    RUST_WORKSPACE_RESOLUTION_ERROR="multiple valid Rust workspace roots detected: ${valid_candidates[*]}"
    return 4
  fi

  RUST_WORKSPACE_RESOLUTION_STATE="valid"
  RUST_WORKSPACE_RESOLUTION_ROOT="${valid_candidates[0]}"
}

resolved_rust_workspace_root() {
  local root="${1:-}"
  probe_rust_workspace_root "$root" || true
  case "$RUST_WORKSPACE_RESOLUTION_STATE" in
    valid)
      printf '%s\n' "$RUST_WORKSPACE_RESOLUTION_ROOT"
      ;;
    absent)
      die "Rust workspace root not found; checked harness-rust"
      ;;
    ambiguous|invalid)
      die "$RUST_WORKSPACE_RESOLUTION_ERROR"
      ;;
    *)
      die "invalid Rust workspace resolver state"
      ;;
  esac
}

rust_semantic_manifest_path() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" ]] || die "Rust workspace root is required"
  printf '%s\n' "$workspace_root/Cargo.toml"
}

rust_semantic_main_path() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" ]] || die "Rust workspace root is required"
  printf '%s\n' "$workspace_root/crates/semantic-mcp/src/main.rs"
}

is_repo_local_real_path() {
  local root="${1:-}"
  local candidate="${2:-}"
  [[ -n "$root" && -n "$candidate" ]] || return 1
  [[ -e "$candidate" ]] || return 1

  local normalized_root=""
  local resolved_candidate=""

  normalized_root="$(canonicalize_dir "$root")" || return 1
  [[ "$candidate" == "$normalized_root" || "$candidate" == "$normalized_root/"* ]] || return 1

  if ! (assert_no_symlink_components "$normalized_root" "$candidate") >/dev/null 2>&1; then
    return 1
  fi

  if [[ -d "$candidate" ]]; then
    resolved_candidate="$(canonicalize_dir "$candidate")" || return 1
  else
    resolved_candidate="$(resolve_existing_path "$candidate")" || return 1
  fi

  path_within_root "$resolved_candidate" "$normalized_root"
}

resolve_rust_semantic_backend() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"

  local workspace_root=""
  local manifest_path=""
  local main_path=""

  reset_rust_workspace_resolution
  probe_rust_workspace_root "$root" || true
  case "$RUST_WORKSPACE_RESOLUTION_STATE" in
    absent)
      return 3
      ;;
    ambiguous|invalid)
      return 4
      ;;
    valid)
      workspace_root="$RUST_WORKSPACE_RESOLUTION_ROOT"
      ;;
    *)
      RUST_WORKSPACE_RESOLUTION_ERROR="invalid Rust workspace resolver state"
      return 4
      ;;
  esac

  manifest_path="$(rust_semantic_manifest_path "$workspace_root")"
  main_path="$(rust_semantic_main_path "$workspace_root")"

  if [[ ! -f "$main_path" ]]; then
    RUST_WORKSPACE_RESOLUTION_STATE="invalid"
    RUST_WORKSPACE_RESOLUTION_ERROR="resolved Rust workspace root is missing semantic-mcp entrypoint: $main_path"
    return 4
  fi
  if ! is_repo_local_real_path "$root" "$workspace_root"; then
    RUST_WORKSPACE_RESOLUTION_STATE="invalid"
    RUST_WORKSPACE_RESOLUTION_ERROR="resolved Rust workspace root must be a repo-local real directory: $workspace_root"
    return 4
  fi
  if ! is_repo_local_real_path "$root" "$manifest_path"; then
    RUST_WORKSPACE_RESOLUTION_STATE="invalid"
    RUST_WORKSPACE_RESOLUTION_ERROR="resolved Rust workspace manifest must be a repo-local real file: $manifest_path"
    return 4
  fi
  if ! is_repo_local_real_path "$root" "$main_path"; then
    RUST_WORKSPACE_RESOLUTION_STATE="invalid"
    RUST_WORKSPACE_RESOLUTION_ERROR="resolved semantic-mcp entrypoint must be a repo-local real file: $main_path"
    return 4
  fi

  RUST_SEMANTIC_BACKEND_ROOT="$workspace_root"
  RUST_SEMANTIC_BACKEND_MANIFEST="$manifest_path"
  RUST_SEMANTIC_BACKEND_MAIN="$main_path"
  return 0
}

semantic_node_cli_entrypoint() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"

  local cli_entrypoint="${root}/scripts/semantic-mcp-server/dist/cli.js"
  [[ -f "$cli_entrypoint" ]] || die "semantic MCP CLI entrypoint not found: $cli_entrypoint"
  is_repo_local_real_path "$root" "$cli_entrypoint" \
    || die "semantic MCP CLI entrypoint must be a repo-local real file: $cli_entrypoint"
  printf '%s\n' "$cli_entrypoint"
}

run_cli() {
  local repo_root="$1"
  shift
  local cli_entrypoint=""
  local rust_backend_status=0

  if resolve_rust_semantic_backend "$repo_root"; then
    run_trusted_runtime \
      cargo \
      -- \
      run \
      --quiet \
      --manifest-path "$RUST_SEMANTIC_BACKEND_MANIFEST" \
      -p semantic-mcp \
      -- \
      "$@"
    return $?
  else
    rust_backend_status=$?
    case "$rust_backend_status" in
      3)
        ;;
      4)
        die "$RUST_WORKSPACE_RESOLUTION_ERROR"
        ;;
      *)
        die "invalid Rust semantic backend resolver state"
        ;;
    esac
  fi

  cli_entrypoint="$(semantic_node_cli_entrypoint "$repo_root")"
  run_trusted_runtime node --repo-root "$repo_root" -- "$cli_entrypoint" "$@"
}

internal_rust_workspace_root_main() {
  local repo_root=""
  local allow_absent=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || die "__internal-rust-workspace-root requires --repo-root value"
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --allow-absent)
        allow_absent=1
        shift
        ;;
      *)
        die "unknown argument for __internal-rust-workspace-root: $1"
        ;;
    esac
  done

  if [[ -z "$repo_root" ]]; then
    repo_root="$(canonicalize_dir "$(script_dir)/..")"
  fi

  probe_rust_workspace_root "$repo_root" || true
  case "$RUST_WORKSPACE_RESOLUTION_STATE" in
    valid)
      printf '%s\n' "$RUST_WORKSPACE_RESOLUTION_ROOT"
      ;;
    absent)
      if [[ "$allow_absent" -eq 1 ]]; then
        return 3
      fi
      die "Rust workspace root not found; checked harness-rust"
      ;;
    ambiguous|invalid)
      die "$RUST_WORKSPACE_RESOLUTION_ERROR"
      ;;
    *)
      die "invalid Rust workspace resolver state"
      ;;
  esac
}

can_exec_repo_local_rust_backend() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"

  if ! resolve_rust_semantic_backend "$root"; then
    return $?
  fi
  trusted_runtime_available cargo || return 1
  return 0
}

flag_allowed_for_command() {
  local command="$1"
  local flag="$2"

  case "$command" in
    enqueue)
      case "$flag" in
        --repo-root|--file-path|--source|--export-json)
          return 0
          ;;
      esac
      ;;
    lease|drain)
      case "$flag" in
        --repo-root|--lease-run-id|--lease-seconds)
          return 0
          ;;
      esac
      ;;
    complete)
      case "$flag" in
        --repo-root|--lease-owner|--expected-file|--lease-run-id|--project-id)
          return 0
          ;;
      esac
      ;;
    requeue)
      case "$flag" in
        --repo-root|--lease-owner|--expected-file|--lease-run-id|--project-id|--error)
          return 0
          ;;
      esac
      ;;
    export-json)
      case "$flag" in
        --repo-root|--project-id|--output)
          return 0
          ;;
      esac
      ;;
  esac

  return 1
}

validate_command_flags() {
  local command="$1"
  shift
  local seen_flags=("$@")
  local validated_flags=()
  local flag=""
  local validated_flag=""

  for flag in "${seen_flags[@]}"; do
    if ! flag_allowed_for_command "$command" "$flag"; then
      die "$command does not allow $flag"
    fi

    case "$command:$flag" in
      complete:--expected-file|requeue:--expected-file)
        validated_flags+=("$flag")
        continue
        ;;
    esac

    if [[ "${#validated_flags[@]}" -gt 0 ]]; then
      for validated_flag in "${validated_flags[@]}"; do
        [[ "$validated_flag" == "$flag" ]] || continue
        die "duplicate flag: $flag"
      done
    fi

    validated_flags+=("$flag")
  done
}

resolve_project_id() {
  local repo_root="$1"
  local resolver="$(script_dir)/resolve-semantic-project-id.sh"
  [[ -x "$resolver" ]] || die "project_id resolver not found or not executable: $resolver"
  /bin/bash "$resolver" --repo-root "$repo_root" --print
}

internal_runtime_env_main() {
  local binary_name=""
  local repo_root=""
  local output_format="shell"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary)
        [[ $# -ge 2 ]] || die "__internal-runtime-env requires --binary value"
        binary_name="$2"
        shift 2
        ;;
      --repo-root)
        [[ $# -ge 2 ]] || die "__internal-runtime-env requires --repo-root value"
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --json)
        output_format="json"
        shift
        ;;
      *)
        die "unknown argument for __internal-runtime-env: $1"
        ;;
    esac
  done

  [[ -n "$binary_name" ]] || die "__internal-runtime-env requires --binary"
  case "$output_format" in
    shell) emit_runtime_env "$binary_name" "$PATH" "$repo_root" ;;
    json) emit_runtime_env_json "$binary_name" "$PATH" "$repo_root" ;;
    *) die "unsupported __internal-runtime-env output format: $output_format" ;;
  esac
}

internal_run_runtime_main() {
  local binary_name=""
  local repo_root=""
  local override_assignments=()
  local runtime_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary)
        [[ $# -ge 2 ]] || die "__internal-run-runtime requires --binary value"
        binary_name="$2"
        shift 2
        ;;
      --repo-root)
        [[ $# -ge 2 ]] || die "__internal-run-runtime requires --repo-root value"
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --env)
        [[ $# -ge 2 ]] || die "__internal-run-runtime requires NAME=VALUE after --env"
        override_assignments+=("$2")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        die "unknown argument for __internal-run-runtime: $1"
        ;;
    esac
  done

  [[ -n "$binary_name" ]] || die "__internal-run-runtime requires --binary"
  [[ $# -gt 0 ]] || die "__internal-run-runtime requires a command"
  if [[ -n "$repo_root" ]]; then
    runtime_args+=(--repo-root "$repo_root")
  fi
  while [[ "${#override_assignments[@]}" -gt 0 ]]; do
    runtime_args+=(--env "${override_assignments[0]}")
    override_assignments=("${override_assignments[@]:1}")
  done
  runtime_args+=(-- "$@")
  exec_trusted_runtime "$binary_name" "${runtime_args[@]}"
}

validate_project_id() {
  local project_id="${1:-}"

  [[ -n "$project_id" ]] || die "project_id must not be empty"
  [[ ${#project_id} -le 64 ]] || die "project_id must be <= 64 characters"
  [[ ! "$project_id" =~ [[:cntrl:]] ]] || die "project_id must not contain control bytes"
  [[ "$project_id" =~ ^[A-Za-z0-9_-]+$ ]] || die "project_id must contain only letters, numbers, '_' or '-'"
  [[ "$project_id" != "agent_base" ]] || die "legacy project_id 'agent_base' is not allowed on DB-authoritative paths"
}

resolve_effective_project_id() {
  local repo_root="$1"
  local requested_project_id="${2:-}"
  local resolved_project_id=""

  resolved_project_id="$(resolve_project_id "$repo_root")" \
    || die "failed to resolve project_id for repo: $repo_root"
  if [[ -n "$requested_project_id" ]]; then
    validate_project_id "$requested_project_id"
    [[ "$requested_project_id" == "$resolved_project_id" ]] \
      || die "project_id mismatch: requested=${requested_project_id} resolved=${resolved_project_id}"
  fi

  printf '%s\n' "$resolved_project_id"
}

enqueue_file() {
  local repo_root="$1"
  local file_path="$2"
  local source="$3"
  local export_json_path="$4"
  local canonical_file_path=""
  local -a enqueue_args=()

  [[ -n "$file_path" ]] || die "enqueue requires --file-path"
  [[ -n "$source" ]] || die "enqueue requires --source"
  canonical_file_path="$(canonicalize_queue_enqueue_file_path "$repo_root" "$file_path")"

  local project_id=""
  project_id="$(resolve_project_id "$repo_root")" \
    || die "failed to resolve project_id for repo: $repo_root"

  enqueue_args=(
    queue enqueue
    --project-id "$project_id"
    --repo-root "$repo_root"
    --file-path "$canonical_file_path"
    --source "$source"
  )
  if [[ -n "$export_json_path" ]]; then
    enqueue_args+=(--export-json "$export_json_path")
  fi

  local enqueue_output=""
  if ! enqueue_output="$(
    run_cli \
      "$repo_root" \
      "${enqueue_args[@]}"
  )"; then
    die "queue enqueue failed for ${file_path}"
  fi

  printf '%s\n' "$enqueue_output"
}

lease_work() {
  local repo_root="$1"
  local lease_run_id="$2"
  local lease_seconds="$3"

  [[ -n "$lease_run_id" ]] || die "lease requires --lease-run-id"
  [[ -n "$lease_seconds" ]] || die "lease requires --lease-seconds"
  [[ "$lease_seconds" =~ ^[1-9][0-9]*$ ]] || die "--lease-seconds must be a positive integer"

  local project_id=""
  project_id="$(resolve_project_id "$repo_root")" \
    || die "failed to resolve project_id for repo: $repo_root"

  run_cli \
    "$repo_root" \
    queue lease \
    --project-id "$project_id" \
    --lease-run-id "$lease_run_id" \
    --lease-seconds "$lease_seconds"
}

finalize_work() {
  local action="$1"
  local repo_root="$2"
  local lease_owner="$3"
  local lease_run_id="$4"
  local error_message="$5"
  local requested_project_id="$6"
  shift 6
  local expected_files=("$@")

  [[ "$action" == "complete" || "$action" == "requeue" ]] || die "unsupported finalize action: $action"
  [[ -n "$lease_owner" ]] || die "$action requires --lease-owner"
  [[ "${#expected_files[@]}" -gt 0 ]] || die "$action requires at least one --expected-file"
  if [[ "$action" == "requeue" ]]; then
    [[ -n "$error_message" ]] || die "requeue requires --error"
  fi

  local project_id=""
  project_id="$(resolve_effective_project_id "$repo_root" "$requested_project_id")" \
    || die "failed to resolve effective project_id for repo: $repo_root"

  local args=(
    queue "$action"
    --project-id "$project_id"
    --lease-owner "$lease_owner"
  )
  if [[ -n "$lease_run_id" ]]; then
    args+=(--lease-run-id "$lease_run_id")
  fi

  local file_path=""
  for file_path in "${expected_files[@]}"; do
    [[ -n "$file_path" ]] || die "$action received an empty --expected-file"
    args+=(--expected-file "$file_path")
  done

  if [[ "$action" == "requeue" ]]; then
    args+=(--error "$error_message")
  fi

  run_cli "$repo_root" "${args[@]}"
}

export_queue_json() {
  local repo_root="$1"
  local requested_project_id="$2"
  local output_path="$3"

  [[ -n "$output_path" ]] || die "export-json requires --output"

  local project_id=""
  project_id="$(resolve_effective_project_id "$repo_root" "$requested_project_id")" \
    || die "failed to resolve effective project_id for repo: $repo_root"

  run_cli \
    "$repo_root" \
    queue export-json \
    --project-id "$project_id" \
    --output "$output_path"
}

main() {
  local command="${1:-}"
  case "$command" in
    -h|--help)
      usage
      exit 0
      ;;
    __internal-rust-workspace-root)
      shift || true
      internal_rust_workspace_root_main "$@"
      return $?
      ;;
    __internal-runtime-env)
      shift || true
      internal_runtime_env_main "$@"
      return 0
      ;;
    __internal-run-runtime)
      shift || true
      internal_run_runtime_main "$@"
      return 0
      ;;
  esac
  [[ -n "$command" ]] || {
    usage >&2
    exit 1
  }
  shift || true

  local repo_root=""
  repo_root="$(canonicalize_dir "$(script_dir)/..")"
  local file_path=""
  local source="manual"
  local export_json_path=""
  local lease_run_id=""
  local lease_seconds=""
  local lease_owner=""
  local error_message=""
  local requested_project_id=""
  local expected_files=()
  local seen_flags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || die "--repo-root requires a value"
        seen_flags+=("$1")
        repo_root="$(canonicalize_dir "$2")"
        shift 2
        ;;
      --file-path)
        [[ $# -ge 2 ]] || die "--file-path requires a value"
        seen_flags+=("$1")
        file_path="$2"
        shift 2
        ;;
      --source)
        [[ $# -ge 2 ]] || die "--source requires a value"
        seen_flags+=("$1")
        source="$2"
        shift 2
        ;;
      --export-json)
        [[ $# -ge 2 ]] || die "--export-json requires a value"
        seen_flags+=("$1")
        export_json_path="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output requires a value"
        seen_flags+=("$1")
        export_json_path="$2"
        shift 2
        ;;
      --lease-run-id)
        [[ $# -ge 2 ]] || die "--lease-run-id requires a value"
        seen_flags+=("$1")
        lease_run_id="$2"
        shift 2
        ;;
      --lease-seconds)
        [[ $# -ge 2 ]] || die "--lease-seconds requires a value"
        seen_flags+=("$1")
        lease_seconds="$2"
        shift 2
        ;;
      --lease-owner)
        [[ $# -ge 2 ]] || die "--lease-owner requires a value"
        seen_flags+=("$1")
        lease_owner="$2"
        shift 2
        ;;
      --error)
        [[ $# -ge 2 ]] || die "--error requires a value"
        seen_flags+=("$1")
        error_message="$2"
        shift 2
        ;;
      --project-id)
        [[ $# -ge 2 ]] || die "--project-id requires a value"
        seen_flags+=("$1")
        requested_project_id="$2"
        shift 2
        ;;
      --expected-file)
        [[ $# -ge 2 ]] || die "--expected-file requires a value"
        seen_flags+=("$1")
        expected_files+=("$2")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
      esac
  done

  validate_command_flags "$command" "${seen_flags[@]}"

  case "$command" in
    enqueue)
      enqueue_file "$repo_root" "$file_path" "$source" "$export_json_path"
      ;;
    lease|drain)
      lease_work "$repo_root" "$lease_run_id" "${lease_seconds:-900}"
      ;;
    complete)
      finalize_work "complete" "$repo_root" "$lease_owner" "$lease_run_id" "" "$requested_project_id" "${expected_files[@]}"
      ;;
    requeue)
      finalize_work "requeue" "$repo_root" "$lease_owner" "$lease_run_id" "$error_message" "$requested_project_id" "${expected_files[@]}"
      ;;
    export-json)
      export_queue_json "$repo_root" "$requested_project_id" "$export_json_path"
      ;;
    *)
      usage >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
