# Agent Base 軽量化・高速化・堅牢化 調査レポート

**調査日:** 2026-04-16
**対象:** agent_base ハーネス基盤全体
**調査観点:** Rust化による高速化、依存削減、堅牢性向上

---

## 1. 現状サマリー

### プロジェクト規模

| 領域 | LOC | ファイル数 | 備考 |
|------|-----|-----------|------|
| Shell scripts (lib/) | 22,749 | 9 | state.sh, coder.sh, reviewer.sh 等 |
| Shell scripts (scripts/) | 2,544 | 13 | codex-wrapper.sh, claude-wrapper.sh 等 |
| auto_orchestrate.sh | 3,853 | 1 | メインオーケストレーター |
| hydra (bash) | 1,486 | 1 | Git worktree マネージャー |
| Semantic MCP Server (TS) | 7,474 | 13 | Node.js + SQLite |
| **合計** | **~38,000** | **46+** | shell + TypeScript |

### 依存関係サイズ

| 依存 | サイズ | 用途 |
|------|--------|------|
| node_modules (MCP Server) | **95 MB** | MCP SDK, better-sqlite3, TypeScript, Vitest |
| .git/ | 31 MB | 履歴 |
| .claude/ | 17 MB | 設定・キャッシュ |
| **合計プロジェクト** | **147 MB** | |

### 主要ボトルネック

| ランク | コンポーネント | 問題 | 影響度 |
|--------|--------------|------|--------|
| 1 | context_analysis.sh | **211回の jq 呼び出し** (ループ内) → 最大8,400回の起動 | 致命的 |
| 2 | context_capsule.sh | **140回の jq 呼び出し** → 最大3,900回の起動 | 致命的 |
| 3 | shadow_verify.sh | 217回のファイル書き込み + worktree 作成 | 高 |
| 4 | auto_orchestrate.sh | 89回の jq 呼び出し + 8ライブラリの source | 高 |
| 5 | reviewer.sh | 57回の jq 呼び出し + 並列上限3 | 中 |
| 6 | state.sh | 37回の jq → state CRUD のクリティカルパス | 中 |
| 7 | MCP Server 起動 | コールドスタート 315-580ms | 低〜中 |

**jq 呼び出し総数: 全スクリプト合計で 661回**

各 jq の起動オーバーヘッドが ~50ms とすると、最悪ケースで **7分以上が jq の起動だけ** に消費される。

---

## 2. Rust 化の提案

### 2.1 Rust 化対象の優先度

#### Tier 1: 最高優先（ROI最大）— `agent-core` CLI

**対象:** state.sh + context_analysis.sh + context_capsule.sh + shadow_verify.sh の機能統合

| 機能 | 現状 | Rust化後 |
|------|------|---------|
| JSON state CRUD | jq 37回/操作 | serde_json でインメモリ処理、0回の外部プロセス起動 |
| コンテキスト分析 | jq 211回 + git 19回 | 全てインプロセス (gix + serde_json) |
| カプセル生成 | jq 140回 | serde_json + tiktoken-rs でインプロセス |
| Shadow Verify | 外部コマンド連鎖 | プロセス管理を直接制御 |

**推定効果:**
- **速度:** 10-50x 高速化（jq 起動オーバーヘッド完全排除）
- **サイズ:** 95MB の node_modules → 5-10MB のシングルバイナリ
- **堅牢性:** 型安全、コンパイル時検証、パニックではなく Result 型

**Rust クレート候補:**

```toml
[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
clap = { version = "4", features = ["derive"] }    # CLI パーサー
gix = "0.70"                                         # Pure-Rust git
rusqlite = { version = "0.33", features = ["bundled"] }  # SQLite
tokio = { version = "1", features = ["full"] }       # 非同期ランタイム
tiktoken-rs = "0.6"                                  # トークン推定
sha2 = "0.10"                                        # SHA256
uuid = { version = "1", features = ["v4"] }          # UUID生成
```

**サブコマンド設計:**

```
agent-core state init --plan <path> --task <name>
agent-core state get <jq-path>
agent-core state set <jq-path> <value>
agent-core state summary

agent-core context analyze --plan <path> --output <path>
agent-core context capsule --input <path> --budget 220

agent-core verify --phase <phase> --worktree <path>
agent-core verify --incremental --diff <commit>
```

#### Tier 2: 高優先 — `semantic-mcp` (MCP Server の Rust 化)

**対象:** scripts/semantic-mcp-server/ 全体

| 指標 | TypeScript (現状) | Rust 化後 |
|------|-------------------|----------|
| node_modules | 95 MB | 0 MB |
| バイナリサイズ | N/A (Node.js 依存) | ~5-8 MB |
| コールドスタート | 315-580 ms | **10-30 ms** |
| メモリ使用量 | ~50-80 MB (Node.js) | ~5-15 MB |
| SQLite アクセス | better-sqlite3 (native binding) | rusqlite (直接リンク) |

**Rust クレート候補:**

```toml
[dependencies]
rusqlite = { version = "0.33", features = ["bundled"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
# MCP protocol は JSON-RPC over stdio → 手書き可能（~500行）
```

**効果:**
- node_modules 95 MB → 完全排除
- Node.js ランタイム依存の排除
- コールドスタート 20x 高速化

#### Tier 3: 中優先 — `hydra` (Worktree Manager)

**対象:** scripts/hydra (1,486行の bash)

| 指標 | Bash (現状) | Rust 化後 |
|------|-------------|----------|
| git 操作 | git CLI 呼び出し | gix でインプロセス |
| ロック管理 | mkdir ベース | fs2::FileLock (OS ネイティブ) |
| エラーハンドリング | set -e + trap | Result 型 + anyhow |
| 並列制御 | bash job control | tokio/rayon |

#### Tier 4: 低優先 — Wrapper スクリプト群

codex-wrapper.sh / claude-wrapper.sh は CLI ラッパーとして bash で十分。
Rust 化の ROI は低い（外部プロセス起動が本質なため）。

---

### 2.2 移行戦略: 段階的 Rust 化

```
Phase 1 (2-3週間): agent-core CLI
  └─ state, context, capsule, verify をシングルバイナリに
  └─ 既存 shell から `agent-core <subcommand>` を呼ぶだけ（drop-in 置換）

Phase 2 (2-3週間): semantic-mcp の Rust 化
  └─ MCP プロトコル (JSON-RPC over stdio) を手実装
  └─ rusqlite で既存 SQLite スキーマをそのまま使用
  └─ node_modules 95MB を完全排除

Phase 3 (1-2週間): hydra の Rust 化
  └─ gix で git 操作をインプロセス化
  └─ ファイルロックを OS ネイティブに

Phase 4 (継続的): Shell 薄層化
  └─ auto_orchestrate.sh → agent-core orchestrate へ段階移行
  └─ 最終的に shell は CLI グルーコードのみ（~500行以下）
```

---

## 3. Rust 化以外の即効施策

Rust 化の前に、既存 shell スクリプトだけで実現できる高速化もある。

### 3.1 jq バッチ化（即効、Rust 化前に実施可能）

```bash
# BEFORE: ループ内で jq を N 回呼ぶ
for file in "${files[@]}"; do
  result=$(jq -R . "$file" | jq -cs 'map(...)')
done

# AFTER: 1回の jq で全ファイルを処理
printf '%s\n' "${files[@]}" | jq -R -cs '[inputs | ...]'
```

**推定効果:** context_analysis.sh で 5-10x 高速化

### 3.2 MCP Server の依存削減（Node.js のまま軽量化）

| 変更 | 削減量 | リスク |
|------|--------|--------|
| `--omit=dev` で本番インストール | -25 MB | なし |
| MCP SDK → 手書き stdio JSON-RPC | -5 MB | 低 |
| Zod → 手書きバリデーション | -6 MB | 低 |
| **合計** | **-36 MB** | |

### 3.3 Shadow Verify のインクリメンタル化

```bash
# BEFORE: 毎回 full worktree 作成
git worktree add ...

# AFTER: 差分のみ検証
changed_files=$(git diff --name-only HEAD~1)
# 変更ファイルに関連するテストだけ実行
```

---

## 4. 堅牢性の改善ポイント

### 4.1 現状の堅牢性（良い点）

- 入力検証: `_validate_identifier()`, `_validate_jq_path()` 等
- セッション検証: UUID 形式のみ許可
- wrapper の fail-closed 設計
- ロック機構（mkdir ベース）

### 4.2 Rust 化で得られる堅牢性

| 領域 | Bash の限界 | Rust の優位性 |
|------|------------|-------------|
| 型安全性 | なし（全て文字列） | コンパイル時に型不整合を検出 |
| エラーハンドリング | `set -e` は不完全（パイプ内で効かない等） | `Result<T, E>` で全エラーパスを強制 |
| 並行処理 | `&` + `wait` （レースコンディション脆弱） | `tokio` / `rayon` で安全な並行処理 |
| JSON 操作 | jq の構文エラーが実行時まで不明 | `serde` でコンパイル時にスキーマ検証 |
| メモリ安全性 | バッファオーバーフロー等の考慮不要だが変数展開のバグ | 所有権システムで保証 |
| テスタビリティ | bash のユニットテストは困難 | `#[test]` で関数単位のテスト |
| ファイルロック | mkdir ベース（クラッシュ時にリーク） | `fs2::FileLock` (OS が自動解放) |

### 4.3 具体的な堅牢性リスク（現状）

1. **jq パイプラインの失敗が伝搬しないケース**: `set -o pipefail` でも jq のパース失敗が silent fail する場合がある
2. **state.json の破損リスク**: jq の出力を直接 state.json に書き戻す際、途中でクラッシュすると破損
3. **ロックファイルのリーク**: プロセスが SIGKILL された場合 mkdir ロックが残る
4. **シェル変数の未初期化**: `set -u` があっても配列の空チェック等で漏れが出やすい

---

## 5. 推定効果まとめ

### パフォーマンス

| 指標 | 現状 | Rust 化後 | 改善率 |
|------|------|----------|--------|
| jq 起動オーバーヘッド | ~7分 (最悪ケース) | 0 秒 | **∞** |
| MCP Server コールドスタート | 315-580 ms | 10-30 ms | **10-20x** |
| state.json 操作 | ~1.8秒/操作 (37 jq) | <1ms/操作 | **1800x** |
| コンテキスト分析 | 数分 | 数秒 | **10-50x** |
| hydra worktree 操作 | git CLI 経由 | gix インプロセス | **3-5x** |

### フットプリント

| 指標 | 現状 | Rust 化後 | 削減率 |
|------|------|----------|--------|
| node_modules | 95 MB | 0 MB | **100%** |
| バイナリ合計 | N/A (Node.js 依存) | ~15-20 MB | — |
| ランタイム依存 | Node.js + jq + git | git のみ (gix 内蔵なら 0) | **大幅削減** |
| メモリ使用量 (MCP) | 50-80 MB | 5-15 MB | **70-80%** |

---

## 6. 推奨 Rust プロジェクト構造

```
rust/
├── Cargo.toml                # workspace
├── crates/
│   ├── agent-core/           # Tier 1: state, context, capsule, verify
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs       # CLI エントリポイント
│   │       ├── state.rs      # state.json CRUD
│   │       ├── context.rs    # コンテキスト分析
│   │       ├── capsule.rs    # カプセル生成
│   │       ├── verify.rs     # Shadow Verify
│   │       └── git.rs        # gix ラッパー
│   │
│   ├── semantic-mcp/         # Tier 2: MCP Server
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs       # stdio MCP サーバー
│   │       ├── db.rs         # rusqlite + migrations
│   │       ├── registry.rs   # レジストリ操作
│   │       ├── preflight.rs  # プリフライト検証
│   │       ├── capsule.rs    # カプセルツール
│   │       └── protocol.rs   # MCP JSON-RPC
│   │
│   ├── hydra/                # Tier 3: Worktree Manager
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs
│   │       ├── worktree.rs   # gix worktree 操作
│   │       └── lock.rs       # OS ネイティブロック
│   │
│   └── shared/               # 共有ライブラリ
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── types.rs      # 共通型定義
│           ├── config.rs     # 設定管理
│           └── error.rs      # エラー型
│
└── tests/                    # 統合テスト
    └── integration/
```

---

## 7. 結論

### やるべきか？ → **Yes、段階的に**

1. **即効施策（今すぐ）:** jq バッチ化 + MCP Server 依存削減 → 2-5x 高速化
2. **Phase 1（最優先）:** `agent-core` CLI → jq 661回を完全排除 → 10-50x 高速化
3. **Phase 2:** `semantic-mcp` Rust 化 → 95MB 排除 + 20x コールドスタート高速化
4. **Phase 3:** `hydra` Rust 化 → git 操作のインプロセス化

**最大のリターン:** Phase 1 の `agent-core` だけで、プロジェクト全体の体感速度が劇的に改善する。
661回の jq 起動が 0 になるインパクトは計り知れない。

**リスク:** Shell → Rust の書き換えは、既存の bash ロジック（特にエッジケースのエラーハンドリング）を完全に移植する必要がある。段階的に移行し、既存 shell からサブコマンドとして呼ぶ戦略が最も安全。
