# P10.5 review

## scope
- crates/stealth-cli/src/commands/egress.rs (new, feature-gated)
- crates/stealth-cli/src/commands/measure.rs (--enable-egress-probe + wired)
- crates/stealth-cli/src/commands/mod.rs (pub mod egress)
- crates/stealth-cli/Cargo.toml ([features] default=[], vps-egress-probe=[])
- .gitignore (/dist/* + !/dist/systemd + nested package re-ignore)

## gates PASS
- cargo check --workspace                                → ok
- cargo check -p stealth-cli --features vps-egress-probe → ok
- cargo test  --workspace --no-fail-fast                 → 630 passed (>=616)
- cargo test  -p stealth-cli egress::tests               → 4 passed
- cargo clippy -p stealth-cli -- -D warnings             → ok
- cargo clippy -p stealth-cli --features vps-egress-probe -- -D warnings → ok
- git check-ignore dist/systemd/system/rev-stealth-mcp.service → exit 1
- git check-ignore dist/systemd/install.sh                     → exit 1
- git check-ignore scripts/semantic-mcp-server/dist/foo.js     → exit 0

## verify
1. Egress probe gated on `#[cfg(feature = "vps-egress-probe")]`. Default
   feature = []. `cargo build/test` without feature pulls no probe code.
   Without feature, `run_probe(true)` returns
   `{enabled:false, reason:"...without vps-egress-probe feature"}`.
2. Double opt-in: feature ON + runtime `--enable-egress-probe` both
   required. CLI flag absent => disabled stub.
3. .gitignore allows dist/systemd/ tracked, keeps dist/* + nested
   pkg dist/ ignored.
4. P10.1-P10.4 artefacts (dist/systemd 10+ files, docs/deploy/vps.md)
   visible in `git status --short` as untracked.
5. Secret redaction in `redact_response_headers`: replaces values for
   authorization/set-cookie/x-api-key/x-auth-token and any key
   containing token/secret/cookie/auth with `<redacted>`. Probe headers
   pass through filter. Test `egress_probe_redacts_token_in_response_headers`
   covers matrix.

return: LGTM or BLOCK: <reason>
