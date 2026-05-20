---
name: typescript-skills-architecture
description: TypeScriptSkills / REV-C Inc. systems architecture skill. Use when designing, reviewing, implementing, benchmarking, or updating latest-stable TypeScript, Node.js, Bun, Deno, React/Next/React Router, high-load HTTP, crawler/browser automation, AI agent, E2EE/security, data/search, edge runtime, and dependency-governance systems.
---

# TypeScriptSkills Skill Hub

- **Version**: `v0.1.2`
- **Snapshot date**: 2026-05-06 JST
- **Registry check**: 2026-05-06 JST late recheck via npm registry
- **Generated from**: `typescript-skills-master.md`
- **Target context**: REV-C Inc. / RustSkills連携 / TypeScriptSkills / CCTeam / Social Psychometrics CRM / Web Builder / AI Agent / 高負荷API・Crawler / E2EE / Data Platform

この `SKILL.md` は Codex / Codex / ChatGPT Skills の軽量入口。判断の本体は `typescript-skills-master.md`、根拠URLは `typescript-skills-sources.md`、分野別の詳細は `references/` に置く。

Dependency version、採用レーン、例外、移行判断を出すときは、必ず `typescript-skills-master.md` を先に読む。`SKILL.md` だけで version register を確定しない。

## 1. Non-negotiable rules

- 原則として **latest stable** を採用する。`alpha` / `beta` / `rc` / `canary` / `next` / `experimental` は R&D 隔離。
- 本番 Node は **latest LTS** を標準。Latest Current は CI matrix で検証し、即本番標準にしない。
- Node 24+ workspace では `pnpm@11.0.6` を標準候補にする。Node 20以下互換が必要なrepoでは pnpm 10系を Hold し、理由を書く。
- `@types/node` は npm latest ではなく、実行Node majorに合わせる。本番Node 24なら `@types/node@24` を固定し、Current検証だけ `@types/node` latest を見る。
- `pnpm-lock.yaml` を必ず固定し、CIでは `pnpm install --frozen-lockfile` を使う。
- 外部HTTP、crawler、form sender、browser automationは、許可済み業務・同意済みデータ処理・自社管理対象・正当なQA/負荷試験に限定する。
- 必ず rate limit、bounded queue、timeout、AbortSignal、audit log、kill switch を持つ。
- secret、token、PII、音声データ、心理推定データ、鍵素材をログへ出さない。
- 無制限Promise、unbounded queue、browser context乱立、巨大body一括読み、`as any`拡散、CJS/ESM混在を避ける。
- 暗号は `jose` / `@noble/*` / `@hpke/*` / `libsodium` / WebCrypto を使っても、test vectors、key rotation、XSS、supply chain を検証する。
- リアルタイム音声・超低遅延・秘密鍵処理は TypeScript 単体で無理に焼かず、Rust sidecar / N-API / WASM を検討する。

## 2. Lane decision map

| Lane | Use when | Load reference |
|---|---|---|
| Runtime/Toolchain | Node/Bun/Deno/TS/pnpm/monorepo/tsconfig | `references/runtime-toolchain.md` |
| Frontend/Fullstack | React/Next/React Router/Vite/TanStack/Tailwind/Web Builder | `references/frontend-fullstack.md` |
| API/Crawler/High-load | Hono/Fastify/Undici/Crawlee/Playwright/Cheerio/OpenAPI | `references/api-crawler-highload.md` |
| Edge Runtime | Cloudflare Workers/Wrangler/Miniflare/Hono edge | `references/edge-runtime-workers.md` |
| AI Agent/Realtime | OpenAI SDK/Agents SDK/AI SDK/LangGraph/MCP/SSE/WebSocket/audio boundary | `references/ai-agent-realtime.md` |
| Crypto/E2EE/Security | jose/noble/hpke/libsodium/WebCrypto/auth/key handling | `references/crypto-e2ee-security.md` |
| Data/State/Search | Drizzle/Kysely/Prisma/Postgres/Redis/BullMQ/vector DB | `references/data-state-search.md` |
| Performance Hot Path | bundle, workers, parsing, queues, memory, Rust sidecar boundary | `references/performance-hotpath.md` |
| Testing/Release Quality | Vitest/Playwright/Biome/ESLint/tsd/publint/ATTW/happy-dom/web-vitals | `references/testing-release-quality.md` |
| Observability/Governance | pino/OTel/Sentry/OSV/Renovate/npm audit/provenance | `references/observability-governance.md` |

Always use `typescript-skills-master.md` as the single source of truth and `typescript-skills-sources.md` as the source registry. The reference files are lane-level expansions generated from the master, not independent policy.

## 3. Canonical architecture patterns

### 3.1 High-load HTTP / crawler

```text
authorized input
  -> allowlist/robots/consent policy
  -> bounded p-queue
  -> p-limit or bottleneck per host/account
  -> undici Client/Pool
  -> cheerio/parse5 for static HTML
  -> playwright/crawlee only for JS-rendered pages
  -> classifier
  -> audit/event sink
```

### 3.2 Fullstack web builder

```text
Next.js / React Router / Vite
  -> React 19 + TanStack Query/Router
  -> Tailwind v4 plugins + clsx + tailwind-merge
  -> Hono/tRPC/OpenAPI typed API
  -> Yjs/Liveblocks/tldraw/Lexical for collaboration/editor needs
  -> Playwright E2E + visual tests
  -> pino/OTel/web-vitals
```

### 3.3 AI agent

```text
OpenAI SDK / OpenAI Agents SDK / AI SDK / LangGraph
  -> typed tool contracts with zod/valibot/typebox
  -> streaming SSE/WebSocket
  -> bounded tool execution queue
  -> audit spans + guardrails
  -> Rust sidecar for audio hot path when needed
```

### 3.4 E2EE/security

```text
jose for JWT/JWE/JWS/OIDC
  -> @noble/* for low-level primitives where needed
  -> @hpke/* for HPKE experiments
  -> libsodium only when its operational tradeoff is accepted
  -> WebCrypto for browser-native crypto
  -> never log secrets or raw keys
```

## 4. Critical version traps

| Trap | Correct rule |
|---|---|
| `undici` vs `undici-types` | They are separate packages. At the late 2026-05-06 recheck both resolve to v8.2.0, but future equality must not be assumed. |
| `@swc/core` vs `@swc/wasm` | They are separate packages. At the late 2026-05-06 recheck both resolve to v1.15.33, but verify each package independently. |
| `pnpm` dist-tag vs official v11 | npm `latest` resolves to pnpm 10.33.3 while `latest-11` resolves to 11.0.6. For Node 24+ pin `packageManager` explicitly to the chosen line. |
| `@types/node` | Match runtime major. Node 24 LTS => `@types/node@24`, not blindly npm latest. |
| Rolldown | If latest is rc/canary, keep R&D. Do not mark as stable core. |

## 5. Required verification commands

```bash
corepack enable
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
```

## 6. Output expectations for agents

When using this skill, produce:

1. architecture decision
2. latest-stable package version status
3. risk/advisory notes
4. migration steps
5. validation commands
6. rollback plan

Never propose dependency upgrades without naming source, lockfile impact, engine requirement, and CI checks.
