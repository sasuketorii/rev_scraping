# Async I/O Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates**: `tokio`, `reqwest`, `tower`, `tower-http`, `axum`, `governor`, `bytes`, `tracing`, `tracing-subscriber`

## Use Cases

- API servers, job workers, LLM/API communication, DB access, and TUI event handling.
- High-load HTTP control planes where rate limits, retries, timeouts, and audit events matter.
- Shared async foundation for crawler/form sender, AI/data, E2EE proxy, and realtime agent lanes.

## Canonical Architecture

```text
Input Source
  -> bounded queue
  -> domain/account/campaign limiter
  -> tower Service stack
  -> reqwest or measured hyper sender
  -> result classifier
  -> audit log / metrics / retry queue
```

## Engineering Rules

- Reuse long-lived `reqwest::Client` instances; never create a client per request.
- Bound concurrency with `Semaphore`, `tower::limit`, and `governor`.
- Put timeouts on every external I/O boundary.
- Use `tower::Service` / `Layer` for timeout, retry, rate limit, concurrency, request ID, and tracing.
- Keep retry policy tied to an explicit failure classifier.
- Prefer `Bytes` / `BytesMut` for I/O payload boundaries.
- Use `CancellationToken` or equivalent structured shutdown.
- Send CPU-heavy work to `rayon`, `spawn_blocking`, or dedicated workers.

## Forbidden Patterns

- Unbounded `spawn`.
- Unbounded channels.
- Holding lock or `DashMap` guards across `.await`.
- Large `fetch_all` / `collect()` calls before the data boundary is justified.
- Logging PII, secrets, tokens, key material, or sensitive inference data.

## SLO / Review Metrics

- p50 / p95 / p99 latency.
- queue depth and backpressure behavior.
- retry, timeout, skipped, and dead-letter counts.
- RSS and allocations/op.
- per-host, per-account, per-campaign concurrency.

## Update Checks

- Verify MSRV, default features, TLS features, HTTP/2 behavior, runtime behavior, and transitive advisories.
- For dependency decisions, update `../rust-skills-master.md` first, then propagate this lane reference if the master changes.
