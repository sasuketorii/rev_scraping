# safe-dispatch.sh — Parallel Coder Dispatch Contract Reference

**Status:** HSDI Phase B deliverable, docs sweep 2026-05-26 (Phase H).
**Enforcement script(s):** `scripts/ci/check-execplan-topology.sh`,
`scripts/safe-dispatch.sh`, `.claude/hooks/snapshot-{pre,post,stop}.sh`.
**Canonical invariant(s):** I-6 (file_owner_token exclusivity), I-7
(PARALLEL_QUIESCE sweep gate), I-8 (Pre/Post SHA256 snapshot).
**Acceptance criterion (AC):** AC-B (dispatch topology lint + snapshot diff
non-empty for declared writers, empty for read-only agents).
**Smoke step (if applicable):** step `phase-B` of `scripts/ci/phase-done-smoke.sh`.

> Coder agent dispatch entry. Pre/post SHA256 snapshot + child env injection
> enforce I-6/I-7/I-8 at the orchestrator boundary, so a single misbehaving
> child cannot silently mutate a sibling agent's owned files.

## 1. What this is

`scripts/safe-dispatch.sh` is the **canonical wrapper-spawn entry** used by
the orchestrator whenever multiple coder agents run in parallel (or whenever
a single coder must be sandboxed to declared owner paths). It was introduced
in HSDI Phase B as the runtime half of the Self-Defense Layer; the static
half is the `dispatch_topology` block in every ExecPlan plus
`scripts/ci/check-execplan-topology.sh`.

Three jobs, in order:

1. Take a **pre-snapshot** SHA256 of every path declared in
   `--owner-tokens`, written to `.agent/state/locks/<task>.before.sha256`.
2. Spawn the named wrapper child with `REVHARNESS_PARALLEL_QUIESCE=1`
   exported into the child env only (never the orchestrator's env).
3. Take a **post-snapshot** of the same paths after the child exits,
   compute changed paths, append a structured row to
   `.agent/metrics/dispatch_events.jsonl`, and propagate the child exit code.

Any change to a path **not** in `--owner-tokens` is invisible to this script
by design — owner-set discipline is enforced upstream by ExecPlan lint, not
post-hoc by safe-dispatch. safe-dispatch's job is to make the declared set
hash-visible so a later reviewer can confirm whether the child kept its
contract.

Throughout this document, `owner_tokens` refers to the declared set passed
via the `--owner-tokens` flag — the same vocabulary used by the
ExecPlan `dispatch_topology` block's `file_owner_token` field.

## 2. CLI

```
scripts/safe-dispatch.sh \
  --task-id <id> \
  --owner-tokens "path1,path2,..." \
  --wrapper <wrapper_path> \
  [--wrapper-args "<args>"] \
  -- "<prompt>"
```

| Flag | Required | Description |
|------|----------|-------------|
| `--task-id <id>` | yes | Task identifier (e.g. `T-H-1`). Restricted to `[A-Za-z0-9._-]`, no path separators. Used as the filename stem for snapshot files. |
| `--owner-tokens <list>` | yes | Comma-separated list of file paths the child is permitted to mutate. Each path must be a regular file or absent (missing files are recorded as `MISSING`). |
| `--wrapper <path>` | yes | Executable to spawn (typically `scripts/codex-wrapper.sh` or `scripts/claude-wrapper.sh`). |
| `--wrapper-args "<args>"` | no | Argv passed to the wrapper, word-split (e.g. `"--role high-coder --stdin"`). |
| `-- "<prompt>"` | yes | Separator + literal prompt text. Everything after `--` is concatenated into a single prompt string and piped into the wrapper on stdin. |
| `-h`, `--help` | — | Print usage to stderr and exit 0. |

Argument validation is strict: missing required flags exit 2 with a
`safe-dispatch:` prefix on stderr. Any unknown argument is also exit 2.

## 3. Behavior (4 steps)

The script runs deterministically in four phases:

1. **Pre-snapshot.** For each `--owner-tokens` path, compute SHA256 using
   `sha256sum` (or `shasum -a 256` fallback). Write the result to
   `.agent/state/locks/<task-id>.before.sha256` via an atomic
   `mktemp + mv` pattern. Missing files are recorded literally as `MISSING`
   so a later create-vs-modify distinction is preserved.
2. **Env injection.** Set `REVHARNESS_PARALLEL_QUIESCE=1` and
   `REVHARNESS_TASK_ID=<task-id>` in the child process environment **only**.
   The orchestrator's own env is not modified — the variables exist for the
   duration of the wrapper child and nothing else. This is the runtime
   anchor for I-7.
3. **Wrapper spawn.** Invoke the wrapper with `--wrapper-args` word-split
   into argv and the prompt fed on stdin via a tmpfile under a per-run
   `mktemp -d` directory. `set +e` brackets the call so a non-zero child
   exit does not skip the post-snapshot.
4. **Post-snapshot + event emit.** Recompute SHA256 of the same paths to
   `.agent/state/locks/<task-id>.after.sha256`, diff before vs. after,
   and append a single JSONL row to `.agent/metrics/dispatch_events.jsonl`.
   The script then exits with the wrapper's exit code (not its own).

The tmpdir is removed via `trap` on `EXIT|HUP|INT|TERM`, so a killed
dispatcher does not leak prompt files.

## 4. JSONL event schema

Path: `.agent/metrics/dispatch_events.jsonl`
Schema name: `safe-dispatch/v1`

```json
{
  "ts": "2026-05-26T12:34:56Z",
  "event": "safe_dispatch",
  "task_id": "T-H-1",
  "wrapper": "scripts/codex-wrapper.sh",
  "exit_code": 0,
  "owner_paths": ["scripts/safe-dispatch.sh", "docs/manual/safe-dispatch.md"],
  "changed_paths": ["docs/manual/safe-dispatch.md"]
}
```

Field notes:

- `ts` is UTC, ISO-8601 with `Z` suffix.
- `owner_paths` echoes `--owner-tokens` in declared order.
- `changed_paths` lists only the subset whose SHA256 differed between the
  before and after snapshots (including transitions from `MISSING` to a real
  hash, and vice versa).
- `exit_code` is the wrapper child's exit code, not safe-dispatch's.

A reviewer reads this file to answer two questions: "did the agent actually
write?" (changed_paths non-empty) and "did it stay inside its lane?"
(every changed path appears in owner_paths). The second question is
tautological by construction — paths outside owner_paths are simply not
snapshotted — which is why I-6 must be enforced **before** dispatch by
ExecPlan lint, not after the fact by this script.

## 5. Invariant linkage

| Invariant | Concern | safe-dispatch role |
|-----------|---------|--------------------|
| **I-6** file_owner_token exclusivity | No two concurrent agents may declare overlapping owner tokens. | safe-dispatch consumes the owner set per task; disjointness is verified upstream by `scripts/ci/check-execplan-topology.sh --strict`. |
| **I-7** PARALLEL_QUIESCE sweep gate | During parallel dispatch, janitor / shutdown hooks must skip destructive sweeps. | safe-dispatch is the **only** sanctioned setter of `REVHARNESS_PARALLEL_QUIESCE=1` for the wrapper child. Facade-wide export is forbidden (Phase H R-H3 erratum). |
| **I-8** Pre/Post SHA256 snapshot | Every dispatched task must leave a reviewable hash trail of its declared write set. | safe-dispatch writes `before.sha256` and `after.sha256` under `.agent/state/locks/` plus a `dispatch_events.jsonl` row. |

I-7 deserves a sharper note: the env variable is **dispatch-window scoped**.
It must exist for the wrapper child and only the wrapper child. Exporting
it from `scripts/rev-harness` (the facade) or from any login shell breaks
janitor sweeps and `clean`-style subcommands — they short-circuit with
`skip: PARALLEL_QUIESCE active` and exit 0 without doing the work. The
correct scope is `safe-dispatch.sh` line 182 (`REVHARNESS_PARALLEL_QUIESCE=1
... "$wrapper" ... < "$prompt_file"`) and nowhere else.

## 6. Orchestrator workflow

Recommended sequence whenever the orchestrator dispatches two or more coder
agents in the same wave:

1. Author or update an ExecPlan with an explicit `dispatch_topology` block.
   Each entry lists `task_id`, `file_owner_token`, `worker_outcome`
   vocabulary, and `evidence_destination`.
2. Run `bash scripts/ci/check-execplan-topology.sh --strict`. Exit 0 is
   the I-6 + I-9 acceptance gate. Reject the dispatch otherwise.
3. For each task, invoke:
   ```
   bash scripts/safe-dispatch.sh \
     --task-id T-X-1 \
     --owner-tokens "<from-execplan>" \
     --wrapper scripts/codex-wrapper.sh \
     --wrapper-args "--role high-coder --stdin" \
     -- "<task prompt>"
   ```
4. After all children exit, inspect `.agent/metrics/dispatch_events.jsonl`
   for the wave's `task_id` rows. Confirm `changed_paths ⊆ owner_paths`
   (always true by construction) and that no read-only agent produced a
   non-empty `changed_paths`.
5. If a writer agent's `changed_paths` differs from the ExecPlan
   declaration, treat it as an I-6/I-8 contract violation and roll back
   from the `before.sha256` record (see §8).

## 7. CI wiring

`scripts/ci/phase-done-smoke.sh` exercises safe-dispatch in its Phase B
step. Each downstream `scripts/ci/hsdi-phase-{B..H}-done.sh` script asserts
that the relevant task's snapshot pair exists under `.agent/state/locks/`
and that the corresponding `dispatch_events.jsonl` row reports the expected
`exit_code` and `changed_paths` shape. A missing snapshot pair is a hard
failure — Phase-done smoke will exit non-zero and block the final dual-LGTM
gate (I-12).

The static counterpart is `scripts/ci/check-execplan-topology.sh`, which
runs on every ExecPlan commit and pre-dispatch. I-6 + I-9 share that same
command line; safe-dispatch never re-validates topology at spawn time
because the cost is paid upstream once.

## 8. Failure recovery

When a `before.sha256` / `after.sha256` diff reveals an unexpected change
(e.g. a writer touched a file outside its declared set, or a read-only
agent mutated anything), the recovery path is:

- **Identify the drift.** Read `.agent/state/locks/<task-id>.before.sha256`
  and `.after.sha256`; compare to the ExecPlan-declared owner set.
- **Reconstruct prior content.** If the drifted file is git-tracked, use
  `git cat-file -p <before-sha>` — the snapshot records SHA256 of file
  contents, not git blob SHAs, so the recovery path is `git checkout --
  <file>` (restore from HEAD/index) or `git restore --source=<commit>
  <file>` for a known-good commit. The `before.sha256` record is the
  audit anchor, not a content store.
- **Child crash.** If the wrapper exited non-zero, the post-snapshot still
  runs (Phase B intentional design). Inspect `changed_paths` — a partial
  write may have landed and need rollback even though the agent failed.
- **Concurrent execution.** safe-dispatch does not implement its own flock;
  parallel safety comes from disjoint owner sets enforced by I-6 plus
  unique `task-id` values. The orchestrator is responsible for never
  spawning two `safe-dispatch.sh` invocations with the same `--task-id`
  in the same wave. The companion janitor (`scripts/rev-harness-janitor.sh`)
  and phase-done smoke gate both implement `flock` independently.

## 9. Cross-references

- `docs/canonical-invariants.md` — I-6 / I-7 / I-8 / I-9 formal definitions.
- `docs/manual/snapshot-hooks.md` — `.claude/hooks/snapshot-{pre,post,stop}.sh`
  integration with PreToolUse / PostToolUse / Stop events.
- `docs/manual/state-transition-guard.md` — `scripts/state-transition-guard.sh`
  and its interaction with the snapshot pair as evidence for phase advance.
- `docs/manual/phase-done-smoke.md` — `scripts/ci/phase-done-smoke.sh`
  per-phase invocation of safe-dispatch and the resulting acceptance gate.
- `scripts/ci/check-execplan-topology.sh` — upstream I-6/I-9 enforcement and
  `dispatch_topology` block schema.
- `docs/manual/hsdi-architecture-overview.md` §Self-Defense — historical
  context for the Phase B introduction of safe-dispatch + the Phase H
  R-H3 erratum that restored I-7's dispatch-window scope.
- `scripts/snapshot-dispatch.sh` — companion helper for ad-hoc snapshot
  capture outside the safe-dispatch flow (debugging / forensics).
- `scripts/harness-bg-spawn.sh` — long-running background spawn variant;
  obeys the same `REVHARNESS_PARALLEL_QUIESCE` contract but does not
  produce SHA256 snapshots and is therefore **not** a substitute for
  safe-dispatch in I-6/I-7/I-8-governed waves.
