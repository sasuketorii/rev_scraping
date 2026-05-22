# Changelog — rev_scraping

All notable changes to the **rev_scraping** project (workspace crates, CLI,
MCP server, recipe pack) are documented here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/) and adheres to
[Semantic Versioning 2.0](https://semver.org/) per `docs/compat.md`.

> **Scope note.** The repo also carries `CHANGELOG.md` at the root, which
> tracks the RevHarness orchestration layer (Claude/Codex wrappers, hooks,
> skill scaffolding). The two surfaces version independently. This file is
> the source of truth for the **rev_scraping product**: `rev-stealth` binary,
> `stealth-mcp` server, recipe pack, AUP semantics.

This file is machine-parseable. Each release section is delimited by a
`## [<version>] - <YYYY-MM-DD>` heading, contains one or more `### <Section>`
sub-sections drawn from the keep-a-changelog vocabulary (`Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, `Security`, `Breaking Changes`), and
optionally records the PR labels that gated the change (`api-additive`,
`api-breaking`, `mcp-schema-breaking`).

PR label conventions (consumed by Lane H.7 `release-please` when it
assembles the next release PR from the unreleased commits):

- `api-additive` — new flag, new subcommand, new env var, new MCP tool, new
  output field. Triggers a **minor** bump.
- `api-breaking` — removed/renamed CLI flag, env var, exit code, output
  field. Triggers a **major** bump and a `### Breaking Changes` section.
- `mcp-schema-breaking` — removed/renamed MCP tool, narrowed value enum,
  changed required-arg semantics. Triggers a **major** bump and a
  `### Breaking Changes` section.
- `security` — credential handling, sanitizer, sandbox, AUP, leak-prevention.
  Triggers a `### Security` section regardless of version bump.

## [Unreleased]

### Added

- **Lane I (v1.3, API stability)**: CLI public-API snapshot
  (`.agent/v1.3/cli-public-api.snapshot.json`), `docs/compat.md` semver
  policy, `scripts/cli-public-api-snapshot.sh` drift gate,
  `scripts/mcp-schema-breaking.sh` MCP tool-list breaking-change detector,
  three new CI jobs (`cli-public-api-snapshot`, `cargo-public-api-diff`,
  `mcp-schema-breaking-detector`), and a `deprecated_completeness` workspace
  test that requires every `#[deprecated]` attribute to populate `since`,
  `note`, and a `replace_with` hint in the note body.


## [1.2.0] - 2026-05-22

### Added

- `stealth-sanitize` 5-layer prompt-injection defense pipeline (20 canary
  classes; envelope `<<<UNTRUSTED_CONTENT origin=… sanitize_id=NONCE>>>`;
  `_meta.sanitize` on every MCP tool response).
- 16 MCP tools (`spider`, `relocate`, `cf_evaluate`, `doctor`, `recipe_*`,
  `auth_*`, `session_show`, `vpn_rotate`) — see `docs/MCP_REFERENCE.md`.
- `rev-stealth config` subtree (`show`, `paths`, `validate`, `diff`, `get`,
  `set`, `edit`, `migrate`, `init`, `history`, `rollback`, `gc`, `profile`).
- `rev-stealth hermes` (`install`, `uninstall`, `verify`).
- Strict UUID v4 manual serde for `SessionId` / `ProgressToken`.

### Security

- Hardened systemd unit: `NoNewPrivileges`, `ProtectSystem=strict`,
  read-only `/etc` mount, isolated `/var/log/rev-stealth/` (mode 0700).
- TPM2-sealed Surfshark credentials via `systemd-creds` when available.
- AUP env-ack flow (`REV_SCRAPING_AUP_ACK`) + `--i-have-authorization` opt-in.

## [1.1.0] - 2026-04-30

### Added

- VPN fail-closed guard family (`--require-vpn`, `--vpn-instance`,
  `--proxy-tier`, `--no-fallback`, leak-poll background monitor).
- `rev-stealth measure` local fingerprint diagnostics (opt-in external SaaS).
- `doctor --deep` extended stack-health checks.
- `doctor --vps` VPS deploy readiness checks.

## [1.0.0] - 2026-03-31

### Added

- Initial public release: stealth browser launcher, captcha bypass, VPN
  rotation, recipe pack, AUP gating.
