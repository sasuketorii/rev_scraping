## Skill: rustskills-tui-realtime-audio-agent

### When to use

Ratatuiベースの営業支援AI、OSマイク音声取得、ASR/LLMストリーミング、リアルタイムトークスクリプト表示、terminal dashboardを作るときに使う。

### Core principles

- `cpal` callback内ではalloc、lock、I/O、JSON parse、network sendをしない。
- callbackからasync世界へは `ringbuf` SPSCで渡す。
- TUI描画はLLM token到着ごとではなく、render tickで間引く。
- 音声、ASR、LLM、UI、loggingをspanで分解して観測する。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A001 | tokio | 1.52.1 | Async I/O | Core | 非同期ランタイム | https://docs.rs/crate/tokio/latest |
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| A008 | hyper | 1.9.0 | Low-level HTTP | Adopt | 高性能HTTP hot path | https://docs.rs/crate/hyper/latest |
| T001 | ratatui | 0.30.0 | TUI | Core | TUI rendering | https://docs.rs/crate/ratatui/latest |
| T002 | crossterm | 0.29.0 | TUI | Core | terminal backend | https://docs.rs/crate/crossterm/latest |
| T003 | cpal | 0.17.3 | Audio | Core | cross-platform audio I/O | https://docs.rs/crate/cpal/latest |
| T004 | ringbuf | 0.4.8 | Audio | Adopt | lock-free SPSC FIFO | https://docs.rs/crate/ringbuf/latest |
| T005 | symphonia | 0.5.5 | Audio | Adopt | pure Rust audio decode | https://docs.rs/crate/symphonia/latest |
| T006 | audio_thread_priority | 0.35.1 | Audio | Adopt | audio RT priority | https://docs.rs/crate/audio_thread_priority/latest |
| T007 | tokio-util | 0.7.18 | Async Utility | Core | cancellation/codec | https://docs.rs/crate/tokio-util/latest |
| T008 | reqwest-eventsource | 0.6.0 | Streaming | Core | SSE client | https://docs.rs/crate/reqwest-eventsource/latest |
| T009 | flume | 0.12.0 | Channel | Adopt | sync/async MPMC | https://docs.rs/crate/flume/latest |
| T010 | crossbeam | 0.8.4 | Concurrency | Adopt | queues/epoch/channel | https://docs.rs/crate/crossbeam/latest |
| C012 | snow | 0.10.0 | Noise | Adopt/R&D | Noise protocol | https://docs.rs/crate/snow/latest |
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E002 | tracing-subscriber | 0.3.23 | Observability | Adopt | log/JSON/filter | https://docs.rs/crate/tracing-subscriber/latest |

### Forbidden patterns

- CPAL callback内で `Vec` 再確保やmutex取得。
- 音声とUIを同一ループで処理する。
- token到着ごとの全画面再描画。
- unbounded channelで音声フレームを貯める。

### Canonical architecture

```text
cpal callback
  -> ringbuf SPSC
  -> audio worker: frame / resample / VAD / encode
  -> ASR or LLM streaming transport
  -> event reducer
  -> ratatui render tick
  -> structured trace/log
```

### Implementation recipes

1. 固定フレームサイズを決め、partial sampleを下流へ漏らさない。
2. `ringbuf` のoccupancy、overflow、underflowをメトリクス化する。
3. render loopは30〜60Hz程度へ制限し、表示用文字列はpre-format bufferへ置く。
4. SSEは `reqwest-eventsource`、多ストリーム/低遅延が必要なら `quinn` をR&D導入する。
5. 圧縮音声が必要な場合だけ `symphonia` を導入し、生PCMだけなら余計なdecode層を入れない。

### Benchmarks / SLOs

- audio callback duration。
- ring buffer occupancy。
- underrun / overrun。
- ASR chunk latency。
- LLM first-token latency。
- render FPS / dropped frames。

### Update checklist

- OS別CPAL backend変更を確認。
- `ratatui` breaking changesとrender API変更を確認。
- `ringbuf` は0.4.8を採用候補にし、crates.io上の0.4.9 yankedを採用しない。

### Sources

- `rustskills_sources.md` の `T001-T010`, `A007`, `E001-E002`。

---
