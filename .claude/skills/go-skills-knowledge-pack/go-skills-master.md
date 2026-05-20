# GoSkills Master v0.1.1-strict

- Snapshot: 2026-05-06 JST
- Target: REV-C の RustSkills・TypeScriptSkills と同じ思想で、Go を「高負荷API / クローラー / ブラウザ自動化 / 自律型AI / CRM / E2EE / 運用基盤」に投入するための世界基準ナレッジ体系にする。
- Core policy: 最新安定版を使う。ただし Go module の semantic import versioning 上、v0.x は「最新タグ」でも stable ではないため、Core ではなく Adopt / Watch / R&D として扱う。
- Primary toolchain: Go 1.26.2。Go公式Release Historyで 2026-04-07 リリースの最新 patch と確認。

---

## 0. How to read this master

このファイルが GoSkills の単一の真実源。`SKILL.md` は軽量入口、`references/` はこのmasterから分野別に切り出した詳細、`go-skills-sources.md` は公式ソースとregistry確認先。

Version registerはsnapshotであり、Go release history、module tag、pkg.go.dev stability表示、vulnerability databaseは更新される。実repoでmoduleを提案・更新するときは、このmasterの方針を読み、`go-skills-sources.md` の公式ソースで現在値を再確認してから `go.mod` / `go.sum` とCIに反映する。

---

## 1. GoSkills の目的

GoSkills は、RustSkills の低レイヤー・極限性能思想と、TypeScriptSkills のフルスタック/AIエージェント運用思想を Go へ写像するための実戦Skillである。

Go の強みは、以下の5点にある。

1. **標準ライブラリの強さ**: `net/http`, `context`, `crypto/tls`, `database/sql`, `log/slog`, `testing`, `runtime/pprof` が最初から実用水準。
2. **goroutine + channel + context**: 高負荷I/Oとキャンセル可能な並行処理を、Rustより少ない儀式で構築できる。
3. **単一バイナリ配布**: CLI、TUI、ワーカー、エージェント、APIサーバーを運用しやすい。
4. **クラウド/バックエンド親和性**: gRPC、Connect、NATS、Temporal、PostgreSQL、OpenTelemetryとの相性が高い。
5. **プロダクト速度**: Rustより短い実装時間で、TypeScriptより堅いバックエンドを作りやすい。

ただし Go は GC を持つため、RustSkills 的な「ゼロコピー / alloc最小化 / ロックフリー / tail latency最適化」をやる場合は、`[]byte`、`sync.Pool`、bounded worker、`pprof`、`runtime/metrics`、allocation profile を明示的に握る必要がある。

---

## 2. REV-C向けGoドメインマップ

### 1.1 高負荷API / クローラー / フォーム送信

基本構成:

```text
net/http tuned Transport
  + context deadline
  + x/time/rate token bucket
  + cenkalti/backoff retry
  + errgroup bounded fan-out
  + pgx/sqlc persistence
  + slog/otel/prometheus observability
```

採用方針:

- デフォルトは `net/http` + `chi`。
- 高速HTTPの特殊用途のみ `fasthttp` を検討。
- JSレンダリングやSPAフォームは `chromedp` または `rod`。
- 静的HTMLは `colly` または `net/http + goquery`。
- 大量goroutineを野放しにしない。`errgroup.SetLimit`, semaphore, `ants` などで上限を持つ。

### 1.2 Web/APIバックエンド

基本構成:

```text
chi / Huma / Connect-Go / gRPC-Go
  + pgx / sqlc
  + OpenTelemetry
  + Prometheus
  + zap or slog
```

採用方針:

- REST/HTTP は `chi` を第一候補。
- OpenAPI 3.1 が必要なら `huma/v2`。
- 型安全RPC・ブラウザ互換・gRPC互換を両立したいなら `connect-go`。
- 既存gRPCインフラや厳密proto契約がある場合は `grpc-go`。
- `fiber/fasthttp` は hot path 用であり、標準 `net/http` 互換性を捨てる判断を伴う。

### 1.3 AIエージェント / MCP / LLM基盤

基本構成:

```text
openai-go/v3
  + modelcontextprotocol/go-sdk or mcp-go
  + langchaingo as R&D
  + NATS / Temporal for orchestration
  + pgx/sqlc for durable state
  + Qdrant client / pgvector for retrieval
```

採用方針:

- OpenAI APIは公式 `github.com/openai/openai-go/v3` を第一候補。
- エージェント間・ツール接続は MCP を Watch/Adopt。
- 長期記憶は PostgreSQL + pgvector または Qdrant。
- 複雑なワークフローは Temporal、イベント配信は NATS。

### 1.4 CLI / TUI / オペレーションツール

基本構成:

```text
cobra
  + bubbletea v2
  + lipgloss v2
  + bubbles v2
  + slog / zap
```

採用方針:

- CLIは `cobra`。
- 対話TUIは Charm stack: `bubbletea/v2`, `lipgloss/v2`, `bubbles/v2`。
- RustのRatatuiほど低レイヤーではないが、Goで運用TUIやエージェントコンソールを作るなら最有力。

### 1.5 E2EE / セキュリティ / 秘匿通信

基本構成:

```text
crypto/tls
  + golang.org/x/crypto
  + circl for PQ/ECC experimental deployment
  + flynn/noise for Noise Protocol
  + strict key lifecycle
```

採用方針:

- 公開API・mTLSは標準 `crypto/tls` を優先。
- Noise系秘匿メッシュは `github.com/flynn/noise` を Adopt/Watch。
- PQ/ECC実験は Cloudflare CIRCL を R&D。
- 秘密鍵・nonce・counter・AAD設計はコードレビュー必須。

---

## 3. 採用レベル定義

| レベル | 意味 | 例 |
|---|---|---|
| Core | REV-C標準として基本採用 | Go 1.26.2, net/http, context, chi, pgx, sqlc, slog, OpenTelemetry |
| Adopt | 用途が合えば積極採用 | Huma, Connect-Go, NATS, Temporal, Bubble Tea, Cobra |
| Watch | 最新タグはあるが v0.x / 互換性 / 運用注意 | chromedp, rod, Colly, Ent, Asynq, Testcontainers |
| R&D | 高度・実験・特殊用途 | fasthttp, sonic, go-json, CIRCL, Noise, MCP, Kafka-Go |
| Hold | 既存互換のみ / 標準採用しない | Fiber v3はCVE・互換性確認後、Fiber v2はlegacy |

---

## 4. Core module register

| Module / Tool | Snapshot version | Tier | Role |
|---|---:|---|---|
| Go | 1.26.2 | Core | 言語・標準ライブラリ・toolchain |
| `net/http` | Go 1.26.2 stdlib | Core | API/HTTP client/server |
| `context` | Go 1.26.2 stdlib | Core | cancellation/deadline propagation |
| `log/slog` | Go 1.26.2 stdlib | Core | structured logging baseline |
| `runtime/pprof` / `runtime/metrics` | Go 1.26.2 stdlib | Core | performance profiling |
| `golang.org/x/sync/errgroup` | v0.20.0 | Core/Watch | structured goroutine groups |
| `golang.org/x/time/rate` | v0.15.0 | Core/Watch | token bucket rate limit |
| `github.com/go-chi/chi/v5` | v5.2.5 | Core | lightweight HTTP router |
| `connectrpc.com/connect` | v1.19.2 | Adopt | Connect/gRPC/gRPC-Web RPC |
| `google.golang.org/grpc` | v1.81.0 | Adopt | canonical gRPC interop |
| `github.com/danielgtaylor/huma/v2` | v2.37.3 | Adopt | REST + OpenAPI 3.1 |
| `github.com/jackc/pgx/v5` | v5.9.2 | Core | PostgreSQL driver/toolkit |
| `github.com/sqlc-dev/sqlc` | v1.31.1 | Core | SQL to type-safe Go codegen |
| `entgo.io/ent` | v0.14.6 | Watch | schema graph ORM/codegen |
| `github.com/gocolly/colly/v2` | v2.3.0 | Watch | crawler framework |
| `github.com/chromedp/chromedp` | v0.15.1 | Watch | Chrome DevTools Protocol automation |
| `github.com/go-rod/rod` | v0.116.2 | Watch | browser automation |
| `github.com/valyala/fasthttp` | v1.71.0 | R&D | ultra-fast non-net/http server/client |
| `github.com/bytedance/sonic` | v1.15.1 | R&D | SIMD/assembly JSON hot path |
| `github.com/goccy/go-json` | v0.10.6 | R&D | high-performance JSON compatible path |
| `github.com/klauspost/compress` | v1.18.6 | Adopt | compression |
| `go.uber.org/zap` | v1.28.0 | Adopt | high-performance structured logging |
| `github.com/rs/zerolog` | v1.35.1 | Adopt | low-allocation structured logging |
| `go.opentelemetry.io/otel` | v1.43.0 | Core | tracing/metrics/logs instrumentation |
| `github.com/prometheus/client_golang` | v1.23.2 | Core | Prometheus metrics |
| `go.uber.org/automaxprocs` | v1.6.0 | Adopt | container-aware GOMAXPROCS |
| `go.uber.org/ratelimit` | v0.3.1 | Adopt/Watch | blocking leaky-bucket limiter |
| `github.com/cenkalti/backoff/v5` | v5.0.3 | Adopt | retry backoff |
| `github.com/hashicorp/go-retryablehttp` | v0.7.8 | Watch | stdlib-like retrying HTTP client |
| `github.com/panjf2000/ants/v2` | v2.12.0 | Adopt | goroutine pool |
| `github.com/nats-io/nats.go` | v1.51.0 | Adopt | messaging / JetStream |
| `go.temporal.io/sdk` | v1.43.0 | Adopt | durable workflows |
| `github.com/hibiken/asynq` | v0.26.0 | Watch | Redis distributed task queue |
| `github.com/segmentio/kafka-go` | v0.4.51 | Watch/R&D | Kafka client without cgo |
| `github.com/openai/openai-go/v3` | v3.34.0 | Adopt | official OpenAI SDK |
| `github.com/tmc/langchaingo` | v0.1.14 | R&D | Go LangChain ecosystem |
| `github.com/modelcontextprotocol/go-sdk` | v1.6.0 | Adopt | official MCP Go SDK |
| `charm.land/bubbletea/v2` | v2.0.6 | Adopt | TUI runtime |
| `charm.land/lipgloss/v2` | v2.0.3 | Adopt | terminal styling |
| `charm.land/bubbles/v2` | v2.1.0 | Adopt | TUI components |
| `github.com/spf13/cobra` | v1.10.2 | Core | CLI framework |
| `golang.org/x/crypto` | v0.50.0 | Core/Watch | supplementary crypto |
| `github.com/cloudflare/circl` | v1.6.3 | R&D | PQ/ECC crypto primitives |
| `github.com/flynn/noise` | v1.1.0 | R&D | Noise Protocol Framework |
| `github.com/qdrant/go-client` | v1.17.1 | Adopt | Qdrant vector DB client |
| `github.com/google/go-cmp` | v0.7.0 | Watch | semantic test comparisons |
| `github.com/stretchr/testify` | v1.11.1 | Adopt | assertions/mocks; dependency watch |
| `github.com/testcontainers/testcontainers-go` | v0.42.0 | Watch | integration/smoke tests with containers |
| `github.com/securego/gosec/v2` | v2.26.1 | Core Tool | security static analysis |
| `golangci-lint` | v2.12.1 | Core Tool | linter runner |
| `govulncheck` | install latest or pinned tool version | Core Tool | Go official vulnerability reachability scanner |
| `staticcheck` | latest pinned in tools | Core Tool | static analysis |

---

## 5. 実装ルール: Goで100点を狙うための非交渉ライン

### 5.1 並行処理

- goroutineを無制限に作らない。
- `context.Context` を第一引数に通す。
- `errgroup.WithContext` と `SetLimit` を標準化する。
- worker queue は bounded channel を基本にする。
- CPU-bound と I/O-bound を同じqueueに混ぜない。

### 5.2 HTTP

- `http.Client` と `http.Transport` をリクエストごとに作らない。
- `Response.Body.Close()` は必ず行う。
- `Timeout` だけでなく、`DialContext`, `TLSHandshakeTimeout`, `ResponseHeaderTimeout`, `MaxIdleConns`, `MaxIdleConnsPerHost` を設計する。
- リトライは冪等性・body rewind・ステータス分類を明示する。
- 相手先別 rate limit と全体 concurrency limit を分ける。

### 5.3 JSON / bytes

- デフォルトは `encoding/json`。
- Hot path のみ `sonic` / `go-json` をベンチ後に導入。
- `[]byte -> string -> []byte` の往復を避ける。
- 大量イベントでは `json.Decoder` streaming と `io.Reader` pipeline を優先。

### 5.4 DB

- PostgreSQLは `pgx` を第一候補。
- SQLは `sqlc` で型安全コード生成。
- ORMは必要な領域だけ `ent`。
- `SELECT *`、巨大 `fetch all`、長時間transactionを禁止。
- `context` timeout と pool saturation を監視する。

### 5.5 Observability

- 全リクエスト・ジョブ・AI tool call に correlation id を持つ。
- ログは `slog` または `zap`/`zerolog` の構造化ログ。
- TraceはOpenTelemetry、metricsはPrometheus。
- 高負荷系は `pprof`, `runtime/metrics`, allocation profile をCI/benchで見る。

### 5.6 Security

- `govulncheck ./...` は必須。
- `gosec ./...` はCIでSARIF化。
- `go mod verify` と `go list -m -u -json all` を更新時に実行。
- 秘密値はenv/secret managerから読み、ログ・panic・traceへ出さない。
- Cryptoは標準ライブラリ優先。CIRCL/Noiseはレビュー付きR&D。

---

## 6. 参照構造

- `SKILL.md`: Codex/Claude向けの軽量Skillハブ。
- `go-skills-update-prompt.md`: ChatGPT / Claude / Gemini Deep Research でGoSkillsを更新するためのプロンプト。
- `go-skills-sources.md`: 公式・pkg.go.dev・GitHub release等のソースインデックス。
- `references/`: 分野別の詳細実装ガイド。
- `AGENTS.md`: リポジトリ運用時のAIエージェント指示。
- `README.md`: パックの使い方。
- `go-skills-pack-audit-2026-05-06.md`: 初期監査レポート。
