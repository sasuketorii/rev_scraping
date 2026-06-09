# Dev Junk Cleanup Plan — 2026-05-21 snapshot

**Audience**: rev_harness maintainer with 4 active repos on disk.
**Current state**: 154 GB across 4 repos, dominated by Rust `target/`.
**Approach**: dry-run first, manual execution per tier. Reversibility notes
included so you can choose where to draw the line.

---

## Snapshot (2026-05-21)

| repo | total | dominant junk |
|---|---|---|
| contact_dev | 73 GB | target/ 65 GB, node_modules 1.5 GB, build 783 MB, .next 608 MB, .venv 299 MB |
| rev_scraping | 57 GB | target/ 56 GB, build 569 MB, node_modules 85 MB |
| rev_salescopilot | 15 GB | target/ 15 GB, node_modules 85 MB |
| rev_harness | 9.4 GB | target/ 9.5 GB, .claude/.agent tmp 62 MB, node_modules 85 MB |

Plus OS-level:
- `~/.semantic-mcp/`: 35 MB across **343 dirs** of which **339 are orphan**
  `queueruntime-*` test residue.
- `~/Library/.../Revharness/semantic-mcp/v1/`: 55 MB, 4 active dirs, clean.

---

## Tier 1 — safe cleanup (~5 GB returned, regenerates in seconds–minutes)

Everything here is gitignored, has zero audit value, regenerates automatically
on next build/install/use.

### 1a. Orphan semantic-mcp dbs (saves ~30 MB, uses canonical GC)

```bash
# Dry-run: list what would be deleted (older than 7 days, RSEM-marked only)
~/dev/rev_harness/harness-rust/target/debug/semantic-mcp gc --older-than-days 7 --dry-run

# Execute (RSEM marker check is built in — won't touch non-RevHarness dbs)
~/dev/rev_harness/harness-rust/target/debug/semantic-mcp gc --older-than-days 7 --force
```

### 1b. Build artifacts (saves ~3.5 GB)

```bash
# Dry-run: list every node_modules / dist / build / .next / .venv / __pycache__
for r in rev_harness rev_scraping rev_salescopilot contact_dev; do
  echo "=== $r ==="
  find ~/dev/$r \( \
       -name node_modules -o -name dist -o -name build \
    -o -name .next -o -name .venv -o -name venv \
    -o -name __pycache__ -o -name .pytest_cache -o -name .turbo -o -name .cache \
    \) -type d -not -path "*/.git/*" -prune 2>/dev/null
done

# Execute (per-repo, run one at a time to verify before next)
# rev_harness (smallest, do first as smoke test):
find ~/dev/rev_harness \( \
       -name node_modules -o -name dist -o -name build \
    -o -name .next -o -name .venv -o -name __pycache__ -o -name .pytest_cache \
    \) -type d -not -path "*/.git/*" -prune -exec rm -rf {} +
# Repeat for: rev_scraping, rev_salescopilot, contact_dev
```

After tier 1b, the next `bash scripts/semantic-bootstrap.sh` validates the Rust
semantic backend (the Node tree was removed in de-overkill S3-B3). `cargo build`
rebuilds `harness-rust/target/`. `.next` rebuilds on first `next dev|build`.

### 1c. Stale logs (saves ~6 MB across 4 repos)

```bash
# Dry-run: logs older than 7 days outside node_modules/target
find ~/dev/{rev_harness,rev_scraping,rev_salescopilot,contact_dev} \
  -name "*.log" -mtime +7 \
  -not -path "*/node_modules/*" -not -path "*/target/*" \
  -not -path "*/.git/*" 2>/dev/null

# Execute (append `-delete` once dry-run looks right)
# find ... -delete
```

**Tier 1 total**: ~3.5 GB returned, ~10 seconds of typing, fully reversible.

---

## Tier 2 — medium cleanup (~145 GB returned, regenerates in 10–30 min)

Rust `target/`. By far the biggest disk hog. `cargo clean` is the canonical
delete; rebuild costs 5–15 min per workspace depending on size.

### 2a. Per-repo cargo clean (dry-run = check size only)

```bash
# Dry-run: report current target/ size per workspace
for r in rev_harness rev_scraping rev_salescopilot contact_dev; do
  echo "=== $r ==="
  find ~/dev/$r -name Cargo.toml -not -path "*/.git/*" -not -path "*/target/*" \
    | head -5 | while read manifest; do
      ws=$(dirname "$manifest")
      tgt="$ws/target"
      if [[ -d "$tgt" ]]; then
        printf "  %s: %s\n" "$ws" "$(du -sh "$tgt" 2>/dev/null | awk '{print $1}')"
      fi
    done
done

# Execute (per workspace — only run on repos you're not actively building)
( cd ~/dev/rev_harness/harness-rust && cargo clean )    # ~9.5 GB
( cd ~/dev/rev_salescopilot/harness-rust && cargo clean ) # ~15 GB
( cd ~/dev/rev_scraping && cargo clean )                 # ~56 GB
( cd ~/dev/contact_dev/harness-rust && cargo clean )     # ~65 GB (largest)
```

### 2b. Cargo registry cache (saves additional ~few GB, system-wide)

```bash
# Show ~/.cargo size
du -sh ~/.cargo 2>/dev/null

# Crate source cache (regenerates on next cargo build, slowest to rewarm)
du -sh ~/.cargo/registry/cache 2>/dev/null
du -sh ~/.cargo/registry/src 2>/dev/null
# du -sh ~/.cargo/git    # if you have git deps

# Cautious deletion: src/ first (regenerates from cache), then cache/
# rm -rf ~/.cargo/registry/src/*
```

**Tier 2 total**: ~145 GB returned, ~30 min to rewarm one workspace each.
Skip the workspace you're actively coding in.

---

## Tier 3 — aggressive cleanup (~62 MB but touches audit trail)

`rev_harness/.claude/tmp/` has 347 files / 62 MB. Includes:
- Today's grading verdicts (`codex_017_grade_r*.md` — referenced from CHANGELOG)
- Past delegation responses, debate outputs
- Old session scratch

### 3a. Surgical (keep audit, drop old scratch)

```bash
# Audit: what's in .claude/tmp/, oldest first
ls -lat ~/dev/rev_harness/.claude/tmp/ | tail -30

# Find what to keep (anything referenced from CHANGELOG.md or *.md docs)
grep -rh "\.claude/tmp/" ~/dev/rev_harness/CHANGELOG.md \
                         ~/dev/rev_harness/README.md \
                         ~/dev/rev_harness/.agent/active/sow/ 2>/dev/null \
  | grep -oE '\.claude/tmp/[^ )`]+' | sort -u

# Delete files older than 30 days NOT referenced anywhere
# (Manual review recommended; the grading verdicts are small, the bulk is old delegation logs)
```

### 3b. Nuclear (delete the whole tmp dir — breaks CHANGELOG audit pointers)

```bash
# NOT RECOMMENDED — breaks the audit-trail commitment made in 0.0.17 CHANGELOG
# rm -rf ~/dev/rev_harness/.claude/tmp
```

**Tier 3 recommendation**: skip unless you specifically need the 62 MB back.
The 0.0.17 CHANGELOG explicitly points at `.claude/tmp/multi-repo-sync/codex_017_grade_r*.md`
files; deleting them makes the audit chain unresolvable.

---

## Recommended sequence

For most cases:

```bash
# 1. Tier 1a (orphan semantic dbs) — ~30 MB, fully safe
~/dev/rev_harness/harness-rust/target/debug/semantic-mcp gc --older-than-days 7 --force

# 2. Tier 1b but skip contact_dev (active development): ~2 GB
for r in rev_harness rev_salescopilot rev_scraping; do
  find ~/dev/$r \( \
       -name node_modules -o -name dist -o -name build -o -name .next -o -name .venv \
    -o -name __pycache__ -o -name .pytest_cache \
    \) -type d -not -path "*/.git/*" -prune -exec rm -rf {} +
done

# 3. Tier 2a on the 2 smallest workspaces first: ~25 GB
( cd ~/dev/rev_harness/harness-rust && cargo clean )
( cd ~/dev/rev_salescopilot/harness-rust && cargo clean )

# 4. Verify: disk reclaimed?
du -sh ~/dev/{rev_harness,rev_scraping,rev_salescopilot,contact_dev}

# 5. If still tight, do contact_dev + rev_scraping cargo clean (big payoff)
```

**Expected result**: ~25–145 GB returned depending on how far you go.

---

## Reversibility cheat-sheet

| What you delete | What brings it back | Cost |
|---|---|---|
| `~/.semantic-mcp/queueruntime-*` | (nothing — orphan test residue) | 0 (was already dead) |
| `node_modules/` | `npm install` or `pnpm install` | ~30s per repo |
| `harness-rust/target/` | `cargo build --release -p agent-core -p semantic-mcp` | 5–15 min per workspace |
| `.next/` | `next build` or `next dev` first run | 1–3 min |
| `.venv/` | `uv venv && uv pip install -r requirements.txt` | 30s–2 min |
| `.claude/tmp/` | (lost — audit trail broken if grading verdicts deleted) | irreversible for audit value |

---

## Why this isn't a script

`development-junk-cleanup` skill exists but its policy is **inspect-first,
no unattended delete**. This plan follows the same discipline:

1. Run the dry-run command, look at the list
2. Decide what's safe given your active work
3. Run the actual delete, one tier at a time
4. Verify disk reclaimed before moving to the next tier

Don't pipe everything into one `rm -rf` loop. The 145 GB sitting in `target/`
took hours to compile cumulatively; throwing it away in a single command is
fine but rebuilding it on demand should be a deliberate choice, not a
side-effect of overzealous cleanup.
