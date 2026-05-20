# v1.1.0 Follow-up — VPS Deployment Feasibility Audit

> **Status:** Design-only (read-only audit). No source changes.
> **Owner:** Claude opus 4.7-high
> **Scope:** Assess feasibility of deploying `rev_scraping` to a headless Linux VPS
> (Contabo / Hetzner / DigitalOcean class) end-to-end — auth capture, scraping
> runtime, VPN egress, MCP exposure, encrypted persistence.
> **References consulted:**
>
> - `.agent/active/v1.1.0_execplan_rev1.md` (P1-P19, M1-M6 plan)
> - `.agent/active/v1_1_p6_linux_baseline.md` (Linux parity verification)
> - `.agent/active/v1_1_audit_linux_gap.md`
> - `crates/stealth-auth/src/bin/rev_auth.rs` (headed-only auth binary)
> - `crates/stealth-core/src/browser.rs` (scraping browser, headless-capable)
> - `crates/stealth-mcp/src/{main,server}.rs` (stdio MCP transport)
> - `crates/stealth-auth/src/keystore.rs` (keyring vs passphrase-only)
> - `src/infra/docker-compose.vpn.yml` (gluetun pool, NET_ADMIN)
>
> **Non-goals:** writing any deploy script, systemd unit, terraform, or Dockerfile.
> Those are explicitly deferred to a future Phase 10 (proposed at the end).

---

## A. Current VPS readiness — quantitative assessment

### A.1 Component-by-component readiness matrix

| Component | Headless-Linux ready? | Evidence | Readiness |
|-----------|----------------------|----------|-----------|
| Workspace build (Rust stable, Ubuntu 22.04) | YES | P6 baseline — `cargo build --workspace` green on Ubuntu 22.04 with `libssl-dev libdbus-1-dev libsecret-1-dev`. Lockfile drift (MSRV 1.83 vs `clap_derive 4.6.1`) called out as pre-existing, not Linux-specific. | 95% |
| `stealth-core` scraping browser | YES | `browser.rs:139-147` honours `profile.headless`: when true, builder calls `new_headless_mode()` (HeadlessMode::New — the modern surface, not the bot.sannysoft-detected legacy mode). No DISPLAY required. | 100% |
| `obscura` subprocess (V8/CDP) | YES | P6 §9 confirms obscura is a pure Rust binary, "no system Chrome dependency". CI builds it on Ubuntu. No DISPLAY needed; CDP listens on a Unix domain socket / TCP port. | 95% |
| `rev-auth` interactive login | **NO** | `rev_auth.rs:530` hard-codes `.with_head()`. Test `headed_launch_uses_with_head_flag` asserts `headless: False`. No CLI flag to override. On a VPS with no DISPLAY, `Browser::launch` will fail (`chrome launch: ...`, exit code 1). This is the **single largest blocker.** | 0% (without workaround) |
| VPN docker (gluetun pool) | YES | `docker-compose.vpn.yml` already uses minimum-privilege `cap_add: NET_ADMIN` + `/dev/net/tun`. P6 §7: "portable on Docker Desktop (macOS) and native Linux dockerd identically." Bound to `127.0.0.1` only — no public exposure. | 95% |
| Cookie persistence (`*.enc`) | YES | `storage.rs::set_file_permissions_0600` / `set_dir_permissions_0700` verified on Linux (P6 §5 test `auth_file_perm_0600_on_linux`). Format is platform-identical. | 100% |
| Keyring (libsecret/D-Bus) on VPS | PARTIAL | P6 §5(3) confirmed: headless containers have no D-Bus session bus → `keyring::Entry::new` errors. Mitigation already in code: `stealth-auth/passphrase-only` Cargo feature + `KeySource::Passphrase` (Argon2id KDF over `REV_SCRAPING_AUTH_PASSPHRASE`). | 80% (with feature flag + env var) |
| `stealth-mcp` server | PARTIAL | `server.rs:50` `run_stdio()` reads JSON-RPC from stdin → stdout. Works fine under systemd `Type=simple` with a socket-activated wrapper or via SSH. No native TCP/Unix-socket transport. Remote MCP clients must SSH-tunnel. | 70% |
| systemd unit files | NO | `scripts/` contains only shell helpers (`vpn_up.sh`, `run_obscura_e2e.sh`, `run_soak.sh`). No `*.service`, no `*.socket`, no `tmpfiles.d` snippet. Has to be authored. | 0% |
| `.env` / secrets injection | PARTIAL | `.env.example` exists; `scripts/load_env.sh` sources it. Fine for dev. Production VPS should use `EnvironmentFile=` on systemd or a secret store (sops-nix, doppler, age-encrypted env). Not addressed by repo. | 50% |
| Origin IP exposure / reverse SSH | NO | No documentation around how to expose MCP to an external agent (e.g., Claude Code running on the operator laptop) without binding a public port. Need SSH `RemoteForward` recipe or Cloudflare Tunnel/Tailscale guidance. | 0% |

### A.2 Aggregate readiness score

Weighted by "blocker severity to a real headless deploy":

| Capability bucket | Weight | Score | Contribution |
|------------------|--------|-------|--------------|
| Build & run scraping pipeline | 25% | 95% | 23.75 |
| Auth capture (rev-auth login) | 25% | 0%  | 0.00 |
| VPN + leak guard | 15% | 95% | 14.25 |
| Persistence (cookies + secrets) | 15% | 85% | 12.75 |
| MCP exposure for remote ops | 10% | 70% | 7.00 |
| Operability (systemd/secrets/observability) | 10% | 20% | 2.00 |
| **Total** | 100% | — | **≈ 59.75 / 100** |

**Bottom line: ~60% ready.** The scraping engine, obscura, VPN topology,
on-disk crypto, and the bulk of Linux parity work are done. The remaining 40%
is dominated by two structural gaps: (1) `rev-auth` cannot run on a headless
VPS today, and (2) there is no productionisation layer (systemd / secrets /
MCP exposure / observability).

---

## B. Critical blockers (ranked)

### B.1 — `rev-auth login` requires a display

**Severity:** P0 (deploy-stopping)
**Evidence:** `crates/stealth-auth/src/bin/rev_auth.rs:530`

```rust
let mut builder = BrowserConfig::builder()
    .chrome_executable(chrome_bin)
    .with_head()              // ← unconditional
    ...
```

Test `headed_launch_uses_with_head_flag` (line 1039) locks this in.
There is no `--headless` flag, no env override, no policy hook.

The auth flow is fundamentally interactive — the user signs in by hand in
the Chrome window, then presses ENTER on stdin (`wait_for_user_or_pattern`
at line 565). Even if we flipped to headless, a human still has to drive
the OAuth / 2FA flow.

On a VPS with no DISPLAY:

- `Browser::launch` will spawn Chrome, Chrome will fail to open a window
  (`Missing X server or $DISPLAY`), and chromiumoxide will return
  `ChromeLaunchError`.
- `EXIT_USER` (1) is emitted; the wrapper `rev-stealth auth login` surfaces
  it as a generic failure.

### B.2 — No systemd / supervisor unit

**Severity:** P1 (operability, not correctness)

`stealth-mcp` is stdio-only; without a wrapper there is no way to:

- Restart on crash.
- Capture structured stderr to journald.
- Apply per-service resource limits (`MemoryMax`, `TasksMax`, `LimitNOFILE`).
- Run scraping batch jobs on a `OnCalendar=` timer.

The fix is purely additive (`*.service` templates), but until those land
the VPS deploy is "tmux + nohup" tier.

### B.3 — Keyring unavailable; passphrase prompt is interactive

**Severity:** P1

P6 already verified the `passphrase-only` Cargo feature works, BUT:

- The feature must be enabled at compile time, so the binary shipped to
  the VPS must be a separate build (or feature must be made default for
  the VPS profile).
- `AuthStore::open` calls `rpassword`/stdin to prompt for the passphrase
  if `REV_SCRAPING_AUTH_PASSPHRASE` is not set. A systemd-managed service
  cannot answer that prompt. So the env var MUST be in the unit's
  `Environment=` / `EnvironmentFile=`, which means the passphrase is
  visible to `systemctl show` for any user with sufficient privilege —
  ideally we want `LoadCredentialEncrypted=` (systemd ≥ 250) with a
  TPM-bound key, or read from a secret-manager socket.

### B.4 — MCP origin exposure model is undefined

**Severity:** P2 (deferred-can-live-with for now)

`stealth-mcp` only speaks stdio. To call it from an external agent we have to
SSH in and run it inline (`ssh vps stealth-mcp`), or wire a stdio→TCP relay
(`socat`, `systemd-socket-activate`). Neither is documented. There is no
discussion of:

- Mutual auth (SSH already covers this, but the recipe matters).
- Replay protection on the JSON-RPC stream (currently none — relies on
  transport).
- Rate-limiting of expensive ops (`spider`, `auth login`) — irrelevant for a
  trusted SSH peer, becomes critical the moment anyone wants to expose MCP
  via Cloudflare Tunnel / Tailscale.

### B.5 — Cookie/secret persistence under VPS volume model

**Severity:** P2

`~/.config/rev_scraping/auth/*.enc` is encrypted at rest, but:

- Contabo's default volume is **not** encrypted; an attacker with cold-storage
  access reads the ciphertext + sees the salt. The Argon2id derivation is the
  only barrier — passphrase entropy is load-bearing.
- Hetzner Cloud Volumes are LUKS-on-host but the key is held by Hetzner.
- DigitalOcean encrypts at rest only for the underlying storage fabric — same
  caveat.

The recommendation is **dm-crypt / LUKS on the VPS** for the data partition
that holds `~/.config/rev_scraping`. The passphrase derivation crypto in the
repo is sound; the threat is the host operator, not the cookie format.

---

## C. Workaround comparison — interactive auth on VPS

The question is: how does a human complete an interactive sign-in on
instagram.com / x.com / etc. when the binary needs to run on a headless VPS?

### C.1 Comparison matrix

| Workaround | One-line summary | Latency | Cost | Security | Implementation effort | Recommended? |
|------------|-------------------|---------|------|----------|----------------------|--------------|
| **Local-capture + export** | Run `rev-auth login` on the operator laptop; rsync the encrypted `.enc` to the VPS. | none (offline) | $0 | **Best** — passphrase + cookie never leave the local box in plaintext; VPS only sees ciphertext. AAD context binding still works. | Low — already supported. Need a documented `rev-auth export` / `rev-auth import` flow (zero code today, just `scp ~/.config/rev_scraping/auth/<profile>.enc vps:~/...`). | **YES (primary)** |
| **Xvfb (virtual framebuffer)** | `xvfb-run -a -s "-screen 0 1280x800x24" rev-auth login ...` | ~1s startup overhead | $0 | Medium — Chrome runs on a fake X server, but the user has no way to *see* the screen. Only useful in combination with VNC or screen-sharing. | Low — apt install xvfb; wrap launch. Code change small. | **No (use VNC instead)** |
| **Xvfb + x11vnc + SSH tunnel** | Start Xvfb, attach x11vnc, expose only on localhost; user SSH-forwards 5900. | ~50-100 ms input latency over SSH | $0 (open-source); $5-10/mo for an extra VPS RAM tier | Medium-good — VNC traffic tunnelled inside SSH; no public port. Need to remember to kill the VNC server after login. Susceptible to clipboard / keystroke leakage if VNC client is misconfigured. | Medium — bash wrapper, ufw rule, systemd unit. | **YES (fallback when local-export not viable, e.g. site IP-binds the session)** |
| **noVNC (browser-based VNC over HTTPS)** | Same as above but the operator uses a browser → Caddy reverse-proxy → noVNC → Xvfb. | ~80-150 ms | $0 + TLS cert (Let's Encrypt) | Medium — adds an HTTPS-exposed surface; must be gated behind basic-auth + IP allowlist + fail2ban. More moving parts than SSH-VNC. | High | No |
| **SSH X11 forwarding (`ssh -X`)** | Just forward Chrome's X protocol to the operator's local X server (XQuartz on macOS). | very high — Chrome over X11 is unusable (10+ s/frame) | $0 | Medium | Trivial | No — known to be unusably slow for modern Chrome |
| **Browserless / Selenium Grid (managed)** | Outsource Chrome to a managed service; `rev-auth` connects via CDP-over-WSS. | dependent on provider region | $50-200/mo | **Worst** — credentials transit a third party; provider has full session access. | Medium — needs a `--cdp-endpoint` flag in `rev_auth.rs`. | No — kills the threat model |
| **Self-hosted browserless on a separate VPS** | Spin a dedicated Chrome-in-Docker box; `rev-auth` connects via WSS. | low (same region) | $5-10/mo extra | Medium — adds an attack surface; the bridge VPS holds plaintext cookies in memory. | High — new flag, new container, CDP transport tests. | No (over-engineered for the threat model) |
| **Manual cookie paste + import** | User opens dev tools in their normal browser, copies cookies into a JSON, `rev-auth import --from-json file.json`. | none | $0 | Worst-of-class — plaintext cookies in shell history, clipboard, file. Defeats the AAD model. | Medium (new subcommand) | No |

### C.2 Recommendation: dual-track

**Track 1 (default): local-capture + secure rsync.** Document a flow:

1. Operator runs `rev-auth login --profile X` on their workstation (works today).
2. Operator runs `scp -p ~/.config/rev_scraping/auth/X.enc vps:~/.config/rev_scraping/auth/X.enc`.
3. Operator ensures `REV_SCRAPING_AUTH_PASSPHRASE` is in the systemd unit's
   credential store (or, better, that the VPS uses LUKS and the passphrase
   is supplied at boot via SSH).
4. AAD context (`aad_context` argument) must be set identically on both sides.

This is **zero code change** + **best security** + **fastest to roll out**.
The only constraint: it does not work if a site IP-pins the session (some
banks, some enterprise SaaS). For instagram.com / x.com / typical SaaS, IP
pinning is rare for cookie sessions.

**Track 2 (fallback): Xvfb + x11vnc behind SSH.** Required when the captured
cookie must be born on the VPS IP. Adds:

- `xvfb-run` wrapper inside a `rev-auth-vnc.service` unit.
- `x11vnc -localhost -nopw -display :99 -bg` started by the same unit.
- Operator runs `ssh -L 5900:127.0.0.1:5900 vps`, opens VNC viewer to
  `localhost:5900`, completes login.
- Service tears down VNC+Xvfb on `rev-auth` exit (use `ExecStopPost=`).

---

## D. Recommended deployment architecture

### D.1 Topology (text diagram)

```
┌────────────────────────────────────────────────────────────────────┐
│ Operator laptop (macOS)                                            │
│                                                                    │
│  ┌──────────────┐    ┌─────────────────┐                          │
│  │ rev-auth     │───▶│ ~/.config/...   │                          │
│  │ (headed,     │    │ /auth/X.enc     │                          │
│  │  local only) │    └─────────────────┘                          │
│  └──────────────┘             │                                    │
│                               │ scp -p (over SSH)                  │
│                               ▼                                    │
│  ┌────────────────────────────────────────┐                       │
│  │ ssh client (ControlMaster, ed25519)    │                       │
│  └────────────────────────────────────────┘                       │
└──────────────────────────────│─────────────────────────────────────┘
                               │ SSH (port 22 only)
                               │ LocalForward 7777:127.0.0.1:7777 (MCP)
                               │ RemoteForward (none — VPS does not call back)
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ VPS (Hetzner CX22 / Contabo VPS-S / DO Premium AMD 4GB)            │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ LUKS-encrypted /var/lib/rev_scraping  (passphrase via        │ │
│  │ systemd-cryptenroll + remote-unlock over SSH at boot)        │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  systemd:                                                          │
│   - rev-scraping-vpn.service    (docker compose up of gluetun-1..3)│
│   - rev-scraping-mcp.socket     (listens 127.0.0.1:7777)           │
│   - rev-scraping-mcp@.service   (per-connection, stdio bridge)     │
│   - rev-scraping-soak.timer     (optional periodic test)           │
│                                                                    │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                   │
│  │  vpn-1     │  │  vpn-2     │  │  vpn-3     │  (each cap_add    │
│  │  gluetun   │  │  gluetun   │  │  gluetun   │   NET_ADMIN,      │
│  │  127.0.0.1 │  │  127.0.0.1 │  │  127.0.0.1 │   /dev/net/tun)   │
│  │  :8001     │  │  :8002     │  │  :8003     │                   │
│  └────────────┘  └────────────┘  └────────────┘                   │
│         ▲              ▲              ▲                            │
│         └──────────────┼──────────────┘                            │
│                        │ HTTP proxy                                 │
│  ┌─────────────────────┴────────────┐                              │
│  │ stealth-mcp (stdio, started by    │                              │
│  │ socket-activated unit)            │                              │
│  │   ↳ spawns obscura on demand      │                              │
│  │   ↳ reads ~/.../auth/*.enc        │                              │
│  └───────────────────────────────────┘                              │
└────────────────────────────────────────────────────────────────────┘
```

### D.2 Trust boundaries

1. **Operator laptop ↔ VPS:** SSH only. ed25519 keys; no password auth;
   `Match Address` restricts to operator's static IPs if practical.
   Surfshark on the operator laptop is *optional* and does not add a
   security property the VPS-side gluetun pool doesn't already give.
2. **VPS host ↔ scraping egress:** VPS public IP must NEVER be the egress
   for site traffic. Enforced by the existing `vpn-rotate::leak_guard`
   which inspects `HostConfig.Sysctls` and probes egress. Add a host-level
   `iptables` rule (Phase 10 deliverable) that drops any outbound to
   well-known target ports except via the gluetun bridges.
3. **VPS ↔ Surfshark over VPS IP:** The question "does adding a host-level
   VPN on top of the gluetun-in-docker layer help?" — **no, generally not.**
   Reasoning:
   - The VPS already has a fixed public IP. Surfshark-on-host would replace
     that with a Surfshark exit IP, but gluetun-in-docker already does
     exactly that for the scraping containers. Two layers = no extra
     anonymity; just doubled latency and a new failure mode.
   - There is one narrow case where host-VPN helps: hiding *operator SSH
     access* from the VPS provider's traffic logs. That's a different
     threat model (provider-side observability) and is better solved by
     using Tailscale / WireGuard for the management plane.

### D.3 Recommended specs

| Provider | Plan | Why |
|----------|------|-----|
| Hetzner | CPX21 (3 vCPU AMD, 4 GB, 80 GB NVMe, 20 TB/mo, ~€5.83/mo) | Best price/perf; native dockerd; LUKS works out of the box; EU jurisdiction. |
| Contabo | VPS S (4 vCPU, 8 GB, 100 GB NVMe, ~€4.50/mo) | Cheapest; caveat — Contabo's "VPS" is OpenVZ-adjacent KVM, but `/dev/net/tun` IS exposed (verified in their docs). Confirm before commit. |
| DigitalOcean | Premium AMD 2vCPU 4GB ($24/mo) | Most expensive of the three but the most mature dockerd + best API for ephemeral test VPSes. |

Minimum spec rationale: 4 GB RAM because gluetun × 3 + Chrome (under
stealth-core's `scrape` flow) + obscura together peak around 1.5-2 GB.
2 vCPU minimum to avoid Chrome jank during navigation events.

---

## E. Phase 10 — proposed scope ("VPS productionisation")

Status: **proposal only** for the v1.2 milestone. v1.1.0 GA does not block on this.

### E.1 Deliverables

| ID | Deliverable | Estimated effort | Notes |
|----|-------------|------------------|-------|
| P10.1 | `--headless` / `--remote-display` flag for `rev-auth`, env var `REV_AUTH_HEADLESS={0,1,xvfb}`. Default remains headed (operator-laptop UX unchanged). | 0.5d | Pure CLI / config change. Tests gated on `target_os = "linux"`. |
| P10.2 | `docs/deploy/vps.md` — operator runbook for the local-capture + scp-export flow. | 0.5d | No code. Documents Track 1 (C.2). |
| P10.3 | `dist/systemd/rev-scraping-mcp.{service,socket}` + `rev-scraping-vpn.service` + `rev-scraping-soak.timer` templates. | 1.0d | Use `LoadCredentialEncrypted=` for the passphrase; `ProtectSystem=strict`, `NoNewPrivileges=`, `MemoryMax=2G`. |
| P10.4 | `scripts/install-vps.sh` — idempotent installer: pin Rust toolchain, install libsecret/libssl/docker, place units, enable timers. | 1.0d | Targets Ubuntu 22.04 LTS only at first. |
| P10.5 | `dist/xvfb/rev-auth-vnc.service` — fallback VNC-over-SSH unit (C.2 Track 2). | 0.5d | Includes `ExecStopPost=` teardown. |
| P10.6 | LUKS / dm-crypt guidance in `docs/deploy/vps.md` § "Persistence". Covers `cryptsetup luksFormat`, `systemd-cryptenroll`, optional `dropbear-initramfs` for remote unlock. | 0.5d | Docs only. |
| P10.7 | `vpn-rotate::leak_guard` extension: optional host-level iptables egress probe (`bollard` cannot reach this; would use `nftables` or `iptc` crate). Detects the "container leak via host route" case. | 1.5d | Optional; only if we observe host-route leaks during P10.4 dry-runs. |
| P10.8 | MCP exposure recipe — SSH `LocalForward 7777:127.0.0.1:7777` + `socat` stdio bridge OR `systemd-socket-activate` template. | 0.5d | Documentation + one helper script. Does NOT add a TCP transport to `stealth-mcp` itself. |
| P10.9 | `rev-stealth doctor --vps` — extends existing doctor with VPS-specific checks: LUKS mount status, gluetun health, `DISPLAY` heuristic ("if unset and `--headless` not passed, warn"), keyring vs passphrase mode resolution. | 0.5d | Pure additive. |

**Total estimated effort: ~6.5 person-days.** Sequencing: P10.1 + P10.2 first
(unblocks operator dogfooding); P10.3 + P10.4 second (productionisation);
P10.5 + P10.6 + P10.8 in parallel; P10.7 + P10.9 last (polish).

### E.2 Out of scope for Phase 10

- New crate (`rev-deploy` or similar). Everything fits under existing crates.
- Multi-VPS orchestration / clustering. v1.2 territory.
- Cloud-provider-specific terraform. The repo stays cloud-agnostic; ops
  docs cover Hetzner as the reference target.
- Public-facing MCP gateway (Cloudflare Tunnel, Tailscale Funnel, etc.).
  Explicitly avoided — the operator-SSH model is sufficient and minimises
  attack surface.
- Replacing gluetun. The existing pool already meets the threat model.

### E.3 Acceptance gates

A Phase 10 PR is mergeable when:

1. `rev-auth login --headless` exits cleanly under Xvfb in a Docker
   `ubuntu:22.04` container with no DISPLAY.
2. `systemctl --user start rev-scraping-mcp.socket` succeeds; a smoke
   JSON-RPC `tools/list` over `nc 127.0.0.1 7777` returns within 2s.
3. `scripts/install-vps.sh` is idempotent (a second run is a no-op).
4. `docs/deploy/vps.md` contains a verifiable rsync-export recipe with
   a sample `aad_context` value and a security-considerations section
   covering the LUKS threat model.
5. No regression in the macOS dev workflow (P6 baseline + all v1.1.0 GA
   gates remain green).

### E.4 Consistency with `v1.1.0_execplan_rev1.md`

- M1-M6 (P1-P19) cover Linux **parity**, not Linux **productionisation**.
  Phase 10 is a strict superset: it builds on the P6 keyring/passphrase
  conclusion, the P8 VPN routing design, the P9 obscura-rewire decision,
  and the P19 soak harness.
- No change to BSL contamination policy, SPDX headers, or `deny.toml`.
- The `--headless` flag for `rev-auth` (P10.1) is additive and preserves
  the current default. No existing tests need rewriting.
- The systemd units (P10.3) live under `dist/` — a new directory — so
  they cannot collide with any of the audited crates / existing scripts.

---

## Appendix — quick reference

### Exit codes touched by VPS mode

| Code | Existing meaning | Behaviour on VPS without workaround |
|------|------------------|-------------------------------------|
| 1 (EXIT_USER) | misuse | Chrome launch fails → surfaced as `chrome launch: ...` |
| 3 (EXIT_CHROME_NOT_FOUND) | binary missing | Hit if `google-chrome` not on PATH; resolver tested in P6 §6 |
| 4 (EXIT_AUTH_EXPIRED) | all cookies expired | Unchanged on VPS |
| 7 (EXIT_LEAK) | VPN leak | Most likely error class on VPS without proper gluetun + iptables |
| 12 (EXIT_ABORTED) | user aborted | n/a on a service-managed run |

### Headless mode is already wired in `stealth-core`

`crates/stealth-core/src/browser.rs:139-147` — the scraping browser
respects `StealthProfile::headless`. The reference profile sets it to
`false` for dev convenience (`browser.rs:433`); a VPS profile would
flip it to `true`. The wrapping CLI (`rev-stealth scrape ...`) already
plumbs this through. **No VPS work needed on the scraping side.**

### Bottom-line one-liner for an operator

```
# On laptop:
rev-auth login --profile site_X --url https://... --domain ...
scp -p ~/.config/rev_scraping/auth/site_X.enc vps:.config/rev_scraping/auth/

# On VPS (one-time):
systemd-cryptenroll --tpm2-device=auto /dev/disk/by-uuid/<luks-uuid>
systemctl --user enable --now rev-scraping-vpn.service \
                              rev-scraping-mcp.socket

# From laptop (each session):
ssh -L 7777:127.0.0.1:7777 vps    # MCP available at localhost:7777
```

This is the target experience after Phase 10 lands.
