# RustSkills Skill Packaging

- **Document ID**: `rustskills-skill-packaging`
- **Status**: durable repo packaging policy
- **Last updated**: 2026-04-30 JST

## Decision

RustSkills skill content remains self-contained under the skill bundle:

- canonical source: `.agent/skills/rustskills-architecture`
- Claude projection: `.claude/skills/rustskills-architecture`
- generated Codex projection: `.agent/generated/skills/codex/rustskills-architecture`
- installed Codex projection: `${CODEX_HOME:-$HOME/.codex}/skills/rustskills-architecture`

The canonical source is projected byte-for-byte to every provider/runtime target named above.

## Why References Stay In The Skill

`references/rustskills_master.md`, `references/rustskills_sources.md`, `references/rustskills_update_prompt.md`, and `references/rustskills_pack_audit_2026-04-29.md` are intentionally packaged with the skill.

Reasons:

- Installed Codex skills must work outside this repository.
- Claude and Codex projections are checked byte-for-byte.
- The projection manifest currently models skill-tree parity, not external docs dependencies.
- Source traceability and update workflows are part of what the RustSkills skill may need during maintenance tasks.

The large master/source/update/audit files are not loaded by default. `SKILL.md` points routine work to narrow lane references, and `references/packaging_navigation.md` explains when to load maintenance files.

## What Belongs In Docs

Repo-operational placement policy belongs here in `docs/rustskills/`.

This docs file is the durable place for:

- why the skill is self-contained
- why root skill `README.md` and `AGENTS.md` are not allowed
- why detailed maintenance materials remain in `references/`
- how byte-for-byte projection parity is verified

This docs file is not part of the installed skill payload and must not be required for ordinary RustSkills use.

## Root Skill Directory Contract

The root of `rustskills-architecture` may contain only loader-supported entries:

- `SKILL.md`
- `agents/`
- `assets/`
- `references/`
- `scripts/`

Do not add root `README.md`, `AGENTS.md`, changelog, installation guide, or other auxiliary root docs to the skill bundle. Put repo-operational docs under `docs/rustskills/` and skill-use details under `references/`.

## Required Verification

Run the RustSkills projection checks after any canonical skill edit:

```bash
jq empty .agent/registry/skill_projection_manifest.json
bash -n scripts/rev-harness-skill-projection.sh test/integration/rev_harness_skill_projection_test.sh
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .agent/skills/rustskills-architecture
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .claude/skills/rustskills-architecture
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .agent/generated/skills/codex/rustskills-architecture
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py "${CODEX_HOME:-$HOME/.codex}/skills/rustskills-architecture"
bash scripts/rev-harness-skill-projection.sh --check --json
bash test/integration/rev_harness_skill_projection_test.sh
diff -qr .agent/skills/rustskills-architecture .claude/skills/rustskills-architecture
diff -qr .agent/skills/rustskills-architecture .agent/generated/skills/codex/rustskills-architecture
diff -qr .agent/skills/rustskills-architecture "${CODEX_HOME:-$HOME/.codex}/skills/rustskills-architecture"
test ! -e rustskills
git diff --check
```
