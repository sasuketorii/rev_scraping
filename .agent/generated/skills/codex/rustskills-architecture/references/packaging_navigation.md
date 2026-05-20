# RustSkills Packaging Navigation

- **Document ID**: `rustskills-packaging-navigation`
- **Version**: `v0.1.0`
- **Snapshot date**: 2026-04-30 JST
- **Purpose**: Keep `SKILL.md` thin while preserving enough local context for Codex and Claude Code skill users to find deeper RustSkills materials only when needed.

---

## Loading Policy

For normal Rust implementation, review, or architecture work:

1. Read `SKILL.md`.
2. Pick one narrow lane reference from the `Lane decision map`.
3. Avoid loading `rustskills_master.md`, `rustskills_sources.md`, `rustskills_update_prompt.md`, and `rustskills_pack_audit_2026-04-29.md` unless the task is about pack maintenance, source traceability, conflict resolution, or dependency/advisory refresh.

For RustSkills pack maintenance:

1. Read this file first.
2. Use the table below to load only the needed maintenance reference.
3. Keep canonical source and projections byte-for-byte identical after any edit.

---

## Maintenance Reference Map

| Need | Load | Notes |
|---|---|---|
| Full conceptual source, historical chapter structure, or deep conflict resolution | `rustskills_master.md` | Large file with a table of contents. Use `rg '^## '` or the TOC before reading broad sections. |
| Source links, crate snapshots, advisory/source traceability, update cadence | `rustskills_sources.md` | Dated snapshot. Verify current facts from primary sources before changing adoption decisions. |
| Web/deep-research refresh prompt for ChatGPT, Claude, or Gemini | `rustskills_update_prompt.md` | Copy-ready prompt and required output format for external research refreshes. |
| Import/audit provenance and known limitations of the pack | `rustskills_pack_audit_2026-04-29.md` | Dated provenance. Do not treat the score or findings as current without revalidation. |
| Observability, dependency update commands, cargo audit/deny/outdated workflow | `observability_update_governance.md` | Use with actual project `Cargo.lock` and benchmark artifacts. |

---

## Docs vs References Placement

The skill bundle stays self-contained:

- Canonical skill source: `.agent/skills/rustskills-architecture`
- Claude projection: `.claude/skills/rustskills-architecture`
- Generated Codex projection: `.agent/generated/skills/codex/rustskills-architecture`
- Installed Codex projection: `${CODEX_HOME:-$HOME/.codex}/skills/rustskills-architecture`

The detailed RustSkills source, source index, update prompt, and audit remain under `references/` because installed Codex skills must be usable outside this repository and projection parity is byte-for-byte.

Repo-operational packaging policy belongs in durable docs. In this repository, see `docs/rustskills/packaging.md` for the stable placement decision and verification contract. That docs file is not part of the installed skill payload and must not be required for ordinary skill use.

---

## Projection Rule

After editing any file in the canonical skill tree, sync the same bytes to:

- `.claude/skills/rustskills-architecture`
- `.agent/generated/skills/codex/rustskills-architecture`
- `${CODEX_HOME:-$HOME/.codex}/skills/rustskills-architecture`

Then run the projection checker and quick validation commands recorded by the Revharness RustSkills placement slice.
