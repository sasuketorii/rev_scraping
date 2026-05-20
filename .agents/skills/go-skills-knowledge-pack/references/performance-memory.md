# Performance / Memory

## Measurement first

Use:

```bash
go test -bench=. -benchmem ./...
go test -run=^$ -bench=BenchmarkName -benchmem -count=10 ./pkg/...
go tool pprof cpu.pprof
go tool pprof heap.pprof
```

## GC-aware patterns

- Reuse buffers with care.
- Prefer streaming over full materialization.
- Avoid `[]byte -> string -> []byte` round trips.
- Keep structs compact and avoid unnecessary pointers in hot structs.
- Use `sync.Pool` only for well-understood temporary objects.

## JSON hot path

Default: `encoding/json`.

Use `sonic` or `go-json` only after:

- golden compatibility tests,
- fuzz tests for malformed input,
- benchmark under realistic payloads,
- CPU architecture compatibility review.

## Worker pools

Go can spawn many goroutines, but massive uncontrolled goroutines still harm memory, scheduler, and tail latency.

Use:

- `errgroup.SetLimit`,
- semaphore,
- bounded channel,
- `ants` for high-churn goroutine pools.

## Container runtime

Use `go.uber.org/automaxprocs` when running in containers to align `GOMAXPROCS` with CPU quota.
