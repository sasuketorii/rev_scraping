# Review P10.2 LoadCredentialEncrypted reader

Repo: $REPO_ROOT

Files (added/modified for P10.2 only):
- dist/systemd/system/rev-stealth-vpn@.service  (LoadCredentialEncrypted= + Environment=*_FILE=%d/...)
- crates/vpn-rotate/src/credentials.rs          (new module: CredentialResolver, CredentialError)
- crates/vpn-rotate/src/lib.rs                  (pub mod credentials;)
- crates/vpn-rotate/Cargo.toml                  (+ secrecy = { workspace = true })
- dist/systemd/setup-credentials.sh             (new: systemd-creds encrypt wrapper, --dry-run, --non-interactive)

Gates already PASS locally:
- cargo check -p vpn-rotate  : OK
- cargo test -p vpn-rotate credentials : 6/6 PASS
- cargo test --workspace --no-fail-fast : 573 passed, 0 failed (baseline 567 + 6 new)
- cargo clippy -p vpn-rotate --all-targets : clean
- bash -n dist/systemd/setup-credentials.sh : OK
- SPDX-License-Identifier: MIT present on both new files
- vendor/ _refs/ untouched

Verify:
1. CredentialResolver::resolve reads <KEY>_FILE first, then env <KEY>, else CredentialError::EnvMissing.
2. Plaintext wrapped in secrecy::SecretString (zeroize on drop, Debug does not leak).
3. Unix file perm check rejects mode where (mode & 0o077) != 0 (i.e. any group/world bit).
4. systemd unit syntax: LoadCredentialEncrypted=name:/path/to.cred ; Environment=KEY_FILE=%d/name.
   (%d expands to $CREDENTIALS_DIRECTORY at runtime.)
5. setup-credentials.sh: idempotent (mktemp + mv -f), no plaintext echoed (read -s, printf '%s' piped),
   --dry-run and --non-interactive supported, root check, requires systemd-creds.
6. API surface additive only (new module); no breaking change to existing vpn-rotate API.

Return:
verdict: LGTM
or
verdict: BLOCK: <one-line reason + file:line>
