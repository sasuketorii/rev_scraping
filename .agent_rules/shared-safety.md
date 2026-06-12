# Shared Safety Rules

Charter: never-rules and fail-closed defaults. Safety text here is intended to
be verbatim-or-stronger than the pre-consolidation root copies.

- [RS-SAFE-01] Never include raw secrets, credentials, API keys, tokens,
  private cookies, or unredacted sensitive payloads in agent output, logs,
  handoffs, tests, fixtures, screenshots, or reports.
- [RS-SAFE-02] When a command might print secrets, redirect or filter output
  before it becomes evidence; if safe redaction is not possible, stop and ask
  for a safer inspection path.
- [RS-SAFE-03] `.shared/project_id` is immutable project identity. Do not
  rewrite, normalize, regenerate, or opportunistically recreate it during
  routine cleanup, rule migration, or wrapper work.
- [RS-SAFE-04] If `.shared/project_id` is missing or malformed, fail closed and
  report the blocker instead of creating a new identity.
- [RS-SAFE-05] Destructive actions require explicit opt-in flags or explicit
  user instruction; follow I-11 in `docs/canonical-invariants.md` and do not
  infer destructive approval from adjacent maintenance requests.
- [RS-SAFE-06] Keep edits inside the approved slice surface. Do not reformat,
  rename, archive, or clean unrelated files while handling a narrow task.
- [RS-SAFE-07] Treat pre-existing worktree changes outside the slice as someone
  else's work. Read around them when necessary, but do not revert or normalize
  them unless explicitly asked.
- [RS-SAFE-08] If a change surface cannot be classified or safely sliced, stop
  as `BLOCK` and route through the applicable role or matrix fail-closed path.
- [RS-SAFE-09] Do not weaken deterministic checks, evidence requirements,
  lease closeout, acceptance language, or security rules to make a report look
  cleaner.
- [RS-SAFE-10] In adopter-template contexts, `.agent_rules/`, `scripts/`,
  `.claude/`, and `.codex/` are protected harness surfaces and should not be
  modified; legacy alias `agent_base` / `agent-base` derived existing harness
  files are the same protected surface. In RevHarness core development, only
  the explicit slice-authorized surface may be changed.
- [RS-SAFE-11] Do not lower test criteria or weaken tests just to make an
  implementation pass; test changes require a specification change or a
  documented test bug.
