# Rust 移行 — 実装進捗報告

**実施日:** 2026-04-16
**現行判定:** `partial parity`。`do not apply as-is; modify first; staged adoption only after remediation`
**読み方:** 本書の `LGTM` / 完了表記は proposal 実装時点の履歴記録であり、現時点の repo-wide acceptance、最終 LGTM、cutover readiness を意味しない。現行の判断は `toRust-Idea/DECISION_20260417_modify_then_apply.md` と `docs/manual/verification-truth-matrix.md` を優先する。

---

## 1. 実装スナップショット

| 指標 | Before (Shell/TS) | After (Rust) | 改善 |
|------|-------------------|-------------|------|
| コード量 | 37,330 LOC (44ファイル) | 19,718 LOC (36ファイル) | **47% 圧縮** |
| 外部依存 | 95 MB (node_modules) | **0 MB** | **100% 削減** |
| バイナリサイズ | N/A (bash+node+jq依存) | **9.0 MB** (2バイナリ合計) | — |
| jq 呼び出し | 661回 | **0回** | **完全排除** |
| テスト数 | bash カスタム (不安定) | **355 `#[test]`** | 型安全+並列実行 |
| 型安全性 | なし | **コンパイル時保証** | — |
| ランタイム依存 | bash + jq + node + git | **git のみ** | 大幅削減 |

注: 上記は workspace の実装観測値であり、全面置換や ROI の決定証跡ではない。ベンチマークと cutover 判定は別途必要。

### バイナリサイズ
```
agent-core:   4.8 MB (release)
semantic-mcp: 4.2 MB (release)
合計:          9.0 MB  ← 95 MB node_modules の 9.5%
```

---

## 2. 移植済みモジュール一覧

以下の `LGTM` は各 slice の履歴上レビュー記録であり、現時点の repo-wide final LGTM ではない。

### agent-core (14 サブコマンド)

| Shell スクリプト | LOC | Rust モジュール | テスト | レビュー記録 |
|-----------------|-----|----------------|--------|---------|
| state.sh | 906 | cmd/state.rs | 7 | LGTM |
| session.sh | 409 | session/mod.rs | 20 | LGTM |
| timeout.sh | 288 | session/timeout.rs | 17 | LGTM |
| utils.sh | 410 | shared/* (6ファイル) | 27 | LGTM |
| context_analysis.sh | 5,509 | cmd/context.rs | 22 | LGTM |
| context_capsule.sh | 3,250 | cmd/capsule.rs | 25 | LGTM |
| shadow_verify.sh | 1,865 | cmd/verify.rs | 18 | LGTM |
| reviewer.sh | 2,371 | cmd/review.rs | 27 | LGTM |
| coder.sh | 1,123 | cmd/coder.rs | 24 | LGTM |
| task_contract.sh | 2,171 | cmd/contract.rs | 14 | LGTM |
| auto_orchestrate.sh | 3,853 | cmd/orchestrate.rs | 8 | LGTM |
| hydra | 1,486 | cmd/worktree.rs | 7 | LGTM |
| quality_gate.sh | 61 | cmd/gate.rs | 3 | LGTM |
| project-id.sh | 325 | cmd/project_id.rs | 11 | LGTM |
| init-project.sh + bootstrap.sh | 703 | cmd/init.rs | 9 | LGTM |
| codex-review-hook.sh | 126 | cmd/hook.rs | 13 | LGTM |

### semantic-mcp (MCP Server)

| TypeScript モジュール | LOC | Rust モジュール | テスト | レビュー記録 |
|---------------------|-----|----------------|--------|---------|
| index.ts + server.ts | 658 | main.rs + protocol.rs | 12 | LGTM |
| db/connection.ts + migrations.ts | 639 | db.rs | 2 | LGTM |
| tools/registry.ts | 1,628 | registry.rs | 20 | LGTM |
| tools/preflight.ts | 1,298 | preflight.rs | 18 | LGTM |
| tools/capsule.ts | 416 | capsule.rs | 13 | LGTM |
| db/review-queue.ts + review-runs.ts | 1,431 | review_queue.rs | 9 | LGTM |
| tools/health.ts | 27 | health.rs | 3 | LGTM |
| cli.ts + utils | 387 | util.rs + context.rs | 7+8 | LGTM |

---

## 3. クレート構造

```
toRust-Idea/rust/
├── Cargo.toml                         # workspace root
├── crates/
│   ├── shared/                        # 共有ライブラリ
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs                 # re-export
│   │       ├── types.rs               # 全ドメイン型 (State, Phase, Session, etc.)
│   │       ├── error.rs               # AgentError + Result<T>
│   │       ├── logging.rs             # tracing ベースログ
│   │       ├── lock.rs                # fs2 ファイルロック (RAII Drop)
│   │       ├── git.rs                 # git CLI ラッパー
│   │       └── validation.rs          # 入力検証 (identifier, session_id, project_id, jq_path)
│   │
│   ├── agent-core/                    # メイン CLI バイナリ (4.8 MB)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs                # clap CLI エントリポイント (14 サブコマンド)
│   │       ├── cmd/
│   │       │   ├── mod.rs
│   │       │   ├── state.rs           # ← state.sh (37 jq → 0)
│   │       │   ├── context.rs         # ← context_analysis.sh (211 jq → 0)
│   │       │   ├── capsule.rs         # ← context_capsule.sh (140 jq → 0)
│   │       │   ├── verify.rs          # ← shadow_verify.sh
│   │       │   ├── review.rs          # ← reviewer.sh (57 jq → 0)
│   │       │   ├── coder.rs           # ← coder.sh
│   │       │   ├── orchestrate.rs     # ← auto_orchestrate.sh (89 jq → 0)
│   │       │   ├── contract.rs        # ← task_contract.sh
│   │       │   ├── worktree.rs        # ← hydra
│   │       │   ├── gate.rs            # ← quality_gate.sh
│   │       │   ├── project_id.rs      # ← project-id.sh
│   │       │   ├── init.rs            # ← init-project.sh + bootstrap.sh
│   │       │   └── hook.rs            # ← codex-review-hook.sh
│   │       └── session/
│   │           ├── mod.rs             # ← session.sh
│   │           └── timeout.rs         # ← timeout.sh
│   │
│   └── semantic-mcp/                  # MCP Server バイナリ (4.2 MB)
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs                # stdio MCP サーバー + signal handling
│           ├── db.rs                  # rusqlite + WAL + migrations (7テーブル)
│           ├── protocol.rs            # JSON-RPC 2.0 手実装
│           ├── tools.rs               # MCP ツール定義 + ディスパッチ
│           ├── registry.rs            # sem.registry.{upsert,query,set_status,delete}
│           ├── preflight.rs           # sem.preflight (220tok budget, fail-closed)
│           ├── capsule.rs             # sem.capsule
│           ├── review_queue.rs        # レビューキュー (enqueue, lease, complete)
│           ├── health.rs              # sem.health
│           ├── context.rs             # ServerContext (Connection + project_id)
│           └── util.rs                # SHA256, truncate, normalize, stable JSON
```

---

## 4. レビュー履歴

この節は実装時のレビュー履歴を示す。現行の adoption verdict は `toRust-Idea/DECISION_20260417_modify_then_apply.md` を優先する。

| ラウンド | レビュワー | 結果 | 指摘 | 修正 |
|---------|-----------|------|------|------|
| Wave 1 初回 | Reviewer-1 | CHANGES REQUIRED | BLOCK 1, HIGH 2, MEDIUM 6 | 全6件修正 |
| Wave 1 再レビュー | Reviewer-1 | **LGTM** | 0 | — |
| 最終レビュー | Final Reviewer | CHANGES REQUIRED | BLOCK 2, HIGH 3 | 全5件修正 |
| 最終再レビュー | Final Reviewer | **LGTM** | 0 | — |

### 修正した指摘一覧
1. get_latest_codex_session のエラーハンドリングバグ (BLOCK)
2. upsert_phase の挙動不整合 (HIGH)
3. session CLI 未接続 (HIGH)
4. 重複 JQ_PATH_RE (MEDIUM)
5. ロック acquire のエラー種別判定 (MEDIUM)
6. ロック Drop のサイレントエラー (MEDIUM)
7. state_dir() のハードコードパス (BLOCK)
8. coder.rs の panic!() (BLOCK)
9. registry.rs の unwrap() (HIGH)
10. hook.rs の非アトミック書き込み (HIGH)
11. verify.rs の非アトミック書き込み (HIGH)

---

## 5. 残っている作業

以下が未完了のため、全面置換・本番 cutover・repo-wide completion 主張はまだできない。

### 必須（本番投入前）

#### A. 統合テスト
- [ ] Shell 版のテストスイート (test/integration/ 16ファイル, ~6,858 LOC) の Rust 移植
  - `cross_agent_wrapper_matrix_test` (928 LOC) — wrapper の mock テスト
  - `coder_engine_truth_test` (947 LOC) — state machine テスト
  - `semantic_coordination_test` (500+ LOC) — coordination テスト
  - `semantic_registry_mutation_flow_test` (600+ LOC) — mutation テスト
  - `hydra_test` (358 LOC) — worktree テスト
  - その他 11 ファイル
- [ ] E2E テスト: `agent-core orchestrate` の実行フロー全体テスト
- [ ] E2E テスト: `semantic-mcp` の stdio MCP プロトコル完全テスト

#### B. Shell → Rust 切り替えブリッジ
- [ ] 既存 Shell スクリプトから `agent-core <subcommand>` を呼ぶブリッジコード作成
  - auto_orchestrate.sh から `agent-core state init/set/get` を呼ぶ
  - reviewer.sh から `agent-core review run-all` を呼ぶ
  - context_analysis.sh から `agent-core context update` を呼ぶ
- [ ] CLAUDE.md の更新（Rust バイナリへのパス追加）
- [ ] .claude/settings.json の hook を Rust バイナリに切り替え

#### C. MCP Server 切り替え
- [ ] launch-semantic-mcp.sh を Rust バイナリ起動に変更
- [ ] .claude/settings.json の mcpServers.semantic を更新
- [ ] .codex/config.toml の mcp_servers.semantic を更新
- [ ] 既存 SQLite DB との互換性確認（マイグレーションスキーマ一致）

#### D. codex-wrapper / claude-wrapper の Rust 化（任意）
- [ ] codex-wrapper.sh (413 LOC) → agent-core wrapper codex
- [ ] claude-wrapper.sh (409 LOC) → agent-core wrapper claude
- [ ] 互換 shim (codex-wrapper-{medium,high,xhigh}.sh) の更新

### 推奨（品質向上）

#### E. パフォーマンスベンチマーク
- [ ] state 操作のベンチマーク（Shell jq vs Rust serde_json）
- [ ] context_analysis のベンチマーク（最大ボトルネック）
- [ ] MCP Server コールドスタート計測（Node.js vs Rust）

#### F. リリースパイプライン
- [ ] クロスコンパイル設定 (x86_64-apple-darwin, aarch64-apple-darwin, x86_64-unknown-linux-gnu)
- [ ] CI/CD ワークフロー (.github/workflows/) の追加
- [ ] sign-and-build.sh の Rust バイナリ対応

#### G. コード品質
- [ ] dead_code warnings の整理（`#[allow(dead_code)]` + コメント or feature flag）
- [ ] clippy 全 warning の解消
- [ ] `cargo doc` でドキュメント生成確認
- [ ] `cargo audit` でセキュリティ監査

### 不要（Shell 維持で十分）

| ファイル | 理由 |
|---------|------|
| launch-semantic-mcp.sh (32 LOC) | MCP 切り替え後に不要になる |
| codex-wrapper-{medium,high,xhigh}.sh (各29 LOC) | exec shim、ROI なし |
| sign-and-build.sh (321 LOC) | macOS 固有、Shell で十分 |
| build-dev.sh (100 LOC) | 開発ヘルパー、Shell で十分 |

---

## 6. 推奨する次のステップ

```
Step 1 (即座): truth/docs と failing evidence を是正
  proposal docs の completion/LGTM 表現を partial parity に揃え、
  failing test / rerun evidence の所在を deterministic に固定する。

Step 2 (次スライス): acceptance-critical remediation
  orchestrate / verify / review / gate の fail-open を閉じ、
  review/verify/cache の stale reuse と acceptance 境界を是正する。

Step 3 (その後): repo-native parity の確認
  project-native layout、semantic coordination、release-gate parity を
  narrow slice ごとに証跡付きで閉じる。

Step 4 (最後): bridge-first pilot
  rollback 可能な 1 経路だけを staged adoption し、
  cutover や Shell 廃止は remediation 完了後に別判断とする。
```

---

## 7. ファイル一覧

### toRust-Idea/ の内容

```
toRust-Idea/
├── RESULT.md                                    # 本ファイル
├── investigation_rust_optimization.md           # 初回調査レポート
├── investigation_rust_migration_feasibility.md  # 移行フィージビリティ調査
└── rust/                                        # Cargo workspace (全ソースコード)
    ├── Cargo.toml
    └── crates/
        ├── shared/      (7 files,  ~800 LOC,  27 tests)
        ├── agent-core/  (18 files, ~14,700 LOC, 236 tests)
        └── semantic-mcp/(11 files, ~4,200 LOC, 92 tests)
```
