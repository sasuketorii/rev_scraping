# rev_scraping v1.0.0 — Verification Truth Matrix (Phase 4 closure)

Generated: 2026-05-12. Maps ExecPlan §1.2 success criteria S1–S12 to the
actual test / artifact that demonstrates them today.

| ID  | Criterion (abridged)                                            | State              | Evidence / how_to_verify                                                            |
|-----|-----------------------------------------------------------------|--------------------|-------------------------------------------------------------------------------------|
| S1  | `spider` evaluates Turnstile resilience and returns 200 + DOM   | GATED-ON-CI-RUN    | Job `test-spider-fallback` in `.github/workflows/ci.yml` (Phase 5b). Locally: `./scripts/run_obscura_e2e.sh`. |
| S2  | obscura subprocess lifecycle + SIGTERM ≤ 5 s                    | GATED-ON-CI-RUN    | Job `test-obscura-lifecycle` in `.github/workflows/ci.yml`. Locally: `./scripts/run_obscura_e2e.sh` (runs `crates/obscura-bridge/tests/obscura_lifecycle.rs`). |
| S3  | Same `session_id` → identical TLS ClientHello bytes             | PENDING            | TLS dump SOW item (Phase 0 leftover); FP cache unit tests cover the key derivation. |
| S4  | DOM cache hit / strsim ≥ 0.85 relocate / exit 10 on ambiguous   | **PASS**           | `crates/stealth-parse/tests/golden_relocate.rs` + exit-mapping unit tests.          |
| S5  | MCP `tools/list` returns 6 tools matching CLI surface           | **PASS**           | `crates/stealth-mcp/tests/mcp_conformance.rs` (`mcp_stdio_conformance`).            |
| S6  | clippy -D warnings PASS + ≥ 40 new unit tests PASS              | **PASS**           | `cargo clippy --workspace --all-targets -- -D warnings` clean; 146 total tests. CI: jobs `test-unit` + `test-clippy`. |
| S7  | obscura / Scrapling source-credit + SPDX headers on new files   | **PASS**           | All Phase 1–4 new `.rs` files carry SPDX + Source headers. (See note below.)        |
| S8  | Zero verbatim from goscrapy (BSL)                               | **PASS**           | `scripts/check_bsl_contamination.sh` (zero matches).                                |
| S9  | Defender signal extraction in `measure` subcommand              | GATED-ON-CI-RUN    | Obscura-dependent; runs under CI once `measure` lands. Locally: `./scripts/run_obscura_e2e.sh`. |
| S10 | Independent bridge SSRF guard (private / loopback / IMDS)       | **PASS** | `obscura_bridge::tests` SSRF unit tests (≥ 3) + `ObscuraBridge::validate_url`.      |
| S11 | VPN-down → obscura killed ≤ 5 s (fail-closed)                   | **PASS** | `vpn-rotate::leak_guard::on_vpn_loss` → `ObscuraBridge::shutdown`; unit-tested.     |
| S12 | AUP enforcement: unauthorized URL → exit 1                      | **PASS** | `crates/stealth-cli/src/aup.rs::tests` + `e2e_aup_enforcement.rs` (3 E2E).          |

**Summary:** 8 PASS / 3 GATED-ON-CI-RUN / 1 PENDING.

Phase 5c closes the obscura-binary CI gap: `.github/workflows/ci.yml`
builds `vendor/obscura/target/release/obscura` (cached via
`actions/cache@v4` keyed on the vendored revision so V8 snapshots are
not rebuilt) and feeds it into jobs `test-obscura-lifecycle` (S2),
`test-cdp-shim-lifecycle` (Phase 5a) and `test-spider-fallback`
(S1 / Phase 5b). S9 still depends on the `measure` subcommand itself
landing in the binary, but its harness is identical to S2 and is
covered by the same workflow once the code merges. S3 remains PENDING
on a separate TLS-byte-diff SOW item.

Local reproduction:

```bash
./scripts/run_obscura_e2e.sh           # builds obscura if missing, runs S1/S2/S9 harnesses
./scripts/run_obscura_e2e.sh --nocapture
```

## Notes

- **S6 test totals:** `cargo test --workspace --no-fail-fast` reports
  146 PASS (default) + 10 PASS (`-- --ignored`) across the workspace.
  New-since-Phase-0 unit tests alone exceed the 40-test floor.
- **S7 caveat:** `scripts/check_source_and_spdx.sh` currently flags
  four pre-existing vendored stealth-cli source files
  (`captcha_cmd.rs`, `doctor.rs`, `browser_cmd.rs`, `vpn_cmd.rs`)
  imported from rev_stealth @ 6fc38fd. These predate Phase 4 and the
  Phase-4 constraint forbids editing them. All Phase 1–4 *new* files
  carry the required headers.
