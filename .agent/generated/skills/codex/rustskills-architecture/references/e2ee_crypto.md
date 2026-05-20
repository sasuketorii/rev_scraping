## Skill: rustskills-e2ee-crypto

### When to use

OpenSSL依存を避けたTLS、アプリケーションレベルE2EE、Noise mesh、HPKE封筒暗号、署名付きエージェントログ、鍵交換、JWT認証を扱うときに使う。

### Core principles

- 公開エッジTLSとアプリケーションE2EEを分ける。
- `rustls` は公開TLS標準、E2EE payloadは `hpke` / `hpke-rs` / `snow` / `chacha20poly1305` などで別設計する。
- identity key、session key、storage key、JWT signing keyを型で分ける。
- nonce再利用、secret Debug、鍵素材ログ出力を禁止する。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| C001 | rustls | 0.23.40 | TLS | Core | TLS 1.2/1.3 | https://docs.rs/crate/rustls/latest |
| C002 | ring | 0.17.14 | Crypto | Conditional | 既存TLS/crypto依存 | https://docs.rs/crate/ring/latest |
| C003 | graviola | 0.3.4 | Crypto Provider | R&D | Rustls provider candidate | https://docs.rs/graviola |
| C004 | rustls-graviola | 0.3.4 | Crypto Provider | R&D | rustls integration | https://docs.rs/rustls-graviola |
| C005 | aes-gcm | 0.10.3 | AEAD | Core | AES-GCM | https://docs.rs/crate/aes-gcm/latest |
| C006 | chacha20poly1305 | 0.10.1 | AEAD | Adopt | ChaCha20-Poly1305 | https://docs.rs/crate/chacha20poly1305/latest |
| C007 | x25519-dalek | 2.0.1 | KEX | Core | X25519鍵交換 | https://docs.rs/crate/x25519-dalek/latest |
| C008 | ed25519-dalek | 2.2.0 | Signature | Adopt | Ed25519署名 | https://docs.rs/crate/ed25519-dalek/latest |
| C009 | argon2 | 0.5.3 | KDF | Core | password hashing/KDF | https://docs.rs/crate/argon2/latest |
| C010 | hpke | 0.13.0 | HPKE | R&D | Pure Rust HPKE | https://docs.rs/crate/hpke/latest |
| C011 | hpke-rs | 0.6.1 | HPKE | R&D | flexible backend HPKE | https://docs.rs/hpke-rs |
| C012 | snow | 0.10.0 | Noise | Adopt/R&D | Noise protocol | https://docs.rs/crate/snow/latest |
| C013 | jsonwebtoken | 10.3.0 | Auth | Core | JWT | https://docs.rs/crate/jsonwebtoken/latest |
| D001 | serde | 1.0.228 | Serialization | Core | 型付きserde | https://docs.rs/crate/serde/latest |
| D002 | serde_json | 1.0.149 | JSON | Core | JSON baseline | https://docs.rs/crate/serde_json/latest |
| D005 | zerocopy | 0.8.48 | Binary View | Adopt | fixed binary header | https://docs.rs/crate/zerocopy/latest |

### Forbidden patterns

- 自作暗号。
- nonceを乱数だけに任せ、再利用検証をしない実装。
- key materialを `Debug` / `Clone` / logへ漏らす設計。
- C/FFI依存を把握せず秘匿バイナリへ混入させる。
- audit status不明の暗号crateを本番標準化する。

### Canonical architecture

```text
public edge TLS: rustls
  -> application payload layer: HPKE or Noise
  -> identity: ed25519-dalek
  -> session: ephemeral x25519
  -> AEAD: chacha20poly1305 or aes-gcm
  -> password/key wrapping: argon2
  -> token auth: jsonwebtoken where appropriate
```

### Implementation recipes

1. AEADのAADに `protocol_version`, `sender`, `recipient`, `message_id`, `key_id` を入れる。
2. nonceはsessionごとの単調counter + direction bit + domain separationで設計する。
3. `ed25519-dalek` でagent decision log、config manifest、snapshot manifestへ署名する。
4. `graviola` / `rustls-graviola` はR&Dとしてprovider差し替え、CPU feature、interop、production readinessを確認する。
5. `snow` はNoise patternを固定し、handshake transcriptとtransport stateの境界を明示する。

### Benchmarks / SLOs

- handshake latency。
- encrypt/decrypt throughput。
- key rotation success。
- nonce violation zero。
- dependency C/FFI footprint。
- fuzz/property/vector test coverage。

### Update checklist

- RustSec、GitHub Advisory、upstream security notesを確認。
- CryptoProvider、C/FFI依存、CPU feature、audit statusを確認。
- RFC/標準文書との整合を確認。
- test vectors / Wycheproof相当の検証を検討。

### Sources

- `rustskills_sources.md` の `C001-C013`, `D005`。

---
