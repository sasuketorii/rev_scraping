# AI Agent / Realtime Reference

## Core stack

- `openai`: official TypeScript/JavaScript API client.
- `@openai/agents`: official TypeScript Agents SDK for orchestration/tools/handoffs.
- `ai` and `@ai-sdk/openai`: streaming UI/provider abstraction.
- `@langchain/langgraph`: graph workflows.
- `@modelcontextprotocol/sdk`: MCP tools/connectors.
- `eventsource` / `ws`: stream transport.

## Architecture

```text
user/input/audio/event
  -> typed schema validation
  -> bounded tool executor
  -> OpenAI SDK / Agents SDK / AI SDK / LangGraph
  -> stream result
  -> audit span
  -> UI/TUI/web update
```

## Rules

- Tool calls must be schema-typed and timeout-bounded.
- Streaming must support cancellation.
- Never log prompts containing secrets/PII without redaction.
- Voice/audio hot path should be Rust sidecar/N-API/WASM if low latency matters.
- Add evals before changing model, system prompt, or tool policy.
