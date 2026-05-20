# Messaging / Workflows

## NATS

Use `github.com/nats-io/nats.go` for:

- event bus,
- lightweight pub/sub,
- JetStream streams,
- agent event fan-out,
- internal control signals.

Rules:

- Define stream/subject naming convention.
- Use durable consumers for important workflows.
- Use request-reply only for low-latency control paths.

## Temporal

Use `go.temporal.io/sdk` for:

- durable workflows,
- retries with state,
- long-running agent tasks,
- human-in-the-loop workflows,
- CRM automations.

Rules:

- Workflow code must be deterministic.
- Activities do side effects.
- Idempotency is mandatory.

## Asynq

Use `github.com/hibiken/asynq` for Redis-backed task queues when Temporal is too heavy. It is v0.x, so Watch.

## Kafka-Go

Use `github.com/segmentio/kafka-go` when Kafka is mandatory and cgo/librdkafka is undesirable. It is v0.x; keep Watch/R&D.
