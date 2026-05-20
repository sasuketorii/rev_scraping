# Phase 7 — Site Recipe L2 Cache: Detailed Design

Status: **DRAFT (design only, no implementation)**
Author: Phase 7 architect (Opus)
Date: 2026-05-12
Companion: `templates/sites/example.com.toml`, `templates/sites/example.com.example.toml`

---

## 0. Goal

Introduce an **L2 discovery cache** that remembers, per-domain, *how*
to scrape a site once an agent has figured it out: API endpoints, URL
patterns, rendering type, paywall fields, anti-bot posture. Reads on
the second visit short-circuit to direct API calls and skip browser
rendering entirely.

L1 (existing `stealth-parse` SQLite WAL) caches *element-level*
fingerprints. L2 caches *site-level* topology. They are complementary
and never overlap.

```
                ┌──────────────────────┐
  URL ────────▶ │  spider entry        │
                └──────────┬───────────┘
                           │
                    domain extracted
                           │
            ┌──────────────▼──────────────┐
            │ SiteRecipeStore::load(dom)  │ ◀── L2 (TOML, per-domain)
            └──────┬──────────────┬───────┘
                   │hit           │miss
                   ▼              ▼
          API direct call    obscura render
                   │              │
                   │      ┌───────▼────────┐
                   │      │ enumerate APIs │
                   │      │   (Phase 7c)   │
                   │      └───────┬────────┘
                   │              │
                   │              ▼
                   │      SiteRecipeStore::save
                   │              │
                   ▼              ▼
           stealth-parse (L1) ────┘
```

---

## A. Crate Layout

**Decision:** new crate `stealth-sites`.

Rationale:
- `stealth-parse` is element-level and depends on `rusqlite`. The recipe
  store is filesystem-only TOML; bundling would force a SQLite dep on
  callers that only want recipes (e.g. the future MCP `recipe_list` tool).
- Keeping the L2 cache isolated makes it trivial to expose via MCP and
  to share across tools that don't need parsing (e.g. `rev-stealth recipe export`).

Workspace additions (in `Cargo.toml`):

```toml
members = [
    # ... existing ...
    "crates/stealth-sites",
]

[workspace.dependencies]
stealth-sites = { path = "crates/stealth-sites" }
```

Dependency graph (additions only):

```
stealth-sites          (new)  — deps: serde, toml, url, anyhow, thiserror, time, directories
stealth-cli            depends on stealth-sites
obscura-bridge         depends on stealth-sites (for save() after discovery)
stealth-mcp            depends on stealth-sites (for recipe_* tools)
stealth-parse          unchanged
stealth-cf             unchanged
```

**LoC estimate (full implementation):**

| File                                | LoC |
|-------------------------------------|----:|
| `src/lib.rs`                        |  40 |
| `src/recipe.rs` (types, serde)      | 220 |
| `src/store.rs` (open/load/save/list/remove, atomic write) | 180 |
| `src/render.rs` (URI template expansion) | 90 |
| `src/error.rs`                      |  40 |
| unit tests                          | 220 |
| **total**                           | **~790** |

CLI/spider integration adds ~150 LoC to `stealth-cli`.

---

## B. TOML Schema

The canonical schema lives in `templates/sites/example.com.toml` and
is reproduced here in summary form. Every key is documented inline in
the template.

```
schema_version = 1

[site]                          # domain identity & classification
  domain, last_verified, rendering, framework, backend_hint, tags

[api]                           # api root descriptor (one per recipe)
  base_url, public_auth_required, auth_method, auth_secret_ref,
  rate_limit_recommendation, response_encoding

[[api.endpoints]]               # repeatable; one row per known endpoint
  purpose, path, url_pattern, http_method,
  required_headers, required_query,
  response_shape, discovered_via, last_verified,
  avg_latency_ms, ok_status

[scraping_strategy]
  preferred_method, fallback_method,
  paywall_fields, public_fields,
  follow_internal_links, max_depth

[rate_limits]
  concurrent, delay_ms, jitter_ms, respect_retry_after

[selectors]                     # optional; HTML fallback path
  <field> = { css, attr?, stable_id }

[fingerprint]                   # optional; mobile-fp preset
  mobile_preset, sec_ch_ua_required, referer_policy, accept_language

[anti_bot]                      # optional; observed edge protections
  cloudflare, turnstile, datadome, recaptcha, akamai, bypass_strategy

[notes]
  text                          # free-form, agent-authored
```

### Validation rules (enforced at load time)
1. `schema_version == 1` (forward-compat reject).
2. `site.domain` matches the filename (`<domain>.toml`).
3. `rendering ∈ {spa, ssr, hybrid, api-only, static}`.
4. `auth_method ∈ {none, cookie, bearer, basic, custom}`.
5. `auth_method != none` ⇒ if endpoints exist that require auth, the
   loader **does not** error, but `auth_secret_ref` must be resolvable
   before use.
6. Every endpoint's `path` MUST parse as an RFC 6570 URI template.
7. Forbidden keys (silently rejected on save): `cookie`, `token`,
   `session`, `bearer`, `password`. Recipes are not a secret store.

---

## C. Rust API

```rust
// crates/stealth-sites/src/lib.rs
pub use error::{Error, Result};
pub use recipe::{SiteRecipe, Endpoint, ScrapingMethod, Rendering};
pub use store::SiteRecipeStore;
```

```rust
pub struct SiteRecipe { /* fully parsed from TOML, all sections */ }

pub struct SiteRecipeStore {
    dir: PathBuf,                          // ~/.rev_scraping/sites/
    cache: RwLock<HashMap<String, Arc<SiteRecipe>>>,
}

impl SiteRecipeStore {
    pub fn open(dir: &Path) -> Result<Self>;
    pub fn default_dir() -> Result<PathBuf>; // resolves ~/.rev_scraping/sites
    pub fn load(&self, domain: &str) -> Result<Option<Arc<SiteRecipe>>>;
    pub fn save(&self, recipe: &SiteRecipe) -> Result<()>;     // atomic
    pub fn list_domains(&self) -> Result<Vec<String>>;
    pub fn remove(&self, domain: &str) -> Result<()>;
    pub fn export(&self, domain: &str, dst: &Path) -> Result<()>;
    pub fn import(&self, src: &Path, overwrite: bool) -> Result<String>;
}

impl SiteRecipe {
    pub fn endpoints(&self, purpose: &str) -> Vec<&Endpoint>;
    pub fn render_url(&self, purpose: &str, params: &HashMap<&str, &str>) -> Result<Url>;
    pub fn preferred_method(&self) -> ScrapingMethod;
    pub fn is_stale(&self, ttl: Duration) -> bool;
    pub fn touch(&mut self);                // updates last_verified
}
```

**Atomic write:** `write(tmp); fsync(tmp); rename(tmp, final)` —
crash-safe; readers either see the old file or the new file, never a
half-written TOML.

**Concurrency:** `RwLock<HashMap>` in-memory cache; on-disk recipes
are mutated only via `save()` which takes a write lock. The store is
process-local — cross-process safety relies on the rename being atomic
on POSIX. If two processes race, the loser overwrites (acceptable: a
recipe is regenerable).

---

## D. spider Integration

`rev-stealth spider --url <URL>` flow:

1. Parse URL → extract eTLD+1 (use `publicsuffix` crate).
2. `store.load(domain)?`:
   - **hit** → branch on `recipe.preferred_method()`:
     - `api`: call endpoints listed in recipe directly via `reqwest`
       with the fingerprint preset. Skip browser entirely.
     - `obscura` / `stealth-cf`: hand off to existing pipeline but
       seed it with `recipe.selectors` and `recipe.fingerprint`.
   - **miss** → run the existing obscura discovery flow → on success
     build a `SiteRecipe` from observations and `store.save()`.
3. Emit JSON with new fields:
   ```json
   { "recipe_hit": true, "recipe_save": false, "recipe_age_secs": 1234 }
   ```

### New flags

| Flag                | Behavior                                                  |
|---------------------|-----------------------------------------------------------|
| `--no-cache`        | Skip `load()`. Still calls `save()` unless `--no-save`.   |
| `--no-save`         | Skip `save()` even on miss.                               |
| `--cache-refresh`   | Force re-discovery and overwrite existing recipe.         |
| `--cache-only`      | If miss, exit code `9` and do nothing.                    |
| `--cache-ttl <DUR>` | Treat recipes older than DUR as miss (default: 30 days).  |

Exit codes (new): `9` = cache miss in `--cache-only` mode.

---

## E. Automatic Endpoint Enumeration

**Three candidates, evaluated:**

| # | Approach                                | Coverage | Cost | Risk     |
|---|-----------------------------------------|---------:|-----:|----------|
| 1 | SSR payload / JS bundle static analysis | medium   | low  | brittle  |
| 2 | chromiumoxide Network domain capture    | high     | med  | reliable |
| 3 | MCP tool — agent issues `spider --discover` and writes recipe | variable | high | depends on agent |

**Recommendation: hybrid (#2 primary, #1 supplement, #3 manual override).**

- **#2 is the workhorse.** During the obscura render that happens on
  cache miss, attach a `Network.requestWillBeSent` / `Network.responseReceived`
  listener. Filter for `XHR`/`Fetch` resource types, `2xx` status,
  `application/json` content-type, same-eTLD+1 as the navigated URL.
  Group by path template (replace numeric / UUID / slug segments with
  `{param}`) and emit one `Endpoint` per group with `discovered_via =
  "network-capture"`.
- **#1 supplements** because some pages embed the API base in the JS
  bundle but never call it on the landing page (e.g. paginated lists).
  Run a regex pass over the main bundle for `https?://[^"'\s]+/(api|v\d)/[^"'\s]*`.
  Probe candidates with `HEAD`; keep 200s with `discovered_via =
  "js-bundle"`.
- **#3 is the escape hatch.** Expose `recipe_propose_endpoint` as an
  MCP tool so an LLM agent can manually register an endpoint it
  discovered out-of-band. Marked `discovered_via = "agent-mcp"`.

Why not #2 alone? On many SPAs the first navigation only triggers a
subset of endpoints (e.g. profile but not articles). #1 catches those
without a second navigation.

Why not #3 alone? Agent latency cost is high; we want zero-LLM
auto-learning on the happy path.

---

## F. Privacy / .gitignore / Security

- **Recipe files** live in `~/.rev_scraping/sites/` — outside the repo,
  no gitignore needed.
- **Templates** in `templates/sites/*.toml` are public (no secrets).
  The `example.com.example.toml` here ships discovered endpoint
  shapes only; no auth material.
- **Secrets are forbidden** in recipes. The loader rejects on save if
  forbidden keys (`cookie`, `token`, `session`, `bearer`, `password`)
  appear anywhere in the parsed `toml::Value`. Auth is referenced
  *by name* via `auth_secret_ref` and resolved at request time from
  a separate `~/.rev_scraping/secrets.toml` (out of scope for Phase 7).
- **Export/import** is supported (`SiteRecipeStore::export`/`import`).
  Import requires `--trust <fingerprint>` flag in CLI to prevent
  silently absorbing recipes from untrusted sources. Imported files
  are re-validated against the same forbidden-key list.
- **PII consideration:** the `[notes]` block is free-form; we
  recommend (in template comments) that agents not write usernames,
  emails, or IPs into notes. Not enforced — would create false
  positives.

---

## G. example.com Recipe (concrete)

Committed at `templates/sites/example.com.example.toml`. Captures
the fujin_metaverse exploration:

- **Endpoints:**
  - `GET /v2/users/{username}` (profile)
  - `GET /v2/users/{username}/articles` (list)
  - `GET /v2/articles/{article_id}` (single)
- **Rendering:** spa / nuxt; `__NUXT_DATA__` mirrors API response.
- **Paywall:** `body` only; `intro_body` plus all metadata public.
- **Anti-bot:** Cloudflare front; obscura bypass sufficient.
- **Rate:** keep concurrent ≤ 2, ~1.5 rps; 429 above ~3 rps.

To activate locally:

```bash
mkdir -p ~/.rev_scraping/sites
cp templates/sites/example.com.example.toml \
   ~/.rev_scraping/sites/example.com.toml
```

---

## H. Test Strategy

### Unit (≥ 5; target ~10)
1. `store_open_creates_dir`
2. `save_then_load_roundtrip`
3. `save_is_atomic` — kill mid-write (using a fault-injecting
   filesystem wrapper), assert old content intact.
4. `render_url_substitutes_params` (including URL-encoding edge cases).
5. `render_url_missing_param_errors`.
6. `list_domains_skips_non_toml_files`.
7. `load_rejects_schema_version_mismatch`.
8. `save_rejects_forbidden_keys` (cookie/token/etc.).
9. `is_stale_respects_ttl`.
10. `import_validates_filename_matches_domain`.

### Integration
- Spin up a `wiremock` server mimicking example.com's three endpoints.
  Run `spider --url http://localhost:<port>/...`:
  - Run 1 → expect `recipe_save: true`, recipe file appears on disk.
  - Run 2 → expect `recipe_hit: true`, no browser launched (assert
    obscura was not invoked via a counter).
- `--cache-only` on a fresh dir → exit code 9.
- `--cache-refresh` overwrites `last_verified`.

### E2E (`#[ignore]`)
- `e2e_example_site_recipe_learn`: real network. Run once with empty
  recipe dir, expect save. Run again, expect hit and no obscura.
- `e2e_recipe_export_import_roundtrip`: export example, remove,
  import, assert equivalence.

---

## I. Phased Rollout

| Sub-phase | Scope | Effort |
|-----------|-------|-------:|
| **7a** | `stealth-sites` crate: types, store, atomic write, URI template, validation, **2 template files**, unit tests. No CLI changes. | ~1 day |
| **7b** | spider integration: domain extraction, `load` branch, `save` on success, JSON fields, four new flags, exit code 9. Uses existing obscura unchanged. | ~0.5 day |
| **7c** | Auto-learning: chromiumoxide Network capture + JS-bundle regex probe → build `SiteRecipe` from observations. Includes path-template canonicalization (numeric/UUID/slug → `{param}`). | ~1 day |
| **7d** | MCP tools: `recipe_list`, `recipe_show`, `recipe_remove`, `recipe_propose_endpoint`, `recipe_export`, `recipe_import`. | ~0.5 day |
| **total** | | **~3 days** |

### Dependency order
- 7a must land first (nothing depends on it but 7b/c/d all consume it).
- 7b and 7c can be parallelized; 7b ships a recipe-aware spider that
  consumes manually-authored recipes (like the example sample),
  giving immediate value before auto-learning lands.
- 7d is independent and can be deferred.

### First task to execute

**Create `crates/stealth-sites` with `recipe.rs` (types + serde) and
the matching unit tests for schema parsing using the committed
template files as fixtures.** That single PR validates the schema is
loadable end-to-end and unlocks every downstream sub-phase.

---

## Appendix — Open questions (defer to implementation review)

1. Should `rate_limits` be a hard cap enforced by the spider, or only
   a hint? (Recommend: hard cap, overridable via CLI flag.)
2. Do we want a `[changelog]` section auto-appended on each
   `--cache-refresh`? (Recommend: no — keep recipes small; rely on
   git-of-the-home-dir if user wants history.)
3. Cross-process file locking (advisory `flock`) — needed? (Recommend:
   skip in 7a; revisit if multi-process spider becomes a thing.)
