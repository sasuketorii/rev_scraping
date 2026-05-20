# AI Agents / MCP / LLM

## OpenAI lane

Use official `github.com/openai/openai-go/v3` for OpenAI API access.

Rules:

- API key from environment or secret manager.
- No raw secrets in logs.
- Stream processing should be cancellable through context.
- Responses/tool calls should be typed and auditable.

## Agent orchestration

Recommended split:

```text
LLM client
  -> typed tool registry
  -> policy / permission check
  -> durable tool execution
  -> event log
  -> retrieval context
  -> response streaming
```

## MCP lane

- Official `github.com/modelcontextprotocol/go-sdk` v1.6.0 is the first Adopt target for MCP client/server implementation.
- Community `mark3labs/mcp-go` can be used after version and API stability review.

MCP adoption rules:

- tool schemas must be explicit,
- side-effecting tools require approval policy,
- tool call logs are immutable,
- secrets are not exposed through tool metadata.

## LangChain Go lane

`github.com/tmc/langchaingo` is useful for experiments, but keep R&D status because it is v0.x and fast-moving.

## Retrieval lane

- PostgreSQL + pgvector for integrated state/search.
- Qdrant for dedicated vector search and high-dimensional retrieval.
- Always maintain IDs that map vector hits back to durable records.
