# CLI / TUI / Audio-adjacent Operations

## CLI

Use `github.com/spf13/cobra` for production CLI.

Rules:

- `RunE` instead of `Run` when errors matter.
- Config precedence: CLI flag > env > config file > default.
- Output machine-readable JSON mode for automation.
- Never print secrets.

## TUI

Charm v2 stack:

- `charm.land/bubbletea/v2` for runtime.
- `charm.land/lipgloss/v2` for styling.
- `charm.land/bubbles/v2` for components.

Design:

```text
Model = immutable-ish app state
Update = event handling and state transition
View = pure rendering
Effects = async command boundaries
```

Keep network calls and LLM streams out of `View`.

## Audio note

Go can build operational TUI and streaming client tools, but ultra-low-latency raw audio is still better served by Rust for CPAL/ringbuf-level control. In Go, prefer delegating real-time capture to Rust/native helper or use a platform-specific library only after latency tests.
