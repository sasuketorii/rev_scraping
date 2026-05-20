# RevHarness Vendor-Neutral Bootstrap

This file is auto-read by both Claude Code and Cursor CLI. It is intentionally
vendor-neutral and contains only shared RevHarness bootstrap instructions.
Vendor-specific operational rules are kept out of this file so that one agent
family does not accidentally follow another family's runtime contract.

Read `AGENTS.md` first for repository-wide RevHarness invariants. Claude Code
orchestrators must then read `.claude/CLAUDE-LOCAL.md` before operating, because
Claude-specific wrapper, delegation, state, and role-switching rules live there.
Cursor-specific rules live under `.cursor/rules/`.

## Scope

This file is the root bootstrap for agents that auto-read `CLAUDE.md`. It points
to the authoritative instruction locations and defines only the shared read
order for this repository.

It is not the source of truth for Claude-only orchestration, Codex-only runtime
policy, Cursor project rules, reviewer verdicts, or acceptance closure.

## Shared Sources

- `AGENTS.md`: vendor-neutral RevHarness invariants for every agent family.
- `.claude/CLAUDE-LOCAL.md`: Claude Code orchestrator-specific operating rules.
- `.cursor/rules/`: Cursor-specific project rules and attachment behavior.
- `docs/roles/*.md`: canonical role definitions.
- `docs/manual/verification-truth-matrix.md`: acceptance and evidence authority.
- `.agent/PROJECT_CONTEXT.md`: project-specific context.
- `.shared/project_id`: immutable project identity.

## Truth Read Order

Use this order for shared, vendor-neutral decisions:

1. The user's current instruction and explicit slice scope.
2. `AGENTS.md` for repo-wide RevHarness invariants.
3. The applicable role definition under `docs/roles/`.
4. `docs/manual/verification-truth-matrix.md` for acceptance authority.
5. The vendor-specific rule file for the agent family actually operating.

Vendor-specific rules may narrow how an agent acts, but they do not override the
truth matrix's deterministic acceptance requirements.

## Claude Bootstrap

When the current operator is Claude Code, read `.claude/CLAUDE-LOCAL.md` at
session start before planning, delegating, editing, reviewing, or reporting. The
root file is intentionally too small to carry Claude orchestration details.

If `.claude/CLAUDE-LOCAL.md` is missing or unreadable during a Claude Code
orchestrator session, fail closed and report that the Claude-specific operating
contract is unavailable.

## Cursor Bootstrap

Cursor agents should treat this file as shared context only. Cursor-specific
rules, including rule attachment and mode-specific behavior, belong in
`.cursor/rules/` and must not be inferred from Claude or Codex documents.

If Cursor-specific rules are absent, do not invent delegation, wrapper, or
runtime behavior from this file. Follow the user instruction, `AGENTS.md`, and
the truth matrix.

## Codex Bootstrap

Codex agents should treat this file as shared context only. Codex runtime
configuration and native subagent presets live under `.codex/`; external
caller-facing execution contracts are documented with the canonical wrappers in
`scripts/`.

This bootstrap does not redefine Codex model policy, sandbox policy, or reviewer
authority.

## Acceptance

`docs/manual/verification-truth-matrix.md` is the authority for acceptance,
worker outcome, evidence placement, reviewer verdict validity, and completion
language. A response, wrapper invocation, or local convention is not enough to
claim acceptance.

Every agent must preserve required deterministic checks, command results,
covered scope, and evidence pointers according to the active slice contract.

## Evidence And Secrets

Use `.claude/tmp/<task>/` or `.agent/active/` for task evidence unless the slice
contract names another destination. Keep artifacts traceable enough for a later
reviewer to replay the decision.

Do not write raw secrets, credentials, tokens, cookies, or unredacted sensitive
payloads into prompts, logs, artifacts, tests, screenshots, or reports. Prefer
redacted previews and record when raw output was intentionally withheld.

## Project Identity

`.shared/project_id` is immutable project identity. Do not regenerate or edit it
during routine instruction, wrapper, or rule migrations.

If project identity is missing or malformed, stop and report the blocker instead
of creating a new identity opportunistically.

## Maintenance Rule

Keep this file short and vendor-neutral. If an update adds agent-family-specific
commands, wrapper details, role-switching obligations, state schemas, or
delegation mechanics, move that content to the vendor-specific location and
leave only a pointer here.
