# TypeScriptSkills Source Index

- **Version**: `v0.1.2`
- **Snapshot date**: 2026-05-06 JST
- **Registry check**: 2026-05-06 JST late recheck via npm registry
- **Rule**: 公式ドキュメント、npm registry、GitHub releases、security advisoryを優先する。非公式記事は補助に限定する。

## Runtime / language / package manager

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-NODE-RELEASES | Node.js Releases | https://nodejs.org/ja/about/previous-releases | LTS/Current release policy |
| SRC-NODE-24 | Node.js v24.15.0 archive | https://nodejs.org/ja/download/archive/v24.15.0 | production latest LTS snapshot |
| SRC-NODE-26 | Node.js v26.0.0 archive | https://nodejs.org/ja/download/archive/v26.0.0 | Current compatibility snapshot |
| SRC-NPM-TYPESCRIPT | npm: typescript | https://www.npmjs.com/package/typescript | compiler latest stable |
| SRC-TS-7-BETA | TypeScript 7.0 Beta blog | https://devblogs.microsoft.com/typescript/announcing-typescript-7-beta/ | beta, not stable |
| SRC-BUN | Bun official | https://bun.com/ | alternate runtime version |
| SRC-DENO | Deno official | https://deno.com/ | alternate runtime version |
| SRC-PNPM-11 | pnpm 11 release | https://pnpm.io/blog/releases/11.0 | pnpm v11 stable and security defaults |
| SRC-PNPM-INSTALL | pnpm installation | https://pnpm.io/next/installation | PNPM_VERSION and Node requirement |
| SRC-PNPM-GITHUB | pnpm GitHub releases | https://github.com/pnpm/pnpm/releases | patch release details |
| SRC-NPM-PNPM | npm: pnpm | https://www.npmjs.com/package/pnpm | registry dist-tag watch |
| SRC-NPM-TYPES-NODE | npm: @types/node | https://www.npmjs.com/package/@types/node | Node typings latest |
| SRC-NPMX-TYPES-NODE | npmx: @types/node versions | https://npmx.dev/package/%40types/node/versions | runtime-major tags e.g. 24.x/25.x |

## Build / lint / test

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-NPM-VITE | npm: vite | https://www.npmjs.com/package/vite | Vite latest stable |
| SRC-VITE-RELEASE | Vite releases | https://vite.dev/blog/announcing-vite8 | stable major check |
| SRC-NPM-ESBUILD | npm: esbuild | https://www.npmjs.com/package/esbuild | bundler/minifier |
| SRC-NPM-SWC-CORE | npm: @swc/core | https://www.npmjs.com/package/@swc/core | SWC core latest; do not confuse with wasm |
| SRC-NPM-SWC-WASM | npm: @swc/wasm | https://www.npmjs.com/package/@swc/wasm | SWC wasm latest; separate package |
| SRC-NPM-BIOME | npm: @biomejs/biome | https://www.npmjs.com/package/@biomejs/biome | linter/formatter |
| SRC-NPM-VITEST | npm: vitest | https://www.npmjs.com/package/vitest | test runner |
| SRC-NPM-PLAYWRIGHT | npm: playwright | https://www.npmjs.com/package/playwright | browser automation |
| SRC-NPM-HAPPY-DOM | npm: happy-dom | https://www.npmjs.com/package/happy-dom | DOM test environment |
| SRC-NPM-WEB-VITALS | npm: web-vitals | https://www.npmjs.com/package/web-vitals | frontend performance metrics |
| SRC-NPM-TSD | npm: tsd | https://www.npmjs.com/package/tsd | public type tests |
| SRC-NPM-PUBLINT | npm: publint | https://www.npmjs.com/package/publint | package publishing lint |
| SRC-PUBLINT-DOCS | publint docs | https://publint.dev/docs/ | package lint usage |
| SRC-NPM-ATTW | npm: @arethetypeswrong/cli | https://www.npmjs.com/package/@arethetypeswrong/cli | package types compatibility |
| SRC-NPM-NCU | npm: npm-check-updates | https://www.npmjs.com/package/npm-check-updates | update planning |

## Frontend / fullstack / builder

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-NPM-REACT | npm: react | https://www.npmjs.com/package/react | React latest stable |
| SRC-REACT-VERSIONS | React versions | https://react.dev/versions | official React release line |
| SRC-NPM-NEXT | npm: next | https://www.npmjs.com/package/next | Next.js latest stable |
| SRC-NEXT-BLOG | Next.js blog | https://nextjs.org/blog | release notes |
| SRC-NPM-REACT-ROUTER | npm: react-router | https://www.npmjs.com/package/react-router | routing/framework |
| SRC-NPM-TANSTACK-QUERY | npm: @tanstack/react-query | https://www.npmjs.com/package/@tanstack/react-query | server state |
| SRC-NPM-TANSTACK-ROUTER | npm: @tanstack/react-router | https://www.npmjs.com/package/@tanstack/react-router | typed routing |
| SRC-NPM-TAILWIND | npm: tailwindcss | https://www.npmjs.com/package/tailwindcss | CSS utility framework |
| SRC-NPM-YJS | npm: yjs | https://www.npmjs.com/package/yjs | CRDT collaboration |
| SRC-NPM-LIVEBLOCKS | npm: @liveblocks/client | https://www.npmjs.com/package/@liveblocks/client | collaboration |
| SRC-NPM-TLDRAW | npm: tldraw | https://www.npmjs.com/package/tldraw | canvas editor |
| SRC-NPM-LEXICAL | npm: lexical | https://www.npmjs.com/package/lexical | rich text editor |
| SRC-NPM-DND-KIT | npm: @dnd-kit/core | https://www.npmjs.com/package/@dnd-kit/core | drag/drop |
| SRC-NPM-FLOATING-UI | npm: @floating-ui/react | https://www.npmjs.com/package/@floating-ui/react | positioning |
| SRC-NPM-RADIX | npm: @radix-ui/react-dialog | https://www.npmjs.com/package/@radix-ui/react-dialog | UI primitive representative |

## API / crawler / edge

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-NPM-HONO | npm: hono | https://www.npmjs.com/package/hono | API/edge framework |
| SRC-NPM-FASTIFY | npm: fastify | https://www.npmjs.com/package/fastify | Node API framework |
| SRC-NPM-UNDICI | npm: undici | https://www.npmjs.com/package/undici | Node HTTP client |
| SRC-NPM-UNDICI-TYPES | npm: undici-types | https://www.npmjs.com/package/undici-types | separate type package |
| SRC-UNDICI-DOCS | Undici docs | https://undici.nodejs.org/ | Node HTTP client docs |
| SRC-NPM-TRPC | npm: @trpc/server | https://www.npmjs.com/package/@trpc/server | typed RPC |
| SRC-NPM-CHEERIO | npm: cheerio | https://www.npmjs.com/package/cheerio | static HTML parse |
| SRC-NPM-PARSE5 | npm: parse5 | https://www.npmjs.com/package/parse5 | HTML parser |
| SRC-NPM-CRAWLEE | npm: crawlee | https://www.npmjs.com/package/crawlee | crawler framework |
| SRC-NPM-P-LIMIT | npm: p-limit | https://www.npmjs.com/package/p-limit | concurrency limit |
| SRC-NPM-P-QUEUE | npm: p-queue | https://www.npmjs.com/package/p-queue | queue/backpressure |
| SRC-NPM-BOTTLENECK | npm: bottleneck | https://www.npmjs.com/package/bottleneck | rate limiter |
| SRC-NPM-WRANGLER | npm: wrangler | https://www.npmjs.com/package/wrangler | Cloudflare Workers CLI |
| SRC-CF-WRANGLER | Cloudflare Wrangler docs | https://developers.cloudflare.com/workers/wrangler/ | official Workers CLI docs |
| SRC-NPM-MINIFLARE | npm: miniflare | https://www.npmjs.com/package/miniflare | Workers local simulator |
| SRC-CF-MINIFLARE | Cloudflare Miniflare docs | https://developers.cloudflare.com/workers/testing/miniflare/ | official simulator docs |

## AI / OpenAI / MCP

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-OPENAI-LIBRARIES | OpenAI API libraries | https://developers.openai.com/api/docs/libraries | official SDKs and Agents SDK |
| SRC-OPENAI-QUICKSTART | OpenAI Developer quickstart | https://developers.openai.com/api/docs/quickstart | official TS/JS SDK install |
| SRC-OPENAI-AGENTS | OpenAI Agents SDK guide | https://developers.openai.com/api/docs/guides/agents | official Agents SDK overview |
| SRC-OPENAI-AGENTS-QUICKSTART | OpenAI Agents quickstart | https://developers.openai.com/api/docs/guides/agents/quickstart | `@openai/agents` install/examples |
| SRC-NPM-OPENAI | npm: openai | https://www.npmjs.com/package/openai | official OpenAI API client |
| SRC-NPM-OPENAI-AGENTS | npm: @openai/agents | https://www.npmjs.com/package/@openai/agents | OpenAI Agents SDK TS |
| SRC-NPM-AI | npm: ai | https://www.npmjs.com/package/ai | Vercel AI SDK |
| SRC-NPM-LANGGRAPH | npm: @langchain/langgraph | https://www.npmjs.com/package/@langchain/langgraph | graph agents |
| SRC-NPM-MCP | npm: @modelcontextprotocol/sdk | https://www.npmjs.com/package/@modelcontextprotocol/sdk | MCP SDK |

## Security / data / observability / governance

| ID | Title | URL | Function / reason |
|---|---|---|---|
| SRC-NPM-JOSE | npm: jose | https://www.npmjs.com/package/jose | JOSE/JWT/JWE/JWS |
| SRC-NPM-NOBLE-CURVES | npm: @noble/curves | https://www.npmjs.com/package/@noble/curves | ECC primitives |
| SRC-NPM-HPKE-CORE | npm: @hpke/core | https://www.npmjs.com/package/@hpke/core | HPKE family |
| SRC-NPM-DRIZZLE | npm: drizzle-orm | https://www.npmjs.com/package/drizzle-orm | SQL toolkit |
| SRC-NPM-KYSELY | npm: kysely | https://www.npmjs.com/package/kysely | SQL query builder |
| SRC-NPM-BULLMQ | npm: bullmq | https://www.npmjs.com/package/bullmq | job queue |
| SRC-NPM-QDRANT | npm: @qdrant/js-client-rest | https://www.npmjs.com/package/@qdrant/js-client-rest | vector search client |
| SRC-NPM-LANCEDB | npm: @lancedb/lancedb | https://www.npmjs.com/package/@lancedb/lancedb | vector DB |
| SRC-NPM-PINO | npm: pino | https://www.npmjs.com/package/pino | logging |
| SRC-NPM-OTEL | npm: @opentelemetry/sdk-node | https://www.npmjs.com/package/@opentelemetry/sdk-node | tracing |
| SRC-NPM-OSV | OSV-Scanner | https://google.github.io/osv-scanner/ | advisory scanner |
| SRC-PNPM-AUDIT | pnpm audit | https://pnpm.io/cli/audit | dependency advisory check |
| SRC-NPM-AUDIT | npm audit docs | https://docs.npmjs.com/auditing-package-dependencies-for-security-vulnerabilities/ | security audit |
| SRC-RENOVATE-NPM | Renovate npm manager | https://docs.renovatebot.com/modules/manager/npm/ | dependency automation |
| SRC-NPM-PROVENANCE | npm provenance docs | https://docs.npmjs.com/generating-provenance-statements | trusted publishing/provenance |

## Known correction watchlist

| Issue | Correct handling |
|---|---|
| `undici` vs `undici-types` | Keep as separate source rows; never copy type package version to runtime package, even when versions currently match |
| `@swc/core` vs `@swc/wasm` | Verify exact scoped package independently, even when versions currently match |
| pnpm 11 vs npm latest dist-tag | Use official releases/installation for v11, but watch npm dist-tag and Node engine; npm `latest` can point to v10 while `latest-11` points to v11 |
| `@types/node` | Use runtime-major version, not blind latest |
| pre/rc/canary | Never mark as Core stable |
