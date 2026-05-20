# rev_scraping — Ultimate Stealth Scraping Toolkit for AI Agents

**Status:** v1.0.0-dev (Phase 0 complete) · License: MIT

`rev_scraping` is a **Defender-Facing Evaluation Toolkit**. It is designed to be driven by
AI coding agents (codex, Claude Code, etc.) through a CLI or MCP (stdio transport) interface,
so they can evaluate the *resilience of bot-mitigation defenses* on **authorized** targets.

This project is positioned as a defender / red-team evaluation tool. It is **not** a
general-purpose unauthorized scraping tool.

---

## ⚠️ Authorized Targets Only — read this before running anything

Use of this toolkit is restricted to systems for which **you possess explicit written
authorization** (e.g. you own the target, or you have a signed pentest / red-team SOW).

Unauthorized use may violate, among others:

- **Cloudflare Terms of Service §2.8** — bypassing Cloudflare protections without
  authorization is a ToS violation.
- **Japan: 不正アクセス禁止法 (Act on Prohibition of Unauthorized Computer Access)** —
  unauthorized access or circumvention of access controls is a criminal offense.
- **United States: Computer Fraud and Abuse Act (CFAA, 18 U.S.C. § 1030)** —
  accessing computers "without authorization" or in excess of authorization is a federal crime.

You, the operator, are solely responsible for ensuring your usage complies with all
applicable laws and contractual terms. The authors disclaim all liability for misuse.

### Technical AUP enforcement

- An allowlist file is required at `~/.rev_scraping/authorized.toml` (directory permission `0700`).
  Schema:
  ```toml
  [[targets]]
  url_pattern = "^https://example\\.test/.*"
  ```
- Targets not matching any `url_pattern` will be **refused by the CLI** (exit 1).
- The acknowledgement environment variable `REV_SCRAPING_AUP_ACK` is **scoped to the current
  date** (date-hash TTL); it must be re-set each calendar day.
- Per Phase 0 decisions, the CLI itself does **not** print a runtime disclaimer banner;
  this README is the canonical disclaimer surface.

---

## Project layout

```
rev_scraping/
├── Cargo.toml              workspace root
├── crates/
│   ├── stealth-core/       (vendored from rev_stealth @ 6fc38fd, MIT)
│   ├── mobile-fp/          (vendored, MIT)
│   ├── vpn-rotate/         (vendored, MIT)
│   ├── captcha-bypass/     (vendored, MIT)
│   ├── stealth-cli/        (vendored, MIT)
│   ├── obscura-bridge/     (NEW, Phase 1a — subprocess + CDP bridge)
│   ├── stealth-cf/         (NEW, Phase 1b — Turnstile resilience eval)
│   ├── stealth-parse/      (NEW, Phase 1c — adaptive relocate + SQLite WAL)
│   ├── stealth-mcp/        (NEW, Phase 3   — MCP stdio server, hand-rolled JSON-RPC)
│   ├── stealth-sites/      (NEW, v1.1.0 P11 — recipe-driven site adapters)
│   └── stealth-auth/       (NEW, v1.1.0 Phase 9 — encrypted cookie cache + rev-auth)
├── vendor/
│   └── obscura/            (vendored obscura source, Apache-2.0)
├── _refs/                  (read-only reference clones — obscura, Scrapling, rev_harness)
├── scripts/
│   ├── check_source_and_spdx.sh
│   └── check_bsl_contamination.sh
├── docs/
├── tests/
└── .agent/active/plan_v1.0.0.md
```

## License composition

| Component                              | License         | Notes                                     |
| -------------------------------------- | --------------- | ----------------------------------------- |
| First-party crates (`obscura-bridge`, `stealth-cf`, `stealth-parse`, `stealth-mcp`) | MIT             | Authored by Sasuke Torii / REV-C Inc.     |
| Vendored from rev_stealth              | MIT             | Originally authored in rev_stealth        |
| `vendor/obscura/`                      | Apache-2.0      | Upstream obscura. Attribution recorded in [`NOTICE`](./NOTICE). |
| Design influence: Scrapling            | BSD-3-Clause    | Design adaptation only, no verbatim port  |
| Design influence: goscrapy             | BSL             | **Design reference only** — zero code     |
| Bundled blocklist (3520 entries)       | inherited from obscura | redistributed as obscura ships     |

## Quick start

```bash
# Phase 0: workspace skeleton compiles (stubs only)
cargo check --workspace

# Phase 1+: see .agent/active/plan_v1.0.0.md
cargo test --workspace
```

## Development status

- **Phase 0** (this commit): workspace scaffold, vendored crate import, plan rev3 saved.
- **Phase 1 a-d**: parallel implementation of `obscura-bridge`, `stealth-cf`,
  `stealth-parse`, `mobile-fp` obscura glue.
- **Phase 2**: `stealth-cli` extension with AUP enforcement.
- **Phase 3**: `stealth-mcp` (stdio).
- **Phase 4**: E2E + `measure` deliverable.

See `.agent/active/plan_v1.0.0.md` for the full ExecPlan (rev3).

---

## §12 Agentic Scraping Stack

> **Positioning: Defender-Facing Evaluation Toolkit.**
> Read the disclaimers at the top of this README — Cloudflare ToS §2.8, Japan's
> 不正アクセス禁止法, and the U.S. CFAA — before doing anything in this section.

`rev_scraping` is an agentic toolkit invoked by AI coding agents
(codex, Claude Code, etc.) via either a CLI binary (`rev-stealth`) or an
MCP **stdio** server (`stealth-mcp`). It exists to let an agent **evaluate the
resilience of bot-mitigation defenses on authorized targets** — not to
defeat them on third-party systems.

### Architecture (simplified)

```
   agent (codex / Claude Code)
        │  CLI argv                       MCP stdio (JSON-RPC 2.0)
        ▼                                       ▼
   stealth-cli  ◄────── in-proc lib ────── stealth-mcp
        │
        ├── obscura-bridge ───► vendor/obscura (Chrome145 TLS/HTTP2 FP,
        │                       3520-entry blocklist, CDP server)
        ├── stealth-cf     ───► obscura-bridge   (Turnstile resilience eval)
        ├── stealth-parse  ───► ~/.rev_scraping/parse.sqlite (WAL, 30 d)
        ├── mobile-fp      ───► obscura-bridge   (mobile FP injection)
        ├── captcha-bypass
        └── vpn-rotate     ───► leak_guard.on_vpn_loss
                                └─► ObscuraBridge::shutdown  (S11, fail-closed)
```

### Crates

| Crate            | Responsibility                                                          |
| ---------------- | ----------------------------------------------------------------------- |
| `stealth-cli`    | `rev-stealth` binary: AUP-gated subcommands + JSON output schema        |
| `obscura-bridge` | obscura subprocess lifecycle + CDP (chromiumoxide 0.9) + bridge SSRF    |
| `stealth-cf`     | Defender-side Turnstile resilience evaluation (no solver)               |
| `stealth-parse`  | Adaptive relocate (SQLite WAL, strsim ≥ 0.85, exit 10 ambiguous path)   |
| `stealth-mcp`    | MCP stdio server (hand-rolled JSON-RPC, 2024-11-05 schema) — exposes CLI ops as MCP tools |
| `mobile-fp`      | Mobile fingerprint preset injection via obscura CDP                     |
| `vpn-rotate`     | Surfshark/Gluetun rotation + `leak_guard::on_vpn_loss` (fail-closed)    |
| `captcha-bypass` | Existing captcha solver glue                                            |
| `stealth-core`   | Shared types / `ExitCode`                                               |
| `stealth-sites`  | Recipe-driven site adapters (v1.1.0 P11) — pluggable per-site selectors |
| `stealth-auth`   | Encrypted cookie cache + `rev-auth` helper (Phase 9, ChaCha20-Poly1305) |

### Building obscura binary

`spider` and `cf-evaluate` launch the vendored `obscura` Chrome-145 / CDP
server as a child process. The workspace does **not** auto-build it,
because obscura lives under `vendor/obscura/` with its own
`Cargo.toml` (Apache-2.0, see `NOTICE`).

```bash
# 1. Build the obscura binary out-of-tree (workspace excludes it; see
#    Cargo.toml `[workspace] exclude`).
cd vendor/obscura && cargo build --release --bin obscura
# 2. Either copy / symlink it onto PATH ...
ln -sf "$(pwd)/target/release/obscura" /usr/local/bin/obscura
# 3. ... or point rev-stealth at it explicitly via env var.
export REV_STEALTH_OBSCURA="$(pwd)/target/release/obscura"
# 4. Or pass --obscura /path/to/obscura on each invocation.
```

**Symptoms when obscura is missing.** `spider` and `cf-evaluate` exit
with code **3** (`obscura launch (permanent): BinaryNotFound`).
Workaround: `relocate --html-file path.html` is the only subcommand that
runs without obscura; it operates on a local HTML snapshot and never
launches a browser. `doctor`, `vpn` and `captcha` are also obscura-free.

### CI integration / running ignored E2E tests locally

All obscura-dependent integration tests are tagged `#[ignore]` so plain
`cargo test` stays green on hosts without the binary. To reproduce the
exact matrix that CI runs (verification matrix S1 / S2 / S9, plus the
Phase 5a `cdp_shim_e2e` and Phase 5b `e2e_spider_fallback` harnesses):

```bash
./scripts/run_obscura_e2e.sh                 # builds obscura if missing
./scripts/run_obscura_e2e.sh -- --nocapture  # pass extra args to cargo test
OBSCURA_BIN=/abs/path/obscura ./scripts/run_obscura_e2e.sh
```

The script exports two env vars that gate the test code paths:

| Variable                   | Consumer                                          | Meaning                                  |
| -------------------------- | ------------------------------------------------- | ---------------------------------------- |
| `REV_SCRAPING_RUN_OBSCURA` | `obscura_lifecycle.rs` (S2)                       | Set to `1` to opt in; otherwise tests skip gracefully. |
| `OBSCURA_BIN`              | `obscura_lifecycle.rs`                            | Absolute path to the obscura binary.     |
| `REV_STEALTH_OBSCURA`      | `stealth-cli` (`spider`, `cf-evaluate`)           | Absolute path used by CLI invocations.   |

GitHub Actions (`.github/workflows/ci.yml`) runs the equivalent matrix
on every push to `main` and every PR: a dedicated `build-obscura` job
compiles the vendored binary once (with `vendor/obscura/target` cached
on the vendored revision so V8 snapshots are reused across runs) and
fans the artifact out to the lifecycle / shim / fallback E2E jobs.

### CLI quick start

```bash
# 1. Build release binary.
cargo build --release
# 2. Author the allowlist. Directory must be mode 0700.
mkdir -p -m 0700 ~/.rev_scraping
cat >~/.rev_scraping/authorized.toml <<'TOML'
[[targets]]
url_pattern = "^https://your-authorized-target\\.test/"
TOML

# 3. Spider an authorized URL with CF resilience eval + relocate.
./target/release/rev-stealth \
    --format json \
    spider \
    --url https://your-authorized-target.test/page \
    --cf-evaluate \
    --stable-id product.price \
    --threshold 0.85

# 4. Run cf-evaluate stand-alone.
./target/release/rev-stealth --format json cf-evaluate \
    --url https://your-authorized-target.test/cf-page

# 5. Relocate against a saved HTML fixture (no network).
./target/release/rev-stealth --format json relocate \
    --session-id $(uuidgen) \
    --stable-id product.price \
    --html-file ./page.html \
    --threshold 0.85
```

### MCP quick start

`stealth-mcp` speaks MCP over stdio. As of v1.1.0 P10 (security hardening),
the server ships a hand-rolled JSON-RPC 2.0 implementation pinned to the
MCP `2024-11-05` schema — no `rmcp` dependency. Transport decision §8 #4
remains stdio-only.

#### Claude Code `.mcp.json`

```json
{
  "mcpServers": {
    "rev-scraping": {
      "command": "/abs/path/to/target/release/stealth-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

#### codex `config.toml`

```toml
[mcp_servers.rev-scraping]
command = "/abs/path/to/target/release/stealth-mcp"
args = []
```

#### Exposed tools (`tools/list`)

| Tool          | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| `spider`      | AUP-gated stealth fetch + optional CF eval + relocate        |
| `relocate`    | Adaptive element re-location (HTML file or URL)              |
| `cf_evaluate` | Defender-side Cloudflare Turnstile resilience evaluation     |
| `doctor`      | Pre-flight leak / kill-switch / DNS / IPv6 / WebRTC checks   |
| `vpn_rotate`  | Surfshark / Gluetun rotation (lazy-on-fail)                  |

### Exit codes

| Code | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | OK                                                                   |
| 1    | User error / AUP rejection / bad args / invalid URL                  |
| 2    | Transient error (network, VPN flap, navigation timeout — retryable) |
| 3    | Permanent error (missing binary, unsupported, store I/O)             |
| 7    | Leak detected / fail-closed (`doctor`)                               |
| 8    | CF resilience evaluation: still blocked / probe inconclusive         |
| 9    | Relocate miss (not found, or ambiguous in non-strict mode)           |
| 10   | Relocate ambiguous + `--strict` (also: attrs_hash / neighbor_hash    |
|      | divergence — structured warn always emitted)                         |

### Credits & upstream licenses

- **obscura** (`vendor/obscura/`) — Apache-2.0. Chrome145 TLS/HTTP2 FP
  cache, 3520-entry blocklist, CDP-compatible WebSocket server.
- **Scrapling** — BSD-3-Clause. Design influence on adaptive relocate
  ideas; no verbatim port. Independent reimplementation in
  `stealth-parse`.
- **goscrapy** — BSL. **Design reference only**; zero lines of code.
  Enforced by `scripts/check_bsl_contamination.sh`.

### Defender-testbed disclaimer

This stack is published as a **defender-side evaluation toolkit**.
See the [Authorized Targets Only](#-authorized-targets-only--read-this-before-running-anything)
section above for the binding statements on Cloudflare ToS §2.8,
不正アクセス禁止法, and CFAA. AUP enforcement is implemented
technically (S12) — there is no path through the CLI that reaches a
network without the allowlist, env-ack, or `--i-have-authorization`
flag being honored first.

## §13 VPN Setup (Multi-Instance Gluetun)

Phase 6a ships a 3-instance Gluetun pool that the `vpn-rotate` crate
drives. Each instance is an isolated `qmcgaw/gluetun` container with a
kill-switch firewall, forced DNS-over-TLS, and its own private bridge
network — so a misconfigured rule cannot leak traffic between tunnels.

IPv6 is disabled at two layers (Job E hardening): gluetun env
`BLOCK_IPV6=on` drops IPv6 egress at the container firewall, and
`sysctls.net.ipv6.conf.{all,default,lo}.disable_ipv6=1` turns IPv6 off
in the kernel — the second layer is what `vpn-rotate::leak_guard`
inspects via `HostConfig.Sysctls` to fail-closed on IPv6 leaks.

### Topology

| Instance | Container | HTTP proxy (host) | Control API (host) |
|----------|-----------|-------------------|--------------------|
| vpn-1    | `vpn-1`   | `127.0.0.1:8001`  | `127.0.0.1:8881`   |
| vpn-2    | `vpn-2`   | `127.0.0.1:8002`  | `127.0.0.1:8882`   |
| vpn-3    | `vpn-3`   | `127.0.0.1:8003`  | `127.0.0.1:8883`   |

All ports are bound to `127.0.0.1` only — the pool is never exposed to
the LAN.

### Setup

1. Copy the env template and fill in real credentials:

   ```bash
   cp .env.example .env.local        # preferred (gitignored)
   chmod 600 .env.local
   $EDITOR .env.local                # set VPN_USER, VPN_PASSWORD, VPN_COUNTRIES
   ```

   `scripts/load_env.sh` resolves env files in this order:

   1. `$ENV_FILE` (explicit override)
   2. `<repo>/.env.local` — **preferred** local secrets file
   3. `<repo>/.env` — legacy fallback (still supported, but `.env.local`
      is recommended so personal credentials never collide with a
      shared/team `.env`)

   Both `.env` and `.env.local` are gitignored.

2. Bring up the pool:

   ```bash
   ./scripts/vpn_up.sh
   ```

   The script loads `.env`, runs `docker compose -f
   src/infra/docker-compose.vpn.yml up -d`, waits for each control-API
   healthcheck, probes the egress IP through the HTTP proxy, and writes
   the result to `~/.rev_scraping/vpn_status.json` (chmod 600).

3. Verify leak posture per instance:

   ```bash
   rev-stealth doctor --container vpn-1
   rev-stealth doctor --container vpn-2
   rev-stealth doctor --container vpn-3
   ```

4. Rotate an exit IP on demand (lazy-on-fail by default):

   ```bash
   rev-stealth vpn rotate --provider surfshark --strategy lazy-on-fail
   ```

5. Tear down:

   ```bash
   ./scripts/vpn_down.sh
   ```

### Security notes

- **Never commit `.env` or `.env.local`.** Both are gitignored
  alongside `.env.*.local`. `scripts/load_env.sh` auto-tightens the
  resolved env file's mode to `0600` if it finds it more permissive.
- **No `sudo` required.** Gluetun runs unprivileged: only `cap_add:
  NET_ADMIN` and `/dev/net/tun` are granted. Do not add `privileged:
  true`.
- **Kill-switch is enforced** via `FIREWALL=on`. If the tunnel drops,
  the container's egress is blackholed — clients hitting the HTTP proxy
  will see connection failures instead of leaking to the clear net.
- **DNS leak protection** is enforced via `DOT=on` with `cloudflare,
  quad9` resolvers and `BLOCK_MALICIOUS=on`.
- Each instance lives on its own bridge (`vpn1-net` / `vpn2-net` /
  `vpn3-net`) — no inter-container traffic.

### Linux (Ubuntu 22.04+) parity notes — v1.1.0 P6

The toolkit targets macOS and Linux as first-class platforms. The
Gluetun pool, `vpn-rotate`, `bollard`, and `stealth-auth` paths all
work on Linux Docker (native `dockerd`) the same way they do on macOS
Docker Desktop, with these differences worth knowing:

- **Docker daemon**: macOS uses Docker Desktop's VM-hosted daemon at
  `~/.docker/run/docker.sock`; Linux uses the native `/var/run/docker.sock`.
  `bollard`'s `Docker::connect_with_local_defaults()` selects the right
  socket automatically. If you run the Linux daemon rootless, the
  socket path moves to `$XDG_RUNTIME_DIR/docker.sock`.
- **`cap_add: NET_ADMIN` + `/dev/net/tun`**: identical semantics on
  both platforms. On Linux, ensure the `tun` kernel module is loaded
  (`lsmod | grep tun`; modern Ubuntu loads it on demand). No
  `privileged: true` is needed — and Linux must not add it either.
- **System Chrome**: on Linux the resolver walks `$PATH` for
  `google-chrome`, `google-chrome-stable`, `chromium-browser`, then
  `chromium` (in that order). Override with `--chrome-bin` or
  `REV_AUTH_CHROME_BIN`. macOS uses the standard `/Applications/...`
  bundles. The macOS-only `CFFIXED_USER_HOME` env var is not set on
  Linux — Chrome on Linux respects `--user-data-dir` for all writes,
  so no equivalent is needed.
- **Keyring backend**: the `keyring` v3 crate resolves to **libsecret**
  on Linux (D-Bus Secret Service), which means a running
  `gnome-keyring-daemon` (or `kwalletd`, or `keepassxc` with the
  Secret Service plugin) at run time. Headless Linux CI hosts that
  lack a D-Bus session must use the **passphrase fallback** —
  `cargo build --features passphrase-only` for the `stealth-auth`
  crate, or set `REV_SCRAPING_AUTH_PASSPHRASE` to keep the cookie jar
  encrypted with an Argon2id-derived key (see Phase 9a).
  Build-time deps: `apt-get install -y libsecret-1-dev libdbus-1-dev`.
- **File permissions**: `0600` for files, `0700` for directories under
  `~/.rev_scraping/` — identical helper (`storage::set_file_permissions_0600`
  / `set_dir_permissions_0700`) on both platforms, both verified by
  the P6 Linux parity tests.
- **`/dev/shm` size in containers**: when running Chrome inside a Docker
  container on Linux CI, pass `--disable-dev-shm-usage` if the default
  `/dev/shm` is < 256 MiB (the Chrome flag is already set by the
  `obscura-bridge` builder).

### Fail-closed VPN-required guard (Phase 6c)

`spider`, `cf-evaluate`, and `relocate --url` are **fail-closed by
default**: they refuse to send a single byte off-host unless the
configured Gluetun pool passes a startup leak probe (kill-switch / DNS
lock / IPv6 disabled / exit-IP country). Any failure exits **7
(Leak)** with a JSON error.

1. Install the policy template (once per machine):

   ```bash
   mkdir -p ~/.rev_scraping
   cp templates/policy.toml ~/.rev_scraping/policy.toml
   chmod 600 ~/.rev_scraping/policy.toml
   $EDITOR ~/.rev_scraping/policy.toml   # tighten country / instances
   ```

2. Override precedence (highest wins):

   1. `REV_SCRAPING_REQUIRE_VPN=1` (cannot be loosened by lower layers)
   2. `--require-vpn` CLI flag
   3. `--allow-no-vpn` CLI flag (ignored when env=1)
   4. `policy.toml::require_vpn`
   5. Built-in default = `true`

   `REV_SCRAPING_REQUIRE_VPN=0` is **advisory only** — it never
   loosens a policy that says `true`.

3. `VPN_INSTANCES` env var
   (`vpn-1:8001:8881,vpn-2:8002:8882,...`) overrides the
   `[[vpn_instances]]` table when set, so a single `.env` can drive
   both `docker-compose.vpn.yml` and the leak-guard probe.

4. Pre-existing tests / smoke checks that intentionally run without
   VPN must pass `--allow-no-vpn` explicitly. The default policy will
   not silently let them through.

## §14 Authenticated Scraping (Phase 9)

> **One-time human-driven login → encrypted cookie capture → transparent
> replay** by `spider` / `cf-evaluate` / `relocate` and MCP tools. No
> credential, 2FA, or CAPTCHA automation. Acknowledgment: cookie-capture
> pattern inspired by `rev_magic`.

### Security model

- Encryption: **XChaCha20-Poly1305** AEAD (24-byte nonce), key in OS
  keyring (macOS Keychain / Linux Secret Service / Windows Credential
  Manager). Argon2id passphrase fallback (`--passphrase-fd`,
  fail-closed on headless Linux without explicit opt-in).
- On-disk layout: `~/.config/rev_scraping/auth/<profile>.jar.enc`
  (mode `0600`), parent dir `0700`. Atomic write + fsync.
- AAD: `rev_scraping:stealth-auth:v1:<profile>` binds each blob to
  its filename.
- Delete = shred (`AuthStore::delete` overwrites then unlinks).
- `#![forbid(unsafe_code)]` on the `stealth-auth` crate.
- No `Password` / `TotpSecret` / `RecoveryCode` types in source.

### CLI usage (canonical flow)

```bash
# 1. One-time setup: install policy + extend AUP.
cp templates/policy.toml ~/.rev_scraping/policy.toml
chmod 600 ~/.rev_scraping/policy.toml
cat >> ~/.rev_scraping/authorized.toml <<'TOML'
[[targets]]
url_pattern = "example\\.com"
auth_allowed = true
TOML

# 2. Interactive login (opens a headed browser via the rev-auth
#    helper subprocess; you sign in manually).
rev-stealth auth login \
  --profile my_account \
  --url    https://example.com/login \
  --domain example.com

# Optional: bypass the VPN-required guard for this login (env REV_SCRAPING_REQUIRE_VPN=1 still wins).
rev-stealth auth login --profile my_account --url https://example.com/login --domain example.com --allow-no-vpn

# 3. Replay during scraping. The session cookie + UA captured at
#    login are transparently applied to both HTTP fetch and CDP.
rev-stealth spider \
  --url https://example.com/members/page \
  --use-auth my_account

# 4. Inspect, refresh, delete.
rev-stealth auth list
rev-stealth auth status --profile my_account   # exit 4 if AllExpired
rev-stealth auth delete --profile my_account --force
```

### MCP usage (two-phase, human-in-the-loop)

MCP cannot block for minutes waiting for a human, so login is a
two-call sequence:

```jsonc
// 1. Agent calls auth_login_start. Server spawns rev-auth, opens a
//    browser on the user's desktop, returns a session_token + a
//    completion marker path.
{"tool":"auth_login_start","arguments":{
  "profile":"my_account",
  "url":"https://example.com/login",
  "domain":"example.com"
}}

// 2. User completes the login in their browser. rev-auth writes the
//    encrypted jar and drops a marker file.

// 3. Agent polls auth_login_complete with the session_token; the
//    server returns success once the marker appears.
{"tool":"auth_login_complete","arguments":{
  "session_token":"<uuid from step 1>"
}}
```

MCP invariants:

- No tool ever returns cookie values. Every output envelope carries
  `"cookie_values_returned": false`.
- No `auth_export` over MCP. CLI-only, audited, TTY-gated.
- Per-session consent token (TTL 1 hour).

### Exit codes (auth-specific)

| Code | Meaning                                     |
|------|---------------------------------------------|
| 0    | OK                                          |
| 1    | UserError (AUP refusal, bad args)           |
| 4    | **AuthExpired** (Phase 9 new, additive)     |
| 7    | VPN leak / kill-switch trip                 |

### ⚠️ Legal disclaimer

**Use this feature only against accounts and properties you own or
are explicitly authorized to access.**

- **Japan:** 不正アクセス禁止法 (Act on Prohibition of Unauthorized
  Computer Access, 不正アクセス禁止法). Using captured cookies to
  reach a system you are not authorized to use is a criminal offence.
- **United States:** Computer Fraud and Abuse Act (CFAA, 18 U.S.C.
  § 1030). Authorized access only.
- **Service Terms:** Most consumer SNS (Twitter/X, Meta/Facebook/
  Instagram, LinkedIn, TikTok, …) prohibit automated cookie reuse in
  their ToS. Even if technically possible, doing so may violate the
  contract you accepted when you signed up. Default
  `AuthRefusalPolicy::RefuseByDefault` ships for these hosts.
- **EU / EEA:** GDPR — captured cookies may contain personal data
  about you and third parties. Treat the encrypted jar as personal
  data of the data subjects who logged in.

The encryption posture above is strong, but **YOU are the data
controller** for cookies you capture. Loss, leakage, or misuse is
your responsibility.

**Explicitly out of scope for Phase 9:**

- Automated credential entry, 2FA solving, CAPTCHA solving.
- Silent auto-refresh / daemonised re-login.
- Passkey / WebAuthn replay.

If you need any of these, you are outside the design envelope —
stop, re-read this section, and reconsider.

---

## §15 Troubleshooting

Common failures observed during v1.0.0-dev → v1.1.0 development. Each
row links a symptom to a deterministic repair.

| Symptom | Root cause | Repair |
| ------- | ---------- | ------ |
| `obscura: native dialog stole focus` during spider | Chrome 145 dialog handler races CDP attach (hotfix-2). | Upgrade to v1.1.0+; the bridge now dismisses dialogs via `Page.javascriptDialogOpening` before `Network.enable`. |
| `vpn-rotate: docker daemon unreachable` | Gluetun container not running or wrong socket path. | `docker ps` to confirm; export `DOCKER_HOST=unix:///var/run/docker.sock`; see §13. |
| `auth login: profile is locked` | A previous `rev-auth login` crashed without releasing the SQLite WAL lock. | `rm ~/.rev_scraping/auth/<profile>.lock` after confirming no other process holds it. |
| `SPDX header missing` from `scripts/check_source_and_spdx.sh` | New `.rs` file added without the `// SPDX-License-Identifier: MIT` line. | Add the header as the first line of the file; re-run the check. |
| `auth login` refuses to run without VPN | `REV_SCRAPING_REQUIRE_VPN=1` is the default for authenticated flows. | Either start the VPN (§13) or, on an explicitly authorized localhost / lab target, pass `--allow-no-vpn`. The env var always wins. |
| `cargo-deny: license = "BSL-1.1"` | A transitive dep upgraded to BSL. | Pin or replace; goscrapy-style BSL is forbidden by `scripts/check_bsl_contamination.sh`. |

## §16 Production deployment (Contabo / Linux server)

`rev_scraping` v1.1.0 is verified on **Ubuntu 22.04 / 24.04 LTS** with
the P6 Linux baseline (`.agent/active/v1_1_p6_linux_baseline.md`).
Production install (single host, headless):

```bash
# 1. System prerequisites (Debian/Ubuntu)
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libssl-dev \
    libsqlite3-dev ca-certificates chromium docker.io

# 2. Toolchain (rustup; pinned via rust-toolchain or workspace.rust-version=1.83)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 3. Build obscura out-of-tree (Apache-2.0, see NOTICE)
( cd vendor/obscura && cargo build --release )
sudo install -m 0755 vendor/obscura/target/release/obscura /usr/local/bin/

# 4. Build rev_scraping
cargo build --release --workspace

# 5. Install binaries
sudo install -m 0755 target/release/{rev-stealth,rev-auth,stealth-mcp} \
    /usr/local/bin/

# 6. State directory (mode 0700 mandatory for AUP allowlist + auth jar)
install -d -m 0700 ~/.rev_scraping
```

- **Systemd unit** (optional): see `docs/release-checklist.md` for a
  template `rev-stealth-mcp.service` (Type=simple, no privileged caps).
- **Resource sizing**: 2 vCPU / 4 GB RAM per concurrent obscura
  instance; SQLite WAL grows linearly with `relocate` history (auto-
  pruned after 30 d).
- **Reverse-proxying the MCP server is NOT supported** — MCP is stdio
  by design (§8 #4). Run it as a child of the agent process.

## §17 Performance tuning

| Knob | Default | Recommendation |
| ---- | ------- | -------------- |
| `--concurrency` (spider) | 1 | Increase **only** after measuring per-target politeness; stay ≤ 4 for authorized targets unless ToS explicitly permits otherwise. |
| `stealth-parse` recipe cache | in-memory LRU 256 | Bump `REV_SCRAPING_PARSE_CACHE=1024` for long-running sweeps over a single target. |
| SQLite WAL checkpoint | autocheckpoint 1000 pages | Run `PRAGMA wal_checkpoint(TRUNCATE);` weekly via cron for hot workloads. |
| obscura process pool | 1 child per `rev-stealth` invocation | For parallel CLI runs, prefer fanning out at the agent layer — the bridge does not pool. |
| `mobile-fp` preset reuse | per-invocation | Pin one preset for the duration of a session; switching mid-flight invalidates the TLS cache. |

Profile with `RUST_LOG=info,stealth_parse=debug` and the bundled
`measure` deliverable; do **not** ship `RUST_LOG=trace` to production
(captures cookies in traces).

## §18 Privacy & compliance

`rev_scraping` is a **defender-facing evaluation toolkit**. Re-read
[§ Authorized Targets Only](#-authorized-targets-only--read-this-before-running-anything)
before every engagement.

- **Authorization is technical, not advisory.** The CLI cannot reach
  the network without one of: (a) `~/.rev_scraping/authorized.toml`
  (mode 0700) listing the host, (b) `REV_SCRAPING_I_HAVE_AUTHORIZATION=1`
  acknowledgement, or (c) `--i-have-authorization` flag. S12 enforces
  this in code paths, not docs.
- **ToS reminders.** Cloudflare Terms §2.8; Japan 不正アクセス禁止法
  (Act on Prohibition of Unauthorised Computer Access); U.S. CFAA
  (18 U.S.C. §1030); EU NIS2 / GDPR. Cookie reuse on third-party
  consumer SNS is contractually prohibited even when technically
  possible — see §14.
- **Data minimisation.** Captured cookies and HTML are stored only
  under `~/.rev_scraping/` (mode 0700). Delete after the engagement
  with `rev-auth wipe` and `rm -rf ~/.rev_scraping/parse.sqlite*`.
- **Logging hygiene.** Default tracing redacts cookie values and
  `Authorization` headers. Do not raise to `trace` in shared logs.
- **Reporting vulnerabilities** in `rev_scraping` itself: see
  [`SECURITY.md`](./SECURITY.md).

## §19 Upgrading from v1.0.0-dev

| Area | v1.0.0-dev | v1.1.0 | Migration |
| ---- | ---------- | ------ | --------- |
| Crate count | 9 | 11 (`stealth-sites`, `stealth-auth` added) | Rebuild; new path deps resolve automatically. |
| MCP transport | `rmcp 0.1` planned | Hand-rolled JSON-RPC 2.0 pinned to MCP 2024-11-05 | Re-run agent `tools/list`; tool names unchanged. |
| `auth login` | always required VPN | `--allow-no-vpn` flag added (env still wins) | Update scripts that relied on the implicit refusal. |
| `ProfileStatus` (stealth-auth) | `Active` / `Expired` | + `Stale`, `Revoked` (new variants) | Match exhaustively; default arm recommended for forward compat. |
| JSON envelope | no `warn_level` | adds `warn_level: "info" | "warn" | "error"` | Consumers must tolerate unknown extra fields (we always did, now load-bearing). |
| Supply chain | manual review | `cargo-deny` + `cargo-audit` + `gitleaks` in CI | None — informational. |
| Removed | `wreq`, `rmcp` workspace deps (never wired) | dropped | None — no consumers existed. |

Run `cargo clean && cargo build --release --workspace` after upgrade;
recipe cache SQLite is forward-compatible.

## §20 Contributing

Pull requests are welcome. Before opening one, please read:

1. [`CONTRIBUTING.md`](./CONTRIBUTING.md) — dev setup, SPDX header
   rule, test naming, PR format.
2. [`SECURITY.md`](./SECURITY.md) — never file a security issue
   publicly; use the private channel listed there.
3. [`docs/CODE_OF_CONDUCT.md`](./docs/CODE_OF_CONDUCT.md) —
   Contributor Covenant 2.1.

The `rev` short binary alias (e.g. `rev spider ...` aliasing
`rev-stealth spider ...`) is on the **v1.2 roadmap**; it is
deliberately not in v1.1.0 to keep the bin surface area small.
