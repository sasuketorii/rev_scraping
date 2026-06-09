# Plan v5 — rev_harness 0.0.6 Perfecting (2026-05-14)

監査ソース: gpt-5.5-high × 5 codex-job 並列 (codex-job.sh dogfood)
起案日: 2026-05-14 / リリース目標: 同日

## 0. 監査結果サマリ

| 軸 | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| 1. Shell quality + bash 3.x | 0 | 3 | 4 | 3 |
| 2. Security | 0 | 3 | 3 | 1 |
| 3. API + docs | 0 | 5 | 3 | 2 |
| 4. Edge cases | 0 | 3 | 4 | 3 |
| 5. Release ops | 2 | 4 | 4 | 2 |
| 合計 | 2 | 18 | 18 | 11 |

## 1. 採用 / 延期判断

### 0.0.6 で完全対応 (今日)
- Audit-1 HIGH 全 3件 (exit_code atomic / PID reuse / claude-wrapper --add-dir validation)
- Audit-3 HIGH 全 5件 (start --timeout / role list / shim spec / migration / canonical表記)
- Audit-4 HIGH 全 3件 (wait timeout 境界 / gc --ttl 検証 / gc rm失敗)
- Audit-5 CRITICAL 全 2件 (CI 復旧 / branch protection 代替: CODEOWNERS)
- Audit-5 HIGH 全 4件 (CODEOWNERS / Releases / shim rotation / metrics)
- Audit-2 HIGH-3 (codex-job artifact umask + 非永続化)
- Audit-2 MEDIUM-1 (path traversal、PoC 成立済なので blocker扱い)
- Audit-2 MEDIUM-2/3 (secret stderr 漏洩, sign-and-build secret argv)

### 0.0.7 候補 (破壊的、別 PR)
- Audit-2 HIGH-1 (codex-wrapper -c allowlist 化) — X1-X14b に影響大、X14c-X14z テスト追加必要
- Audit-2 HIGH-2 (claude-wrapper --add-dir / --mcp-config allowlist 化) — 既存利用パターン精査必要

### 後続 (MEDIUM/LOW 一掃)
- Audit-1 MEDIUM 4件 (trap cleanup / 数値検証 / blocked option dangling)
- Audit-3 MEDIUM 3件 (exit code 統一 / changelog format / rewrite_target enum)
- Audit-4 MEDIUM 4件 (disk full / PID 再利用 / HOME unset / clock skew)
- Audit-5 MEDIUM 4件 (CI matrix / version一貫性 / SemVer規約 / dependency matrix)
- LOW 6件 (community profile / ROADMAP / etc.)

## 2. 0.0.6 PR 構成 (3本)

### PR-A: codex-job.sh blocker 修正
変更ファイル:
- ./scripts/codex-job.sh (8修正)
- ./test/integration/cross_agent_wrapper_matrix_test.sh (X15f-h 追加)

詳細修正項目:
1. exit_code atomic write (tmp+mv)
2. PID reuse 判定順序 (exit_code 先確認)
3. wait --timeout 0/1 境界
4. gc --ttl 入力検証 + 上限365
5. gc rm 失敗継続 + summary
6. start --timeout を help から削除
7. umask 077 + prompt の非永続化 (--keep-prompt opt-in)
8. path traversal 防御 (job-id 正規表現、realpath 閉じ込め)

新規テスト: X15f (timeout 0/1 境界), X15g (gc --ttl 不正値), X15h (path traversal)

### PR-B: docs 整合
変更ファイル:
- ./docs/shim-spec.md (job_id + REV_HARNESS_SHIM_HITS_LOG schema 追加)
- ./README.md (role 一覧 high-coder 追加、claude-wrapper を deprecated shim に明記)
- ./docs/migration-agent-sdk-2026-06.md (30日 vs 60日 整理)
- ./CHANGELOG.md (Migration 表記統一、0.0.1/0.0.2 entry 追加)
- ./scripts/claude-wrapper.sh (DEPRECATED コメント表記統一)

### PR-C: CI 復旧 + 運用整備
変更ファイル:
- ./.github/workflows/ci.yml (REV_HARNESS_CANONICAL_ROOT env 追加)
- ./.github/CODEOWNERS (新規)
- ./scripts/shim-hits-rotate.sh (新規、ログローテーション)
- ./docs/mid-review-template.md (新規、6/14 雛形)
- ./docs/release-notes/0.0.3.md, 0.0.4.md, 0.0.5.md (新規、GH Releases 用素材)

リリース後アクション:
- `gh release create 0.0.3/0.0.4/0.0.5/0.0.6` でリリースページ作成
- CI green 確認

## 3. PR コミット順序

1. PR-A (codex-job.sh) → matrix 23/23 確認
2. PR-B (docs) → markdown lint
3. PR-C (CI + 運用) → CI 再実行で green 確認
4. tag 0.0.6 + push
5. gh release create で 0.0.3〜0.0.6 の Release 作成

## 4. 0.0.6 リリース後の TODO (将来 PR)

### 0.0.7 候補 (wrapper allowlist 化、破壊的)
- codex-wrapper -c allowlist
- claude-wrapper --add-dir / --mcp-config allowlist
- X14c-X14z 追加テスト (allowlist 違反 → exit 70)
- migration ガイド (既存利用者の opt-out 経路)

### 0.0.8 候補 (MEDIUM 一掃)
- 全 wrapper の trap cleanup 統一
- exit code 統一 (harness-doctor の 2 → 64)
- CHANGELOG 表記統一
- disk full / HOME unset / clock skew ハンドリング
- CI matrix 化 (macos / ubuntu / wsl)

### 0.1.0 候補 (community + 運用成熟)
- LICENSE / CONTRIBUTING / CODE_OF_CONDUCT / issue template
- ROADMAP.md
- SemVer 運用規約明文化
- dependency platform matrix

## 5. リリース運用度スコア目標
- 現状: 4/10 (Audit-5 評価)
- 0.0.6 後: **7/10** 目標 (CI 復旧 + CODEOWNERS + Releases + rotation + metrics)
- 0.0.7-0.0.8 後: **8.5/10** 目標 (wrapper allowlist + MEDIUM 一掃)
- 0.1.0 後: **9.5/10** 目標 (community profile + ROADMAP)

## 6. 想定リスク

- PR-A の path traversal 防御で job-id 形式が変わる可能性 → X15a-e 回帰防止
- PR-C の CI 復旧で他の構造的問題が露呈する可能性 → コミット前にローカル smoke
- 5並列 codex audit が捕捉できなかった盲点 (audit 自体の網羅性は監査対象外)
- wrapper allowlist 化 (0.0.7 候補) を遅延すると -c / --add-dir 経路から secret 漏洩リスクが継続

## 7. Critical Files for Implementation
- ./scripts/codex-job.sh (PR-A)
- ./test/integration/cross_agent_wrapper_matrix_test.sh (PR-A)
- ./docs/shim-spec.md (PR-B)
- ./README.md (PR-B)
- ./docs/migration-agent-sdk-2026-06.md (PR-B)
- ./CHANGELOG.md (PR-B)
- ./.github/workflows/ci.yml (PR-C)
- ./.github/CODEOWNERS (PR-C)
- ./scripts/shim-hits-rotate.sh (PR-C)
- ./docs/release-notes/{0.0.3,0.0.4,0.0.5}.md (PR-C)

## 8. 関連
- 監査入力: /tmp/audit-1〜5-*.txt (5 監査プロンプト)
- 監査ジョブ ID: /tmp/0.0.6-audit-ids.txt
- 監査出力: ~/.rev_harness/jobs/<id>/log
- 先行 Plan: ./docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md (0.0.3-0.0.4), ./docs/plans/2026-05-reporting-reliability/plan-v4-final.md (0.0.5)
