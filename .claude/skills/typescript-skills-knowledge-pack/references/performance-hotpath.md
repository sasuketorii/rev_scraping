# Performance Hot Path Reference

## JavaScript hot-path rules

- Avoid allocating inside tight loops.
- Reuse HTTP clients, queues, schema validators, and browser contexts.
- Use worker threads/Piscina for CPU-bound tasks.
- Prefer streaming and backpressure over whole-body buffering.
- Use `tinybench` for microbenchmarks and production-like load tests for macro decisions.

## Boundary to Rust

Move to Rust sidecar/N-API/WASM when:

- realtime audio callback safety matters,
- SIMD/zero-copy parsing matters,
- cryptographic key handling must be more tightly controlled,
- Node event loop is the bottleneck,
- GC jitter breaks latency SLO.

## Metrics

Track p50/p95/p99 latency, event loop delay, memory RSS, heap usage, browser context count, request success/failure, retry rate, and queue depth.
