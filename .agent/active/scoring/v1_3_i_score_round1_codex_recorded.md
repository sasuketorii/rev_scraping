# Lane I Codex scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 7.6 | I.3/I.6 強いが I.2 advisory + label gate なし、I.4 changelog-path 不整合、I.5 enum/output policy-only、I.1 output field inventory 弱い |
| B | 8.0 | snapshot/MCP diff/deprecated lint の CI ある、label 条件が機械 enforcement されず adversarial gate 未完 |
| C | 8.2 | semver 可視化良し、hard gate / 全 workspace public API / schema 全面 diff 未揃い |
| D | 7.4 | PR レベル止め部分達成、public API ↔ label/bump/changelog 連動未機械化 |
| E | 7.7 | schema_version=2 / nightly pin 保守意識、release-please/changelog 不整合残 |
| F | 7.5 | deprecated test 良し、snapshot/MCP detector fixture regression / enum rename simulation 不足 |
| G | 8.4 | compat.md honest だが docs と CI 実装の不整合 (label enforcement の機械化要求が advisory 依存) |

overall = 7.79 FAIL

deltas (Codex):
1. cargo-public-api-diff を全 workspace member 対象の hard gate、PR label api-additive/api-breaking 実検査
2. mcp-schema-breaking-detector を label-aware + base-vs-head、tool removal/required tightening/enum narrowing/output field rename 検出 (I.5 limitation 解消)
3. release-please-config.json の changelog-path を CHANGELOG.rev_scraping.md に合わせる + keep-a-changelog parse CI 検証
4. CLI snapshot に JSON/output fields + MCP output schemas + ErrorKind 追加、fixture tests で drift/breaking/additive 3 ケース固定
