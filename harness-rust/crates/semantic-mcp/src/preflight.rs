//! `sem.preflight` tool implementation.
//!
//! Validates planned semantic changes before applying updates:
//! checks target locks, detects ambiguity, duplicate risk, and delete impact.

use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::context::ServerContext;
use crate::util::{
    canonicalize_path_like, estimate_tokens, looks_like_path_target, normalize_path_like,
    normalize_repo_relative_path, path_matches_scope, paths_overlap, sanitize_value, sha256_hex,
    truncate,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const TOKEN_CHAR_RATIO: usize = 3;
const RESPONSE_TOKEN_BUDGET: usize = 220;
const RESPONSE_CHAR_BUDGET: usize = RESPONSE_TOKEN_BUDGET * TOKEN_CHAR_RATIO;
const CAPSULE_TOKEN_BUDGET: usize = 200;
const CAPSULE_CHAR_BUDGET: usize = CAPSULE_TOKEN_BUDGET * TOKEN_CHAR_RATIO;
const DELETE_SUMMARY_CHAR_BUDGET: usize = 360;
const OVERLAP_LOOKBACK_HOURS: u32 = 12;
const MAX_CONFLICTS: usize = 4;
const MAX_CONFLICT_REASON_LENGTH: usize = 72;
const MAX_ADJACENCY_LINE_CHARS: usize = 1024 * 1024;

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Signal for target_lock / ambiguity / duplicate_risk.
#[derive(Debug, Clone, Serialize)]
pub struct PreflightSignal {
    pub status: String,
    pub summary: String,
}

/// A single conflict found during preflight.
#[derive(Debug, Clone, Serialize)]
pub struct PreflightConflict {
    pub semantic_id: String,
    pub reason: String,
}

/// Dependency verdict passed through from the caller.
#[derive(Debug, Clone, Serialize)]
pub struct DependencyVerdict {
    pub status: String,
    pub issues: Vec<Value>,
    pub checked_at: String,
}

/// Response from `sem.preflight`.
#[derive(Debug, Serialize)]
pub struct PreflightResponse {
    pub verdict: String,
    pub conflicts: Vec<PreflightConflict>,
    pub delete_impacts_summary: String,
    pub capsule: String,
    pub target_lock: PreflightSignal,
    pub ambiguity: PreflightSignal,
    pub duplicate_risk: PreflightSignal,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dependency_verdict: Option<DependencyVerdict>,
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

struct NormalizedInput {
    #[allow(dead_code)]
    project_id: String,
    task_id: String,
    scope: Vec<String>,
    proposed_components: Vec<String>,
    deleted_paths: Vec<String>,
    removed_symbols: Vec<String>,
    move_candidates: Vec<(String, String)>,
    adjacency_path: Option<String>,
    dependency_verdict: Option<DependencyVerdict>,
}

struct ProposedTarget {
    semantic_id: String,
    name: String,
    target_path: Option<String>,
}

struct DeleteImpactAnalysis {
    reverse_dep: String,
    deleted_path_count: usize,
    removed_symbol_count: usize,
    deleted_symbol_count: usize,
    impact_count: usize,
    impacted_symbols: Vec<String>,
    reason: String,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute the `sem.preflight` tool.
pub fn handle_preflight(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let normalized = normalize_input(ctx, input)?;
    let proposed_targets = collect_proposed_targets(&normalized.proposed_components);

    // Find conflicts: existing components matching proposed_components.
    let mut conflicts = find_conflicts(ctx, &normalized.proposed_components)?;

    // Analyze target risks.
    let (target_lock, ambiguity, duplicate_risk, target_conflicts) =
        analyze_target_risks(ctx, &normalized, &proposed_targets)?;
    conflicts.extend(target_conflicts);
    conflicts = dedupe_conflicts(conflicts);

    let overlap_task_ids = find_scope_overlaps(ctx, &normalized.task_id, &normalized.scope)?;
    let lock_signals = detect_lock_signals();
    let delete_impact = analyze_delete_impacts(ctx, &normalized)?;
    let delete_impacts_summary =
        build_delete_impacts_summary(&delete_impact, &normalized.move_candidates);

    let verdict = resolve_verdict(
        !conflicts.is_empty(),
        !overlap_task_ids.is_empty(),
        !lock_signals.is_empty(),
        duplicate_risk.status == "warn",
    );

    let capsule = build_preflight_capsule(PreflightCapsuleInput {
        task_id: &normalized.task_id,
        verdict: &verdict,
        scope: &normalized.scope,
        conflicts: &conflicts,
        delete_impact: &delete_impact,
        overlap_task_ids: &overlap_task_ids,
        lock_signals: &lock_signals,
        target_lock: &target_lock,
        ambiguity: &ambiguity,
        duplicate_risk: &duplicate_risk,
        dependency_verdict: normalized.dependency_verdict.as_ref(),
    })?;

    persist_preflight_capsule(ctx, &normalized.task_id, &capsule, &normalized.scope)?;

    let mut response = PreflightResponse {
        verdict,
        conflicts: compact_conflicts(&conflicts),
        delete_impacts_summary: truncate(&delete_impacts_summary, DELETE_SUMMARY_CHAR_BUDGET),
        capsule,
        target_lock,
        ambiguity,
        duplicate_risk,
        dependency_verdict: normalized.dependency_verdict.clone(),
    };

    enforce_response_budget(&mut response)?;

    serde_json::to_value(response).map_err(|e| format!("sem.preflight failed: serialization: {e}"))
}

// ---------------------------------------------------------------------------
// Input normalization
// ---------------------------------------------------------------------------

fn normalize_input(ctx: &ServerContext, input: &Value) -> Result<NormalizedInput, String> {
    let obj = input
        .as_object()
        .ok_or("sem.preflight failed: arguments must be an object")?;

    let project_id = obj
        .get("project_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.preflight failed: project_id is required")?;

    if project_id != ctx.project_id {
        return Err(format!(
            "sem.preflight failed: project_id mismatch: expected {}, received {project_id}",
            ctx.project_id
        ));
    }

    let task_id = obj
        .get("task_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.preflight failed: task_id is required")?;

    let scope = normalize_string_array(obj.get("scope"), "scope")?;
    let scope = normalize_path_list(scope);
    let proposed_components =
        normalize_string_array(obj.get("proposed_components"), "proposed_components")?;
    let deleted_paths = normalize_optional_string_array(obj.get("deleted_paths"), "deleted_paths")?;
    let deleted_paths = normalize_path_list(deleted_paths);
    let removed_symbols =
        normalize_optional_string_array(obj.get("removed_symbols"), "removed_symbols")?;

    let move_candidates = normalize_move_candidates(obj.get("move_candidates"))?;
    let adjacency_path = match obj.get("adjacency_path") {
        None | Some(Value::Null) => None,
        Some(Value::String(path)) => Some(normalize_repo_relative_path(
            &ctx.repo_root,
            path,
            "adjacency_path",
        )?),
        Some(_) => return Err("sem.preflight failed: adjacency_path must be a string".into()),
    };

    let dependency_verdict = normalize_dependency_verdict(obj.get("dependency_verdict"))?;

    Ok(NormalizedInput {
        project_id,
        task_id,
        scope,
        proposed_components,
        deleted_paths,
        removed_symbols,
        move_candidates,
        adjacency_path,
        dependency_verdict,
    })
}

fn normalize_path_list(values: Vec<String>) -> Vec<String> {
    let mut result = Vec::new();
    let mut seen = HashSet::new();

    for value in values {
        let normalized = canonicalize_path_like(&value);
        if !normalized.is_empty() && seen.insert(normalized.clone()) {
            result.push(normalized);
        }
    }

    result
}

fn normalize_string_array(value: Option<&Value>, field: &str) -> Result<Vec<String>, String> {
    let arr = value
        .and_then(|v| v.as_array())
        .ok_or_else(|| format!("sem.preflight failed: {field} must be string[]"))?;
    let mut result: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for (i, item) in arr.iter().enumerate() {
        let s = item
            .as_str()
            .ok_or_else(|| format!("sem.preflight failed: {field}[{i}] must be a string"))?;
        let trimmed = s.trim();
        if trimmed.is_empty() {
            return Err(format!(
                "sem.preflight failed: {field}[{i}] must not be empty"
            ));
        }
        if seen.insert(trimmed.to_string()) {
            result.push(trimmed.to_string());
        }
    }
    Ok(result)
}

fn normalize_optional_string_array(
    value: Option<&Value>,
    field: &str,
) -> Result<Vec<String>, String> {
    match value {
        None => Ok(Vec::new()),
        Some(Value::Null) => Err(format!("sem.preflight failed: {field} must be string[]")),
        Some(v) => normalize_string_array(Some(v), field),
    }
}

fn normalize_move_candidates(value: Option<&Value>) -> Result<Vec<(String, String)>, String> {
    match value {
        None => Ok(Vec::new()),
        Some(Value::Null) => Err("move_candidates must be an array".into()),
        Some(Value::Array(arr)) => {
            let mut result = Vec::new();
            for (i, item) in arr.iter().enumerate() {
                let obj = item
                    .as_object()
                    .ok_or_else(|| format!("move_candidates[{i}] must be an object"))?;
                let old_path = obj
                    .get("old_path")
                    .and_then(|v| v.as_str())
                    .map(canonicalize_path_like)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| format!("move_candidates[{i}].old_path is required"))?;
                let new_path = obj
                    .get("new_path")
                    .and_then(|v| v.as_str())
                    .map(canonicalize_path_like)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| format!("move_candidates[{i}].new_path is required"))?;
                result.push((old_path, new_path));
            }
            Ok(result)
        }
        _ => Err("move_candidates must be an array".into()),
    }
}

fn normalize_dependency_verdict(
    value: Option<&Value>,
) -> Result<Option<DependencyVerdict>, String> {
    match value {
        None => Ok(None),
        Some(Value::Null) => Err("dependency_verdict must be an object".into()),
        Some(v) => {
            let obj = v
                .as_object()
                .ok_or("dependency_verdict must be an object")?;
            let status = obj
                .get("status")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .ok_or("dependency_verdict.status is required")?;
            let issues = obj
                .get("issues")
                .and_then(|v| v.as_array())
                .cloned()
                .ok_or("dependency_verdict.issues is required")?;
            let checked_at = obj
                .get("checked_at")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .ok_or("dependency_verdict.checked_at is required")?;
            Ok(Some(DependencyVerdict {
                status,
                issues: issues.into_iter().collect(),
                checked_at,
            }))
        }
    }
}

// ---------------------------------------------------------------------------
// Conflict detection
// ---------------------------------------------------------------------------

fn find_conflicts(
    ctx: &ServerContext,
    proposed: &[String],
) -> Result<Vec<PreflightConflict>, String> {
    let mut conflicts: Vec<PreflightConflict> = Vec::new();

    // Check for duplicates in proposed list.
    let mut seen = HashSet::new();
    let mut dupes = HashSet::new();
    for sid in proposed {
        if !seen.insert(sid.clone()) {
            dupes.insert(sid.clone());
        }
    }
    for sid in &dupes {
        conflicts.push(PreflightConflict {
            semantic_id: sid.clone(),
            reason: "duplicate_proposed_component".to_string(),
        });
    }

    if proposed.is_empty() {
        return Ok(conflicts);
    }

    // Check existing components.
    let placeholders: Vec<String> = (0..proposed.len()).map(|i| format!("?{}", i + 2)).collect();
    let sql = format!(
        "SELECT semantic_id, status FROM components
         WHERE project_id = ?1 AND semantic_id IN ({}) AND status != 'deleted'",
        placeholders.join(", ")
    );
    let mut stmt = ctx
        .conn
        .prepare(&sql)
        .map_err(|e| format!("sem.preflight failed: {e}"))?;

    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(ctx.project_id.clone())];
    for sid in proposed {
        params.push(Box::new(sid.clone()));
    }
    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    let rows = stmt
        .query_map(param_refs.as_slice(), |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| format!("sem.preflight failed: {e}"))?;

    for row in rows {
        let (sid, status) = row.map_err(|e| format!("sem.preflight failed: {e}"))?;
        conflicts.push(PreflightConflict {
            semantic_id: sid,
            reason: format!("already_exists:{status}"),
        });
    }

    Ok(dedupe_conflicts(conflicts))
}

// ---------------------------------------------------------------------------
// Target risk analysis
// ---------------------------------------------------------------------------

fn analyze_target_risks(
    ctx: &ServerContext,
    input: &NormalizedInput,
    proposed_targets: &[ProposedTarget],
) -> Result<
    (
        PreflightSignal,
        PreflightSignal,
        PreflightSignal,
        Vec<PreflightConflict>,
    ),
    String,
> {
    if proposed_targets.is_empty() {
        return Ok((
            PreflightSignal {
                status: "none".into(),
                summary: "none".into(),
            },
            PreflightSignal {
                status: "none".into(),
                summary: "none".into(),
            },
            PreflightSignal {
                status: "none".into(),
                summary: "none".into(),
            },
            Vec::new(),
        ));
    }

    let scope_paths = input.scope.iter().map(String::as_str).collect::<Vec<_>>();
    let move_target_set: HashSet<String> = input
        .move_candidates
        .iter()
        .map(|(_, new)| normalize_path_like(new))
        .collect();

    let lockable_count = proposed_targets
        .iter()
        .filter(|t| t.target_path.is_some())
        .count();
    let mut target_lock_signals: Vec<String> = Vec::new();
    let ambiguity_signals: Vec<String> = Vec::new();
    let mut duplicate_signals: Vec<String> = Vec::new();
    let mut conflicts: Vec<PreflightConflict> = Vec::new();

    for target in proposed_targets {
        // Target lock check.
        if let Some(tp) = &target.target_path {
            let norm_tp = normalize_path_like(tp);
            if scope_paths.is_empty() {
                target_lock_signals.push(format!(
                    "{}->{}",
                    target.semantic_id,
                    truncate(&norm_tp, 32)
                ));
                conflicts.push(PreflightConflict {
                    semantic_id: target.semantic_id.clone(),
                    reason: format!("target_lock_scope_missing:{}", truncate(&norm_tp, 40)),
                });
            } else if !scope_paths
                .iter()
                .any(|scope| path_matches_scope(&norm_tp, scope))
                && !move_target_set.contains(&norm_tp)
            {
                target_lock_signals.push(format!(
                    "{}->{}",
                    target.semantic_id,
                    truncate(&norm_tp, 32)
                ));
                conflicts.push(PreflightConflict {
                    semantic_id: target.semantic_id.clone(),
                    reason: format!("target_lock_scope_mismatch:{}", truncate(&norm_tp, 40)),
                });
            }
        }

        // Duplicate risk: check if name exists under a different semantic_id.
        let mut stmt = ctx
            .conn
            .prepare(
                "SELECT semantic_id, file_path FROM components
                 WHERE project_id = ?1 AND name = ?2 AND semantic_id != ?3 AND status != 'deleted'
                 ORDER BY updated_at DESC, semantic_id ASC",
            )
            .map_err(|e| format!("preflight: {e}"))?;
        let rows: Vec<(String, String)> = stmt
            .query_map(
                rusqlite::params![ctx.project_id, target.name, target.semantic_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| format!("preflight: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        if !rows.is_empty() {
            let sample: Vec<String> = rows
                .iter()
                .take(2)
                .map(|(_, fp)| truncate(&normalize_path_like(fp), 24))
                .collect();
            let signal = format!("{}@{}", target.name, sample.join("|"));
            duplicate_signals.push(signal.clone());
        }
    }

    let tl_status = if !target_lock_signals.is_empty() {
        "blocked"
    } else if lockable_count > 0 {
        "clear"
    } else {
        "none"
    };

    let amb_status = if !ambiguity_signals.is_empty() {
        "blocked"
    } else {
        "none"
    };

    let dup_status = if !ambiguity_signals.is_empty() {
        "blocked"
    } else if !duplicate_signals.is_empty() {
        "warn"
    } else {
        "none"
    };

    Ok((
        build_signal(
            tl_status,
            &target_lock_signals,
            if lockable_count > 0 { "clear" } else { "none" },
        ),
        build_signal(amb_status, &ambiguity_signals, "none"),
        build_signal(
            dup_status,
            &[ambiguity_signals.clone(), duplicate_signals].concat(),
            "none",
        ),
        dedupe_conflicts(conflicts),
    ))
}

fn collect_proposed_targets(proposed: &[String]) -> Vec<ProposedTarget> {
    proposed
        .iter()
        .map(|sid| {
            let sep = sid.find(':');
            let module_segment = match sep {
                Some(idx) => &sid[..idx],
                None => sid,
            };
            let symbol_name = match sep {
                Some(idx) if idx < sid.len() - 1 => &sid[idx + 1..],
                _ => sid,
            };
            let target_path = if looks_like_path_target(module_segment) {
                Some(canonicalize_path_like(module_segment))
            } else {
                None
            };
            ProposedTarget {
                semantic_id: sid.clone(),
                name: symbol_name.to_string(),
                target_path,
            }
        })
        .collect()
}

fn build_signal(status: &str, values: &[String], empty_summary: &str) -> PreflightSignal {
    if values.is_empty() {
        return PreflightSignal {
            status: status.to_string(),
            summary: empty_summary.to_string(),
        };
    }
    PreflightSignal {
        status: status.to_string(),
        summary: truncate(
            &values.iter().take(2).cloned().collect::<Vec<_>>().join(","),
            120,
        ),
    }
}

// ---------------------------------------------------------------------------
// Scope overlap detection
// ---------------------------------------------------------------------------

fn find_scope_overlaps(
    ctx: &ServerContext,
    task_id: &str,
    scope: &[String],
) -> Result<Vec<String>, String> {
    if scope.is_empty() {
        return Ok(Vec::new());
    }

    let sql = format!(
        "SELECT task_id, content FROM capsules
         WHERE project_id = ?1 AND phase = 'preflight' AND task_id != ?2
           AND created_at >= datetime('now', '-{OVERLAP_LOOKBACK_HOURS} hours')
         ORDER BY created_at DESC LIMIT 50"
    );
    let mut stmt = ctx
        .conn
        .prepare(&sql)
        .map_err(|e| format!("preflight overlap: {e}"))?;
    let rows = stmt
        .query_map(rusqlite::params![ctx.project_id, task_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| format!("preflight overlap: {e}"))?;

    let mut overlap_ids = HashSet::new();
    for row in rows {
        let (tid, content) = row.map_err(|e| format!("preflight: {e}"))?;
        let prior_scope = extract_scope_from_capsule(&content);
        if prior_scope
            .iter()
            .any(|prior| scope.iter().any(|current| paths_overlap(prior, current)))
        {
            overlap_ids.insert(tid);
        }
    }

    Ok(overlap_ids.into_iter().collect())
}

fn extract_scope_from_capsule(capsule: &str) -> Vec<String> {
    for line in capsule.lines() {
        if let Some(raw) = line.strip_prefix("SCOPE=") {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                return Vec::new();
            }
            return trimmed
                .split('|')
                .map(canonicalize_path_like)
                .filter(|s| !s.is_empty())
                .collect();
        }
    }
    Vec::new()
}

// ---------------------------------------------------------------------------
// Lock signal detection
// ---------------------------------------------------------------------------

fn detect_lock_signals() -> Vec<String> {
    let candidates = [
        ".agent/registry/.lock",
        ".agent/.lock",
        ".claude/tmp/review_queue.lock",
    ];
    candidates
        .iter()
        .filter(|p| Path::new(p).exists())
        .map(|p| p.to_string())
        .collect()
}

// ---------------------------------------------------------------------------
// Delete impact analysis
// ---------------------------------------------------------------------------

fn analyze_delete_impacts(
    ctx: &ServerContext,
    input: &NormalizedInput,
) -> Result<DeleteImpactAnalysis, String> {
    let moved_old: HashSet<&str> = input
        .move_candidates
        .iter()
        .map(|(old, _)| old.as_str())
        .collect();
    let effective_deleted: Vec<&str> = input
        .deleted_paths
        .iter()
        .filter(|p| !moved_old.contains(p.as_str()))
        .map(|s| s.as_str())
        .collect();

    let mut deleted_symbol_ids: HashSet<String> = input.removed_symbols.iter().cloned().collect();

    if !effective_deleted.is_empty() {
        let placeholders: Vec<String> = (0..effective_deleted.len())
            .map(|i| format!("?{}", i + 2))
            .collect();
        let sql = format!(
            "SELECT semantic_id FROM components
             WHERE project_id = ?1 AND file_path IN ({})",
            placeholders.join(", ")
        );
        let mut stmt = ctx
            .conn
            .prepare(&sql)
            .map_err(|e| format!("preflight: {e}"))?;
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> =
            vec![Box::new(ctx.project_id.clone())];
        for p in &effective_deleted {
            params.push(Box::new(p.to_string()));
        }
        let param_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        let rows = stmt
            .query_map(param_refs.as_slice(), |row| row.get::<_, String>(0))
            .map_err(|e| format!("preflight: {e}"))?;
        for sid in rows.flatten() {
            deleted_symbol_ids.insert(sid);
        }
    }

    let deleted_symbols: Vec<String> = deleted_symbol_ids.into_iter().collect();
    if effective_deleted.is_empty() && deleted_symbols.is_empty() {
        return Ok(DeleteImpactAnalysis {
            reverse_dep: "skipped".into(),
            deleted_path_count: 0,
            removed_symbol_count: input.removed_symbols.len(),
            deleted_symbol_count: 0,
            impact_count: 0,
            impacted_symbols: Vec::new(),
            reason: "no_delete_signals".into(),
        });
    }

    let adjacency_path = match &input.adjacency_path {
        None => {
            return Ok(DeleteImpactAnalysis {
                reverse_dep: "unavailable".into(),
                deleted_path_count: effective_deleted.len(),
                removed_symbol_count: input.removed_symbols.len(),
                deleted_symbol_count: deleted_symbols.len(),
                impact_count: 0,
                impacted_symbols: Vec::new(),
                reason: "adjacency_not_provided".into(),
            });
        }
        Some(p) => p.clone(),
    };

    let absolute_adjacency_path = ctx.repo_root.join(&adjacency_path);
    if !absolute_adjacency_path.exists() {
        return Ok(DeleteImpactAnalysis {
            reverse_dep: "unavailable".into(),
            deleted_path_count: effective_deleted.len(),
            removed_symbol_count: input.removed_symbols.len(),
            deleted_symbol_count: deleted_symbols.len(),
            impact_count: 0,
            impacted_symbols: Vec::new(),
            reason: "adjacency_missing".into(),
        });
    }

    let target_set: HashSet<&str> = deleted_symbols.iter().map(|s| s.as_str()).collect();
    let mut impacted = HashSet::new();

    stream_adjacency_rows(&absolute_adjacency_path, |parsed, _line_number| {
        let source = parsed
            .get("source_logical_id")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty());
        let target = parsed
            .get("target_logical_id")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty());
        match (source, target) {
            (Some(src), Some(tgt)) => {
                if target_set.contains(tgt) && !target_set.contains(src) {
                    impacted.insert(src.to_string());
                }
            }
            _ => return Err("malformed adjacency row".to_string()),
        }
        Ok(())
    })?;

    Ok(DeleteImpactAnalysis {
        reverse_dep: "available".into(),
        deleted_path_count: effective_deleted.len(),
        removed_symbol_count: input.removed_symbols.len(),
        deleted_symbol_count: deleted_symbols.len(),
        impact_count: impacted.len(),
        impacted_symbols: impacted.into_iter().collect(),
        reason: "ok".into(),
    })
}

fn stream_adjacency_rows<F>(path: &Path, mut on_row: F) -> Result<(), String>
where
    F: FnMut(Value, usize) -> Result<(), String>,
{
    let file = File::open(path)
        .map_err(|e| format!("preflight adjacency failed: failed to open adjacency_path: {e}"))?;
    let mut reader = BufReader::new(file);
    let mut pending = Vec::new();
    let mut line_number = 0usize;

    loop {
        let (consumed, complete_line) = {
            let available = reader.fill_buf().map_err(|e| {
                format!("preflight adjacency failed: failed to read adjacency chunk: {e}")
            })?;
            if available.is_empty() {
                break;
            }
            if let Some(newline_index) = available.iter().position(|byte| *byte == b'\n') {
                append_adjacency_bytes(&mut pending, &available[..newline_index])?;
                (newline_index + 1, Some(std::mem::take(&mut pending)))
            } else {
                append_adjacency_bytes(&mut pending, available)?;
                (available.len(), None)
            }
        };
        reader.consume(consumed);
        if let Some(line) = complete_line {
            line_number += 1;
            parse_adjacency_line(&line, line_number, &mut on_row)?;
        }
    }

    if !pending.is_empty() {
        line_number += 1;
        parse_adjacency_line(&pending, line_number, &mut on_row)?;
    }

    Ok(())
}

fn append_adjacency_bytes(pending: &mut Vec<u8>, chunk: &[u8]) -> Result<(), String> {
    if pending.len().saturating_add(chunk.len()) > MAX_ADJACENCY_LINE_CHARS {
        return Err(format!(
            "adjacency line exceeds {MAX_ADJACENCY_LINE_CHARS} characters"
        ));
    }
    pending.extend_from_slice(chunk);
    Ok(())
}

fn parse_adjacency_line<F>(bytes: &[u8], line_number: usize, on_row: &mut F) -> Result<(), String>
where
    F: FnMut(Value, usize) -> Result<(), String>,
{
    let line_without_newline = match bytes.strip_suffix(b"\r") {
        Some(stripped) => stripped,
        None => bytes,
    };
    if line_without_newline.len() > MAX_ADJACENCY_LINE_CHARS {
        return Err(format!(
            "adjacency line exceeds {MAX_ADJACENCY_LINE_CHARS} characters"
        ));
    }

    let line = std::str::from_utf8(line_without_newline)
        .map_err(|e| format!("malformed adjacency JSON at line {line_number}: {e}"))?;
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(());
    }

    let parsed: Value = serde_json::from_str(trimmed)
        .map_err(|e| format!("malformed adjacency JSON at line {line_number}: {e}"))?;
    if !parsed.is_object() {
        return Err(format!("malformed adjacency row at line {line_number}"));
    }
    on_row(parsed, line_number).map_err(|e| format!("{e} at line {line_number}"))
}

fn build_delete_impacts_summary(
    analysis: &DeleteImpactAnalysis,
    move_candidates: &[(String, String)],
) -> String {
    let mut parts = vec![
        format!("del_paths={}", analysis.deleted_path_count),
        format!("rm_syms={}", analysis.removed_symbol_count),
        format!("deleted_ids={}", analysis.deleted_symbol_count),
        format!("reverse_dep={}", analysis.reverse_dep),
        format!("impacts={}", analysis.impact_count),
    ];

    if !move_candidates.is_empty() {
        parts.push(format!("moves={}", move_candidates.len()));
    }

    if !analysis.impacted_symbols.is_empty() {
        let sample: Vec<String> = analysis
            .impacted_symbols
            .iter()
            .take(3)
            .map(|s| truncate(s, 40))
            .collect();
        parts.push(format!("sample={}", sample.join("|")));
    }

    if analysis.reverse_dep != "available" {
        parts.push(format!("reason={}", analysis.reason));
    }

    truncate(&parts.join(" "), DELETE_SUMMARY_CHAR_BUDGET)
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

fn resolve_verdict(
    has_conflicts: bool,
    has_overlap: bool,
    has_locks: bool,
    has_dup_warning: bool,
) -> String {
    if has_conflicts {
        return "BLOCK".to_string();
    }
    if has_overlap || has_locks || has_dup_warning {
        return "WARN".to_string();
    }
    "PASS".to_string()
}

// ---------------------------------------------------------------------------
// Capsule building
// ---------------------------------------------------------------------------

struct PreflightCapsuleInput<'a> {
    task_id: &'a str,
    verdict: &'a str,
    scope: &'a [String],
    conflicts: &'a [PreflightConflict],
    delete_impact: &'a DeleteImpactAnalysis,
    overlap_task_ids: &'a [String],
    lock_signals: &'a [String],
    target_lock: &'a PreflightSignal,
    ambiguity: &'a PreflightSignal,
    duplicate_risk: &'a PreflightSignal,
    dependency_verdict: Option<&'a DependencyVerdict>,
}

fn build_preflight_capsule(input: PreflightCapsuleInput<'_>) -> Result<String, String> {
    let mut warning_signals: Vec<String> = Vec::new();
    if !input.overlap_task_ids.is_empty() {
        let sample: Vec<&str> = input
            .overlap_task_ids
            .iter()
            .take(3)
            .map(|s| s.as_str())
            .collect();
        warning_signals.push(format!("overlap:{}", sample.join("|")));
    }
    if !input.lock_signals.is_empty() {
        let sample: Vec<&str> = input
            .lock_signals
            .iter()
            .take(2)
            .map(|s| s.as_str())
            .collect();
        warning_signals.push(format!("lock:{}", sample.join("|")));
    }

    let scope_hash = sha256_hex(&input.scope.join("\n"));
    let dep_status = input
        .dependency_verdict
        .map(|d| d.status.as_str())
        .unwrap_or("none");

    let mut lines = vec![
        format!("TASK={}", sanitize_value(input.task_id)),
        "PHASE=preflight".to_string(),
        format!("VERDICT={}", input.verdict),
        format!("SCOPE_COUNT={}", input.scope.len()),
        format!("SCOPE_SHA256={scope_hash}"),
        format!("CONFLICT_COUNT={}", input.conflicts.len()),
        format!("IMPACT_COUNT={}", input.delete_impact.impact_count),
        format!("TARGET_LOCK={}", sanitize_value(&input.target_lock.status)),
        format!("AMBIGUITY={}", sanitize_value(&input.ambiguity.status)),
        format!(
            "DUPLICATE_RISK={}",
            sanitize_value(&input.duplicate_risk.status)
        ),
        format!("DEP_STATUS={dep_status}"),
    ];
    if !warning_signals.is_empty() {
        lines.push(format!(
            "WARNINGS={}",
            sanitize_value(&warning_signals.join(","))
        ));
    }

    // Trim to budget.
    trim_capsule_lines(&mut lines)?;
    Ok(with_capsule_hash(&lines))
}

fn trim_capsule_lines(lines: &mut Vec<String>) -> Result<(), String> {
    let trim_order = [
        "other",
        "task_id",
        "delete_impacts",
        "conflicts",
        "warnings",
    ];

    while with_capsule_hash(lines).len() > CAPSULE_CHAR_BUDGET {
        let mut changed = false;
        for class in &trim_order {
            if *class == "warnings" {
                if let Some(idx) = find_line_by_class(lines, class) {
                    if lines[idx] != "WARNINGS=truncated" {
                        lines[idx] = "WARNINGS=truncated".to_string();
                        changed = true;
                        break;
                    }
                }
                continue;
            }
            if let Some(idx) = find_line_by_class(lines, class) {
                lines.remove(idx);
                changed = true;
                break;
            }
        }
        if !changed {
            break;
        }
    }

    if with_capsule_hash(lines).len() > CAPSULE_CHAR_BUDGET {
        return Err("preflight capsule exceeded 200-token budget".to_string());
    }

    Ok(())
}

fn find_line_by_class(lines: &[String], class: &str) -> Option<usize> {
    (0..lines.len())
        .rev()
        .find(|&i| classify_line(&lines[i]) == class)
}

fn classify_line(line: &str) -> &'static str {
    if line.starts_with("VERDICT=") {
        return "verdict";
    }
    if line.starts_with("TARGET_LOCK=")
        || line.starts_with("AMBIGUITY=")
        || line.starts_with("DUPLICATE_RISK=")
    {
        return "signal";
    }
    if line.starts_with("WARNINGS=") {
        return "warnings";
    }
    if line.starts_with("CONFLICT_COUNT=") || line.starts_with("CONFLICTS=") {
        return "conflicts";
    }
    if line.starts_with("IMPACT_COUNT=") || line.starts_with("DELETE_IMPACTS=") {
        return "delete_impacts";
    }
    if line.starts_with("TASK=") || line.starts_with("TASK_ID=") {
        return "task_id";
    }
    "other"
}

fn with_capsule_hash(lines: &[String]) -> String {
    let body = lines.join("\n");
    let hash = sha256_hex(&body);
    format!("{body}\nCAPSULE_SHA256={hash}")
}

fn persist_preflight_capsule(
    ctx: &ServerContext,
    task_id: &str,
    capsule: &str,
    scope: &[String],
) -> Result<(), String> {
    let scope_storage: Vec<String> = scope.iter().map(|s| canonicalize_path_like(s)).collect();
    let storage_capsule = format!("{capsule}\nSCOPE={}", scope_storage.join("|"));
    let token_count = estimate_tokens(&storage_capsule);

    ctx.conn
        .execute(
            "INSERT INTO capsules (project_id, task_id, phase, content, token_count, created_at)
             VALUES (?1, ?2, 'preflight', ?3, ?4, datetime('now'))",
            rusqlite::params![ctx.project_id, task_id, storage_capsule, token_count],
        )
        .map_err(|e| format!("persist capsule failed: {e}"))?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn compact_conflicts(conflicts: &[PreflightConflict]) -> Vec<PreflightConflict> {
    conflicts
        .iter()
        .take(MAX_CONFLICTS)
        .map(|c| PreflightConflict {
            semantic_id: c.semantic_id.clone(),
            reason: truncate(&c.reason, MAX_CONFLICT_REASON_LENGTH),
        })
        .collect()
}

fn dedupe_conflicts(conflicts: Vec<PreflightConflict>) -> Vec<PreflightConflict> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for c in conflicts {
        let key = format!("{}|{}", c.semantic_id, c.reason);
        if seen.insert(key) {
            result.push(c);
        }
    }
    result
}

fn enforce_response_budget(response: &mut PreflightResponse) -> Result<(), String> {
    // Iteratively compact until within budget.
    for _ in 0..20 {
        let json =
            serde_json::to_string(response).map_err(|e| format!("serialization error: {e}"))?;
        if json.len() <= RESPONSE_CHAR_BUDGET {
            return Ok(());
        }

        // Try trimming in order.
        if response.duplicate_risk.summary.len() > 32 {
            response.duplicate_risk.summary = truncate(&response.duplicate_risk.summary, 32);
            continue;
        }
        if response.ambiguity.summary.len() > 32 {
            response.ambiguity.summary = truncate(&response.ambiguity.summary, 32);
            continue;
        }
        if response.target_lock.summary.len() > 32 {
            response.target_lock.summary = truncate(&response.target_lock.summary, 32);
            continue;
        }
        if response.delete_impacts_summary.len() > 80 {
            response.delete_impacts_summary = truncate(&response.delete_impacts_summary, 80);
            continue;
        }
        if response.delete_impacts_summary.len() > 32 {
            response.delete_impacts_summary = truncate(&response.delete_impacts_summary, 32);
            continue;
        }
        if !response.conflicts.is_empty() {
            response.conflicts.pop();
            continue;
        }

        return Err("sem.preflight failed: preflight response exceeded 220-token budget".into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::ServerContext;
    use rusqlite::Connection;

    type TestContext = ServerContext;

    fn test_ctx(project_id: &str) -> TestContext {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
        ServerContext::new(
            conn,
            project_id.to_string(),
            std::env::current_dir().unwrap(),
        )
    }

    fn test_ctx_with_repo_root(project_id: &str, repo_root: std::path::PathBuf) -> TestContext {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
        ServerContext::new(conn, project_id.to_string(), repo_root)
    }

    fn unique_temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "semantic-mcp-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    fn basic_preflight_input(project_id: &str, task_id: &str) -> Value {
        serde_json::json!({
            "project_id": project_id,
            "task_id": task_id,
            "scope": ["src/foo.rs"],
            "proposed_components": ["mod:foo"],
        })
    }

    #[test]
    fn test_preflight_pass_no_conflicts() {
        let ctx = test_ctx("proj1");
        let input = basic_preflight_input("proj1", "task-1");
        let result = handle_preflight(&ctx, &input).unwrap();
        assert_eq!(result["verdict"], "PASS");
        assert!(result["conflicts"].as_array().unwrap().is_empty());
    }

    #[test]
    fn test_preflight_empty_proposed_components() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": [],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        assert_eq!(result["verdict"], "PASS");
    }

    #[test]
    fn test_preflight_existing_component_conflict() {
        let ctx = test_ctx("proj1");
        // Insert a component first
        let upsert_input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:foo",
                "file_path": "src/foo.rs",
                "kind": "function",
            }]
        });
        crate::registry::handle_upsert(&ctx, &upsert_input).unwrap();

        // Now preflight with the same proposed_component
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": ["mod:foo"],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        assert_eq!(result["verdict"], "BLOCK");
        let conflicts = result["conflicts"].as_array().unwrap();
        assert!(!conflicts.is_empty());
    }

    #[test]
    fn test_preflight_missing_project_id_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": [],
        });
        let result = handle_preflight(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("project_id"));
    }

    #[test]
    fn test_preflight_missing_task_id_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "scope": ["src/foo.rs"],
            "proposed_components": [],
        });
        let result = handle_preflight(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("task_id"));
    }

    #[test]
    fn test_preflight_project_id_mismatch_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "wrong",
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": [],
        });
        let result = handle_preflight(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("mismatch"));
    }

    #[test]
    fn test_preflight_capsule_contains_verdict() {
        let ctx = test_ctx("proj1");
        let input = basic_preflight_input("proj1", "task-1");
        let result = handle_preflight(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("VERDICT=PASS"));
    }

    #[test]
    fn test_preflight_capsule_contains_sha256() {
        let ctx = test_ctx("proj1");
        let input = basic_preflight_input("proj1", "task-1");
        let result = handle_preflight(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("CAPSULE_SHA256="));
    }

    #[test]
    fn test_preflight_persists_capsule_to_db() {
        let ctx = test_ctx("proj1");
        let input = basic_preflight_input("proj1", "task-1");
        handle_preflight(&ctx, &input).unwrap();

        let exists: i64 = ctx
            .conn
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM capsules
                    WHERE project_id = 'proj1' AND phase = 'preflight'
                 )",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(exists, 1);
    }

    #[test]
    fn test_preflight_delete_impacts_empty() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": ["mod:foo"],
            "deleted_paths": [],
            "removed_symbols": [],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        let summary = result["delete_impacts_summary"].as_str().unwrap();
        assert!(summary.contains("del_paths=0"));
    }

    #[test]
    fn test_preflight_with_deleted_paths() {
        let ctx = test_ctx("proj1");
        // Upsert a component first
        let upsert = serde_json::json!({
            "components": [{
                "semantic_id": "mod:old",
                "file_path": "src/old.rs",
                "kind": "function",
            }]
        });
        crate::registry::handle_upsert(&ctx, &upsert).unwrap();

        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/new.rs"],
            "proposed_components": ["mod:new"],
            "deleted_paths": ["src/old.rs"],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        let summary = result["delete_impacts_summary"].as_str().unwrap();
        assert!(summary.contains("del_paths=1"));
    }

    #[test]
    fn preflight_streams_adjacency_and_fails_on_malformed_json() {
        let repo_root = unique_temp_dir("preflight-streams");
        std::fs::write(
            repo_root.join("adjacency.jsonl"),
            r#"{"source_logical_id":"mod:caller","target_logical_id":"mod:old"}"#,
        )
        .unwrap();
        let ctx = test_ctx_with_repo_root("proj1", repo_root.clone());
        crate::registry::handle_upsert(
            &ctx,
            &serde_json::json!({
                "components": [{
                    "semantic_id": "mod:old",
                    "file_path": "src/old.rs",
                    "kind": "function"
                }]
            }),
        )
        .unwrap();

        let ok = handle_preflight(
            &ctx,
            &serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": ["src/old.rs"],
                "adjacency_path": "adjacency.jsonl"
            }),
        )
        .unwrap();
        assert!(ok["delete_impacts_summary"]
            .as_str()
            .unwrap()
            .contains("impacts=1"));

        std::fs::write(
            repo_root.join("malformed.jsonl"),
            "{\"source_logical_id\":\n",
        )
        .unwrap();
        let malformed = handle_preflight(
            &ctx,
            &serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-2",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new2"],
                "deleted_paths": ["src/old.rs"],
                "adjacency_path": "malformed.jsonl"
            }),
        );
        assert!(malformed.is_err());
        assert!(malformed.unwrap_err().contains("malformed adjacency JSON"));
    }

    #[test]
    fn preflight_rejects_missing_adjacency_fields() {
        let repo_root = unique_temp_dir("preflight-missing-fields");
        std::fs::write(
            repo_root.join("adjacency.jsonl"),
            r#"{"source_logical_id":"mod:caller"}"#,
        )
        .unwrap();
        let ctx = test_ctx_with_repo_root("proj1", repo_root);
        crate::registry::handle_upsert(
            &ctx,
            &serde_json::json!({
                "components": [{
                    "semantic_id": "mod:old",
                    "file_path": "src/old.rs",
                    "kind": "function"
                }]
            }),
        )
        .unwrap();
        let result = handle_preflight(
            &ctx,
            &serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": ["src/old.rs"],
                "adjacency_path": "adjacency.jsonl"
            }),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("malformed adjacency row"));
    }

    #[test]
    fn preflight_rejects_overlong_adjacency_line() {
        let repo_root = unique_temp_dir("preflight-overlong");
        std::fs::write(
            repo_root.join("adjacency.jsonl"),
            "x".repeat(MAX_ADJACENCY_LINE_CHARS + 1),
        )
        .unwrap();
        let ctx = test_ctx_with_repo_root("proj1", repo_root);
        crate::registry::handle_upsert(
            &ctx,
            &serde_json::json!({
                "components": [{
                    "semantic_id": "mod:old",
                    "file_path": "src/old.rs",
                    "kind": "function"
                }]
            }),
        )
        .unwrap();
        let result = handle_preflight(
            &ctx,
            &serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": ["src/old.rs"],
                "adjacency_path": "adjacency.jsonl"
            }),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("adjacency line exceeds"));
    }

    #[test]
    fn test_preflight_with_dependency_verdict() {
        let ctx = test_ctx("p1");
        let input = serde_json::json!({
            "project_id": "p1",
            "task_id": "t1",
            "scope": ["a.rs"],
            "proposed_components": ["m:f"],
            "dependency_verdict": {
                "status": "pass",
                "issues": [],
                "checked_at": "2024-01-01T00:00:00Z"
            }
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        assert!(result.get("dependency_verdict").is_some());
        assert_eq!(result["dependency_verdict"]["status"], "pass");
    }

    #[test]
    fn preflight_rejects_null_dependency_verdict() {
        let ctx = test_ctx("p1");
        let input = serde_json::json!({
            "project_id": "p1",
            "task_id": "t1",
            "scope": ["a.rs"],
            "proposed_components": ["m:f"],
            "dependency_verdict": null
        });
        let result = handle_preflight(&ctx, &input);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("dependency_verdict must be an object"));
    }

    #[test]
    fn test_preflight_duplicate_proposed_components_deduplicated() {
        let ctx = test_ctx("proj1");
        // normalize_string_array deduplicates, so two "mod:foo" become one
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/foo.rs"],
            "proposed_components": ["mod:foo", "mod:foo"],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        // After dedup it's just one component, no conflict in empty DB
        assert_eq!(result["verdict"], "PASS");
    }

    #[test]
    fn test_preflight_target_lock_accepts_directory_scope() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-dir-scope",
            "scope": ["apps/web"],
            "proposed_components": ["apps/web/src/page.tsx:HomePage"],
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        assert_eq!(result["verdict"], "PASS");
        assert_eq!(result["target_lock"]["status"], "clear");
    }

    #[test]
    fn test_preflight_scope_overlap_detects_nested_paths() {
        let ctx = test_ctx("proj1");
        let first = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-root",
            "scope": ["packages/ui"],
            "proposed_components": ["mod:root"],
        });
        handle_preflight(&ctx, &first).unwrap();

        let second = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-file",
            "scope": ["packages/ui/src/button.tsx"],
            "proposed_components": ["mod:file"],
        });
        let result = handle_preflight(&ctx, &second).unwrap();
        assert_eq!(result["verdict"], "WARN");
    }

    #[test]
    fn preflight_treats_null_adjacency_path_as_absent() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "scope": ["src/new.rs"],
            "proposed_components": ["mod:new"],
            "adjacency_path": null,
        });
        let result = handle_preflight(&ctx, &input).unwrap();
        assert_eq!(result["verdict"], "PASS");
    }

    #[test]
    fn preflight_rejects_non_string_adjacency_path() {
        let ctx = test_ctx("proj1");

        for adjacency_path in [
            serde_json::json!(42),
            serde_json::json!(["adjacency.jsonl"]),
            serde_json::json!({"path": "adjacency.jsonl"}),
        ] {
            let input = serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "adjacency_path": adjacency_path,
            });
            let result = handle_preflight(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn preflight_rejects_invalid_present_optional_array_fields() {
        let ctx = test_ctx("proj1");

        for input in [
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-deleted-null",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": null,
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-deleted-non-array",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": "src/old.rs",
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-deleted-element",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "deleted_paths": [42],
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-removed-null",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "removed_symbols": null,
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-removed-non-array",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "removed_symbols": "mod:old",
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-removed-element",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "removed_symbols": [42],
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-move-null",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "move_candidates": null,
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-move-non-array",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "move_candidates": {"old_path": "src/old.rs", "new_path": "src/new.rs"},
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-move-element",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "move_candidates": [42],
            }),
            serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-move-missing",
                "scope": ["src/new.rs"],
                "proposed_components": ["mod:new"],
                "move_candidates": [{"old_path": "src/old.rs"}],
            }),
        ] {
            let result = handle_preflight(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    // -- Helper function tests --

    #[test]
    fn test_resolve_verdict_no_issues() {
        assert_eq!(resolve_verdict(false, false, false, false), "PASS");
    }

    #[test]
    fn test_resolve_verdict_with_conflicts() {
        assert_eq!(resolve_verdict(true, false, false, false), "BLOCK");
    }

    #[test]
    fn test_resolve_verdict_with_overlap() {
        assert_eq!(resolve_verdict(false, true, false, false), "WARN");
    }

    #[test]
    fn test_resolve_verdict_with_dup_warning() {
        assert_eq!(resolve_verdict(false, false, false, true), "WARN");
    }

    #[test]
    fn test_resolve_verdict_conflicts_trump_warn() {
        assert_eq!(resolve_verdict(true, true, true, true), "BLOCK");
    }

    #[test]
    fn test_extract_scope_from_capsule() {
        let capsule = "TASK=t1\nSCOPE=src/foo.rs|src/bar.rs\nVERDICT=PASS";
        let scope = extract_scope_from_capsule(capsule);
        assert_eq!(scope.len(), 2);
        assert!(scope.contains(&"src/foo.rs".to_string()));
        assert!(scope.contains(&"src/bar.rs".to_string()));
    }

    #[test]
    fn test_extract_scope_from_capsule_empty() {
        let capsule = "TASK=t1\nVERDICT=PASS";
        let scope = extract_scope_from_capsule(capsule);
        assert!(scope.is_empty());
    }
}
