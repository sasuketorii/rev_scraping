---
name: go-skills-architecture
description: "Use this skill when designing, reviewing, or updating Go systems for REV-C projects: high-load crawlers, API backends, browser automation, AI agents, CRM/data/search platforms, messaging/workflows, TUI/CLI tools, and security-sensitive infrastructure. Prefer latest stable versions, pinned modules, official documentation, and strict CI/security checks."
metadata:
  version: 0.1.1-strict
  summary: REV-C 向けの Go 高負荷API・クローラー・AIエージェント・E2EE・データ基盤構築Skill。最新安定版を前提に、Go公式標準ライブラリと厳選moduleを使い分ける。
---

# GoSkills

- **Version**: `v0.1.1-strict`
- **Snapshot date**: 2026-05-06 JST
- **Generated from**: `go-skills-master.md`
- **Source registry**: `go-skills-sources.md`

この `SKILL.md` は Codex / Claude Code / ChatGPT Skills の軽量入口。判断の本体は `go-skills-master.md`、根拠URLは `go-skills-sources.md`、分野別詳細は `references/` に置く。

Dependency version、採用レーン、例外、移行判断を出すときは、必ず `go-skills-master.md` を先に読む。`SKILL.md` だけでmodule registerを確定しない。

## Mission

GoSkills は、REV-C のプロジェクト群に Go を投入するための実戦Skillである。RustSkills の低レイヤー性能思想と TypeScriptSkills のAI/フルスタック運用思想を、Goの標準ライブラリ・goroutine・単一バイナリ運用に写像する。

## Default stance

1. 最新安定版を使う。
2. `go.mod` / `go.sum` / tool version を固定する。
3. v0.x module は「最新タグ」でも stable 扱いしない。Adopt/Watch/R&Dで扱う。
4. 公式docs、pkg.go.dev、GitHub Releases、Go vulnerability database を優先する。
5. 100点判定は実repoで `go test`, `govulncheck`, `gosec`, `golangci-lint`, `pprof`, benchmark を通してから行う。

## Primary toolchain

- Go: 1.26.2
- Production baseline: latest Go patch release
- CI: same Go patch + previous supported Go major if compatibility is required
- Security: `govulncheck`, `gosec`, `go mod verify`
- Lint: `go vet`, `staticcheck`, `golangci-lint`

## Architecture lanes

### 1. API / backend

Use:

- `net/http` as default HTTP core
- `github.com/go-chi/chi/v5` for routing
- `connectrpc.com/connect` for browser-compatible RPC
- `google.golang.org/grpc` for strict gRPC interop
- `github.com/danielgtaylor/huma/v2` for REST + OpenAPI 3.1

Rules:

- Do not create `http.Client` per request.
- Always set deadline/cancellation through `context.Context`.
- Use middleware for request id, auth, timeout, body size limit, logging, tracing.

### 2. High-load crawler / form sender

Use:

- `net/http.Transport` tuned per target class
- `golang.org/x/sync/errgroup` with `SetLimit`
- `golang.org/x/time/rate` for token bucket limits
- `github.com/cenkalti/backoff/v5` for retry policy
- `github.com/gocolly/colly/v2` for crawler abstraction
- `github.com/chromedp/chromedp` / `github.com/go-rod/rod` for browser/CDP escalation
- `github.com/valyala/fasthttp` only for measured hot paths

Rules:

- Treat browser automation as escalation, not default crawling.
- Separate global concurrency, host-level concurrency, and account/campaign rate limits.
- Never let queues become unbounded.

### 3. Data / CRM / search

Use:

- `github.com/jackc/pgx/v5` for PostgreSQL
- `github.com/sqlc-dev/sqlc` for type-safe SQL codegen
- `entgo.io/ent` for schema graph/codegen where useful
- `github.com/qdrant/go-client` for vector DB
- pgvector/SQL path for PostgreSQL-native vector workflows when appropriate

Rules:

- Keep operational truth in PostgreSQL.
- Keep semantic retrieval in vector store or pgvector lane.
- Avoid huge eager loads. Stream rows and batch writes.

### 4. AI agents / MCP / workflows

Use:

- `github.com/openai/openai-go/v3` for official OpenAI API access
- `github.com/modelcontextprotocol/go-sdk` v1.6.0 as official MCP SDK adopt lane
- `github.com/tmc/langchaingo` as R&D
- `github.com/nats-io/nats.go` for event bus / JetStream
- `go.temporal.io/sdk` for durable workflows
- `github.com/hibiken/asynq` for Redis task queue watch lane

Rules:

- Make agent tool calls typed and auditable.
- Persist durable state outside the LLM loop.
- Use idempotency keys for tool execution.

### 5. CLI / TUI

Use:

- `github.com/spf13/cobra` for CLI
- `charm.land/bubbletea/v2` for TUI runtime
- `charm.land/lipgloss/v2` for styling
- `charm.land/bubbles/v2` for components

Rules:

- Separate app state, update loop, renderer, and side effects.
- Keep network/LLM calls outside render path.
- Use structured logs even for CLI tools.

### 6. Security / E2EE

Use:

- `crypto/tls` and standard crypto first
- `golang.org/x/crypto` for supplemental crypto
- `github.com/cloudflare/circl` for PQ/ECC R&D
- `github.com/flynn/noise` for Noise Protocol R&D

Rules:

- Do not invent cryptographic protocols casually.
- Review nonce/counter/AAD/key rotation explicitly.
- Keep secret material out of logs, traces, panics, and test fixtures.

### 7. Observability / performance

Use:

- `log/slog` default
- `go.uber.org/zap` or `github.com/rs/zerolog` for performance logging
- `go.opentelemetry.io/otel`
- `github.com/prometheus/client_golang`
- `runtime/pprof`, `runtime/metrics`, `testing.B`
- `go.uber.org/automaxprocs` in containers

Rules:

- Measure p50/p95/p99 and allocations/op.
- Use `pprof` before “optimizing.”
- Watch GC pauses and goroutine counts under load.

### 8. Multi-skill platform integration

When Cloudflare, Supabase, Rust, TypeScript, and Go skills are loaded together:

- Cloudflare runtime rules override Go runtime assumptions for Workers.
- Supabase official/client rules override Go community-client assumptions.
- Rust owns low-level E2EE/performance kernels unless explicitly reassigned.
- TypeScript owns browser, frontend, and general Cloudflare Worker glue.
- Go owns backend APIs, CLIs, durable workflows, service workers, and orchestration.

Read `references/multiskill-interop.md` before making cross-language architecture decisions.

## Required update checklist

Run in every serious update:

```bash
go version
go env GOVERSION
go list -m -u -json all
go mod tidy
go mod verify
go test ./...
go test -race ./...
go vet ./...
govulncheck ./...
gosec ./...
golangci-lint run
staticcheck ./...
go test -bench=. -benchmem ./...
```

## References

Detailed rules live in these reference files. They are lane-level expansions generated from the master, not independent policy:

- `references/runtime-toolchain.md`
- `references/api-backend-rpc.md`
- `references/highload-crawler-browser.md`
- `references/data-persistence-search.md`
- `references/ai-agents-mcp.md`
- `references/tui-cli-audio.md`
- `references/crypto-security-e2ee.md`
- `references/messaging-workflows.md`
- `references/performance-memory.md`
- `references/observability-governance.md`
- `references/testing-release.md`
- `references/multiskill-interop.md`
