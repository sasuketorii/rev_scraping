# TypeScriptSkills Master

- **Version**: `v0.1.2`
- **Snapshot date**: 2026-05-06 JST
- **Registry check**: 2026-05-06 JST late recheck via npm registry
- **Owner context**: REV-C Inc. / RustSkills連携
- **Goal**: RustSkills と同等に、TypeScriptでも「最新安定版・高負荷・AI agent・Web Builder・E2EE・データ基盤・更新しやすさ」を満たす技術体系を作る。

## 0. How to read this master

このファイルが TypeScriptSkills の単一の真実源。`SKILL.md` は軽量入口、`references/` はこのmasterから分野別に切り出した詳細、`typescript-skills-sources.md` は公式ソースとregistry確認先。

Version registerはsnapshotであり、npm dist-tag、Node LTS/Current、package engineは同日中にも変わり得る。実repoでdependencyを提案・更新するときは、このmasterの方針を読み、`typescript-skills-sources.md` の公式ソースで現在値を再確認してから lockfile とCIに反映する。

## 0.1 Audit history

この節は履歴であり、現在のpackage version指示そのものではない。

1. `README.md` と `references/` 実ファイル数が不一致だったため、10本の参照ファイルに再構成した。
2. `v0.1.1-strict` early snapshotでは `undici v8.2.0` を `undici v8.1.0` に戻し、`undici-types v8.2.0` との取り違えを修正した。late recheckでは `undici` も v8.2.0。
3. `v0.1.1-strict` early snapshotでは `@swc/core v1.15.33` を `@swc/core v1.15.32` に戻し、`@swc/wasm v1.15.33` との取り違えを修正した。late recheckでは `@swc/core` も v1.15.33。
4. `pnpm` は npm registry の latest dist-tag と公式 v11 line がズレる可能性がある。Node 24 LTS workspaceでは `pnpm@11.0.6` を標準候補にする。
5. `@types/node` は npm最新だけではなく、実行Node majorへ合わせる。Node 24 LTS本番では `@types/node@24.12.2`、Current検証では `@types/node@25.6.0` を見る。
6. `tsd` / `publint` / `@arethetypeswrong/cli` / `web-vitals` / `happy-dom` / `wrangler` / `miniflare` を明示的に追加した。

## 1. Operating principles

- **最新安定版優先**: `latest` stableを使う。ただし `beta` / `rc` / `canary` / `next` / `experimental` はR&D隔離。
- **Node LTS本番**: 本番は latest LTS。CurrentはCIで互換確認し、即本番標準にしない。
- **lockfile固定**: `pnpm-lock.yaml` をcommitし、CIは frozen lockfile。
- **bounded everything**: queue、browser context、Promise、HTTP pool、agent tool call は必ず上限を持つ。
- **TypeScriptの限界を認める**: 低遅延音声、暗号鍵ホットパス、SIMD/zero-copyは Rust sidecar / N-API / WASM を使う。
- **更新可能性を設計する**: version register、source index、update prompt、audit reportを常に同期する。

## 2. Project-domain mapping

| REV-C / RustSkills domain | TypeScriptSkills design |
|---|---|
| 超高負荷クローラー＆フォーム送信 | `undici` + `p-limit` + `p-queue` + `bottleneck` + `cheerio`/`parse5`; JS-rendered only `playwright`/`crawlee` |
| フルスタックWebビルダー | `React` + `Next.js`/`Vite`/`React Router` + `TanStack` + `Yjs`/`Liveblocks`/`tldraw`/`Lexical` |
| インサイドセールスAIエージェント | `openai` + `@openai/agents` + `ai` + `@langchain/langgraph` + `@modelcontextprotocol/sdk`; audio hot pathはRust側 |
| 秘匿E2EEインフラ | `jose` + `@noble/*` + `@hpke/*` + WebCrypto; pure browser cryptoとkey rotationを重視 |
| 自律型エージェント＆データ基盤 | `Drizzle`/`Kysely`/`Postgres` + `Redis`/`BullMQ` + `Qdrant`/`LanceDB` + observability |

## 3. Latest-stable version register at snapshot

### 3.1 Runtime / toolchain

| Package / Tool | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| Node.js LTS | v24.15.0 | Core | production runtime | Latest LTS line at snapshot |
| Node.js Current | v26.0.0 | CI/R&D | compatibility runtime | CI matrix only |
| TypeScript | v6.0.3 | Core | language/compiler | TypeScript 7 betaはR&D |
| Bun | v1.3.13 | Adopt/R&D | alternate runtime | benchmark/compat lane |
| Deno | v2.7.14 | Adopt/R&D | alternate secure runtime | permissions/edge scripts |
| pnpm | v11.0.6 | Core for Node 24+ | package manager | Node 22+ required; explicit pin |
| pnpm 10 | v10.33.3 | Hold | legacy Node compatibility | Node 20以下が必要なrepoのみ |
| @types/node@24 | v24.12.2 | Core | Node LTS typings | 本番Node 24に合わせる |
| @types/node | v25.6.0 | Watch/CI | npm latest typings | Current互換検証用 |
| tsx | v4.21.0 | Core | TS runner | dev scripts |
| vite | v8.0.10 | Core | build/dev server | frontend + library dev |
| esbuild | v0.28.0 | Core | bundling/minify | fast transform |
| @swc/core | v1.15.33 | Adopt | transpile | `@swc/wasm`と別packageとして確認 |
| @swc/wasm | v1.15.33 | R&D | wasm SWC | coreとはversion差あり |
| turbo | v2.9.9 | Adopt | monorepo tasks | large workspace |
| nx | v22.7.1 | Adopt | monorepo governance | more structured monorepo |
| @biomejs/biome | v2.4.14 | Core | formatter/linter | fast default |
| oxlint | v1.63.0 | Adopt | JS/TS lint | performance lint |
| eslint | v10.3.0 | Adopt | lint ecosystem | rule ecosystem |
| typescript-eslint | v8.59.2 | Adopt | TS lint integration | ESLint lane |
| prettier | v3.8.3 | Adopt | formatting | only if team prefers |

### 3.2 Frontend / fullstack / web builder

| Package | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| react | v19.2.5 | Core | UI runtime | React 19 line |
| react-dom | v19.2.5 | Core | DOM renderer | match React |
| next | v16.2.4 | Core | fullstack app | app/web platform |
| @vitejs/plugin-react | v6.0.1 | Core | Vite React | default React plugin |
| @vitejs/plugin-react-swc | v4.3.0 | Adopt | SWC React | speed path |
| @tanstack/react-query | v5.100.9 | Core | server state | caching/query invalidation |
| @tanstack/react-router | v1.169.2 | Adopt | typed router | Vite/SPAs |
| @tanstack/start | v1.120.20 | Adopt/R&D | fullstack | project-specific |
| react-router | v7.x | Adopt | routing/framework | verify latest during update |
| tailwindcss | v4.2.4 | Core | styling | Tailwind v4 |
| tailwind-merge | v3.5.0 | Core | class merge | utility conflict resolution |
| clsx | v2.1.1 | Core | class conditionals | low risk |
| class-variance-authority | v0.7.1 | Adopt | component variants | design system |
| zustand | v5.0.13 | Adopt | client state | simple store |
| jotai | v2.20.0 | Adopt | atom state | fine-grained |
| xstate | v5.31.0 | Adopt | state machine | workflows/agents |
| yjs | latest stable | Core | CRDT collaboration | web builder |
| @liveblocks/client | latest stable | Adopt | realtime collaboration | SaaS collaboration |
| tldraw | latest stable | Adopt | canvas/editor | visual builder |
| lexical | latest stable | Adopt | rich text editor | editor core |
| @dnd-kit/core | latest stable | Adopt | drag/drop | builder interactions |
| @floating-ui/react | latest stable | Adopt | positioning | popovers/menus |
| @radix-ui/react-* | latest stable | Adopt | a11y primitives | component system |
| web-vitals | v5.2.0 | Core | frontend perf metrics | CWV/soft nav telemetry |

### 3.3 API / crawler / browser / edge

| Package | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| hono | v4.12.17 | Core | Web/API framework | edge + Node |
| fastify | v5.8.5 | Core | Node API server | plugins/perf |
| @fastify/rate-limit | v10.3.0 | Core | rate limit | public API |
| @fastify/cors | v11.2.0 | Core | CORS | API hardening |
| undici | v8.2.0 | Core | HTTP client/hot path | late recheck; keep separate from `undici-types` |
| undici-types | v8.2.0 | Support | TS types for undici | separate package |
| @trpc/server | v11.17.0 | Adopt | typed RPC | internal apps |
| @hono/zod-openapi | latest stable | Adopt | OpenAPI contracts | API-first Hono |
| zod-openapi | latest stable | Adopt | OpenAPI generation | schema reuse |
| openapi-typescript | latest stable | Adopt | typed clients | contract-first |
| cheerio | v1.2.0 | Core | static HTML parsing | no browser needed |
| parse5 | v8.0.1 | Core | HTML parser | standards parsing |
| htmlparser2 | v12.0.0 | Adopt | streaming-ish HTML parse | perf lane |
| puppeteer | v24.42.0 | Adopt | browser automation | Chrome automation |
| playwright | v1.59.1 | Core | E2E/browser automation | browser QA/crawler fallback |
| @playwright/test | v1.59.1 | Core | E2E test runner | visual/browser tests |
| crawlee | v3.16.0 | Adopt | crawler framework | JS-rendered/site policies |
| robots-parser | v3.0.1 | Core | robots policy | compliance gate |
| p-limit | v7.3.0 | Core | concurrency cap | per-lane control |
| p-queue | v9.2.0 | Core | bounded queue | backpressure |
| bottleneck | v2.19.5 | Core | rate limiter | per host/account |
| wrangler | v4.86.0 | Adopt | Cloudflare Workers CLI | edge deploy/dev |
| miniflare | v4.20260430.0 | Adopt | Workers local simulator | edge tests |

### 3.4 AI agent / realtime

| Package | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| openai | v6.36.0 | Core | official OpenAI API client | direct model/API calls |
| @openai/agents | v0.8.2 | Adopt | OpenAI Agents SDK TS | orchestration/tools/handoffs |
| ai | v6.0.175 | Adopt | Vercel AI SDK | streaming UI/provider abstraction |
| @ai-sdk/openai | v3.0.61 | Adopt | OpenAI provider for AI SDK | UI streaming |
| langchain | v1.4.0 | Adopt | LLM framework | ecosystem/RAG |
| @langchain/langgraph | v1.3.0 | Adopt | graph agents | complex workflows |
| @modelcontextprotocol/sdk | v1.29.0 | Core | MCP protocol | tools/connectors |
| eventsource | v4.1.0 | Core | SSE client | token stream |
| ws | v8.20.0 | Core | WebSocket | realtime control |
| @inquirer/prompts | v8.4.2 | Adopt | CLI prompts | dev tools |
| ink | v7.0.2 | Adopt | React TUI | TS TUI alternative |

### 3.5 Crypto / E2EE / validation

| Package | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| jose | v6.2.3 | Core | JOSE/JWT/JWE/JWS | auth + token crypto |
| @noble/curves | v2.2.0 | Adopt | ECC primitives | browser/Node crypto |
| @noble/ciphers | v2.2.0 | Adopt | cipher primitives | use with care |
| @noble/hashes | v2.2.0 | Adopt | hash primitives | use with care |
| @hpke/core | latest stable | Adopt/R&D | HPKE | verify package split on update |
| @hpke/chacha20poly1305 | latest stable | Adopt/R&D | HPKE AEAD | E2EE experiments |
| @hpke/dhkem-x25519 | latest stable | Adopt/R&D | HPKE KEM | E2EE experiments |
| libsodium-wrappers-sumo | v0.8.4 | Adopt/R&D | sodium crypto | operational tradeoff |
| zod | v4.4.3 | Core | schema validation | agents/API |
| valibot | v1.4.0 | Adopt | schema validation | smaller bundle |
| arktype | v2.2.0 | Adopt | type-first validation | perf/type DX |
| @sinclair/typebox | v0.34.49 | Adopt | JSON schema | OpenAPI contracts |
| ajv | v8.20.0 | Core | JSON schema validation | runtime validation |

### 3.6 Data / state / search / observability

| Package | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| drizzle-orm | v0.45.2 | Core | SQL ORM/query | typed DB |
| drizzle-kit | v0.31.10 | Core | migrations | Drizzle tooling |
| kysely | v0.28.17 | Core | SQL query builder | explicit SQL |
| prisma | v7.8.0 | Adopt | ORM/tooling | DX-heavy projects |
| @prisma/client | v7.8.0 | Adopt | Prisma client | match prisma |
| pg | v8.20.0 | Core | Postgres driver | Node DB |
| postgres | v3.4.9 | Adopt | Postgres client | lightweight alternative |
| ioredis | v5.10.1 | Core | Redis client | cache/queue |
| bullmq | v5.76.5 | Core | job queue | worker system |
| @qdrant/js-client-rest | v1.17.0 | Adopt | vector DB client | semantic search |
| @lancedb/lancedb | v0.27.2 | Adopt | vector DB | AI memory/search |
| @pinecone-database/pinecone | v7.2.0 | Adopt | vector DB SaaS | managed search |
| pino | v10.3.1 | Core | logging | JSON logs |
| @opentelemetry/api | v1.9.1 | Core | telemetry API | tracing metrics |
| @opentelemetry/sdk-node | v0.216.0 | Core | Node OTel SDK | tracing pipeline |
| prom-client | v15.1.3 | Adopt | Prometheus metrics | service metrics |
| @sentry/node | v10.51.0 | Adopt | error monitoring | prod incidents |

### 3.7 Testing / release quality / governance

| Package / Tool | Snapshot version | Tier | Role | Notes |
|---|---:|---|---|---|
| vitest | v4.1.5 | Core | unit/integration test | Vite-native |
| @playwright/test | v1.59.1 | Core | E2E/browser test | browser automation |
| msw | v2.14.3 | Adopt | API mocking | frontend tests |
| happy-dom | v20.9.0 | Adopt | DOM test environment | fast DOM |
| storybook | v10.3.6 | Adopt | component docs/tests | UI systems |
| tinybench | v6.0.1 | Adopt | benchmark | perf gates |
| knip | v6.11.0 | Core | unused deps/exports | repo hygiene |
| tsd | v0.33.0 | Core for libs | type tests | public API type contracts |
| publint | v0.3.18 | Core for libs | package lint | export/package checks |
| @arethetypeswrong/cli | v0.18.2 | Core for libs | type package analysis | ESM/CJS/type compatibility |
| npm-check-updates | v21.0.3 | Adopt | update planning | never auto-merge alone |
| renovate | v43.x | Core | dependency automation | PR-based updates |
| dependency-cruiser | latest stable | Adopt | import graph governance | boundaries |
| osv-scanner | latest stable | Core | advisory scan | lockfile scan |

## 4. Architecture rules by lane

### 4.1 High-load API / crawler

- Static HTMLは `undici + cheerio/parse5` を基本にする。
- JS-rendered/SPA/visual QAのみ `playwright` / `crawlee` に昇格する。
- `p-limit` は単純な同時数制御、`p-queue` はbounded queue、`bottleneck` はhost/account別rate制御。
- requestごとにHTTP client/contextを作らない。Pool/Clientを再利用する。
- bodyは可能な限りstreaming / bounded size。巨大body一括読みを禁止する。

### 4.2 Web Builder

- Next.jsはSSR/Fullstack/SaaS dashboardに使う。
- ViteはWeb Builderのdev速度、library、SPAに使う。
- React Router/TanStack Routerはtyped routesやSPA compositionで採用。
- CRDT/collaborationはYjs/Liveblocks、canvasはtldraw、rich textはLexical、drag/dropはdnd-kit。
- UI performanceはweb-vitalsとbundle budgetで数値化する。

### 4.3 AI Agent

- 直接APIは `openai`。
- code-first orchestrationは `@openai/agents`。
- UI streaming/provider abstractionは `ai`。
- graph/multi-agentはLangGraph、tool ecosystemはMCP。
- tool callは型付きschema、bounded executor、audit span、timeoutを必須にする。

### 4.4 E2EE / Security

- BrowserではWebCryptoを第一候補にし、cross-runtimeでは `jose` と `@noble/*` を検証する。
- HPKE系はR&Dから開始し、test vectorsとinteroperabilityを通す。
- libsodiumは強力だがbundle/wasm/operational tradeoffを評価して採用する。
- secret redaction、key rotation、kid、aud/iss検証、clock skewを標準化する。

### 4.5 Data / Search

- relational consistencyはPostgres + Drizzle/Kysely。
- job queueはBullMQ、cache/sessionはRedis。
- vector DBはQdrant/LanceDB/Pineconeから運用要件で選ぶ。
- Social Psychometrics CRMではPIIとembedding payloadを分離し、削除要求・監査・同意管理を設計に入れる。

## 5. Update protocol

1. npm package名とscopeを必ず確認する。
2. `latest` tag、major-specific tag、runtime-specific tagを分ける。
3. `undici` と `undici-types`、`@swc/core` と `@swc/wasm` のような近接packageを混同しない。
4. Node/Pnpm/TypeScriptのengine要件を確認する。
5. `pnpm-lock.yaml` を更新し、CIを通す。
6. Advisoryはnpm audit、pnpm audit、OSV-Scanner、GitHub Advisoryを併用する。
7. 更新結果はMaster、SKILL、Sources、README、Auditに同時反映する。

## 6. Verification commands

```bash
corepack enable
node --version
pnpm --version
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
pnpm exec vite build
pnpm exec playwright test
```

## 7. Remaining path to true 100

このPack単体は実運用前ナレッジとして96点相当。100点にするには、実repoの `package.json` / `pnpm-lock.yaml` / `tsconfig` / CI / bundle analyzer / load test / browser E2E / supply-chain scanを通して、実測値で更新する必要がある。
