# TypeScriptSkills Pack Audit v0.1.2

- **Date**: 2026-05-06 JST
- **Scope**: Master-first structure normalization and same-day registry recheck.
- **Result**: `v0.1.2` keeps the `v0.1.1-strict` governance model, makes `typescript-skills-master.md` the explicit source of truth, and moves strict audit deltas into history so they do not read as unexplained current instructions.

## Corrections

1. Declared `typescript-skills-master.md` as the single source of truth in `README.md`, `SKILL.md`, `AGENTS.md`, and `typescript-skills-master.md`.
2. Clarified that `SKILL.md` is a compact agent entrypoint and must not be treated as the complete version register.
3. Added `Registry check: 2026-05-06 JST late recheck via npm registry`.
4. Updated active version register entries from the late recheck:
   - `undici`: v8.2.0
   - `undici-types`: v8.2.0
   - `@swc/core`: v1.15.33
   - `@swc/wasm`: v1.15.33
   - `pnpm` npm `latest`: v10.33.3
   - `pnpm` npm `latest-11`: v11.0.6
   - `@types/node` latest: v25.6.0
   - `@types/node@24`: v24.12.2
5. Reworded `undici` / `undici-types` and `@swc/core` / `@swc/wasm` traps so equal current versions do not erase the package-boundary warning.

## Remaining policy

- Use latest stable by default.
- Keep prerelease, canary, next, and experimental packages in R&D lanes.
- Match `@types/node` to the production Node major.
- Pin `packageManager` explicitly; do not blindly follow npm `latest` when the official pnpm line differs.
- For real projects, confirm with lockfile, typecheck, lint, tests, E2E, audit, package-quality checks, and bundle/bench evidence.
