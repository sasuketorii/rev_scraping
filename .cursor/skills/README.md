# Cursor Skills

This directory is reserved for Cursor's canonical project-level Agent Skills
discovery path.

RevHarness currently keeps the skill source projections in:

- `.agents/skills/` for the cross-platform project-level path.
- `.claude/skills/` for Claude Code and Cursor legacy compatibility.

Those provider directories contain the active `SKILL.md` files and must remain
in parity. If a skill is added directly under `.cursor/skills/`, keep provider
parity with `.agents/skills/` and preserve Cursor-compatible frontmatter:
`name:` and `description:`.
