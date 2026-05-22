# rev_scraping v1.2.0 — Production Hardening Release

**Release date**: 2026-05-22
**Tag**: `v1.2.0`
**Baseline**: v1.1.0 (commit 67665db, GA-READY-ON-OPERATOR-PUSH)

## TL;DR

v1.2.0 closes the 4 production-audit findings against v1.1.0 (VPS 60/100, HermesAgent Conditional, Config UX 42/100, Agentability 62/100) and adds a defense-in-depth prompt-injection sanitizer that v1.1.0 lacked entirely.

- **Workspace tests**: 519 → **776 PASS** (+257) / 0 fail / 38 ignored
- **Python tests**: 0 → **20 PASS** (Hermes adapter)
- **MCP tools**: 15 → **16** (`session_show` added)
- **Crates**: 11 → **13** (`stealth-agent-contracts` + `stealth-sanitize` added)
- **Sub-phases LGTM'd**: 30 across 6 lanes (A-F)

## What's new

### Lane A — VPS production deploy
- `dist/systemd/` 5 unit files (`stealth-mcp.service`, `vpn@.service`, `rev-stealth-doctor.{service,timer}`, `xvfb-vnc.service`)
- `systemd-creds`-encrypted secret loader (`<KEY>_FILE` env precedence, 0o077-bit reject)
- `rev-stealth doctor --vps` 9 deep checks (JSON top-level array)
- `dist/systemd/install.sh` + `uninstall.sh --purge`
- `docs/deploy/vps.md` 8-section operator runbook
- `rev-stealth measure --enable-egress-probe` (feature-gated, default OFF; URL/header/error redaction throughout)

### Lane B — Config UX
- `crates/stealth-cli/src/config_io/` (schema / validate / writer / lev / migration)
- `ConfigWriter` atomic write **0600 at creation** (no chmod-after race)
- `rev-stealth config {show,paths,validate,diff,get,init,set,edit,migrate,history,rollback,gc}`
- `rev-stealth config profile {list,create,switch,delete}` (registry env `REV_SCRAPING_PROFILES_ROOT` decoupled from activation `REV_SCRAPING_HOME`; active-profile delete refused)
- Levenshtein typo suggestions for unknown TOML keys

### Lane C — Agentability
- New crate `stealth-agent-contracts`:
  - `ErrorEnvelope` with 26 closed `ErrorKind` variants (compile-time arity guard via `#[forbid(unreachable_patterns)]` exhaustive match)
  - `SessionId` / `ProgressToken` strict UUID v4 (`Version::Random` AND `Variant::RFC4122` — manual `Serialize/Deserialize` rejects forged input)
  - `ToolRateLimiter` per-host token bucket + 429 `Retry-After` clamp at `MAX_429_BACKOFF_SECS=86400` (DoS defense)
  - `IdempotencyKey` Stripe-style + DashMap `remove_if` atomic TOCTOU fix
  - `ProgressTracker` with `notify_waiters` broadcast
- 16 MCP tools `inputSchema` now ship `$schema: draft-07`, `additionalProperties: false`, per-field `description` + `examples` + `enum`
- 16 MCP tools `outputSchema` files at `docs/json-schemas/*.output.json`
- `AuthToolError` / `RecipeError` → `ErrorEnvelope` central mapping
- `session_show` MCP tool (16th tool), reads `<session_dir>/<id>.json` from `InstancePool::persist_session` shape
- Schema migration framework (`config_io/migration.rs`, bounded loop, `LATEST_SCHEMA_VERSION=1`)

### Lane D — Hermes plugin
- `dist/hermes/rev-scraping-mcp/` Python adapter (pure-stdlib)
- `plugin.yaml` / `__init__.py` (register 16 tools) / `mcp_client.py` (subprocess JSON-RPC 2.0) / `lifecycle.py` (exponential 1/2/4/8/16s restart) / `tool_proxy.py` / `schema_bridge.py`
- 20 Python smoke tests (initialize/tools/list/tools/call roundtrip, cookie redaction, fd-leak, env smuggling)
- `rev-stealth hermes {install,uninstall,verify}` CLI

### Lane E — Docs / CI
- `docs/MCP_REFERENCE.md` auto-generated from runtime (16 tools × inputSchema + outputSchema + 26 ErrorKind variants)
- `cargo run -p stealth-mcp --bin gen_reference -- --check` freshness gate
- `.github/workflows/ci.yml` 8 jobs: `rust-test`, `rust-clippy`, `rust-fmt-check`, `mcp-schema-lint`, `config-cli-smoke`, `hermes-contract`, `systemd-analyze` (ubuntu-24.04 systemd 255, `.service` + `.timer`), `headless-auth` (skip-marked)

### Lane F — Prompt injection defense ⭐
- New crate `stealth-sanitize` (5 layers from synthesis: L2 envelope + L3 canary + L4 unicode + L5 clamp + L7 `_meta.sanitize`)
- 20 canary rules / 3 severity tiers (Critical / High / Suspicious)
- **Detection rate**: Critical 100% (8/8), High 100% (12/12) on 20-fixture golden corpus
- **False positive**: 0 Critical/High, ≤ 1 Suspicious per fixture on 20 benign fixtures
- L2 envelope: `<<<UNTRUSTED_CONTENT origin=... tool=... sanitize_id=NONCE>>>...<<<END_UNTRUSTED_CONTENT sanitize_id=NONCE>>>` with 64-bit nonce forgery defense
- L4 unicode: NFKC + zero-width strip + tag-char strip (U+E0000-E007F) + bidi override strip (U+202D/E, U+2066-9)
- L5 clamp: per-field 256 KiB / total 512 KiB / head-and-tail keep
- L7 `_meta.sanitize` envelope field on all 16 output schemas
- **Mode**: Warn default; Critical canaries trigger `aborted=true` + `isError:true` (raw `env.message` never reaches LLM-visible response)
- Central wiring at `stealth-mcp::server::dispatch_tool` + `policy_for_tool()` per-tool table
- Idempotence prop test (50-iter) + 16-tool integration `_meta.sanitize` presence regression

## Security fixes (called out)

1. **UUID v4 forgery** — `transparent` deserialize accepted non-v4 input
2. **DoS via `Retry-After: u64::MAX`** — `Instant + Duration` overflow path
3. **TOCTOU race in idempotency expired-eviction** — atomic `DashMap::remove_if`
4. **chmod-after permission window** in `ConfigWriter` temp / backup
5. **systemd `ExecStart`** missing `exec` (zombie reaper)
6. **docker-compose `${VPN_USER}`** interpolation eating `${}` shell quoting
7. **JSON output type contract**: `--vps` JSON now top-level array, not `{doctor, vps}` object
8. **Hermes `readline()`** deadline-bypass (raw `os.read` + partial-byte carry)
9. **Hermes `start()` fd leak** on handshake-fail
10. **Hermes `env=` ctor** bypassed `filter_env` (smuggling vector)
11. **`auth.rs` CLI `--python-check=false`** parse regression
12. **`stealth-sanitize` descendant pointer key-leak** (positional `_k<idx>` propagation in walk recursion)

## Known issues (carried into v1.2.0)

- `crates/stealth-cli/src/commands/auth.rs::tests::auth_login_with_allow_no_vpn_skips_probe` races on process-wide `REV_SCRAPING_REQUIRE_VPN` env var under `--test-threads=4`. Reproducible only without `--no-fail-fast`. CI uses `--no-fail-fast` (matches release gate). Pre-existing in v1.1.0, scoped out of v1.2.0; tracked for v1.2.1.

## v1.2.1 backlog (deferred from synthesis)

- L1 ammonia full HTML scrubbing (hidden text removal, JSON-LD relocate, SVG drop)
- L6 URL filter (scheme allowlist + length cap)
- Multi-language canary set (JP / ZH / KR / RU)
- Hermes Python mirror sanitizer
- `stealth-sanitize` Enforce-mode default flip (currently Warn + Critical-only fail-closed)
- L2 envelope marker rework so it doesn't self-trigger canary #19 on re-scan (broader idempotence)
- Site-specific policy overrides
- `recipe_import` strict mode (refuses recipes whose own fields trip Critical canaries — T3 supply-chain vector close)

## Process notes

- 30 sub-phases LGTM'd via Opus 4.7-high coder × Codex gpt-5.5-high reviewer loop
- Canonical wrapper: `scripts/codex-wrapper.sh --role reviewer --stdin` (raw `codex exec` prohibited)
- Slice ≤ 2 KB / max 3 review rounds per slice
- Evidence: `.agent/active/{prompts,reviews}/p*_review*.{md,out}` (28+ rounds captured)
- `REV_HARNESS_DELEGATION_METRIC` line emitted per round
- One documented Codex CLI failure mode landed during work: `§16.8` Codex bail-out at large prompt × high/xhigh effort × open-ended design tasks (PR'd to RevHarness 0.0.16 / 0.0.17)

## Upgrade notes

- Cargo workspace version bumped 1.1.0 → 1.2.0 (`[workspace.package]`)
- Two new workspace members: `stealth-agent-contracts`, `stealth-sanitize`
- `~/.rev_scraping/` profile / config layout unchanged for existing users (`schema_version=1` identity migration ships)
- `stealth-mcp` binary tools count: 15 → 16 (`session_show`)
- All existing MCP `result` payloads gain `_meta.sanitize` field (additive, schema-compatible)
- VPS install path: `dist/systemd/install.sh` (idempotent; `--with-vnc-fallback` opt-in)
- Hermes plugin path: `~/.hermes/plugins/rev-scraping-mcp/` (default; override via `rev-stealth hermes install --prefix`)

## Acknowledgments

Sole human operator + Opus 4.7-high coder + Codex gpt-5.5-high reviewer.
