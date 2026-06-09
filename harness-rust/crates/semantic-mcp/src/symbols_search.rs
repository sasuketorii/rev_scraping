//! Read-only advisory `sem.symbols.search` implementation.
//!
//! Provides free-form name / qualified_name substring search over the
//! tree-sitter `symbols` index. This complements `sem.search`, which only
//! covers the curated registry (`components`). It is strictly read-only
//! (SELECT only): no migration, no INSERT/UPDATE/DELETE, no schema change.

use serde::Serialize;
use serde_json::Value;

use crate::context::ServerContext;

const DEFAULT_LIMIT: usize = 10;
const MAX_LIMIT: usize = 25;
const MAX_SIGNATURE_CHARS: usize = 120;
const MAX_CAPSULE_BUDGET_TOKENS: usize = 200;
const DEFAULT_CAPSULE_BUDGET_TOKENS: usize = 120;

#[derive(Debug, Clone, Serialize)]
pub struct SymbolItem {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub qualified_name: Option<String>,
    pub kind: String,
    pub language: String,
    pub file_path: String,
    pub line: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_line: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visibility: Option<String>,
    pub source: String,
}

#[derive(Debug, Serialize)]
pub struct SymbolsSearchResponse {
    pub items: Vec<SymbolItem>,
    pub total: usize,
    pub truncated: bool,
    pub advisory_only: bool,
}

struct SymbolsSearchInput {
    query: String,
    kind: Option<String>,
    language: Option<String>,
    path_prefix: Option<String>,
    limit: usize,
    capsule_budget_tokens: usize,
}

struct SymbolRow {
    name: String,
    qualified_name: Option<String>,
    kind: String,
    language: String,
    file_path: String,
    start_line: i64,
    end_line: i64,
    signature: Option<String>,
    visibility: Option<String>,
}

pub fn handle_symbols_search(ctx: &ServerContext, args: &Value) -> Result<Value, String> {
    let input = normalize_input(ctx, args)?;
    let rows = query_symbols(ctx, &input)?;

    let total_matched = rows.len();
    let truncated = total_matched > input.limit;
    let items: Vec<SymbolItem> = rows
        .into_iter()
        .take(input.limit)
        .map(|row| SymbolItem {
            name: row.name,
            qualified_name: row.qualified_name.filter(|s| !s.is_empty()),
            kind: row.kind,
            language: row.language,
            file_path: row.file_path,
            line: row.start_line,
            end_line: Some(row.end_line),
            signature: row
                .signature
                .filter(|s| !s.is_empty())
                .map(|s| truncate_chars(&s, MAX_SIGNATURE_CHARS)),
            visibility: row.visibility.filter(|s| !s.is_empty()),
            source: "symbols".to_string(),
        })
        .collect();

    let response = compact_response(items, total_matched, truncated, input.capsule_budget_tokens);
    serde_json::to_value(response).map_err(|e| format!("sem.symbols.search failed: {e}"))
}

fn normalize_input(ctx: &ServerContext, args: &Value) -> Result<SymbolsSearchInput, String> {
    let obj = args
        .as_object()
        .ok_or_else(|| "sem.symbols.search failed: search input must be an object".to_string())?;

    if let Some(project_id) = get_optional_string(obj, "project_id")? {
        if project_id != ctx.project_id {
            return Err(format!(
                "sem.symbols.search failed: project_id mismatch: expected {}, received {}",
                ctx.project_id, project_id
            ));
        }
    }

    let query = get_required_string(obj, "query")?;
    let kind = get_optional_string(obj, "kind")?;
    let language = get_optional_string(obj, "language")?;
    let path_prefix = get_optional_string(obj, "path_prefix")?;
    let limit = clamp_usize(
        parse_usize(obj.get("limit"), "limit")?.unwrap_or(DEFAULT_LIMIT),
        1,
        MAX_LIMIT,
    );
    let capsule_budget_tokens = clamp_usize(
        parse_usize(obj.get("capsule_budget_tokens"), "capsule_budget_tokens")?
            .unwrap_or(DEFAULT_CAPSULE_BUDGET_TOKENS),
        1,
        MAX_CAPSULE_BUDGET_TOKENS,
    );

    Ok(SymbolsSearchInput {
        query,
        kind,
        language,
        path_prefix,
        limit,
        capsule_budget_tokens,
    })
}

fn query_symbols(
    ctx: &ServerContext,
    input: &SymbolsSearchInput,
) -> Result<Vec<SymbolRow>, String> {
    let like = format!("%{}%", escape_like(&input.query));
    // path_prefix is matched via `file_path LIKE (?5 || '%')`, so the literal
    // prefix portion must also be LIKE-escaped to avoid wildcard injection.
    let escaped_path_prefix = input.path_prefix.as_ref().map(|p| escape_like(p));

    let sql = "\
        SELECT name, qualified_name, kind, language, file_path, start_line, end_line, signature, visibility \
        FROM symbols \
        WHERE project_id = ?1 \
          AND (name LIKE ?2 ESCAPE '\\' OR qualified_name LIKE ?2 ESCAPE '\\') \
          AND (?3 IS NULL OR kind = ?3) \
          AND (?4 IS NULL OR language = ?4) \
          AND (?5 IS NULL OR file_path LIKE (?5 || '%') ESCAPE '\\') \
        ORDER BY (name = ?6) DESC, length(name) ASC, file_path ASC, start_line ASC \
        LIMIT ?7";

    let mut stmt = ctx
        .conn
        .prepare(sql)
        .map_err(|e| format!("sem.symbols.search failed: query prepare failed: {e}"))?;

    let limit_plus_one = (input.limit as i64).saturating_add(1);
    let rows = stmt
        .query_map(
            rusqlite::params![
                ctx.project_id,
                like,
                input.kind,
                input.language,
                escaped_path_prefix,
                input.query,
                limit_plus_one,
            ],
            |row| {
                Ok(SymbolRow {
                    name: row.get(0)?,
                    qualified_name: row.get(1)?,
                    kind: row.get(2)?,
                    language: row.get(3)?,
                    file_path: row.get(4)?,
                    start_line: row.get(5)?,
                    end_line: row.get(6)?,
                    signature: row.get(7)?,
                    visibility: row.get(8)?,
                })
            },
        )
        .map_err(|e| format!("sem.symbols.search failed: query failed: {e}"))?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(|e| format!("sem.symbols.search failed: row read failed: {e}"))?);
    }
    Ok(out)
}

fn compact_response(
    items: Vec<SymbolItem>,
    total: usize,
    truncated: bool,
    capsule_budget_tokens: usize,
) -> SymbolsSearchResponse {
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

fn build_response(items: Vec<SymbolItem>, total: usize, truncated: bool) -> SymbolsSearchResponse {
    SymbolsSearchResponse {
        items,
        total,
        truncated,
        advisory_only: true,
    }
}

fn get_required_string(obj: &serde_json::Map<String, Value>, key: &str) -> Result<String, String> {
    get_optional_string(obj, key)?
        .ok_or_else(|| format!("sem.symbols.search failed: {key} is required"))
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
            "sem.symbols.search failed: {key} must be a non-blank string"
        )),
    }
}

fn parse_usize(value: Option<&Value>, label: &str) -> Result<Option<usize>, String> {
    match value {
        None => Ok(None),
        Some(Value::Number(number)) => number
            .as_i64()
            .map(|v| Some(v.max(1) as usize))
            .ok_or_else(|| format!("sem.symbols.search failed: {label} must be an integer")),
        Some(Value::String(value)) if value.parse::<i64>().is_ok() => {
            Ok(Some(value.parse::<i64>().unwrap().max(1) as usize))
        }
        Some(_) => Err(format!(
            "sem.symbols.search failed: {label} must be an integer"
        )),
    }
}

fn clamp_usize(value: usize, min: usize, max: usize) -> usize {
    value.max(min).min(max)
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
mod tests {
    use super::*;
    use crate::db;
    use rusqlite::Connection;
    use serde_json::json;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_ctx() -> (ServerContext, PathBuf) {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let repo_root = std::env::temp_dir().join(format!("semantic-mcp-symsearch-{suffix}"));
        std::fs::create_dir_all(&repo_root).unwrap();
        let conn = Connection::open_in_memory().unwrap();
        db::run_migrations(&conn).unwrap();
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

    #[allow(clippy::too_many_arguments)]
    fn insert_symbol(
        ctx: &ServerContext,
        name: &str,
        qualified_name: &str,
        kind: &str,
        language: &str,
        file_path: &str,
        start_line: i64,
        end_line: i64,
        signature: &str,
        visibility: &str,
    ) {
        ctx.conn
            .execute(
                "INSERT INTO symbols (
                    project_id, file_path, file_hash, name, qualified_name, kind, language,
                    start_line, end_line, start_col, end_col, signature, visibility
                 ) VALUES (?1, ?2, '', ?3, ?4, ?5, ?6, ?7, ?8, 0, 0, ?9, ?10)",
                rusqlite::params![
                    "test-project",
                    file_path,
                    name,
                    qualified_name,
                    kind,
                    language,
                    start_line,
                    end_line,
                    signature,
                    visibility,
                ],
            )
            .unwrap();
    }

    fn remove_test_repo(path: PathBuf) {
        let _ = std::fs::remove_dir_all(path);
    }

    #[test]
    fn finds_by_name_substring() {
        let (ctx, repo_root) = test_ctx();
        insert_symbol(
            &ctx,
            "computeUserScore",
            "billing::computeUserScore",
            "function",
            "rust",
            "src/billing/score.rs",
            10,
            42,
            "fn computeUserScore(user: &User) -> f64",
            "pub",
        );
        let result = handle_symbols_search(
            &ctx,
            &json!({ "project_id": "test-project", "query": "UserScore" }),
        )
        .unwrap();
        assert_eq!(result["advisory_only"], true);
        assert_eq!(result["total"], 1);
        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["name"], "computeUserScore");
        assert_eq!(items[0]["qualified_name"], "billing::computeUserScore");
        assert_eq!(items[0]["line"], 10);
        assert_eq!(items[0]["end_line"], 42);
        assert_eq!(items[0]["source"], "symbols");
        assert_eq!(items[0]["visibility"], "pub");
        remove_test_repo(repo_root);
    }

    #[test]
    fn matches_qualified_name_only() {
        let (ctx, repo_root) = test_ctx();
        insert_symbol(
            &ctx,
            "handler",
            "auth::login::handler",
            "function",
            "rust",
            "src/auth/login.rs",
            5,
            9,
            "",
            "",
        );
        let result = handle_symbols_search(
            &ctx,
            &json!({ "query": "auth::login" }),
        )
        .unwrap();
        assert_eq!(result["total"], 1);
        assert_eq!(result["items"][0]["name"], "handler");
        // empty signature/visibility omitted
        assert!(result["items"][0].get("signature").is_none());
        assert!(result["items"][0].get("visibility").is_none());
        remove_test_repo(repo_root);
    }

    #[test]
    fn respects_kind_language_and_path_prefix_filters() {
        let (ctx, repo_root) = test_ctx();
        insert_symbol(&ctx, "Widget", "ui::Widget", "class", "typescript", "src/ui/widget.ts", 1, 2, "", "");
        insert_symbol(&ctx, "Widget", "core::Widget", "function", "rust", "src/core/widget.rs", 1, 2, "", "");
        insert_symbol(&ctx, "Widget", "vendor::Widget", "class", "typescript", "vendor/ui/widget.ts", 1, 2, "", "");

        // kind filter
        let r = handle_symbols_search(&ctx, &json!({ "query": "Widget", "kind": "function" })).unwrap();
        assert_eq!(r["total"], 1);
        assert_eq!(r["items"][0]["language"], "rust");

        // language filter
        let r = handle_symbols_search(&ctx, &json!({ "query": "Widget", "language": "typescript" })).unwrap();
        assert_eq!(r["total"], 2);

        // path_prefix filter
        let r = handle_symbols_search(&ctx, &json!({ "query": "Widget", "path_prefix": "src/ui" })).unwrap();
        assert_eq!(r["total"], 1);
        assert_eq!(r["items"][0]["file_path"], "src/ui/widget.ts");
        remove_test_repo(repo_root);
    }

    #[test]
    fn path_prefix_matches_repo_relative_stored_paths() {
        // Post path-flip, symbols.file_path is stored REPO-RELATIVE. A
        // repo-relative path_prefix (e.g. "contact_sender_v2/sidecar") must
        // match; an absolute-looking prefix must NOT (would only match the old
        // absolute storage). This is the "free fix" for the 2.2 root cause:
        // scope_paths/path_prefix (repo-relative) now align with storage.
        let (ctx, repo_root) = test_ctx();
        insert_symbol(
            &ctx,
            "classifyRequiredMissCause",
            "sender::classifyRequiredMissCause",
            "function",
            "typescript",
            "contact_sender_v2/sidecar/scripts/sender-opt/proof-harness.ts",
            256,
            300,
            "",
            "",
        );

        // Repo-relative prefix matches.
        let hit = handle_symbols_search(
            &ctx,
            &json!({
                "query": "classifyRequiredMissCause",
                "path_prefix": "contact_sender_v2/sidecar/scripts/sender-opt"
            }),
        )
        .unwrap();
        assert_eq!(hit["total"], 1);
        assert_eq!(
            hit["items"][0]["file_path"],
            "contact_sender_v2/sidecar/scripts/sender-opt/proof-harness.ts"
        );

        // An absolute prefix does NOT match a repo-relative stored path.
        let miss = handle_symbols_search(
            &ctx,
            &json!({
                "query": "classifyRequiredMissCause",
                "path_prefix": "/tmp/revh-test/contact_sender_v2"
            }),
        )
        .unwrap();
        assert_eq!(miss["total"], 0);
        remove_test_repo(repo_root);
    }

    #[test]
    fn exact_name_ranks_first() {
        let (ctx, repo_root) = test_ctx();
        // substring-but-longer match
        insert_symbol(&ctx, "parseConfigFile", "x::parseConfigFile", "function", "rust", "src/z.rs", 1, 2, "", "");
        // exact name match
        insert_symbol(&ctx, "parse", "x::parse", "function", "rust", "src/a.rs", 1, 2, "", "");
        let result = handle_symbols_search(&ctx, &json!({ "query": "parse" })).unwrap();
        assert_eq!(result["total"], 2);
        assert_eq!(result["items"][0]["name"], "parse");
        remove_test_repo(repo_root);
    }

    #[test]
    fn limit_and_truncation() {
        let (ctx, repo_root) = test_ctx();
        for i in 0..5 {
            insert_symbol(
                &ctx,
                &format!("fooSymbol{i}"),
                &format!("m::fooSymbol{i}"),
                "function",
                "rust",
                &format!("src/f{i}.rs"),
                1,
                2,
                "",
                "",
            );
        }
        let result =
            handle_symbols_search(&ctx, &json!({ "query": "fooSymbol", "limit": 3, "capsule_budget_tokens": 200 }))
                .unwrap();
        assert_eq!(result["items"].as_array().unwrap().len(), 3);
        assert_eq!(result["truncated"], true);
        remove_test_repo(repo_root);
    }

    #[test]
    fn no_match_returns_empty() {
        let (ctx, repo_root) = test_ctx();
        insert_symbol(&ctx, "alpha", "m::alpha", "function", "rust", "src/a.rs", 1, 2, "", "");
        let result = handle_symbols_search(&ctx, &json!({ "query": "zzz_nomatch" })).unwrap();
        assert_eq!(result["total"], 0);
        assert_eq!(result["items"].as_array().unwrap().len(), 0);
        assert_eq!(result["truncated"], false);
        remove_test_repo(repo_root);
    }

    #[test]
    fn like_wildcards_in_query_are_escaped() {
        let (ctx, repo_root) = test_ctx();
        insert_symbol(&ctx, "abc", "m::abc", "function", "rust", "src/a.rs", 1, 2, "", "");
        insert_symbol(&ctx, "a_c", "m::a_c", "function", "rust", "src/b.rs", 1, 2, "", "");
        // `_` is a LIKE wildcard; escaping means "a_c" matches only the literal underscore symbol.
        let result = handle_symbols_search(&ctx, &json!({ "query": "a_c" })).unwrap();
        assert_eq!(result["total"], 1);
        assert_eq!(result["items"][0]["name"], "a_c");
        remove_test_repo(repo_root);
    }

    #[test]
    fn rejects_project_id_mismatch_and_blank_query() {
        let (ctx, repo_root) = test_ctx();
        let mismatch =
            handle_symbols_search(&ctx, &json!({ "project_id": "other", "query": "x" }));
        assert!(mismatch.unwrap_err().contains("project_id mismatch"));
        let blank = handle_symbols_search(&ctx, &json!({ "query": "   " }));
        assert!(blank.is_err());
        remove_test_repo(repo_root);
    }
}
