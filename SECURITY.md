<!-- SPDX-License-Identifier: MIT -->

# Security Policy

`rev_scraping` is a defender-facing evaluation toolkit. Because it
ships AUP enforcement, encrypted cookie storage, and VPN fail-closed
guards, security regressions are treated as **release blockers**.

## Supported versions

| Version          | Supported          |
| ---------------- | ------------------ |
| `1.1.x`          | yes — current line |
| `1.0.0-dev`     | no — pre-release   |
| < `1.0.0-dev`  | no                 |

## Reporting a vulnerability

**Do not** file public GitHub issues for security problems. Please use
one of:

1. **GitHub Security Advisory** — preferred. Open a private advisory
   on the project repository's Security tab. We acknowledge within
   3 business days.
2. **Email** — `security@rev-c.invalid` (PGP key fingerprint published
   in the same place as releases). Replace with the project's actual
   contact before publishing the repo.

Include:

- Affected version (`rev-stealth --version` / commit SHA).
- Reproduction steps or proof of concept.
- Impact assessment (data exposure, AUP bypass, code execution, etc.).
- Whether you intend to disclose publicly and on what timeline.

We follow **90-day coordinated disclosure** by default and will
publish an advisory + patched release before the window closes.

## Threat model

The authoritative threat model lives in the ExecPlan, section §G
(`.agent/active/v1.1.0_execplan_rev1.md` §G). High-level posture:

- **In scope**: AUP bypass, cookie cache decryption without keyring,
  VPN-loss leak, obscura subprocess escape, MCP stdio injection,
  recipe poisoning, cache poisoning of `stealth-parse` SQLite,
  trace-log credential leakage.
- **Out of scope**: defeating Cloudflare on third-party targets,
  automated CAPTCHA solving, passkey replay (these are non-goals,
  not vulnerabilities).

## Safe operation guidance

### Cookies and the encrypted jar

- The jar is encrypted with **ChaCha20-Poly1305**; the data-encryption
  key is wrapped by an OS keyring entry (macOS Keychain, Linux
  Secret Service, or `passphrase-only` fallback build).
- AAD binds each blob to `rev_scraping:stealth-auth:v1:<profile>`.
  Copying a blob between profiles fails decryption — by design.
- **Never** commit `~/.rev_scraping/auth/` to source control.
- Delete with `rev-auth wipe <profile>` at the end of an engagement;
  do not rely on the OS to zero free space.

### Recipe cache (`~/.rev_scraping/parse.sqlite`)

- Treat as **untrusted input** if the host is shared. A poisoned
  recipe can mis-relocate elements; AUP enforcement still protects
  the network boundary, but business logic may be affected.
- Mode 0700 on the parent directory is mandatory.

### VPN credentials

- Gluetun / Surfshark credentials live in your Docker env, not in
  `rev_scraping`. We never read them. Keep `.env` files out of git.
- The `leak_guard::on_vpn_loss` hook is fail-closed: a VPN flap shuts
  down the obscura bridge. Do not disable this in production.

### MCP stdio server

- `stealth-mcp` only accepts a fixed allowlist of tools (`spider`,
  `relocate`, `cf_evaluate`, `doctor`, `vpn_rotate`). It is **not**
  exposed over the network — stdio only (transport decision §8 #4).
- Run it as a child of the agent process; do not put a reverse proxy
  in front.

## Hall of fame

Reporters who follow coordinated disclosure are credited here after
the patched release ships.
