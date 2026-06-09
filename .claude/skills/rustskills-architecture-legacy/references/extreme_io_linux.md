## Skill: rustskills-extreme-io-linux

### When to use

標準Tokio/reqwestレーンでSLOを満たせず、Linux専用・高密度I/O・低tail latency・大規模スプール/ログI/Oが必要なときにのみ使う。

### Core principles

- R&Dレーンとして扱い、本番では標準レーンへfallback可能にする。
- `tokio-uring` / `monoio` はLinux専用・成熟度監視対象。
- per-core worker、fixed buffer、zero-copy send、thread affinityは計測後に導入する。
- allocator変更は全体へ一括適用せず、対象バイナリごとにA/B testする。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| A008 | hyper | 1.9.0 | Low-level HTTP | Adopt | 高性能HTTP hot path | https://docs.rs/crate/hyper/latest |
| A009 | tokio-uring | 0.5.0 | io_uring | R&D | Linux専用I/O | https://docs.rs/crate/tokio-uring/latest |
| A010 | monoio | 0.2.4 | Thread-per-core | R&D | io_uring / shared-nothing | https://docs.rs/crate/monoio/latest |
| D003 | simd-json | 0.17.0 | JSON/SIMD | Adopt | JSON hot path | https://docs.rs/crate/simd-json/latest |
| M001 | tikv-jemallocator | 0.6.1 | Allocator | Adopt/Measure | Linux server allocator | https://docs.rs/crate/tikv-jemallocator/latest |
| M002 | bumpalo | 3.20.2 | Arena | Adopt | 一括破棄arena | https://docs.rs/crate/bumpalo/latest |
| M003 | ahash | 0.8.12 | Hashing | Adopt | internal fast hash | https://docs.rs/crate/ahash/latest |
| M008 | once_cell | 1.21.4 | Lazy Init | Adopt | static selectors/config | https://docs.rs/crate/once_cell/latest |
| U008 | criterion | 0.8.2 | Benchmark | Tool | statistical benchmark | https://docs.rs/crate/criterion/latest |
| U009 | iai-callgrind | 0.16.1 | Benchmark | Tool | instruction-level benchmark | https://docs.rs/crate/iai-callgrind/latest |
| U010 | pprof | 0.15.0 | Profiling | Tool | CPU profiling | https://docs.rs/crate/pprof/latest |

### Forbidden patterns

- 測定なしで `tokio-uring` / `monoio` を標準化する。
- portabilityが必要なバイナリへLinux専用runtimeを混ぜる。
- `unsafe` やunchecked zero-copyを検証なしで使う。
- allocatorで悪い設計を隠す。

### Canonical architecture

```text
standard control plane
  -> prepared payload / static config
  -> per-core extreme worker
  -> fixed buffer pool
  -> hyper or io_uring I/O
  -> minimal parser / simd-json if measured
  -> compact event sink
```

### Implementation recipes

1. まず標準レーンでprofileし、ボトルネックがI/O、alloc、JSON、syscall、DBのどれかを特定する。
2. `simd-json` はmutable bufferを所有できる解析workerに限定する。
3. `rkyv` / `zerocopy` / `bytemuck` はデータ境界の型安全性をレビューしてから使う。
4. `tikv-jemallocator` はRSS、p99、allocations/opを旧版比較する。
5. canaryで1% trafficを流し、fallback可能性を保つ。

### Benchmarks / SLOs

- CPU util、syscalls/sec、RSS、page faults、allocations/op。
- p99/p999 latency。
- throughput per core。
- perf flamegraph / pprof / iai-callgrind差分。

### Update checklist

- kernel要件、MSRV、runtime interop、docs build、yanked情報を確認。
- zero-copy API変更やfixed buffer API変更を確認。
- allocator featureがprofiling用に膨らんでいないか確認。

### Sources

- `rustskills_sources.md` の `A009-A010`, `D003-D005`, `M001-M003`, `U008-U010`。

---
