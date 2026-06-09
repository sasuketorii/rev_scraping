#!/usr/bin/env bash
# rev-harness-path-leak-guard.sh
#
# Block commits that would introduce home-directory absolute paths
# (e.g. /Users/<user>/dev/...) into RevHarness file contents. Such paths
# are environment-specific and historically the dominant source of
# cross-project / personal-info leaks in this repo (see 0.0.15 audit:
# 21 hits across 6 sibling project names).
#
# This guard only inspects STAGED changes (`git diff --cached`) so it
# can be used either:
#   - manually:    bash scripts/rev-harness-path-leak-guard.sh
#   - as a hook:   bash scripts/install-rev-harness-hooks.sh (writes
#                  .git/hooks/pre-commit that invokes this script)
#
# Exit codes:
#   0  no path-leak introduced by staged changes
#   1  staged changes introduce at least one /Users/<name>/dev/ path
#   2  invocation error (no git repo, etc.)
#
# Bypass: `git commit --no-verify` (use sparingly; documented escape
# hatch for legitimate fixture / test cases that must contain the
# pattern literally).
#
# Allowlist:
#   - Markdown files under `.agent/active/prompts/` and `.agent/active/sow/`
#     where prior path references already exist for historical reference.
#     We do not retroactively block these; only new lines.
#   - Lines that explicitly opt in with the marker
#     `# rev-harness-path-leak-guard: allow`
#
# Compatibility: macOS bash 3.x (no associative arrays).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${REV_HARNESS_REPO_ROOT:-${PROJECT_ROOT:-}}"
if [[ -n "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || REPO_ROOT=""
fi
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
fi

die() { printf 'rev-harness-path-leak-guard: %s\n' "$*" >&2; exit "${2:-2}"; }

command -v git >/dev/null 2>&1 || die "git is required"
[[ -d "$REPO_ROOT/.git" ]] || die "not a git repo: $REPO_ROOT"

# Read staged diff. Only +added lines matter (existing leaks are
# grandfathered until a real history rewrite is performed).
diff_output="$(git -C "$REPO_ROOT" diff --cached --no-color --unified=0 2>/dev/null)" || die "git diff failed"
[[ -n "$diff_output" ]] || { exit 0; }

# Pattern: /Users/<word>/dev/   or   /home/<word>/dev/
# Allows the marker `# rev-harness-path-leak-guard: allow` on the same line.
violations="$(printf '%s\n' "$diff_output" \
  | grep -nE '^\+' \
  | grep -vE 'rev-harness-path-leak-guard: allow' \
  | grep -E '/Users/[A-Za-z0-9_.-]+/dev/|/home/[A-Za-z0-9_.-]+/dev/' \
  || true)"

if [[ -z "$violations" ]]; then
  exit 0
fi

cat >&2 <<EOF
[rev-harness-path-leak-guard] BLOCKED: staged change introduces
home-directory absolute path(s). These leak personal layout / sibling
project names into the repository history (private repo today, but
distribution-bound).

Offending lines:
EOF
printf '%s\n' "$violations" | head -20 >&2
cat >&2 <<EOF

Resolutions:
  1. Use a relative path or \$HOME / \$REPO_ROOT placeholder.
  2. If the literal path is intentional (e.g., fixture/test), add the
     opt-in marker on the same line:
       # rev-harness-path-leak-guard: allow
  3. Bypass (use sparingly, requires explicit reason):
       git commit --no-verify
EOF
exit 1
