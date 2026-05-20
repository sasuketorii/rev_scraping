# RevHarness invariants

This file is the vendor-neutral instruction source for any agent reading this
repository. Cursor, Codex, Claude, and future agent clients may all read it, so
it contains only project-wide invariants and cross-agent responsibilities.

Vendor-specific operating rules belong elsewhere:

- Claude Code: `.claude/CLAUDE-LOCAL.md`
- Cursor: `.cursor/rules/`
- Codex: `.codex/config.toml`, `.codex/agents/`, and the relevant wrapper docs

## Purpose

RevHarness is a multi-agent development harness for building systems with high
accuracy, deterministic verification, low resource overhead, and clear review
boundaries. Every agent is responsible for preserving those invariants even when
it is only editing documentation or orchestration metadata.

This file is the root-level invariant contract. It is not a replacement for role
definitions, vendor-specific rules, or task-local slice contracts.

## Read Order

Use this order when deciding what controls a task:

1. The user's current instruction and explicit task scope.
2. This `AGENTS.md` file for vendor-neutral repo invariants.
3. The applicable role definitions under `docs/roles/`.
4. `docs/manual/verification-truth-matrix.md` for acceptance authority.
5. Vendor-specific rules only for the agent family actually operating.

If two sources conflict, do not silently choose a convenient rule. Prefer the
newer and more specific user instruction unless it weakens safety, evidence,
secrets handling, or deterministic acceptance requirements.

## Acceptance Authority

`docs/manual/verification-truth-matrix.md` is the acceptance authority for this
repository. A wrapper setting, model setting, agent response, or reviewer note
does not by itself prove completion.

Before reporting a task as accepted or ready for the next gate, the responsible
agent must preserve the exact required checks, their results, the covered scope,
and an artifact pointer or explicit no-artifact reason.

## Evidence Convention

Task evidence should be written under `.claude/tmp/<task>/` or `.agent/active/`
unless a slice contract names a more specific destination. Evidence includes
command logs, review packets, smoke-test outputs, migration notes, and block
reports.

The reader's responsibility is to keep evidence traceable. Do not replace a
machine-check result with reasoning-only confidence, and do not cite volatile
terminal output as the sole evidence when the slice requires a durable artifact.

## Project Identity

`.shared/project_id` is immutable project identity. Agents may read it when they
need to bind state, cache, semantic index, or evidence to this checkout.

Do not rewrite, normalize, or regenerate `.shared/project_id` as part of routine
cleanup. If it is malformed or missing, fail closed and report the blocker.

## Secret Redaction

Never include raw secrets, credentials, API keys, tokens, private cookies, or
unredacted sensitive payloads in agent output, logs, handoffs, tests, fixtures,
or screenshots. Use a redacted preview that preserves only enough shape for
debugging.

When a command might print secrets, redirect or filter the output before it
becomes evidence. If safe redaction is not possible, stop and ask for a safer
inspection path.

## Cross-Family Delegation

When an agent delegates work to another agent family, it must use the canonical
wrapper or documented entrypoint in `scripts/` for that family and role. Direct
binary calls are not completion evidence and may bypass safety guards.

Cursor agents must not delegate to other agent families unless a later
Cursor-specific rule explicitly permits it. Claude and Codex orchestration must
keep same-family native delegation inside the current agent family, and use
durable artifact packets when crossing families.

## Vendor-Specific Boundaries

Do not put Claude-only, Codex-only, or Cursor-only operating rules in this file.
Root instructions are shared context, so vendor-specific rules here can cause
another agent to follow the wrong runtime contract.

Claude-specific orchestration, role switching, wrapper, and state-management
rules live in `.claude/CLAUDE-LOCAL.md`. Cursor-specific attachment and CLI
rules live under `.cursor/rules/`. Codex-specific runtime configuration lives in
`.codex/` and the canonical wrapper documentation.

## Change Discipline

Keep edits inside the approved slice surface. Do not reformat, rename, archive,
or clean unrelated files while handling a narrow task.

If the worktree already contains changes outside the slice, treat them as
someone else's work. Read around them when necessary, but do not revert or
normalize them unless the user explicitly asks.

## Deterministic Checks

Each task must name the exact checks that matter for its surface. A docs-only
migration may use targeted grep and smoke tests; runtime or security-sensitive
changes need the relevant unit, integration, release, or gate checks.

If a required check cannot run, record the exact command attempted, why it could
not run, and what evidence is needed to unblock it. Do not downscope a required
check after implementation just to produce a cleaner report.

## Reporting

Reports should distinguish worker outcome from acceptance state. Coder-style
work can report `DIFF`, `NO-CHANGE`, or `BLOCK`; final acceptance belongs to the
configured gate and reviewer/orchestrator process.

User-facing summaries should be concise, evidence-backed, and explicit about
tests run or not run. Avoid claiming LGTM, completed, or accepted unless the
truth matrix conditions for those words are satisfied.
