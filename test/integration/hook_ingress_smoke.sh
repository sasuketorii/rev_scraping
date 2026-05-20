#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

repo_rust_workspace_root() {
  /bin/bash "$REPO_ROOT/scripts/semantic-review-queue.sh" __internal-rust-workspace-root --repo-root "$REPO_ROOT"
}

RUST_WORKSPACE_ROOT="$(repo_rust_workspace_root)"
RUST_MANIFEST="$RUST_WORKSPACE_ROOT/Cargo.toml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

count_lines() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l < "$file_path" | tr -d '[:space:]'
}

write_hostile_path_binary() {
  local bin_dir="$1"
  local binary_name="$2"
  local message="$3"
  local marker_path="${bin_dir}/${binary_name}.marker"

  mkdir -p "$bin_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'echo %q >&2\n' "$message"
    printf ': > %q\n' "$marker_path"
    printf '%s\n' 'exit 99'
  } > "$bin_dir/$binary_name"
  chmod +x "$bin_dir/$binary_name"
}

assert_hostile_path_binary_not_executed() {
  local bin_dir="$1"
  local binary_name="$2"
  [[ ! -e "$bin_dir/${binary_name}.marker" ]] || fail "hostile ${binary_name} binary executed unexpectedly"
}

write_marker_binary_path() {
  local binary_path="$1"
  local marker_path="$2"
  local message="$3"
  local exit_code="${4:-99}"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'echo %q >&2\n' "$message"
    printf ': > %q\n' "$marker_path"
    printf 'exit %q\n' "$exit_code"
  } > "$binary_path"
  chmod +x "$binary_path"
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/hook_ingress_smoke.XXXXXX")
trap '/bin/rm -rf "$tmpdir"' EXIT

startup_poison="$tmpdir/startup-shell-poison.sh"
startup_poison_marker="$tmpdir/startup-shell-poison.marker"
direct_hook_stdout="$tmpdir/direct_hook.stdout"
direct_hook_stderr="$tmpdir/direct_hook.stderr"
hook_repo="$tmpdir/hook_repo"
hook_args_log="$tmpdir/hook_args.log"
hook_stdout="$tmpdir/hook.stdout"
hook_stderr="$tmpdir/hook.stderr"
hook_recheck_stdout="$tmpdir/hook_recheck.stdout"
hook_recheck_stderr="$tmpdir/hook_recheck.stderr"
hook_outside_stderr="$tmpdir/hook_outside.stderr"
hook_forged_stderr="$tmpdir/hook_forged.stderr"
hook_exec_env_stderr="$tmpdir/hook_exec_env.stderr"
hook_rustc_wrapper="$tmpdir/hook-rustc-wrapper.sh"
hook_rustc_wrapper_marker="$tmpdir/hook-rustc-wrapper.marker"
hook_target_dir="$tmpdir/hook-target"
hook_hostile_dir="$tmpdir/hook-hostile-bin"
hook_runtime_log="$tmpdir/hook_runtime.log"
hook_cargo_runtime_log="$tmpdir/hook_cargo_runtime.log"
hook_forged_marker="$tmpdir/hook-forged.marker"
hook_exec_env_poison_marker="$tmpdir/hook-exec-env-poison.marker"
hook_workspace_root=""
hook_workspace_manifest=""
hook_workspace_bin=""
hook_workspace_receipt=""

[[ -x "$REPO_ROOT/.claude/hooks/codex-review-hook.sh" ]] \
  || fail "repo hook entrypoint must keep the executable bit"

{
  printf '%s\n' '#!/bin/sh'
  printf ': > %q\n' "$startup_poison_marker"
  printf '%s\n' "printf 'startup shell poison executed unexpectedly\\n' >&2"
  printf '%s\n' 'exit 95'
} > "$startup_poison"
chmod +x "$startup_poison"

BASH_ENV="$startup_poison" \
ENV="$startup_poison" \
  "$REPO_ROOT/.claude/hooks/codex-review-hook.sh" </dev/null >"$direct_hook_stdout" 2>"$direct_hook_stderr" \
  || fail "repo hook entrypoint should run via direct exec with poisoned startup env neutralized"

[[ ! -e "$startup_poison_marker" ]] \
  || fail "review hook must neutralize BASH_ENV and ENV before entering bash-specific logic"
[[ ! -s "$direct_hook_stdout" ]] || fail "repo hook entrypoint should stay silent on stdout"

mkdir -p "$hook_repo"
hook_repo="$(cd "$hook_repo" && pwd -P)"
hook_workspace_root="$hook_repo/harness-rust"
hook_workspace_manifest="$hook_workspace_root/Cargo.toml"
hook_workspace_bin="$hook_workspace_root/target/debug/hook-review-queue"
hook_workspace_receipt="${hook_workspace_bin}.review-hook-receipt"
mkdir -p "$hook_repo/.claude/hooks" "$hook_repo/.claude/tmp" "$hook_repo/scripts" "$hook_repo/src" "$hook_workspace_root"
/bin/cp -p "$REPO_ROOT/.claude/hooks/codex-review-hook.sh" "$hook_repo/.claude/hooks/codex-review-hook.sh"
/bin/cp -p "$RUST_WORKSPACE_ROOT/Cargo.toml" "$hook_workspace_manifest"
/bin/cp -p "$RUST_WORKSPACE_ROOT/Cargo.lock" "$hook_workspace_root/Cargo.lock"
/bin/cp -R "$RUST_WORKSPACE_ROOT/crates" "$hook_workspace_root/crates"
if [[ -d "$RUST_WORKSPACE_ROOT/.cargo" ]]; then
  /bin/cp -R "$RUST_WORKSPACE_ROOT/.cargo" "$hook_workspace_root/.cargo"
fi
: > "$hook_args_log"
: > "$hook_runtime_log"
: > "$hook_cargo_runtime_log"
: > "$hook_repo/src/main.rs"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf 'real_helper=%q\n' "$REPO_ROOT/scripts/semantic-review-queue.sh"
  printf 'args_log=%q\n' "$hook_args_log"
  printf 'runtime_log=%q\n' "$hook_runtime_log"
  printf 'cargo_runtime_log=%q\n' "$hook_cargo_runtime_log"
  printf '%s\n' 'command="${1:-}"'
  printf '%s\n' ''
  printf '%s\n' '[[ -n "$command" ]] || {'
  printf '%s\n' "  printf 'semantic-review-queue stub: missing command\\n' >&2"
  printf '%s\n' '  exit 64'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'case "$command" in'
  printf '%s\n' '  __internal-rust-workspace-root)'
  printf '%s\n' '    shift'
  printf '%s\n' '    exec "$real_helper" __internal-rust-workspace-root "$@"'
  printf '%s\n' '    ;;'
  printf '%s\n' '  __internal-runtime-env)'
  printf '%s\n' '    shift'
  printf '%s\n' '    printf "%s\n" "__internal-runtime-env" >> "$runtime_log"'
  printf '%s\n' '    exec "$real_helper" __internal-runtime-env "$@"'
  printf '%s\n' '    ;;'
  printf '%s\n' '  __internal-run-runtime)'
  printf '%s\n' '    shift'
  printf '%s\n' '    runtime_binary=""'
  printf '%s\n' '    original_args=("$@")'
  printf '%s\n' '    while [[ $# -gt 0 ]]; do'
  printf '%s\n' '      case "$1" in'
  printf '%s\n' '        --binary)'
  printf '%s\n' '          [[ $# -ge 2 ]] || {'
  printf '%s\n' "            printf 'semantic-review-queue stub: missing runtime binary value\\n' >&2"
  printf '%s\n' '            exit 64'
  printf '%s\n' '          }'
  printf '%s\n' '          runtime_binary="$2"'
  printf '%s\n' '          shift 2'
  printf '%s\n' '          ;;'
  printf '%s\n' '        --env)'
  printf '%s\n' '          [[ $# -ge 2 ]] || {'
  printf '%s\n' "            printf 'semantic-review-queue stub: missing runtime env value\\n' >&2"
  printf '%s\n' '            exit 64'
  printf '%s\n' '          }'
  printf '%s\n' '          shift 2'
  printf '%s\n' '          ;;'
  printf '%s\n' '        --)'
  printf '%s\n' '          break'
  printf '%s\n' '          ;;'
  printf '%s\n' '        *)'
  printf '%s\n' '          shift'
  printf '%s\n' '          ;;'
  printf '%s\n' '      esac'
  printf '%s\n' '    done'
  printf '%s\n' '    printf "%s\n" "__internal-run-runtime:${runtime_binary}" >> "$runtime_log"'
  printf '%s\n' '    if [[ "$runtime_binary" == "cargo" ]]; then'
  printf '%s\n' '      printf "%s\n" cargo >> "$cargo_runtime_log"'
  printf '%s\n' '    fi'
  printf '%s\n' '    if [[ -n "${HOOK_FAIL_RUNTIME_BINARY:-}" && "$runtime_binary" == "$HOOK_FAIL_RUNTIME_BINARY" ]]; then'
  printf '%s\n' "      printf 'semantic-review-queue stub: blocked trusted runtime: %s\\n' \"\$runtime_binary\" >&2"
  printf '%s\n' '      exit 98'
  printf '%s\n' '    fi'
  printf '%s\n' '    exec "$real_helper" __internal-run-runtime "${original_args[@]}"'
  printf '%s\n' '    ;;'
  printf '%s\n' '  enqueue)'
  printf '%s\n' '    if [[ -n "${HOOK_EXEC_ENV_POISON_MARKER:-}" ]]; then'
  printf '%s\n' '      : > "$HOOK_EXEC_ENV_POISON_MARKER"'
  printf '%s\n' "      printf 'semantic-review-queue stub: enqueue inherited poisoned exec env\\n' >&2"
  printf '%s\n' '      exit 96'
  printf '%s\n' '    fi'
  printf '%s\n' '    printf "%s\n" "$*" >> "$args_log"'
  printf '%s\n' '    printf "%s\n" "${HOOK_HELPER_OUTPUT:-{\"duplicate\":false}}"'
  printf '%s\n' '    ;;'
  printf '%s\n' '  *)'
  printf '%s\n' "    printf 'semantic-review-queue stub: unsupported command: %s\\n' \"\$command\" >&2"
  printf '%s\n' '    exit 64'
  printf '%s\n' '    ;;'
  printf '%s\n' 'esac'
} > "$hook_repo/scripts/semantic-review-queue.sh"
chmod +x "$hook_repo/scripts/semantic-review-queue.sh"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf ': > %q\n' "$hook_rustc_wrapper_marker"
  printf '%s\n' 'exit 97'
} > "$hook_rustc_wrapper"
chmod +x "$hook_rustc_wrapper"
write_hostile_path_binary "$hook_hostile_dir" dirname "fake dirname should not be executed"
write_hostile_path_binary "$hook_hostile_dir" basename "fake basename should not be executed"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    BASH_ENV="$startup_poison" \
    ENV="$startup_poison" \
    PATH="$hook_hostile_dir:$PATH" \
    RUSTC_WRAPPER="$hook_rustc_wrapper" \
    CARGO_TARGET_DIR="$hook_target_dir" \
    ./.claude/hooks/codex-review-hook.sh
  ) >"$hook_stdout" 2>"$hook_stderr"

[[ ! -e "$startup_poison_marker" ]] \
  || fail "review hook must not execute startup poison during a real hook ingress run"
[[ ! -s "$hook_stdout" ]] || fail "review hook should stay silent on stdout"
[[ ! -e "$hook_rustc_wrapper_marker" ]] || fail "review hook must not inherit caller RUSTC_WRAPPER into trusted cargo build"
[[ ! -e "$hook_target_dir" ]] || fail "review hook must not inherit caller CARGO_TARGET_DIR into trusted cargo build"
[[ -x "$hook_workspace_bin" ]] || fail "review hook should build hook-review-queue into the workspace-local target"
assert_hostile_path_binary_not_executed "$hook_hostile_dir" dirname
assert_hostile_path_binary_not_executed "$hook_hostile_dir" basename
grep -Fqx -- "enqueue --repo-root $hook_repo --file-path src/main.rs --source hook --export-json $hook_repo/.claude/tmp/review_queue.json" "$hook_args_log" \
  || fail "review hook did not enqueue the normalized repo-relative path"
grep -Fq -- "__internal-runtime-env" "$hook_runtime_log" \
  || fail "review hook should resolve a trusted runtime env before the final hook-review-queue exec"

hook_calls_after_cold="$(count_lines "$hook_args_log")"
[[ "$hook_calls_after_cold" == "1" ]] || fail "initial hook run should enqueue exactly once"
cargo_calls_after_cold="$(count_lines "$hook_cargo_runtime_log")"
[[ "$cargo_calls_after_cold" == "1" ]] || fail "cold hook run should build exactly once via trusted cargo"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    PATH="$hook_hostile_dir:$PATH" \
    ./.claude/hooks/codex-review-hook.sh
  ) >"$hook_recheck_stdout" 2>"$hook_recheck_stderr" \
  || fail "review hook should revalidate the cached hook-review-queue binary via trusted cargo before enqueueing"

[[ ! -s "$hook_recheck_stdout" ]] || fail "repeat review hook path should stay silent on stdout"
hook_calls_after_recheck="$(count_lines "$hook_args_log")"
[[ "$hook_calls_after_recheck" == "2" ]] || fail "repeat hook run should enqueue exactly once more"
cargo_calls_after_recheck="$(count_lines "$hook_cargo_runtime_log")"
[[ "$cargo_calls_after_recheck" == "2" ]] \
  || fail "persistent warm-cache acceptance must stay disabled; repeat hook run should still invoke trusted cargo"

outside_file="$tmpdir/outside.rs"
: > "$outside_file"
hook_calls_before="$hook_calls_after_recheck"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$outside_file" \
  | (
    cd "$hook_repo"
    ./.claude/hooks/codex-review-hook.sh
  ) >/dev/null 2>"$hook_outside_stderr"

hook_calls_after="$(count_lines "$hook_args_log")"
[[ "$hook_calls_after" == "$hook_calls_before" ]] || fail "repo-external file should be skipped"
grep -Fq -- "Skipping file outside repo: $outside_file" "$hook_outside_stderr" \
  || fail "repo-external skip should be logged"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/CLAUDE.md" \
  | (
    cd "$hook_repo"
    ./.claude/hooks/codex-review-hook.sh
  ) >/dev/null 2>/dev/null

hook_calls_final="$(count_lines "$hook_args_log")"
[[ "$hook_calls_final" == "$hook_calls_before" ]] || fail "non-code file should not be enqueued"

write_marker_binary_path "$hook_workspace_bin" "$hook_forged_marker" "forged cached hook-review-queue binary should not execute" 93
forged_cksum_output="$("/usr/bin/cksum" "$hook_workspace_bin")"
forged_cksum_value="${forged_cksum_output%% *}"
forged_cksum_output="${forged_cksum_output#* }"
forged_size_value="${forged_cksum_output%% *}"
{
  printf '%s\n' 'format=review-hook-receipt-v1'
  printf 'repo_root=%s\n' "$hook_repo"
  printf 'workspace_root=%s\n' "$hook_workspace_root"
  printf 'workspace_manifest=%s\n' "$hook_workspace_manifest"
  printf 'binary_path=%s\n' "$hook_workspace_bin"
  printf 'binary_checksum=%s:%s\n' "$forged_cksum_value" "$forged_size_value"
} > "$hook_workspace_receipt"
/usr/bin/touch "$hook_workspace_bin" "$hook_workspace_receipt"
cargo_calls_before_forged="$(count_lines "$hook_cargo_runtime_log")"

if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    HOOK_FAIL_RUNTIME_BINARY=cargo \
    ./.claude/hooks/codex-review-hook.sh
  ) >/dev/null 2>"$hook_forged_stderr"; then
  fail "review hook should fail closed instead of trusting a forged warm-cache receipt"
fi

grep -Fq -- "failed to build hook-review-queue hook ingress" "$hook_forged_stderr" \
  || fail "forged receipt rejection should surface as a trusted rebuild failure"
[[ ! -e "$hook_forged_marker" ]] \
  || fail "review hook must not execute a forged warm-cache binary"
cargo_calls_after_forged="$(count_lines "$hook_cargo_runtime_log")"
[[ "$cargo_calls_after_forged" == "$((cargo_calls_before_forged + 1))" ]] \
  || fail "forged receipt rejection should still attempt exactly one trusted cargo rebuild"
hook_calls_after_forged="$(count_lines "$hook_args_log")"
[[ "$hook_calls_after_forged" == "$hook_calls_final" ]] \
  || fail "forged receipt rejection should not enqueue changes"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    HOOK_EXEC_ENV_POISON_MARKER="$hook_exec_env_poison_marker" \
    ./.claude/hooks/codex-review-hook.sh
  ) >/dev/null 2>"$hook_exec_env_stderr" \
  || fail "review hook should scrub caller env before the final hook-review-queue exec"

[[ ! -e "$hook_exec_env_poison_marker" ]] \
  || fail "review hook leaked caller env into the final hook-review-queue exec path"
hook_calls_after_exec_env="$(count_lines "$hook_args_log")"
[[ "$hook_calls_after_exec_env" == "$((hook_calls_after_forged + 1))" ]] \
  || fail "trusted exec hardening should still allow one enqueue"
cargo_calls_after_exec_env="$(count_lines "$hook_cargo_runtime_log")"
[[ "$cargo_calls_after_exec_env" == "$((cargo_calls_after_forged + 1))" ]] \
  || fail "trusted exec hardening should still perform one trusted cargo validation build"

cargo test -p hook-review-queue --manifest-path "$RUST_MANIFEST"

printf 'PASS: hook_ingress_smoke\n'
