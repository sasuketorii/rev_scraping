# AGENTS.md

## Purpose

This repository uses TypeScriptSkills v0.1.2 as the architecture and dependency-governance standard for REV-C TypeScript systems.

`typescript-skills-master.md` is the single source of truth. `SKILL.md` is only the compact skill entrypoint; do not treat it as the full version register.

## Hard rules

- Use latest stable packages unless a Hold/R&D reason is explicitly documented.
- Production Node baseline is latest LTS. Current Node is CI compatibility only.
- For Node 24+ workspaces, use `packageManager: "pnpm@11.0.6"` unless there is a documented compatibility blocker.
- For Node 20 or older compatibility, hold pnpm 10 and document why.
- Match `@types/node` to the runtime major. Do not blindly use npm latest in production.
- Never confuse `undici` with `undici-types` or `@swc/core` with `@swc/wasm`.
- Keep `pnpm-lock.yaml` committed.
- Do not introduce unbounded concurrency, unlimited browser contexts, or long-running tool calls without timeout.
- Do not log secrets, tokens, PII, voice payloads, psychological scoring data, or raw keys.

## Required checks

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
pnpm test:e2e
pnpm audit --audit-level high
pnpm dlx osv-scanner scan --lockfile pnpm-lock.yaml
pnpm outdated --recursive
pnpm exec knip
pnpm exec publint
pnpm exec attw --pack .
```

## Dependency updates

When changing dependencies:

1. Verify exact npm package and scope.
2. Check official docs/release notes.
3. Check engine requirements.
4. Check advisory status.
5. Update lockfile.
6. Run all required checks.
7. Update `typescript-skills-sources.md` if the package is part of the standard stack.

## Architecture

Use references in this order:

1. `SKILL.md`
2. `typescript-skills-master.md`
3. `references/*.md`
4. `typescript-skills-sources.md`
5. `typescript-skills-update-prompt.md`
