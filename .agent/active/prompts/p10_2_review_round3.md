# Review P10.2 round 3 — systemd $ escaping fix

Repo: $REPO_ROOT

Round-2 BLOCK was: "systemd expands ${REV_STEALTH_BIN:-/usr/bin/docker}
before /bin/sh, breaking shell-side defaults / command substitution".

Root cause: systemd's own ${VAR} expansion in ExecStart= eats the $ in
$(cat "${VPN_USER_FILE}") and does not support ${VAR:-default}.

Fix applied (only file changed since round 2):
- dist/systemd/system/rev-stealth-vpn@.service

  All shell-side $ are now written as $$ so systemd passes a literal $ to
  /bin/sh. Concretely:
    $$(cat "$${VPN_USER_FILE}")           → sh sees $(cat "${VPN_USER_FILE}")
    "$${REV_STEALTH_BIN}"                 → sh sees "${REV_STEALTH_BIN}"
  REV_STEALTH_BIN is set via Environment=REV_STEALTH_BIN=/usr/bin/docker
  (no shell :-default because systemd doesn't grok :-).

  This also incidentally fixes the pre-existing
  ${REV_STEALTH_BIN:-/usr/bin/docker} construct the reviewer called out.

Verification done locally:
- cargo test -p vpn-rotate credentials : 6/6 PASS (unchanged)
- cargo clippy -p vpn-rotate --all-targets -- -D warnings : clean
- bash -n equivalent of the ExecStart inner sh script: OK
- systemd-analyze not available on darwin host; relying on documented
  behavior: man systemd.service(5) "$$ produces a literal dollar sign",
  "${VAR:-default} is NOT supported".

Other files (unchanged since round 1):
- crates/vpn-rotate/src/credentials.rs
- crates/vpn-rotate/src/lib.rs
- crates/vpn-rotate/Cargo.toml
- dist/systemd/setup-credentials.sh

Please confirm:
1. $$ escaping in ExecStart is correct (sh receives `$(cat "${VPN_USER_FILE}")`).
2. REV_STEALTH_BIN explicit Environment= replaces the unsupported :-default.
3. No regression in CredentialResolver / setup script / cred file flow.

Return:
verdict: LGTM
or
verdict: BLOCK: <one-line reason + file:line>
