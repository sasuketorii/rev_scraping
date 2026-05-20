# Subscription-Only Codex / Opus Orchestration

## Purpose

This guide defines the Revharness boundary for using the latest Codex and Opus through local subscription-authenticated tools only.

Revharness must not treat subscriptions as an API pool. It treats them as human-owned local product sessions that can be invoked for short-lived work with explicit artifacts and deterministic closeout.

## Subscription-Only Rule

API fallback is forbidden.

The orchestration path must block when these API-key surfaces are present:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `OPENAI_API_KEY`
- `CODEX_API_KEY`
- Claude Code `apiKeyHelper`

`CLAUDE_CODE_OAUTH_TOKEN` is allowed only as Claude Code subscription OAuth generated from a subscription login. If subscription usage is exhausted, the correct result is `BLOCK` or `WAIT`, not API-key fallback, Console credit fallback, or background retry.

The executable preflight is:

```bash
bash scripts/subscription-auth-guard.sh check --provider all --json
```

Wrapper-launched orchestration also enforces this boundary at the runtime entrypoint:

- `scripts/claude-wrapper.sh` runs `subscription-auth-guard.sh check --provider claude` before launching Claude and passes any wrapper `--settings` sources to the guard.
- `scripts/codex-wrapper.sh` runs `subscription-auth-guard.sh check --provider codex` before launching Codex.
- Claude wrapper `--bare` is rejected in subscription-only wrapper mode, regardless of API key or `apiKeyHelper` availability, because it depends on API-key/helper authentication instead of the Claude Code subscription OAuth/keychain path.

These wrapper checks are preflight gates. A blocked run must not invoke the underlying `claude` or `codex` binary.

## Orchestration Shape

Revharness owns the control plane, not the internal conversation graph.

- Codex-to-Codex native subagent work remains inside Codex without recursively calling `scripts/codex-wrapper.sh`.
- Opus-to-Opus native Claude Code delegation remains inside Claude Code without recursively calling `scripts/claude-wrapper.sh`.
- Cross-family Codex / Opus coordination must use artifacts, not direct long-lived chat sessions.

Dual-native policy:
- Claude top-level orchestrator uses Claude Code native subagents / Task-agent teams.
- Codex top-level orchestrator uses Codex native subagents / `.codex/agents/*.toml`.
- Same-family native delegation does not route through wrapper scripts.
- Cross-family work is artifact-packet based and must close leases before acceptance.

This document defines the contract for artifact-based Codex / Opus coordination. Passing `subscription-auth-guard` and `rev-harness-lease-guard` proves that subscription-only auth and lease closeout gates are enforceable; it does not by itself prove that a live Codex process and a live Opus process exchanged a task successfully. `bash test/integration/cross_family_artifact_smoke_test.sh` proves the deterministic artifact-packet and lease-closeout contract. `bash scripts/cross-family-live-smoke-preflight.sh check --json --workspace workspace/<task> --artifact-root .claude/tmp/<task>` is a read-only gate for whether a live smoke may be attempted; it never starts a model process and always keeps `completion_claim_allowed=false`. `bash scripts/cross-family-live-artifact-smoke.sh --json` is the opt-in live artifact smoke: it runs one short-lived Codex worker, one short-lived Opus reviewer, validates packet/lease closeout, and scans for residual workers. It is not default CI because it consumes local subscription-authenticated CLI capacity.

The cross-family handoff unit is a durable artifact packet:

- plan or Contract Envelope pointer
- SOW / task lineage pointer
- question or requested review scope
- required checks
- evidence destination
- completion boundary
- returned verdict or worker outcome

AI-to-AI agreement is never acceptance truth. `LGTM`, `pending acceptance`, and `completed` remain governed by `docs/manual/verification-truth-matrix.md`.

Cross-agent packets should be English by default to reduce token and context overhead. The orchestrator's final report to the user remains Japanese unless the user explicitly requests another language.

## Writable Worker Workspace

`.claude/tmp/**` is an orchestration artifact and state area, not a model-owned implementation workspace.

Claude Code can classify writes under `.claude/**` as sensitive-file writes. In a live Opus implementation smoke, `Write` to `.claude/tmp/...` was denied by the Claude Code permission layer even with `--permission-mode bypassPermissions` and explicit `Write` / `Edit` tools enabled. The same Opus low-effort write succeeded when the implementation target was moved to `workspace/...`.

Use this split:

- `.claude/tmp/<task>/**`: prompts, packets, lease registries, review outputs, stderr pointers, and other orchestration artifacts.
- `workspace/<task>/**`: disposable implementation worktrees or scratch apps owned by delegated implementation workers.

When Opus or another Claude Code worker is assigned implementation work, the prompt must name a non-`.claude` writable target such as `workspace/<task>/...`. The orchestrator may still store the worker prompt, lease registry, and returned report in `.claude/tmp/<task>/...`.

For wrapper-launched Claude / Opus implementation workers, pass `--implementation-workspace workspace/<task>` to `scripts/claude-wrapper.sh`. The wrapper rejects `.claude/**` or non-`workspace/**` implementation workspaces before starting Claude, and injects the workspace boundary into the worker prompt.

Disposable `workspace/<task>` directories are not acceptance truth and must be closed out like any other worker surface: required results copied or referenced from traceable artifacts, leases closed, and the disposable workspace removed when the user requested destruction.

## Lease Registry

Every orchestration worker that Revharness starts or tracks must have a lease record.

The registry schema is:

```json
{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "task-slice-worker-01",
      "provider": "codex",
      "model": "gpt-5.5",
      "purpose": "review",
      "state": "completed",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}
```

Completion is blocked when any lease is `running`, `stale`, `failed`, malformed, missing artifacts, or references an artifact outside the repo.

The executable closeout gate is:

```bash
bash scripts/rev-harness-lease-guard.sh validate --file .claude/tmp/<task>/agent-leases.json --json
```

Allowed closed states:

- `completed`
- `blocked`
- `reaped`

`blocked` is closed only in the lifecycle sense. It still requires a traceable artifact explaining the block and does not imply task acceptance.

## Goal Boundary

Codex Goal workflows may be useful as Codex-specific runtime steering, but they are not the Revharness source of truth.

Goal must not replace:

- task lineage ledger
- SOW
- required deterministic checks
- evidence destination
- reviewer verdict
- `docs/manual/verification-truth-matrix.md`

If a future slice adds Codex app-server Goal transport, it must set the Goal before the run, clear it after the run, and fail closed when clear verification is unavailable. Non-interactive automation must not inject `/goal` slash commands into stdin.

## Closeout Rule

The orchestrator can stop asking a worker only when all of these are true:

- the worker returned a structured artifact;
- open questions are zero or explicitly rerouted;
- required checks are recorded;
- no lease remains `running`, `stale`, `failed`, or malformed;
- every closed lease has at least one traceable artifact;
- subscription-auth guard is clean;
- acceptance state is determined by Revharness gates, not model consensus.
