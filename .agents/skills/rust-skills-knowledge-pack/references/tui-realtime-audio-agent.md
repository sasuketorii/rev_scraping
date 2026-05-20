# TUI Realtime Audio Agent Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Registry recheck**: 2026-05-06 JST spot-check shows `ringbuf` v0.5.0.
- **Primary crates**: `ratatui`, `crossterm`, `cpal`, `ringbuf`, `symphonia`, `audio_thread_priority`, `tokio-util`, `flume`, `crossbeam`, `reqwest-eventsource`, `quinn`

## Use Cases

- Inside-sales realtime assistance over terminal UI.
- OS microphone capture, ASR/LLM streaming, and live script/state display.
- SSH-friendly dashboards for voice and agent workflows.

## Architecture

```text
OS mic
  -> cpal callback
  -> lock-free SPSC ring buffer
  -> frame normalizer / VAD / encoder
  -> LLM/ASR streaming client
  -> event reducer
  -> ratatui render tick
```

## Engineering Rules

- CPAL callback code copies samples only.
- Callback code must be allocation-free, non-blocking, and network-free.
- Use `ringbuf` for SPSC audio transfer from callback to worker.
- Separate audio input, ASR/LLM stream, key input, state reducer, and render tasks.
- Render on ticks, not every token.
- Use conversation-level trace IDs and latency budgets.
- Treat QUIC as R&D unless multi-stream transport requirements justify it.

## Forbidden Patterns

- Allocation, mutex lock, JSON parsing, HTTP, or heavy logging in the audio callback.
- Drawing the TUI for every streamed token.
- Mixing audio callback state and async networking state.
- Pinning yanked `ringbuf` versions.

## SLO / Review Metrics

- audio callback duration.
- ring buffer occupancy, underrun, and overrun.
- ASR chunk latency.
- LLM first-token latency.
- render FPS and dropped frames.
- end-to-end turn latency.

## Update Checks

- Verify `ringbuf` docs.rs/latest and crates.io yanked status before changing versions.
- For existing audio pipelines, treat `ringbuf` 0.4.x -> 0.5.x as an API/behavior review item, not a blind patch bump.
- Check OS permissions and stability before adopting `audio_thread_priority`.
- For QUIC, verify `quinn-proto` transitive advisory status in `Cargo.lock`.
