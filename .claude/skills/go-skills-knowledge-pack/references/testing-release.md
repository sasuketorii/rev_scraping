# Testing / Release / Supply Chain

## Required tests

```bash
go test ./...
go test -race ./...
go vet ./...
staticcheck ./...
golangci-lint run
govulncheck ./...
gosec ./...
```

## Integration tests

Use `github.com/testcontainers/testcontainers-go` for PostgreSQL, Redis, NATS, Kafka, Qdrant, and other service dependencies. It is v0.x, so keep Watch.

## Assertions

- `github.com/google/go-cmp` for semantic diffs in tests.
- `github.com/stretchr/testify` for assertions/mocks where team accepts dependency surface.

## Release

- Build reproducibly.
- Pin Go version.
- Run `go mod verify`.
- Generate SBOM if required.
- Run `govulncheck` on source and optionally built binary.
- Capture benchmark deltas for hot path changes.

## Suggested CI gates

```bash
go mod tidy && git diff --exit-code go.mod go.sum
go mod verify
go test ./...
go test -race ./...
go vet ./...
govulncheck ./...
gosec -fmt sarif -out gosec.sarif ./...
golangci-lint run
staticcheck ./...
```
