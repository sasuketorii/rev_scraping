# Harness Plugin Boundary And Trust Matrix

Date: `2026-04-06`
Status: `authoritative plugin boundary`

## 1. Goal

This document closes `Phase 5: Plugin-Ready Boundary, Not Plugin Monolith` for the active harness plan.

The target state is:

- reusable workflows may be extracted later without moving repo authority out of the repository
- plugin and MCP surfaces have an explicit trust decision
- future orchestrators know what must remain repo-local

## 2. Boundary Model

| Layer | Current owner | Examples | Pluginization stance |
| --- | --- | --- | --- |
| Repo core | repo-root policy/config | `AGENTS.md`, `.agent_rules/RULES.md`, `.agent/PROJECT_CONTEXT.md`, `.codex/config.toml`, `.claude/settings.json` | never pluginize |
| Thin coordinator | repo-local shell | `.claude/commands/auto_orchestrate.sh`, `.claude/commands/lib/*.sh` | keep repo-local; shrink, do not externalize |
| Reusable workflow | prompts / agent presets / docs | `docs/prompts/*.md`, `.codex/agents/*.toml`, `docs/roles/*.md` | extractable only if no authority or security boundary moves |
| Local intelligence | repo-local semantic runtime | `harness-rust/crates/semantic-mcp/**`, `scripts/project-id.sh`, `scripts/resolve-semantic-project-id.sh`, `.shared/project_id` | never remote-pluginize; keep self-hosted and repo-scoped |

## 3. What Must Stay Repo-Local

The following are not valid plugin extraction targets:

- canonical `project_id` resolution and `.shared/project_id`
- `semantic.db` authority, review queue authority, and review trace authority
- fail-closed merge/preflight/queue gates
- sandbox / approval / wrapper security boundaries
- repo-local Git inspection that determines safety contracts

If a future design moves any of these outside the repo, that is a new plan, not a continuation of the current one.

## 4. Extraction Candidates

The following may be extracted later if they remain non-authoritative:

- reviewer prompt templates under `docs/prompts/`
- generic skill text and subagent presets under `.codex/agents/`
- documentation-only runbooks and checklists

Extraction rule:

- if the surface needs repo-local authority, fail-closed logic, or immutable identity, it stays local
- if the surface is only a reusable prompt or workflow description, it may become a plugin or skill artifact later

## 5. Trust Matrix

| Surface | Declared at | Provenance | Transport | Auth scope | Capability class | Repo write | Failure mode | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `semantic` MCP | `.claude/settings.json` and `.codex/config.toml` via `scripts/launch-semantic-mcp.sh` | self-hosted repo-local | local `stdio` | repo-local `project_id` namespace | read/write semantic DB, queue, review trace | no direct repo-file write; DB write only | authoritative mutators `BLOCK` when unavailable; read-only compatibility may return empty fallback only where already contracted | admitted, repo-local only |
| GitHub plugin/app | session/plugin surface, not repo-declared | official connector/plugin | remote connector API | user GitHub app installation scope | metadata read, PR/issue/review writes | no local filesystem write | optional/manual only; never authority for repo runtime | admitted as optional external tool |
| Local skills / agent presets | `.codex/agents/*.toml`, role docs, prompt docs | repo-authored | local files | none by themselves | workflow description only | none by themselves | if missing, workflow degrades to local manual routing; no authority loss | admitted, repo-local |
| Third-party MCP/plugin candidate | not currently declared | third-party or unknown | local or remote | unknown | unknown | unknown | default `BLOCK` until provenance, auth scope, write capability, and failure mode are documented | not admitted |
| Figma/design MCP candidate | not currently declared in repo runtime | third-party or unknown until explicitly pinned | expected remote or local bridge | design-system-specific | read or write depends on implementation | unknown | default `BLOCK` until separately audited and added to this matrix | not admitted |

## 6. Negative Boundary

This repo is explicitly **not** converging toward a single monolithic plugin.

Reasons:

- the harness carries repo-local authority and fail-closed safety contracts
- plugin transport is a trust boundary, not just a packaging format
- externalizing coordinator or DB authority would reintroduce ambiguity that earlier phases removed

## 7. Phase 5 Exit Criteria

`Phase 5` is considered closed only while the following remain true:

- this matrix is the single current trust decision for plugin/MCP surfaces
- unknown or unaudited plugin/MCP surfaces default to `BLOCK`
- no repo-authoritative state is moved into a plugin or remote service
- future extraction work is limited to reusable workflow text or presets, not authority surfaces
