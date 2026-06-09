# ExecPlan: tree-sitter ネイティブ統合

**ステータス:** 設計完了・実装待ち
**目的:** ファイル単位の解析 → シンボル単位の解析へアップグレード
**影響:** context, capsule, preflight, review, semantic-mcp 全レイヤー

---

## 1. アーキテクチャ決定

### 新クレート `tree-sitter-index`

`shared` や `agent-core` に混ぜず、独立クレートとする。

**理由:**
- `shared` は軽量基盤（SQLite 依存なし）。tree-sitter の C バイナリ（~15MB）を入れると責務が崩れる
- `agent-core` は CLI 層。パーサーインフラと CLI ディスパッチの混在は結合度が高すぎる
- 独立クレートなら agent-core と semantic-mcp の両方から依存できる

**依存グラフ:**
```
shared (基盤: 型, エラー, ログ, ロック, git)
  ^
  |
tree-sitter-index (パース + シンボル DB)
  ^            ^
  |            |
agent-core   semantic-mcp
```

### クレート構造

```
crates/tree-sitter-index/
  Cargo.toml
  src/
    lib.rs              # public API, re-export
    parser.rs           # 言語ルーター, tree-sitter 初期化
    types.rs            # Symbol, Dependency, ImpactReport 型定義
    db.rs               # symbols/dependencies テーブル, CRUD
    incremental.rs      # ハッシュベース変更検知, バッチオーケストレーション
    extractors/
      mod.rs            # SymbolExtractor トレイト + ディスパッチ
      rust.rs           # Rust クエリパターン
      typescript.rs     # TypeScript/JavaScript クエリパターン
      python.rs         # Python クエリパターン
      go.rs             # Go クエリパターン
      shell.rs          # Shell/Bash クエリパターン
```

**推定 LOC:** 1,800〜2,200

---

## 2. 依存クレート

```toml
[workspace.dependencies]
tree-sitter = "0.24"
tree-sitter-rust = "0.23"
tree-sitter-typescript = "0.23"
tree-sitter-javascript = "0.23"
tree-sitter-python = "0.23"
tree-sitter-go = "0.23"
tree-sitter-bash = "0.23"
```

---

## 3. DB スキーマ

既存の `semantic.db` に 3 テーブル追加（マイグレーションは冪等）。

FOREIGN KEY 制約は宣言のみ（SQLite デフォルトでは未強制）。参照整合性はアプリケーションロジック（delete-then-insert トランザクション）で保証する。PRAGMA foreign_keys = ON は設定しない。

**upsert 戦略: Delete-then-Insert (トランザクション内)**

ファイルの再インデックス時:
1. BEGIN TRANSACTION
2. DELETE FROM symbol_dependencies WHERE from_symbol_id IN (SELECT id FROM symbols WHERE project_id = ? AND file_path = ?)
3. DELETE FROM symbols WHERE project_id = ? AND file_path = ?
4. INSERT INTO symbols (...) VALUES (...)  -- 新シンボル群
5. INSERT INTO symbol_dependencies (...) VALUES (...)  -- 新依存群
6. COMMIT

UNIQUE 制約は不要（symbols テーブル側）。トランザクション内の delete-insert で一貫性を保証。
Foreign key の self-reference (parent_symbol_id) は同一トランザクション内で解決。

```sql
-- シンボルテーブル: 1行 = 1シンボル
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

-- 依存グラフ: シンボル間のエッジ
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

-- パースキャッシュ: ファイル単位のパース状態追跡
CREATE TABLE IF NOT EXISTS file_parse_cache (
    project_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    symbol_count INTEGER NOT NULL DEFAULT 0,
    parsed_at TEXT NOT NULL DEFAULT (datetime('now')),
    parse_duration_ms INTEGER,
    PRIMARY KEY (project_id, file_path)
);

-- インデックス
CREATE INDEX IF NOT EXISTS idx_symbols_project_file ON symbols(project_id, file_path);
CREATE INDEX IF NOT EXISTS idx_symbols_project_name ON symbols(project_id, name);
CREATE INDEX IF NOT EXISTS idx_symbols_project_kind ON symbols(project_id, kind);
CREATE INDEX IF NOT EXISTS idx_symbols_project_qualified ON symbols(project_id, qualified_name);
CREATE INDEX IF NOT EXISTS idx_deps_from ON symbol_dependencies(from_symbol_id);
CREATE INDEX IF NOT EXISTS idx_deps_to ON symbol_dependencies(to_symbol_id);
CREATE INDEX IF NOT EXISTS idx_deps_to_name ON symbol_dependencies(project_id, to_name);
```

---

## 4. 型定義 (`types.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Symbol {
    pub id: Option<i64>,
    pub file_path: String,
    pub file_hash: String,
    pub name: String,
    pub qualified_name: Option<String>,
    pub kind: SymbolKind,
    pub language: String,
    pub start_line: u32,
    pub end_line: u32,
    pub start_col: u32,
    pub end_col: u32,
    pub signature: Option<String>,
    pub visibility: Option<String>,
    pub parent_symbol_id: Option<i64>,
    pub body_hash: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    Function, Class, Struct, Enum, Method, Import, Export,
    Type, Interface, Const, Mod, Trait, Impl,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolDependency {
    pub from_symbol_id: i64,
    pub to_symbol_id: Option<i64>,
    pub to_name: String,
    pub kind: DependencyKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyKind {
    Calls, Imports, Extends, Implements, UsesType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImpactReport {
    pub changed_symbols: Vec<Symbol>,
    pub affected_symbols: Vec<Symbol>,
    pub affected_files: Vec<String>,
    pub depth: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexResult {
    pub files_parsed: usize,
    pub files_skipped: usize,
    pub symbols_extracted: usize,
    pub dependencies_extracted: usize,
    pub total_duration_ms: u64,
}
```

---

## 5. 言語ルーター (`parser.rs`)

```rust
pub fn get_language(lang: &str) -> Option<tree_sitter::Language> {
    match lang {
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),
        "typescript" | "tsx" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "javascript" | "jsx" => Some(tree_sitter_javascript::LANGUAGE.into()),
        "python" => Some(tree_sitter_python::LANGUAGE.into()),
        "go" => Some(tree_sitter_go::LANGUAGE.into()),
        "shell" | "bash" => Some(tree_sitter_bash::LANGUAGE.into()),
        _ => None,
    }
}

pub fn parse_source(source: &str, language: &str) -> Result<tree_sitter::Tree, AgentError> {
    let lang = get_language(language)
        .ok_or_else(|| AgentError::Database(format!("Unsupported language: {language}")))?;
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&lang)
        .map_err(|e| AgentError::Database(format!("Failed to set language: {e}")))?;
    parser.parse(source, None)
        .ok_or_else(|| AgentError::Database(format!("Failed to parse source for language: {language}")))
}
```

---

## 6. シンボル抽出器 (`extractors/`)

### トレイト定義

SymbolExtractor は RawSymbol（file_path/file_hash なし）を返す。呼び出し元が file_path と file_hash をセットしてから DB に upsert する。

```rust
/// file_path, file_hash を持たない中間表現。
/// 呼び出し元 (incremental.rs) が file_path と file_hash を付与して Symbol に変換する。
#[derive(Debug, Clone)]
pub struct RawSymbol {
    pub name: String,
    pub qualified_name: Option<String>,
    pub kind: SymbolKind,
    pub language: String,
    pub start_line: u32,
    pub end_line: u32,
    pub start_col: u32,
    pub end_col: u32,
    pub signature: Option<String>,
    pub visibility: Option<String>,
    pub body_hash: Option<String>,
    pub children: Vec<RawSymbol>,  // ネスト構造（parent_symbol_id 解決前）
}

pub trait SymbolExtractor {
    fn extract_symbols(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawSymbol>;
    fn extract_dependencies(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<SymbolDependency>;
}
```

### 言語別クエリパターン

**Rust** (~200 LOC):
- `(function_item name: (identifier) @name)` → Function
- `(struct_item name: (type_identifier) @name)` → Struct
- `(enum_item name: (type_identifier) @name)` → Enum
- `(impl_item type: (type_identifier) @name)` → Impl
- `(trait_item name: (type_identifier) @name)` → Trait
- `(use_declaration) @import` → Import
- `(mod_item name: (identifier) @name)` → Mod
- `(const_item name: (identifier) @name)` → Const
- visibility: `(visibility_modifier)` ノードの有無で判定

**TypeScript/JavaScript** (~200 LOC):
- `(function_declaration name: (identifier) @name)` → Function
- `(class_declaration name: (identifier) @name)` → Class
- `(method_definition name: (property_identifier) @name)` → Method
- `(export_statement)` → Export
- `(import_statement)` → Import
- `(interface_declaration name: (identifier) @name)` → Interface (TS)
- `(type_alias_declaration name: (identifier) @name)` → Type (TS)

**Python** (~150 LOC):
- `(function_definition name: (identifier) @name)` → Function
- `(class_definition name: (identifier) @name)` → Class
- `(import_statement)` / `(import_from_statement)` → Import

**Go** (~150 LOC):
- `(function_declaration name: (identifier) @name)` → Function
- `(method_declaration name: (field_identifier) @name)` → Method
- `(type_declaration (type_spec name: (type_identifier) @name))` → Type
- `(import_declaration)` → Import

**Shell** (~80 LOC):
- `(function_definition name: (word) @name)` → Function

---

## 7. インクリメンタルエンジン (`incremental.rs`)

```rust
/// ファイル群をインデックス（変更分のみパース）
pub fn index_files(
    conn: &Connection,
    project_id: &str,
    files: &[(PathBuf, String, String)],  // (path, language, hash)
) -> shared::error::Result<IndexResult> {
    // 1. file_parse_cache をチェック — hash 一致ならスキップ
    // 2. ファイル読み取り
    // 3. parse_source() → tree
    // 4. extract_symbols() + extract_dependencies()
    // 5. トランザクション内で DB に delete-then-insert (upsert 戦略参照)
    // 6. パースキャッシュ更新
}

/// 影響分析: 変更ファイルのシンボルから依存元を BFS で辿る
pub fn impact_analysis(
    conn: &Connection,
    project_id: &str,
    changed_files: &[&str],
    max_depth: u32,  // デフォルト 3
) -> shared::error::Result<ImpactReport> {
    // 1. 変更ファイルの全シンボルを取得
    // 2. dependents_of() を BFS で max_depth まで走査
    // 3. 重複排除、影響ファイル収集
    // 4. ImpactReport を返却
}

/// ファイル削除時にシンボルと依存を除去
pub fn remove_file_symbols(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> shared::error::Result<()> {
    // 1. BEGIN TRANSACTION
    // 2. DELETE FROM symbol_dependencies WHERE from_symbol_id IN
    //    (SELECT id FROM symbols WHERE project_id = ? AND file_path = ?)
    // 3. DELETE FROM symbols WHERE project_id = ? AND file_path = ?
    // 4. DELETE FROM file_parse_cache WHERE project_id = ? AND file_path = ?
    // 5. COMMIT
    // git diff で削除されたファイルを検知した際に index_files() の前段で呼び出す
}
```

---

## 8. agent-core 統合ポイント

### 8a. context.rs — 新サブコマンド `IndexSymbols`

agent-core は rusqlite に直接依存しない。tree-sitter-index が高レベル API を提供:

```rust
// tree-sitter-index の公開 API
pub fn index_files_at_path(
    db_path: &str,
    project_id: &str,
    files: &[(PathBuf, String, String)],
) -> Result<IndexResult> {
    let conn = open_connection(db_path)?;
    run_tree_sitter_migrations(&conn)?;
    index_files(&conn, project_id, files)
}

pub fn impact_analysis_at_path(
    db_path: &str,
    project_id: &str,
    changed_files: &[&str],
    max_depth: u32,
) -> Result<ImpactReport> {
    let conn = open_connection(db_path)?;
    impact_analysis(&conn, project_id, changed_files, max_depth)
}
```

agent-core は `tree-sitter-index` クレートに依存し、パスベース API を呼ぶのみ。

```rust
IndexSymbols {
    #[arg(long)] snapshot: String,
    #[arg(long)] db_path: String,
    #[arg(long)] project_id: String,
}
```

スナップショットからファイル一覧を読み、tree-sitter でインデックス。
既存の `Update` パスは変更なし（高速性を維持）。

### 8b. capsule.rs — `build_capsule_with_symbols()`

```rust
pub fn build_capsule_with_symbols(
    plan_path: &Path,
    changed_files: &[String],
    db: &Connection,
    project_id: &str,
    budget: u32,
) -> Result<Capsule> {
    // 1. 変更ファイルのシンボルを DB から取得
    // 2. impact_analysis で影響シンボルを特定
    // 3. シンボル signature を scope_summary に使用（ファイル名ではなく）
    // 4. セキュリティ pin: シンボル名で判定
}
```

**効果:** プロンプトに「ファイル名一覧」ではなく「関数シグネチャ一覧」を注入。LLM の理解精度が段違い。

### 8c. semantic-mcp — 新ツール `sem.registry.symbols`

コンポーネントの `file_path` から symbols テーブルを JOIN し、登録済みコンポーネントに紐づくシンボル一覧を返す。

---

## 9. パフォーマンス特性

| 指標 | 値 |
|------|-----|
| パース速度 | ~1-5ms/ファイル (100-1000行) |
| 1000ファイルリポジトリ初回インデックス | ~2-5秒 |
| 1ファイル変更後の再インデックス | ~5ms |
| バッチ INSERT (1000シンボル) | ~10ms (WAL + トランザクション) |
| 影響分析 BFS (深度3) | ~1-5ms |
| バイナリサイズ増加 | ~8-15MB (6言語の C グラマー) |
| 初回ビルド時間増加 | ~30-60秒 (C コードコンパイル、以降はキャッシュ) |

---

## 10. フェーズ計画

### Phase 1: 基盤 (1-2日)
- `crates/tree-sitter-index/` 作成
- `types.rs`, `parser.rs`, `db.rs` 実装
- `extractors/rust.rs` 実装（Rust から始める）
- ユニットテスト

### Phase 2: 言語エクストラクタ (1-2日)
- TypeScript, Python, Go, Shell エクストラクタ実装
- 各言語のテストスイート

### Phase 3: インクリメンタルエンジン (1日)
- `incremental.rs` 実装
- `impact_analysis()` BFS 実装
- 統合テスト: agent_base 自体をインデックス

### Phase 4: agent-core 統合 (1-2日)
- context.rs `IndexSymbols` サブコマンド
- capsule.rs `build_capsule_with_symbols()`
- semantic-mcp DB マイグレーション追加
- E2E テスト

### Phase 5: ポリッシュ (0.5-1日)
- パース失敗時の graceful fallback
- `--no-symbols` フラグ（後方互換）
- ドキュメント、パフォーマンスログ

---

## 11. エラー型

全ての public 関数は `shared::error::Result<T>` を返す。
`shared::error::AgentError` に `Database(String)` バリアントを追加（前提条件）。

```rust
// shared/src/error.rs に追加
#[error("Database error: {0}")]
Database(String),
```

tree-sitter-index 内で `rusqlite::Error` → `AgentError::Database` に変換:
```rust
impl From<rusqlite::Error> for AgentError {
    fn from(e: rusqlite::Error) -> Self {
        AgentError::Database(e.to_string())
    }
}
```

---

## 12. 実装順序と依存関係

```
PLAN_TREE_SITTER                    PLAN_SQLITE_CACHE
================                    =================
Phase 1: 基盤                       Phase 1: 基盤 (cache クレート)
  types.rs, parser.rs, db.rs          CacheManager + 4テーブル
  extractors/rust.rs                  ※ symbols テーブルは定義しない
         |                                     |
Phase 2: 言語エクストラクタ          Phase 2-6: 統合 (verify/context/review/capsule/CLI)
         |                                     |
Phase 3: インクリメンタル                       |
         |                                     |
Phase 4: agent-core 統合 ←──────── Phase 7: Symbol Cache (tree-sitter 連携)
         |                                     |
Phase 5: ポリッシュ                 Phase 8: DB 統合
```

**依存方向:**
- PLAN_SQLITE_CACHE Phase 7 は PLAN_TREE_SITTER Phase 3 完了を前提とする
- PLAN_SQLITE_CACHE Phase 1-6 は PLAN_TREE_SITTER と独立して実装可能
- 両プランとも `shared::error::AgentError::Database` バリアント追加が前提条件

---

## 13. リスクと対策

| リスク | 対策 |
|--------|------|
| tree-sitter バージョン非互換 | workspace で pin、CI で全6言語テスト |
| クロスファイル依存解決が困難 | Phase 1 は名前ベースマッチング。完全解決は将来フェーズ |
| 大規模リポジトリの初回インデックス | インクリメンタルキャッシュで 2回目以降は高速。`--changed-only` フラグ |
| TSX/JSX パースのエッジケース | tree-sitter-typescript は TSX 用の別 Language を提供。拡張子でルーティング |
| バイナリサイズ肥大 | CLI ツールとしては許容範囲。必要なら feature flag で言語選択 |
