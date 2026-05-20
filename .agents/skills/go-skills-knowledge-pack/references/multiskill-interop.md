# Multi-Skill Interop: Cloudflare / Supabase / Rust / TypeScript / Go

## Purpose

このファイルは、開発基盤エージェントに CloudflareSkills、SupabaseSkills、RustSkills、TypeScriptSkills、GoSkills を同時に読み込ませるときの衝突解決ルールである。
GoSkills は Go単体の最適化だけでなく、プラットフォーム全体の役割分担を守る。

## Source-of-truth hierarchy

1. Security / compliance / secrets: platform-specific official docs and AGENTS.md override language preference.
2. Cloudflare runtime behavior: CloudflareSkills override language-specific assumptions.
3. Supabase product behavior: SupabaseSkills override language-specific client assumptions.
4. Language implementation details: RustSkills / TypeScriptSkills / GoSkills apply inside their assigned runtime boundary.
5. Performance claims: require benchmark or production metrics before final adoption.

## Runtime ownership

### Cloudflare edge

Default:

- TypeScript for general Workers, Pages Functions, Durable Objects, Queues, R2/KV/D1 glue, and Miniflare/Wrangler testing.
- Rust for Wasm-heavy Workers, crypto/performance kernels, or Rust-owned edge APIs through workers-rs.
- Go is not the default Cloudflare Worker language. Go may enter through WebAssembly/TinyGo/R&D only when the Cloudflare constraints are explicitly accepted.

Rules:

- Do not port a Cloudflare Worker to Go merely because backend code is Go.
- If Worker runtime constraints conflict with Go stdlib assumptions, CloudflareSkills wins.
- Worker tests should normally stay in TypeScript/JavaScript even when Rust Wasm is used, because local worker tooling is Node/Wrangler/Miniflare centered.

### Supabase

Default:

- Supabase is treated as a Postgres platform: Database, Auth, Edge Functions, Realtime, Storage, Vector, Management API.
- TypeScript uses official `@supabase/supabase-js` for client and edge glue.
- Go uses `pgx` + `sqlc` for server-side PostgreSQL access and only uses community Supabase Go clients as Watch/R&D.
- Service-role keys are server-only and must not cross into browser/Worker public client code.

Rules:

- If a task requires first-class Supabase SDK behavior, prefer TypeScript unless an official Go SDK exists and is verified.
- For Go services, prefer direct Postgres access through `pgx`/`sqlc` over community REST wrappers when correctness and observability matter.
- RLS, auth policy, database migrations, and edge-function behavior are SupabaseSkills concerns; GoSkills only implements service code around them.

### Rust

Default:

- Rust owns zero-copy, SIMD, low-level E2EE, Wasm kernels, high-performance crawler hot paths, and pure-Rust crypto decisions.
- Go may own orchestration around Rust services, but should not silently replace Rust for the low-level lanes.

Rules:

- If RustSkills specifies pure-Rust cryptography or memory layout constraints, GoSkills must not weaken them.
- Cross-language boundaries should use explicit protocols: HTTP/Connect/gRPC/NATS, or versioned binary contracts when justified.

### TypeScript

Default:

- TypeScript owns frontend, Next/React, Cloudflare general Workers, Supabase JS client, Playwright, UI automation, and browser-side agent interfaces.
- Go owns API services, CLIs, worker daemons, durable workflows, and backend integration.

Rules:

- Browser automation: TypeScript Playwright is default for E2E; Go `chromedp`/`rod` is backend-side browser automation only when Go ownership is clear.
- Avoid duplicating schema definitions. Generate TS/Go/Rust types from one schema source where possible.

## Agent routing matrix

| Task | Primary skill | Secondary skill |
|---|---|---|
| Cloudflare Worker API | Cloudflare + TypeScript | Rust if Wasm/perf |
| Cloudflare Rust Worker | Cloudflare + Rust | TypeScript for testing |
| Supabase browser/client integration | Supabase + TypeScript | Go only for backend calls |
| Supabase server-side data service | Supabase + Go | Rust if perf/crypto |
| High-load API backend | Go | Rust for hot path |
| E2EE/protocol kernel | Rust | Go for service wrapper |
| Frontend/fullstack UI | TypeScript | Rust if Leptos/Wasm chosen |
| Durable workflow orchestration | Go | TS for edge triggers |
| Vector/search data plane | Supabase/Go/Rust depending backend | TS for UI |

## Repo-level rules for multi-skill agents

1. Load platform instructions first: `AGENTS.md`, Cloudflare/Supabase project docs, then language skill.
2. Never let two language skills generate the same file without an ownership decision.
3. Put generated code under language-specific directories, for example `services/go-*`, `workers/ts-*`, `crates/*`, `apps/web`.
4. Keep secrets and environment names consistent across languages, but never share secret values in generated files.
5. Run all relevant CI gates for the affected languages, not just the language that edited files.

## Minimum integrated CI gates

```bash
# Go
go test ./...
go test -race ./...
govulncheck ./...
gosec ./...
golangci-lint run

# TypeScript / Cloudflare / Supabase JS
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
pnpm exec wrangler deploy --dry-run

# Rust
cargo test --all-targets --all-features
cargo clippy --all-targets --all-features -- -D warnings
cargo audit
cargo deny check
```

## Red flags

- Go code assumes Cloudflare Workers has normal Go runtime semantics.
- Go code uses community Supabase client as if it were official.
- TypeScript code receives service-role secrets in browser/edge-public context.
- Rust crypto constraints are reimplemented in Go without protocol review.
- Multiple skills define conflicting schema, env, auth, or routing rules.
