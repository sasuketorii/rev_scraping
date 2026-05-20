# GoSkills Sources Index v0.1.1-strict

Snapshot: 2026-05-06 JST

このソース集は、公式ドキュメント、pkg.go.dev、GitHub Releases、Go vulnerability database を中心にした更新用インデックスである。更新時は日本語・英語の両方で確認する。

## Core language / toolchain

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-GO-RELEASE-HISTORY | Go Release History | https://go.dev/doc/devel/release | Go latest stable, patch release, support policy | Go 1.26.2 / 2026-04-07 |
| SRC-GO-HOME | Go official homepage | https://go.dev/ | Go language overview, standard library, concurrency | Core source |
| SRC-GO-STD-NETHTTP | net/http standard library | https://pkg.go.dev/net/http | HTTP server/client | Go 1.26.2 stdlib |
| SRC-GO-STD-CONTEXT | context standard library | https://pkg.go.dev/context | cancellation/deadline propagation | Go 1.26.2 stdlib |
| SRC-GO-STD-SLOG | log/slog standard library | https://pkg.go.dev/log/slog | structured logging | Go 1.26.2 stdlib |
| SRC-GO-STD-CRYPTO | crypto standard library | https://pkg.go.dev/crypto | crypto primitives index | Go 1.26.2 stdlib |
| SRC-GO-PPROF | runtime/pprof | https://pkg.go.dev/runtime/pprof | CPU/heap/profile | Go 1.26.2 stdlib |
| SRC-GO-METRICS | runtime/metrics | https://pkg.go.dev/runtime/metrics | runtime metrics | Go 1.26.2 stdlib |

## Official supplemental Go modules

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-X-SYNC-ERRGROUP | golang.org/x/sync/errgroup | https://pkg.go.dev/golang.org/x/sync/errgroup | goroutine group, error propagation, context cancellation | v0.20.0 |
| SRC-X-TIME-RATE | golang.org/x/time/rate | https://pkg.go.dev/golang.org/x/time/rate | token bucket rate limiter | v0.15.0 |
| SRC-X-CRYPTO | golang.org/x/crypto | https://pkg.go.dev/golang.org/x/crypto | supplemental cryptography | v0.50.0 |
| SRC-X-VULN | golang.org/x/vuln/govulncheck | https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck | Go official vulnerability scanner | latest/pinned tool |
| SRC-GO-VULN-DB | Go Vulnerability Database | https://go.dev/doc/security/vuln/database | vulnerability DB used by govulncheck | canonical vuln.go.dev |

## API / RPC / Backend

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-CHI | go-chi/chi | https://pkg.go.dev/github.com/go-chi/chi/v5 | lightweight HTTP router | v5.2.5 |
| SRC-CONNECT | connectrpc/connect-go | https://pkg.go.dev/connectrpc.com/connect | Connect/gRPC/gRPC-Web RPC | v1.19.2 |
| SRC-GRPC | grpc-go | https://pkg.go.dev/google.golang.org/grpc | canonical gRPC | v1.81.0 |
| SRC-HUMA | Huma v2 | https://pkg.go.dev/github.com/danielgtaylor/huma/v2 | REST APIs with OpenAPI 3.1 | v2.37.3 |
| SRC-GIN | Gin | https://pkg.go.dev/github.com/gin-gonic/gin | HTTP web framework | v1.12.0 |
| SRC-FIBER-V2 | Fiber v2 | https://pkg.go.dev/github.com/gofiber/fiber/v2 | fasthttp-based framework | v2.52.13 legacy/hold |
| SRC-FASTHTTP | fasthttp | https://pkg.go.dev/github.com/valyala/fasthttp | high-performance HTTP | v1.71.0 R&D |

## High-load crawler / browser automation

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-COLLY | Colly | https://pkg.go.dev/github.com/gocolly/colly/v2 | crawler framework | v2.3.0 |
| SRC-CHROMEDP | chromedp | https://pkg.go.dev/github.com/chromedp/chromedp | Chrome DevTools Protocol automation | v0.15.1 Watch |
| SRC-ROD | rod | https://pkg.go.dev/github.com/go-rod/rod | browser automation | v0.116.2 Watch |
| SRC-GOQUERY | goquery | https://pkg.go.dev/github.com/PuerkitoBio/goquery | jQuery-like HTML traversal | version check required |
| SRC-RETRYABLEHTTP | go-retryablehttp | https://pkg.go.dev/github.com/hashicorp/go-retryablehttp | retrying stdlib-like HTTP client | v0.7.8 Watch |
| SRC-BACKOFF | cenkalti/backoff v5 | https://pkg.go.dev/github.com/cenkalti/backoff/v5 | exponential backoff | v5.0.3 |
| SRC-UBER-RATELIMIT | uber-go/ratelimit | https://pkg.go.dev/go.uber.org/ratelimit | blocking leaky-bucket limiter | v0.3.1 |
| SRC-ANTS | panjf2000/ants | https://pkg.go.dev/github.com/panjf2000/ants/v2 | goroutine pool | v2.12.0 |

## Data / DB / search

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-PGX | pgx | https://pkg.go.dev/github.com/jackc/pgx/v5 | pure Go PostgreSQL driver/toolkit | v5.9.2 |
| SRC-SQLC | sqlc | https://pkg.go.dev/github.com/sqlc-dev/sqlc | generate type-safe Go from SQL | v1.31.1 |
| SRC-ENT | ent | https://pkg.go.dev/entgo.io/ent | entity graph/schema codegen | v0.14.6 Watch |
| SRC-QDRANT-GO | qdrant/go-client | https://github.com/qdrant/go-client | Qdrant vector DB client | v1.17.1 |
| SRC-PGVECTOR-GO | pgvector-go | https://github.com/pgvector/pgvector-go | pgvector Go helper | version/tag check required |
| SRC-GO-REDIS | go-redis | https://pkg.go.dev/github.com/redis/go-redis/v9 | Redis client | version check required |
| SRC-RISTRETTO | Ristretto v2 | https://github.com/dgraph-io/ristretto | high-performance memory cache | v2.4.0 release watch |
| SRC-FASTCACHE | VictoriaMetrics fastcache | https://pkg.go.dev/github.com/VictoriaMetrics/fastcache | GC-light cache | version check required |

## JSON / compression / hot path

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-SONIC | bytedance/sonic | https://pkg.go.dev/github.com/bytedance/sonic | high-performance JSON | v1.15.1 |
| SRC-GO-JSON | goccy/go-json | https://pkg.go.dev/github.com/goccy/go-json | high-performance JSON | v0.10.6 Watch |
| SRC-KLAUSPOST-COMPRESS | klauspost/compress | https://pkg.go.dev/github.com/klauspost/compress | zstd/gzip/deflate/snappy etc. | v1.18.6 |

## Messaging / workflows

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-NATS-GO | nats.go | https://pkg.go.dev/github.com/nats-io/nats.go | NATS / JetStream client | v1.51.0 |
| SRC-TEMPORAL-GO | Temporal Go SDK | https://pkg.go.dev/go.temporal.io/sdk | durable workflow orchestration | v1.43.0 |
| SRC-ASYNQ | Asynq | https://pkg.go.dev/github.com/hibiken/asynq | Redis distributed task queue | v0.26.0 Watch |
| SRC-KAFKA-GO | kafka-go | https://pkg.go.dev/github.com/segmentio/kafka-go | Kafka client without cgo | v0.4.51 Watch/R&D |

## AI / MCP

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-OPENAI-GO | OpenAI Go SDK | https://developers.openai.com/api/libraries/go | Official OpenAI Go API library | v3.34.0 |
| SRC-OPENAI-SDKS | OpenAI SDKs | https://platform.openai.com/docs/libraries | Official SDK list | Go SDK official |
| SRC-MCP-GO-OFFICIAL | Model Context Protocol Go SDK | https://pkg.go.dev/github.com/modelcontextprotocol/go-sdk/mcp | official MCP Go SDK | v1.6.0 |
| SRC-MCP-DOCS | Model Context Protocol docs | https://modelcontextprotocol.io/ | MCP standard docs | official |
| SRC-MCP-GO-MARK3LABS | mark3labs/mcp-go | https://github.com/mark3labs/mcp-go | community MCP Go implementation | Watch |
| SRC-LANGCHAINGO | LangChain Go | https://pkg.go.dev/github.com/tmc/langchaingo | LLM/agent framework for Go | v0.1.14 R&D |

## CLI / TUI

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-COBRA | Cobra | https://pkg.go.dev/github.com/spf13/cobra | CLI framework | v1.10.2 |
| SRC-BUBBLETEA | Bubble Tea v2 | https://pkg.go.dev/charm.land/bubbletea/v2 | TUI runtime | v2.0.6 |
| SRC-LIPGLOSS | Lip Gloss v2 | https://pkg.go.dev/charm.land/lipgloss/v2 | terminal styling | v2.0.3 |
| SRC-BUBBLES | Bubbles v2 | https://pkg.go.dev/charm.land/bubbles/v2 | TUI components | v2.1.0 |
| SRC-CHARM-V2-BLOG | Charm v2 announcement | https://charm.land/blog/charm-v2/ | v2 readiness/optimized rendering | official blog |

## Observability / operations

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-ZAP | zap | https://pkg.go.dev/go.uber.org/zap | high-performance structured logging | v1.28.0 |
| SRC-ZERolog | zerolog | https://pkg.go.dev/github.com/rs/zerolog | low-allocation structured logging | v1.35.1 |
| SRC-OTEL | OpenTelemetry Go | https://pkg.go.dev/go.opentelemetry.io/otel | traces/metrics/logs instrumentation | v1.43.0 |
| SRC-PROM | prometheus/client_golang | https://pkg.go.dev/github.com/prometheus/client_golang | Prometheus metrics | v1.23.2 |
| SRC-AUTOMAXPROCS | automaxprocs | https://pkg.go.dev/go.uber.org/automaxprocs | container-aware GOMAXPROCS | v1.6.0 |

## Testing / quality / security

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-GO-CMP | go-cmp | https://pkg.go.dev/github.com/google/go-cmp/cmp | semantic test comparisons | v0.7.0 Watch |
| SRC-TESTIFY | testify | https://pkg.go.dev/github.com/stretchr/testify | assertions/mocks/suites | v1.11.1 |
| SRC-TESTCONTAINERS | testcontainers-go | https://pkg.go.dev/github.com/testcontainers/testcontainers-go | containerized integration tests | v0.42.0 Watch |
| SRC-GOLANGCI-LINT | golangci-lint changelog | https://golangci-lint.run/docs/product/changelog/ | linter runner changelog | v2.12.1 |
| SRC-STATICCHECK | Staticcheck docs | https://staticcheck.dev/docs/getting-started/ | static analysis | latest pinned |
| SRC-GOSEC | gosec | https://pkg.go.dev/github.com/securego/gosec/v2 | security static analysis | v2.26.1 |
| SRC-GOVULNCHECK | govulncheck tutorial | https://go.dev/doc/tutorial/govulncheck | official vulnerability scanner tutorial | official |

## Crypto / E2EE

| ID | Title | URL | Function | Snapshot |
|---|---|---|---|---|
| SRC-CIRCL | Cloudflare CIRCL | https://pkg.go.dev/github.com/cloudflare/circl | PQ/ECC crypto primitives | v1.6.3 R&D |
| SRC-CIRCL-RELEASES | CIRCL GitHub Releases | https://github.com/cloudflare/circl/releases | release watch | v1.6.3 latest by GitHub |
| SRC-NOISE | flynn/noise | https://pkg.go.dev/github.com/flynn/noise | Noise Protocol Framework | v1.1.0 R&D |
| SRC-NOISE-PROTOCOL | Noise Protocol | https://noiseprotocol.org/ | protocol standard | standard |
| SRC-AGE | age | https://pkg.go.dev/filippo.io/age | file encryption | version check required |

## Multi-skill platform sources added in v0.1.1-strict

| ID | Title | URL | Function | Rule |
|---|---|---|---|---|
| SRC-CLOUDFLARE-WORKERS-LANGUAGES | Cloudflare Workers Languages | https://developers.cloudflare.com/workers/languages/ | first-class Worker languages and Wasm route | Cloudflare runtime source of truth |
| SRC-CLOUDFLARE-WASM | Cloudflare Workers WebAssembly | https://developers.cloudflare.com/workers/runtime-apis/webassembly/ | Wasm support and threading/binary-size constraints | Go-on-Workers is Wasm/R&D, not default |
| SRC-CLOUDFLARE-RUST | Cloudflare Workers Rust | https://developers.cloudflare.com/workers/languages/rust/ | workers-rs support | Rust edge ownership |
| SRC-SUPABASE-CLIENT-LIBS | Supabase Client Libraries | https://supabase.com/docs/guides/api/rest/client-libs | official vs community libraries | Go Supabase clients are Watch/R&D unless official |
| SRC-SUPABASE-POSTGRES | Supabase Platform | https://supabase.com/ | Postgres/Auth/Realtime/Storage/Vector platform | Go uses pgx/sqlc for server-side DB access |
| SRC-SQLC-PGX | sqlc using Go and pgx | https://docs.sqlc.dev/en/v1.23.0/guides/using-go-and-pgx.html | pgx/sqlc integration | preferred Go server-side Supabase/Postgres path |
