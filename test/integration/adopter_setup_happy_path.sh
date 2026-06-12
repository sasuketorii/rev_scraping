#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'cd "$REPO_ROOT" >/dev/null 2>&1 || true; rm -rf "$TMP" >/dev/null 2>&1 || true' EXIT
TARGET="$TMP/target"

mkdir -p "$TMP/scripts" "$TARGET"
cp "$REPO_ROOT/scripts/rev-harness-adopter-setup.sh" "$TMP/scripts/"
cp "$REPO_ROOT/scripts/_canonical-guard.sh" "$TMP/scripts/"

cat >"$TMP/scripts/init-project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .shared
printf 'adopter-happy\n' > .shared/project_id
touch .gitignore
EOF
cat >"$TMP/scripts/install-rev-harness-hooks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/hooks
printf '# hook\n' > .git/hooks/pre-commit
EOF
cat >"$TMP/scripts/harness-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"OK"}\n'
EOF
chmod +x "$TMP"/scripts/*.sh

OUT="$TMP/out.jsonl"
(
  cd "$TMP"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_CANONICAL_ROOT="$TMP"
  bash scripts/rev-harness-adopter-setup.sh setup --target "$TARGET" --dry-run >"$OUT"
)

test ! -e "$TARGET/.shared/rev-harness-adopter-setup.state.json"
test "$(grep -c '"event":"phase_started"' "$OUT")" -eq 3
test "$(grep -c '"event":"phase_ok"' "$OUT")" -eq 3
! grep -q '"phase":"semantic_node"' "$OUT"
! grep -q '"phase":"semantic_rust"' "$OUT"
test ! -e "$TARGET/.rev-harness-state/paths.json"
grep -q '"event":"run_summary".*"status":"ok"' "$OUT"
printf 'adopter_setup_happy_path: ok\n'
exit 0
