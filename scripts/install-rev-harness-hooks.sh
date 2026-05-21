#!/usr/bin/env bash
# install-rev-harness-hooks.sh
#
# Idempotent installer for RevHarness git pre-commit hooks.
#
# Currently wires:
#   - rev-harness-path-leak-guard.sh  (block home-dir absolute paths)
#   - rev-harness-secret-guard.sh     (if present; existing secret scanner)
#
# Usage:
#   bash scripts/install-rev-harness-hooks.sh         # install (creates .git/hooks/pre-commit)
#   bash scripts/install-rev-harness-hooks.sh --uninstall
#   bash scripts/install-rev-harness-hooks.sh --status
#
# The hook delegates to the canonical scripts so updates to the guard
# logic land automatically — the .git/hooks/pre-commit body itself is
# stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HOOK="$REPO_ROOT/.git/hooks/pre-commit"
MARKER="# rev-harness-hooks installed"

action="${1:-install}"

case "$action" in
  --uninstall)
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      rm "$HOOK"
      echo "removed $HOOK"
    else
      echo "no rev-harness hook to remove"
    fi
    exit 0
    ;;
  --status)
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      echo "installed: $HOOK"
      exit 0
    else
      echo "not installed"
      exit 1
    fi
    ;;
  install|"")
    ;;
  *)
    echo "unknown action: $action (use: install | --uninstall | --status)" >&2
    exit 2
    ;;
esac

if [[ -f "$HOOK" ]] && ! grep -q "$MARKER" "$HOOK"; then
  echo "WARN: existing $HOOK is not managed by rev-harness; backing up to ${HOOK}.bak" >&2
  cp "$HOOK" "${HOOK}.bak"
fi

cat >"$HOOK" <<'HOOK'
#!/usr/bin/env bash
# rev-harness-hooks installed
set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"

# 1. path-leak guard (blocks /Users/.../dev/ absolute paths in staged diff)
if [[ -x "$REPO_ROOT/scripts/rev-harness-path-leak-guard.sh" ]]; then
  bash "$REPO_ROOT/scripts/rev-harness-path-leak-guard.sh" || exit $?
fi

# 2. secret guard (existing scanner, if present)
if [[ -x "$REPO_ROOT/scripts/rev-harness-secret-guard.sh" ]]; then
  bash "$REPO_ROOT/scripts/rev-harness-secret-guard.sh" check --staged-only || exit $?
fi

exit 0
HOOK
chmod +x "$HOOK"
echo "installed: $HOOK"
echo ""
echo "verify: bash scripts/install-rev-harness-hooks.sh --status"
echo "test:   git commit --dry-run (will run guards on staged diff)"
echo "bypass: git commit --no-verify (use sparingly)"
