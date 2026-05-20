---
name: harness-official-docs-update
description: Use before changing Revharness behavior that depends on current Codex, OpenAI prompt guidance, Claude Code, subagents, skills, hooks, settings, wrappers, or Goal workflows.
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: Harness Official Docs Update

This skill owns the upstream-documentation intake step for Revharness behavior changes. Use it before planning or editing harness surfaces whose correctness depends on current OpenAI Codex, OpenAI API prompting, or Claude Code behavior.

## Use When

- Updating Codex wrapper, role, model, prompting, Goal, app-server, workflow, or native subagent behavior.
- Updating Claude Code settings, hooks, subagents, skills, permissions, or delegation behavior.
- Simplifying prompts based on GPT-5.5 / Codex / Claude Code guidance.
- Adding or changing a Revharness workflow because an upstream AI coding tool changed.

## Official Sources

Start from `docs/official-docs-links.md`. For Codex / Claude Code surfaces, prefer these official source families:

- OpenAI Codex changelog, workflows, prompting, and app-server docs.
- OpenAI prompt guidance for model/prompt updates.
- Claude Code subagents, settings, hooks, and current subagent reference docs.

Record which pages were consulted in the plan, SOW, or research handoff. If current official docs are unavailable, record the failure and do not claim the update is official-docs-backed.

## Local Authority Mapping

Official upstream guidance is input, not Revharness truth. After reading the official source, map the change into the local authority layer:

- runtime wrapper behavior: `scripts/*wrapper*.sh` and the relevant skill / role docs
- durable task contract: `docs/manual/common-task-contract.md`
- acceptance / LGTM / completion: `docs/manual/verification-truth-matrix.md`
- role boundaries: `docs/roles/*.md`
- workflow routing: `.claude/skills/*.md`

Do not let an upstream recommendation silently override local sandbox, approval, wrapper, task-lineage, evidence, or acceptance rules.

## Goal / Contract Envelope Boundary

- Codex Goal is optional runtime steering or transport only.
- Goal is not a task contract, evidence store, LGTM condition, completion authority, or acceptance truth.
- Non-interactive automation must not inject `/goal` slash commands into stdin.
- If Codex app-server Goal transport is added later, it must be explicit opt-in, set the Goal before the run, clear it after the run, and fail closed when unavailable.
- Durable Revharness artifacts must continue to carry task lineage, slice id, required checks, evidence destination, completion boundary, and review evidence.

## Output

For each update, leave a concise handoff:

- official docs consulted
- upstream behavior or recommendation
- local Revharness authority files affected
- boundaries that were not changed
- deterministic checks required before review
