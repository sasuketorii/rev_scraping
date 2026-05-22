# Lane K Opus scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 9.0 | truth-matrix deterministic-evidence 原則整合、coverage.yml/security.yml/bench.yml が evidence path 明示 |
| B | 9.2 | 8 sub-phase 全 deliverable、forbid(unsafe) 13/13、proptest 8 × 256 が target crate 網羅、fuzz 3 target 攻撃面選定良 |
| C | 9.1 | 781→800 PASS (+19) 実数確認可、cargo-llvm-cov delta + 多層 security gate + 4 matrix cross-platform、fuzz nightly 1h/day 妥当 |
| D | 9.3 | supply-chain (SBOM + cosign keyless OIDC) + nightly fuzz crash + cross-platform + forbid-unsafe を 1 lane で揃え。branch TRACKED-ONLY 段階開示は honest 加点 |
| E | 8.7 | fuzz nightly 3 × 1h/day + cross-platform 4 + bench 4-way で CI 分数増、intel macos runner high cost、budget 明示薄 |
| F | 9.0 | line soft gate v1.3 → branch TRACKED-ONLY v1.4 二段階破壊なし、forbid(unsafe) は obscura-bridge escape hatch、SBOM/cosign 新規 |
| G | 8.8 | sub-phase ごと workflow path/lint 名/proptest 数 明記、Codex retrofit max 3 round 運用明示、SAFETY-doc awk 位置は ExecPlan 本文依存 |

overall = 9.06
verdict: PASS (>= 9.0)

deltas (v1.4 候補、非 blocking):
- E+0.3: CI 分数 budget 数値見積り (intel macos runner 単価) を ExecPlan 追記
- G+0.2: SAFETY-doc lint awk regex 実体を workflow inline script 出典コメント
- B+0.2: TUI / obscura-bridge FFI 境界 fuzz v1.4 検討
