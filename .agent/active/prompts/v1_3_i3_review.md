# Review v1.3 I.3 — docs/compat.md semver policy

## Files touched
- `docs/compat.md` (new, ~120 lines)
- `README.md` — added one TOC bullet linking to `docs/compat.md`

## Gates PASS
- markdown renders (manual visual check).
- README TOC link target exists.

## Verify (3)
1. Three tiers are explicitly documented with their guarantees:
   - MCP schema = 2-major
   - CLI flags / env vars / exit codes = 1-major
   - Internal Rust types = no guarantee
2. Each tier names its drift gate (snapshot script / cargo-public-api / mcp-schema-breaking) and the required PR label (api-additive / api-breaking / mcp-schema-breaking).
3. The deprecation lifecycle (ship → `#[deprecated]` warning → remove) is documented for both MCP tools and CLI flags, and is reachable from the README.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
