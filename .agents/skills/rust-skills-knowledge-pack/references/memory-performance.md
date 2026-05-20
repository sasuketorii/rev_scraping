# Memory / Performance Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates/tools**: `bytes`, `rkyv`, `simd-json`, `tikv-jemallocator`, `talc`, `smallvec`, `bumpalo`, `ahash`, `dashmap`, `parking_lot`, `arc-swap`, `moka`, `once_cell`, `criterion`, `iai-callgrind`, `pprof`, `cargo-bloat`

## Use Cases

- Hot-path payload movement, JSON parsing, and frozen snapshots.
- Allocation pressure reduction in high-load workers and WASM.
- Low-latency shared config, cache, and concurrent map access.
- Benchmark and profile-driven dependency adoption.

## Engineering Rules

- Prefer `Bytes` / `BytesMut` at I/O boundaries to reduce clones.
- Use `simd-json` only after profiling proves JSON parsing is the bottleneck.
- Use `rkyv` for immutable snapshots with schema versions and validation.
- Use `tikv-jemallocator` only for measured Linux server allocation pressure.
- Use `talc` only after WASM size/runtime A/B testing.
- Use `bumpalo` for batch/page/lead arenas with clear lifetime boundaries.
- Use `arc-swap` for immutable hot-reload config.
- Use `moka` for bounded TTL/cache behavior.

## Forbidden Patterns

- Allocator swaps without before/after RSS, allocation, latency, and binary-size measurements.
- `DashMap` guard held across `.await`.
- `ahash` for attacker-controlled external keys without review.
- unchecked `rkyv` reads outside measured and validated hot paths.
- Large JSON deserialization or response body collection before data boundaries are justified.

## SLO / Review Metrics

- allocations/op.
- RSS and peak memory.
- p95 / p99 hot-path latency.
- binary size and WASM compressed size.
- snapshot load time.
- instruction count or CPU profile for hot paths.

## Update Checks

- Run `criterion` / `iai-callgrind` / `pprof` for hot-path changes.
- Use `cargo bloat` or equivalent when binary/WASM size is a decision factor.
- Record benchmark impact in `../rust-skills-master.md` before promoting an optimization.
