#!/bin/sh
if [ "${1-}" != "--__codex-review-hook-bash__" ]; then
  unset BASH_ENV ENV
  exec /bin/bash --noprofile --norc "$0" --__codex-review-hook-bash__ "$@"
fi
shift
#
# codex-review-hook.sh - shell adapter for review-queue hook ingress
#
# The caller-facing hook path remains a shell adapter ingress for Claude Code
# compatibility.
# Hook orchestration ingress lives in Rust (`hook-review-queue hook review-queue`).
# Durable queue authority lives in the repo-local semantic backend, with
# `scripts/semantic-review-queue.sh` enforcing trusted runtime adaptation for
# the Rust-first / Node-fallback backend path behind this adapter.
#
# Bash-only logic begins after the sh trampoline clears startup env hooks.
set -euo pipefail

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

SCRIPT_DIR="$(script_dir)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUEUE_FILE="${REPO_ROOT}/.claude/tmp/review_queue.json"
QUEUE_HELPER="${REPO_ROOT}/scripts/semantic-review-queue.sh"
RUST_WORKSPACE_ROOT=""
RUST_MANIFEST=""
RUST_LOCKFILE=""
HOOK_REVIEW_QUEUE_MANIFEST=""
RUST_BIN_DIR=""
RUST_BIN=""
RUST_BIN_RECEIPT=""
HOOK_TRUSTED_RUNTIME_PASSTHROUGH_ENV_NAMES=(
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
HOOK_TRUSTED_EXEC_ENV_ASSIGNMENTS=()

log_hook() {
  echo "[review-hook] $*" >&2
}

die_hook() {
  log_hook "ERROR: $*"
  exit 1
}

run_trusted_runtime() {
  local binary_name="${1:-}"
  [[ -n "$binary_name" ]] || die_hook "runtime binary name is required"
  [[ -x "$QUEUE_HELPER" ]] || die_hook "queue helper not found or not executable: $QUEUE_HELPER"
  shift || true
  "$QUEUE_HELPER" __internal-run-runtime --binary "$binary_name" "$@"
}

load_trusted_runtime_env() {
  local binary_name="${1:-}"
  local env_output=""

  [[ -n "$binary_name" ]] || die_hook "runtime binary name is required"
  [[ -x "$QUEUE_HELPER" ]] || die_hook "queue helper not found or not executable: $QUEUE_HELPER"
  env_output="$("$QUEUE_HELPER" __internal-runtime-env --binary "$binary_name")" \
    || die_hook "failed to resolve trusted runtime env for: $binary_name"
  eval "$env_output"
}

resolve_hook_rust_workspace_paths() {
  local workspace_root=""

  [[ -x "$QUEUE_HELPER" ]] || die_hook "queue helper not found or not executable: $QUEUE_HELPER"
  workspace_root="$("$QUEUE_HELPER" __internal-rust-workspace-root --repo-root "$REPO_ROOT")" \
    || die_hook "failed to resolve Rust workspace root"

  RUST_WORKSPACE_ROOT="$workspace_root"
  RUST_MANIFEST="${RUST_WORKSPACE_ROOT}/Cargo.toml"
  RUST_LOCKFILE="${RUST_WORKSPACE_ROOT}/Cargo.lock"
  HOOK_REVIEW_QUEUE_MANIFEST="${RUST_WORKSPACE_ROOT}/crates/hook-review-queue/Cargo.toml"
  RUST_BIN_DIR="${RUST_WORKSPACE_ROOT}/target/debug"
  RUST_BIN="${RUST_BIN_DIR}/hook-review-queue"
  RUST_BIN_RECEIPT="${RUST_BIN}.review-hook-receipt"
}

append_hook_exec_passthrough_env() {
  local env_name="${1:-}"
  local env_value=""

  [[ -n "$env_name" ]] || die_hook "trusted exec passthrough env name is required"
  eval "env_value=\${${env_name}:-}"
  [[ -n "$env_value" ]] || return 0
  HOOK_TRUSTED_EXEC_ENV_ASSIGNMENTS+=("${env_name}=${env_value}")
}

build_hook_exec_env_assignments() {
  local exec_path=""
  local passthrough_name=""

  load_trusted_runtime_env cargo

  [[ -n "${RUNTIME_PATH:-}" ]] || die_hook "trusted cargo PATH is required"
  [[ -n "${RUNTIME_HOME:-}" ]] || die_hook "trusted cargo HOME is required"
  [[ -n "${RUNTIME_CARGO_HOME:-}" ]] || die_hook "trusted cargo CARGO_HOME is required"
  [[ -n "${RUNTIME_RUSTUP_HOME:-}" ]] || die_hook "trusted cargo RUSTUP_HOME is required"

  exec_path="${RUNTIME_PATH}"
  if [[ -n "${RUNTIME_TOOLCHAIN_BIN:-}" ]]; then
    exec_path="${RUNTIME_TOOLCHAIN_BIN}${exec_path:+:${exec_path}}"
  fi

  HOOK_TRUSTED_EXEC_ENV_ASSIGNMENTS=(
    "PATH=$exec_path"
    "HOME=$RUNTIME_HOME"
    "CARGO_HOME=$RUNTIME_CARGO_HOME"
    "RUSTUP_HOME=$RUNTIME_RUSTUP_HOME"
  )

  for passthrough_name in "${HOOK_TRUSTED_RUNTIME_PASSTHROUGH_ENV_NAMES[@]}"; do
    append_hook_exec_passthrough_env "$passthrough_name"
  done
}

exec_hook_binary_trusted() {
  build_hook_exec_env_assignments
  exec /usr/bin/env -i "${HOOK_TRUSTED_EXEC_ENV_ASSIGNMENTS[@]}" \
    "$RUST_BIN" \
    hook review-queue \
    --repo-root "$REPO_ROOT" \
    --queue-helper "$QUEUE_HELPER" \
    --queue-file "$QUEUE_FILE"
}

trusted_system_binary_path() {
  local binary_name="${1:-}"
  local candidate=""

  [[ "$binary_name" =~ ^[A-Za-z0-9._+-]+$ ]] \
    || die_hook "trusted system binary name is invalid: $binary_name"

  for candidate in "/usr/bin/$binary_name" "/bin/$binary_name"; do
    [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  die_hook "trusted system binary not found: $binary_name"
}

assert_existing_path_prefix_has_no_symlink_components() {
  local path_value="${1:-}"
  local remaining=""
  local component=""
  local current=""

  [[ -n "$path_value" && "$path_value" == /* ]] \
    || die_hook "absolute path is required for symlink validation: $path_value"

  remaining="${path_value#/}"
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component="${remaining%%/*}"
      remaining="${remaining#*/}"
    else
      component="$remaining"
      remaining=""
    fi
    [[ -n "$component" ]] || continue
    current="${current}/${component}"
    if [[ -L "$current" ]]; then
      die_hook "path contains symlink component: $current"
    fi
    if [[ ! -e "$current" ]]; then
      break
    fi
  done
}

assert_hook_output_paths_trusted() {
  assert_existing_path_prefix_has_no_symlink_components "$RUST_WORKSPACE_ROOT"
  assert_existing_path_prefix_has_no_symlink_components "${RUST_WORKSPACE_ROOT}/target"
  assert_existing_path_prefix_has_no_symlink_components "$RUST_BIN_DIR"
  assert_existing_path_prefix_has_no_symlink_components "$RUST_BIN"
  assert_existing_path_prefix_has_no_symlink_components "$RUST_BIN_RECEIPT"

  if [[ -e "${RUST_WORKSPACE_ROOT}/target" && ! -d "${RUST_WORKSPACE_ROOT}/target" ]]; then
    die_hook "Rust target path is not a directory: ${RUST_WORKSPACE_ROOT}/target"
  fi
  if [[ -e "$RUST_BIN_DIR" && ! -d "$RUST_BIN_DIR" ]]; then
    die_hook "Rust binary directory is not a directory: $RUST_BIN_DIR"
  fi
  if [[ -e "$RUST_BIN" && ! -f "$RUST_BIN" ]]; then
    die_hook "Rust hook binary path is not a regular file: $RUST_BIN"
  fi
  if [[ -e "$RUST_BIN_RECEIPT" && ! -f "$RUST_BIN_RECEIPT" ]]; then
    die_hook "Rust hook receipt path is not a regular file: $RUST_BIN_RECEIPT"
  fi
}

canonicalize_existing_path() {
  local path_value="${1:-}"
  local parent_dir=""
  local base_name=""

  [[ -n "$path_value" ]] || die_hook "path is required"
  [[ -e "$path_value" ]] || die_hook "path does not exist: $path_value"

  case "$path_value" in
    */*)
      parent_dir="${path_value%/*}"
      base_name="${path_value##*/}"
      ;;
    *)
      parent_dir="."
      base_name="$path_value"
      ;;
  esac

  parent_dir="$(cd "$parent_dir" && pwd -P)"
  printf '%s/%s\n' "$parent_dir" "$base_name"
}

path_list_contains() {
  local needle="${1:-}"
  shift || true

  local candidate=""
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done

  return 1
}

trusted_file_checksum() {
  local file_path="${1:-}"
  local cksum_bin=""
  local checksum_output=""
  local checksum_value=""
  local size_value=""

  [[ -f "$file_path" && ! -L "$file_path" ]] || die_hook "checksum target is not a trusted file: $file_path"

  cksum_bin="$(trusted_system_binary_path cksum)"
  checksum_output="$("$cksum_bin" "$file_path")" \
    || die_hook "failed to checksum file: $file_path"
  checksum_value="${checksum_output%% *}"
  checksum_output="${checksum_output#* }"
  size_value="${checksum_output%% *}"
  [[ "$checksum_value" =~ ^[0-9]+$ && "$size_value" =~ ^[0-9]+$ ]] \
    || die_hook "unexpected checksum output for file: $file_path"
  printf '%s:%s\n' "$checksum_value" "$size_value"
}

emit_tree_inputs() {
  local root_path="${1:-}"
  local find_bin=""
  [[ -d "$root_path" ]] || return 0
  root_path="$(canonicalize_existing_path "$root_path")"

  find_bin="$(trusted_system_binary_path find)"
  "$find_bin" -P "$root_path" -print
}

emit_manifest_build_inputs() {
  local manifest_path="${1:-}"
  local manifest_dir=""
  local manifest_line=""
  local path_value=""
  local candidate_path=""
  local canonical_candidate=""

  manifest_path="$(canonicalize_existing_path "$manifest_path")"
  [[ -f "$manifest_path" ]] || die_hook "Rust manifest not found: $manifest_path"
  manifest_dir="${manifest_path%/*}"

  printf '%s\n' "$manifest_dir"
  printf '%s\n' "$manifest_path"

  if [[ -f "$manifest_dir/build.rs" ]]; then
    printf '%s\n' "$(canonicalize_existing_path "$manifest_dir/build.rs")"
  fi

  if [[ -d "$manifest_dir/src" ]]; then
    emit_tree_inputs "$manifest_dir/src"
  fi

  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ "$manifest_line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$manifest_line" =~ path[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      path_value="${BASH_REMATCH[1]}"
      candidate_path="${manifest_dir}/${path_value}"
      [[ -e "$candidate_path" ]] || die_hook "manifest path input not found: $candidate_path"
      canonical_candidate="$(canonicalize_existing_path "$candidate_path")"
      if [[ -d "$canonical_candidate" && -f "$canonical_candidate/Cargo.toml" ]]; then
        printf 'MANIFEST:%s\n' "$(canonicalize_existing_path "$canonical_candidate/Cargo.toml")"
      elif [[ -d "$canonical_candidate" ]]; then
        emit_tree_inputs "$canonical_candidate"
      else
        printf '%s\n' "$canonical_candidate"
        printf '%s\n' "$(canonicalize_existing_path "${canonical_candidate%/*}")"
      fi
    fi
  done < "$manifest_path"
}

hook_build_inputs() {
  local pending_manifests=("$HOOK_REVIEW_QUEUE_MANIFEST")
  local seen_manifests=()
  local current_manifest=""
  local emitted_path=""

  printf '%s\n' "$(canonicalize_existing_path "$RUST_MANIFEST")"
  if [[ -f "$RUST_LOCKFILE" ]]; then
    printf '%s\n' "$(canonicalize_existing_path "$RUST_LOCKFILE")"
  fi

  if [[ -d "$RUST_WORKSPACE_ROOT/.cargo" ]]; then
    emit_tree_inputs "$RUST_WORKSPACE_ROOT/.cargo"
  fi

  while [[ "${#pending_manifests[@]}" -gt 0 ]]; do
    current_manifest="$(canonicalize_existing_path "${pending_manifests[0]}")"
    if [[ "${#pending_manifests[@]}" -gt 1 ]]; then
      pending_manifests=("${pending_manifests[@]:1}")
    else
      pending_manifests=()
    fi

    if [[ "${#seen_manifests[@]}" -gt 0 ]] \
      && path_list_contains "$current_manifest" "${seen_manifests[@]}"; then
      continue
    fi
    seen_manifests+=("$current_manifest")

    while IFS= read -r emitted_path || [[ -n "$emitted_path" ]]; do
      case "$emitted_path" in
        MANIFEST:*)
          pending_manifests+=("${emitted_path#MANIFEST:}")
          ;;
        *)
          printf '%s\n' "$emitted_path"
          ;;
      esac
    done < <(emit_manifest_build_inputs "$current_manifest")
  done
}

write_hook_build_receipt() {
  local receipt_tmp="${RUST_BIN_RECEIPT}.tmp.$$"
  local binary_checksum=""

  assert_hook_output_paths_trusted
  [[ -x "$RUST_BIN" && -f "$RUST_BIN" ]] || die_hook "built hook-review-queue binary not found: $RUST_BIN"
  [[ ! -e "$receipt_tmp" && ! -L "$receipt_tmp" ]] \
    || die_hook "temporary hook receipt path already exists: $receipt_tmp"

  binary_checksum="$(trusted_file_checksum "$RUST_BIN")"

  (
    umask 077
    cat > "$receipt_tmp" <<EOF
format=review-hook-receipt-v1
repo_root=$REPO_ROOT
workspace_root=$RUST_WORKSPACE_ROOT
workspace_manifest=$RUST_MANIFEST
binary_path=$RUST_BIN
binary_checksum=$binary_checksum
EOF
  ) || {
    /bin/rm -f "$receipt_tmp"
    die_hook "failed to write hook build receipt: $RUST_BIN_RECEIPT"
  }

  [[ -f "$receipt_tmp" && ! -L "$receipt_tmp" ]] \
    || die_hook "temporary hook receipt was not created as a trusted regular file: $receipt_tmp"

  /bin/mv -f "$receipt_tmp" "$RUST_BIN_RECEIPT" \
    || die_hook "failed to install hook build receipt: $RUST_BIN_RECEIPT"
}

hook_binary_has_trusted_receipt() {
  local receipt_line=""
  local binary_checksum=""
  local has_format=0
  local has_repo_root=0
  local has_workspace_root=0
  local has_manifest=0
  local has_binary_path=0
  local has_binary_checksum=0

  [[ -x "$RUST_BIN" && -f "$RUST_BIN" ]] || return 1
  [[ -f "$RUST_BIN_RECEIPT" && ! -L "$RUST_BIN_RECEIPT" ]] || return 1
  if [[ "$RUST_BIN" -nt "$RUST_BIN_RECEIPT" ]]; then
    return 1
  fi

  binary_checksum="$(trusted_file_checksum "$RUST_BIN")"

  while IFS= read -r receipt_line || [[ -n "$receipt_line" ]]; do
    case "$receipt_line" in
      format=review-hook-receipt-v1)
        has_format=1
        ;;
      "repo_root=$REPO_ROOT")
        has_repo_root=1
        ;;
      "workspace_root=$RUST_WORKSPACE_ROOT")
        has_workspace_root=1
        ;;
      "workspace_manifest=$RUST_MANIFEST")
        has_manifest=1
        ;;
      "binary_path=$RUST_BIN")
        has_binary_path=1
        ;;
      "binary_checksum=$binary_checksum")
        has_binary_checksum=1
        ;;
    esac
  done < "$RUST_BIN_RECEIPT"

  [[ "$has_format" -eq 1 \
    && "$has_repo_root" -eq 1 \
    && "$has_workspace_root" -eq 1 \
    && "$has_manifest" -eq 1 \
    && "$has_binary_path" -eq 1 \
    && "$has_binary_checksum" -eq 1 ]]
}

hook_binary_is_warm() {
  local input_path=""

  assert_hook_output_paths_trusted
  [[ -x "$RUST_BIN" ]] || return 1
  hook_binary_has_trusted_receipt || return 1

  while IFS= read -r input_path || [[ -n "$input_path" ]]; do
    [[ -e "$input_path" ]] || die_hook "hook build input not found: $input_path"
    if [[ "$input_path" -nt "$RUST_BIN" || "$input_path" -nt "$RUST_BIN_RECEIPT" ]]; then
      return 1
    fi
  done < <(hook_build_inputs)

  return 0
}

resolve_hook_rust_workspace_paths

if [[ ! -f "$RUST_MANIFEST" ]]; then
  die_hook "Rust manifest not found: $RUST_MANIFEST"
fi

assert_hook_output_paths_trusted

# Persistent warm-cache acceptance is disabled because the cached binary and
# receipt share the same writable trust domain and have no external provenance
# root. We still preserve warm-build performance by forcing a trusted cargo
# build each run, which reuses Cargo's own incremental cache when valid.
if ! run_trusted_runtime \
  cargo \
  --env 'RUSTFLAGS=-Awarnings' \
  -- \
  build \
  --quiet \
  --manifest-path "$RUST_MANIFEST" \
  -p hook-review-queue; then
  die_hook "failed to build hook-review-queue hook ingress"
fi

if [[ ! -x "$RUST_BIN" ]]; then
  die_hook "built hook-review-queue binary not found: $RUST_BIN"
fi

exec_hook_binary_trusted
