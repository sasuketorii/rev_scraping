# P10.5 review round-4 (LGTM ping)

## round-3 BLOCK → fix
Reviewer: `is_sensitive_param` missed `api-key`, `apikey`, `access_key`,
`cookie`, etc., so `?api-key=SECRET` would still leak.

Fix at [egress.rs is_sensitive_param](crates/stealth-cli/src/commands/egress.rs):
- Normalize the key: strip `-` and `_`, lowercase. Now `api-key`,
  `api_key`, `apikey`, `Access-Key`, `X-Auth-Token`, `X-CSRF-Token`,
  `aws-session-token`, `client-secret`, `refresh_token` all collapse.
- Expanded exact-match list: token / secret / key / auth / password /
  passwd / apikey / accesskey / sessionkey / sessionid / cookie /
  bearer / credential / credentials / sig / signature.
- Expanded substring matches: token / secret / auth / password /
  passwd / apikey / accesskey / session / cookie / credential /
  bearer / signature.

Test strengthened (`redact_url_strips_userinfo_and_token_query`) to
cover `token=xyz`, `api_key=AA`, `api-key=BB`, `apikey=CC`,
`access_key=DD`, `cookie=EE`, `x-csrf-token=FF`, `signature=GG`. None
of those values may appear in the redacted URL.

## gates re-run
- cargo check --workspace                                → ok
- cargo check -p stealth-cli --features vps-egress-probe → ok
- cargo clippy -p stealth-cli -- -D warnings             → ok
- cargo clippy -p stealth-cli --features vps-egress-probe -- -D warnings → ok
- cargo test  --workspace --no-fail-fast                 → 641 passed
- cargo test  egress::                                   → 6 passed (both modes)
- git check-ignore dist/systemd/system/rev-stealth-mcp.service → exit 1
- git check-ignore dist/systemd/install.sh                     → exit 1
- git check-ignore scripts/semantic-mcp-server/dist/foo.js     → exit 0

return: LGTM or BLOCK: <reason>
