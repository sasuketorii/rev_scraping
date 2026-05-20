# TypeScriptSkills Knowledge Pack

- **Version**: `v0.1.2`
- **Snapshot date**: 2026-05-06 JST
- **Registry check**: 2026-05-06 JST late recheck via npm registry
- **Scope**: REV-C Inc. の TypeScript 技術体系。RustSkills の思想を TypeScript / Node.js / Bun / Deno / Web / AI Agent / E2EE / Data Platform へ移植する。
- **Policy**: 原則は **latest stable**。ただし Node.js は「本番 latest LTS + CI latest Current」、pnpm は Node engine と registry dist-tag の差分を明示して運用する。

## Document roles

`typescript-skills-master.md` が単一の真実源です。`SKILL.md` はCodex/Claude/ChatGPT Skills用の軽量入口で、重要ルールと参照先だけを持ちます。`references/` はmasterから分野別に切り出した詳細資料、`typescript-skills-sources.md` は公式ソースとregistry確認先です。

## Files

```text
typescript-skills-knowledge-pack/
  README.md
  AGENTS.md
  SKILL.md
  typescript-skills-master.md
  typescript-skills-sources.md
  typescript-skills-update-prompt.md
  typescript-skills-pack-audit-2026-05-06-v0.1.2.md  # current versioned audit
  typescript-skills-pack-audit-2026-05-06-v0.1.1.md  # historical/versioned audit
  references/
    runtime-toolchain.md
    frontend-fullstack.md
    api-crawler-highload.md
    edge-runtime-workers.md
    ai-agent-realtime.md
    crypto-e2ee-security.md
    data-state-search.md
    performance-hotpath.md
    testing-release-quality.md
    observability-governance.md
```

## Baseline

- Production runtime: **Node.js latest LTS**
- Compatibility/R&D runtime: **Node.js latest Current**, Bun, Deno
- Package manager: **pnpm latest stable compatible with production Node baseline**
- Language: TypeScript latest stable
- Web: React / Next.js / React Router / Vite / TanStack / Tailwind
- API: Hono / Fastify / Undici / OpenAPI contract generation
- Browser automation: Playwright / Crawlee / Cheerio / parse5
- Edge: Cloudflare Workers / Wrangler / Miniflare where required
- AI: OpenAI SDK / OpenAI Agents SDK / Vercel AI SDK / LangGraph / MCP
- Web Builder: Yjs / Liveblocks / tldraw / Lexical / dnd-kit / Floating UI / Radix
- Data: Drizzle / Kysely / Postgres / Redis / BullMQ / Qdrant / LanceDB
- Observability: pino / OpenTelemetry / Prometheus / Sentry / web-vitals
- Release quality: tsd / publint / @arethetypeswrong/cli / dependency-cruiser / knip
- Supply chain: pnpm minimumReleaseAge, OSV-Scanner, npm audit, Renovate, trusted publishing/provenance

## How to use

1. `SKILL.md` を Codex / Claude Code / ChatGPT Skills の入口として読む。
2. 依存関係、採用可否、設計例外、更新方針は `typescript-skills-master.md` を正として判断する。
3. 分野別の実装詳細は `references/*` を参照する。
4. 更新時は `typescript-skills-update-prompt.md` を ChatGPT / Claude / Gemini Deep Research に貼り、公式ソース中心に再調査する。
5. package version は latest stable を基本にし、pre/rc/canary/next は R&D 隔離する。
6. 実repoでは必ず lockfile、audit、typecheck、lint、test、E2E、bundle/bench を通す。

## Safety

Crawler、form sender、browser automation、AI agent、E2EEは、許可済み業務・同意済みデータ処理・自社管理対象・正当なQA/負荷試験に限定する。外部対象には必ず rate limit、allowlist、audit、kill switch を設計する。

## Audit history

この節は履歴です。現在の採用判断は必ず `typescript-skills-master.md` の version register と `typescript-skills-sources.md` の公式ソース確認で行います。

- `v0.1.1-strict`: `README.md` と `references/` の構造不一致を解消し、`undici` / `undici-types`、`@swc/core` / `@swc/wasm`、pnpm dist-tag、`@types/node` runtime-major対応を明示した。
- `v0.1.2`: master-first構造を明文化し、同日内のregistry変化で過去監査メモが現在指示に見えないようにした。late recheckでは `undici` と `undici-types` はどちらも v8.2.0、`@swc/core` と `@swc/wasm` はどちらも v1.15.33。
