## Skill: rustskills-leptos-wasm-builder

### When to use

RustSkills UI、CRM dashboard、Web Builder、agent console、SSR + WASM UI、browser-side API連携を作るときに使う。

### Core principles

- `leptos` をfull-stack UIの中核にする。
- 重い処理はserver functions/APIへ逃がし、WASMにはUI stateと最小ロジックを載せる。
- `wasm-bindgen` / `web-sys` のfeatureは最小化する。
- signal粒度を小さくし、route dataを親子で分割する。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| W001 | leptos | 0.8.19 | Web/WASM | Core | Rust fullstack UI | https://docs.rs/crate/leptos/latest |
| W002 | leptos_router | 0.8.13 | Web/WASM | Core | Leptos routing | https://docs.rs/crate/leptos_router/latest |
| W003 | wasm-bindgen | 0.2.120 | Web/WASM | Core | Rust-JS boundary | https://docs.rs/crate/wasm-bindgen/latest |
| W004 | web-sys | 0.3.97 | Web/WASM | Core | Browser API binding | https://docs.rs/crate/web-sys/latest |
| W005 | gloo-net | 0.7.0 | Web/WASM | Core | WASM HTTP | https://docs.rs/crate/gloo-net/latest |
| W006 | tailwind_fuse | 0.3.2 | UI | Core | Tailwind class merge | https://docs.rs/tailwind_fuse |
| W007 | talc | 5.0.3 | Allocator/WASM | Adopt | no_std/WASM allocator | https://docs.rs/crate/talc/latest |
| W008 | smallvec | 1.15.1 | Memory | Adopt | 小Vecのstack最適化 | https://docs.rs/crate/smallvec/latest |
| W009 | bytemuck | 1.25.0 | Byte Cast | Adopt | POD byte casting | https://docs.rs/crate/bytemuck/latest |
| D004 | rkyv | 0.8.16 | Zero-copy Serde | Adopt | frozen snapshot | https://docs.rs/crate/rkyv/latest |
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E002 | tracing-subscriber | 0.3.23 | Observability | Adopt | log/JSON/filter | https://docs.rs/crate/tracing-subscriber/latest |

### Forbidden patterns

- 全画面・全DOMを巨大signalで再描画する。
- JS/WASM境界を細かい値で何千回も跨ぐ。
- WASMにDB/暗号/巨大解析ロジックを丸ごと持ち込む。
- `web-sys` featureを全部有効化する。

### Canonical architecture

```text
SSR shell
  -> route-level data loader
  -> small reactive islands
  -> server functions for heavy work
  -> gloo-net for client API
  -> wasm-bindgen/web-sys minimal boundary
```

### Implementation recipes

1. routeごとにloaderを分け、親Resourceを維持し、子だけ差し替える。
2. browser APIは必要featureだけをCargo.tomlで有効化する。
3. bulk transferにはTypedArray / bufferを使い、細かいJSONオブジェクトを大量に渡さない。
4. `smallvec` は状態数が少ない候補配列へ使う。
5. `talc` はWeb Builderのclient-heavy moduleでA/B testする。

### Benchmarks / SLOs

- compressed WASM size。
- hydration time。
- first interaction time。
- route transition latency。
- JS/WASM boundary calls。
- signal invalidation count。

### Update checklist

- `leptos` / `leptos_router` のbreaking changesとmigration guideを確認。
- `wasm-bindgen` / `web-sys` のgenerated bindings差分を確認。
- bundle size diffを必ず取る。

### Sources

- `rustskills_sources.md` の `W001-W009`, `D004`。

---
