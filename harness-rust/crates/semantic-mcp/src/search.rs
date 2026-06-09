//! Bounded advisory `sem.search` implementation.
//!
//! This is intentionally stateless: no persistent index, watcher, cache, or
//! background process is introduced.

use serde::Serialize;
use serde_json::Value;
use shared::ranker::{compute_rank_score, recency_score, RankingWeights};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::context::ServerContext;

const MAX_LIMIT: usize = 10;
const DEFAULT_LIMIT: usize = 8;
const MAX_CAPSULE_BUDGET_TOKENS: usize = 200;
const DEFAULT_CAPSULE_BUDGET_TOKENS: usize = 120;
const MAX_EXCERPT_CHARS: usize = 80;
const MAX_SCOPE_PATHS: usize = 40;
const MAX_FILES_PER_SEARCH: usize = 40;
const MAX_SEARCH_FILE_BYTES: u64 = 256 * 1024;

#[derive(Debug, Clone, Serialize)]
pub struct SearchItem {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub semantic_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub excerpt: Option<String>,
    pub source: String,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<SearchItem>,
    pub total: usize,
    pub truncated: bool,
    pub capsule: String,
    pub advisory_only: bool,
}

struct SearchInput {
    query: String,
    scope_paths: Vec<String>,
    mode: SearchMode,
    limit: usize,
    capsule_budget_tokens: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SearchMode {
    Fts5,
    LegacyLike,
}

struct RegistryRow {
    semantic_id: String,
    file_path: String,
    name: String,
    kind: String,
}

struct FtsRow {
    semantic_id: String,
    file_path: String,
    name: String,
    kind: String,
    updated_at_unix_ms: u64,
    bm25_rank: f64,
}

const MAX_SYMBOL_SIGNATURE_CHARS: usize = 120;

struct SymbolsRow {
    name: String,
    qualified_name: Option<String>,
    kind: String,
    file_path: String,
    start_line: i64,
    signature: Option<String>,
}

pub fn handle_search(ctx: &ServerContext, args: &Value) -> Result<Value, String> {
    let input = normalize_search_input(ctx, args)?;
    let response = match input.mode {
        SearchMode::Fts5 => {
            validate_scope_paths(ctx, &input.scope_paths)?;
            let fts_items = query_fts5_items(ctx, &input)?;
            // Union the tree-sitter symbols table (source:"symbols") so the
            // default sem.search surfaces indexed symbols, not only the curated
            // registry. components/FTS hits keep their existing ordering and
            // are merged ahead of symbols hits via the unified comparator.
            let symbol_items = query_symbols_items(ctx, &input)?;
            let mut merged = merge_union_items(fts_items, symbol_items, &input.query);
            let total = merged.len();
            let truncated = total > input.limit;
            merged.truncate(input.limit);
            compact_response(merged, total, truncated, input.capsule_budget_tokens)
        }
        SearchMode::LegacyLike => {
            let files = resolve_scope_files(ctx, &input.scope_paths)?;
            let registry_items = query_registry_items(ctx, &input)?;
            let filesystem_items = search_files(ctx, &files, &input.query)?;
            let symbol_items = query_symbols_items(ctx, &input)?;
            let registry_fs = merge_search_items(registry_items, filesystem_items);
            let mut merged = merge_union_items(registry_fs, symbol_items, &input.query);
            let total = merged.len();
            let truncated = total > input.limit;
            let limited = merged.drain(..total.min(input.limit)).collect::<Vec<_>>();
            compact_response(limited, total, truncated, input.capsule_budget_tokens)
        }
    };
    serde_json::to_value(response).map_err(|e| format!("sem.search failed: {e}"))
}

fn normalize_search_input(ctx: &ServerContext, args: &Value) -> Result<SearchInput, String> {
    let obj = args
        .as_object()
        .ok_or_else(|| "sem.search failed: search input must be an object".to_string())?;

    if let Some(project_id) = get_optional_string(obj, "project_id")? {
        if project_id != ctx.project_id {
            return Err(format!(
                "sem.search failed: project_id mismatch: expected {}, received {}",
                ctx.project_id, project_id
            ));
        }
    }

    let query = get_required_string(obj, "query")?;
    let scope_paths = get_scope_paths(obj)?;
    let mode = parse_search_mode(get_optional_string(obj, "kind")?)?;
    let limit = clamp_usize(
        parse_usize(obj.get("limit"), "limit")?.unwrap_or(DEFAULT_LIMIT),
        1,
        MAX_LIMIT,
    );
    let budget_value = get_consistent_alias(
        obj,
        &["capsule_budget_tokens", "capsuleBudgetTokens"],
        "capsule_budget_tokens/capsuleBudgetTokens",
    )?;
    let capsule_budget_tokens = clamp_usize(
        parse_usize(budget_value, "capsule_budget_tokens")?
            .unwrap_or(DEFAULT_CAPSULE_BUDGET_TOKENS),
        1,
        MAX_CAPSULE_BUDGET_TOKENS,
    );

    Ok(SearchInput {
        query,
        scope_paths,
        mode,
        limit,
        capsule_budget_tokens,
    })
}

fn parse_search_mode(kind: Option<String>) -> Result<SearchMode, String> {
    match kind.as_deref().unwrap_or("fts5") {
        "fts5" => Ok(SearchMode::Fts5),
        "legacy-like" => Ok(SearchMode::LegacyLike),
        other => Err(format!(
            "sem.search failed: kind must be one of: fts5, legacy-like; received {other}"
        )),
    }
}

fn get_scope_paths(obj: &serde_json::Map<String, Value>) -> Result<Vec<String>, String> {
    let value = get_consistent_alias(
        obj,
        &["scope_paths", "scopePaths"],
        "scope_paths/scopePaths",
    )?
    .ok_or_else(|| {
        "sem.search failed: scope_paths (or legacy scopePaths) must be a non-empty array"
            .to_string()
    })?;
    let arr = value.as_array().ok_or_else(|| {
        "sem.search failed: scope_paths (or legacy scopePaths) must be a non-empty array"
            .to_string()
    })?;
    if arr.is_empty() {
        return Err(
            "sem.search failed: scope_paths (or legacy scopePaths) must be a non-empty array"
                .to_string(),
        );
    }
    if arr.len() > MAX_SCOPE_PATHS {
        return Err(format!(
            "sem.search failed: scope_paths must contain at most {MAX_SCOPE_PATHS} entries"
        ));
    }

    let mut paths = Vec::with_capacity(arr.len());
    for (idx, entry) in arr.iter().enumerate() {
        let Some(raw) = entry.as_str() else {
            return Err(format!(
                "sem.search failed: scope_paths[{idx}] must be a non-blank string"
            ));
        };
        let normalized = raw
            .trim()
            .replace('\\', "/")
            .trim_start_matches("./")
            .trim_end_matches('/')
            .to_string();
        if normalized.is_empty() || normalized == "." || normalized == "*" || normalized == "**" {
            return Err(
                "sem.search failed: scope_paths must not request broad default scans".to_string(),
            );
        }
        if normalized.starts_with('/') || normalized.contains("..") {
            return Err("sem.search failed: scope_paths must be repo-relative and must not traverse outside repo root".to_string());
        }
        paths.push(normalized);
    }
    Ok(paths)
}

fn resolve_scope_files(
    ctx: &ServerContext,
    scope_paths: &[String],
) -> Result<Vec<PathBuf>, String> {
    let repo_root = fs::canonicalize(&ctx.repo_root)
        .map_err(|e| format!("sem.search failed: repo root canonicalization failed: {e}"))?;
    let mut files = Vec::new();

    for scope_path in scope_paths {
        let absolute = repo_root.join(scope_path);
        let metadata = fs::symlink_metadata(&absolute)
            .map_err(|e| format!("sem.search failed: scope path unreadable: {e}"))?;
        if metadata.file_type().is_symlink() {
            return Err("sem.search failed: scope_paths must not include symlinks".to_string());
        }
        let real = fs::canonicalize(&absolute)
            .map_err(|e| format!("sem.search failed: scope path canonicalization failed: {e}"))?;
        assert_inside_repo(&repo_root, &real)?;
        if metadata.is_dir() {
            collect_directory_files(&repo_root, &real, &mut files)?;
        } else if metadata.is_file() {
            files.push(real);
        }
    }

    files.sort();
    files.dedup();
    files.truncate(MAX_FILES_PER_SEARCH);
    if files.is_empty() {
        return Err(
            "sem.search failed: scope_paths did not resolve to searchable files".to_string(),
        );
    }
    Ok(files)
}

fn validate_scope_paths(ctx: &ServerContext, scope_paths: &[String]) -> Result<(), String> {
    let repo_root = fs::canonicalize(&ctx.repo_root)
        .map_err(|e| format!("sem.search failed: repo root canonicalization failed: {e}"))?;
    for scope_path in scope_paths {
        let absolute = repo_root.join(scope_path);
        let metadata = fs::symlink_metadata(&absolute)
            .map_err(|e| format!("sem.search failed: scope path unreadable: {e}"))?;
        if metadata.file_type().is_symlink() {
            return Err("sem.search failed: scope_paths must not include symlinks".to_string());
        }
        let real = fs::canonicalize(&absolute)
            .map_err(|e| format!("sem.search failed: scope path canonicalization failed: {e}"))?;
        assert_inside_repo(&repo_root, &real)?;
    }
    Ok(())
}

fn collect_directory_files(
    repo_root: &Path,
    dir: &Path,
    files: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let mut entries = fs::read_dir(dir)
        .map_err(|e| format!("sem.search failed: directory read failed: {e}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("sem.search failed: directory entry read failed: {e}"))?;
    entries.sort_by_key(|entry| entry.file_name());

    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();
        if [".git", "node_modules", "target", "dist", ".claude"].contains(&name.as_str()) {
            continue;
        }
        if entry
            .file_type()
            .map_err(|e| format!("sem.search failed: file type read failed: {e}"))?
            .is_symlink()
        {
            return Err("sem.search failed: scope_paths must not include symlinks".to_string());
        }
        let metadata = entry
            .metadata()
            .map_err(|e| format!("sem.search failed: metadata read failed: {e}"))?;
        let real = fs::canonicalize(entry.path())
            .map_err(|e| format!("sem.search failed: scope path canonicalization failed: {e}"))?;
        assert_inside_repo(repo_root, &real)?;
        if metadata.is_dir() {
            collect_directory_files(repo_root, &real, files)?;
        } else if metadata.is_file() {
            files.push(real);
        }
    }
    Ok(())
}

fn query_registry_items(
    ctx: &ServerContext,
    input: &SearchInput,
) -> Result<Vec<SearchItem>, String> {
    let like = format!(
        "%{}%",
        input
            .query
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    );
    let mut sql = String::from(
        "SELECT semantic_id, file_path, name, kind FROM components WHERE project_id = ?1 AND status != 'deleted' AND (name LIKE ?2 ESCAPE '\\' OR semantic_id LIKE ?2 ESCAPE '\\' OR file_path LIKE ?2 ESCAPE '\\') AND (",
    );
    let mut params: Vec<String> = vec![ctx.project_id.clone(), like];
    let mut parts = Vec::new();
    for scope_path in &input.scope_paths {
        let idx = params.len() + 1;
        let idx2 = params.len() + 2;
        parts.push(format!(
            "(file_path = ?{idx} OR file_path LIKE ?{idx2} ESCAPE '\\')"
        ));
        params.push(scope_path.clone());
        params.push(format!(
            "{}/%",
            escape_like(scope_path.trim_end_matches('/'))
        ));
    }
    sql.push_str(&parts.join(" OR "));
    sql.push(')');
    let limit_idx = params.len() + 1;
    sql.push_str(&format!(
        " ORDER BY updated_at DESC, semantic_id ASC LIMIT ?{limit_idx}"
    ));
    params.push(MAX_LIMIT.to_string());

    let mut stmt = ctx
        .conn
        .prepare(&sql)
        .map_err(|e| format!("sem.search failed: registry query prepare failed: {e}"))?;
    let rows = stmt
        .query_map(rusqlite::params_from_iter(params.iter()), |row| {
            Ok(RegistryRow {
                semantic_id: row.get(0)?,
                file_path: row.get(1)?,
                name: row.get(2)?,
                kind: row.get(3)?,
            })
        })
        .map_err(|e| format!("sem.search failed: registry query failed: {e}"))?;

    let mut items = Vec::new();
    for row in rows {
        let row = row.map_err(|e| format!("sem.search failed: registry row read failed: {e}"))?;
        items.push(SearchItem {
            path: row.file_path,
            symbol: Some(row.name),
            semantic_id: Some(row.semantic_id),
            kind: Some(row.kind),
            line: None,
            excerpt: None,
            source: "registry".to_string(),
        });
    }
    Ok(items)
}

/// Union arm: query the tree-sitter `symbols` table so `sem.search` surfaces
/// indexed symbols (31k+ rows), not just the curated `components` registry.
///
/// Reuses the proven query shape from `sem.symbols.search`
/// ([`crate::symbols_search`]): name/qualified_name LIKE, exact-name ranking,
/// signature truncation. The repo-relative `scope_paths` filter mirrors the
/// `components` arm (exact file match OR directory prefix) so a scoped
/// `sem.search` filters symbols rows the same way it filters registry rows.
///
/// Read-only (SELECT only). Tagged `source:"symbols"`.
fn query_symbols_items(
    ctx: &ServerContext,
    input: &SearchInput,
) -> Result<Vec<SearchItem>, String> {
    // The tree-sitter `symbols` table is created by
    // `tree_sitter_index::db::run_tree_sitter_migrations`, which the production
    // server runs alongside the semantic-mcp migrations
    // (`db::open_project_connection`). If a DB predates that table, the union
    // arm degrades to zero rows rather than failing the whole search: registry
    // / FTS results must still be served (additive, advisory union).
    if !symbols_table_exists(ctx)? {
        return Ok(Vec::new());
    }
    let like = format!("%{}%", escape_like(&input.query));
    let mut sql = String::from(
        "SELECT name, qualified_name, kind, file_path, start_line, signature \
         FROM symbols \
         WHERE project_id = ?1 \
           AND (name LIKE ?2 ESCAPE '\\' OR qualified_name LIKE ?2 ESCAPE '\\') \
           AND (",
    );
    let mut params: Vec<String> = vec![ctx.project_id.clone(), like];
    let mut parts = Vec::new();
    for scope_path in &input.scope_paths {
        let idx = params.len() + 1;
        let idx2 = params.len() + 2;
        parts.push(format!(
            "(file_path = ?{idx} OR file_path LIKE ?{idx2} ESCAPE '\\')"
        ));
        params.push(scope_path.clone());
        params.push(format!("{}/%", escape_like(scope_path.trim_end_matches('/'))));
    }
    sql.push_str(&parts.join(" OR "));
    sql.push(')');
    // Exact-name first, then shortest name, then deterministic path/line.
    let exact_idx = params.len() + 1;
    let limit_idx = params.len() + 2;
    sql.push_str(&format!(
        " ORDER BY (name = ?{exact_idx}) DESC, length(name) ASC, file_path ASC, start_line ASC LIMIT ?{limit_idx}"
    ));
    params.push(input.query.clone());
    // Cap at MAX_LIMIT (sem.search's bound) so the union arm cannot exceed the
    // overall result budget before merge/limit.
    params.push(MAX_LIMIT.to_string());

    let mut stmt = ctx
        .conn
        .prepare(&sql)
        .map_err(|e| format!("sem.search failed: symbols query prepare failed: {e}"))?;
    let rows = stmt
        .query_map(rusqlite::params_from_iter(params.iter()), |row| {
            Ok(SymbolsRow {
                name: row.get(0)?,
                qualified_name: row.get(1)?,
                kind: row.get(2)?,
                file_path: row.get(3)?,
                start_line: row.get(4)?,
                signature: row.get(5)?,
            })
        })
        .map_err(|e| format!("sem.search failed: symbols query failed: {e}"))?;

    let mut items = Vec::new();
    for row in rows {
        let row = row.map_err(|e| format!("sem.search failed: symbols row read failed: {e}"))?;
        let line = if row.start_line > 0 {
            Some(row.start_line as usize)
        } else {
            None
        };
        let excerpt = row
            .signature
            .filter(|s| !s.is_empty())
            .map(|s| truncate_chars(&s, MAX_SYMBOL_SIGNATURE_CHARS));
        items.push(SearchItem {
            path: row.file_path,
            symbol: Some(row.name),
            // qualified_name (when present) is the most useful stable id for a
            // symbol hit; fall back to None so the field is omitted.
            semantic_id: row.qualified_name.filter(|s| !s.is_empty()),
            kind: Some(row.kind),
            line,
            excerpt,
            source: "symbols".to_string(),
        });
    }
    Ok(items)
}

fn symbols_table_exists(ctx: &ServerContext) -> Result<bool, String> {
    ctx.conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'symbols' LIMIT 1",
            [],
            |_| Ok(()),
        )
        .map(|_| true)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(false),
            other => Err(format!(
                "sem.search failed: symbols table probe failed: {other}"
            )),
        })
}

fn query_fts5_items(ctx: &ServerContext, input: &SearchInput) -> Result<Vec<SearchItem>, String> {
    let escaped_query = fts5_escape(&input.query);
    let mut sql = String::from(
        "SELECT c.semantic_id,
                c.file_path,
                c.name,
                c.kind,
                COALESCE(CAST(strftime('%s', c.updated_at) AS INTEGER) * 1000, 0) AS updated_at_unix_ms,
                bm25(components_fts) AS bm25_rank
         FROM components_fts
         JOIN components c ON c.id = components_fts.rowid
         WHERE components_fts MATCH ?1
           AND c.project_id = ?2
           AND c.status != 'deleted'
           AND (",
    );
    let mut params: Vec<String> = vec![escaped_query, ctx.project_id.clone()];
    let mut parts = Vec::new();
    for scope_path in &input.scope_paths {
        let idx = params.len() + 1;
        let idx2 = params.len() + 2;
        parts.push(format!(
            "(c.file_path = ?{idx} OR c.file_path LIKE ?{idx2} ESCAPE '\\')"
        ));
        params.push(scope_path.clone());
        params.push(format!(
            "{}/%",
            escape_like(scope_path.trim_end_matches('/'))
        ));
    }
    sql.push_str(&parts.join(" OR "));
    sql.push(')');
    let limit_idx = params.len() + 1;
    sql.push_str(&format!(" ORDER BY bm25_rank ASC LIMIT ?{limit_idx}"));
    params.push(input.limit.saturating_add(1).to_string());

    let mut stmt = ctx
        .conn
        .prepare(&sql)
        .map_err(|e| format!("sem.search failed: fts5 query prepare failed: {e}"))?;
    let rows = stmt
        .query_map(rusqlite::params_from_iter(params.iter()), |row| {
            let updated_at_unix_ms: i64 = row.get(4)?;
            Ok(FtsRow {
                semantic_id: row.get(0)?,
                file_path: row.get(1)?,
                name: row.get(2)?,
                kind: row.get(3)?,
                updated_at_unix_ms: updated_at_unix_ms.max(0) as u64,
                bm25_rank: row.get(5)?,
            })
        })
        .map_err(|e| format!("sem.search failed: fts5 query failed: {e}"))?;

    let mut rows_vec = Vec::new();
    for row in rows {
        rows_vec.push(row.map_err(|e| format!("sem.search failed: fts5 row read failed: {e}"))?);
    }

    let bm25_min = rows_vec
        .iter()
        .map(|row| row.bm25_rank)
        .fold(f64::INFINITY, f64::min);
    let bm25_max = rows_vec
        .iter()
        .map(|row| row.bm25_rank)
        .fold(f64::NEG_INFINITY, f64::max);
    let now_unix_ms = ctx.clock.now_unix_ms();

    let mut scored = rows_vec
        .into_iter()
        .map(|row| {
            let bm25_normalized = normalize_bm25(row.bm25_rank, bm25_min, bm25_max);
            let recency = recency_score(row.updated_at_unix_ms, now_unix_ms);
            let score = compute_rank_score(0, 0, recency, bm25_normalized, &RankingWeights::SEARCH);
            (score, row)
        })
        .collect::<Vec<_>>();

    scored.sort_by(|(left_score, left), (right_score, right)| {
        right_score
            .partial_cmp(left_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.file_path.cmp(&right.file_path))
            .then_with(|| left.semantic_id.cmp(&right.semantic_id))
    });

    Ok(scored
        .into_iter()
        .map(|(_, row)| SearchItem {
            path: row.file_path,
            symbol: Some(row.name),
            semantic_id: Some(row.semantic_id),
            kind: Some(row.kind),
            line: None,
            excerpt: None,
            source: "fts5".to_string(),
        })
        .collect())
}

fn normalize_bm25(rank: f64, min: f64, max: f64) -> f64 {
    if !rank.is_finite() || !min.is_finite() || !max.is_finite() {
        return 0.0;
    }
    if (max - min).abs() < f64::EPSILON {
        return 1.0;
    }
    ((max - rank) / (max - min)).clamp(0.0, 1.0)
}

#[doc(hidden)]
pub fn fts5_escape(input: &str) -> String {
    let escaped = input.replace('"', r#""""#);
    format!(r#""{escaped}""#)
}

fn search_files(
    ctx: &ServerContext,
    files: &[PathBuf],
    query: &str,
) -> Result<Vec<SearchItem>, String> {
    let needle = query.to_lowercase();
    let mut items = Vec::new();
    let repo_root = fs::canonicalize(&ctx.repo_root)
        .map_err(|e| format!("sem.search failed: repo root canonicalization failed: {e}"))?;

    for file in files {
        let metadata = fs::metadata(file)
            .map_err(|e| format!("sem.search failed: metadata read failed: {e}"))?;
        if metadata.len() > MAX_SEARCH_FILE_BYTES {
            continue;
        }
        let bytes =
            fs::read(file).map_err(|e| format!("sem.search failed: file read failed: {e}"))?;
        let Ok(content) = String::from_utf8(bytes) else {
            continue;
        };
        for (idx, line) in content.lines().enumerate() {
            if !line.to_lowercase().contains(&needle) {
                continue;
            }
            let rel = file
                .strip_prefix(&repo_root)
                .map_err(|_| "sem.search failed: file must stay inside repo root".to_string())?
                .to_string_lossy()
                .replace('\\', "/");
            items.push(SearchItem {
                path: rel,
                symbol: None,
                semantic_id: None,
                kind: None,
                line: Some(idx + 1),
                excerpt: Some(truncate_chars(line.trim(), MAX_EXCERPT_CHARS)),
                source: "filesystem".to_string(),
            });
            break;
        }
    }
    Ok(items)
}

fn merge_search_items(
    registry_items: Vec<SearchItem>,
    filesystem_items: Vec<SearchItem>,
) -> Vec<SearchItem> {
    let mut by_path: BTreeMap<String, SearchItem> = BTreeMap::new();
    for item in registry_items {
        by_path.insert(item.path.clone(), item);
    }
    for item in filesystem_items {
        if let Some(existing) = by_path.get_mut(&item.path) {
            existing.line = item.line;
            existing.excerpt = item.excerpt;
            existing.source = "registry+filesystem".to_string();
        } else {
            by_path.insert(item.path.clone(), item);
        }
    }
    by_path.into_values().collect()
}

/// Merge the existing components/registry/FTS/filesystem result set with the
/// symbols-union result set into one deterministically-ordered list.
///
/// Ordering (additive, does not reshuffle within a tier):
/// 1. Exact-name matches (`symbol == query`) first, across all sources.
/// 2. Existing arms (registry/fts/filesystem) before symbols hits, preserving
///    each arm's own internal ranking (stable sort).
/// De-dup: a symbols hit that points at the same (path, symbol) as an existing
/// hit is dropped so the registry/FTS row (richer source value) wins.
fn merge_union_items(
    primary: Vec<SearchItem>,
    symbol_items: Vec<SearchItem>,
    query: &str,
) -> Vec<SearchItem> {
    let mut seen: std::collections::BTreeSet<(String, Option<String>)> = primary
        .iter()
        .map(|item| (item.path.clone(), item.symbol.clone()))
        .collect();
    let mut merged = primary;
    for item in symbol_items {
        let key = (item.path.clone(), item.symbol.clone());
        if seen.insert(key) {
            merged.push(item);
        }
    }
    // Stable sort: exact-name first, then existing arms before symbols. Within
    // each (exact, tier) bucket the original arm ordering is preserved.
    merged.sort_by(|left, right| {
        let left_exact = u8::from(left.symbol.as_deref() != Some(query));
        let right_exact = u8::from(right.symbol.as_deref() != Some(query));
        let left_tier = u8::from(left.source == "symbols");
        let right_tier = u8::from(right.source == "symbols");
        left_exact
            .cmp(&right_exact)
            .then_with(|| left_tier.cmp(&right_tier))
    });
    merged
}

fn compact_response(
    items: Vec<SearchItem>,
    total: usize,
    truncated: bool,
    capsule_budget_tokens: usize,
) -> SearchResponse {
    let mut compact_items = items;
    let char_budget = capsule_budget_tokens * 3;
    loop {
        let response = build_response(
            compact_items.clone(),
            total,
            truncated || compact_items.len() < total,
        );
        if serde_json::to_string(&response)
            .map(|v| v.len())
            .unwrap_or(usize::MAX)
            <= char_budget
        {
            return response;
        }
        if compact_items.is_empty() {
            return build_response(Vec::new(), total, true);
        }
        compact_items.pop();
    }
}

fn build_response(items: Vec<SearchItem>, total: usize, truncated: bool) -> SearchResponse {
    SearchResponse {
        capsule: format!(
            "matched:{total} returned:{} truncated:{truncated} advisory_only:true",
            items.len()
        ),
        items,
        total,
        truncated,
        advisory_only: true,
    }
}


fn get_required_string(obj: &serde_json::Map<String, Value>, key: &str) -> Result<String, String> {
    get_optional_string(obj, key)?.ok_or_else(|| format!("sem.search failed: {key} is required"))
}

fn get_optional_string(
    obj: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, String> {
    match obj.get(key) {
        None => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => {
            Ok(Some(value.trim().to_string()))
        }
        Some(_) => Err(format!(
            "sem.search failed: {key} must be a non-blank string"
        )),
    }
}

fn get_consistent_alias<'a>(
    obj: &'a serde_json::Map<String, Value>,
    keys: &[&str],
    label: &str,
) -> Result<Option<&'a Value>, String> {
    let present: Vec<&str> = keys
        .iter()
        .copied()
        .filter(|key| obj.contains_key(*key))
        .collect();
    if present.is_empty() {
        return Ok(None);
    }
    let first = obj.get(present[0]).expect("present key");
    for key in present.iter().skip(1) {
        if obj.get(*key) != Some(first) {
            return Err(format!("sem.search failed: {label} aliases must match"));
        }
    }
    Ok(Some(first))
}

fn parse_usize(value: Option<&Value>, label: &str) -> Result<Option<usize>, String> {
    match value {
        None => Ok(None),
        Some(Value::Number(number)) => number
            .as_i64()
            .map(|v| Some(v.max(1) as usize))
            .ok_or_else(|| format!("sem.search failed: {label} must be an integer")),
        Some(Value::String(value)) if value.parse::<i64>().is_ok() => {
            Ok(Some(value.parse::<i64>().unwrap().max(1) as usize))
        }
        Some(_) => Err(format!("sem.search failed: {label} must be an integer")),
    }
}

fn clamp_usize(value: usize, min: usize, max: usize) -> usize {
    value.max(min).min(max)
}

fn assert_inside_repo(repo_root: &Path, target: &Path) -> Result<(), String> {
    if target.starts_with(repo_root) {
        return Ok(());
    }
    Err("sem.search failed: scope_paths must stay inside repo root".to_string())
}

fn truncate_chars(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

fn escape_like(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

#[cfg(test)]
fn remove_test_repo(path: PathBuf) {
    let _ = fs::remove_dir_all(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use rusqlite::Connection;
    use serde_json::json;
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_ctx() -> (ServerContext, PathBuf) {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let repo_root = std::env::temp_dir().join(format!("semantic-mcp-search-rust-{suffix}"));
        fs::create_dir_all(&repo_root).unwrap();
        let conn = Connection::open_in_memory().unwrap();
        db::run_migrations(&conn).unwrap();
        // Tree-sitter `symbols` table is required for the sem.search union arm.
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
        conn.execute(
            "INSERT INTO projects (id, name, root_path, created_at, updated_at) VALUES (?1, ?2, ?3, datetime('now'), datetime('now'))",
            rusqlite::params!["test-project", "Test Project", repo_root.display().to_string()],
        )
        .unwrap();
        (
            ServerContext::new(conn, "test-project".to_string(), repo_root.clone()),
            repo_root,
        )
    }

    #[test]
    fn search_returns_advisory_registry_and_filesystem_match() {
        let (ctx, repo_root) = test_ctx();
        let file = repo_root.join("src/core/user-service.ts");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(
            &file,
            format!(
                "export class UserService {{\n  {} targetNeedle\n}}\n",
                "x".repeat(120)
            ),
        )
        .unwrap();
        ctx.conn
            .execute(
                "INSERT INTO components (project_id, semantic_id, name, module, file_path, kind, exports, imports, hash, status, idem, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '[]', '[]', '', 'active', '', datetime('now'))",
                rusqlite::params![
                    "test-project",
                    "core:UserService",
                    "UserService",
                    "core",
                    "src/core/user-service.ts",
                    "class"
                ],
            )
            .unwrap();

        let result = handle_search(
            &ctx,
            &json!({
                "project_id": "test-project",
                "query": "UserService",
                "kind": "legacy-like",
                "scope_paths": ["src/core/user-service.ts"],
                "limit": 50,
                "capsule_budget_tokens": 500
            }),
        )
        .unwrap();

        assert_eq!(result["advisory_only"], true);
        assert_eq!(result["items"][0]["path"], "src/core/user-service.ts");
        assert_eq!(result["items"][0]["semantic_id"], "core:UserService");
        assert_eq!(result["items"][0]["source"], "registry+filesystem");
        assert!(
            result["items"][0]["excerpt"]
                .as_str()
                .unwrap()
                .chars()
                .count()
                <= 80
        );
        remove_test_repo(repo_root);
    }

    #[test]
    fn search_rejects_unsafe_scopes_and_alias_mismatch() {
        let (ctx, repo_root) = test_ctx();
        let file = repo_root.join("src/core/user-service.ts");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "targetNeedle").unwrap();
        symlink(&file, repo_root.join("linked.ts")).unwrap();

        for scope_paths in [
            json!([]),
            json!(["."]),
            json!(["*"]),
            json!(["/tmp/file.ts"]),
            json!(["../outside.ts"]),
            json!(["linked.ts"]),
        ] {
            let result = handle_search(
                &ctx,
                &json!({"query": "targetNeedle", "kind": "legacy-like", "scope_paths": scope_paths}),
            );
            assert!(result.is_err());
        }

        let result = handle_search(
            &ctx,
            &json!({
                "query": "targetNeedle",
                "kind": "legacy-like",
                "scope_paths": ["src/core/user-service.ts"],
                "scopePaths": ["src/core/other.ts"]
            }),
        );
        assert!(result.unwrap_err().contains("aliases must match"));
        remove_test_repo(repo_root);
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_symbol(
        ctx: &ServerContext,
        name: &str,
        qualified_name: &str,
        kind: &str,
        language: &str,
        file_path: &str,
        start_line: i64,
        signature: &str,
    ) {
        ctx.conn
            .execute(
                "INSERT INTO symbols (
                    project_id, file_path, file_hash, name, qualified_name, kind, language,
                    start_line, end_line, start_col, end_col, signature, visibility
                 ) VALUES (?1, ?2, '', ?3, ?4, ?5, ?6, ?7, ?8, 0, 0, ?9, '')",
                rusqlite::params![
                    "test-project",
                    file_path,
                    name,
                    qualified_name,
                    kind,
                    language,
                    start_line,
                    start_line + 10,
                    signature,
                ],
            )
            .unwrap();
    }

    fn insert_component(ctx: &ServerContext, semantic_id: &str, name: &str, file_path: &str) {
        ctx.conn
            .execute(
                "INSERT INTO components (project_id, semantic_id, name, module, file_path, kind, exports, imports, hash, status, idem, updated_at) VALUES (?1, ?2, ?3, 'core', ?4, 'function', '[]', '[]', '', 'active', '', datetime('now'))",
                rusqlite::params!["test-project", semantic_id, name, file_path],
            )
            .unwrap();
    }

    #[test]
    fn search_finds_symbols_only_name_via_union_fts5() {
        // HEADLINE KPI: a name that exists ONLY in the tree-sitter `symbols`
        // table (not in `components`) must be returned by the default
        // sem.search (fts5 mode) tagged source:"symbols".
        let (ctx, repo_root) = test_ctx();
        let dir = repo_root.join("contact_sender_v2/sidecar/scripts/sender-opt");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("proof-harness.ts"), "// proof harness\n").unwrap();
        insert_symbol(
            &ctx,
            "classifyRequiredMissCause",
            "sender::classifyRequiredMissCause",
            "function",
            "typescript",
            "contact_sender_v2/sidecar/scripts/sender-opt/proof-harness.ts",
            256,
            "function classifyRequiredMissCause(miss: Miss): Cause",
        );

        let result = handle_search(
            &ctx,
            &json!({
                "query": "classifyRequiredMissCause",
                "scope_paths": ["contact_sender_v2/sidecar/scripts/sender-opt"],
                "limit": 10,
                "capsule_budget_tokens": 200
            }),
        )
        .unwrap();

        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 1, "symbols hit must be returned: {result:?}");
        assert_eq!(items[0]["source"], "symbols");
        assert_eq!(items[0]["symbol"], "classifyRequiredMissCause");
        assert_eq!(
            items[0]["path"],
            "contact_sender_v2/sidecar/scripts/sender-opt/proof-harness.ts"
        );
        assert_eq!(items[0]["semantic_id"], "sender::classifyRequiredMissCause");
        assert_eq!(items[0]["line"], 256);
        remove_test_repo(repo_root);
    }

    #[test]
    fn search_union_keeps_registry_and_adds_symbols() {
        // Registry (components) hits remain, AND symbols-only hits appear, in
        // one merged result set. Uses legacy-like so the `components` arm is
        // queried directly (the union arm is identical across both modes).
        let (ctx, repo_root) = test_ctx();
        fs::create_dir_all(repo_root.join("src")).unwrap();
        fs::write(repo_root.join("src/widget.ts"), "// widget\n").unwrap();
        fs::write(repo_root.join("src/widget_sym.ts"), "// sym\n").unwrap();
        insert_component(&ctx, "core:WidgetRegistry", "WidgetRegistry", "src/widget.ts");
        // Symbol that exists ONLY in the symbols table (distinct name + path).
        insert_symbol(
            &ctx,
            "WidgetFromSymbols",
            "core::WidgetFromSymbols",
            "function",
            "typescript",
            "src/widget_sym.ts",
            12,
            "",
        );

        let result = handle_search(
            &ctx,
            &json!({
                "query": "Widget",
                "kind": "legacy-like",
                "scope_paths": ["src"],
                "limit": 10,
                "capsule_budget_tokens": 200
            }),
        )
        .unwrap();

        let items = result["items"].as_array().unwrap();
        let sources: Vec<&str> = items
            .iter()
            .map(|i| i["source"].as_str().unwrap())
            .collect();
        assert!(
            sources.iter().any(|s| s.contains("registry")),
            "registry hit must remain: {sources:?}"
        );
        assert!(
            sources.contains(&"symbols"),
            "symbols hit must be added: {sources:?}"
        );
        remove_test_repo(repo_root);
    }

    #[test]
    fn search_union_scope_paths_filter_symbols() {
        // scope_paths (repo-relative, post-Slice-A) must filter symbols rows:
        // an in-scope symbol is returned; an out-of-scope symbol is not.
        let (ctx, repo_root) = test_ctx();
        fs::create_dir_all(repo_root.join("src/in")).unwrap();
        fs::create_dir_all(repo_root.join("src/out")).unwrap();
        fs::write(repo_root.join("src/in/a.ts"), "// in\n").unwrap();
        fs::write(repo_root.join("src/out/b.ts"), "// out\n").unwrap();
        insert_symbol(&ctx, "scopedThing", "m::scopedThing", "function", "typescript", "src/in/a.ts", 1, "");
        insert_symbol(&ctx, "scopedThing", "m::scopedThing", "function", "typescript", "src/out/b.ts", 1, "");

        let result = handle_search(
            &ctx,
            &json!({
                "query": "scopedThing",
                "scope_paths": ["src/in"],
                "limit": 10
            }),
        )
        .unwrap();

        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 1, "only in-scope symbol returned: {result:?}");
        assert_eq!(items[0]["path"], "src/in/a.ts");
        assert_eq!(items[0]["source"], "symbols");
        remove_test_repo(repo_root);
    }

    #[test]
    fn search_union_legacy_like_mode_also_finds_symbols() {
        // The symbols union applies to legacy-like mode too.
        let (ctx, repo_root) = test_ctx();
        let dir = repo_root.join("src/core");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("svc.ts"), "// no inline needle here\n").unwrap();
        insert_symbol(
            &ctx,
            "onlyInSymbols",
            "core::onlyInSymbols",
            "function",
            "typescript",
            "src/core/svc.ts",
            7,
            "",
        );

        let result = handle_search(
            &ctx,
            &json!({
                "query": "onlyInSymbols",
                "kind": "legacy-like",
                "scope_paths": ["src/core"],
                "limit": 10,
                "capsule_budget_tokens": 200
            }),
        )
        .unwrap();

        let items = result["items"].as_array().unwrap();
        assert!(
            items.iter().any(|i| i["source"] == "symbols"
                && i["symbol"] == "onlyInSymbols"),
            "legacy-like union must include symbols hit: {result:?}"
        );
        remove_test_repo(repo_root);
    }

    #[test]
    fn search_rejects_unbounded_scope_lists_and_skips_invalid_utf8() {
        let (ctx, repo_root) = test_ctx();
        let mut paths = Vec::new();
        for index in 0..41 {
            let rel = format!("src/core/file-{index}.ts");
            let file = repo_root.join(&rel);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(&file, "targetNeedle").unwrap();
            paths.push(rel);
        }

        let result = handle_search(
            &ctx,
            &json!({
                "query": "targetNeedle",
                "kind": "legacy-like",
                "scope_paths": paths
            }),
        );
        assert!(result.unwrap_err().contains("at most 40 entries"));

        let invalid_utf8 = repo_root.join("src/core/invalid-utf8.bin");
        fs::write(
            &invalid_utf8,
            [0xff, 0xfe, b't', b'a', b'r', b'g', b'e', b't'],
        )
        .unwrap();
        let result = handle_search(
            &ctx,
            &json!({
                "query": "target",
                "kind": "legacy-like",
                "scope_paths": ["src/core/invalid-utf8.bin"]
            }),
        )
        .unwrap();
        assert_eq!(result["items"].as_array().unwrap().len(), 0);
        assert_eq!(result["total"], 0);
        remove_test_repo(repo_root);
    }
}
