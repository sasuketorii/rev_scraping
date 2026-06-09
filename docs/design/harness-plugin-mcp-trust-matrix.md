# Harness Plugin And MCP Trust Matrix

Date: `2026-04-06`
Historical plan artifacts are not shipped in the client-ready distribution. This document is the stable trust-boundary anchor.

## Policy

plugin / MCP は capability surface であると同時に trust boundary です。

この repo では次を hard rule とします。

- provenance 不明または未監査の plugin / MCP は既定で `BLOCK`
- repo write-capable surface は sandbox / approval boundary を迂回してはならない
- profile / skill / plugin / MCP frontmatter は権限昇格の起点になってはならない
- native Codex multi-agent / subagent orchestration は wrapper 再帰起動に逃がさない

## Current Repo-Configured Capability Surfaces

| Surface | Kind | Provenance | Transport | Auth / token source | Capability class | Filesystem / network expectation | Repo write | Failure contract | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `semantic` via `.claude/settings.json` and `.codex/config.toml` -> `./scripts/launch-semantic-mcp.sh` | MCP | `self-hosted` | `local stdio` | none beyond local process environment | `write-capable` for semantic DB, queue, review trace | reads repo, writes `semantic.db`, no remote network required | `No` direct repo write | query-only compatibility may return empty with `WARN`; mutator fallback is `BLOCK`; preflight fallback is `BLOCK` | authoritative durable state lives in `semantic.db`; repo-local auto-start is configured for Claude and Codex |
| `.claude/hooks/codex-review-hook.sh` | local hook | `self-hosted` | local command | none | `side-effect capable` | repo read, queue enqueue path, local shell execution | `No` direct repo write | malformed queue / invalid project identity is `BLOCK` | routes through DB-backed queue path |
| `.codex/agents/*.toml` | native agent preset | `self-hosted` | in-process | none | `workflow only` | inherits parent sandbox and network policy | inherited only | profile / preset driven privilege escalation attempt is `BLOCK` | not a plugin; listed because it is a capability boundary |
| `.claude/skills/*.md` | native skill | `self-hosted` | in-process | none | `workflow only` | inherits parent sandbox and network policy | inherited only | missing skill is explicit fallback or `WARN`; sandbox/approval escalation is `BLOCK` | workflow owner, not authority owner |

## External Plugin Policy

This repo does not declare any repo-configured remote plugin as part of runtime truth.

Therefore:

- external vendor plugins are optional session tooling, not repo authority
- a new external plugin cannot be used as runtime truth until a row is added to this matrix
- any external plugin with unknown provenance, remote write surface, or unclear auth scope is `BLOCK`

Required columns for any future row:

1. provenance
2. transport
3. auth scope and token source
4. capability class
5. filesystem / network expectation
6. repo write permission
7. failure result: `ALLOW`, `WARN`, or `BLOCK`

## Failure Contract Summary

| Case | Expected result |
| --- | --- |
| semantic MCP query path unavailable but compatibility query exists | `WARN` with empty compatibility result only |
| semantic MCP mutator path unavailable | `BLOCK` |
| semantic MCP preflight unavailable | `BLOCK` |
| stale JSONL export presented as authority | `BLOCK` |
| invalid or legacy `project_id` enters queue/runtime path | `BLOCK` |
| profile / skill / plugin tries to escalate sandbox / approval / network | `BLOCK` |
| wrapper recursion used for native Codex orchestration | `BLOCK` |

## Review Checklist For New Integrations

Before adding any new plugin or MCP row:

1. confirm provenance and transport
2. identify token source and auth scope
3. classify read/write/side-effect capability
4. verify it cannot bypass repo sandbox / approval policy
5. assign `ALLOW/WARN/BLOCK` for each failure mode
6. decide whether the surface is repo authority or optional tooling
7. reject the integration if any item is unknown
