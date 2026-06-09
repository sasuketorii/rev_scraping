#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'cd "$REPO_ROOT" >/dev/null 2>&1 || true; rm -rf "$TMP" >/dev/null 2>&1 || true' EXIT
TARGET="$TMP/target"

mkdir -p "$TMP/scripts" "$TMP/bin" "$TARGET/harness-rust"
cp "$REPO_ROOT/scripts/rev-harness-adopter-setup.sh" "$TMP/scripts/"
cp "$REPO_ROOT/scripts/_canonical-guard.sh" "$TMP/scripts/"

cat >"$TMP/scripts/init-project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .shared
printf 'adopter-resume\n' > .shared/project_id
touch .gitignore
EOF
cat >"$TMP/scripts/semantic-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .semantic-node
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
cat >"$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f "$PWD/../cargo-success" ]]; then
  printf 'simulated cargo failure\n' >&2
  exit 101
fi
printf 'cargo ok\n'
EOF
chmod +x "$TMP"/scripts/*.sh "$TMP/bin/cargo"

set +e
(
  cd "$TMP"
  export PATH="$TMP/bin:$PATH"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_CANONICAL_ROOT="$TMP"
  bash scripts/rev-harness-adopter-setup.sh setup --target "$TARGET" >"$TMP/first.out" 2>"$TMP/first.err"
)
FIRST_RC=$?
set -e

test "$FIRST_RC" -eq 12
jq -e '.phases.semantic_rust.status == "failed"' "$TARGET/.shared/rev-harness-adopter-setup.state.json" >/dev/null

touch "$TARGET/cargo-success"
(
  cd "$TMP"
  export PATH="$TMP/bin:$PATH"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_CANONICAL_ROOT="$TMP"
  bash scripts/rev-harness-adopter-setup.sh setup --target "$TARGET" --resume >"$TMP/resume.out"
)

jq -e '.schema == "rev-harness-state/v1" and .current_phase == "done" and .phases.semantic_rust.status == "ok"' \
  "$TARGET/.shared/rev-harness-adopter-setup.state.json" >/dev/null
grep -q '"event":"verified-skip".*"phase":"init"' "$TMP/resume.out"
grep -q '"event":"verified-skip".*"phase":"semantic_node"' "$TMP/resume.out"
grep -q '"event":"phase_started".*"phase":"semantic_rust"' "$TMP/resume.out"

printf 'adopter_setup_partial_fail_resume: ok\n'
exit 0
