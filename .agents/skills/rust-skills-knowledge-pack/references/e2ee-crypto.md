# E2EE / Crypto Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates**: `rustls`, `rustls-graviola`, `graviola`, `ring`, `aes-gcm`, `chacha20poly1305`, `x25519-dalek`, `ed25519-dalek`, `argon2`, `hpke`, `hpke-rs`, `snow`, `jsonwebtoken`, `zeroize`

## Use Cases

- Public API TLS and mTLS.
- Application-layer payload E2EE.
- Agent/node identity, config signatures, and decision-log signatures.
- Password hashing, key wrapping, session keys, and storage encryption.

## Architecture

```text
public edge TLS: rustls
application payload: HPKE or Noise
identity: ed25519-dalek
session: x25519 ephemeral
AEAD: chacha20poly1305 or aes-gcm
password/key wrapping: argon2
secret cleanup: zeroize discipline
```

## Engineering Rules

- Separate public TLS from application payload encryption.
- Use ephemeral X25519 for session key agreement.
- Use Ed25519 for node, agent, config, and decision-log signatures.
- Choose AES-GCM when AES-NI is reliable; prefer ChaCha20-Poly1305 for broader CPU/mobile/anonymized-node contexts.
- Include version, sender, recipient, and message ID in associated data.
- Represent identity keys, session keys, storage keys, and signing keys as distinct types.
- Treat HPKE, `hpke-rs`, `snow`, `graviola`, and `rustls-graviola` as R&D unless audit, test vectors, provider choice, and fallback are complete.

## Forbidden Patterns

- Custom cryptography.
- Nonce reuse.
- Key-purpose reuse or identity/session/storage key confusion.
- Secret material in `Debug`, logs, traces, metrics, snapshots, or panic output.
- Promoting crypto provider changes without dependency and CPU-feature review.

## SLO / Review Metrics

- handshake latency.
- encrypt/decrypt throughput.
- key rotation success.
- nonce monotonicity validation.
- dependency C/FFI footprint.
- fuzz/property/vector test coverage.

## Update Checks

- Run `cargo audit` and `cargo deny`; inspect transitive dependencies, not just direct crates.
- For QUIC/HPKE/TLS, verify `quinn-proto`, `rustls-webpki`, `aws-lc-sys`, and `hpke-rs-rust-crypto` when present in `Cargo.lock`.
