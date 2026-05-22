# P10.5 review round-3

## round-2 BLOCK finding → fix
Reviewer: `format!("HEAD {url_safe}: {e}")` still leaks because
`reqwest::Error` Display can append `for url (...)`.

Fix: added `scrub_reqwest_error(e: reqwest::Error) -> String` that calls
`e.without_url().to_string()` — the reqwest-canonical way to drop the
URL. The send-error branch now formats `{safe_err}` instead of `{e}`,
keeping only our pre-redacted `url_safe` prefix.

Regression test (feature-gated, runs under `--features vps-egress-probe`):
`scrub_reqwest_error_strips_url_with_token`. It HEADs
`http://127.0.0.1:1/probe?token=SENSITIVE_TOKEN_DO_NOT_LEAK` (guaranteed
connect-refuse / timeout) and asserts the scrubbed string contains
neither `SENSITIVE_TOKEN_DO_NOT_LEAK` nor `127.0.0.1:1`.

## gates re-run (now includes 1 new test)
- cargo check --workspace                                → ok
- cargo check -p stealth-cli --features vps-egress-probe → ok
- cargo clippy -p stealth-cli -- -D warnings             → ok
- cargo clippy -p stealth-cli --features vps-egress-probe -- -D warnings → ok
- cargo test  --workspace --no-fail-fast                 → 640 passed
- cargo test  egress:: (no-feature)                      → 6 passed
- cargo test  egress:: --features vps-egress-probe       → 6 passed
  (the without-feature stub test swaps for the scrub_reqwest_error test)
- git check-ignore dist/systemd/system/rev-stealth-mcp.service → exit 1
- git check-ignore dist/systemd/install.sh                     → exit 1
- git check-ignore scripts/semantic-mcp-server/dist/foo.js     → exit 0

## carryover invariants
- Feature default OFF; CLI flag required (double opt-in).
- redact_url() strips userinfo + sensitive query params.
- redact_response_headers() unchanged; headers always pass through it.
- `tls_protocol_version` honestly labeled (placeholder) and HTTP version
  surfaced as `http_version`.

return: LGTM or BLOCK: <reason>
