# Step 1 — Local install

The fastest path on macOS:

```sh
brew tap sasuketorii/rev-stealth
brew install rev-stealth
```

On Linux, pick one:

```sh
# Debian / Ubuntu
sudo dpkg -i rev-stealth_1.3.0_amd64.deb

# Any Rust toolchain
cargo install --locked rev-stealth
```

## Verify

```sh
rev-stealth --version
rev-stealth doctor
```

`doctor` runs ~10 self-tests (config dir writable, Chromium discoverable,
DNS reachable, VPN config parseable, …). Failures are reported with a
`doc_url` field pointing at the corresponding troubleshooting page.

## Smoke test

```sh
rev-stealth doctor --output-format json | jq '.summary.status'
# expected: "ok"
```

If the status is `"warn"` or `"fail"`, follow the `doc_url` for each
failing check. The most common first-run failure is `BrowserNotFound`
([fix](../errors/BrowserNotFound.md)).
