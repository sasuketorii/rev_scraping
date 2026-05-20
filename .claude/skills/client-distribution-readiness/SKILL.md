---
name: client-distribution-readiness
description: Use before handing Revharness to a client, tagging a clean distribution, or claiming client-ready packaging. Audits stale archive references, local absolute paths, semantic DB regeneration policy, skill projection parity, distribution manifest consistency, and doctor clean-distribution assumptions. Complements development-junk-cleanup; inspect-first and no unattended delete.
---

# Client Distribution Readiness

Use this skill when the task is final client handoff, clean distribution, tag/push readiness, or "did cleanup miss anything?" for Revharness. This is not the daily temporary-file cleanup route; use `development-junk-cleanup` for routine `.claude/tmp/**`, active run artifacts, and MCP residue.

## Contract

- Default to inspect-only. Do not delete, move, or rewrite artifacts unless a reviewed plan explicitly authorizes the exact paths.
- Treat external client distribution as at least `standard`; escalate to `heavy` if release/tag/push, security boundary, wrapper/model policy, semantic authority, or acceptance policy changes are in scope.
- Do not ship historical `.agent/archive/**` plans, SOWs, handovers, disposable workspaces, `.claude/tmp/**`, or semantic DB files as client-facing evidence unless the distribution manifest explicitly allows them.
- Interpret `.agent/registry/rev_harness_distribution_manifest.json` `preserve_globs` as adoption-local preservation only. Client package exclusions must be declared separately under `client_distribution.exclude_globs`.
- Replace local absolute paths with repo-relative paths, `$REVHARNESS_ROOT`, `$CODEX_HOME`, or documented user-local paths.
- Keep semantic DBs out of distribution. The handoff contract must say that semantic state is regenerated on first use through the semantic MCP launcher, doctor, or explicit reindex workflow.
- Ensure skill sync rules cover every shared Claude/Codex skill added by the slice. The active installed Codex projection must match the source when the manifest says `byte-for-byte`.
- Ensure doctor and distribution checks do not require old development logs, old archive contents, or prior local semantic DB state.

## Inspection Runbook

Start with machine-checkable structure:

```bash
jq empty .agent/registry/rev_harness_distribution_manifest.json .agent/registry/skill_projection_manifest.json .agent/registry/skill_routing_matrix.json
bash scripts/rev-harness-skill-routing-check.sh --json
bash scripts/rev-harness-skill-projection.sh --check --json
bash scripts/harness-doctor.sh --quick --json
```

Search for distribution-hostile residue. Review every match manually; an allowed match must explicitly describe a non-shipped path or regeneration rule.

```bash
rg -n '(/U)sers/|(/p)rivate/var/|[.]agent/archive/(plans|sow|handover)|semantic[.]db|[.]claude/tmp|workspace/' \
  AGENTS.md CLAUDE.md docs .agent/registry .claude/skills scripts \
  --glob '!**/target/**'
```

Check distribution policy alignment:

- `.agent/registry/rev_harness_distribution_manifest.json` must preserve current product/source roots for adoption while `client_distribution.exclude_globs` excludes historical/run-local evidence from client packages.
- `docs/manual/harness-user-guide.md` must explain that semantic DBs are not shipped and are regenerated on first use.
- `docs/manual/skill-integration.md` and `.agent/registry/skill_projection_manifest.json` must agree on shared skill sync.
- `scripts/harness-doctor.sh` must be clean-distribution aware and must not fail only because old archive artifacts were pruned.

## Fix Boundaries

- Documentation-only clarification may remain `standard` when it does not change runtime or acceptance policy.
- Adding or changing skill routing, projection manifests, doctor checks, or distribution manifests requires reviewer evidence.
- Any cleanup that removes tracked files must list exact paths, preservation rationale, and rollback expectations before mutation.
- Do not convert this skill into a daemon, scheduler, or autonomous deleter.

## Required Verification

For this skill itself or distribution-readiness routing changes:

```bash
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .claude/skills/client-distribution-readiness
bash scripts/rev-harness-skill-routing-check.sh --json
bash scripts/rev-harness-skill-projection.sh --check --json
bash test/integration/rev_harness_skill_projection_test.sh
bash test/integration/harness_doctor_quick_test.sh
git diff --check
```

Before a real client handoff, also run the current release gate tier required by `docs/manual/verification-truth-matrix.md`.
