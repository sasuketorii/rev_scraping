# P10.5 review round-2

## round-1 BLOCK findings → fixes
1. URL leak risk via REV_STEALTH_EGRESS_PROBE_URL → added `redact_url()`
   which strips userinfo and redacts sensitive query params
   (token/secret/key/auth/password). Probe `endpoint` field and the
   `HEAD {url}` error message now use `url_safe` only. Regression tests:
   - `redact_url_strips_userinfo_and_token_query` (alice:s3cret@host?token=xyz&api_key=AA)
   - `redact_url_fails_closed_on_garbage` (returns `<unparseable-url>`)
2. Mislabeled `tls_protocol_version` → renamed wire field to
   `http_version` (reqwest does not expose TLS version on Response).
   The `tls_protocol_version` field is kept in the JSON shape but
   pinned to `"<not exposed by reqwest>"` so callers see an honest
   placeholder rather than HTTP/1.1.

## gates re-run
- cargo check --workspace                               → ok
- cargo check -p stealth-cli --features vps-egress-probe → ok
- cargo clippy -p stealth-cli -- -D warnings            → ok
- cargo clippy -p stealth-cli --features vps-egress-probe -- -D warnings → ok
- cargo test --workspace --no-fail-fast                 → 640 passed
- cargo test egress::tests                              → 6 passed
  (added 2 new redact_url tests; total egress unit ≥ 5)
- git check-ignore dist/systemd/system/rev-stealth-mcp.service → exit 1
- git check-ignore dist/systemd/install.sh                     → exit 1
- git check-ignore scripts/semantic-mcp-server/dist/foo.js     → exit 0

## verify (carryover invariants still hold)
- Feature default OFF; CLI flag required (double opt-in).
- Probe disabled stub still emits no network I/O.
- Header redaction unchanged.

return: LGTM or BLOCK: <reason>
