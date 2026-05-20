# Crypto / Security / E2EE

## Default

Use Go standard crypto first:

- `crypto/tls` for TLS/mTLS
- `crypto/rand` for randomness
- `crypto/ed25519`, `crypto/ecdh`, `crypto/aes`, `crypto/cipher` as applicable
- `golang.org/x/crypto` for supplemental primitives

## R&D / advanced

- `github.com/cloudflare/circl`: PQ/ECC experimental deployment. Use with caution; project itself warns that experimental content may change.
- `github.com/flynn/noise`: Noise Protocol Framework implementation. Use only after protocol pattern review.
- `filippo.io/age`: file encryption lane; version check required before pinning.

## Non-negotiable rules

- No custom crypto protocol without review.
- Nonce reuse is a critical failure.
- Keys have roles: identity, session, wrapping, signing, encryption.
- Log redaction is mandatory.
- Store key IDs and algorithm IDs in envelopes.
- AAD should include protocol version, sender/recipient IDs, message type, and context.

## E2EE lane shape

```text
transport TLS/mTLS
  + app-level envelope encryption
  + signed metadata
  + key rotation
  + immutable audit log
```

For high anonymity or C-dependency-sensitive cases, Rust may remain the primary implementation language. Go can still serve control planes, gateways, CLI, and orchestration.
