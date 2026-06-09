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
3. `docs/canonical-invariants.md` for the 13-invariant on-disk single source.
4. `docs/manual/verification-truth-matrix.md` for acceptance authority.
5. `docs/manual/hsdi-architecture-overview.md` for HSDI four-layer model.
6. The applicable role definitions under `docs/roles/`.
7. Operator manuals under `docs/manual/*.md` (lifecycle, smoke gate,
   release binary privacy, safe-dispatch, state-transition guard,
   snapshot hooks, path-leak soft layer).
8. Vendor-specific rules only for the agent family actually operating.

If two sources conflict, do not silently choose a convenient rule. Prefer the
newer and more specific user instruction unless it weakens safety, evidence,
secrets handling, or deterministic acceptance requirements.

## Session Start (Orchestrator session)

When this harness is driven by an orchestrator session — whether Claude Code or
Codex — the orchestrator **must** invoke the `orchestrator-bootstrap` skill at
session start, before the first substantive action (planning, delegating,
editing, reviewing, or reporting). Both families expose Skills; use the
family-native skill invocation (Claude Code: `Skill` tool; Codex: its native
skill mechanism).

`orchestrator-bootstrap` is the canonical session-start routine that raw-reads
required context, consults memory, user meta-goal, and truth read order in one
pass, and may use a FRESH semantic capsule only as optional acceleration. Skip
only when the user explicitly says to skip.

Cursor agents are not orchestrators in this harness and follow `.cursor/rules/`
instead.

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

## Dual-native orchestration boundary

Codex native subagents are configured through `.codex/config.toml` and
`.codex/agents/*.toml`; Claude-native agents use their own Claude-local
configuration. Native subagents must not recursively invoke cross-family
wrapper scripts. Cross-family handoffs use wrapper entrypoints and durable
artifact packets so reviewer evidence, task scope, and acceptance state remain
auditable across agent families.

The root Codex model-policy mirror is intentionally minimal and mirrors the
registry-backed baseline:

```toml
model = "gpt-5.5"
model_reasoning_effort = "medium"
web_search = "cached"

[features]
multi_agent = true
```

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

## Governance Lessons (HSDI 由来)

These lessons are reusable orchestration discipline derived from HSDI Phases
A-H. They are not phase-specific and apply to every future phase.

- **Reviewer findings are hypotheses, not verdicts.** Orchestrators own
  production-reachability analysis before absorbing any reviewer
  recommendation. A reviewer can be highly confident and still be wrong about
  what the change actually breaks in production. See `CHANGELOG.md` §0.0.18
  Phase G §10 erratum for the canonical retract case (Round 2 Patch 4).
- **Agent-based dual-LGTM is provisional.** A 9+/10 verdict from both Opus
  xhigh and Codex xhigh is a strong signal but is not by itself a final
  verdict. I-12 (`docs/canonical-invariants.md` §I-12) requires
  `scripts/ci/phase-done-smoke.sh` exit 0 before `lgtm_stage=final` and
  before `state.json.phase=done` is permitted.
- **Defense-in-depth can disable the primary function.** A safety helper
  inserted to harden one surface can silently break the surface it was
  meant to protect. Cross-check every defense-in-depth change against the
  primary user-visible flow before merging.

## Deferred Work

Work consciously deferred past the current release is recorded in
`docs/manual/roadmap-wave-22.md` and the matching `CHANGELOG.md` "deferral"
section (e.g. §0.0.18 Wave 22 deferral). Do not silently expand a current
slice to absorb deferred items.

The canonical Wave 22 deferred item literals are:

- `decision.rs` Rust reader for `decisions` table
- `sem.decision.get` MCP tool
- `rev-harness upgrade --apply`
- `rev-harness uninstall --apply`
- TS Orchestrator PoC

## Reporting

Reports should distinguish worker outcome from acceptance state. Coder-style
work can report `DIFF`, `NO-CHANGE`, or `BLOCK`; final acceptance belongs to the
configured gate and reviewer/orchestrator process.

User-facing summaries should be concise, evidence-backed, and explicit about
tests run or not run. Avoid claiming LGTM, completed, or accepted unless the
truth matrix conditions for those words are satisfied.

## Index of 13 invariants (canonical anchor: `docs/canonical-invariants.md`)

| ID | Reference summary |
|---|---|
| I-1 | Privacy hard gate blocks raw path/secret leaks before commit. |
| I-2 | Tier 1 semantic capsule output stays byte-stable. |
| I-2b | Shipped `semantic-mcp` binary must scan privacy-clean. |
| I-3 | Dual-LGTM requires durable on-disk evidence and hashes. |
| I-4 | Graceful-shutdown hook fails open instead of blocking work. |
| I-5 | Wrapper help and behavior remain byte-pinned and parity-checked. |
| I-6 | Parallel dispatch requires exclusive `file_owner_token` ownership. |
| I-7 | `PARALLEL_QUIESCE` is scoped to the dispatch window only. |
| I-8 | Safe dispatch records pre/post SHA256 snapshots. |
| I-9 | ExecPlan dispatch topology is linted before parallel work. |
| I-10 | Facades call child scripts; they do not absorb implementation. |
| I-11 | Destructive actions require explicit opt-in flags. |
| I-12 | Final phase advance requires smoke-gated dual-LGTM. |
| I-13 | Semantic MCP wire contract requires `semantic-mcp`, absolute launcher path, and no project_id env sentinel. |

### I-2b (Binary privacy stable)
Shipped Rust binary `harness-rust/target/release/semantic-mcp` MUST scan clean:
`strings <binary> | grep -E '/Users/|/home/|contact_dev|.cargo/registry/src|.rustup/toolchains'` = 0 hits.
Enforced by `scripts/ci/release-binary-privacy-scan.sh` (T-H-4 + T-H-4a/4b deliverable).

### I-12 (Smoke-gated dual-LGTM)
Agent-based dual-LGTM (Opus xhigh / Codex xhigh, 9+/10) is a **provisional** verdict only.
A **final** verdict requires `phase-done-smoke.sh` to execute and exit 0 on every step.
Advancing `state.json.phase = "done"` requires `lgtm_stage = final`
(enforced by `scripts/state-transition-guard.sh --require-lgtm-final`).

This invariant closes the structural gap observed across the prior 7 HSDI phases (A-G),
where agent-based 9+/10 dual-LGTM verdicts missed production smoke failures.
