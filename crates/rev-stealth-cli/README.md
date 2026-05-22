# rev-stealth-cli

[![crates.io](https://img.shields.io/crates/v/rev-stealth-cli.svg)](https://crates.io/crates/rev-stealth-cli)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`rev-stealth` is a stealth web scraping & Model Context Protocol (MCP) CLI
designed for AI agent developers (Claude Code / Cursor / Hermes operators).

This crate (`rev-stealth-cli`) is the **publish front** for `cargo install`.
The full workspace and source live at
[github.com/sasuketorii/rev_scraping](https://github.com/sasuketorii/rev_scraping).

## Install

```bash
cargo install --locked rev-stealth-cli
rev-stealth --help
```

Other install paths:

- **Homebrew** (macOS / Linux): `brew install sasuketorii/rev-stealth/rev-stealth`
- **Debian / Ubuntu**: `.deb` artifacts on GitHub Releases
- **RHEL / Fedora**: `.rpm` artifacts on GitHub Releases
- **Docker (distroless)**: `docker pull ghcr.io/sasuketorii/rev-stealth:latest`
- **curl-pipe-sh**: `curl -fsSL https://raw.githubusercontent.com/sasuketorii/rev_scraping/main/install.sh | sh`

All release artifacts are cosign-signed and SLSA L3 attested.

## Quickstart

See the [full tutorial](https://sasuketorii.github.io/rev_scraping/) on
GitHub Pages.

## License

MIT — see [LICENSE](https://github.com/sasuketorii/rev_scraping/blob/main/LICENSE).
