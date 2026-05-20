# Runtime / Toolchain Reference

## Baseline

- Production: Node.js latest LTS.
- Compatibility: Node.js latest Current in CI.
- Language: TypeScript latest stable.
- Package manager: pnpm, explicitly pinned via `packageManager`.

## Snapshot decisions

| Item | Version | Decision |
|---|---:|---|
| Node.js LTS | v24.15.0 | production baseline |
| Node.js Current | v26.0.0 | CI matrix only |
| TypeScript | v6.0.3 | Core |
| TypeScript 7.0 Beta | beta | R&D only |
| pnpm | v11.0.6 | Node 24+ Core |
| pnpm 10 | v10.33.3 | Hold only for legacy Node |
| @types/node@24 | v24.12.2 | production Node 24 typings |
| @types/node | v25.6.0 | Current/type compatibility watch |
| @swc/core | v1.15.33 | Core/Adopt; verify separately from wasm |
| @swc/wasm | v1.15.33 | separate package; do not mix |

## package.json baseline

```json
{
  "type": "module",
  "packageManager": "pnpm@11.0.6",
  "engines": {
    "node": ">=24 <27",
    "pnpm": ">=11 <12"
  }
}
```

## Advanced guidance

- Use `moduleResolution: "Bundler"` for modern web apps where appropriate.
- Use `NodeNext` only when package boundary and Node ESM/CJS behavior require it.
- Put version catalogs in `pnpm-workspace.yaml` for monorepos.
- Use exact pins for production-critical packages; avoid accidental major drift.
