# v1.1.0 GA — P1 Audit: v1.0.0-dev Artifacts Inventory

> **Phase:** P1 (Repo audit — foundational)
> **Purpose:** snapshot of all v1.0.0-dev shipped artifacts that v1.1.0 sub-phases will extend or amend. Used as the "before" reference for §15-§20 doc additions, naming reconciliation, and Linux parity work.

---

## 1. ExecPlan / design artifacts (`.agent/active/*.md`)

| File | Role |
|---|---|
| `plan_v1.0.0.md` | original v1.0.0 plan (Phase 1-9) |
| `phase8_proxy_routing_design.md` | Phase 8 per-site proxy routing |
| `phase9_plan_A_opus.md` / `phase9_plan_B_codex.md` / `phase9_execplan_rev1.md` | Phase 9 (auth) plan A/B + rev1 synthesis |
| `phase9_hotfix1_followups.md` | hotfix-2 follow-up notes (cookie order + dialog) — directly feeds B1 |
| `vpn_required_design.md` | Phase 6c fail-closed VPN guard |
| `sites_recipe_design.md` | site recipe TOML schema (v1 → v2) |
| `cdp_compat_findings.md` / `cdp_compat_deep_findings.md` / `cdp_remaining_events.md` | obscura CDP compatibility notes |
| `v1.1.0_plan_A_opus.md` / `v1.1.0_plan_B_codex.md` | v1.1.0 plans A and B |
| `v1.1.0_execplan_rev1.md` | **current ExecPlan** (synthesis, this P1's parent) |

Total: 14 active design docs at start of v1.1.0 P1.

## 2. Published binaries (3)

| Bin name | Crate | Path |
|---|---|---|
| `rev-stealth` | `stealth-cli`  | `crates/stealth-cli/src/main.rs` |
| `stealth-mcp` | `stealth-mcp`  | `crates/stealth-mcp/src/main.rs` |
| `rev-auth`    | `stealth-auth` | `crates/stealth-auth/src/bin/rev_auth.rs` |

> No `rev` alias yet (Q8 / B8 in ExecPlan: alias decision deferred to P9).

## 3. Templates shipped with repo

| Path | Schema | Purpose |
|---|---|---|
| `templates/policy.toml` | n/a (CLI policy schema v1) | VPN/AUP defaults, copied to `~/.rev_scraping/policy.toml` (mode 0600) |
| `templates/sites/example.com.toml` | **site recipe schema_version = 2** (Phase 8: proxy tier auto-learn fields added; v1 recipes still load) | structural reference template (NOT a working recipe) |
| `templates/sites/brain-market.com.example.toml` | site recipe v2 | example for a specific real-world target shape |

Loader: `stealth-sites::SiteRecipe`. Companion L1 cache: `~/.rev_scraping/parse.sqlite` (stealth-parse).

## 4. Workspace exclusions / vendored

- `vendor/obscura/` — Apache-2.0 obscura source, **excluded** from workspace (`[workspace] exclude`). Built out-of-tree by user; binary auto-discovered or via `REV_STEALTH_OBSCURA` env / `--obscura` flag. Symptoms when missing: exit code 3 (`BinaryNotFound`).
- `_refs/` — read-only reference clones (obscura, Scrapling, rev_harness). `.gitignore`d.

## 5. CI / shell scripts (`scripts/`)

- `scripts/check_source_and_spdx.sh` (currently green) — license/source guard, runs in CI.
- `scripts/check_bsl_contamination.sh` — BSL anti-contamination check (Scrapling is BSD-3, not BSL, but guard exists for future deps).

## 6. README structure (baseline for §15-§20 additions per B7/P10)

| § | Title | Lines (approx) | v1.1.0 fate |
|---|-------|----------------|-------------|
| §0 / Intro | "rev_scraping — Ultimate Stealth Scraping Toolkit for AI Agents" | 1– | unchanged |
| §AUP | Authorized Targets Only, Technical AUP | 14–46 | unchanged |
| §Project layout | tree | 47–71 | **P9 update** (Q8-2: add stealth-sites, stealth-auth) |
| §License composition | table | 73–82 | minor (P10 SECURITY pointer) |
| §Quick start | Phase 0/1+ build | 84–105 | small update to mention `auth login` |
| §Development status | Phase 1-9 list | 94–106 | bump to "v1.0.0-dev complete; v1.1.0 GA in progress" |
| **§12 Agentic Scraping Stack** | architecture, crates table, building obscura, CI integration, CLI quick start, MCP quick start, exit codes, credits, defender-testbed disclaimer | 107–304 | **P9 update** (Q8-1 crates table to 11 rows; Q8-3 rmcp wording) |
| **§13 VPN Setup (Multi-Instance Gluetun)** | topology, setup, security notes, fail-closed guard (6c) | 305–431 | minor (B5 Linux fold-in: Docker + tun perms) |
| **§14 Authenticated Scraping (Phase 9)** | security model, CLI canonical flow, MCP two-phase flow, exit codes, legal disclaimer | 433–end | B1/B2/B6 fold-in; cookie order + `--allow-no-vpn` examples |
| **§15 Installation** (Linux first-class) | — | (NEW, B5/B7) | P10 to author |
| **§16 Troubleshooting** | — | (NEW, B7/C6) | doctor --deep matrix |
| **§17 Upgrade / Migration** | — | (NEW, B7) | v1.0→v1.1 backward-compat statement |
| **§18 Telemetry / Privacy** | — | (NEW, B7) | "no telemetry by default" |
| **§19 Performance baseline** | — | (NEW, B7 + C5 measure) | optional, document only if measure ships |
| **§20 Non-goals & roadmap** | — | (NEW, B7) | reflects ExecPlan DEFER D1-D10 |

Top-level new files to add (per B7):
- `CHANGELOG.md` (new — currently missing)
- `SECURITY.md` (new)
- `CONTRIBUTING.md` (new)
- `CODE_OF_CONDUCT.md` (new)

## 7. Test surface (v1.0.0-dev baseline)

- Workspace tests: **459 PASS**, 0 fail, 110 ignored (live/E2E gated by `#[ignore]` or env flags such as `REV_LIVE=1`).
- Clippy: clean with `-D warnings`.
- SPDX/source guard: PASS.
- Doctests: present but most modules have 0 (1 ignored doctest in `vpn-rotate::leak_monitor`).

## 8. Exit-code conventions in use (must remain backward-compatible per ExecPlan)

From README §12 + §14:
- `0` success
- `2` policy/AUP violation
- `3` obscura launch (permanent: BinaryNotFound)
- `10` relocate ambiguous (no candidate ≥ strsim 0.85)
- (auth-specific exit codes listed under README §14)

> v1.1.0 must not change semantics of these. New codes (if any) appended only.
