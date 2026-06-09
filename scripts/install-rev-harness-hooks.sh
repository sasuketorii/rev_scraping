#!/usr/bin/env bash
# install-rev-harness-hooks.sh
#
# Idempotent installer for RevHarness git pre-commit hooks.
#
# Currently wires:
#   - rev-harness-path-leak-guard.sh  (block home-dir absolute paths)
#   - rev-harness-secret-guard.sh     (if present; existing secret scanner)
#
# Opt-in (--with-index-hook):
#   - .git/hooks/post-commit that detaches `agent-core context index-commit`
#     so the just-committed change is incrementally re-indexed into the
#     semantic-mcp db without blocking the commit. fail-open + async with
#     bounded redacted evidence under .git/rev-harness/.
#
# Usage:
#   bash scripts/install-rev-harness-hooks.sh --harness-root <path>
#                                                 # install (creates .git/hooks/pre-commit)
#   bash scripts/install-rev-harness-hooks.sh --harness-root <path> --with-index-hook
#                                                 # also creates .git/hooks/post-commit (opt-in)
#   bash scripts/install-rev-harness-hooks.sh --uninstall
#   bash scripts/install-rev-harness-hooks.sh --status
#   bash scripts/install-rev-harness-hooks.sh --without-hsdi-hooks
#
# The hook delegates to the canonical scripts so updates to the guard
# logic land automatically — the .git/hooks/pre-commit body itself is
# stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
MARKER="# rev-harness-hooks installed"

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/install-rev-harness-hooks.sh [install|--uninstall|--status]
       [--with-hsdi-hooks|--without-hsdi-hooks]
       [--with-index-hook]
       [--adopter-root <path>] [--harness-root <path>]
USAGE
}

die() {
  printf 'install-rev-harness-hooks: %s\n' "$*" >&2
  exit "${2:-2}"
}

abs_dir() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  cd "$path" 2>/dev/null && pwd -P
}

git_hook_path() {
  local root="$1" hook="${2:-pre-commit}" top path
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" \
    || die "adopter-root is not a git repository: $root"
  path="$(git -C "$top" rev-parse --git-path "hooks/$hook" 2>/dev/null)" \
    || die "failed to resolve $hook hook path for adopter-root: $root"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$top" "$path" ;;
  esac
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ensure_local_settings_ignored() {
  local root="$1" top exclude_file
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" \
    || die "adopter-root is not a git repository: $root"
  exclude_file="$(git -C "$top" rev-parse --git-path info/exclude 2>/dev/null)" \
    || die "failed to resolve git exclude path for adopter-root: $root"
  case "$exclude_file" in
    /*) ;;
    *) exclude_file="$top/$exclude_file" ;;
  esac
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  grep -Fxq '.claude/settings.local.json' "$exclude_file" 2>/dev/null \
    || printf '%s\n' '.claude/settings.local.json' >> "$exclude_file"
  grep -Fxq '.claude/settings.local.json.*' "$exclude_file" 2>/dev/null \
    || printf '%s\n' '.claude/settings.local.json.*' >> "$exclude_file"
}

action="install"
with_hsdi_hooks=1
with_index_hook=0
adopter_root="$REPO_ROOT"
harness_root=""
harness_root_seen=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    install) action="install"; shift ;;
    --uninstall) action="--uninstall"; shift ;;
    --status) action="--status"; shift ;;
    --with-hsdi-hooks) with_hsdi_hooks=1; shift ;;
    --without-hsdi-hooks) with_hsdi_hooks=0; shift ;;
    --with-index-hook) with_index_hook=1; shift ;;
    --adopter-root)
      [[ "$#" -ge 2 ]] || die "--adopter-root requires a path"
      adopter_root="$2"
      shift 2
      ;;
    --harness-root)
      [[ "$#" -ge 2 ]] || die "--harness-root requires a path"
      harness_root="$2"
      harness_root_seen=1
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

adopter_root="$(abs_dir "$adopter_root")" || die "adopter-root does not exist: $adopter_root"
HOOK="$(git_hook_path "$adopter_root" pre-commit)"
POST_HOOK="$(git_hook_path "$adopter_root" post-commit)"

case "$action" in
  --uninstall)
    removed=0
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      /bin/rm -f -- "$HOOK"
      echo "removed $HOOK"
      removed=1
    fi
    if [[ -f "$POST_HOOK" ]] && grep -q "$MARKER" "$POST_HOOK" 2>/dev/null; then
      /bin/rm -f -- "$POST_HOOK"
      echo "removed $POST_HOOK"
      removed=1
    fi
    [[ "$removed" -eq 1 ]] || echo "no rev-harness hook to remove"
    exit 0
    ;;
  --status)
    status_rc=1
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      echo "installed: $HOOK"
      status_rc=0
    fi
    if [[ -f "$POST_HOOK" ]] && grep -q "$MARKER" "$POST_HOOK" 2>/dev/null; then
      echo "installed: $POST_HOOK"
      status_rc=0
    fi
    [[ "$status_rc" -eq 0 ]] || echo "not installed"
    exit "$status_rc"
    ;;
  install|"")
    ;;
  *)
    echo "unknown action: $action (use: install | --uninstall | --status)" >&2
    usage
    exit 2
    ;;
esac

if [[ "$harness_root_seen" -ne 1 || -z "$harness_root" ]]; then
  die "harness-root required; pass --harness-root <path> (usually the RevHarness root)" 2
fi
harness_root="$(abs_dir "$harness_root")" || die "harness-root does not exist: $harness_root"
if [[ ! -f "$harness_root/scripts/rev-harness-path-leak-guard.sh" ]]; then
  die "harness-root missing scripts/rev-harness-path-leak-guard.sh: $harness_root"
fi

mkdir -p "$(dirname "$HOOK")"

if [[ -f "$HOOK" ]] && ! grep -q "$MARKER" "$HOOK"; then
  echo "WARN: existing $HOOK is not managed by rev-harness; backing up to ${HOOK}.bak" >&2
  /bin/cp -- "$HOOK" "${HOOK}.bak"
fi

HARNESS_ROOT_QUOTED="$(shell_quote "$harness_root")"
ADOPTER_ROOT_QUOTED="$(shell_quote "$adopter_root")"

cat >"$HOOK" <<HOOK
#!/usr/bin/env bash
# rev-harness-hooks installed
set -e
HARNESS_ROOT_LITERAL=$HARNESS_ROOT_QUOTED
ADOPTER_ROOT_LITERAL=$ADOPTER_ROOT_QUOTED

# 1. path-leak guard (blocks ~/dev/ absolute paths in staged diff)
if [[ -x "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-path-leak-guard.sh" ]]; then
  PROJECT_ROOT="\$ADOPTER_ROOT_LITERAL" REV_HARNESS_REPO_ROOT="\$ADOPTER_ROOT_LITERAL" \
    bash "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-path-leak-guard.sh" || exit \$?
fi

# 2. secret guard (existing scanner, if present)
if [[ -x "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-secret-guard.sh" ]]; then
  PROJECT_ROOT="\$ADOPTER_ROOT_LITERAL" REV_HARNESS_REPO_ROOT="\$ADOPTER_ROOT_LITERAL" \
    bash "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-secret-guard.sh" check --staged-only || exit \$?
fi

exit 0
HOOK
chmod +x "$HOOK"
echo "installed: $HOOK"
echo ""
echo "verify: bash scripts/install-rev-harness-hooks.sh --status"
echo "test:   git commit --dry-run (will run guards on staged diff)"
echo "bypass: git commit --no-verify (use sparingly)"

# --- post-commit semantic index hook (opt-in via --with-index-hook) ---------
# Detaches `agent-core context index-commit` so the just-committed change is
# incrementally re-indexed into the semantic-mcp db without blocking the commit.
# fail-open (exit 0 always) + async (detach) + binary-missing => logged skip.
# NOTE: index-commit only upserts files changed in the commit (gc_orphans=false);
# deleted/renamed files leave orphan symbols that only the periodic
# `agent-core context index-all` sweep removes.
if [[ "$with_index_hook" == "1" ]]; then
  if [[ -f "$POST_HOOK" ]] && ! grep -q "$MARKER" "$POST_HOOK"; then
    echo "WARN: existing $POST_HOOK is not managed by rev-harness; backing up to ${POST_HOOK}.bak" >&2
    /bin/cp -- "$POST_HOOK" "${POST_HOOK}.bak"
  fi

  {
    cat <<'HOOK_HEADER'
#!/usr/bin/env bash
# rev-harness-hooks installed
# rev-harness post-commit semantic index hook (opt-in)
# fail-open: never block a commit. Detaches index-commit and exits 0.
HOOK_HEADER
    printf 'HARNESS_ROOT_LITERAL=%s\n' "$HARNESS_ROOT_QUOTED"
    printf 'ADOPTER_ROOT_LITERAL=%s\n' "$ADOPTER_ROOT_QUOTED"
    cat <<'HOOK_BODY'

# Locate the agent-core binary (release preferred, debug fallback). Mirrors the
# discovery order in scripts/semantic-bootstrap.sh. Absent => logged fail-open skip.
AGENT_CORE_BIN=""
for cand in \
  "${REV_HARNESS_AGENT_CORE_BIN:-}" \
  "$HARNESS_ROOT_LITERAL/harness-rust/target/release/agent-core" \
  "$HARNESS_ROOT_LITERAL/harness-rust/target/debug/agent-core"; do
  if [[ -n "$cand" && -x "$cand" ]]; then AGENT_CORE_BIN="$cand"; break; fi
done

# Capture immutable refs before detaching. The worker must not resolve HEAD
# later after another commit has advanced the branch.
POST_HEAD="$(git -C "$ADOPTER_ROOT_LITERAL" rev-parse --verify HEAD 2>/dev/null || true)"
POST_BASE="$(git -C "$ADOPTER_ROOT_LITERAL" rev-parse --verify HEAD^1 2>/dev/null || true)"
LOG_DIR="$(cd "$ADOPTER_ROOT_LITERAL" && git rev-parse --git-path rev-harness 2>/dev/null || printf '.git/rev-harness')"
export HARNESS_ROOT_LITERAL ADOPTER_ROOT_LITERAL AGENT_CORE_BIN POST_HEAD POST_BASE LOG_DIR

if [[ -n "$AGENT_CORE_BIN" && -n "$POST_HEAD" ]]; then
  # Detach: run in the adopter cwd (so the db matches the live MCP), fully
  # backgrounded so commit latency stays ~zero. setsid when available, else
  # nohup. Output is bounded and redacted into .git/rev-harness; errors never
  # propagate to the commit.
  INDEX_WORKER='
set +e
cd "$ADOPTER_ROOT_LITERAL" || exit 0
mkdir -p "$LOG_DIR" || exit 0
raw="${TMPDIR:-/tmp}/revh-index-$$.log"
evidence="$LOG_DIR/post-commit-index-evidence.jsonl"
if [[ -n "${POST_BASE:-}" ]]; then
  "$AGENT_CORE_BIN" context index-commit --head "$POST_HEAD" --base "$POST_BASE" --apply --evidence "$evidence" >"$raw" 2>&1
else
  "$AGENT_CORE_BIN" context index-commit --head "$POST_HEAD" --apply --evidence "$evidence" >"$raw" 2>&1
fi
status=$?
log="$LOG_DIR/post-commit-index.log"
sed_args=(-e "s|$ADOPTER_ROOT_LITERAL|<repo_root>|g" -e "s|$HARNESS_ROOT_LITERAL|<harness_root>|g")
if [[ -n "${HOME:-}" ]]; then
  sed_args+=(-e "s|$HOME|<home>|g")
fi
{
  printf "ts=%s status=%s head=%s base=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "${POST_HEAD:-unknown}" "${POST_BASE:-<root>}"
  sed "${sed_args[@]}" "$raw" 2>/dev/null | tail -n 120
} >> "$log"
tail -n 1000 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
rm -f "$raw"
exit 0
'
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$INDEX_WORKER" \
      >/dev/null 2>&1 < /dev/null &
  else
    nohup bash -c "$INDEX_WORKER" \
      >/dev/null 2>&1 < /dev/null &
  fi
  disown 2>/dev/null || true
else
  (
    cd "$ADOPTER_ROOT_LITERAL" &&
    mkdir -p "$LOG_DIR" &&
    printf "ts=%s status=skip reason=%s head=%s base=%s\n" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$([[ -z "$AGENT_CORE_BIN" ]] && printf 'agent-core-missing' || printf 'head-missing')" \
      "${POST_HEAD:-unknown}" "${POST_BASE:-<root>}" \
      >> "$LOG_DIR/post-commit-index.log"
  ) >/dev/null 2>&1 || true
fi

exit 0
HOOK_BODY
  } >"$POST_HOOK"
  chmod +x "$POST_HOOK"
  echo "installed: $POST_HOOK"
  echo "note: index-commit upserts only commit-changed files (gc_orphans=false);"
  echo "      run 'agent-core context index-all' periodically to reap orphan symbols."
fi

if [[ "$with_hsdi_hooks" == "1" ]]; then
  settings_dir="$adopter_root/.claude"
  settings_file="$settings_dir/settings.local.json"
  run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
  mkdir -p "$settings_dir"
  ensure_local_settings_ignored "$adopter_root"
  if [[ ! -f "$settings_file" ]]; then
    printf '{}\n' > "$settings_file"
  fi
  bash "$SCRIPT_DIR/_hsdi-settings-merge.sh" merge \
    --config "$settings_file" \
    --harness-root "$harness_root" \
    --run-id "$run_id"
fi
