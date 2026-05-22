# rev-stealth

Stealth scraping CLI for AI agents (rev_scraping v1.2+): captcha bypass,
browser fingerprint control, VPN rotation, content sanitization, and an MCP
server in a single binary.

> Authorized targets only. `rev-stealth` is a defender-facing evaluation
> toolkit for teams that own the systems they test against. See `EXIT CODES`
> below and the project [AUP](https://github.com/sasuketorii/rev_scraping)
> for the full acceptable-use policy.

## Install

```sh
cargo install --locked rev-stealth
rev-stealth --help
```

Other distribution channels (post v1.3.0 release cut):

- Homebrew: `brew install sasuketorii/rev-stealth/rev-stealth`
- Debian / Ubuntu: `.deb` artifact from the GitHub release
- RHEL / Fedora: `.rpm` artifact from the GitHub release
- Docker: `ghcr.io/sasuketorii/rev-stealth:<tag>` (distroless)
- One-liner: `curl -fsSL https://github.com/sasuketorii/rev_scraping/raw/main/install.sh | sh`

See [`docs/distribution.md`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/distribution.md)
for the full distribution matrix and the rationale behind Slice A (direct
`cargo install rev-stealth`, no separate publish-wrapper crate).

## Requirements

- Rust toolchain **1.83+** (`rust-version` pinned by the workspace).
- Chrome / Chromium **120+** on `PATH` for browser / stealth-test / measure flows.
  Override with `REV_STEALTH_CHROME=/path/to/chrome` if not installed in a
  default location.
- macOS Keychain or Linux secret-service for the sealed `AuthStore`
  (`rev-stealth auth login` / `auth refresh`). Set
  `REV_SCRAPING_AUTH_PASSPHRASE` to bypass the keystore in CI.

## What it does

`rev-stealth` is a single binary with the following subcommands. Run
`rev-stealth <cmd> --help` for the full surface — every command emits
either human-readable output or `--format json` for agent consumers.

| Command       | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `captcha`     | reCAPTCHA v2/v3, hCaptcha, Turnstile solver + verify probes    |
| `browser`     | Fingerprint-cloaked Chrome launch + bot-detection sweep        |
| `vpn`         | Surfshark / Gluetun lazy-rotate-on-fail + status / leak guard  |
| `doctor`      | Pre-flight leak checks (kill-switch / DNS / IPv6 / WebRTC)     |
| `spider`      | AUP-gated browse + optional CF eval + adaptive relocate        |
| `relocate`    | Locate a previously fingerprinted element by stable_id         |
| `cf-evaluate` | Cloudflare Turnstile resilience evaluation (no solver)         |
| `auth`        | Sealed session capture / list / status / refresh / delete      |
| `measure`     | Local fingerprint diagnostics (`--enable-external` for SaaS)   |
| `config`      | Layered config inspection + atomic mutation (0600 + backups)   |
| `hermes`      | Manage the bundled Hermes MCP plugin scaffold                  |

### v1.3 additions ("CLI black belt", Lane G)

- `rev-stealth completions <bash|zsh|fish|nushell>` — emit shell completion to
  stdout, in lockstep with the live clap `--help` tree via a CI gate.
- Manpages installed by the `.deb` / `.rpm` / Homebrew formulas
  (`cargo xtask manpages`).
- `cargo install rev-stealth` builds the same library + binary surface that
  the workspace consumes (no separate wrapper crate; Slice A retirement of
  the historical `rev-stealth-cli` plumbing crate).

## Exit codes

Stable across the agent contract — parse the process status to decide
retry vs. escalate:

| Code | Meaning           | Notes                                              |
|------|-------------------|----------------------------------------------------|
| 0    | Ok                | Action completed.                                  |
| 1    | UserError         | Bad args / AUP rejection / config validation.      |
| 2    | TransientError    | Network / VPN / provider flap (retryable).         |
| 3    | PermanentError    | Unsupported / not implemented / IO failure.        |
| 4    | AuthExpired       | Stored auth profile expired (Phase 9a).            |
| 7    | Leak              | Fail-closed: leak detected by `doctor` or VPN guard.|

## Library surface

The CLI lives in the `stealth_cli` library so embedders can drive it
programmatically:

```rust
fn main() -> std::process::ExitCode {
    std::process::ExitCode::from(stealth_cli::run() as u8)
}
```

`stealth_cli::run()` builds an owned multi-thread Tokio runtime per call;
do not invoke from inside an existing runtime. Use the async core
`stealth_cli::run_async()` when you already own a runtime.

## License & links

- License: [MIT](https://github.com/sasuketorii/rev_scraping/blob/main/LICENSE)
- Homepage / repository: <https://github.com/sasuketorii/rev_scraping>
- Documentation: <https://sasuketorii.github.io/rev_scraping/>
- Issue tracker: <https://github.com/sasuketorii/rev_scraping/issues>
