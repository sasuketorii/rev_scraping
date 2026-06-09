## Skill: rustskills-memory-performance

### When to use

メモリアロケーション、短命オブジェクト、HashMap hot path、共有設定、キャッシュ、並行Map、lock contention、zero-copy binary viewを最適化するときに使う。

### Core principles

- 標準実装で計測し、hot pathだけ最適化する。
- 小配列は `smallvec`、短命大量オブジェクトは `bumpalo`、共有設定は `arc-swap`、TTLキャッシュは `moka`、並行Mapは `dashmap` を候補にする。
- 外部入力を攻撃者が制御できる公開APIで `ahash` を安易に使わない。
- guard保持中await禁止。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| W008 | smallvec | 1.15.1 | Memory | Adopt | 小Vecのstack最適化 | https://docs.rs/crate/smallvec/latest |
| W009 | bytemuck | 1.25.0 | Byte Cast | Adopt | POD byte casting | https://docs.rs/crate/bytemuck/latest |
| D004 | rkyv | 0.8.16 | Zero-copy Serde | Adopt | frozen snapshot | https://docs.rs/crate/rkyv/latest |
| D005 | zerocopy | 0.8.48 | Binary View | Adopt | fixed binary header | https://docs.rs/crate/zerocopy/latest |
| M001 | tikv-jemallocator | 0.6.1 | Allocator | Adopt/Measure | Linux server allocator | https://docs.rs/crate/tikv-jemallocator/latest |
| M002 | bumpalo | 3.20.2 | Arena | Adopt | 一括破棄arena | https://docs.rs/crate/bumpalo/latest |
| M003 | ahash | 0.8.12 | Hashing | Adopt | internal fast hash | https://docs.rs/crate/ahash/latest |
| M004 | dashmap | 6.1.0 | Concurrent Map | Adopt | sharded map | https://docs.rs/crate/dashmap/latest |
| M005 | parking_lot | 0.12.5 | Lock | Adopt | lightweight lock | https://docs.rs/crate/parking_lot/latest |
| M006 | arc-swap | 1.9.1 | Lock-free Config | Adopt | hot reload config | https://docs.rs/crate/arc-swap/latest |
| M007 | moka | 0.12.15 | Cache | Adopt | async cache | https://docs.rs/crate/moka/latest |
| M008 | once_cell | 1.21.4 | Lazy Init | Adopt | static selectors/config | https://docs.rs/crate/once_cell/latest |

### Forbidden patterns

- `Arc<Mutex<HashMap<...>>>` を全hot pathの万能解にする。
- lock内でawait、I/O、JSON parse、DBアクセスをする。
- 大量の短命 `String` / `Vec` / `HashMap` を無計画に生成する。
- `unsafe` castでバイナリを読む。

### Canonical architecture

```text
profile first
  -> classify bottleneck: copy / alloc / lock / parse / I/O
  -> choose small targeted primitive
  -> benchmark before/after
  -> document decision in Master
```

### Implementation recipes

1. configやprompt templateは `ArcSwap<Config>` でimmutable snapshotとして差し替える。
2. 1ページ/1リード/1イベントバッチ単位の一時データは `bumpalo` arenaへ逃がす。
3. `DashMap` guardは即dropし、値は `Arc` で外に出してからawaitする。
4. `Bytes` / `zerocopy` / `bytemuck` は境界検証とalignmentを明示して使う。
5. `tikv-jemallocator` は対象バイナリ限定で計測する。

### Benchmarks / SLOs

- allocations/op。
- lock contention。
- RSS / fragmentation。
- p99 latency。
- cache hit rate。
- CPU flamegraph上のallocator比率。

### Update checklist

- feature追加で依存が膨らんでいないか確認。
- allocatorやlock primitiveのMSRVとplatform制約を確認。
- benchmarkなしの最適化PRを拒否する。

### Sources

- `rustskills_sources.md` の `M001-M008`, `A007`, `D004-D005`, `W008-W009`。

---
