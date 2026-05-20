//! `sem.capsule` tool implementation.
//!
//! Generates a compact semantic capsule for the current task context.
//! Enforces a strict token budget (default 220, body <= 200).

use serde::Serialize;
use serde_json::Value;
use shared::freshness;

use crate::context::ServerContext;
use crate::context_top_k;
use crate::util::{estimate_tokens, sanitize_value, sha256_hex};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const TOKEN_CHAR_RATIO: usize = 3;
const DEFAULT_BUDGET: i64 = 220;
const MAX_BUDGET: i64 = 220;
const MAX_BODY_TOKENS: i64 = 200;
const META_TOKEN_RESERVE: i64 = 20;

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from `sem.capsule`.
#[derive(Debug, Clone, Serialize)]
pub struct CapsuleResponse {
    pub capsule: String,
    pub constraints: Vec<String>,
    pub hints: Vec<String>,
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

struct NormalizedInput {
    project_id: String,
    task_id: String,
    phase: String,
    budget: i64,
    body_token_budget: i64,
    changed_symbols: Vec<String>,
    top_k_symbols: Vec<String>,
    index_version: u64,
    file_sha_rollup: String,
    preflight_verdict: Option<String>,
    target_lock: Option<CapsuleSignal>,
    ambiguity: Option<CapsuleSignal>,
    duplicate_risk: Option<CapsuleSignal>,
}

struct CapsuleSignal {
    status: String,
    _summary: Option<String>,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute the `sem.capsule` tool.
pub fn handle_capsule(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let normalized = normalize_capsule_input(ctx, input)?;
    let capsule = build_capsule_body(&normalized)?;

    let constraints = vec![
        format!("total_tokens<={}", normalized.budget),
        format!("capsule_tokens<={}", normalized.body_token_budget),
        "format=key_value_scc".to_string(),
        "hash=sha256".to_string(),
    ];

    let hints = build_hints(&normalized);

    let mut response = CapsuleResponse {
        capsule,
        constraints,
        hints,
    };

    fit_response_to_budget(&mut response, normalized.budget)?;
    persist_capsule(ctx, &normalized, &response.capsule)?;

    serde_json::to_value(response).map_err(|e| format!("sem.capsule failed: serialization: {e}"))
}

// ---------------------------------------------------------------------------
// Input normalization
// ---------------------------------------------------------------------------

fn normalize_capsule_input(ctx: &ServerContext, input: &Value) -> Result<NormalizedInput, String> {
    let obj = input
        .as_object()
        .ok_or("sem.capsule failed: arguments must be an object")?;

    let project_id = obj
        .get("project_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.capsule failed: project_id is required")?;

    if project_id != ctx.project_id {
        return Err(format!(
            "sem.capsule failed: project_id mismatch: expected {}, received {project_id}",
            ctx.project_id
        ));
    }

    let task_id = obj
        .get("task_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.capsule failed: task_id is required")?;

    let phase = obj
        .get("phase")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.capsule failed: phase is required")?;
    if obj.get("top_k_symbols").is_some() {
        return Err(
            "sem.capsule failed: top_k_symbols is server-issued; provide context_token instead (see sem.context.top_k) (fail-closed)"
                .to_string(),
        );
    }
    let context_token = obj
        .get("context_token")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or("sem.capsule failed: context_token is required")?;

    let requested_budget = obj
        .get("budget")
        .and_then(|v| v.as_i64())
        .unwrap_or(DEFAULT_BUDGET);
    let budget = requested_budget.min(MAX_BUDGET);
    if budget <= META_TOKEN_RESERVE {
        return Err("sem.capsule failed: budget too small: requires > 20 tokens".into());
    }

    let body_token_budget = MAX_BODY_TOKENS.min(budget - META_TOKEN_RESERVE);

    let context_obj = match obj.get("context") {
        None | Some(Value::Null) => None,
        Some(Value::Object(context)) => Some(context),
        Some(_) => return Err("sem.capsule failed: context must be an object".into()),
    };

    let changed_symbols = context_obj
        .and_then(|c| c.get("changed_symbols"))
        .map(|value| normalize_optional_str_array(value, "context.changed_symbols"))
        .transpose()?
        .unwrap_or_default();

    if context_obj.and_then(|c| c.get("top_k_symbols")).is_some() {
        return Err(
            "sem.capsule failed: top_k_symbols is server-issued; provide context_token instead (see sem.context.top_k) (fail-closed)"
                .to_string(),
        );
    }

    let preflight_verdict = normalize_optional_context_string(
        context_obj.and_then(|c| c.get("preflight_verdict")),
        "context.preflight_verdict",
    )?
    .map(|s| s.to_uppercase());

    let target_lock = normalize_optional_signal(
        context_obj.and_then(|c| c.get("target_lock")),
        "context.target_lock",
    )?;
    let ambiguity = normalize_optional_signal(
        context_obj.and_then(|c| c.get("ambiguity")),
        "context.ambiguity",
    )?;
    let duplicate_risk = normalize_optional_signal(
        context_obj.and_then(|c| c.get("duplicate_risk")),
        "context.duplicate_risk",
    )?;
    let issued_context = context_top_k::resolve_context_token(ctx, &context_token)?;
    freshness::verify_unchanged(
        &ctx.conn,
        &project_id,
        &ctx.repo_root,
        &issued_context.changed_files,
        &issued_context.file_sha_rollup,
    )
    .map_err(|_| {
        "sem.capsule failed: file_parse_cache changed since context_token was issued (cache freshness violation); re-issue via sem.context.top_k"
            .to_string()
    })?;
    let top_k_symbols = issued_context
        .top_k_symbols
        .iter()
        .map(|entry| {
            format!(
                "{}:{}:{}:{}",
                entry.qualified_name, entry.name, entry.file_path, entry.kind
            )
        })
        .collect::<Vec<_>>();

    Ok(NormalizedInput {
        project_id,
        task_id,
        phase,
        budget,
        body_token_budget,
        changed_symbols,
        top_k_symbols,
        index_version: issued_context.index_version,
        file_sha_rollup: issued_context.file_sha_rollup,
        preflight_verdict,
        target_lock,
        ambiguity,
        duplicate_risk,
    })
}

fn normalize_optional_str_array(value: &Value, field: &str) -> Result<Vec<String>, String> {
    match value {
        Value::Null => Err(format!("{field} must be string[]")),
        Value::Array(arr) => {
            let mut result = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for (i, item) in arr.iter().enumerate() {
                let s = item
                    .as_str()
                    .ok_or_else(|| format!("{field}[{i}] must be a string"))?;
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    return Err(format!("{field}[{i}] must not be empty"));
                }
                if seen.insert(trimmed.to_string()) {
                    result.push(trimmed.to_string());
                }
            }
            Ok(result)
        }
        _ => Err(format!("{field} must be string[]")),
    }
}

fn normalize_optional_context_string(
    value: Option<&Value>,
    field: &str,
) -> Result<Option<String>, String> {
    match value {
        None => Ok(None),
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_string()))
            }
        }
        Some(_) => Err(format!("{field} must be a string")),
    }
}

fn normalize_optional_signal(
    value: Option<&Value>,
    field: &str,
) -> Result<Option<CapsuleSignal>, String> {
    match value {
        None => Ok(None),
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(CapsuleSignal {
                    status: trimmed.to_string(),
                    _summary: None,
                }))
            }
        }
        Some(Value::Object(obj)) => {
            let status =
                normalize_optional_context_string(obj.get("status"), &format!("{field}.status"))?
                    .ok_or_else(|| format!("{field}.status is required"))?;
            let summary =
                normalize_optional_context_string(obj.get("summary"), &format!("{field}.summary"))?;
            Ok(Some(CapsuleSignal {
                status,
                _summary: summary,
            }))
        }
        Some(_) => Err(format!("{field} must be a string or object")),
    }
}

// ---------------------------------------------------------------------------
// Capsule building
// ---------------------------------------------------------------------------

fn build_capsule_body(input: &NormalizedInput) -> Result<String, String> {
    let changed_digest = sha256_hex(&input.changed_symbols.join("\n"));
    let top_k_digest = sha256_hex(&input.top_k_symbols.join("\n"));

    let tl = input
        .target_lock
        .as_ref()
        .map(|s| s.status.as_str())
        .unwrap_or("unknown");
    let amb = input
        .ambiguity
        .as_ref()
        .map(|s| s.status.as_str())
        .unwrap_or("unknown");
    let dup = input
        .duplicate_risk
        .as_ref()
        .map(|s| s.status.as_str())
        .unwrap_or("unknown");

    let mut lines = vec![
        format!("TASK={}", sanitize_value(&input.task_id)),
        format!("PHASE={}", sanitize_value(&input.phase)),
        format!("PROJECT={}", sanitize_value(&input.project_id)),
        format!(
            "PREFLIGHT={}",
            sanitize_value(input.preflight_verdict.as_deref().unwrap_or("UNKNOWN"))
        ),
        format!("TARGET_LOCK={}", sanitize_value(tl)),
        format!("AMBIGUITY={}", sanitize_value(amb)),
        format!("DUPLICATE_RISK={}", sanitize_value(dup)),
        format!("CHANGED_COUNT={}", input.changed_symbols.len()),
        format!("CHANGED_SHA256={changed_digest}"),
        format!("TOPK_COUNT={}", input.top_k_symbols.len()),
        format!("TOPK_SHA256={top_k_digest}"),
    ];
    let index_version_slot = lines.len();
    lines.push(format!("INDEX_VERSION={}", input.index_version));
    lines.push(format!("FILE_SHA_ROLLUP={}", input.file_sha_rollup));

    if !input.changed_symbols.is_empty() {
        lines.push(format!(
            "CHANGED_HEAD={}",
            build_head(&input.changed_symbols)
        ));
    }
    if !input.top_k_symbols.is_empty() {
        lines.push(format!("TOPK_HEAD={}", build_head(&input.top_k_symbols)));
    }

    let mut capsule = with_capsule_hash(&lines, &[index_version_slot]);
    let body_char_budget = (input.body_token_budget as usize) * TOKEN_CHAR_RATIO;

    if capsule.len() > body_char_budget {
        // Remove HEAD lines.
        lines.retain(|l| !l.starts_with("CHANGED_HEAD=") && !l.starts_with("TOPK_HEAD="));
        capsule = with_capsule_hash(&lines, &[index_version_slot]);
    }

    if capsule.len() > body_char_budget {
        return Err("sem.capsule failed: capsule body exceeded token budget (fail-closed)".into());
    }

    Ok(capsule)
}

fn build_head(values: &[String]) -> String {
    values
        .iter()
        .take(2)
        .map(|v| sanitize_value(v))
        .collect::<Vec<_>>()
        .join("|")
}

fn with_capsule_hash(lines: &[String], exclude_indices: &[usize]) -> String {
    let hash_input = lines
        .iter()
        .enumerate()
        .filter(|(idx, _)| !exclude_indices.contains(idx))
        .map(|(_, line)| line.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let body = lines.join("\n");
    let hash = sha256_hex(&hash_input);
    format!("{body}\nCAPSULE_SHA256={hash}")
}

fn build_hints(input: &NormalizedInput) -> Vec<String> {
    let mut hints = Vec::new();

    if let Some(sig) = &input.target_lock {
        hints.push(format!("target_lock={}", sanitize_value(&sig.status)));
    }
    if let Some(sig) = &input.ambiguity {
        hints.push(format!("ambiguity={}", sanitize_value(&sig.status)));
    }
    if let Some(sig) = &input.duplicate_risk {
        hints.push(format!("duplicate_risk={}", sanitize_value(&sig.status)));
    }
    if let Some(pf) = &input.preflight_verdict {
        hints.push(format!("preflight={}", sanitize_value(pf)));
    }
    if let Some(first) = input.changed_symbols.first() {
        hints.push(format!("focus_changed={}", sanitize_value(first)));
    }
    if let Some(first) = input.top_k_symbols.first() {
        hints.push(format!("check_similar={}", sanitize_value(first)));
    }

    hints
}

fn fit_response_to_budget(response: &mut CapsuleResponse, budget: i64) -> Result<(), String> {
    let max_chars = (budget as usize) * TOKEN_CHAR_RATIO;

    loop {
        let json =
            serde_json::to_string(response).map_err(|e| format!("serialization error: {e}"))?;
        if json.len() <= max_chars {
            return Ok(());
        }

        if !response.hints.is_empty() {
            response.hints.pop();
            continue;
        }
        if response.constraints.len() > 1 {
            response.constraints.pop();
            continue;
        }

        return Err(
            "sem.capsule failed: capsule response exceeded token budget (fail-closed)".into(),
        );
    }
}

fn persist_capsule(
    ctx: &ServerContext,
    input: &NormalizedInput,
    capsule: &str,
) -> Result<(), String> {
    let token_count = estimate_tokens(capsule);
    ctx.conn
        .execute(
            "INSERT INTO capsules (project_id, task_id, phase, content, token_count, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))",
            rusqlite::params![
                ctx.project_id,
                input.task_id,
                input.phase,
                capsule,
                token_count
            ],
        )
        .map_err(|e| format!("persist capsule failed: {e}"))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::{NormalizedContext, ServerContext, TopKEntry};
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

    fn basic_capsule_input(project_id: &str) -> Value {
        serde_json::json!({
            "project_id": project_id,
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
        })
    }

    fn seed_context_token(ctx: &ServerContext) {
        seed_context_token_with_topk(ctx, Vec::new());
    }

    fn seed_context_token_with_topk(ctx: &ServerContext, top_k_symbols: Vec<TopKEntry>) {
        ctx.token_cache.lock().unwrap().put(
            "token-1".to_string(),
            (
                NormalizedContext {
                    changed_files: Vec::new(),
                    top_k_symbols,
                    file_sha_rollup: crate::util::sha256_hex(""),
                    index_version: 7,
                    issued_at_unix_ms: ctx.clock.now_unix_ms(),
                },
                ctx.clock.now(),
            ),
        );
    }

    fn top_entry(name: &str) -> TopKEntry {
        TopKEntry {
            qualified_name: name.to_string(),
            name: name.to_string(),
            file_path: "src/lib.rs".to_string(),
            kind: "function".to_string(),
            rank_score: 1.0,
            rationale: "fan_in=0,impact_depth=0".to_string(),
        }
    }

    #[test]
    fn test_capsule_basic_build() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = basic_capsule_input("proj1");
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("TASK=task-1"));
        assert!(capsule.contains("PHASE=impl"));
        assert!(capsule.contains("PROJECT=proj1"));
        assert!(capsule.contains("INDEX_VERSION=7"));
        assert!(capsule.contains("FILE_SHA_ROLLUP="));
    }

    #[test]
    fn test_capsule_contains_sha256() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = basic_capsule_input("proj1");
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("CAPSULE_SHA256="));
    }

    #[test]
    fn test_capsule_sha256_is_deterministic() {
        let ctx1 = test_ctx("proj1");
        let ctx2 = test_ctx("proj1");
        seed_context_token(&ctx1);
        seed_context_token(&ctx2);
        let input = basic_capsule_input("proj1");

        let r1 = handle_capsule(&ctx1, &input).unwrap();
        let r2 = handle_capsule(&ctx2, &input).unwrap();

        let capsule1 = r1["capsule"].as_str().unwrap();
        let capsule2 = r2["capsule"].as_str().unwrap();
        assert_eq!(capsule1, capsule2);
    }

    #[test]
    fn test_capsule_with_changed_symbols() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": {
                "changed_symbols": ["mod:foo", "mod:bar"],
            }
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("CHANGED_COUNT=2"));
    }

    #[test]
    fn test_capsule_with_top_k_symbols() {
        let ctx = test_ctx("proj1");
        seed_context_token_with_topk(
            &ctx,
            vec![
                top_entry("mod:alpha"),
                top_entry("mod:beta"),
                top_entry("mod:gamma"),
            ],
        );
        let input = basic_capsule_input("proj1");
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("TOPK_COUNT=3"));
    }

    #[test]
    fn test_capsule_persists_to_db() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = basic_capsule_input("proj1");
        handle_capsule(&ctx, &input).unwrap();

        let exists: i64 = ctx
            .conn
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM capsules
                    WHERE project_id = 'proj1' AND phase = 'impl'
                 )",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(exists, 1);
    }

    #[test]
    fn test_capsule_retrieves_from_db() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = basic_capsule_input("proj1");
        let result = handle_capsule(&ctx, &input).unwrap();
        let expected_capsule = result["capsule"].as_str().unwrap();

        let stored: String = ctx.conn.query_row(
            "SELECT content FROM capsules WHERE project_id = 'proj1' AND phase = 'impl' LIMIT 1",
            [],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(stored, expected_capsule);
    }

    #[test]
    fn test_capsule_missing_project_id_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "task_id": "task-1",
            "phase": "impl",
        });
        let result = handle_capsule(&ctx, &input);
        assert!(result.is_err());
    }

    #[test]
    fn test_capsule_missing_phase_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
        });
        let result = handle_capsule(&ctx, &input);
        assert!(result.is_err());
    }

    #[test]
    fn test_capsule_constraints_present() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = basic_capsule_input("proj1");
        let result = handle_capsule(&ctx, &input).unwrap();
        let constraints = result["constraints"].as_array().unwrap();
        assert!(!constraints.is_empty());
        // Should contain token budget constraints
        let constraint_strs: Vec<&str> = constraints.iter().map(|c| c.as_str().unwrap()).collect();
        assert!(constraint_strs.iter().any(|c| c.contains("total_tokens")));
    }

    #[test]
    fn test_capsule_budget_enforcement() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "budget": 220,
            "context_token": "token-1",
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        // 200 tokens * 3 chars = 600 chars max for body
        assert!(capsule.len() <= 600);
    }

    #[test]
    fn test_capsule_budget_too_small_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "budget": 10,
            "context_token": "token-1",
        });
        let result = handle_capsule(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("budget too small"));
    }

    #[test]
    fn test_capsule_with_preflight_verdict() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": {
                "preflight_verdict": "PASS",
            }
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("PREFLIGHT=PASS"));
    }

    #[test]
    fn capsule_treats_null_context_as_absent() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": null,
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        assert!(capsule.contains("TARGET_LOCK=unknown"));
        assert!(result["hints"].as_array().unwrap().is_empty());
    }

    #[test]
    fn capsule_treats_null_target_lock_as_absent() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": {
                "target_lock": null,
                "changed_symbols": ["mod:foo"]
            },
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        let hints = result["hints"].as_array().unwrap();
        assert!(capsule.contains("TARGET_LOCK=unknown"));
        assert!(!hints
            .iter()
            .filter_map(Value::as_str)
            .any(|hint| hint.starts_with("target_lock=")));
    }

    #[test]
    fn capsule_treats_node_optional_context_null_fields_as_absent() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);
        let input = serde_json::json!({
            "project_id": "proj1",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": {
                "preflight_verdict": null,
                "ambiguity": null,
                "duplicate_risk": null,
            },
        });
        let result = handle_capsule(&ctx, &input).unwrap();
        let capsule = result["capsule"].as_str().unwrap();
        let hints = result["hints"].as_array().unwrap();
        assert!(capsule.contains("PREFLIGHT=UNKNOWN"));
        assert!(capsule.contains("AMBIGUITY=unknown"));
        assert!(capsule.contains("DUPLICATE_RISK=unknown"));
        assert!(hints.iter().filter_map(Value::as_str).all(|hint| {
            !hint.starts_with("preflight=")
                && !hint.starts_with("ambiguity=")
                && !hint.starts_with("duplicate_risk=")
        }));
    }

    #[test]
    fn capsule_rejects_present_non_object_context() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);

        for context in [
            serde_json::json!("invalid"),
            serde_json::json!(["changed"]),
            serde_json::json!(42),
        ] {
            let input = serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "phase": "impl",
                "context_token": "token-1",
                "context": context,
            });
            let result = handle_capsule(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn capsule_rejects_invalid_nested_context_fields() {
        let ctx = test_ctx("proj1");
        seed_context_token(&ctx);

        for context in [
            serde_json::json!({"changed_symbols": null}),
            serde_json::json!({"changed_symbols": "mod:foo"}),
            serde_json::json!({"changed_symbols": [42]}),
            serde_json::json!({"top_k_symbols": null}),
            serde_json::json!({"top_k_symbols": "mod:foo"}),
            serde_json::json!({"top_k_symbols": [42]}),
            serde_json::json!({"preflight_verdict": 42}),
            serde_json::json!({"target_lock": 42}),
            serde_json::json!({"target_lock": {}}),
            serde_json::json!({"target_lock": {"status": 42}}),
            serde_json::json!({"target_lock": {"status": ""}}),
            serde_json::json!({"target_lock": {"status": "warn", "summary": 42}}),
            serde_json::json!({"ambiguity": []}),
            serde_json::json!({"duplicate_risk": {"summary": "missing status"}}),
        ] {
            let input = serde_json::json!({
                "project_id": "proj1",
                "task_id": "task-1",
                "phase": "impl",
                "context_token": "token-1",
                "context": context,
            });
            let result = handle_capsule(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn test_capsule_project_id_mismatch_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "wrong",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
        });
        let result = handle_capsule(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("mismatch"));
    }

    #[test]
    fn build_capsule_body_token_count() {
        let cases = vec![
            (Vec::new(), Vec::new()),
            (vec!["src/lib.rs:alpha".to_string()], Vec::new()),
            (Vec::new(), vec!["src/lib.rs:beta".to_string()]),
            (
                vec![
                    "src/lib.rs:alpha".to_string(),
                    "src/main.rs:main".to_string(),
                ],
                vec!["src/lib.rs:beta".to_string()],
            ),
            (
                (0..16)
                    .map(|i| format!("src/file_{i}.rs:sym_{i}"))
                    .collect(),
                (0..16).map(|i| format!("src/top_{i}.rs:sym_{i}")).collect(),
            ),
            (
                (0..512)
                    .map(|i| format!("src/{}_{i}.rs:sym_{i}", "x".repeat(200)))
                    .collect(),
                (0..512)
                    .map(|i| format!("src/{}_{i}.rs:top_{i}", "y".repeat(200)))
                    .collect(),
            ),
        ];

        for (changed_symbols, top_k_symbols) in cases {
            let input = NormalizedInput {
                project_id: "proj1".to_string(),
                task_id: "task-1".to_string(),
                phase: "impl".to_string(),
                budget: MAX_BUDGET,
                body_token_budget: MAX_BODY_TOKENS,
                changed_symbols,
                top_k_symbols,
                index_version: 42,
                file_sha_rollup: crate::util::sha256_hex("rollup"),
                preflight_verdict: Some("PASS".to_string()),
                target_lock: None,
                ambiguity: None,
                duplicate_risk: None,
            };
            let capsule = build_capsule_body(&input).unwrap();
            assert!(
                estimate_tokens(&capsule) <= MAX_BODY_TOKENS,
                "capsule exceeded body token budget: {}",
                estimate_tokens(&capsule)
            );
            assert!(estimate_tokens(&capsule) <= MAX_BUDGET);
        }
    }
}
