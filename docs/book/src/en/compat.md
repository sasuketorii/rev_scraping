# Compatibility & Semver

| Surface | Guarantee | Notes |
|---|---|---|
| MCP tool schema | **2-major** versions | tool input/outputSchema; breaking change requires `mcp-schema-breaking` PR label |
| CLI flags | **1-major** version | renaming/removing a flag requires a deprecation cycle |
| Output envelope (`ErrorEnvelope`, `--output-format json`) | **2-major** | fields are additive; renames are breaking |
| Internal Rust types (`pub` items inside `crates/stealth-*`) | **no guarantee** | use the CLI or MCP, not the library, if you need stability |
| File on-disk layout (`~/.config/rev-stealth/`, `~/.local/share/rev-stealth/`) | **1-major** | migrations run automatically with `--dry-run` available |

See also:

- [`docs/MCP_REFERENCE.md`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md) — full auto-generated tool reference
- `cargo-public-api` PR gate — every `pub` item change must be labeled
  `api-additive` or `api-breaking`.
- `CHANGELOG.md` — keep-a-changelog format, machine-parseable.
