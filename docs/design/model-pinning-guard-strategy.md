# Design (draft): `gpt-5.5` 固定維持ガード戦略 (Slice B-3)

Date: `2026-05-11`
Status: `draft`
Owner: `coder (Opus 4.7 medium)`
ExecPlan: `docs/execplan-codex-plugin-cc-evaluation.md` Slice B-3

> **本ドキュメントは設計 draft であり、実装 (CI / pre-commit / hook) は別 ExecPlan + 人間オペレーター承認後にのみ行う。**

## 0. 方針 (動かないルール)

1. `gpt-5.5` の **ハードコードは意図的** であり、Codex CLI が下位モデル (`gpt-5.4` 等) へ暗黙的に降格するのを防ぐためのもの。
2. **自動 fallback / 下位モデル切替を設計してはならない** (ExecPlan Non-Goals)。
3. EOL / 404 / quota 枯渇を検出した場合は **fail-loud**: 即停止 + 人間オペレーター通知。自動継続は不可。
4. `.agent/registry/model_policy.json` の `runtime_fallback_below_minimum: "forbidden"` を「policy 宣言」、本 guard を「実運用での執行手段」と位置付ける。

## 1. 入力 (Slice B-1 / B-2 結果)

- 参照箇所: 計 39 hits / 18 files (`docs/research/gpt-5_5-references.md` 参照)。
- 正本: `.agent/registry/model_policy.json` (`current_model`, `stable_default_model`, `minimum_allowed_model`, `model_order`, `native_agent_presets.model`, `runtime_fallback_below_minimum`).
- 実在性: Codex CLI v0.130.0 / ChatGPT account 経路で **実在** と判定 (`docs/research/gpt-5_5-codex-cli-availability.md` 参照)。

## 2. ガード設計 (5 項目)

### G-1. Typo / 近隣モデル名混入 検出 (CI + pre-commit)

**目的**: `gpt-5.4`, `gpt-5.6`, `gpt-5.5-mini`, `gpt5.5`, `GPT-5.5`, `gpt_5_5` 等の **`gpt-5.5` 以外の `gpt-5.x` 文字列** を検出してビルド/コミットを停止する。

**正規表現案** (PCRE / ripgrep):

```
# 1) gpt-5.x 系のうち 5.5 以外をすべて検出 (大小 dot/underscore/dash 揺れ込み)
(?i)\bgpt[\s_\-]?5[\s._\-]?(?!5\b)[0-9]+(?:[\s._\-]?(?:mini|nano|turbo|preview|pro|o))?\b

# 2) 表記揺れの 5.5 (正規 `gpt-5.5` 以外を検出してから許容例外を除外)
(?i)\bgpt[\s_\-]?5[._\-]5\b
  → 上記にマッチした行のうち、リテラル `gpt-5.5` ではない (大文字 / underscore / space) ものを fail-loud
```

**運用方針**:

- `rg -nP '<pattern>'` を `scripts/check-model-name-typos.sh` 相当に実装 (本 Slice では実装しない、設計のみ)。
- **除外パス**: `test/integration/model_policy_consistency_test.sh` 内の fake-evidence fixture (line 88, 101, 114, 153 等は `# example_forbidden_model …` コメントを伴う) は **コメントマーカ `example_forbidden_model` を含む行のみ skip**。パス単位の wholesale exclude は禁止 (誤検出抑止より検出網のほうが重要)。
- `docs/execplan-codex-plugin-cc-evaluation.md` 等の **meta doc** (本 ExecPlan を含む計画系 markdown) も skip しない: 計画 doc 内の typo も検出対象とする。

**配置**:

- `.git/hooks/pre-commit` 経由 (`scripts/install-hooks.sh` 相当で配布)。
- CI: GitHub Actions / 既存 deterministic checks の 1 ステップ。
- 既存 `test/integration/model_policy_consistency_test.sh` と **重複しない / 補完する** 位置付け (既存 test は policy JSON 整合性、本 guard は **テキスト全文の typo 検出**)。

### G-2. `model_policy.json` 機械可読 invariant の CI 強制

**目的**: 正本ファイルの不変条件を機械的に検証し、人間操作ミスを早期検出。

**Invariants** (CI で assertion):

- `current_model == stable_default_model == minimum_allowed_model == "gpt-5.5"`
- `model_order[-1] == "gpt-5.5"` (末尾 = 現行)
- `runtime_fallback_below_minimum == "forbidden"`
- `native_agent_presets.model == "gpt-5.5"`
- `candidate_model == null` (本 Slice 段階)

**実装案** (本 Slice では実装しない):

- `scripts/check-model-policy-invariants.sh` で `jq -e` による表明。
- 失敗時 exit 1 + stderr に明示メッセージ + Slack/メール通知 (G-4 と統合)。

### G-3. `docs/generated/codex-model-policy.md` の drift 検出

**目的**: 自動生成 doc が手で書き換えられたり、正本 JSON との不整合が放置されるのを防ぐ。

**設計**:

- CI で `scripts/regenerate-codex-model-policy-md.sh` 相当を実行し、`git diff --exit-code docs/generated/codex-model-policy.md` で drift があれば fail。
- 手書き編集は禁止 (doc 冒頭に `<!-- GENERATED; DO NOT EDIT BY HAND -->` の前置を必須化)。

### G-4. EOL / 404 / quota 枯渇 検出時の **fail-loud** 動作

**目的**: Codex CLI が `gpt-5.5` を 404 / "model not supported" / quota exhausted で拒否した場合、**自動継続させない**。

**検出シグナル** (`codex exec` のエラー応答に対する parser):

- HTTP 400 + `message: ".*model is not supported.*"` (B-2 対照実験で実観測)
- HTTP 404 (将来 EOL 時の想定)
- HTTP 429 + `quota` 文字列 (subscription 枯渇)
- HTTP 5xx 連続 (transient)

**fail-loud アクション** (本 Slice は手順設計のみ):

1. `codex-wrapper.sh` / 呼び出し元スクリプトは **非ゼロ exit + stderr に banner**:
   ```
   [FAIL-LOUD] gpt-5.5 unavailable (HTTP <code>). Auto-fallback is FORBIDDEN.
   Operator action required: confirm Codex CLI model availability and either
   (a) wait & retry, or (b) raise an ExecPlan to update model_policy.json.
   ```
2. **下位モデルへの自動 retry / fallback を試みない** (`--model gpt-5.4` 等への切替コードは存在自体を禁止)。
3. 人間通知: 既存通知経路 (Slack / メール / `logs/INCIDENT/*.jsonl`) の choose-one を draft 段階で記載し、実装時に具体化。
4. 並行ジョブはすべて **graceful stop** (新規 codex 呼び出しを抑止、進行中は中断しない)。
5. ロールバック不能性: fail-loud 後に自動再開しない。再開には人間オペレーターの explicit re-run が必須。

### G-5. EOL 監視 (受動的)

**目的**: `gpt-5.5` の EOL アナウンスをリアクティブに、ただし **自動 fallback なしに** 検出する。

**設計案**:

- `docs/official-docs-links.md` に Codex CLI release notes / OpenAI model deprecation page URL を集約。
- CI 週次ジョブで該当 URL を fetch し、本文に `gpt-5.5` の `deprecated|sunset|retire|EOL` 近接トークンが現れたら **fail-loud で通知**。
- 自動的に `model_policy.json` を書き換えない。

**注意**: 公式 API 経由のモデル enum 取得が CLI で出来ない (B-2 結論) ため、本監視はテキスト heuristics に依存する。誤検出は許容、見逃しが許されないため通知は二重化推奨 (要確認)。

## 3. 既存仕組みとの整合

- `test/integration/model_policy_consistency_test.sh` は既存の policy consistency test。本 guard と **重複させない**: 既存 test は JSON 整合、本 guard はテキスト typo + invariant + drift + fail-loud。
- `scripts/cross-family-live-artifact-smoke.sh` / `test/integration/cross_*_test.sh` の payload は `gpt-5.5` をハードコードしているが、これは smoke / fixture であり policy ではない。G-1 の検出網からは外さない (typo を含む変更は smoke でも禁止)。

## 4. 実装フェーズに先送りする項目

- 実 script (`scripts/check-model-name-typos.sh`, `scripts/check-model-policy-invariants.sh`).
- `.git/hooks/pre-commit` 配布。
- CI workflow (`.github/workflows/...`).
- 通知経路の具体実装 (Slack webhook / メール / incidents log)。
- EOL 監視の URL リスト確定。

これらは **別 ExecPlan + 手動承認** をもって着手する。本 doc は仕様提案までで停止。

## 5. 非目標 (再確認)

- 自動 fallback table を作らない。
- 下位モデルへの動的切替コードを書かない。
- `gpt-5.5` を別モデルへ置換しない (本 Slice の範囲外)。

## 6. 要確認 (Open Questions)

- [ ] G-4 の通知経路 (Slack / メール / log のいずれを正にするか)。
- [ ] G-5 の OpenAI 側公式 deprecation ページの安定 URL (`docs/official-docs-links.md` 更新が必要)。
- [ ] pre-commit と CI の二重化方針 (どちらが authoritative か)。
- [ ] subscription 経路以外 (API plan / Azure) を想定する必要があるか。
