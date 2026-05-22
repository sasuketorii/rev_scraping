以下はファイル変更なしの圧縮 ExecPlan です。現 checkout は `967a292...` で、`v1.2.0` tag は `b2153aa0` と確認しました。確認済み根拠: 13 crate/MSRV/unsafe forbid は [Cargo.toml]($REPO_ROOT/Cargo.toml:8)、v1.2.0 776 PASS/16 MCP tool/5 systemd unit は [RELEASE_NOTES_v1.2.0.md]($REPO_ROOT/RELEASE_NOTES_v1.2.0.md:11)、cookie 暗号は [crypto.rs]($REPO_ROOT/crates/stealth-auth/src/crypto.rs:45) と [keystore.rs]($REPO_ROOT/crates/stealth-auth/src/keystore.rs:20)、JA4 は現状 placeholder です [measure.rs]($REPO_ROOT/crates/stealth-cli/src/commands/measure.rs:8)。未実行: `cargo test`。

## Section 0: 9/10 基準
- 軸1 9/10: TPM2 sealed cookie DEK、`epoch` 世代、オンライン rotation、HMAC-chain/Merkle audit、hardware identity、break-glass recovery、tamper test。10/10 は FIPS/HSM vendor certification まで行くので過剰。効く相手は SOC/forensic 運用。
- 軸2 9/10: deb/rpm/Homebrew/PKGBUILD、Docker/Podman/Helm、Terraform/Ansible、SBOM+cosign+attestation、backup/restore drill、Prometheus/Grafana/OTel、`/healthz` `/readyz`、semver/deprecation。10/10 は managed SaaS/multi-region。
- 軸3 9/10: JA3/JA4/H2/H3 が real browser 差分閾値内、Sec-CH-UA 整合、Canvas/WebGL/Audio active policy、behavior model、residential proxy adapter、CreepJS/FingerprintJS/IPQS CI、Cloudflare/Akamai/DataDome は許可済み fixture のみ。10/10 は arms race と非公開 bot vendor 契約。
- 軸4 9/10: coverage 85/75、proptest 全 crate、cargo-fuzz 3境界、cargo-mutants mutation score gate、compose e2e、MSRV CI、cargo-audit/deny、perf regression、chaos e2e。
- 軸5 9/10: docs site、5-7段階 tutorial、ADR、rustdoc deploy、error dictionary、SECURITY/CONTRIBUTING/RFC 完備、MCP playground、i18n 6言語、quarterly competitor matrix。

## Section 1: Axis 1 Crypto Plan
Gap: XChaCha20-Poly1305 + keyring/Argon2id は確認済みだが、TPM sealed key、epoch rotation、tamper-evident audit は未実装。`SECURITY.md` は v1.2.0 後も `1.1.x current` と placeholder contact のままなので要修正 [SECURITY.md]($REPO_ROOT/SECURITY.md:13)。

Sub-phase G1-G10, 各 0.5-1.0d:
G1 envelope v2 `{epoch,kek_id,aad}` schema。accept: v1 decrypt compat test。
G2 Linux TPM2 sealed KEK backend。accept: TPMあり integration、なし skip。
G3 systemd-creds PCR policy hardening。accept: signed PCR decrypt success/fail。
G4 macOS Secure Enclave/YubiKey design spike。accept: backend trait + unsupported errors。
G5 rotation CLI/job。accept: N profiles reencrypt, rollback snapshot。
G6 background rotation lock。accept: concurrent load/save race test。
G7 HMAC-chain audit JSONL v2。accept: deletion/reorder tamper fails。
G8 Merkle periodic root file。accept: root verification tool。
G9 break-glass recovery doc/test. accept: passphrase-only recovery fixture。
G10 security review. Reviewer: security reviewer + external SOC if available。Risk: locked-out profiles。Rollback: keep v1 envelope read path. Estimate 8/14/24 dev-days。

## Section 2: Axis 2 Deploy Plan
Gap: systemd/VPS exists, but package/IaC/container/SBOM/health/observability/DR are mostly absent by search.

Sub-phase H1-H12:
H1 packaging spec inventory。H2 deb via cargo-deb。H3 rpm via cargo-generate-rpm。H4 Homebrew tap formula。H5 Arch PKGBUILD。H6 distroless/scratch image。H7 Podman quadlet + Docker compose standard。H8 Helm chart single-node。H9 Terraform+Ansible minimal modules。H10 CycloneDX/SPDX SBOM + cosign attest。H11 backup/restore runbook + restore smoke。H12 optional HTTP probe + Prometheus/Grafana/OTel.
Acceptance: each artifact builds in CI, install/remove smoke, SBOM attached, `/readyz` fails until MCP deps ready. Reviewer: release-readiness + security. Risk: packaging drift. Rollback: keep GitHub binary release as canonical. Estimate 16/30/50d।

## Section 3: Axis 3 Stealth Plan
Gap: biggest. JS/CDP/mobile fingerprinting exists, Sec-CH-UA exists, but real JA4 is stubbed and external providers now advertise residential proxies/unblock APIs: Browserless `/unblock` and residential proxy docs, Bright Data Unlocker, Scrapling MCP HTTP/3/TLS fingerprint docs. Public official refs: Playwright MCP, Browserless, Bright Data, Scrapling.

Sub-phase I1-I15:
I1 legal/AUP fixture policy. I2 measurement harness schema. I3 real JA3/JA4 collector. I4 Chrome/Firefox/Safari TLS profile selection. I5 HTTP/2 SETTINGS replay. I6 QUIC/H3 feasibility spike. I7 Sec-CH-UA consistency validator. I8 Canvas/WebGL/Audio site policy. I9 behavior input model. I10 proxy provider trait. I11 Bright Data/Oxylabs/Smartproxy adapters. I12 CreepJS/FingerprintJS/IPQS CI opt-in. I13 owned Cloudflare fixture. I14 Akamai/DataDome only if licensed fixture. I15 score dashboard.
Targets: CreepJS bot signal <5%, IPQS bot score <30, JA4 equal to selected browser family, H2 SETTINGS exact profile, owned fixture success ≥90% over 50 authorized runs. Reviewer: security/legal first, then performance. Risk: evasion misuse and unstable arms race。Rollback: measurement-only mode. Estimate 25/45/80d。

## Section 4: Axis 4 Quality Plan
Gap: CI already has fmt/check/clippy/test/doc and security workflow, but no fuzz/mutation/coverage/criterion/chaos found.

Sub-phase J1-J10:
J1 coverage baseline with `cargo-llvm-cov`。J2 coverage gates 85/75. J3 proptest shared strategy crate. J4 proptest per crate. J5 cargo-fuzz targets for sanitize/parse/vpn. J6 cargo-mutants nightly job. J7 compose e2e stealth-mcp+Gluetun. J8 Chrome SIGKILL/VPN drop chaos. J9 criterion+bencher.dev. J10 cargo-public-api/cargo-bloat drift gate.
Acceptance: CI artifacts, thresholds, known flaky auth env race isolated. Reviewer: test strategist + performance. Estimate 12/22/35d。

## Section 5: Axis 5 Docs Plan
Gap: README EN/JA and generated MCP reference exist, but docs site/i18n/playground/ADR/error runbooks are incomplete. Security docs exist but stale contact/version.

Sub-phase K1-K12:
K1 mdBook/Docusaurus choice. K2 docs site deploy. K3 Hello World to prod 7 tutorials. K4 ADR backfill from 30 sub-phases. K5 rustdoc private/public pages. K6 26 ErrorKind troubleshooting dictionary. K7 SECURITY/PGP/contact/hall-of-fame fix. K8 CONTRIBUTING/RFC harden. K9 MCP playground design. K10 playground subset implementation. K11 i18n pipeline EN/JA/zh/ko/de/fr/es/pt-BR. K12 quarterly competitor matrix process.
Acceptance: dead-link check, snippets compile, docs freshness CI. Estimate 14/28/45d。

## Section 6: Parallel Lanes
Lane G = crypto, H = deploy, I = stealth, J = quality, K = docs. Dependencies: G2/G3 before H systemd TPM docs; H12 before I score exporter; J1/J7 support all release claims; K7 depends on G/H decisions. No cycle. With 5 real lanes, critical path is I at ~45d realistic plus H12/J infra overlap. Single developer sum is ~139d realistic; 5-lane calendar is ~50d realistic.

## Section 7: v1.3 Judgment
Do not ship “all five 9/10” as v1.3. Recommended v1.3: J quality 9/10 + H supply-chain/observability 8.8 + I measurement harness, not bypass claims. v1.4: G hardware-backed crypto + K docs. Axis3 should not be marketed as 9/10 until external authorized score gates pass repeatedly.

## Section 8: Objections
Scope creep: yes if framed as one release; no if split into G-K lanes with machine gates.  
8→9 ROI: justified only for enterprise/SOC users; hobby users do not need TPM/Merkle/IaC.  
TLS arms race: win by measurement and pluggable profiles, not permanent bypass claims.  
i18n impossible solo: use source EN/JA as authoritative, machine translate, native review only for release pages.  
Mutation ROI: keep nightly and boundary-focused; do not block every PR initially.

Self-score: criteria measurable yes; sub-phases ≤1d yes at planning granularity; dependency graph acyclic yes; estimates intentionally conservative; individual-resource reality handled by split release. Sources checked: Playwright MCP/auth, Puppeteer LaunchOptions, Crawl4AI self-host/MCP, Browserless unblock/proxies, Bright Data Unlocker, Scrapling MCP, systemd credentials.
