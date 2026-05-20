# Testing / Release Quality Reference

## Core tools

| Tool | Version | Role |
|---|---:|---|
| vitest | v4.1.5 | unit/integration test |
| playwright / @playwright/test | v1.59.1 | browser/E2E test |
| happy-dom | v20.9.0 | fast DOM test environment |
| msw | v2.14.3 | API mocking |
| tinybench | v6.0.1 | benchmark |
| tsd | v0.33.0 | type-level tests |
| publint | v0.3.18 | package publishing lint |
| @arethetypeswrong/cli | v0.18.2 | package type compatibility |
| knip | v6.11.0 | unused files/deps/exports |
| web-vitals | v5.2.0 | real-user frontend metrics |

## Required for libraries

```bash
pnpm exec tsd
pnpm exec publint
pnpm exec attw --pack .
```

## Required for apps

```bash
pnpm typecheck
pnpm lint
pnpm test
pnpm test:e2e
pnpm exec playwright test
```

## Rules

- TypeScript libraries need type tests, not only runtime tests.
- ESM/CJS/package exports must be linted before publish.
- Browser-heavy apps need Playwright, not only jsdom/happy-dom.
- Web Builder UI must have interaction tests and visual regression checks.
