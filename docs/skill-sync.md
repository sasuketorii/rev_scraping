# Skill Sync Contract (`scripts/sync-knowledge-pack.sh`)

This document defines the cross-scope skill-pack sync contract for RevHarness
adopters. It covers what the report-only check does today and how a future
`--apply` step must behave so that project-local overrides are preserved.

## Scope

The script covers 9 cross-scope skill packs (audit §6.1):

- `rust-skills-knowledge-pack`
- `typescript-skills-knowledge-pack`
- `go-skills-knowledge-pack`
- `revc-shadcn-frontend-workflow`
- `self-growth-proposal-triage`
- `supabase-deploy-guard`
- `cloudflare-deploy-guard`
- `payload-cms-deploy-guard`
- `codex-app-server-guard`

Each pack is compared across three scopes:

| Scope    | Location                                            |
|----------|-----------------------------------------------------|
| project  | `$REPO_ROOT/.claude/skills/<pack>`                  |
| user     | `$HOME/.claude/skills/<pack>`                       |
| agents   | `$REPO_ROOT/.agent/skills/<pack>` (optional)        |

## Modes

- **Report-only (this session)**: `./scripts/sync-knowledge-pack.sh` runs a
  read-only diff and writes `.agent/active/skill-sync-report.md`. No file
  outside the repo working tree is written. There is intentionally no
  `--apply` flag in this session — Supabase patching and any user-scope writes
  are deferred to a follow-up session.
- **Future `--apply` (not implemented here)**: planned default direction is
  project -> user. When implemented, `--apply` must respect the preserve
  contract below.

## Project-only preserve contract

Some adopting projects need to keep workspace-specific overrides inside an
otherwise-mirrored skill file (for example, a Rust pack that pins a workspace
baseline to `edition = "2021"` while the global pack documents R&D rows for
edition 2024). The sync contract recognises two preserve markers so the
override can survive future apply runs:

### 1. Explicit fence

```
<!-- preserve:project-only:start -->
... project-local override content ...
<!-- preserve:project-only:end -->
```

The script reports the line range of every fence pair it finds. A future
`--apply` step must read the user-side fence content (if present) and splice
it back into the project-side content before writing the user-scope file.

### 2. Implicit "workspace baseline" header

Any markdown heading line matching `^#{1,6} .* workspace baseline` is treated
as the start of an implicit preserve block. The script reports the heading
line; a future `--apply` step should treat the entire section under that
heading (up to the next equal-or-higher-level heading) as a preserve window.

This pattern matches headings like:

- `## Rev_SalesCopilot workspace baseline (2026-06-01)`
- `### Rev_FooBar workspace baseline`

## Report contract

The report file (`.agent/active/skill-sync-report.md`) contains:

1. Top metadata (timestamp, repo root, user scope path, mode, direction).
2. Coverage list (the 9 packs above).
3. Per-skill block with:
   - presence per scope,
   - verdict per cross-scope pair (`exact mirror`, `drift: N files differ`,
     `missing on <scope>`),
   - project file count,
   - detected project-only preserve windows.
4. Notes section reminding readers that drift counts include files within
   preserve windows for visibility; a future `--apply` step must skip
   preserved line ranges when writing.

## Future `--apply` design (not implemented here)

When `--apply` is added in a follow-up session, it must:

1. Default direction is **project -> user**. A `--reverse` flag may be added
   later but is out of scope for the initial apply implementation.
2. For each file with `drift`:
   - If the file has no preserve windows on the user side, replace the
     user-scope file with the project-scope file byte-for-byte.
   - If the user-scope file contains preserve windows (fence or workspace
     baseline header), read each preserve window's content from the
     user-scope file and splice it back into the project-scope content at
     the matching anchor before writing.
3. `--apply` must be gated by an explicit `--dry-run` preview that prints the
   list of files that would change and the preserve windows that would be
   spliced. Both modes must reuse the same verdict format as the report-only
   check.
4. `--apply` must never touch files outside `$HOME/.claude/skills/<pack>`
   (when direction is project -> user). The script must refuse to run if the
   user-scope path is a symlink that points outside the expected location.
5. The Supabase pack (`supabase-deploy-guard`) is intentionally in scope for
   the future apply, but only after the dedicated Supabase patching session
   has produced an authoritative project-side baseline.

## Acceptance (this session)

- `bash -n scripts/sync-knowledge-pack.sh` exits 0.
- `./scripts/sync-knowledge-pack.sh` exits 0 and writes a non-empty report.
- The report names each of the 9 packs and gives each a verdict.
- The script contains the preserve detection logic (grep / awk for
  `preserve:project-only` and `workspace baseline`).
- No `--apply` flag is implemented or referenced as actionable.
