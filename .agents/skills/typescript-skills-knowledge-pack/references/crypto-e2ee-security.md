# Crypto / E2EE / Security Reference

## Core stack

- `jose`: JWT/JWE/JWS/OIDC-level crypto.
- WebCrypto: browser-native cryptographic operations.
- `@noble/*`: low-level primitives where audited usage is clear.
- `@hpke/*`: HPKE family, Adopt/R&D until test vectors and interoperability pass.
- `libsodium-wrappers-sumo`: strong but operationally heavier option.

## Rules

- Do not invent crypto protocols.
- Always include key rotation, `kid`, algorithm pinning, issuer/audience validation, and clock-skew policy.
- E2EE payload crypto must have test vectors.
- Browser E2EE must account for XSS. Crypto does not protect secrets from compromised JS.
- Secret material must be redacted from logs and crash dumps.
