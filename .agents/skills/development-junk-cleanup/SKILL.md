---
name: development-junk-cleanup
description: Use when the user asks to clean, prune, archive, inspect, or reduce development junk, stale harness artifacts, temporary run directories, or Codex/Codex MCP helper residue in Revharness. Routes to existing janitor, artifact-pruner, and MCP cleanup scripts with read-only defaults and no delete path.
---

# Development Junk Cleanup

Use this skill for periodic harness hygiene when the task is about stale `.Codex/tmp/**` artifacts, old run directories, local cleanup candidates, or MCP helper residue.

## Contract

- Default action: inspect.
- This workflow never deletes files.
- Prefer read-only inventory, report, or dry-run commands first.
- Do not create a new cleanup engine for this workflow.
- Do not move release, lineage, acceptance, archive, source, test, docs, registry, or project identity authority.
- Treat cleanup output as hygiene evidence only. It is not acceptance, release readiness, reviewer validity, or completion evidence.

## Command Routing

Use the existing dispatcher first:

```bash
bash scripts/rev-harness-janitor.sh inspect --root .Codex/tmp --json
bash scripts/rev-harness-janitor.sh plan --root .Codex/tmp --json
```

For active run artifacts, use the existing pruner in dry-run mode:

```bash
bash scripts/harness-active-artifact-pruner.sh --root .Codex/tmp/harness-release-gate --keep-latest 20 --max-age-days 14 --json
```

For MCP helper residue, report first:

```bash
bash scripts/cleanup-codex-mcp-zombies.sh report --include-semantic
```

## Escalation Rules

- `archive` remains report-only through `scripts/rev-harness-janitor.sh` in this slice.
- Live movement with `scripts/harness-active-artifact-pruner.sh --execute` requires a separate reviewed plan and explicit archive directory under the selected `.Codex/tmp` root.
- MCP live cleanup requires the existing script's explicit PID/age guards and a separate user/operator decision.
- If any root is outside repo-local `.Codex/tmp`, is a symlink, is missing, or is ambiguous, stop and report `BLOCK`.
- If a candidate is git-tracked or referenced by active state, latest pointer, pinned baseline, release evidence, or lineage evidence, do not move it.

## Verification

Before reporting the workflow as ready or reviewed, run the relevant subset:

```bash
bash -n scripts/rev-harness-janitor.sh scripts/harness-active-artifact-pruner.sh scripts/cleanup-codex-mcp-zombies.sh
bash test/integration/rev_harness_janitor_test.sh
bash test/integration/harness_active_artifact_pruner_test.sh
bash test/integration/codex_mcp_zombie_cleanup_contract_test.sh
```

For skill edits, also run:

```bash
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .Codex/skills/development-junk-cleanup
```
