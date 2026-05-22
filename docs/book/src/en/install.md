# Installation

`rev-stealth` ships as a single static binary. Pick whichever channel matches
your environment — they all install the same artifact, just from different
distribution surfaces.

## macOS — Homebrew (recommended)

```sh
brew tap sasuketorii/rev-stealth
brew install rev-stealth
rev-stealth --version
```

Apple Silicon and Intel are both bottled. The formula pulls the
cosign-verified release tarball from the GitHub release matching the
formula version.

## Debian / Ubuntu — `.deb`

```sh
curl -fsSL https://github.com/sasuketorii/rev_scraping/releases/download/v1.3.0/rev-stealth_1.3.0_amd64.deb -o rev-stealth.deb
sudo dpkg -i rev-stealth.deb
```

Tested on Debian 12, Ubuntu 22.04, Ubuntu 24.04. The package installs into
`/usr/local/bin/rev-stealth` and ships an apparmor profile (optional).

## RHEL / Fedora — `.rpm`

```sh
sudo rpm -i https://github.com/sasuketorii/rev_scraping/releases/download/v1.3.0/rev-stealth-1.3.0-1.x86_64.rpm
```

## Rust / `cargo install`

```sh
cargo install --locked rev-stealth
```

`--locked` honours the published `Cargo.lock`. This is the recommended
channel for contributors and for environments where reproducibility matters
more than convenience.

## Container image (distroless multi-arch)

```sh
docker pull ghcr.io/sasuketorii/rev-stealth:v1.3.0
docker run --rm ghcr.io/sasuketorii/rev-stealth:v1.3.0 doctor
```

Chromium runs in a separate sidecar image
(`ghcr.io/sasuketorii/rev-stealth-chromium`). See the
[VPS deployment chapter](./tutorial/07-vps.md) for a sample compose file.

## `curl | sh` (last resort)

```sh
curl -fsSL https://get.rev-stealth.dev | sh
```

The installer verifies the cosign signature before extracting. If you do not
trust the installer you can verify the artifact yourself:

```sh
cosign verify-blob \
  --certificate-identity-regexp '^https://github.com/sasuketorii/rev_scraping/.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --signature rev-stealth.sig \
  rev-stealth
```

## Verifying the install

```sh
rev-stealth --version
rev-stealth doctor --output-format json | jq '.checks[] | select(.status != "ok")'
```

`doctor` is the official self-test; an empty filter means every check
passes.
