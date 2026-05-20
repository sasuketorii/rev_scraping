# GoSkills Pack Audit — 2026-05-06

## Score

Initial quality: 96/100 before real-repo validation.

100点にするには、実際の `go.mod` / `go.sum` / CI / benchmark / pprof / production SLO を通す必要がある。

## What was verified

- Go latest stable patch: Go 1.26.2.
- Go release support policy: major release is supported until two newer major releases.
- Core backend modules: chi, pgx, sqlc, Connect, gRPC, Huma.
- Browser automation: chromedp, rod.
- Crawler: Colly.
- High-performance hot path: fasthttp, sonic, go-json.
- Observability: slog, zap, zerolog, OpenTelemetry, Prometheus.
- Workflow/messaging: NATS, Temporal, Asynq, Kafka-Go.
- AI: official OpenAI Go SDK, MCP Go SDK v1.6.0, LangChain Go watch.
- Security: govulncheck, gosec, golangci-lint, staticcheck, x/crypto, CIRCL, Noise.

## Strict caveats

### 1. v0.x module policy

Go modules below v1 are not considered stable by semantic import versioning. The following are useful but must remain Watch/R&D:

- `github.com/chromedp/chromedp` v0.15.1
- `github.com/go-rod/rod` v0.116.2
- `github.com/gocolly/colly/v2` is v2 and stable by major path, but crawler policy risk remains.
- `entgo.io/ent` v0.14.6
- `github.com/hibiken/asynq` v0.26.0
- `github.com/segmentio/kafka-go` v0.4.51
- `github.com/tmc/langchaingo` v0.1.14
- `github.com/testcontainers/testcontainers-go` v0.42.0
- `golang.org/x/*` modules are v0.x but official Go supplemental modules; treat as Core/Watch.

### 2. fasthttp / Fiber policy

`fasthttp` can be extremely fast but is not drop-in compatible with `net/http`. Use only when measured. Fiber is not selected as default because net/http compatibility matters for middleware, tracing, and standard integration.

### 3. JSON hot path policy

`sonic` and `go-json` are not default replacements for `encoding/json`. Use them only after benchmark and compatibility tests.

### 4. Crypto policy

Go standard crypto is strong for most production needs. CIRCL and Noise are R&D/Adopt only after cryptographic design review. Never invent custom protocol glue without nonce/counter/AAD review.

### 5. OpenAI / MCP policy

OpenAI uses the official Go SDK. MCP Go SDK is v1.6.0 and stable by v1 module path, but should still be checked against Model Context Protocol spec updates and transport security advisories.

## Required real-repo validation

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

## Final judgment

This pack is production-ready as a knowledge base, not yet as a certified dependency lock. Certification requires actual project lockfile and CI evidence.
