# v1.3 Quality Bar — Dual 9/10 Convergence Protocol

**Mandate (user, 2026-05-23)**: Opus 4.7-xhigh と Codex gpt-5.5-xhigh の **両方が 10 点中 9 点以上を出すまで** 各 Lane を反復する。

## 評価プロトコル

Lane の coder driver が LGTM (binary) で sub-phase 完走した後、**追加で graded review** を実施:

1. Lane driver の完走報告を `.agent/active/reviews/v1_3_<lane>_final.md` として保存
2. **Opus 4.7-xhigh scoring agent** を独立 dispatch — Lane 成果物を 7 軸で採点
3. **Codex gpt-5.5-xhigh scoring** を canonical wrapper 経由で同じ rubric で採点
4. **両方が ≥ 9.0** で合格、Lane 完了
5. どちらか < 9.0 → 採点者の指摘を集約 → fix driver dispatch → 再採点
6. 最大 3 ラウンドの scoring (3 回 fix で 9/10 取れなければ narrow stop で operator escalate)

## Scoring rubric (7 軸 × 10 点満点)

Lane 共通の評価軸。各軸 0-10 で採点、平均が overall score。

### 軸 A: Acceptance criteria 充足度 (重み 2.0)
- ExecPlan に書かれた各 sub-phase の acceptance criteria を機械的に検証
- 全 criteria PASS → 10、半分 PASS → 5、未着手 → 0

### 軸 B: 外部 verifiable / CI gate / adversarial test の 3 原則 (重み 1.5)
- Plan A §0.2 由来。「gameable な 9/10」排除原則
- 3 原則 ≥ 2 で 10、1 で 5、0 で 0

### 軸 C: 競合比較で勝つか (重み 1.5)
- ripgrep / fd / gh / wrangler / Crawl4AI / Browserless と並べたとき同等以上か
- Lane G なら CLI UX、Lane H なら配布、Lane I なら semver discipline、Lane J なら docs、Lane K なら quality infra
- 「明確に勝つ」→ 10、「同等」→ 7、「劣後」→ 3

### 軸 D: AI エージェント開発者体験 (重み 2.0)
- Claude Code / Cursor / Hermes ユーザが evaluate して reject しないか
- JSON output / error envelope / idempotency / discoverability などが体験良く揃ってるか
- 「最初に試すべき」レベル → 10、「使える」→ 7、「習熟前提」→ 4

### 軸 E: 1 年後の負債回避 (重み 1.0)
- 採用技術が 1 年後も maintain されているか
- 設定ファイルや schema の breaking change リスク
- CI / dependency が腐る速度
- 安心 → 10、要注意点あり → 6、明確な負債 → 3

### 軸 F: テスト + evidence の質 (重み 1.0)
- 機械検証可能な test (proptest / fuzz / golden / integration) の量と質
- 単なる happy-path test は 5、edge case + adversarial で 10
- evidence (artifacts, logs, screenshots) の保存有無

### 軸 G: ドキュメント完全性 (重み 1.0)
- Lane 成果物が次の人 (operator / contributor / reviewer) が読んで理解可能か
- ADR / RELEASE_NOTES 反映 / README / mdBook 整合性
- 「次の人にハンドオフ可能」→ 10、「自分しか分からない」→ 3

## 計算式

```
overall = (A*2.0 + B*1.5 + C*1.5 + D*2.0 + E*1.0 + F*1.0 + G*1.0) / 10.0
合格: Opus overall ≥ 9.0 AND Codex overall ≥ 9.0
```

両者の score 差が 1.5 を超えた場合、disagreement reason を文書化、tie-break は operator。

## Lane 別の追加軸 (rubric 上書き、上記 7 軸の D を再解釈)

| Lane | D の特化 |
|------|---------|
| G — CLI UX 黒帯化 | 「ripgrep ファンが好む」+ 「Claude Code から `--output-format json` で安全に pipe できる」|
| H — 配布距離ゼロ | 「`brew install rev-stealth` を 60 秒で実行できる」+「SBOM/cosign で supply-chain 監査可能」|
| I — API stability | 「semver 違反が PR レベルで止まる」+「deprecation policy が機械可読」|
| J — Agent-First docs | 「`docs/.../tutorial/05-claude-code.md` 通りで 5 分で動く」+「26 ErrorKind 全て個別解説」|
| K — Quality moat | 「coverage 80%+ / fuzz nightly / cross-platform 4 matrix / SBOM/sigstore」|

## Scoring agent への prompt 雛形

```
あなたは <Opus 4.7-xhigh | Codex gpt-5.5-xhigh> の v1.3 Lane <X> scoring 担当。

Lane 成果物: <driver report path>
Rubric: .agent/active/v1_3_quality_bar.md の 7 軸 (A-G)
ExecPlan 参照: .agent/active/v1_3_uplift_execplan_rev1.md Lane <X>
ベースライン: v1.2.0 (commit b2153aa0)

各軸を 0-10 で採点、根拠を 1-3 行で記述。
最後に overall score (重み付き平均) を出して、< 9.0 なら具体的な「9 にするための差分」を箇条書き。

形式:
| 軸 | スコア | 根拠 |
|---|---|---|
| A | X.X | ... |
...
overall = X.XX

verdict: PASS (≥ 9.0) | FAIL (< 9.0)
deltas to reach 9.0: <none | bullet list>
```

## Scoring loop ターミネーション

- max 3 fix round per lane
- 3 round で両者 9/10 未達 → narrow stop + operator escalation (v1.3.0 として ship するか、v1.3.0-rc1 で出して soak するか判断)
- 両者 ≥ 9.0 で初回合格は理想だが現実的には 1-2 fix round 想定

## Evidence 保存

- Scoring prompts: `.agent/active/scoring/v1_3_<lane>_score_round{1,2,3}_<opus|codex>.md`
- Scoring responses: `.agent/active/scoring/v1_3_<lane>_score_round{1,2,3}_<opus|codex>.out`
- Final convergence record: `.agent/active/scoring/v1_3_<lane>_convergence.md` (両者の最終 score + delta history)

## Operator visibility

各 lane の Pass/Fail と差分は `.agent/active/v1_3_progress.md` (ダッシュボード markdown) に集約、operator は 1 ファイル見れば全 lane 進捗を把握可能。
