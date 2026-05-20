---
name: codex-app-server-product-integration
description: Use when designing or updating an agent-enabled local app, GUI, Mac app, IDE-like client, image-generation GUI, personal agent, code-review app, or any product that should drive Codex through codex app-server, JSON-RPC/JSONL, approval loops, streaming events, or ChatGPT subscription-backed local Codex auth.
---

# Codex App Server Product Integration

Use this skill before choosing SDK, direct API, `codex exec`, wrapper automation, or Claude Code plugin integration for an agent-enabled application.

## Decision Rule

- Choose `codex app-server` first for local apps that need a long-lived Codex agent, bidirectional streaming, multi-turn state, approval round-trips, file/shell/image/search/MCP tool access, or a GUI over Codex.
- Choose `scripts/codex-wrapper.sh --role ...` or `codex exec` for deterministic one-shot harness automation, CI, cron, release-gate checks, or reviewer/coder calls.
- Choose the OpenAI SDK or API when the application server owns auth, billing, typed API calls, or non-Codex product behavior.
- Choose OpenAI `codex-plugin-cc` when Claude Code is the operator UI and the user wants official Claude Code -> Codex review/delegation UX.

## Transport Defaults

- Prefer `stdio://` for embedded local clients. It is the default `codex app-server` transport and uses newline-delimited JSON.
- Treat `ws://IP:PORT` as experimental. Use loopback only unless a reviewed design adds WebSocket auth and network exposure controls.
- For WebSocket, require token or signed bearer auth before any non-loopback exposure.
- Do not expose a user's local Codex subscription over an unauthenticated network listener.

## Revharness Boundaries

- App-server is a product integration transport, not acceptance truth.
- Goal/app-server state must not replace ExecPlan, SOW, task lineage ledger, deterministic checks, reviewer LGTM, or completion boundary.
- Subscription-only remains the default: do not introduce API-key dependency for this workflow unless the user explicitly changes the policy.
- Local trust is the security model. The authenticated Codex user is the local machine user behind `codex login`.
- Shell/file write capability must be surfaced in the product UX with explicit trust and approval boundaries.

## Minimal Checks Before Implementation

```bash
codex app-server --help
rg -n "OpenAI Codex App Server|OpenAI Codex Plugin for Claude Code" docs/official-docs-links.md
```

For Revharness behavior changes, route through `harness-official-docs-update` and record official docs consulted, local authority mapping, and deterministic checks before review.
