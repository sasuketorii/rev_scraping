# Review P10.2 round 2 — fix for docker-compose VPN_USER interpolation

Repo: $REPO_ROOT

Round-1 BLOCK was: "encrypted creds exported only as *_FILE but compose still
interpolates ${VPN_USER}/${VPN_PASSWORD} → blank OPENVPN_USER".

Fix applied (only file changed since round 1):
- dist/systemd/system/rev-stealth-vpn@.service
  ExecStart now hydrates raw env from the credential files at startup:
    ExecStart=/bin/sh -c 'set -eu; \
      VPN_USER="$(cat "${VPN_USER_FILE}")"; \
      VPN_PASSWORD="$(cat "${VPN_PASSWORD_FILE}")"; \
      export VPN_USER VPN_PASSWORD; \
      exec "${REV_STEALTH_BIN:-/usr/bin/docker}" compose --project-name rev-stealth-vpn-%i up -d'

Rationale:
- src/infra/docker-compose.vpn.yml lines 35/36/74/75/113/114 use
  ${VPN_USER}/${VPN_PASSWORD} for OPENVPN_USER / OPENVPN_PASSWORD.
- *_FILE remains source of truth on disk; raw env exists only inside the
  ExecStart child process (passed to docker via compose), never written to disk.
- CredentialResolver (Rust side) still prefers *_FILE, so in-process consumers
  do not regress to plaintext env.

Other files (unchanged from round 1):
- crates/vpn-rotate/src/credentials.rs
- crates/vpn-rotate/src/lib.rs
- crates/vpn-rotate/Cargo.toml
- dist/systemd/setup-credentials.sh

Gates re-verified:
- cargo test -p vpn-rotate credentials : 6/6 PASS
- cargo test --workspace --no-fail-fast : 583 passed, 0 failed
- cargo clippy -p vpn-rotate --all-targets -- -D warnings : clean
- bash -n dist/systemd/setup-credentials.sh : OK
- vendor/ _refs/ untouched

Verify just the round-1 issue is resolved and nothing new broke. Return:
verdict: LGTM
or
verdict: BLOCK: <one-line reason + file:line>
