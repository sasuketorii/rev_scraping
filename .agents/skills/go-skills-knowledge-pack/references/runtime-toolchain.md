# Runtime / Toolchain

## Baseline

- Go 1.26.2 を最新安定patchとして採用。
- `go` directive は原則 `go 1.26`。
- `toolchain` directive を使う場合はCIとローカルの挙動差を明示する。
- Goのサポートは「2つ後のmajorが出るまで」という公式方針に従う。

## Standard packages to master

- `context`: cancellation, deadline, request scoped values.
- `net/http`: server, client, middleware, transport tuning.
- `sync`, `sync/atomic`: shared state and concurrency primitives.
- `runtime`, `runtime/pprof`, `runtime/metrics`: performance and memory.
- `log/slog`: default structured logging.
- `testing`: unit, benchmark, fuzz.

## Practical rules

- Every network or DB call should accept `context.Context`.
- Do not use unbounded goroutine spawning.
- Use `errgroup.WithContext` for fan-out work.
- Always inspect `allocs/op` and `B/op` in benchmarks before declaring a path optimized.

## Tool pinning

Use a `tools.go` pattern or CI install script with explicit versions.

```go
//go:build tools
package tools

import (
    _ "golang.org/x/vuln/cmd/govulncheck"
    _ "github.com/securego/gosec/v2/cmd/gosec"
)
```

Then keep versions pinned in `go.mod` or a tool lock mechanism.
