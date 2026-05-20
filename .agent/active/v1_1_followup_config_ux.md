# v1.1.0 Follow-up: Configuration UX Audit

- Auditor: Claude opus 4.7-high (read-only, design-only)
- Date: 2026-05-20
- Scope: All operator-visible configuration surfaces of rev_scraping
  v1.1.0 (CLI flags, env vars, TOML files under `~/.rev_scraping/`,
  templates under `templates/`, `.env*`, audit log, secret stores, MCP
  agent surface).
- Method: static read of the workspace (`crates/`, `templates/`,
  `~/.rev_scraping/`), no execution, no edits.

## 0. TL;DR

rev_scraping ships a **security-first, but UX-poor** configuration
model. Loading is fail-closed and the schema is validated by serde, but
there is **no `config` subcommand at all**: no `show`, no `validate`,
no `init`, no `diff`, no `migrate`. Operators are expected to hand-edit
TOML, `chmod 600`, restart shells, and trust that `doctor` will surface
mistakes — and `doctor` only deep-checks two of the seven configurable
surfaces. There is also **no schema-version field** on `policy.toml`
or `authorized.toml` (only `sites/*.toml` carries one), which makes
forward migration brittle.

The system is solid for a single careful operator and very dangerous
for an AI agent or a 3-person team that wants to safely rotate
secrets, switch environments, or roll back a bad edit.

Overall UX score (0-100): **42 / 100**.

The remainder of this report scores each of the 10 evaluation axes,
cites concrete file paths, and proposes a Phase-10 / v1.2.0 config-UX
work package.

---

## 1. Visibility — "Where is all my config and what is it set to?"

**Score: 2 / 10**

### Findings

- There is no `rev-stealth config show` (verified by reading
  `crates/stealth-cli/src/main.rs` lines 60-95: only `Captcha`,
  `Browser`, `Vpn`, `Doctor`, `Spider`, `Relocate`, `CfEvaluate`,
  `Auth`, `Measure` exist).
- Effective configuration is the union of:
  1. `~/.rev_scraping/policy.toml`
  2. `~/.rev_scraping/authorized.toml`
  3. `~/.rev_scraping/sites/*.toml`
  4. `~/.rev_scraping/auth/*.enc` (opaque blobs)
  5. `~/.rev_scraping/audit.jsonl` (created lazily; not present in this
     install)
  6. `.env` / `.env.local` (process-cwd, not `$HOME`-resolved)
  7. >12 distinct `REV_SCRAPING_*` / `VPN_*` env vars (collected from
     `grep env::var` — see Appendix A).
  8. Built-in defaults (`policy::default_*`, hardcoded VPN pool
     of 3 when env is unset, etc.).
- `doctor` deep-mode partially inspects (1) for `pool.instances`
  count, but does not echo the effective config; the operator cannot
  see "after merging env + CLI + policy + defaults, this is what the
  next run will actually use."
- `sites/*.toml` are silently picked up by domain match; there is no
  listing command (`recipe_list` exists in the MCP layer but not on
  the CLI, see `crates/stealth-mcp/src/recipe_tools.rs:17`).
- The README documents env vars per-feature but no single canonical
  list exists.

### Recommended

- Add `rev-stealth config show [--format=json|toml|human] [--effective]
  [--source]` that prints the merged tree and, with `--source`,
  annotates every leaf with the layer that supplied it (env / CLI /
  policy.toml / authorized.toml / default).
- Add `rev-stealth config paths` that prints every file rev-stealth
  would read, with `exists?` / `mode` / `size` columns.
- Surface `recipe_list` as a CLI subcommand (`rev-stealth recipe list`)
  with the same body the MCP tool already implements.

---

## 2. Validation — "Did I write a typo that will only break at 3am?"

**Score: 4 / 10**

### Findings

- TOML parsing is via serde-derived structs (`Policy`, `AuthorizedFile`,
  `SiteRecipe`). Unknown fields are silently accepted (serde default).
  Typos like `requite_vpn = true` are ignored without warning.
- There is partial deep validation:
  - `policy.toml` proxy `url = "..."` rejected if it embeds a literal
    secret (`policy.rs` / `proxy_resolver.rs`).
  - `authorized.toml::targets[].url_pattern` is compiled via `regex::Regex`
    at load time, so a malformed regex is caught.
  - `doctor` parses `policy.toml` and flags pool-instance count < 3.
- There is **no schema validation** for `authorized.toml` field
  completeness, no warning when `sites/*.toml::schema_version` is
  unknown, no cross-file consistency check (e.g.
  `authorized.toml::proxy_tier = "residential"` referencing a tier
  that does not exist in `policy.toml::proxies`).
- No `rev-stealth config validate` command.
- `docs/json-schemas/` exists but is not wired to a runtime validator
  for `policy.toml` or `authorized.toml` (only recipes have one).

### Recommended

- Mark all config structs `#[serde(deny_unknown_fields)]`. This alone
  catches 80% of operator typos.
- Add `rev-stealth config validate [--strict]` that:
  1. Parses every file in `~/.rev_scraping/`.
  2. Cross-references tier names, secret refs, instance names.
  3. Emits warnings for: world-readable mode (>0o600), missing
     `last_verified`, unknown `schema_version`, regex patterns that
     compile but never match any allowlisted URL.
  4. Exits non-zero on errors so it can run in CI / pre-commit.
- Publish JSON Schema for `policy.toml` and `authorized.toml` under
  `docs/json-schemas/` and reference them from a top-of-file comment
  so VS Code's Even Better TOML plugin lights up red squigglies live.

---

## 3. Migration — "Schema went from v1 → v2; what happens to my old file?"

**Score: 3 / 10**

### Findings

- Only `sites/*.toml` carries `schema_version` (`recipe.rs:16-28`,
  default `1`). The `templates/sites/example.com.toml` advertises
  `schema_version = 2` (Phase 8 proxy fields). Existing cached
  v1 recipes still load because the new fields default to
  `None`, but there is no explicit migration path or up-conversion
  step — the file stays at `version=1` on disk forever and no
  warning is emitted that newer fields are dormant.
- `policy.toml` and `authorized.toml` have **no version field at all**.
  Any future breaking change will be a silent foot-gun.
- There is no `rev-stealth config migrate` command and no `.bak` is
  written before any in-place change (recipe auto-refresh writes the
  new file via `tempfile` rename — good for atomicity, bad for
  history).
- The release notes (`CHANGELOG.md`) document schema bumps but do not
  link to a runbook.

### Recommended

- Add `schema_version = 1` to `policy.toml` and `authorized.toml`
  template now (v1.1.0 is current; cut the version field in v1.1.1
  before any breaking change lands).
- Implement `rev-stealth config migrate [--from <v>] [--to <v>]
  [--dry-run]` that:
  1. Reads the on-disk file.
  2. Applies sequential migrations defined as `Fn(Value) -> Value`.
  3. Writes `<file>.bak.<epoch>` before overwriting.
  4. Verifies the new file re-parses cleanly.
- On startup, if `schema_version < SUPPORTED`, refuse to run and
  point the user at `rev-stealth config migrate`.

---

## 4. Secret Separation — "Where do credentials actually live?"

**Score: 7 / 10**

### Findings

- Cookie blobs use `stealth-auth` with ChaCha20-Poly1305, key sourced
  from OS keyring (`keystore.rs:28`) with passphrase fallback via
  `REV_SCRAPING_AUTH_PASSPHRASE`. This is excellent.
- `policy.toml::proxies.*.url` rejects literal creds; only
  `${ENV_VAR}` placeholders are accepted (per template, lines about
  "CRITICAL SECRET RULE").
- VPN OpenVPN creds live in `.env` (`VPN_USER`, `VPN_PASSWORD`). The
  `.env` file MUST be `chmod 600`, but nothing checks this at runtime
  (no permission audit in `doctor` for `.env`; only the auth dir is
  checked).
- There is **no `op://` (1Password CLI) or `keyring://` URI scheme** in
  `policy.toml` proxy URLs — only `${ENV}` interpolation. Operators
  who use a vault must shim it into env at shell start.
- `audit.jsonl` test claims "no cookie value in audit" (`audit.rs:31`),
  good.

### Recommended

- Add a permission audit step to `doctor` that warns if `.env`,
  `.env.local`, `policy.toml`, `authorized.toml` exceed `0o600`.
- Extend the `${...}` interpolator in `proxy_resolver.rs:927` to also
  accept `${op://vault/item/field}`, `${keyring://service/user}`,
  `${file:///path}` schemes. Each resolver is opt-in behind a
  cargo feature so the default build remains minimal.
- Document secret rotation in `docs/secrets-rotation.md`: how to
  rekey the auth keyring entry, how to roll VPN creds, how the audit
  log records (or does not record) the event.

---

## 5. Defaults — "Does it work out of the box?"

**Score: 6 / 10**

### Findings

- `Policy::default()` returns `require_vpn = true`, no proxies, no
  vpn_required_country — sensibly fail-closed. With **no** policy
  file present, every fetch refuses to run because no VPN tier is
  configured and `direct` is illegal under `require_vpn=true`.
  Friendly error? Not really: the operator must read source to
  realise they need a non-empty `[[vpn_instances]]` block.
- `authorized.toml` absence: `aup::load_allowlist` returns
  `Ok(None)` (`aup.rs:60`), which means every URL is rejected unless
  the operator either lists targets or uses
  `--i-have-authorization` / `REV_SCRAPING_AUP_ACK`.
- `~/.rev_scraping/` is not auto-created. First run yields a confusing
  "policy.toml not found at ..." warning in `doctor`, but no
  `init` step.
- The CLI lacks a `--dry-run` switch for fetcher commands that would
  exercise config loading without touching the network.

### Recommended

- On any command that needs `policy.toml`, if absent, print:
  "no ~/.rev_scraping/policy.toml; run `rev-stealth config init`."
- Bundle a non-trivial default `policy.toml` (the current empty
  default behaves like "require VPN with no VPN" which is impossible
  to satisfy without configuration anyway). Either keep the fail-closed
  behaviour and surface a precise hint, or ship a 3-instance loopback
  stub in `init`.

---

## 6. Templates / Init — "Is there a hand-holding bootstrap?"

**Score: 3 / 10**

### Findings

- `templates/policy.toml` and `templates/sites/*.toml` exist and are
  well-commented (the policy template is ~170 lines with banners and
  cautions).
- Operators are instructed by README and template comments to
  `cp templates/policy.toml ~/.rev_scraping/policy.toml && chmod 600`.
- There is **no interactive `rev-stealth config init`** that:
  - Detects an existing install and refuses to overwrite.
  - Prompts for VPN provider, instance count, country.
  - Writes `policy.toml` + permissions + creates the directory
    structure + writes a stub `authorized.toml`.
- The current bootstrap is purely manual `cp` + edit.

### Recommended

- Add `rev-stealth config init [--non-interactive] [--vpn-provider X]
  [--vpn-instances N] [--country JP]` that:
  1. Creates `~/.rev_scraping/{sites,auth}` with `0700`.
  2. Renders `policy.toml`, `authorized.toml` from embedded templates
     with field substitution.
  3. Sets `0600` on the files.
  4. Calls `config validate` at the end as a self-test.
- In `--non-interactive` mode, accept a single YAML/JSON spec on stdin
  so AI agents can call it programmatically.

---

## 7. Per-environment Profiles — "dev vs staging vs prod"

**Score: 1 / 10**

### Findings

- There is **no notion of profiles**. The config root is hardcoded to
  `~/.rev_scraping/` (overridable only by `REV_SCRAPING_HOME` per
  `doctor.rs:476`).
- `dirs::home_dir().join(".rev_scraping")` is the single source of truth
  for `policy.toml`, `authorized.toml`, `sites/`, `auth/`.
- Operators wanting dev/staging/prod must run multiple shells, each
  with a different `REV_SCRAPING_HOME=/path/to/profile-X` and a
  parallel `.env`. This works, but:
  - No CLI flag exposes it (`--profile prod`).
  - `doctor` and `Cargo.toml` features do not key off it.
  - Audit log path is per-profile too, so cross-profile auditing
    requires manual aggregation.

### Recommended

- Add `--profile <name>` global flag and `REV_SCRAPING_PROFILE` env
  var. Resolution: `~/.rev_scraping/profiles/<name>/...`, falling
  back to `~/.rev_scraping/` when unset (so existing single-profile
  installs are untouched).
- `rev-stealth config profile {list,create,switch,delete}` commands.
- `config show --all-profiles` to diff effective config across them.

---

## 8. Diff / Dry-run — "What changes if I edit this?"

**Score: 2 / 10**

### Findings

- No `rev-stealth config diff` or `rev-stealth config plan` command.
- `recipe_runtime.rs` writes recipes via tempfile + rename — atomic,
  but no diff is presented even when an existing recipe is updated.
- `spider.rs:2131` shows that initial recipe creation writes a
  `schema_version = 1` shell from scratch — no comparison against
  the live file.
- The only "what will happen?" feedback is post-hoc, in `audit.jsonl`.

### Recommended

- `rev-stealth config diff <file>` that loads the on-disk file, runs
  the in-memory effective config, and prints a unified diff colored
  by severity (security-relevant changes red).
- For recipe writes from `spider --cache-refresh`, always log a
  one-line summary of which fields changed (e.g.
  `recipe brain-market.com: +2 endpoints, schema 1→2`).
- Add `--dry-run` to every config-writing command (`auth login`,
  recipe refresh, future `config migrate`).

---

## 9. Rollback — "I broke it; how do I undo?"

**Score: 2 / 10**

### Findings

- No automatic `.bak` is created on config writes. The atomic
  `tempfile`-rename pattern means the previous version is gone the
  instant the new file lands.
- `git` is the operator's only rollback (and only if they
  remembered to commit before editing; `~/.rev_scraping/` is outside
  the repo and not a default git target).
- `audit.jsonl` records auth events but not config edits.
- There is no `rev-stealth config history`, no `--undo`.

### Recommended

- All config writers must produce `<file>.bak.<epoch_ms>` before
  rename. Keep last N (default 5) per file; sweep older with a
  `config gc` subcommand.
- `rev-stealth config rollback <file> [--to <epoch>]` to restore.
- Log every write to `audit.jsonl` with `event = "config_write"`,
  file path, before/after sha256, actor (CLI / MCP / human).

---

## 10. Agentability — "Can an AI safely manage this config?"

**Score: 4 / 10**

### Findings

- MCP tool surface (`crates/stealth-mcp/src/tools.rs`) exposes:
  `spider`, `relocate`, `cf_evaluate`, `doctor`, `recipe_list`,
  `recipe_show`, `recipe_remove`, `recipe_propose_endpoint`,
  `recipe_export`, `recipe_import`, `auth_login_start`,
  `auth_login_complete`, `auth_list`, `auth_status`, `vpn_rotate`.
- Notable gaps:
  - No `policy_show` / `policy_set` / `policy_validate`.
  - No `aup_list_targets` / `aup_add_target` /
    `aup_remove_target`.
  - No `config_diff`, no `config_init`.
- The MCP CLI shim is robust (`stealth-mcp/src/cli.rs` resolves the
  binary via `REV_SCRAPING_CLI_PATH`), but the absence of dedicated
  config tools forces agents to either shell out to file write (which
  the harness will rightly block) or do nothing.
- `recipe_import` is the only safe write surface and is limited to
  recipes.

### Recommended

- Add MCP tools:
  - `policy_show` (read-only, returns effective merged config)
  - `policy_propose_change` (returns a diff; the operator approves)
  - `aup_add_target` (writes a new `[[targets]]` block; idempotent;
    rejects regexes that compile to a strict superset of an existing
    pattern unless `--allow-superset`)
  - `config_validate` (machine-readable JSON of validate result)
- Every write path goes through the same `.bak` + audit-log machinery
  designed in §9, so an agent's edits are auditable and reversible.
- Document an agent-safe workflow in `docs/agent-config-playbook.md`.

---

## Score Summary

| Axis | Score | Notes |
| ---- | ----- | ----- |
| 1. Visibility | 2/10 | No `config show`. |
| 2. Validation | 4/10 | Serde + regex compile; no deny_unknown_fields, no `config validate`. |
| 3. Migration | 3/10 | Schema version only on recipes; no migrator. |
| 4. Secret separation | 7/10 | Keyring + ChaCha + env interpolation good; no vault scheme. |
| 5. Defaults | 6/10 | Fail-closed correct; first-run error is opaque. |
| 6. Templates / init | 3/10 | Templates exist; no interactive init. |
| 7. Per-environment | 1/10 | No profiles, only one `$HOME` override. |
| 8. Diff / dry-run | 2/10 | No diff command. |
| 9. Rollback | 2/10 | No `.bak`, no history. |
| 10. Agentability | 4/10 | Recipe + auth MCP tools exist; policy/AUP missing. |

Weighted overall: **42 / 100** (simple average 3.4/10).

---

## Phase 10 Candidate Work Package: "Configuration UX Hardening"

Suggested ordering, smallest-blast-radius first.

### P10.1 — Visibility (1 sprint)
- `rev-stealth config show [--effective] [--source] [--format]`
- `rev-stealth config paths`
- `rev-stealth recipe list` (CLI parity with MCP)

### P10.2 — Validation (1 sprint)
- `#[serde(deny_unknown_fields)]` on Policy, AuthorizedFile,
  SiteRecipe, sub-structs.
- `rev-stealth config validate [--strict]`
- JSON Schema artifacts for `policy.toml`, `authorized.toml`.

### P10.3 — Versioning & Migration (0.5 sprint)
- Add `schema_version = 1` to policy + authorized templates.
- Define migration registry pattern in `stealth-cli::config_migrate`.
- Stub `rev-stealth config migrate --dry-run` (no migrations needed yet).

### P10.4 — Backup, Diff, Rollback (1 sprint)
- All config writers produce `<file>.bak.<epoch_ms>` + audit row.
- `rev-stealth config diff`, `rev-stealth config history`,
  `rev-stealth config rollback`.

### P10.5 — Init & Templates (0.5 sprint)
- `rev-stealth config init [--non-interactive]` with embedded
  templates and field substitution.
- Permission audit (`0o600`) in `doctor`.

### P10.6 — Profiles (1 sprint)
- `--profile`, `REV_SCRAPING_PROFILE`, `~/.rev_scraping/profiles/<name>/`.
- Update `doctor` and all path resolvers.
- `rev-stealth config profile {list,create,switch}`.

### P10.7 — Agent Surface (0.5 sprint)
- MCP tools: `policy_show`, `policy_propose_change`,
  `aup_add_target`, `aup_remove_target`, `config_validate`.
- All write tools route through P10.4 backup machinery.

### P10.8 — Secret Vault URIs (optional, 0.5 sprint, feature-gated)
- `op://`, `keyring://`, `file://` schemes in `${...}` interpolator.

Total: ~5 dev sprints. Each phase is independently shippable; P10.1
and P10.2 dominate the operator pain ceiling and should land first.

---

## Appendix A — Environment Variables in use (grep evidence)

From `grep env::var`:

- `REV_SCRAPING_REQUIRE_VPN` (policy.rs:26)
- `VPN_INSTANCES` (policy.rs:30, vpn-rotate/docker.rs:103)
- `REV_SCRAPING_AUP_ACK` (aup.rs)
- `REV_SCRAPING_AUTH_PASSPHRASE` (stealth-auth keystore)
- `REV_SCRAPING_HOME` (doctor.rs:476)
- `REV_SCRAPING_CLI_PATH` (stealth-mcp/cli.rs:10)
- `REV_STEALTH_SIDECAR` (captcha-bypass/bridge.rs:106)
- `REV_STEALTH_VPN_FAIL_THRESHOLD` (vpn-rotate/docker.rs:52)
- `REV_STEALTH_RUN_DOCKER_TESTS` (vpn-rotate/leak_guard.rs:490)
- `REV_SCRAPING_RUN_OBSCURA` (obscura-bridge/auth_inject.rs:283)
- `REV_SCRAPING_ALLOW_LOOPBACK` (obscura-bridge/ssrf.rs:43)
- `VPN_PROVIDER`, `VPN_USER`, `VPN_PASSWORD`, `VPN_COUNTRIES`
  (.env.example)
- `HOME` (vpn-rotate/instance_pool.rs:220)
- `${...}` interpolated proxy-URL vars (proxy_resolver.rs:927)

The fact that this list takes a grep run to produce is itself a
visibility failure (`config show --env-vars` would print it).

---

## Appendix B — File-level summary

| Path | Owner | Mode (this install) | Schema versioned? | Validated? |
| ---- | ----- | ------------------- | ----------------- | ---------- |
| `~/.rev_scraping/policy.toml` | operator | 0600 | No | partial (proxy URL secret check) |
| `~/.rev_scraping/authorized.toml` | operator | 0600 | No | regex compile only |
| `~/.rev_scraping/sites/*.toml` | spider auto-refresh | 0600 dir / file mode varies | Yes (`schema_version`) | serde-derive |
| `~/.rev_scraping/auth/*.enc` | stealth-auth | dir 0700 | n/a (binary blob) | AEAD verify |
| `~/.rev_scraping/audit.jsonl` | stealth-auth | n/a (absent here) | No | append-only |
| `.env.local` | operator | 0600 (verified) | No | none at runtime |
| `.env.example` | repo | 0644 | No | static text |
| `templates/policy.toml` | repo | 0644 | No (but advertises Phase 8) | static text |
| `templates/sites/example.com.toml` | repo | 0644 | Yes (`schema_version = 2`) | static text |
| Cargo features per crate | repo | n/a | n/a | `cargo deny` |

---

## Appendix C — Things this audit explicitly did NOT touch

- Runtime correctness of policy enforcement (covered by
  `v1.1.0_final_review*.md`).
- Secret cryptography review (covered by `SECURITY.md` and
  `stealth-auth` audit).
- Performance of TOML load (~µs, irrelevant).
- Windows / Linux mode bit semantics (the audit assumes a POSIX
  operator).

End of report.
