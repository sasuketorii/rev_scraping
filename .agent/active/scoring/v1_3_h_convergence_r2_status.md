# Lane H — R2 Dual Scoring Status (interim)

| Scorer | Round | Overall | Verdict |
|--------|-------|---------|---------|
| Codex gpt-5.5-xhigh | R1 | 6.79 | FAIL |
| Opus 4.7-xhigh | R1 | 7.38 | FAIL |
| Codex gpt-5.5-xhigh | R2 (post B-1+B-2+B-3) | 8.00 | FAIL by 1.0 |
| Opus 4.7-xhigh | R2 (pending) | — | — |

## R2 軸別 (Codex)
| 軸 | R1 → R2 | Δ |
|---|---|---|
| A acceptance | 6.8 → 8.0 | +1.2 |
| B 3-principles | 8.0 → 9.2 | +1.2 |
| C 競合 | 7.0 → 8.6 | +1.6 |
| D agent UX | 5.8 → 6.0 | +0.2 ← 最低 |
| E 負債回避 | 7.5 → 8.6 | +1.1 |
| F test+evidence | 6.0 → 8.5 | +2.5 ← 最大 |
| G docs | 6.0 → 7.1 | +1.1 |

## D 軸 6.0 の限界
Codex 指摘 4 点 (これは **Slice C 領域 = v1.3.0 tag execution**):
1. `sasuketorii/homebrew-rev-stealth` tap repo 未作成 (GitHub 側手動操作)
2. `rev-stealth-*` packages 未 crates.io publish (cargo publish 実走)
3. Formula version/sha256 placeholder (release-please の extra-files rewrite が tag 時に実行)
4. mdBook handbook が "promises in present tense" (bottles/cargo install/GH release)

すべて **plumbing は完備、tag 時に external gate が実走する設計**。Lane H Option A 選択時の前提。

## 9.0 達成への道
Lane H 単独では困難 — Slice C = v1.3.0 RC tag execution 必須。
- 全 5 lane で plumbing 完成 → v1.3.0 RC tag push
- release.yml が dry-run でも実 publish でも走行
- post-tag artifact + 実 install で D 軸 6.0 → 9.0+ 期待
- Lane H R3 採点 (post-tag baseline) で 両者 ≥ 9.0 期待

## v1.3.0 cut 後の post-tag rescore plan
- tag v1.3.0 → release.yml 全 job 完了 → 外部 gate (brew install/cargo install/docker pull/cosign verify) 実 PASS
- post-tag evidence: `.github/release-evidence/v1.3.0/`
- Lane H Codex R3 / Opus R2 を post-tag baseline で再採点
