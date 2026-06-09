# Client Export Runbook

**Audience**: RevHarness maintainer who needs to package the current tree
for an external client / public release / OSS publication.

**Purpose**: Produce a clean tarball or fresh git repo that contains the
working tree only — no internal commit history, no design partner
debates, no `/Users/<you>/dev/...` references, no maintainer-only audit
artifacts.

**Why this exists**: The internal rev_harness repo retains 107+ commits
of design debates, plans, and sibling-project path references that have
forensic value internally but should not ship to clients. The
[Opus×Codex history sanitization debate (2026-05-21)](../../.claude/tmp/multi-repo-sync/codex_history_sanitize_debate.md)
concluded **do not rewrite upstream history** — instead, sanitize at
distribution time with this runbook.

---

## Canonical recipe (5 minutes)

```bash
# 1. Make sure you are on a clean main with no uncommitted changes
cd ~/dev/rev_harness
git status   # must be clean
git fetch origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
  { echo "diverged from origin/main, abort"; exit 1; }

# 2. Pick a target version (typically the next semver bump)
TARGET_VER="1.0.0"     # ← edit per release
EXPORT_DIR="/tmp/revharness-export-${TARGET_VER}"
rm -rf "$EXPORT_DIR"

# 3. Snapshot the working tree (no .git, no history)
git archive --format=tar HEAD | tar -x -C "$EXPORT_DIR"

# 4. Strip maintainer-only artifacts that survive archive
cd "$EXPORT_DIR"
rm -rf \
  .agent/active/prompts \
  .agent/active/sow \
  .agent/active/plan_*.md \
  .claude/tmp \
  .claude/scheduled_tasks.lock \
  harness-rust/target \
  .git/hooks/pre-commit.bak

# 5. Verify no <user>/dev/ leaks survive (run the existing guard
#    against the snapshot)
if grep -rEn '/Users/[A-Za-z0-9_.-]+/dev/|/home/[A-Za-z0-9_.-]+/dev/' \
     --include='*.md' --include='*.json' --include='*.sh' --include='*.toml' \
     . 2>/dev/null | grep -v 'rev-harness-path-leak-guard: allow' | head; then
  echo "[ABORT] path-leak survives the export; clean those files first"
  exit 1
fi

# 6. Verify no real secrets (defense in depth — should be empty given
#    the internal repo never had any)
grep -rE 'sk-ant-[A-Za-z0-9_-]{40,}|ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]+|AKIA[A-Z0-9]{16}' \
     --include='*.md' --include='*.json' --include='*.sh' --include='*.toml' \
     --include='*.rs' --include='*.ts' --include='*.py' . 2>/dev/null | head
# (no output expected)

# 7. Fresh git init with a single squash commit
git init -q
git add -A
git -c user.email='noreply@anthropic.com' -c user.name='RevHarness Release' \
  commit -q -m "RevHarness ${TARGET_VER} (clean export)" \
  -m "Initial public release of RevHarness — orchestration scaffolding for Claude Code and Codex with deterministic verification, semantic-mcp, and managed-adopter pattern." \
  --no-verify
git tag -a "${TARGET_VER}" -m "RevHarness ${TARGET_VER}"

# 8. Produce the distributable
cd /tmp
tar czf "revharness-${TARGET_VER}.tar.gz" -C "$EXPORT_DIR" .
shasum -a 256 "revharness-${TARGET_VER}.tar.gz" > "revharness-${TARGET_VER}.tar.gz.sha256"
echo ""
echo "OK: /tmp/revharness-${TARGET_VER}.tar.gz produced"
ls -la /tmp/revharness-${TARGET_VER}.tar.gz*
```

---

## What gets stripped (step 4 detail)

| Path | Why removed |
|---|---|
| `.agent/active/prompts/` (81+ md files) | Design partner prompts, grading prompts — internal IP, often contain `/Users/<you>/dev/` references |
| `.agent/active/sow/` | SoW design docs — internal-only context |
| `.agent/active/plan_*.md` | ExecPlans — internal forensic value, not user-facing |
| `.claude/tmp/` | Run-time scratch (delegation responses, grader outputs, etc.) — never useful to client |
| `.claude/scheduled_tasks.lock` | Runtime lock file |
| `harness-rust/target/` | Cargo build artifact — client builds the Rust semantic backend locally (`cargo build -p semantic-mcp`); the Node tree was removed in de-overkill S3-B3 |
| `.git/hooks/pre-commit.bak` | Backup from `install-rev-harness-hooks.sh` |

**Intentionally kept**:
- `.agent/templates/`, `.agent/registry/`, `.agent/generated/` — these are the runtime contract the harness depends on
- `.claude/skills/`, `.claude/commands/`, `.claude/CLAUDE-LOCAL.md` — orchestrator UX surface
- `.codex/` — Codex CLI integration
- `.cursor/rules/`, `.cursor/skills/` — Cursor CLI integration
- `docs/` (including this file) — user documentation
- `harness-rust/` source (minus `target/`) — Rust core source

---

## Per-client variant (optional)

If a client requires further redaction (e.g., remove specific component
names, branding), add step 4.5 after step 4:

```bash
# 4.5. Per-client redaction
sed -i.bak 's/internal-project-name/PRODUCT/g' README.md AGENTS.md
find . -name '*.bak' -delete
```

Keep client-specific redaction scripts in a separate private repo
(e.g., `revharness-release-tooling/`), not in the public `rev_harness/`
tree itself.

---

## Why not rewrite the upstream `rev_harness` history?

[Opus×Codex 2026-05-21 verdict](../../.claude/tmp/multi-repo-sync/codex_history_sanitize_debate.md)
selected **Option C** (preserve history) because:

1. **No real secrets**: 107-commit history contains 0 `sk-ant-*` /
   `AKIA*` / `ghp_*` / private-key hits. Only low-severity leaks
   (hostname in author metadata, abs paths in plan files, sibling
   project names).
2. **Private repo, 0 forks**: blast radius is bounded by GitHub access
   control.
3. **Filter-repo coverage risk = HIGH**: the spot-check audit
   under-counted cross-project path leaks 6×. Surgical removal
   guarantees missing something and forcing a second force-push.
4. **Lifecycle correctness**: JIT sanitization (this runbook) lets the
   maintainer keep the internal audit trail while still producing a
   clean client artifact. Per-client redaction is also feasible.
5. **Reversibility**: this runbook is reversible (the source repo is
   intact). A force-push history rewrite is not.

When `rev_harness` becomes public OR a first client handoff is
imminent, run an **exhaustive re-audit** (not the sampled one from
2026-05-21) before deciding to escalate. Until then, this runbook is
the canonical path.

---

## Maintenance checklist

When upstream `rev_harness` adds:

- New `.agent/active/` subdir → add to step 4 strip list
- New runtime cache path → add to step 4 strip list
- New language / file type that may contain leaks → add to step 5 grep
- New release tag scheme → update step 2 `TARGET_VER` convention

The path-leak guard (`scripts/rev-harness-path-leak-guard.sh`) installed
via `scripts/install-rev-harness-hooks.sh` keeps the leak surface from
growing on internal commits. This runbook is the export-side
complement.
