# Shared Workflow Rules

Charter: how work moves through RevHarness. Acceptance state machines and
schema details remain in `docs/manual/verification-truth-matrix.md`.

- [RS-WORK-10] Before work begins, read the active plan under `.agent/active/`
  when one exists and align implementation to the current slice contract.
- [RS-WORK-11] Use Blueprint/TDD for implementation work unless the documented
  slice exception applies: docs/config-only changes or tiny non-logic edits may
  skip it when the reason is recorded in the SOW or report.
- [RS-WORK-12] Do not pass a broad task directly to a coder or reviewer. First
  determine `task class / schema profile / change surface / required checks /
  evidence destination / completion boundary`.
- [RS-WORK-13] The canonical classifier entrypoint is
  `scripts/rev-harness-task-classifier.sh classify --intent <intent> --files <path>... --json`.
- [RS-WORK-14] `light` direct handling is allowed only for non-normative typo,
  prompt wording, admin bookkeeping, or existing-reference cleanup that does not
  touch runtime code, role/policy/skill behavior, wrappers, model policy,
  semantic authority, security/trust boundaries, release/tag/merge, gates, or
  acceptance/final-signoff.
- [RS-WORK-15] Role, policy, skill, wrapper, model-policy, semantic, security,
  release, gate, or acceptance changes are `standard` or `heavy` and must use
  normal Coder/Reviewer/release discipline.
- [RS-WORK-16] For integration branches (`main`, `develop`, `release/*`),
  direct editing is normally prohibited. Use `scripts/hydra new <task>` or a
  git worktree unless the documented session exception applies.
- [RS-WORK-17] Worktree exceptions are session-scoped and must be recorded with
  the permission, changed files, and reason.
- [RS-WORK-18] Product code for new RevHarness projects defaults to `src/`.
  Existing adopters may retain native layouts such as `apps/`, `packages/`, or
  `services/` as explicit compatibility paths.
- [RS-WORK-19] `workspace/` is for disposable Hydra worktrees and must not hold
  permanent committed product code.
- [RS-WORK-20] SOW, handoff, prompts, and evidence artifacts live under
  `.agent/active/**` or `.claude/tmp/**` unless the slice contract names a more
  specific destination.
- [RS-WORK-21] Stable docs must not store latest-run artifact status as if it
  were durable truth; volatile evidence remains in the slice evidence
  destination.
- [RS-WORK-22] Deprecated or obsolete tests/docs are archived only when the
  active slice authorizes that archival surface.
- [RS-WORK-23] Safe merge, dispatch topology, ownership tokens, and phase
  advance gates defer to the relevant manuals and invariants in
  `docs/manual/**` and `docs/canonical-invariants.md`.
- [RS-WORK-24] Preserve existing code style, project structure, and naming
  conventions unless the active slice explicitly authorizes changing them.
- [RS-WORK-25] For technical unknowns and error resolution, prefer official
  documentation or the repository's official-doc links over speculation.
- [RS-WORK-26] For a new project with only requirements or no initialized
  environment, consult `setup/setup_rules.md` before setup or rule alignment.
- [RS-WORK-27] After implementation, run the checks required by the active
  slice and fix root causes rather than applying symptom-only workarounds.
- [RS-WORK-28] Agents MUST verify that worktree-created SOW filenames merge
  back without collisions before merge.
- [RS-WORK-29] Handoffs assume the next agent has no implicit context; prompts
  must include the current state, important facts, failed attempts, and known
  blockers instead of relying on unstated history.
- [RS-WORK-30] Once a handoff prompt and feedback have unblocked the work,
  archive the prompt and feedback under the appropriate archive locations
  instead of leaving them as active working artifacts.
- [RS-WORK-31] Toolchain choices should follow the project contract. When no
  stronger local contract exists, Python uses `uv`, Node.js uses one consistent
  package manager such as `npm` or `pnpm`, and direct legacy tool use requires
  a compatibility reason.
- [RS-WORK-32] Project-specific technical stack, requirements, and
  specification details come from the project `README.md` and `.agent/`
  requirement/context files before generic rule text.
- [RS-WORK-33] Code-signing, notarization, CI trigger, hash-recording, and
  release-operation details defer to the dedicated signing/build manuals and
  workflow files; update those records when signing procedures change.
- [RS-WORK-34] Role-conflict handling is explicit: do not let a reviewer become
  an implementer directly, declare role changes before switching, and split
  mixed coder/reviewer requests through the orchestrated flow.
- [RS-WORK-35] Merge Queue and branch protection are required for protected
  integration branches unless an explicit emergency exception records owner
  approval, urgency, post-review, and documentation.
- [RS-WORK-36] After implementation, perform a self-audit of the changed
  surface for security, performance, maintainability, and requirement fit
  before reporting the worker outcome.
- [RS-WORK-37] SOW files are recorded under `.agent/active/sow/` using the
  merge-safe filename form `YYYYMMDD_[TaskName].md`; one session should leave
  one traceable SOW file unless the active slice names a narrower record.
- [RS-WORK-38] Before `hydra close <task>` or a protected-branch merge of a
  Hydra worktree, `hydra preflight <task>` must pass; unresolved same-file
  worktree conflicts block automatic merge.
