# Observability / Governance

## Logs

Default: `log/slog`.

Performance alternatives:

- `go.uber.org/zap`
- `github.com/rs/zerolog`

Rules:

- Use structured fields.
- Include request/job/agent/tool IDs.
- Never log secrets, tokens, raw authorization headers, or decrypted payloads.

## Traces

Use OpenTelemetry.

Trace:

- inbound request,
- outbound HTTP,
- DB query,
- LLM call,
- tool call,
- workflow activity,
- browser automation step.

## Metrics

Use Prometheus client.

Required metrics:

- request latency histogram,
- outbound request latency/error,
- queue depth,
- rate limiter waits,
- goroutine count,
- heap allocation,
- DB pool saturation,
- workflow retry count.

## Update governance

Every update must record:

- source URL,
- version,
- release date,
- stability tier,
- security advisory check,
- lockfile impact,
- benchmark impact if hot path.
