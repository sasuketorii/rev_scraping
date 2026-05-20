# API / Backend / RPC

## Default stack

- `net/http` as protocol core.
- `github.com/go-chi/chi/v5` for router/middleware.
- `connectrpc.com/connect` for type-safe RPC with browser support.
- `google.golang.org/grpc` for classic gRPC interoperability.
- `github.com/danielgtaylor/huma/v2` for REST + OpenAPI 3.1.

## chi lane

Use chi when you need minimal, idiomatic HTTP APIs.

```text
Request
  -> request id
  -> body size limit
  -> auth
  -> timeout
  -> otel span
  -> handler
```

Rules:

- Route handlers stay thin.
- Business logic lives in service structs.
- All handlers use context deadline.
- Response schemas are explicit.

## Connect lane

Use Connect when you want:

- typed contracts,
- gRPC compatibility,
- gRPC-Web/browser friendliness,
- less ceremony than classic gRPC.

## gRPC lane

Use grpc-go when:

- existing platform already speaks gRPC,
- streaming RPC is essential,
- proto contracts are cross-language truth.

## Huma lane

Use Huma when:

- OpenAPI 3.1 output matters,
- schema-first API docs are central,
- REST remains the public API surface.

## Anti-patterns

- `http.Client` per request.
- no timeout on outbound calls.
- middleware that reads entire body without size limit.
- logging raw Authorization headers.
- huge response maps instead of typed DTOs.
