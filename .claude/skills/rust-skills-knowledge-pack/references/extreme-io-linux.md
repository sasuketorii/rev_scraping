# Extreme Linux I/O Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates**: `hyper`, `bytes`, `tokio-uring`, `monoio`, `simd-json`, `tikv-jemallocator`, `moka`, `dashmap`

## Use Cases

- Linux-only high-density HTTP workers.
- Response spool, log/cache I/O, and batch ingest paths.
- JSON or payload hot paths proven by profiling to be bottlenecks.

## Standard Difference

- Prioritize measured throughput and tail latency over portability only for isolated hot paths.
- Replace `reqwest` convenience with thin `hyper` senders only when the standard lane loses under benchmark.
- Use `Bytes` as the shared payload boundary.
- Use `simd-json` only where `serde_json` is measured as the bottleneck.
- Start `tokio-uring` and `monoio` as R&D, not default production runtime choices.

## Adoption Conditions

- Linux kernel and deployment target are fixed and documented.
- p95 / p99, RSS, CPU, allocation count, and syscall metrics beat the standard Tokio lane.
- Standard Tokio fallback exists and can be switched during incident response.
- Operational behavior, metrics, and failure modes are understood before production promotion.

## Architecture

```text
prepared payloads
  -> BytesMut template expansion
  -> hyper sender shard
  -> Linux-specific worker model
  -> simd-json parse if profiled necessary
  -> spool/cache/log I/O experiment
  -> benchmark and fallback gate
```

## Forbidden Patterns

- Making Linux-specific runtime code the only implementation path.
- Adopting io_uring/thread-per-core because it is novel rather than measured.
- Holding `DashMap` guards across `.await`.
- Adding allocator/runtime changes without RSS, allocation, and tail-latency baselines.

## SLO / Review Metrics

- p95 / p99 latency and throughput.
- RSS and allocations/op.
- CPU utilization and syscall count.
- spool/cache I/O latency.
- fallback success under controlled failover.
