---
name: rev-harness-lifecycle
description: "rev_harness lifecycle: install/verify/repair/status/upgrade/uninstall; triggers: revharness入れて, doctor, repair, status, upgrade inspect. NOT: tmp掃除, packaging, session開始."
metadata:
  version: 1.0.0
  owner: rev_harness
---

# Rev Harness Lifecycle

## When to use
- Install: set up RevHarness in a project with the canonical facade.
- Verify: run the health check when the operator asks whether it works.
- Repair: run the repair path after a broken or partial install.
- Status: inspect current adoption phase and doctor state.
- Upgrade inspect: review upgrade state without applying mutation.
- Uninstall checklist: print the removal checklist; require explicit user intent for destructive apply.

## Trigger phrases
| User phrase | Command |
|---|---|
| `revharness 入れて`, `初回セットアップ`, `enable rev_harness` | `rev-harness install` |
| `doctor 回して`, `動いてる?`, `verify rev_harness` | `rev-harness verify` |
| `壊れた、直して`, `repair rev_harness` | `rev-harness repair` |
| `状態`, `status` | `rev-harness status` |
| `アップグレード見て`, `upgrade inspect` | `rev-harness upgrade inspect` |
| `アンインストール手順`, `uninstall checklist` | `rev-harness uninstall` |

## What NOT to do
- Do NOT use this skill for `.claude/tmp` cleanup; use `development-junk-cleanup`.
- Do NOT use this skill for client packaging or distribution readiness; use `client-distribution-readiness`.
- Do NOT use this skill for session start or orchestrator wake-up; use `orchestrator-bootstrap`.

## Invocation

```bash
bash scripts/rev-harness <subcommand> [options]
```

Use the facade subcommands exactly: `install`, `verify`, `repair`, `status`, `upgrade inspect`, or `uninstall`.
Keep destructive paths dry-run/checklist first unless the user gives a separate explicit apply instruction.
