# Plan v4 (Final) — rev_harness 0.0.5 報告信頼性問題対応

期日: 2026-05-14 起案 / リリース目標: 同日
関連: Plan v3 (Agent SDK billing separation, 0.0.3-0.0.4)、commit 履歴 c09fe32 / 486eb0e / 699311b

## 0. 問題
Claude Code orchestrator から codex-wrapper.sh 経由で Codex を呼ぶ際、Task tool で起動した sub-agent が長時間 codex 実行 (5〜15分) を polling 待ちしようとして自分の token/tool 予算を枯渇 → "I'll wait" return → ゲート検証なしで終了。実装は OK だが監督層からのレポートが脱落する。

## 1. 根本原因
- Agent 1回起動の暗黙上限 (max tool calls + token budget)
- Bash `wait $pid` はセッション跨げない
- ScheduleWakeup は /loop dynamic 専用、sub-agent 不可
- run_in_background は親への return が即時、内側 agent は自分の予算

## 2. 採用解 (Option A + Option C ハイブリッド)
中核は **Option A (監督省略 + 責務分離)** で sub-agent 予算枯渇を構造的に消す。`scripts/codex-job.sh` を新設し codex-wrapper.sh の API 表面は不変。job.sh の wait サブコマンドに **Option C (Monitor 親和 block-wait)** セマンティクスを持たせ、1-turn 完結性も確保。

### 却下した代替
- **Option A 純粋**: 自動修正ラウンドが失われる懸念に対し、verifier sub-agent を短命起動する形で対応可能だが UX が 2 turn 化するため Option C 要素を取り入れる
- **Option B (fire-and-exit + verifier)**: ゲート検証ロジックが verifier に飛び散り、shim-hits の解釈が二重実装になるため却下
- **Option C 純粋**: wrapper API 表面拡大 (`--detach` 追加) で同期/非同期の二系統を wrapper 内に抱えると shim-hits 意味論が分岐するため却下

## 3. 実装スコープ

### 新規ファイル
- `scripts/codex-job.sh`: サブコマンド start / status / wait / result / gc
- jobs ディレクトリ規約: `$REV_HARNESS_RUN_DIR/jobs/<job-id>/{cmd,pid,log,exit_code,status.json}`
- `docs/plans/2026-05-reporting-reliability/plan-v4-final.md` (この文書)

### 改修ファイル
- `scripts/codex-wrapper.sh`: **改修なし** (API 表面温存)。job.sh が wrapper を nohup で起動する形に留める
- `scripts/_shim-log.sh`: PR#2 で job-id 紐付けフィールド追加 (オプショナル、0.0.4 互換)
- `test/integration/cross_agent_wrapper_matrix_test.sh`: X15a-e 追加
- `README.md`: Quickstart に job.sh 例追加
- `docs/adoption-guide.md`: "long-running codex execution" セクション追加
- `CHANGELOG.md`: 0.0.5 entry

## 4. テスト戦略

既存 X1-X14b は wrapper 同期パスのまま温存 (影響なし)。新規:

| ID | 検証内容 |
|---|---|
| X15a | job start: 即 return、job-id / status.json / pid file が生成 |
| X15b | job wait: 完了済 job で exit_code 取得 + status JSON 出力 |
| X15c | job wait timeout: Monitor 不在環境想定、--timeout 指定で status 返却 + non-block exit |
| X15d | job gc + 並列 job: TTL 超過 job 回収、ULID で id 衝突なし |
| X15e | shim-hits join key: shim-hits.log に job-id 紐付け確認 (PR#2) |

## 5. 0.0.3 / 0.0.4 整合

- preflight / VENDOR GUARD / gpt-5.5 固定 / shim-hits.log は wrapper 内に温存
- job.sh は wrapper を呼ぶだけなので全ガードが透過的に効く
- PR#2 で shim-hits の job-id 紐付けは backward-compatible (新フィールドのみ追加)

## 6. PR 構成 (2 本)

**PR#1: codex-job.sh コア + 単体テスト** (revert 可能粒度)
- 新規: scripts/codex-job.sh
- 新規: test/integration/cross_agent_wrapper_matrix_test.sh の X15a-d
- wrapper 改修なし
- 検証: matrix 18/18 (X1-X14b + X15a-d) PASS

**PR#2: shim-hits 紐付け + docs**
- 改修: scripts/_shim-log.sh (job-id フィールド追加)
- 新規: X15e
- 改修: README, docs/adoption-guide.md, CHANGELOG
- 後方互換維持 (job-id 未渡しでも従来通り動作)

## 7. リリース手順

1. PR#1 マージ → matrix 全件グリーン確認
2. (任意) `v0.0.5-rc1` タグ → 24h soak
3. PR#2 マージ → matrix 全件グリーン確認
4. `v0.0.5` annotated tag → push
5. shim 期間は不要 (既存パス無改変)、soft-mode も不要

## 8. 想定リスク

| リスク | 緩和策 |
|---|---|
| nohup 起動の孤児プロセス | `gc` サブコマンドで TTL 回収 (default 7d) |
| exit-code file の atomic write 失敗 | tmp+rename パターン必須、`mv` で atomic |
| Monitor 不在環境での wait timeout | 既定 900s (15分)、--timeout で上書き可、X15c で検証 |
| 並列 job-id 衝突 | ULID 採用 (lexicographic sortable + 衝突回避) |
| jobs ディレクトリ肥大化 | gc サブコマンドを cron 化推奨、adoption-guide に明記 |
| shim-hits backward compatibility | 新フィールド (job_id) はオプショナル、既存パーサ無影響 |

## 9. UX フロー例

### Claude Code orchestrator (Monitor 利用可)
```bash
# 起動 (即 return)
job_id=$(scripts/codex-job.sh start --role reviewer "review src/foo.rs")

# Monitor で block wait (Claude Code TUI 内、1 tool call 完結)
scripts/codex-job.sh wait "$job_id" --timeout 1800 > result.json

# exit code 取得
exit_code=$(scripts/codex-job.sh result "$job_id" --field exit_code)
```

### Bash 直接利用 (CI / 手動)
```bash
job_id=$(scripts/codex-job.sh start --role coder "implement X")
# 他作業
sleep 30
scripts/codex-job.sh status "$job_id"  # running / completed
# 完了後
scripts/codex-job.sh result "$job_id"  # status.json を stdout に
```

## 10. Critical Files for Implementation
- ./scripts/codex-job.sh (新規)
- ./scripts/_shim-log.sh (PR#2 改修)
- ./test/integration/cross_agent_wrapper_matrix_test.sh (X15a-e 追加)
- ./README.md (Quickstart 例)
- ./docs/adoption-guide.md (long-running section)
- ./CHANGELOG.md (0.0.5 entry)

## 11. 関連 commit
- c09fe32: Agent SDK billing policy (0.0.3 起点)
- 486eb0e: Plan v3 final (Agent SDK 課金分離対応)
- ea365f9: PII sanitize (0.0.3 リリース)
- 9d80c57: canonical guard (0.0.4)
- cf7fb2f: adoption-guide + CHANGELOG (0.0.4 リリース)
- 699311b: housekeeping (0.0.3 確定日付 + vendored inventory)
