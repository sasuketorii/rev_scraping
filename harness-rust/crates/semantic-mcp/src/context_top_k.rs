//! `sem.context.top_k` implementation.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use shared::freshness::{self, FreshnessError};
use shared::ranker::{compute_rank_score, recency_score, RankingWeights};

use crate::context::{NormalizedContext, ServerContext, TopKEntry};
use crate::util::{normalize_repo_relative_path, sha256_hex};

pub const TTL_SECS: u64 = 1800;

#[derive(Debug)]
struct TopKInput {
    project_id: String,
    task_id: String,
    phase: String,
    changed_files: Vec<String>,
    k: usize,
    max_depth: u32,
    max_nodes: u32,
}

#[derive(Debug, Serialize)]
struct TopKResponse {
    context_token: String,
    top_k_symbols: Vec<TopKEntry>,
    index_version: u64,
    file_sha_rollup: String,
    issued_at_unix_ms: u64,
    ttl_secs: u64,
}

pub fn handle_context_top_k(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let input = normalize_input(ctx, input)?;
    // symbols.file_path is now repo-relative, so impact_analysis must query by
    // the repo-relative changed_files (no repo_root.join). normalize_input has
    // already validated and normalized these to repo-relative forward-slash
    // form.
    let changed_refs = input
        .changed_files
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();

    let report = tree_sitter_index::incremental::impact_analysis(
        &ctx.conn,
        &input.project_id,
        &changed_refs,
        input.max_depth,
        input.max_nodes,
    )
    .map_err(|e| format!("sem.context.top_k failed: impact analysis: {e}"))?;
    let fan_in =
        tree_sitter_index::incremental::detect_high_fan_in(&ctx.conn, &input.project_id, 1)
            .map_err(|e| format!("sem.context.top_k failed: fan-in analysis: {e}"))?;

    let top_k_symbols = rank_top_k(ctx, &report, &fan_in, input.k)?;
    let freshness = freshness::snapshot(
        &ctx.conn,
        &input.project_id,
        &ctx.repo_root,
        &input.changed_files,
    )
    .map_err(map_topk_freshness_error)?;
    let file_sha_rollup = freshness.file_sha_rollup;
    let index_version = freshness.index_version;
    let issued_at_unix_ms = ctx.clock.now_unix_ms();
    let top_k_summary = summarize_top_k(&top_k_symbols);
    let context_token = sha256_hex(&format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        input.project_id, input.task_id, input.phase, file_sha_rollup, index_version, top_k_summary
    ));

    let normalized = NormalizedContext {
        changed_files: input.changed_files,
        top_k_symbols: top_k_symbols.clone(),
        file_sha_rollup: file_sha_rollup.clone(),
        index_version,
        issued_at_unix_ms,
    };
    ctx.put_token_with_sweep(
        context_token.clone(),
        normalized,
        Duration::from_secs(TTL_SECS),
    )
    .map_err(|e| format!("sem.context.top_k failed: {e}"))?;

    serde_json::to_value(TopKResponse {
        context_token,
        top_k_symbols,
        index_version,
        file_sha_rollup,
        issued_at_unix_ms,
        ttl_secs: TTL_SECS,
    })
    .map_err(|e| format!("sem.context.top_k failed: serialization: {e}"))
}

pub fn resolve_context_token(
    ctx: &ServerContext,
    context_token: &str,
) -> Result<NormalizedContext, String> {
    let token = context_token.trim();
    if token.is_empty() {
        return Err("sem.capsule failed: context_token is required".to_string());
    }
    let mut cache = ctx
        .token_cache
        .lock()
        .map_err(|_| "sem.capsule failed: token cache lock poisoned".to_string())?;
    let (normalized, issued_at) = cache.get(token).ok_or_else(|| {
        "sem.capsule failed: context_token not found; re-issue via sem.context.top_k".to_string()
    })?;
    if ctx.clock.now().duration_since(*issued_at).as_secs() >= TTL_SECS {
        return Err(
            "sem.capsule failed: context_token expired (issued_at + ttl < now); re-issue via sem.context.top_k"
                .to_string(),
        );
    }
    Ok(normalized.clone())
}

pub fn summarize_top_k(top_k_symbols: &[TopKEntry]) -> String {
    top_k_symbols
        .iter()
        .map(|entry| {
            format!(
                "{}\t{}\t{}\t{}",
                entry.qualified_name, entry.name, entry.file_path, entry.kind
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn normalize_input(ctx: &ServerContext, input: &Value) -> Result<TopKInput, String> {
    let obj = input
        .as_object()
        .ok_or("sem.context.top_k failed: arguments must be an object")?;
    let project_id = required_str(obj, "project_id", "sem.context.top_k")?;
    if project_id != ctx.project_id {
        return Err(format!(
            "sem.context.top_k failed: project_id mismatch: expected {}, received {project_id}",
            ctx.project_id
        ));
    }
    let task_id = required_str(obj, "task_id", "sem.context.top_k")?;
    let phase = required_str(obj, "phase", "sem.context.top_k")?;
    let changed_value = obj
        .get("changed_files")
        .ok_or("sem.context.top_k failed: changed_files is required")?;
    let changed_array = changed_value
        .as_array()
        .ok_or("sem.context.top_k failed: changed_files must be an array")?;
    if changed_array.is_empty() || changed_array.len() > 512 {
        return Err("sem.context.top_k failed: changed_files length must be 1..=512".to_string());
    }
    let mut changed_files = Vec::with_capacity(changed_array.len());
    for (idx, value) in changed_array.iter().enumerate() {
        let raw = value.as_str().ok_or_else(|| {
            format!("sem.context.top_k failed: changed_files[{idx}] must be a string")
        })?;
        changed_files.push(normalize_repo_relative_path(
            &ctx.repo_root,
            raw,
            &format!("changed_files[{idx}]"),
        )?);
    }
    changed_files.sort();
    changed_files.dedup();

    Ok(TopKInput {
        project_id,
        task_id,
        phase,
        changed_files,
        k: optional_usize(obj.get("k"), "k", 8, 1, 32)?,
        max_depth: optional_usize(obj.get("max_depth"), "max_depth", 3, 1, 5)? as u32,
        max_nodes: optional_usize(obj.get("max_nodes"), "max_nodes", 256, 1, 1024)? as u32,
    })
}

fn rank_top_k(
    ctx: &ServerContext,
    report: &tree_sitter_index::ImpactReport,
    fan_in: &[(tree_sitter_index::Symbol, u32)],
    k: usize,
) -> Result<Vec<TopKEntry>, String> {
    let mut fan_in_by_symbol = HashMap::new();
    for (symbol, count) in fan_in {
        fan_in_by_symbol.insert(symbol_key(symbol), *count);
    }

    let mut candidates = Vec::new();
    for symbol in &report.changed_symbols {
        candidates.push((symbol, 0_u32));
    }
    for symbol in &report.affected_symbols {
        candidates.push((symbol, 1_u32));
    }
    for (symbol, _) in fan_in {
        candidates.push((symbol, input_depth_for_fan_in(report)));
    }

    let mut by_key: HashMap<String, TopKEntry> = HashMap::new();
    let mut updated_at_by_file: HashMap<String, u64> = HashMap::new();
    let now_unix_ms = ctx.clock.now_unix_ms();
    for (symbol, depth) in candidates {
        let Some(repo_relative) = repo_relative_path(&ctx.repo_root, &symbol.file_path)? else {
            continue;
        };
        let key = symbol_key(symbol);
        let fan_count = *fan_in_by_symbol.get(&key).unwrap_or(&0);
        let updated_at_unix_ms =
            lookup_file_updated_at_unix_ms(ctx, &mut updated_at_by_file, &symbol.file_path)?;
        let recency = recency_score(updated_at_unix_ms, now_unix_ms);
        let score = compute_rank_score(depth, fan_count, recency, 0.0, &RankingWeights::TOP_K);
        let entry = TopKEntry {
            qualified_name: symbol
                .qualified_name
                .clone()
                .unwrap_or_else(|| symbol.name.clone()),
            name: symbol.name.clone(),
            file_path: repo_relative,
            kind: symbol.kind.to_string(),
            rank_score: (score * 1000.0).round() / 1000.0,
            rationale: format!("fan_in={fan_count},impact_depth={depth}"),
        };
        by_key
            .entry(key)
            .and_modify(|existing| {
                if entry.rank_score > existing.rank_score {
                    *existing = entry.clone();
                }
            })
            .or_insert(entry);
    }

    let mut entries = by_key.into_values().collect::<Vec<_>>();
    entries.sort_by(|a, b| {
        b.rank_score
            .partial_cmp(&a.rank_score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.file_path.cmp(&b.file_path))
            .then_with(|| a.qualified_name.cmp(&b.qualified_name))
            .then_with(|| a.name.cmp(&b.name))
    });
    entries.truncate(k);
    Ok(entries)
}

fn lookup_file_updated_at_unix_ms(
    ctx: &ServerContext,
    cache: &mut HashMap<String, u64>,
    file_path: &str,
) -> Result<u64, String> {
    if let Some(updated_at) = cache.get(file_path) {
        return Ok(*updated_at);
    }
    let updated_at: Option<i64> = ctx
        .conn
        .query_row(
            "SELECT MAX(updated_at_unix_ms)
             FROM file_parse_cache
             WHERE project_id = ?1 AND file_path = ?2",
            rusqlite::params![ctx.project_id, file_path],
            |row| row.get(0),
        )
        .map_err(|e| format!("sem.context.top_k failed: file_parse_cache recency read: {e}"))?;
    let updated_at = updated_at.unwrap_or(0).max(0) as u64;
    cache.insert(file_path.to_string(), updated_at);
    Ok(updated_at)
}

fn input_depth_for_fan_in(report: &tree_sitter_index::ImpactReport) -> u32 {
    if report.populated {
        report.depth.saturating_add(1)
    } else {
        1
    }
}

fn required_str(
    obj: &serde_json::Map<String, Value>,
    key: &str,
    tool: &str,
) -> Result<String, String> {
    obj.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{tool} failed: {key} is required"))
}

fn optional_usize(
    value: Option<&Value>,
    field: &str,
    default: usize,
    min: usize,
    max: usize,
) -> Result<usize, String> {
    let parsed = match value {
        None | Some(Value::Null) => default,
        Some(Value::Number(n)) => n
            .as_u64()
            .ok_or_else(|| format!("sem.context.top_k failed: {field} must be an integer"))?
            as usize,
        Some(Value::String(s)) => s
            .parse::<usize>()
            .map_err(|_| format!("sem.context.top_k failed: {field} must be an integer"))?,
        Some(_) => {
            return Err(format!(
                "sem.context.top_k failed: {field} must be an integer"
            ))
        }
    };
    if parsed < min || parsed > max {
        return Err(format!(
            "sem.context.top_k failed: {field} must be {min}..={max}"
        ));
    }
    Ok(parsed)
}

fn symbol_key(symbol: &tree_sitter_index::Symbol) -> String {
    format!(
        "{}\t{}\t{}\t{}",
        symbol
            .qualified_name
            .as_deref()
            .unwrap_or(symbol.name.as_str()),
        symbol.name,
        symbol.file_path,
        symbol.kind
    )
}

/// Return a repo-relative, forward-slash path for a stored `symbols.file_path`.
///
/// CRITICAL silent-drop guard (I-2 omission landmine): since the path flip,
/// `symbols.file_path` is stored REPO-RELATIVE. If this still only handled
/// absolute inputs (`strip_prefix(repo_root)` → `None` on a relative input),
/// rank_top_k would silently skip EVERY top-k symbol and break the capsule by
/// omission. So a relative input passes through unchanged; an absolute input is
/// still stripped for migration/back-compat; an absolute path outside the repo
/// root yields `None`.
fn repo_relative_path(repo_root: &Path, file_path: &str) -> Result<Option<String>, String> {
    let path = PathBuf::from(file_path);
    if path.is_relative() {
        // Already repo-relative (the post-flip storage form): pass through.
        return Ok(Some(path_to_forward_slashes(&path)));
    }
    let relative = match path.strip_prefix(repo_root) {
        Ok(relative) => relative,
        Err(_) => return Ok(None),
    };
    Ok(Some(path_to_forward_slashes(relative)))
}

fn path_to_forward_slashes(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn map_topk_freshness_error(error: FreshnessError) -> String {
    match error {
        FreshnessError::MissingCacheEntry(path) => {
            // Actionable, NOT lazy-index: indexing is edit-driven, so a changed
            // file that has not been Edit/Write-touched (i.e. stable source) has
            // no parse-cache row yet. Tell the caller exactly how to populate it
            // with the source-first bootstrap, and that the file is otherwise
            // picked up on the next orchestration iteration.
            format!(
                "sem.context.top_k failed: file_parse_cache miss for {path}. \
                 This file is not yet indexed (indexing is edit-driven; stable \
                 source that was not just edited is not covered). Run the \
                 source-first full reindex once: `agent-core context index-all \
                 --apply` from the repo root (or `scripts/semantic-bootstrap.sh \
                 --index-all`), then retry. Edited files are also indexed \
                 automatically on the next iteration."
            )
        }
        FreshnessError::InvalidIndexVersion(value) => {
            format!("sem.context.top_k failed: read index version: _ts_meta.index_version invalid: {value}")
        }
        other => format!("sem.context.top_k failed: freshness snapshot: {other}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn repo_relative_path_passes_through_already_relative_input() {
        // CRITICAL silent-drop guard: post path-flip, symbols.file_path is
        // stored repo-relative. A relative input must pass through unchanged so
        // rank_top_k does NOT skip the symbol (which would break the capsule by
        // omission).
        let repo_root = Path::new("/tmp/revh-test/project");
        let out = repo_relative_path(repo_root, "src/foo/bar.rs").unwrap();
        assert_eq!(out, Some("src/foo/bar.rs".to_string()));
    }

    #[test]
    fn repo_relative_path_strips_absolute_under_root_for_backcompat() {
        // Legacy/migration back-compat: an absolute path under the repo root is
        // still stripped to repo-relative.
        let repo_root = Path::new("/tmp/revh-test/project");
        let out =
            repo_relative_path(repo_root, "/tmp/revh-test/project/src/foo/bar.rs").unwrap();
        assert_eq!(out, Some("src/foo/bar.rs".to_string()));
    }

    #[test]
    fn repo_relative_path_drops_absolute_outside_root() {
        let repo_root = Path::new("/tmp/revh-test/project");
        let out = repo_relative_path(repo_root, "/etc/passwd").unwrap();
        assert_eq!(out, None);
    }
}
