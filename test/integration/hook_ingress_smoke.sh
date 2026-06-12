#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hook_ingress_smoke.XXXXXX")"
trap '/bin/rm -rf "$tmpdir"' EXIT

startup_poison="$tmpdir/startup-shell-poison.sh"
startup_poison_marker="$tmpdir/startup-shell-poison.marker"
direct_hook_stdout="$tmpdir/direct_hook.stdout"
direct_hook_stderr="$tmpdir/direct_hook.stderr"

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
  || fail "repo hook entrypoint should run with poisoned startup env neutralized"

[[ ! -e "$startup_poison_marker" ]] \
  || fail "review hook must neutralize BASH_ENV and ENV before entering bash-specific logic"
[[ ! -s "$direct_hook_stdout" ]] || fail "repo hook entrypoint should stay silent on stdout"

bash "$REPO_ROOT/scripts/ci/hook-fail-behavior-test.sh" --post-tool-use --no-semantic

printf 'PASS: hook_ingress_smoke\n'
