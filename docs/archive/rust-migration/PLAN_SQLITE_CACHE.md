# ExecPlan: SQLite インデックスキャッシュシステム

**ステータス:** 設計完了・実装待ち
**目的:** ビルド・検証・レビューの冗長実行を排除し、機械検証・コンテキスト構築時間の 40-70% 削減
**配置:** 独立クレート `crates/cache` (`cache::CacheManager`)

---

## 1. アーキテクチャ決定

### CacheManager を独立クレート `cache` に配置

**理由:**
- shared は軽量基盤。rusqlite (SQLite C ライブラリ 2.5MB) を入れると全クレートが影響を受ける
- cache は shared に依存、agent-core と semantic-mcp は cache に依存（opt-in）

**依存グラフ:**
```
shared (基盤)
  ^
  |
cache (CacheManager + rusqlite)
  ^            ^
  |            |
agent-core   semantic-mcp
```

**DB 配置:** 既存の `~/.semantic-mcp/{project_id}/semantic.db` に 4 テーブルを追加。別 DB は作らない。

**マイグレーション:** `CacheManager::new()` 内部で `ensure_schema()` を呼び出し、`CREATE TABLE IF NOT EXISTS` で冪等にテーブルを作成する。明示的なマイグレーションステップは不要。

---

## 2. DB スキーマ（4 テーブル追加）

> **注意:** symbols/symbol_dependencies テーブルは PLAN_TREE_SITTER が所有。本プランの Phase 7 は tree-sitter プランの実装後に連携。

```sql
-- ファイルインデックス: 全ファイルの状態追跡
CREATE TABLE IF NOT EXISTS file_index (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    size_bytes INTEGER,
    language TEXT,
    module_name TEXT,
    mtime_epoch INTEGER,
    last_indexed_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (project_id, file_path)
);

-- 検証キャッシュ: ファイル×ツール単位の結果（最新結果で上書き）
CREATE TABLE IF NOT EXISTS verify_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    tool TEXT NOT NULL,
    status TEXT NOT NULL,
    findings_json TEXT,
    cached_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (project_id, file_path, tool)
);

-- レビューキャッシュ: ファイル×レビュワー単位の結果
CREATE TABLE IF NOT EXISTS review_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    reviewer TEXT NOT NULL,
    verdict TEXT,
    findings_json TEXT,
    reviewed_at TEXT,
    PRIMARY KEY (project_id, file_path, file_hash, reviewer)
);

-- カプセルキャッシュ: コンテキストハッシュ単位
CREATE TABLE IF NOT EXISTS capsule_cache (
    project_id TEXT NOT NULL,
    context_hash TEXT NOT NULL,
    capsule_json TEXT NOT NULL,
    capsule_sha256 TEXT NOT NULL,
    token_count INTEGER,
    cached_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (project_id, context_hash)
);

-- インデックス
CREATE INDEX IF NOT EXISTS idx_file_index_hash ON file_index(project_id, file_hash);
CREATE INDEX IF NOT EXISTS idx_verify_cache_tool ON verify_cache(project_id, tool);
CREATE INDEX IF NOT EXISTS idx_review_cache_reviewer ON review_cache(project_id, reviewer);
CREATE INDEX IF NOT EXISTS idx_capsule_cache_at ON capsule_cache(project_id, cached_at);
```

---

## 3. CacheManager API

### スレッド安全性

rusqlite::Connection は Send ではないため、CacheManager もスレッド間共有不可。

**戦略:** 各スレッドが独自の CacheManager インスタンスを生成する。
SQLite WAL モードが複数接続の並行読み取りを許可するため、これは安全。

```rust
// メインスレッド
let cache_main = CacheManager::new(&project_id)?;
let cached_reviewers = cache_main.pre_check_reviews(&files, &reviewers);

// ワーカースレッド (レビュー実行)
std::thread::spawn(move || {
    // キャッシュ不要 — メインスレッドで事前/事後チェック
    run_single_reviewer(...)
});

// メインスレッドで結果をストア
cache_main.store_review_results(&results);
```

### ツール分類

```rust
/// ファイル単位でキャッシュ可能なツール
const FILE_LEVEL_TOOLS: &[&str] = &[
    "eslint", "ruff", "shellcheck", "semgrep", "clippy-file",
];

/// プロジェクト全体チェック（ファイル単位キャッシュ不可）
const PROJECT_LEVEL_TOOLS: &[&str] = &[
    "cargo-check", "cargo-test", "tsc", "npm-test",
];
```

FILE_LEVEL_TOOLS のみ verify_cache に保存する。PROJECT_LEVEL_TOOLS は毎回実行。

### API 定義

```rust
pub struct CacheManager {
    conn: rusqlite::Connection,
    project_id: String,
}

impl CacheManager {
    /// 本番用: ~/.semantic-mcp/{project_id}/semantic.db を開く
    /// 内部で ensure_schema() を呼び出し、テーブルが存在しなければ作成する
    pub fn new(project_id: &str) -> Result<Self>;

    /// テスト用: インメモリ DB
    pub fn new_in_memory(project_id: &str) -> Result<Self>;

    // --- ファイルインデックス ---
    pub fn check_file_index(&self, file: &str) -> Option<FileIndexEntry>;
    pub fn update_file_index(&self, entry: &FileIndexEntry) -> Result<()>;
    pub fn bulk_update_file_index(&self, entries: &[FileIndexEntry]) -> Result<()>;

    // --- 検証キャッシュ ---
    pub fn check_verify_cache(&self, file: &str, hash: &str, tool: &str) -> Option<CachedVerifyResult>;
    pub fn store_verify_result(&self, file: &str, hash: &str, tool: &str, status: &str, findings: &str) -> Result<()>;
    pub fn bulk_check_verify(&self, files: &[(String, String)], tool: &str) -> Vec<(String, Option<CachedVerifyResult>)>;

    // --- レビューキャッシュ ---
    pub fn check_review_cache(&self, file: &str, hash: &str, reviewer: &str) -> Option<CachedReview>;
    pub fn store_review_result(&self, file: &str, hash: &str, reviewer: &str, verdict: &str, findings: &str) -> Result<()>;

    // --- カプセルキャッシュ ---
    pub fn check_capsule_cache(&self, context_hash: &str) -> Option<CachedCapsule>;
    pub fn store_capsule(&self, context_hash: &str, capsule_json: &str, sha256: &str, tokens: u32) -> Result<()>;

    // --- 管理 ---
    pub fn get_cache_stats(&self) -> CacheStats;
    pub fn clear_all(&self) -> Result<()>;
    pub fn clear_file(&self, file: &str) -> Result<()>;
    pub fn evict_stale(&self, max_age_days: u32) -> Result<u64>;
}
```

### 型定義

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileIndexEntry {
    pub file_path: String,
    pub file_hash: String,
    pub size_bytes: Option<u64>,
    pub language: Option<String>,
    pub module_name: Option<String>,
    pub mtime_epoch: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedVerifyResult {
    pub status: String,
    pub findings_json: String,
    pub cached_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedReview {
    pub verdict: String,
    pub findings_json: String,
    pub reviewed_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedCapsule {
    pub capsule_json: String,
    pub capsule_sha256: String,
    pub token_count: u32,
    pub cached_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheStats {
    pub file_index_count: u64,
    pub verify_cache_count: u64,
    pub review_cache_count: u64,
    pub capsule_cache_count: u64,
    pub total_size_bytes: u64,
}
```

---

## 4. 統合ポイント（具体的な変更箇所）

### 4a. verify.rs -- 検証キャッシュ

`shadow_verify_run()` 内:
1. 変更ファイルの SHA256 を計算
2. `check_verify_cache(file, hash, tool)` でキャッシュ確認
3. キャッシュヒット -> ツール実行スキップ、キャッシュ結果をマージ
4. キャッシュミス -> 通常実行 -> `store_verify_result()` で保存

**注意:** `cargo check` / `tsc` のようなプロジェクト全体チェックはファイル単位キャッシュ不可。ファイル単位でキャッシュするのは `eslint`, `ruff`, `shellcheck`, `semgrep` 等のファイル単位ツールのみ。

### 4b. context.rs -- RepoMap キャッシュ

`context_update()` 内:
1. `check_file_index(file)` -> hash 一致なら `build_repomap_entry()` スキップ
2. 不一致 -> 通常処理 -> `update_file_index()` で保存
3. **mtime 最適化 (opt-in):** `--trust-mtime` フラグ指定時のみ有効。mtime が変わっていなければ hash 変更なしと仮定し、hash 計算を省略する。デフォルトは hash ベースの判定を使用（安全側）

### 4c. review.rs -- レビューキャッシュ

`run_parallel()` 内（メインスレッドで事前チェック）:
1. 各 (file, reviewer) に対して `check_review_cache(file, hash, reviewer)`
2. ヒット -> そのレビュワーのスレッド起動をスキップ
3. ミス -> 通常の並列実行 -> 完了後 `store_review_result()` で保存

**並列アクセス:** CacheManager の Connection は Send ではない。メインスレッドで事前/事後に操作し、レビュー実行自体は既存の並列パスを使う。

### 4d. capsule.rs -- カプセルキャッシュ

`build_capsule()` の前:
1. `context_hash = SHA256(plan_content + changed_files.sort().join())`
2. `check_capsule_cache(context_hash)` -> ヒットなら早期リターン
3. ミス -> 通常ビルド -> `store_capsule()` で保存

### 4e. orchestrate.rs -- キャッシュ管理統合

```rust
// オーケストレーション開始時
let cache = CacheManager::new(&project_id)?;
cache.evict_stale(7)?;  // 7日以上古いエントリを削除

// オーケストレーション終了時
let stats = cache.get_cache_stats();
tracing::info!(
    "Cache stats: files={}, verify={}, review={}, capsule={}, hit_rate={:.1}%",
    stats.file_index_count, stats.verify_cache_count,
    stats.review_cache_count, stats.capsule_cache_count,
    calculated_hit_rate
);
```

### 4f. 新 CLI サブコマンド

```rust
pub enum CacheAction {
    /// キャッシュ統計表示
    Stats { #[arg(long)] project_id: String },
    /// 全キャッシュクリア
    Clear { #[arg(long)] project_id: String },
    /// 特定ファイルのキャッシュクリア
    ClearFile { #[arg(long)] project_id: String, #[arg(long)] file: String },
    /// 古いエントリを削除
    Evict { #[arg(long)] project_id: String, #[arg(long, default_value = "7")] max_age_days: u32 },
}
```

---

## 5. キャッシュ無効化戦略

| トリガー | 無効化対象 | メカニズム |
|---------|-----------|-----------|
| ファイル変更 | verify_cache, review_cache, file_index | file_hash 不一致で自動的にミス |
| 設定変更 (.eslintrc 等) | verify_cache 全体 | 将来: config_hash をキーに追加 |
| ツールバージョン変更 | verify_cache (該当ツール) | 将来: tool_version をキーに追加 |
| 手動クリア | 指定対象 | `agent-core cache clear` |
| 経過時間 | 全テーブル | `evict_stale(max_age_days)` |

**Phase 1 では file_hash のみでキャッシュキーを構成。** config_hash, tool_version は将来の強化項目。

---

## 6. パフォーマンス推定

### キャッシュヒット率予測

| シナリオ | キャッシュなし | キャッシュあり (推定) | 時間削減 |
|---------|-------------|---------------------|---------|
| Verify: 100ファイル, 5変更 | 100ファイル lint | 95% ヒット -> 5ファイルのみ | ~90% |
| RepoMap: 1000ファイル, 10変更 | 1000ファイル解析 | 99% ヒット -> 10ファイルのみ | ~99% |
| Review: 3レビュワー, 1ファイル変更 | 3回フルレビュー | 67-100% ヒット | 60-120秒/レビュワー |
| Capsule: 同一プラン, 変更なし | フルビルド | 100% ヒット | ~100ms |
| **40エージェントセッション全体** | 全イテレーション フル実行 | **60-85% ヒット** | **機械検証・コンテキスト構築時間の 40-70% 削減** |

### 40エージェントセッションの時間削減推定

```
初回イテレーション: 0% ヒット（コールドキャッシュ）
2回目 (5% ファイル変更): ~95% ヒット (verify + context)
3回目 (2% ファイル変更): ~98% ヒット
...
平均: 60-85% ヒット
```

---

## 7. エラーハンドリング（graceful degradation）

**キャッシュ障害でパイプラインを止めない。**

```rust
impl CacheManager {
    fn try_check<T>(&self, op: impl FnOnce() -> Result<Option<T>>) -> Option<T> {
        match op() {
            Ok(result) => result,
            Err(e) => {
                tracing::warn!("Cache check failed (graceful skip): {e}");
                None  // キャッシュミスとして扱う
            }
        }
    }

    fn try_store(&self, op: impl FnOnce() -> Result<()>) {
        if let Err(e) = op() {
            tracing::warn!("Cache store failed (non-fatal): {e}");
        }
    }
}
```

---

## 8. フェーズ計画

### Phase 1: 基盤 (1日) -- 350 LOC
- `crates/cache/` 新規クレート作成
- CacheManager + 全メソッド実装
- `CacheManager::new()` 内で `ensure_schema()` を呼び出し、4テーブルを冪等に作成
- `shared/src/error.rs` に Database バリアント追加
- ユニットテスト（in-memory DB）

### Phase 2: Verify 統合 (0.5日) -- 80 LOC
- `verify.rs` にキャッシュチェック/ストア追加
- ヒット率ログ

### Phase 3: Context 統合 (0.5日) -- 60 LOC
- `context.rs` にファイルインデックスチェック追加
- mtime 最適化

### Phase 4: Review 統合 (0.5日) -- 60 LOC
- `review.rs` にメインスレッド事前チェック追加

### Phase 5: Capsule 統合 (0.5日) -- 40 LOC
- `capsule.rs` にコンテキストハッシュベースキャッシュ追加

### Phase 6: CLI + Orchestration (0.5日) -- 100 LOC
- `cmd/cache_cmd.rs` 新規
- `orchestrate.rs` にキャッシュ管理統合

### Phase 7: Symbol Cache (deferred)
- symbols/symbol_dependencies テーブルは PLAN_TREE_SITTER が所有。本プランの Phase 7 は tree-sitter プランの実装後に連携。
- tree-sitter-index クレートのパスベース API を cache クレートから呼び出し、シンボルキャッシュ統合を実現

### Phase 8: DB 統合 (0.5日) -- 30 LOC
- `semantic-mcp/db.rs` のマイグレーションにキャッシュテーブル追加

**合計: 新規 550 LOC + 修正 332 LOC = 882 LOC**

---

## 9. テスト戦略

```rust
#[test]
fn test_verify_cache_hit() {
    let cache = CacheManager::new_in_memory("test").unwrap();
    cache.store_verify_result("src/main.rs", "abc123", "eslint", "pass", "[]").unwrap();
    let result = cache.check_verify_cache("src/main.rs", "abc123", "eslint");
    assert!(result.is_some());
    assert_eq!(result.unwrap().status, "pass");
}

#[test]
fn test_verify_cache_miss_on_hash_change() {
    let cache = CacheManager::new_in_memory("test").unwrap();
    cache.store_verify_result("src/main.rs", "abc123", "eslint", "pass", "[]").unwrap();
    let result = cache.check_verify_cache("src/main.rs", "def456", "eslint");
    assert!(result.is_none());  // hash 変更 -> ミス
}

#[test]
fn test_evict_stale_entries() {
    let cache = CacheManager::new_in_memory("test").unwrap();
    // ... store old entries, evict, verify removed
}

#[test]
fn test_graceful_degradation() {
    // DB 接続エラー時でもパイプラインは止まらない
}
```

---

## 10. リスクと対策

| リスク | 対策 |
|--------|------|
| キャッシュ汚染（不正確な結果を返す） | SHA256 ハッシュは衝突確率が天文学的に低い。file_hash ベースの無効化は決定的 |
| 並列アクセス競合 | SQLite WAL モード + busy_timeout 5000ms。CacheManager は Send ではないためスレッド跨ぎなし |
| DB サイズ肥大 | `evict_stale()` を自動実行（デフォルト 7日）。オーケストレーション開始時に呼ぶ |
| マイグレーション安全性 | 全テーブル `CREATE IF NOT EXISTS`。既存データへの破壊的変更なし |
| キャッシュ障害時の影響 | graceful degradation: 障害時はキャッシュミスとして通常パスにフォールバック |

---

## 11. 実装順序と依存関係

```
PLAN_SQLITE_CACHE                   PLAN_TREE_SITTER
=================                   ================
Phase 1: 基盤 (cache クレート)       Phase 1: 基盤
  4テーブル作成                        types.rs, parser.rs, db.rs
  ※ symbols テーブルは定義しない              |
         |                           Phase 2: 言語エクストラクタ
Phase 2: Verify 統合                         |
Phase 3: Context 統合                Phase 3: インクリメンタル
Phase 4: Review 統合                         |
Phase 5: Capsule 統合                Phase 4: agent-core 統合
Phase 6: CLI + Orchestration                 |
         |                           Phase 5: ポリッシュ
         |                                   |
Phase 7: Symbol Cache ──依存──────► tree-sitter Phase 3 完了必須
         |
Phase 8: DB 統合
```

**依存方向:**
- Phase 1-6 は PLAN_TREE_SITTER と独立して実装可能
- Phase 7 は PLAN_TREE_SITTER Phase 3（インクリメンタルエンジン）完了を前提とする
- 両プランとも `shared::error::AgentError::Database` バリアント追加が前提条件
