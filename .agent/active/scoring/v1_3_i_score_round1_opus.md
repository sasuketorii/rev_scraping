# Lane I Opus scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 9.2 | snapshot 6 dim + deprecated_completeness 2 tests; I.5 freshness-only documented |
| B | 9.0 | compat.md 3-tier + CHANGELOG keep-a-changelog 1.1 + I.5 honest disclosure |
| C | 9.5 | Playwright/Crawl4AI/Browserless are public-API-drift-undocumented; 3 detectors here are gap-widening |
| D | 8.8 | typed agent reads cargo-public-api CI diff; compat machine-grep-able; replace_with attr lacks schema export (-0.2) |
| E | 9.0 | schema_version-aware snapshot script; detector has base-diff slot for future |
| F | 9.0 | 3 CI jobs lightweight (snapshot static, public-api advisory) |
| G | 9.0 | breaking detector advisory + schema-version fail-closed + deprecated CI catches silent removal |

overall = 9.08
verdict: PASS (>= 9.0)

deltas to harden 9.0 -> 9.3+:
- D+0.2: export #[deprecated]'s replace_with into cli-public-api.snapshot.json
- A+0.1: add opt-in base-diff skeleton to mcp-schema-breaking.sh
- B+0.1: add 3-case worked-example table for MCP breaking in compat.md
- E+0.1: schema_version bump migration note section in compat.md
- G+0.1: require removal_target_version in deprecated_completeness test
