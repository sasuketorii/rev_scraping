---
name: cursor-caller
description: 'Call Cursor CLI (binary `agent`) through the canonical RevHarness wrapper. Use when the task is light/medium and Codex-grade reasoning is overkill, or when the user explicitly asks for Cursor. Triggers include "cursor で" / "cursor agent で" / "ask モードで調べて" / "yolo で全自動". Three roles align to Cursor official mode terminology: `ask` (true read-only via --mode ask), `agent` (default write-capable agent mode), `yolo` (agent + --force command auto-approval). Cross-family delegation invariant: always invoke through `scripts/cursor-wrapper.sh`; never call `agent` directly. Safety note: per Cursor official docs, `agent -p` (default mode) has write/shell access; only `--mode ask` is a guaranteed read-only path.'
---

# Cursor Caller

This skill is a **selection hint (lens)**, not a workflow owner. Cursor is RevHarness's third orchestration target alongside Claude Code and Codex.

## Safety model (read this first)

Per Cursor's official docs (`https://cursor.com/docs/cli/reference/parameters`):

- `agent -p` (default agent mode) **has access to all tools, including write and shell**. It is not proposal-only.
- `--force` / `--yolo` **auto-approve commands**. They are NOT a file-write gate.
- `--mode ask` is Cursor's documented **true read-only** mode.

The wrapper exposes 3 roles that align with these semantics. The naming intentionally avoids words like "composer" or "proposal-only" because those would misrepresent what the underlying CLI does.

## Roles

| Role | wrapper passes to `agent` | Effective behavior |
|---|---|---|
| `ask` (default) | `-p --output-format text --mode ask` | True read-only. No file writes. No shell execution. |
| `agent` | `-p --output-format text` | Default agent mode. Write + shell tool access. Cursor still prompts per command (no `--force`). |
| `yolo` | `-p --output-format text --force` | Write + shell + command auto-approval. Maximum automation, minimum safety. CI / mechanical execution only. |

`ask` is default because it is the only role that gives a hard read-only guarantee. If you want writes, opt in explicitly.

## When to pick Cursor over Codex

| Scenario | Pick Cursor | Pick Codex |
|---|---|---|
| Repo Q&A / "explain this file" / search-style | ask | (research) |
| Single-function rewrite < 50 LOC, no security concerns, no deterministic-check requirement | agent | — |
| Single-function rewrite where Reviewer LGTM / deterministic checks are needed | — | coder + production-function-implementer |
| Mechanical bulk transform (CI-driven, well-scoped) | yolo | — |
| Production function with input validation, error handling, tests | — | high-coder + production-function-implementer |
| Security-sensitive surface | — | high-coder |
| Code review with verdict | — | reviewer + staff-code-reviewer |

Rule of thumb: if you want a hard read-only guarantee, use `ask`. If you want Codex-grade contract compliance (envelope schemas, deterministic verification), use Codex.

## How to invoke

Canonical entrypoint: `scripts/cursor-wrapper.sh`. Direct `agent` invocation is forbidden under RevHarness governance.

### Read-only (default)

```bash
cat prompt.md | ./scripts/cursor-wrapper.sh --role ask --stdin > answer.md
```

The wrapper appends `--mode ask` to the agent argv; Cursor will not modify files.

### Standard agent (writes allowed)

```bash
cat prompt.md | ./scripts/cursor-wrapper.sh --role agent --stdin > output.md
```

No `--mode` flag is passed. Cursor runs in default agent mode and will prompt before potentially destructive commands.

### Full automation (command auto-approval)

```bash
cat prompt.md | ./scripts/cursor-wrapper.sh --role yolo --stdin > output.md
```

`--force` is passed. Commands run without per-command approval. Use only in CI or mechanical workflows where you accept the risk.

### Dry-run (0-cost validation)

```bash
./scripts/cursor-wrapper.sh --role ask --dry-run
```

Resolves role, emits the delegation metric, but does not invoke `agent`.

## Delegation metric (JSONL on stderr)

```
REV_HARNESS_DELEGATION_METRIC {"schema_version":1,"vendor":"cursor","wrapper_role":"cursor-ask",...,"cursor_mode":"ask","cursor_force_flag":""}
```

Cursor-specific fields:
- `vendor`: `"cursor"` (distinguishes from Codex/Claude metrics)
- `cursor_mode`: `"ask"` for read-only role, empty otherwise
- `cursor_force_flag`: `"--force"` for `yolo` role, empty otherwise

**Important**: `cursor_force_flag` records **command approval behavior** (auto-approve), not file-write permission. File writes are gated by `cursor_mode == "ask"` only.

## Fail-closed conditions

- `agent` binary not found at `$HOME/.local/bin/agent`, `/usr/local/bin/agent`, or `PATH`.
- Unknown role (`ask | agent | yolo` only).
- `--role` specified more than once (role escape rejected).
- `--stdin` omitted on non-dry-run invocation.
- Vendoring guard trip from non-canonical root.

## What this skill is NOT for

- Heavy implementation with RevHarness role contracts → Codex coder/high-coder/reviewer
- Reviewer LGTM gate → `scripts/codex-wrapper.sh --role reviewer` (Codex 固定)
- Anything requiring specialty manifests (production-function-implementer, staff-code-reviewer, etc.) — Cursor wrapper does not implement the specialty system in round 2.

## Pointers

- Wrapper source: `scripts/cursor-wrapper.sh`
- Tests: `test/unit/test-cursor-wrapper.sh` (24 passed, includes argv assertions + signal trap + vendoring guard regression)
- Fake fixture: `test/fixtures/fake-cursor/agent`
- Cursor official docs (always primary source of truth):
  - https://cursor.com/cli
  - https://cursor.com/docs/cli/overview
  - https://cursor.com/docs/cli/installation
  - https://cursor.com/docs/cli/headless
  - https://cursor.com/docs/cli/reference/parameters (the one that defines flag semantics)
- Auth: handled by the user out-of-band (`agent login` interactive).
