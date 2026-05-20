# Crawler / Form Sender Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates**: `tokio`, `reqwest`, `tower`, `governor`, `bytes`, `hyper`, `scraper`, `serde_urlencoded`, `polars`, `tracing`
- **Browser escalation**: `chromiumoxide` only when `reqwest + scraper` cannot observe the required JS-rendered state.

## Use Cases

- Authorized bulk target processing, business form extraction, and controlled form submission.
- Valid load tests against owned or explicitly permitted systems.
- Lead/list preprocessing from CSV, Parquet, or DB inputs.

## Standard Architecture

```text
CSV/Parquet/DB input
  -> Polars lazy preprocess
  -> bounded async queue
  -> per-host/per-account governor limiter
  -> tower Service stack
  -> reqwest Client pool
  -> response classifier
  -> sqlx audit / surrealdb state
  -> retry/dead-letter queue
```

## Hot Path Option

```text
prepared payloads
  -> BytesMut template expansion
  -> hyper sender shard
  -> per-core worker
  -> simd-json response parse if measured necessary
  -> spool/log path if measured beneficial
```

## Engineering Rules

- Static HTML and ordinary forms use `reqwest + scraper`.
- Pre-encode stable form bodies with `serde_urlencoded` where possible.
- Model rate limits at host, account, campaign, and global levels.
- Add target allowlist/policy checks before dispatch.
- Classify success, retryable failure, permanent failure, skipped, timeout, and policy-denied results.
- Attach trace/job IDs to every send attempt and audit event.
- Use browser automation only for authorized JS-rendered pages, SPA forms, screenshots, or QA.

## Forbidden Patterns

- Unauthorized bulk sending or any design meant to bypass service protections.
- Unbounded queues or unbounded task fan-out.
- Per-request HTTP client construction.
- Missing timeout, retry budget, rate limit, or stop switch.
- PII, hidden tokens, credentials, or secrets in logs.

## SLO / Review Metrics

- p50 / p95 / p99 request latency.
- success, failure, retry, skipped, timeout, and policy-denied counts.
- per-host concurrency and queue depth.
- RSS, allocations/op, and timeout rate.
- external backoff reasons and dead-letter volume.
