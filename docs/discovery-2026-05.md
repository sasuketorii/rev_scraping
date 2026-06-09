# Discovery: claude-wrapper 参照棚卸し (2026-05-14)

## 1. rev_harness 内の参照一覧

| ファイル | 行番号 | 内容 | 分類 |
|---------|--------|------|------|
| scripts/claude-wrapper.sh | 7, 334-336 | wrapper 定義・ヘルプテキスト | 実装 |
| scripts/claude-wrapper.sh | 693, 768 | `claude --print` 呼出・エラーハンドリング | 実装 |
| scripts/claude-wrapper.sh | 743 | stderr ログ出力 | 実装 |
| .claude/commands/lib/session.sh | 105, 136, 139, 180 | CLAUDE_WRAPPER 解決・実行 | 実装 |
| .claude/commands/README.md | 102-125 | 使用方法ドキュメント | docs |
| CLAUDE.md | 22, 104, 174, 394, 405 | cross-family 委譲ルール | docs |
| AGENTS.md | 261, 271, 291 | same-family/cross-family ポリシー | docs |
| docs/agent-sdk-policy.md | 36, 47, 50, 59, 80 | SDK ポリシー参照 | docs |
| test/integration/cross_agent_wrapper_matrix_test.sh | 354, 467, 667-700, 982, 1138 | マトリックステスト X2-X4, X7, X11 | テスト |
| test/integration/claude_wrapper_mode_split_test.sh | 79, 109, 142, 167, 193, 247, 269, 294, 310, 336, 363, 391, 422, 450, 477, 503, 532, 560, 589, 618, 647, 683, 720, 748, 776, 808, 842, 870, 900, 930, 958, 984, 1013, 1041, 1070, 1098, 1129, 1155, 1181, 1207, 1236 | mode split テスト(多数) | テスト |
| test/integration/harness_release_gate.sh | 625 | release gate テスト | テスト |
| test/integration/claude_live_runtime_smoke.sh | 53 | smoke テスト | テスト |
| scripts/rev-harness-dual-native-check.sh | 40, 49 | dual-native チェック | 実装 |
| scripts/init-project.sh | 306 | 初期化ドキュメント | docs |
| scripts/rev-harness-task-classifier.sh | 111 | タスク分類 | 実装 |
| scripts/cross-family-live-artifact-smoke.sh | 15, 525 | smoke テスト、filter | 実装 |
| .agent/PROJECT_CONTEXT.md | 205 | agent context | docs |
| .agent_rules/RULES.md | 587 | agent rules | docs |

**参照総数: 約 95+ 行**

## 2. dev 横断スキャン結果

### vendored copy 検出

他リポジトリ 9 件において `scripts/claude-wrapper.sh` の vendored copy / snapshot / worktree コピーを検出 (詳細は非公開ログ参照)。

**検出: 12+ 箇所 (他リポジトリ distributed copy)**

### .gitmodules スキャン
**検出: なし** (rev_license は 2026-05-14 commit a0a806f で分離済)

## 3. claude --print 呼出位置

**ファイル**: `scripts/claude-wrapper.sh` (787 LOC)  
**行番号**: 693, 768

### コード抜粋 (行 690-775)

```bash
CMD=(claude --print --permission-mode "$FIXED_PERMISSION_MODE" --effort "$CLI_EFFORT")

if [[ "$RESUME_MODE" == true ]]; then
  CMD+=(--resume "$RESUME_SESSION_ID")
  if [[ "$FORK_SESSION" == true ]]; then
    CMD+=(--fork-session --session-id "$SESSION_ID")
  fi
fi

if [[ -n "$INPUT_FILE" ]]; then
  CMD+=(< "$INPUT_FILE")
fi

log_info "Claude を呼び出します: ${CMD[*]}"
EXIT_CODE=0
"${CMD[@]}" >"$OUTPUT_FILE" 2>"$STDERR_LOG" || EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 0 ]]; then
  log_error "claude --print が異常終了しました (exit code: ${EXIT_CODE})"
fi
```

**呼出形式**: `claude --print --permission-mode <mode> --effort <effort> [--resume <id>] [--fork-session ...] [< input]`

## 4. 間接呼出の検査

### hooks (.claude/settings.json)
**検出: なし**

### .codex/agents/*.toml
**検出: なし** (claude-wrapper 直接参照なし)

### session.sh / auto_orchestrate.sh
**検出: あり**
- `session.sh` 行 136: `_session_resolve_canonical_wrapper_path` で canonical wrapper を解決
- `session.sh` 行 180: `"$CLAUDE_WRAPPER" "$@"` で呼び出し
- canonical path 以外は fail-closed で拒否 (行 138-139)

### semantic-runtime
**検出: なし**

## 5. matrix test 棚卸し (X1-X13)

| TestID | 名称 | 方向 | 内容 | negative化対象 |
|--------|------|------|------|---|
| X1 | codex_to_codex | Codex→Codex | codex wrapper role matrix, non-interactive resume fail | no |
| X2 | codex_to_claude | **Codex→Claude** | claude wrapper with `--print`, bypassPermissions, medium effort | **yes** (Codex → Claude 禁止) |
| X3 | claude_to_codex | **Claude→Codex** | reviewer role, legacy shims, role escape rejection | no (positive) |
| X4 | claude_to_claude | **Claude→Claude** | claude wrapper with `--print`, bypassPermissions, medium effort | no (positive but same-family) |
| X5 | session_helpers | mixed | non-interactive flow, continuation fail, effort cap | no |
| X6 | codex_strips_flags | Codex | --cd, --add-dir strip | no |
| X7 | claude_strips_flags | **Codex→Claude** | equals-form bypass flag strip | **yes** (Codex → Claude 禁止) |
| X8 | session_rejects_override | mixed | CLAUDE_WRAPPER env override rejection | no |
| X9 | session_uses_canonical | Codex | canonical codex wrapper routing | no |
| X10 | reviewer_rejects_override | Claude | CODEX_WRAPPER_CANONICAL override rejection | no |
| X11 | claude_rejects_external_stderr | **Codex→Claude** | repo-external stderr root rejection | **yes** (Codex → Claude 禁止) |
| X12 | codex_rejects_model_override | Codex | model policy, multi-agent guard | no |
| X13 | codex_rejects_api_key | Codex | OpenAI API-key auth rejection (subscription-auth) | no |

**総テスト数: 13 個**  
**cross-family Claude→Codex: X3 (positive, ただし manual session / reviewer 経由)**  
**cross-family Codex→Claude: X2, X7, X11 (3件, いずれも negative化対象)**

## 6. PR-A/B での処理対象まとめ

### PR-A: claude-wrapper.sh → shim 化
**対象ファイル:**
- `scripts/claude-wrapper.sh` (787 LOC 全体)
  - 行 693: `claude --print` → `claude --delegate` 互換ラッパーへ
  - 行 768: エラーハンドリング update
  - canonical path check は保持 (fail-closed)

### PR-B: negative test 化
**対象テストID:** (3件)
- **X2** (test_x2_codex_to_claude)
  - テスト: Codex → Claude 委譲が fail-closed で拒否されることを検証
  - 現在: positive (成功する) → negative (失敗すべき) へ転換
- **X7** (claude_strips_flags)
  - 実体は Codex→Claude 経路での equals-form bypass flag strip 検証
  - 現在: positive → negative (Codex → Claude 委譲自体が fail-closed) へ転換
- **X11** (claude_rejects_external_stderr)
  - 実体は Codex→Claude 経路での repo-external stderr root rejection 検証
  - 現在: positive → negative (Codex → Claude 委譲自体が fail-closed) へ転換

**その他テスト:**
- X3, X4: positive のまま保持 (直接の claude-wrapper 使用 or session helper 経由)

### PR-D: 削除候補
**条件:** Discovery で検出された参照件数 × 月次想定呼出頻度 = 0 の場合のみ

**予測:**
- rev_harness 内参照: ~95 行 (doc/config) → **永続保持** (agent SDK policy の記録値)
- vendored copy 他リポ: ~12 箇所 → **段階的廃止** (各リポで shim 化)
- X2, X7, X11 negative test (3件): **PR-B で inverse logic へ**
- 6/15 以降 Agent SDK credit 消費 → 意図しない従量課金リスク **最小化**

---

**出力日**: 2026-05-14  
**検査対象**: `./` (rev_harness リポルート)  
**実行者**: claude-code / Discovery 工程  
**次フェーズ**: PR-A/B 実装 (cross-family delegation shim 化)
