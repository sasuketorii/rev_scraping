# ExecPlan: tree-sitter + SQLite Cache — 57件全対策 + 32件追加修正版

## Context

既存の PLAN_TREE_SITTER.md と PLAN_SQLITE_CACHE.md に対して、adversarial review で **57件の問題** が発見された。さらにプラン自体のレビューで **32件の設計不備** が追加発見された。

本プランはこれら **全89件の対策を織り込んだ完全版** である。

**対象:** `toRust-Idea/rust/crates/` 配下
**既存:** 3クレート (shared, agent-core, semantic-mcp), 19,718 LOC, 356テスト

---

## 0. 前提条件（Phase 0）

### 0a. AgentError::Database 追加

`shared/src/error.rs` に追加:
```rust
#[error("Database error: {0}")]
Database(String),
```

**orphan rule 回避:** shared に rusqlite 依存を入れない。各クレートで `.map_err(|e| AgentError::Database(e.to_string()))` を使用。`From<rusqlite::Error>` は実装しない。

### 0b. Phase 依存関係

```
Phase 0 (前提)
  |
  +---> Phase 1 (cache クレート)
  +---> Phase 2 (tree-sitter-index クレート)
  |
  Phase 3 (tree-sitter 言語エクストラクタ) ← Phase 2 完了後
  |
  Phase 4 (agent-core 統合) ← Phase 1, 3 完了後
  |
  Phase 5 (CLI + ポリッシュ) ← Phase 4 完了後
  |
  Phase 6 (semantic-mcp DB 統合) ← Phase 4 完了後
```

---

## 1. cache クレート基盤

### 1a. アーキテクチャ

独立クレート `crates/cache/`。shared に rusqlite を入れない。

```
shared (基盤: 型安全、rusqlite なし)
  ^
  |
cache (CacheManager + rusqlite)     tree-sitter-index (パーサー + rusqlite)
  ^            ^                       ^            ^
  |            |                       |            |
agent-core   semantic-mcp          agent-core   semantic-mcp
```

### 1b. DB スキーマ（4テーブル）

```sql
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

CREATE TABLE IF NOT EXISTS verify_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    tool TEXT NOT NULL,
    config_hash TEXT NOT NULL DEFAULT '',
    tool_version TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    findings_json TEXT,
    cached_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (project_id, file_path, tool)
    -- HIT判定: WHERE file_hash=? AND config_hash=? AND tool_version=?
    -- INSERT OR REPLACE で最新結果のみ保持
);

CREATE TABLE IF NOT EXISTS review_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    reviewer TEXT NOT NULL,
    prompt_hash TEXT NOT NULL DEFAULT '',
    head_commit TEXT NOT NULL DEFAULT '',
    verdict TEXT,
    findings_json TEXT,
    reviewed_at TEXT,
    PRIMARY KEY (project_id, file_path, reviewer)
    -- HIT判定: WHERE file_hash=? AND prompt_hash=? AND head_commit=?
    -- INSERT OR REPLACE で最新結果のみ保持
);

CREATE TABLE IF NOT EXISTS capsule_cache (
    project_id TEXT NOT NULL,
    context_hash TEXT NOT NULL,
    capsule_json TEXT NOT NULL,
    capsule_sha256 TEXT NOT NULL,
    token_count INTEGER,
    last_accessed_at TEXT DEFAULT (datetime('now')),
    cached_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (project_id, context_hash)
);

CREATE INDEX IF NOT EXISTS idx_file_index_hash ON file_index(project_id, file_hash);
CREATE INDEX IF NOT EXISTS idx_verify_cache_tool ON verify_cache(project_id, tool);
CREATE INDEX IF NOT EXISTS idx_review_cache_reviewer ON review_cache(project_id, reviewer);
CREATE INDEX IF NOT EXISTS idx_capsule_cache_accessed ON capsule_cache(project_id, last_accessed_at);
```

**PK 設計の根拠:**
- verify_cache / review_cache: PK に file_hash を含めない → INSERT OR REPLACE で最新結果のみ保持（蓄積防止）
- HIT 判定は WHERE 句で file_hash + config_hash + tool_version を全てチェック（正確性保証）
- capsule_cache: LRU は last_accessed_at で管理（cached_at ではなく access 時更新）

### 1c. config_hash の計算

```rust
/// ツールごとの設定ファイルマッピング
const TOOL_CONFIG_MAP: &[(&str, &[&str])] = &[
    ("eslint", &[".eslintrc", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yml"]),
    ("ruff", &[".ruff.toml", "ruff.toml", "pyproject.toml"]),
    ("clippy", &["clippy.toml", ".clippy.toml"]),
    ("shellcheck", &[".shellcheckrc"]),
    ("semgrep", &[".semgrep.yml", ".semgrep"]),
];

/// 設定ファイルのハッシュを計算。存在しない場合は空文字列のハッシュ
fn compute_config_hash(tool: &str, project_root: &Path) -> String {
    let empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    let config_files = TOOL_CONFIG_MAP.iter()
        .find(|(t, _)| *t == tool)
        .map(|(_, files)| *files)
        .unwrap_or(&[]);

    for config in config_files {
        let path = project_root.join(config);
        if path.exists() {
            return compute_file_hash(&path).unwrap_or_else(|_| empty_hash.to_string());
        }
    }
    empty_hash.to_string()
}
```

### 1d. prompt_hash の計算

```rust
/// Reviewer プロンプト「テンプレート」のハッシュ（動的コンテキストは含めない）
fn compute_prompt_hash(reviewer: &str, prompts_dir: &Path) -> String {
    let empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    // テンプレートファイル: docs/prompts/reviewer_{name}.md
    let template_path = prompts_dir.join(format!("reviewer_{reviewer}.md"));
    if template_path.exists() {
        compute_file_hash(&template_path).unwrap_or_else(|_| empty_hash.to_string())
    } else {
        empty_hash.to_string()
    }
}
```

**スコープ:** テンプレート部分のみハッシュ。coder output 等の動的部分は含めない。

### 1e. symbols_digest の計算

```rust
/// 変更ファイルのシンボル ID リストのダイジェスト
/// impact_analysis の前に計算し、capsule_cache のキーに含める
fn compute_symbols_digest(conn: &Connection, project_id: &str, changed_files: &[&str]) -> String {
    let empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    // SQL: SELECT id FROM symbols WHERE project_id=? AND file_path IN (?) ORDER BY id
    let ids: Vec<i64> = /* query */;
    if ids.is_empty() {
        return empty_hash.to_string();
    }
    let input = ids.iter().map(|id| id.to_string()).collect::<Vec<_>>().join(",");
    sha256_hex(input.as_bytes())
}
```

**タイミング:** context update 完了後、capsule build の前に計算。循環依存なし。

### 1f. tool_version の取得

```rust
fn get_tool_version(tool: &str) -> String {
    let (cmd, args) = match tool {
        "eslint" => ("eslint", vec!["--version"]),
        "ruff" => ("ruff", vec!["--version"]),
        "semgrep" => ("semgrep", vec!["--version"]),
        "clippy" => ("cargo", vec!["clippy", "--version"]),
        "shellcheck" => ("shellcheck", vec!["--version"]),
        _ => return String::new(),
    };
    Command::new(cmd).args(&args).output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}
```

### 1g. CacheManager API（全シグネチャ確定版）

```rust
pub struct CacheManager {
    conn: Connection,
    project_id: String,
}

impl CacheManager {
    pub fn new(project_id: &str) -> Result<Self>;  // ensure_schema + quick_check 内蔵
    pub fn new_in_memory(project_id: &str) -> Result<Self>;

    // --- verify ---
    pub fn check_verify(&self, file: &str, file_hash: &str, tool: &str,
                        config_hash: &str, tool_version: &str) -> Option<CachedVerifyResult>;
    pub fn store_verify(&self, file: &str, file_hash: &str, tool: &str,
                        config_hash: &str, tool_version: &str,
                        status: &str, findings: &str) -> Result<()>;

    // --- review ---
    pub fn check_review(&self, file: &str, file_hash: &str, reviewer: &str,
                        prompt_hash: &str, head_commit: &str) -> Option<CachedReview>;
    pub fn store_review(&self, file: &str, file_hash: &str, reviewer: &str,
                        prompt_hash: &str, head_commit: &str,
                        verdict: &str, findings: &str) -> Result<()>;

    // --- capsule ---
    pub fn check_capsule(&self, context_hash: &str) -> Option<CachedCapsule>;
    pub fn store_capsule(&self, context_hash: &str, json: &str, sha256: &str, tokens: u32) -> Result<()>;
    pub fn touch_capsule(&self, context_hash: &str) -> Result<()>;  // last_accessed_at 更新

    // --- file index ---
    pub fn check_file_index(&self, file: &str) -> Option<FileIndexEntry>;
    pub fn update_file_index(&self, entry: &FileIndexEntry) -> Result<()>;

    // --- verify miss → review 無効化 ---
    pub fn invalidate_review_on_verify_miss(&self, file: &str) -> Result<()>;
    // 注: ファイル内容が変わった場合のみ発火。config変更のみでは発火しない。

    // --- maintenance ---
    pub fn maintenance(&self, max_age_days: u32, existing_files: &[String]) -> Result<MaintenanceResult>;
    pub fn gc_deleted_files(&self, existing_files: &[String]) -> Result<GcResult>;
    pub fn evict_stale(&self, max_age_days: u32) -> Result<u64>;  // 1000行ずつバッチ DELETE
    pub fn enforce_capsule_lru(&self, max_entries: u32) -> Result<()>;  // last_accessed_at 基準
    pub fn wal_checkpoint(&self) -> Result<()>;
    pub fn vacuum_if_needed(&self) -> Result<bool>;  // 削除率30%超で実行

    // --- 管理 ---
    pub fn get_cache_stats(&self) -> CacheStats;
    pub fn clear_cache_only(&self) -> Result<()>;  // 4 cache テーブルのみ
    pub fn clear_all(&self) -> Result<()>;  // cache + tree-sitter 7テーブル全て
    pub fn clear_file(&self, file: &str) -> Result<()>;

    // --- audit ---
    pub fn audit(&self, sample_size: u32) -> Result<AuditResult>;
    // N個のverify_cacheエントリをランダム選択、ツール再実行、結果比較
    // ミスマッチ率 > 20% → そのツールの全キャッシュ無効化
}

// --- ツール分類 ---
const FILE_LEVEL_TOOLS: &[&str] = &["eslint", "ruff", "shellcheck", "semgrep"];
const PROJECT_LEVEL_TOOLS: &[&str] = &["cargo-check", "cargo-test", "tsc", "npm-test"];
// FILE_LEVEL_TOOLS のみ verify_cache に保存
```

### 1h. DB 接続管理

```rust
fn open_cache_db(project_id: &str) -> Result<Connection> {
    let db_dir = dirs::home_dir()
        .ok_or_else(|| AgentError::Config("HOME not set".into()))?
        .join(".semantic-mcp")
        .join(project_id);
    std::fs::create_dir_all(&db_dir)  // #20: ディレクトリなければ作成
        .map_err(AgentError::Io)?;
    let db_path = db_dir.join("semantic.db");
    let conn = Connection::open(&db_path)
        .map_err(|e| AgentError::Database(e.to_string()))?;

    // pragmas
    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| AgentError::Database(e.to_string()))?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(|e| AgentError::Database(e.to_string()))?;
    conn.pragma_update(None, "busy_timeout", 30000)  // #14: 30秒
        .map_err(|e| AgentError::Database(e.to_string()))?;

    // #C-1: 起動時 quick_check (integrity_check より高速)
    let check: String = conn.query_row("PRAGMA quick_check", [], |r| r.get(0))
        .map_err(|e| AgentError::Database(e.to_string()))?;
    if check != "ok" {
        tracing::error!("DB quick_check failed: {check}. Dropping cache tables only...");
        drop_cache_tables(&conn)?;  // semantic-mcp コアテーブルは残す
    }

    ensure_schema(&conn)?;
    check_schema_version(&conn)?;
    Ok(conn)
}

/// cache + tree-sitter テーブルのみ DROP（semantic-mcp コアは残す）
fn drop_cache_tables(conn: &Connection) -> Result<()> {
    for table in &["file_index", "verify_cache", "review_cache", "capsule_cache",
                   "symbols", "symbol_dependencies", "file_parse_cache"] {
        conn.execute(&format!("DROP TABLE IF EXISTS {table}"), [])
            .map_err(|e| AgentError::Database(e.to_string()))?;
    }
    Ok(())
}
```

### 1i. スキーマバージョニングとマイグレーション

```rust
const CACHE_SCHEMA_VERSION: i32 = 1;

fn check_schema_version(conn: &Connection) -> Result<()> {
    // cache 用に独自の _cache_meta テーブルでバージョン管理
    // （user_version は semantic-mcp が使用するため衝突回避）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS _cache_meta (key TEXT PRIMARY KEY, value TEXT)",
        [],
    ).map_err(|e| AgentError::Database(e.to_string()))?;

    let current: i32 = conn.query_row(
        "SELECT COALESCE((SELECT value FROM _cache_meta WHERE key='schema_version'), '0')",
        [], |r| r.get::<_, String>(0),
    ).map(|s| s.parse().unwrap_or(0))
     .unwrap_or(0);

    if current < CACHE_SCHEMA_VERSION {
        run_cache_migrations(conn, current, CACHE_SCHEMA_VERSION)?;
        conn.execute(
            "INSERT OR REPLACE INTO _cache_meta (key, value) VALUES ('schema_version', ?1)",
            params![CACHE_SCHEMA_VERSION.to_string()],
        ).map_err(|e| AgentError::Database(e.to_string()))?;
    }
    Ok(())
}

fn run_cache_migrations(conn: &Connection, from: i32, to: i32) -> Result<()> {
    // version 0 → 1: 全テーブル CREATE (IF NOT EXISTS なので冪等)
    if from < 1 {
        ensure_schema(conn)?;
    }
    // version 1 → 2 (将来): ALTER TABLE ADD COLUMN ... DEFAULT ...
    // SQLite は NOT NULL + DEFAULT 付きの ADD COLUMN のみ許可
    Ok(())
}
```

**review_cache PK 変更のマイグレーション:**
旧 PK `(project_id, file_path, file_hash, reviewer)` → 新 PK `(project_id, file_path, reviewer)`。
既存 DB が旧スキーマの場合:
```rust
// version 0 → 1 マイグレーション内
conn.execute_batch("
    CREATE TABLE IF NOT EXISTS review_cache_v2 (...新スキーマ...);
    INSERT OR IGNORE INTO review_cache_v2 SELECT ... FROM review_cache;
    DROP TABLE IF EXISTS review_cache;
    ALTER TABLE review_cache_v2 RENAME TO review_cache;
")?;
```

### 1j. evict_stale 対象テーブルと日付カラム

| テーブル | 日付カラム | evict 対象 |
|---------|-----------|-----------|
| file_index | last_indexed_at | YES |
| verify_cache | cached_at | YES |
| review_cache | reviewed_at | YES |
| capsule_cache | cached_at | YES (+ LRU) |
| symbols | updated_at | YES |
| symbol_dependencies | updated_at | YES |
| file_parse_cache | parsed_at | YES |

```rust
fn evict_stale(&self, max_age_days: u32) -> Result<u64> {
    let tables = [
        ("file_index", "last_indexed_at"),
        ("verify_cache", "cached_at"),
        ("review_cache", "reviewed_at"),
        ("capsule_cache", "cached_at"),
        ("symbols", "updated_at"),
        ("symbol_dependencies", "updated_at"),
        ("file_parse_cache", "parsed_at"),
    ];
    let mut total = 0u64;
    for (table, col) in &tables {
        loop {
            // 1000行ずつバッチ DELETE (#D-3)
            // NOTE: DELETE ... LIMIT は SQLite デフォルトでは未サポート
            // サブクエリで rowid を特定してから DELETE する
            let deleted = conn.execute(
                &format!("DELETE FROM {table} WHERE rowid IN (
                    SELECT rowid FROM {table} WHERE project_id=?1 AND {col} < datetime('now', '-' || ?2 || ' days') LIMIT 1000
                )"),
                params![self.project_id, max_age_days],
            ).map_err(|e| AgentError::Database(e.to_string()))?;
            total += deleted as u64;
            if deleted < 1000 { break; }
        }
    }
    Ok(total)
}
```

### 1k. disk full 検出

```rust
fn try_store<F: FnOnce(&Connection) -> rusqlite::Result<()>>(&self, op: F) {
    match op(&self.conn) {
        Ok(()) => {},
        Err(e) if is_disk_full(&e) => {
            tracing::error!("Disk full detected. Cache writes disabled for this session.");
            // self.read_only フラグは AtomicBool で管理不可（Connection が !Send）
            // → CacheManager 内の bool フラグで管理
        },
        Err(e) => {
            tracing::warn!("Cache store failed (non-fatal): {e}");
        }
    }
}

fn is_disk_full(e: &rusqlite::Error) -> bool {
    matches!(e, rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error { code: rusqlite::ffi::ErrorCode::DiskFull, .. }, _
    ))
}
```

### 1l. findings_json バリデーション

```rust
fn validate_findings(findings: &str) -> Result<()> {
    if findings.len() > 1_048_576 {  // 1MB
        return Err(AgentError::Validation("findings_json exceeds 1MB limit".into()));
    }
    serde_json::from_str::<serde_json::Value>(findings)
        .map_err(|_| AgentError::Validation("findings_json is not valid JSON".into()))?;
    Ok(())
}
```

### 1m. file_path 正規化

```rust
fn validate_and_normalize_path(file_path: &str, project_root: &Path) -> Result<String> {
    let normalized = file_path.replace('\\', "/");
    if normalized.contains("..") || normalized.starts_with('/') {
        return Err(AgentError::Validation(format!("Invalid path: {file_path}")));
    }
    if normalized.len() > 4096 {  // #33
        return Err(AgentError::Validation(format!("Path too long: {}", normalized.len())));
    }
    Ok(normalized)
}
```

### 1n. GC の existing_files 取得

**前提:** `shared/src/git.rs` に以下の関数を Phase 0 で追加する:
```rust
/// Git 追跡中の全ファイル一覧を返す（指定ディレクトリ基準）
pub fn git_ls_files_at(root: &Path) -> Result<Vec<String>> {
    let output = Command::new("git")
        .args(["-C", &root.to_string_lossy(), "ls-files", "--cached"])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to run git ls-files: {e}")))?;
    if !output.status.success() {
        return Err(AgentError::Git("git ls-files failed".into()));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| l.to_string())
        .collect())
}
```

```rust
// orchestrate.rs で GC 呼び出し時:
// context update 完了後に git ls-files から取得（context update 前ではない）
fn get_existing_files_for_gc(project_root: &Path) -> Result<Vec<String>> {
    shared::git::git_ls_files_at(project_root)
}
```

**タイミング:** `maintenance()` は context update 完了後に呼ぶ（chicken-and-egg 問題を回避）。

---

## 2. tree-sitter-index クレート基盤

### 2-pre. symbols / symbol_dependencies スキーマ定義

tree-sitter-index が所有する 3 テーブル（cache クレートは所有しない）:

```sql
CREATE TABLE IF NOT EXISTS symbols (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    name TEXT NOT NULL,
    qualified_name TEXT,
    kind TEXT NOT NULL,
    language TEXT NOT NULL,
    start_line INTEGER NOT NULL,
    end_line INTEGER NOT NULL,
    start_col INTEGER NOT NULL DEFAULT 0,
    end_col INTEGER NOT NULL DEFAULT 0,
    signature TEXT,
    visibility TEXT,
    parent_symbol_id INTEGER,
    body_hash TEXT,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (parent_symbol_id) REFERENCES symbols(id)
);

CREATE TABLE IF NOT EXISTS symbol_dependencies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    from_symbol_id INTEGER NOT NULL,
    to_symbol_id INTEGER,
    to_name TEXT NOT NULL,
    kind TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (from_symbol_id) REFERENCES symbols(id),
    UNIQUE(project_id, from_symbol_id, to_name, kind)
);

CREATE TABLE IF NOT EXISTS file_parse_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    grammar_version TEXT NOT NULL DEFAULT '',
    symbol_count INTEGER NOT NULL DEFAULT 0,
    parsed_at TEXT NOT NULL DEFAULT (datetime('now')),
    parse_duration_ms INTEGER,
    PRIMARY KEY (project_id, file_path)
);

CREATE INDEX IF NOT EXISTS idx_symbols_project_file ON symbols(project_id, file_path);
CREATE INDEX IF NOT EXISTS idx_symbols_project_name ON symbols(project_id, name);
CREATE INDEX IF NOT EXISTS idx_symbols_project_kind ON symbols(project_id, kind);
CREATE INDEX IF NOT EXISTS idx_symbols_project_qualified ON symbols(project_id, qualified_name);
CREATE INDEX IF NOT EXISTS idx_deps_from ON symbol_dependencies(from_symbol_id);
CREATE INDEX IF NOT EXISTS idx_deps_to ON symbol_dependencies(to_symbol_id);
CREATE INDEX IF NOT EXISTS idx_deps_to_name ON symbol_dependencies(project_id, to_name);
```

FK 制約は宣言のみ。PRAGMA foreign_keys = ON は設定しない。

### 2a. ImpactReport 拡張

```rust
pub struct ImpactReport {
    pub changed_symbols: Vec<Symbol>,
    pub affected_symbols: Vec<Symbol>,
    pub affected_files: Vec<String>,
    pub depth: u32,
    pub populated: bool,               // symbols テーブルにデータがあるか
    pub parse_failed_files: Vec<String>, // パース失敗したファイル一覧
    pub ambiguous_matches: u32,         // 名前衝突数
    pub truncated: bool,                // max_nodes で打ち切ったか
}
```

capsule 生成時に `populated == false` なら警告を含める。

### 2b. impact_analysis 安全弁

```rust
pub fn impact_analysis(
    conn: &Connection,
    project_id: &str,
    changed_files: &[&str],
    max_depth: u32,     // デフォルト 3
    max_nodes: u32,     // デフォルト 500
) -> Result<ImpactReport>
```

BFS で `visited.len() >= max_nodes` に達したら打ち切り、`truncated = true`。

### 2c. fan-in 検出とフルスコープ強制

```rust
pub fn detect_high_fan_in(conn: &Connection, project_id: &str, threshold: u32) -> Result<Vec<Symbol>> {
    // SELECT s.*, COUNT(d.id) as fan_in FROM symbols s
    // JOIN symbol_dependencies d ON d.to_symbol_id = s.id
    // WHERE s.project_id = ?1 GROUP BY s.id HAVING fan_in > ?2
}

pub fn should_force_full_review(iteration: u32, interval: u32) -> bool {
    interval > 0 && iteration % interval == 0  // デフォルト 5 イテレーションに 1 回
}
```

fan-in > threshold のシンボルが変更された場合: 全ファイルを affected、review_cache 無視。

### 2d. パース失敗閾値（設定可能）

```rust
pub fn index_files(
    conn: &Connection,
    project_id: &str,
    files: &[(PathBuf, String, String)],
    config: &IndexConfig,
) -> Result<IndexResult>

pub struct IndexConfig {
    pub max_file_size: u64,             // デフォルト 102400 (100KB)
    pub parse_failure_threshold: f64,   // デフォルト 0.05 (5%)
    pub exclude_patterns: Vec<String>,  // e.g. ["*.min.js", "dist/**"]
}
```

パース前チェック:
1. ファイルサイズ > max_file_size → スキップ
2. 先頭 8KB に NUL バイト → スキップ（バイナリ検出）
3. パース失敗率 > threshold → `Err(AgentError::Validation("BLOCK"))` を返す

### 2e. file_parse_cache に grammar_version 追加

```rust
const GRAMMAR_VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"), ":",
    // 各言語のバージョンは Cargo.lock から取得するのが理想だが、
    // 実用上はこのクレートのバージョンで十分
);
```

```sql
CREATE TABLE IF NOT EXISTS file_parse_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    grammar_version TEXT NOT NULL DEFAULT '',
    symbol_count INTEGER NOT NULL DEFAULT 0,
    parsed_at TEXT NOT NULL DEFAULT (datetime('now')),
    parse_duration_ms INTEGER,
    PRIMARY KEY (project_id, file_path)
);
```

HIT 判定: `WHERE file_hash = ? AND grammar_version = ?`

### 2f. remove_file_symbols（to_symbol_id 側も削除）

```rust
pub fn remove_file_symbols(conn: &Connection, project_id: &str, file_path: &str) -> Result<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // 1. to_symbol_id 側の依存エッジも削除 (#7 修正)
    tx.execute(
        "DELETE FROM symbol_dependencies WHERE to_symbol_id IN \
         (SELECT id FROM symbols WHERE project_id=?1 AND file_path=?2)",
        params![project_id, file_path],
    )?;
    // 2. from_symbol_id 側の依存エッジ削除
    tx.execute(
        "DELETE FROM symbol_dependencies WHERE from_symbol_id IN \
         (SELECT id FROM symbols WHERE project_id=?1 AND file_path=?2)",
        params![project_id, file_path],
    )?;
    // 3. シンボル削除
    tx.execute("DELETE FROM symbols WHERE project_id=?1 AND file_path=?2", params![project_id, file_path])?;
    // 4. パースキャッシュ削除
    tx.execute("DELETE FROM file_parse_cache WHERE project_id=?1 AND file_path=?2", params![project_id, file_path])?;
    tx.commit()?;
    Ok(())
}
```

### 2g. トランザクション戦略（テーブル別）

| テーブル | 戦略 | 理由 |
|---------|------|------|
| symbols, symbol_dependencies | DELETE-then-INSERT in IMMEDIATE tx | シンボル数が減る場合がある。INSERT OR REPLACE では古いシンボルが残る |
| file_parse_cache | INSERT OR REPLACE | 1行/ファイル、常に上書き |
| verify_cache, review_cache | INSERT OR REPLACE | 1行/ファイル+ツール、常に上書き |
| capsule_cache | INSERT OR REPLACE | 1行/context_hash、常に上書き |
| file_index | INSERT OR REPLACE | 1行/ファイル、常に上書き |

### 2h. post-index シンボル解決パス (#35)

```rust
/// 全ファイルインデックス完了後に to_symbol_id を解決
pub fn resolve_pending_dependencies(conn: &Connection, project_id: &str) -> Result<u32> {
    let resolved = conn.execute(
        "UPDATE symbol_dependencies SET to_symbol_id = (
            SELECT s.id FROM symbols s
            WHERE s.project_id = symbol_dependencies.project_id
              AND s.name = symbol_dependencies.to_name
            LIMIT 1
         )
         WHERE project_id = ?1 AND to_symbol_id IS NULL",
        params![project_id],
    )?;
    Ok(resolved as u32)
}
```

### 2i. ERROR ノード除外

エクストラクタのクエリ結果から `ERROR` ノードの子孫を除外:
```rust
fn is_error_descendant(node: tree_sitter::Node) -> bool {
    let mut current = node;
    while let Some(parent) = current.parent() {
        if parent.is_error() { return true; }
        current = parent;
    }
    false
}
```

### 2j. マイグレーション統合

**3つのマイグレーションシステムの統合:**
- semantic-mcp: `run_migrations()` → 既存 7 テーブル
- cache: `ensure_schema()` → cache 4 テーブル + `_cache_meta`
- tree-sitter-index: `run_tree_sitter_migrations()` → 3 テーブル

**方針:** 各クレートが自分のテーブルを所有。`_cache_meta` と `_ts_meta` で独立バージョン管理。`user_version` は semantic-mcp 専用。衝突なし。

---

## 3. agent-core 統合（全体整合性保証付き）

### 3a. verify.rs 統合

```rust
// shadow_verify_run 内:
let config_hash = compute_config_hash(tool, project_root);
let tool_version = get_tool_version(tool);

if let Some(cached) = cache.check_verify(&file, &file_hash, tool, &config_hash, &tool_version) {
    // HIT: キャッシュ結果を使用
} else {
    // MISS: ツール実行
    let result = run_tool(tool, &file)?;
    cache.store_verify(&file, &file_hash, tool, &config_hash, &tool_version, &result.status, &result.findings)?;
    // verify miss → 同一ファイルの review も無効化（ファイル内容変更時のみ）
    if file_hash_changed {
        cache.invalidate_review_on_verify_miss(&file)?;
    }
}
```

### 3b. review.rs 統合（フルスコープ強制付き）

```rust
let head_commit = shared::git::git_current_head()?;
let prompt_hash = compute_prompt_hash(reviewer, &prompts_dir);

// フルスコープ強制チェック
let force_full = should_force_full_review(iteration, 5);
let has_high_fan_in = /* fan-in > threshold のシンボルが変更された */;

if !force_full && !has_high_fan_in {
    if let Some(cached) = cache.check_review(&file, &file_hash, reviewer, &prompt_hash, &head_commit) {
        // HIT
    }
}
// MISS or FORCED: 通常レビュー実行
```

### 3c. orchestrate.rs 統合

```rust
// context update 完了後に maintenance
let existing_files = get_existing_files_for_gc(&project_root)?;
let maint = cache.maintenance(7, &existing_files)?;
tracing::info!("Maintenance: evicted={}, gc={}, vacuumed={}", maint.evicted, maint.gc.deleted_rows, maint.vacuumed);
```

### 3d. lock ファイルの扱い (#E-5)

```rust
// context.rs の should_index_file:
// *.lock は indexing 不要だが changed_files には含める
fn should_index_file(path: &Path) -> bool { ... }  // *.lock → false

// collect_changed_files は should_index_file を使わず、全変更ファイルを返す
// indexing 対象のフィルタリングは index_files 呼び出し時に行う
```

---

## 4. feature flag（バイナリサイズ制御）

```toml
# crates/tree-sitter-index/Cargo.toml
[features]
default = ["lang-rust", "lang-typescript", "lang-python"]
lang-rust = ["dep:tree-sitter-rust"]
lang-typescript = ["dep:tree-sitter-typescript", "dep:tree-sitter-javascript"]
lang-python = ["dep:tree-sitter-python"]
lang-go = ["dep:tree-sitter-go"]
lang-shell = ["dep:tree-sitter-bash"]
all-languages = ["lang-rust", "lang-typescript", "lang-python", "lang-go", "lang-shell"]
```

---

## 4b. 未定義型・関数の補完

### invalidate_review_on_verify_miss SQL:
```rust
fn invalidate_review_on_verify_miss(&self, file: &str) -> Result<()> {
    self.conn.execute(
        "DELETE FROM review_cache WHERE project_id = ?1 AND file_path = ?2",
        params![self.project_id, file],
    ).map_err(|e| AgentError::Database(e.to_string()))?;
    Ok(())
}
```

### _ts_meta テーブル (tree-sitter-index バージョン管理):
```rust
const TS_SCHEMA_VERSION: i32 = 1;

fn check_ts_schema_version(conn: &Connection) -> Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS _ts_meta (key TEXT PRIMARY KEY, value TEXT)",
        [],
    ).map_err(|e| AgentError::Database(e.to_string()))?;
    let current: i32 = conn.query_row(
        "SELECT COALESCE((SELECT value FROM _ts_meta WHERE key='schema_version'), '0')",
        [], |r| r.get::<_, String>(0),
    ).map(|s| s.parse().unwrap_or(0)).unwrap_or(0);
    if current < TS_SCHEMA_VERSION {
        run_ts_migrations(conn)?;
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta (key, value) VALUES ('schema_version', ?1)",
            params![TS_SCHEMA_VERSION.to_string()],
        ).map_err(|e| AgentError::Database(e.to_string()))?;
    }
    Ok(())
}
```

### maintenance() 実装:
```rust
pub fn maintenance(&self, max_age_days: u32, existing_files: &[String]) -> Result<MaintenanceResult> {
    let evicted = self.evict_stale(max_age_days)?;
    let gc = self.gc_deleted_files(existing_files)?;
    self.enforce_capsule_lru(500)?;
    self.wal_checkpoint()?;
    let vacuumed = self.vacuum_if_needed()?;
    Ok(MaintenanceResult { evicted, gc_deleted: gc.deleted_rows, vacuumed })
}
```

### 型定義（返り値/パラメータ型）:
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

#[derive(Debug, Clone)]
pub struct MaintenanceResult {
    pub evicted: u64,
    pub gc_deleted: u64,
    pub vacuumed: bool,
}

#[derive(Debug, Clone)]
pub struct GcResult {
    pub deleted_rows: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditResult {
    pub samples_checked: u32,
    pub mismatches: u32,
    pub mismatch_rate: f64,
    pub invalidated_tools: Vec<String>,
}
```

### busy_timeout 統一:
semantic-mcp の `db.rs` も busy_timeout を 30000ms に更新する（Phase 6 で実施）。

---

## 5. 検証方法（具体的受け入れ基準）

1. `cargo check --workspace` — エラー 0
2. `cargo test --workspace` — 500+ テスト全通過
3. `cargo clippy --workspace -- -D warnings` — warning 0
4. **キャッシュ正確性:**
   - eslintrc 変更後 → verify_cache ミス確認
   - レビュワープロンプト変更後 → review_cache ミス確認
   - HEAD 変更後 → review_cache ミス確認
   - ファイル削除後 → GC でエントリ消去確認
5. **蓄積安定性:**
   - 1000回 store + evict 後、`page_count * page_size < 2 * active_data_size`
   - capsule LRU が 500 エントリで安定
6. **パース失敗:**
   - 不正ファイル → ImpactReport.populated=false, parse_failed_files に含まれる
   - 失敗率 > 5% → BLOCK
7. **フルスコープ:**
   - iteration % 5 == 0 でキャッシュ無視確認
   - fan-in > 10 のシンボル変更で全ファイル affected 確認
8. **DB 安全性:**
   - quick_check 失敗 → cache テーブルのみ DROP（semantic-mcp コア残存確認）
   - disk full → graceful degradation（パイプライン継続確認）
