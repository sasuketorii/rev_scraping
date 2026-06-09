# 中間レビュー雛形 (2026-06-14)

Plan v3 (`docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md`) C 節「中間レビュー」用テンプレ。
本ファイルはテンプレートであり、実際の判定結果は `docs/mid-review-2026-06.md` に複製して記入する。

## 0. メタ情報

- 実施日: 2026-06-14 (±3日許容)
- 担当: @sasuketorii
- 対象期間: 2026-05-15 〜 2026-06-13 (30日間)
- 入力データ
  - `~/.rev_harness/shim-hits.log` (現行 + rotate された `.1`〜`.5`)
  - Anthropic console の Agent SDK 課金実績
  - Anthropic 公式ポリシー更新ログ (5/14 時点との差分)

## 1. shim-hits.log 集計

### 1.1 全体ヒット数

```bash
LOG=~/.rev_harness/shim-hits.log
# 現行 + ローテーション済を結合
cat "$LOG" "$LOG".[1-5] 2>/dev/null | wc -l
```

### 1.2 rewrite_target 別ヒット数

```bash
cat "$LOG" "$LOG".[1-5] 2>/dev/null \
  | jq -r '.rewrite_target' \
  | sort | uniq -c | sort -nr
```

### 1.3 task-tool への rewrite 件数 (主指標)

```bash
cat "$LOG" "$LOG".[1-5] 2>/dev/null \
  | jq -c 'select(.rewrite_target == "task-tool")' \
  | wc -l
```

### 1.4 連続ヒット 0 日数の計算

```bash
# ts は ISO8601 (例: 2026-06-10T07:21:33Z)
# 日付ごとのヒット数を出し、末尾から 0 が続く日数を数える
cat "$LOG" "$LOG".[1-5] 2>/dev/null \
  | jq -r '.ts[:10]' \
  | sort | uniq -c \
  | awk '{print $2, $1}' > /tmp/per-day.txt

# 直近 30 日のうち末尾から連続 0 日数 (per-day.txt に出ていない日 = 0 ヒット)
today=$(date -u +%Y-%m-%d)
streak=0
for i in $(seq 0 29); do
  # macOS: date -v-${i}d、Linux: date -d "$today -$i day"
  if date -v-${i}d -u +%Y-%m-%d >/dev/null 2>&1; then
    d=$(date -v-${i}d -u +%Y-%m-%d)
  else
    d=$(date -u -d "$today -$i day" +%Y-%m-%d)
  fi
  if grep -q "^$d " /tmp/per-day.txt; then
    break
  fi
  streak=$((streak + 1))
done
echo "consecutive_zero_days=$streak"
```

## 2. Agent SDK 課金実績 vs 5/14 予測

| 指標 | 5/14 予測 | 実績 (5/15-6/13) | 比率 |
| --- | --- | --- | --- |
| 月次 credit 消費 | TODO | TODO | TODO% |
| 月次 USD 換算 | TODO | TODO | TODO% |
| 想定外 spike の有無 | - | (有/無) | - |

予測値の根拠は Plan v3 F 節を参照: `参照件数 × 月次想定呼出頻度 × Agent SDK credit 単価`。

## 3. Anthropic 側ポリシー変動

- [ ] Agent SDK の billing model 変更なし
- [ ] claude-code CLI の subprocess policy 変更なし
- [ ] その他、課金やセキュリティに影響する公式アナウンスなし

差分があれば下記に列挙:

- (なし / TODO)

## 4. 判定マトリクス

Plan v3 PR-D の 3 分岐に従う。

| 条件 | 措置 | 7/14 PR-D |
| --- | --- | --- |
| Agent SDK 実績が予測 ±20% 以内 かつ task-tool rewrite ヒット数 0 (14 日連続) | 早期撤収候補。6 月後半に PR-D を前倒し検討 | 前倒し可 |
| 予測内 かつ ヒット数 1〜10 | 通常スケジュール。7/14 に削除のみ実施。opt-in 復活は別 PR | 予定通り |
| 予測超過 (>120%) または ヒット数 >10 | 緊急対応プラン (Plan v3 E 節) 発動。PR-D 保留 | 保留 |

## 5. 結論

- 判定: (前倒し可 / 予定通り / 保留)
- 次アクション:
  - (例) `docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md` の PR-D マイルストーンを 2026-06-28 に前倒し
  - (例) 通常スケジュール継続。本ドキュメントを `docs/mid-review-2026-06.md` として確定
- 確定済み記録: `docs/mid-review-2026-06.md`

## 6. 補足

- 本テンプレートは PII を一切含まない (shim-hits.log の caller_hash / argv_hash のみ使用)
- ローテーション漏れに備え、集計時に `~/.rev_harness/shim-hits.log.{1..5}` を必ず glob で結合する
