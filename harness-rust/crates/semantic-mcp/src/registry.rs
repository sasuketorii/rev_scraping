//! `sem.registry.*` tool implementations.
//!
//! Provides upsert, query, set_status, and delete operations on the
//! component registry with idempotency tracking via `registry_deltas`.

use std::collections::{HashMap, HashSet};

use serde::Serialize;
use serde_json::Value;

use crate::context::ServerContext;
use crate::util::{
    build_prefix_upper_bound, canonicalize_path_like, clamp_i64, normalize_path_like,
    normalize_repo_relative_path, sha256_hex, stable_stringify,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MUTABLE_STATUSES: &[&str] = &["active", "inactive", "incomplete", "buggy", "deprecated"];
const QUERYABLE_STATUSES: &[&str] = &[
    "active",
    "inactive",
    "incomplete",
    "buggy",
    "deprecated",
    "deleted",
];
const QUERY_RESPONSE_ITEM_LIMIT: usize = 4;
const QUERY_RESPONSE_CHAR_BUDGET: usize = 600;

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from `sem.registry.upsert`.
#[derive(Debug, Serialize)]
pub struct UpsertResponse {
    pub applied: bool,
    pub new_count: usize,
    pub updated_count: usize,
}

/// A single item in a query response.
#[derive(Debug, Clone, Serialize)]
pub struct QueryItem {
    pub semantic_id: String,
    pub path: String,
    pub symbol: String,
    pub kind: String,
}

/// Response from `sem.registry.query`.
#[derive(Debug, Serialize)]
pub struct QueryResponse {
    pub items: Vec<QueryItem>,
    pub total: i64,
    pub capsule: String,
}

/// Response from `sem.registry.set_status`.
#[derive(Debug, Serialize)]
pub struct SetStatusResponse {
    pub applied: bool,
    pub semantic_id: String,
    pub old_status: String,
    pub new_status: String,
    pub updated_at: String,
}

/// Response from `sem.registry.delete`.
#[derive(Debug, Serialize)]
pub struct DeleteResponse {
    pub applied: bool,
    pub semantic_id: String,
    pub deleted_at: String,
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

struct NormalizedComponent {
    semantic_id: String,
    name: String,
    module: String,
    file_path: String,
    kind: String,
    exports_json: String,
    imports_json: String,
    hash: String,
    figma_ref: Option<String>,
    status: String,
    inactive_reason: Option<String>,
    security_level: Option<String>,
    idem: String,
}

struct ComponentRow {
    name: String,
    module: String,
    file_path: String,
    kind: String,
    exports: String,
    imports: String,
    hash: String,
    figma_ref: Option<String>,
    status: String,
    inactive_reason: Option<String>,
    security_level: Option<String>,
    idem: String,
}

// ---------------------------------------------------------------------------
// Upsert
// ---------------------------------------------------------------------------

/// Execute `sem.registry.upsert`.
pub fn handle_upsert(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let obj = match input {
        Value::Null => serde_json::Map::new(),
        Value::Object(obj) => obj.clone(),
        _ => return Err("sem.registry.upsert failed: arguments must be an object".into()),
    };
    validate_registry_upsert_input(&obj).map_err(|e| format!("sem.registry.upsert failed: {e}"))?;
    validate_project_id_match(ctx, &obj)?;

    let payloads = extract_component_payloads(&obj, &ctx.project_id)?;
    if payloads.is_empty() {
        return Err("sem.registry.upsert failed: components or deltas are required".into());
    }

    let mut components: Vec<NormalizedComponent> = Vec::new();
    for payload in &payloads {
        components.push(normalize_component_payload(payload, ctx)?);
    }

    // Sort and dedupe check.
    components.sort_by(|a, b| a.semantic_id.cmp(&b.semantic_id));
    let mut seen = HashSet::new();
    for c in &components {
        if !seen.insert(&c.semantic_id) {
            return Err(format!(
                "sem.registry.upsert failed: upsert input contains duplicate semantic_id: {}",
                c.semantic_id
            ));
        }
    }

    // Check target lock contracts.
    for c in &components {
        assert_target_lock_contract(c)?;
    }

    // Check ownership duplicates within request.
    assert_no_duplicate_ownership(&components)?;

    // Build idempotency key.
    let delta_payload = build_upsert_delta_payload(&components);
    let idempotency_key = sha256_hex(&delta_payload);
    let primary_sid = if components.len() == 1 {
        Some(components[0].semantic_id.clone())
    } else {
        None
    };

    // Execute in transaction.
    let tx = ctx
        .conn
        .unchecked_transaction()
        .map_err(|e| format!("sem.registry.upsert failed: {e}"))?;

    // Read current rows.
    let mut current_rows: Vec<(NormalizedComponent, Option<ComponentRow>)> = Vec::new();
    {
        let mut stmt = tx
            .prepare(
                "SELECT name, module, file_path, kind, exports, imports, hash,
                        figma_ref, status, inactive_reason, security_level, idem
                 FROM components
                 WHERE project_id = ?1 AND semantic_id = ?2
                 LIMIT 1",
            )
            .map_err(|e| format!("sem.registry.upsert failed: {e}"))?;

        for comp in components {
            let row: Option<ComponentRow> = stmt
                .query_row(rusqlite::params![ctx.project_id, comp.semantic_id], |row| {
                    Ok(ComponentRow {
                        name: row.get(0)?,
                        module: row.get(1)?,
                        file_path: row.get(2)?,
                        kind: row.get(3)?,
                        exports: row.get(4)?,
                        imports: row.get(5)?,
                        hash: row.get(6)?,
                        figma_ref: row.get(7)?,
                        status: row.get(8)?,
                        inactive_reason: row.get(9)?,
                        security_level: row.get(10)?,
                        idem: row.get(11)?,
                    })
                })
                .ok();

            // Check ownership lock.
            assert_registry_ownership_lock(&tx, ctx, &comp, row.as_ref())?;

            current_rows.push((comp, row));
        }
    }

    let has_pending_repair = current_rows.iter().any(|(comp, row)| match row {
        None => true,
        Some(r) => !is_row_in_sync(r, comp),
    });

    let delta_changes = insert_registry_delta(
        &tx,
        &ctx.project_id,
        &idempotency_key,
        "upsert",
        primary_sid.as_deref(),
        &delta_payload,
    )?;

    if delta_changes == 0 && !has_pending_repair {
        tx.commit().map_err(|e| format!("commit failed: {e}"))?;
        let resp = UpsertResponse {
            applied: false,
            new_count: 0,
            updated_count: 0,
        };
        return serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"));
    }

    let mut new_count = 0usize;
    let mut updated_count = 0usize;

    for (entry, current_row) in &current_rows {
        if let Some(row) = current_row {
            if is_row_in_sync(row, entry) {
                continue;
            }
        }

        tx.execute(
            "INSERT INTO components (
                project_id, semantic_id, name, module, file_path, kind,
                exports, imports, hash, figma_ref, status, inactive_reason,
                security_level, idem, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, datetime('now'))
            ON CONFLICT(project_id, semantic_id) DO UPDATE SET
                name = excluded.name,
                module = excluded.module,
                file_path = excluded.file_path,
                kind = excluded.kind,
                exports = excluded.exports,
                imports = excluded.imports,
                hash = excluded.hash,
                figma_ref = excluded.figma_ref,
                status = excluded.status,
                inactive_reason = excluded.inactive_reason,
                security_level = excluded.security_level,
                idem = excluded.idem,
                updated_at = datetime('now')",
            rusqlite::params![
                ctx.project_id,
                entry.semantic_id,
                entry.name,
                entry.module,
                entry.file_path,
                entry.kind,
                entry.exports_json,
                entry.imports_json,
                entry.hash,
                entry.figma_ref,
                entry.status,
                entry.inactive_reason,
                entry.security_level,
                entry.idem,
            ],
        )
        .map_err(|e| format!("sem.registry.upsert failed: {e}"))?;

        let row_id: i64 = tx
            .query_row(
                "SELECT id FROM components WHERE project_id = ?1 AND semantic_id = ?2",
                rusqlite::params![ctx.project_id, entry.semantic_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("sem.registry.upsert failed: row id lookup failed: {e}"))?;

        tx.execute(
            "INSERT OR REPLACE INTO components_fts(rowid, name, semantic_id, module, kind, file_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                row_id,
                entry.name,
                entry.semantic_id,
                entry.module,
                entry.kind,
                entry.file_path,
            ],
        )
        .map_err(|e| format!("sem.registry.upsert failed: components_fts sync failed: {e}"))?;

        if current_row.is_some() {
            updated_count += 1;
        } else {
            new_count += 1;
        }
    }

    tx.commit().map_err(|e| format!("commit failed: {e}"))?;

    let resp = UpsertResponse {
        applied: delta_changes > 0 || has_pending_repair,
        new_count,
        updated_count,
    };
    serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"))
}

// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------

/// Execute `sem.registry.query`.
pub fn handle_query(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let obj = input.as_object().unwrap_or(&serde_json::Map::new()).clone();
    validate_project_id_match(ctx, &obj)?;

    let kind = get_present_string(&obj, "kind")?;
    let semantic_id = get_present_exact_string(&obj, "semantic_id")?
        .map(|sid| normalize_identifier(&sid))
        .transpose()?;
    let path_prefix = get_exact_alias_string(&obj, &["path_prefix", "pathPrefix", "path"])?
        .map(|path| normalize_path_prefix(&path))
        .filter(|path| !path.is_empty());
    let name_exact = get_exact_alias_string(
        &obj,
        &["name_exact", "nameExact", "symbol_exact", "symbolExact"],
    )?;
    let name_partial = get_alias_string(&obj, &["name_partial", "namePartial", "name", "symbol"])?;
    let statuses = resolve_query_statuses(&obj)?;
    let limit = clamp_i64(parse_optional_int(&obj, "limit")?.unwrap_or(8), 1, 25);
    let offset = clamp_i64(parse_optional_int(&obj, "offset")?.unwrap_or(0), 0, 10000);

    let mut where_clauses: Vec<String> = vec!["project_id = ?1".to_string()];
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(ctx.project_id.clone())];
    let mut param_idx = 2u32;

    if let Some(k) = &kind {
        where_clauses.push(format!("kind = ?{param_idx}"));
        params.push(Box::new(k.clone()));
        param_idx += 1;
    }
    if let Some(sid) = &semantic_id {
        where_clauses.push(format!("semantic_id = ?{param_idx}"));
        params.push(Box::new(sid.clone()));
        param_idx += 1;
    }
    if let Some(pp) = &path_prefix {
        if let Some(upper_bound) = build_prefix_upper_bound(pp) {
            where_clauses.push(format!(
                "file_path >= ?{param_idx} AND file_path < ?{}",
                param_idx + 1
            ));
            params.push(Box::new(pp.clone()));
            params.push(Box::new(upper_bound));
            param_idx += 2;
        } else {
            where_clauses.push(format!("file_path >= ?{param_idx}"));
            params.push(Box::new(pp.clone()));
            param_idx += 1;
        }
    }
    if let Some(exact) = &name_exact {
        where_clauses.push(format!("name = ?{param_idx}"));
        params.push(Box::new(exact.clone()));
        param_idx += 1;
    }
    if let Some(np) = &name_partial {
        where_clauses.push(format!("name LIKE ?{param_idx}"));
        params.push(Box::new(format!("%{np}%")));
        param_idx += 1;
    }
    if let Some(sts) = &statuses {
        if !sts.is_empty() {
            let placeholders: Vec<String> = sts
                .iter()
                .enumerate()
                .map(|(i, _)| format!("?{}", param_idx + i as u32))
                .collect();
            where_clauses.push(format!("status IN ({})", placeholders.join(", ")));
            for s in sts {
                params.push(Box::new(s.clone()));
            }
            param_idx += sts.len() as u32;
        }
    }

    let where_str = where_clauses.join(" AND ");

    // Count total.
    let count_sql = format!("SELECT COUNT(*) FROM components WHERE {where_str}");
    let total: i64 = {
        let mut stmt = ctx
            .conn
            .prepare(&count_sql)
            .map_err(|e| format!("sem.registry.query failed: {e}"))?;
        let param_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        stmt.query_row(param_refs.as_slice(), |row| row.get(0))
            .map_err(|e| format!("sem.registry.query failed: {e}"))?
    };

    // Fetch rows.
    let order_by = if path_prefix.is_some()
        && semantic_id.is_none()
        && name_exact.is_none()
        && name_partial.is_none()
    {
        "file_path ASC, semantic_id ASC"
    } else {
        "updated_at DESC, semantic_id ASC"
    };

    let query_sql = format!(
        "SELECT semantic_id, file_path, name, kind
         FROM components
         WHERE {where_str}
         ORDER BY {order_by}
         LIMIT ?{} OFFSET ?{}",
        param_idx,
        param_idx + 1
    );
    params.push(Box::new(limit));
    params.push(Box::new(offset));

    let mut items: Vec<QueryItem> = Vec::new();
    {
        let mut stmt = ctx
            .conn
            .prepare(&query_sql)
            .map_err(|e| format!("sem.registry.query failed: {e}"))?;
        let param_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        let rows = stmt
            .query_map(param_refs.as_slice(), |row| {
                Ok(QueryItem {
                    semantic_id: row.get(0)?,
                    path: row.get(1)?,
                    symbol: row.get(2)?,
                    kind: row.get(3)?,
                })
            })
            .map_err(|e| format!("sem.registry.query failed: {e}"))?;
        for row in rows {
            items.push(row.map_err(|e| format!("sem.registry.query failed: {e}"))?);
        }
    }

    let resp = compact_query_response(items, total);
    serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"))
}

// ---------------------------------------------------------------------------
// Set Status
// ---------------------------------------------------------------------------

/// Execute `sem.registry.set_status`.
pub fn handle_set_status(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let obj = as_required_object(input, "input")?;
    validate_project_id_match(ctx, &obj)?;

    let semantic_id = resolve_semantic_id(&obj)?;
    let requested_status = get_required_string(&obj, "status")?;
    let new_status = normalize_mutable_status(&requested_status)?;
    let requested_reason = get_alias_string(&obj, &["inactive_reason", "reason"])?;

    let tx = ctx
        .conn
        .unchecked_transaction()
        .map_err(|e| format!("sem.registry.set_status failed: {e}"))?;

    let current: Option<(String, Option<String>, String)> = tx
        .query_row(
            "SELECT status, inactive_reason, updated_at
             FROM components
             WHERE project_id = ?1 AND semantic_id = ?2 LIMIT 1",
            rusqlite::params![ctx.project_id, semantic_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .ok();

    let (old_status, old_reason, old_updated_at) = current.ok_or_else(|| {
        format!("sem.registry.set_status failed: component not found: {semantic_id}")
    })?;

    let next_reason = if new_status == "active" {
        None
    } else {
        requested_reason.or(old_reason.clone())
    };

    let delta_payload = stable_stringify(&serde_json::json!({
        "inactive_reason": next_reason,
        "semantic_id": semantic_id,
        "status": new_status,
    }));
    let idempotency_key = sha256_hex(&format!("set_status:{delta_payload}"));

    if old_status == new_status && old_reason == next_reason {
        let delta_changes = insert_registry_delta(
            &tx,
            &ctx.project_id,
            &idempotency_key,
            "set_status",
            Some(&semantic_id),
            &delta_payload,
        )?;
        tx.commit().map_err(|e| format!("commit failed: {e}"))?;
        let resp = SetStatusResponse {
            applied: delta_changes > 0,
            semantic_id,
            old_status,
            new_status,
            updated_at: old_updated_at,
        };
        return serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"));
    }

    tx.execute(
        "UPDATE components SET status = ?1, inactive_reason = ?2, updated_at = datetime('now')
         WHERE project_id = ?3 AND semantic_id = ?4",
        rusqlite::params![new_status, next_reason, ctx.project_id, semantic_id],
    )
    .map_err(|e| format!("sem.registry.set_status failed: {e}"))?;

    let updated_at: String = tx
        .query_row(
            "SELECT updated_at FROM components WHERE project_id = ?1 AND semantic_id = ?2 LIMIT 1",
            rusqlite::params![ctx.project_id, semantic_id],
            |row| row.get(0),
        )
        .map_err(|e| format!("sem.registry.set_status failed: verification error: {e}"))?;

    let _delta_changes = insert_registry_delta(
        &tx,
        &ctx.project_id,
        &idempotency_key,
        "set_status",
        Some(&semantic_id),
        &delta_payload,
    )?;

    tx.commit().map_err(|e| format!("commit failed: {e}"))?;

    let resp = SetStatusResponse {
        applied: true,
        semantic_id,
        old_status,
        new_status,
        updated_at,
    };
    serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"))
}

// ---------------------------------------------------------------------------
// Delete (soft-delete)
// ---------------------------------------------------------------------------

/// Execute `sem.registry.delete`.
pub fn handle_delete(ctx: &ServerContext, input: &Value) -> Result<Value, String> {
    let obj = as_required_object(input, "input")?;
    validate_project_id_match(ctx, &obj)?;

    let semantic_id = resolve_semantic_id(&obj)?;
    let reason = get_alias_string(&obj, &["inactive_reason", "reason"])?
        .unwrap_or_else(|| "deleted via sem.registry.delete".to_string());

    let tx = ctx
        .conn
        .unchecked_transaction()
        .map_err(|e| format!("sem.registry.delete failed: {e}"))?;

    let current: Option<(i64, String, Option<String>, String)> = tx
        .query_row(
            "SELECT id, status, inactive_reason, updated_at
             FROM components
             WHERE project_id = ?1 AND semantic_id = ?2 LIMIT 1",
            rusqlite::params![ctx.project_id, semantic_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .ok();

    let (component_id, old_status, old_reason, old_updated_at) = current
        .ok_or_else(|| format!("sem.registry.delete failed: component not found: {semantic_id}"))?;

    let delta_payload = stable_stringify(&serde_json::json!({
        "inactive_reason": reason,
        "semantic_id": semantic_id,
        "status": "deleted",
    }));
    let idempotency_key = sha256_hex(&format!("delete:{delta_payload}"));

    if old_status == "deleted" && old_reason.as_deref() == Some(&reason) {
        tx.execute(
            "DELETE FROM components_fts WHERE rowid = ?1",
            rusqlite::params![component_id],
        )
        .map_err(|e| format!("sem.registry.delete failed: components_fts sync failed: {e}"))?;
        let delta_changes = insert_registry_delta(
            &tx,
            &ctx.project_id,
            &idempotency_key,
            "delete",
            Some(&semantic_id),
            &delta_payload,
        )?;
        tx.commit().map_err(|e| format!("commit failed: {e}"))?;
        let resp = DeleteResponse {
            applied: delta_changes > 0,
            semantic_id,
            deleted_at: old_updated_at,
        };
        return serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"));
    }

    let changes = tx
        .execute(
            "UPDATE components SET status = 'deleted', inactive_reason = ?1, updated_at = datetime('now')
             WHERE project_id = ?2 AND semantic_id = ?3",
            rusqlite::params![reason, ctx.project_id, semantic_id],
        )
        .map_err(|e| format!("sem.registry.delete failed: {e}"))?;

    if changes == 0 {
        return Err(format!(
            "sem.registry.delete failed: component not found: {semantic_id}"
        ));
    }

    tx.execute(
        "DELETE FROM components_fts WHERE rowid = ?1",
        rusqlite::params![component_id],
    )
    .map_err(|e| format!("sem.registry.delete failed: components_fts sync failed: {e}"))?;

    let deleted_at: String = tx
        .query_row(
            "SELECT updated_at FROM components WHERE project_id = ?1 AND semantic_id = ?2 LIMIT 1",
            rusqlite::params![ctx.project_id, semantic_id],
            |row| row.get(0),
        )
        .map_err(|e| format!("sem.registry.delete failed: verification error: {e}"))?;

    insert_registry_delta(
        &tx,
        &ctx.project_id,
        &idempotency_key,
        "delete",
        Some(&semantic_id),
        &delta_payload,
    )?;

    tx.commit().map_err(|e| format!("commit failed: {e}"))?;

    tracing::info!(
        "sem.registry.delete project_id={} semantic_id={} reason={}",
        ctx.project_id,
        semantic_id,
        reason
    );

    let resp = DeleteResponse {
        applied: true,
        semantic_id,
        deleted_at,
    };
    serde_json::to_value(resp).map_err(|e| format!("serialization error: {e}"))
}

// ---------------------------------------------------------------------------
// Helper: insert registry delta
// ---------------------------------------------------------------------------

fn insert_registry_delta(
    conn: &rusqlite::Connection,
    project_id: &str,
    idempotency_key: &str,
    delta_type: &str,
    semantic_id: Option<&str>,
    payload: &str,
) -> Result<usize, String> {
    let result = conn.execute(
        "INSERT OR IGNORE INTO registry_deltas
            (project_id, idempotency_key, delta_type, semantic_id, payload, applied_at)
         VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))",
        rusqlite::params![
            project_id,
            idempotency_key,
            delta_type,
            semantic_id,
            payload
        ],
    );

    match result {
        Ok(changes) => Ok(changes),
        Err(e) => {
            let msg = e.to_string().to_lowercase();
            if msg.contains("no column named") && msg.contains("semantic_id") {
                // Fallback for older schemas without semantic_id column.
                conn.execute(
                    "INSERT OR IGNORE INTO registry_deltas
                        (project_id, idempotency_key, delta_type, payload, applied_at)
                     VALUES (?1, ?2, ?3, ?4, datetime('now'))",
                    rusqlite::params![project_id, idempotency_key, delta_type, payload],
                )
                .map_err(|e2| format!("delta insert failed: {e2}"))
            } else {
                Err(format!("delta insert failed: {e}"))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: normalize component payload
// ---------------------------------------------------------------------------

fn normalize_component_payload(
    payload: &Value,
    ctx: &ServerContext,
) -> Result<NormalizedComponent, String> {
    let obj = as_required_object(payload, "component")?;
    validate_project_id_matches(&ctx.project_id, &obj)?;

    let semantic_id = resolve_semantic_id(&obj)?;
    let symbol = get_alias_string(&obj, &["name", "symbol"])?
        .unwrap_or_else(|| extract_name_from_id(&semantic_id));
    let module =
        get_present_string(&obj, "module")?.unwrap_or_else(|| extract_module_from_id(&semantic_id));
    let module = if looks_like_path_target(&module) {
        normalize_repo_relative_path(&ctx.repo_root, &module, "module")?
    } else {
        module
    };
    let file_path = get_alias_string(&obj, &["file_path", "path", "file"])?
        .map(|path| normalize_repo_relative_path(&ctx.repo_root, &path, "file_path"))
        .transpose()?
        .filter(|path| !path.is_empty())
        .ok_or_else(|| format!("component {semantic_id} is missing file_path"))?;
    let kind = get_present_string(&obj, "kind")?.unwrap_or_else(|| "unknown".to_string());
    let status = match get_exact_alias_string(&obj, &["status", "_status"])? {
        Some(value) => normalize_queryable_status(&value)?,
        None => "active".to_string(),
    };
    let exports_json = vec_to_json_string(get_array_alias_string(&obj, &["exports", "exported"])?);
    let imports_json =
        vec_to_json_string(get_array_alias_string(&obj, &["imports", "dependencies"])?);
    let figma_ref = get_present_string(&obj, "figma_ref")?;
    let inactive_reason = get_alias_string(&obj, &["inactive_reason", "_inactive_reason"])?;
    let security_level = get_present_string(&obj, "security_level")?;

    let hash = get_present_string(&obj, "hash")?.unwrap_or_else(|| {
        sha256_hex(&stable_stringify(&serde_json::json!({
            "exports": serde_json::from_str::<Value>(&exports_json).unwrap_or(Value::Array(vec![])),
            "figma_ref": figma_ref,
            "file_path": file_path,
            "imports": serde_json::from_str::<Value>(&imports_json).unwrap_or(Value::Array(vec![])),
            "inactive_reason": inactive_reason,
            "kind": kind,
            "module": module,
            "name": symbol,
            "security_level": security_level,
            "semantic_id": semantic_id,
            "status": status,
        })))
    });

    let idem = sha256_hex(&stable_stringify(&serde_json::json!({
        "hash": hash,
        "semantic_id": semantic_id,
        "status": status,
    })));

    Ok(NormalizedComponent {
        semantic_id,
        name: symbol,
        module,
        file_path,
        kind,
        exports_json,
        imports_json,
        hash,
        figma_ref,
        status,
        inactive_reason,
        security_level,
        idem,
    })
}

fn build_upsert_delta_payload(components: &[NormalizedComponent]) -> String {
    let comps: Vec<Value> = components
        .iter()
        .map(|c| {
            serde_json::json!({
                "exports": serde_json::from_str::<Value>(&c.exports_json).unwrap_or(Value::Array(vec![])),
                "figma_ref": c.figma_ref,
                "file_path": c.file_path,
                "hash": c.hash,
                "idem": c.idem,
                "imports": serde_json::from_str::<Value>(&c.imports_json).unwrap_or(Value::Array(vec![])),
                "inactive_reason": c.inactive_reason,
                "kind": c.kind,
                "module": c.module,
                "name": c.name,
                "security_level": c.security_level,
                "semantic_id": c.semantic_id,
                "status": c.status,
            })
        })
        .collect();
    stable_stringify(&serde_json::json!({
        "components": comps,
        "delta_type": "upsert",
    }))
}

fn is_row_in_sync(row: &ComponentRow, comp: &NormalizedComponent) -> bool {
    row.name == comp.name
        && row.module == comp.module
        && row.file_path == comp.file_path
        && row.kind == comp.kind
        && row.exports == comp.exports_json
        && row.imports == comp.imports_json
        && row.hash == comp.hash
        && row.figma_ref == comp.figma_ref
        && row.status == comp.status
        && row.inactive_reason == comp.inactive_reason
        && row.security_level == comp.security_level
        && row.idem == comp.idem
}

fn assert_target_lock_contract(comp: &NormalizedComponent) -> Result<(), String> {
    if !looks_like_path_target(&comp.module) {
        return Ok(());
    }
    let norm_module = normalize_path_like(&comp.module);
    let norm_path = normalize_path_like(&comp.file_path);
    if norm_module != norm_path {
        return Err(format!(
            "sem.registry.upsert failed: component {} target_lock mismatch: module {} expects file_path {}, received {}",
            comp.semantic_id, comp.module, comp.module, comp.file_path
        ));
    }
    Ok(())
}

fn assert_registry_ownership_lock(
    conn: &rusqlite::Connection,
    ctx: &ServerContext,
    entry: &NormalizedComponent,
    current_row: Option<&ComponentRow>,
) -> Result<(), String> {
    let norm_path = normalize_path_like(&entry.file_path);

    if let Some(row) = current_row {
        if row.status != "deleted" && normalize_path_like(&row.file_path) != norm_path {
            return Err(format!(
                "sem.registry.upsert failed: component {} registry ownership mismatch: existing file_path {}, requested {}",
                entry.semantic_id, row.file_path, entry.file_path
            ));
        }
    }

    let mut stmt = conn
        .prepare(
            "SELECT semantic_id, file_path FROM components
             WHERE project_id = ?1 AND name = ?2 AND semantic_id != ?3 AND status != 'deleted'
             ORDER BY updated_at DESC, semantic_id ASC",
        )
        .map_err(|e| format!("ownership check failed: {e}"))?;

    let rows = stmt
        .query_map(
            rusqlite::params![ctx.project_id, entry.name, entry.semantic_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .map_err(|e| format!("ownership check failed: {e}"))?;

    for row_result in rows {
        let (sid, fp) = row_result.map_err(|e| format!("ownership row error: {e}"))?;
        if normalize_path_like(&fp) == norm_path {
            return Err(format!(
                "sem.registry.upsert failed: component {} registry ownership mismatch: {} already owns {}",
                entry.semantic_id, sid, fp
            ));
        }
    }

    Ok(())
}

fn assert_no_duplicate_ownership(entries: &[NormalizedComponent]) -> Result<(), String> {
    let mut ownership: HashMap<String, &NormalizedComponent> = HashMap::new();
    for entry in entries {
        let key = format!(
            "{}|{}",
            entry.name.trim(),
            normalize_path_like(&entry.file_path)
        );
        if let Some(existing) = ownership.get(&key) {
            if existing.semantic_id != entry.semantic_id {
                return Err(format!(
                    "sem.registry.upsert failed: registry ownership mismatch: {} and {} both claim {}",
                    existing.semantic_id,
                    entry.semantic_id,
                    normalize_path_like(&entry.file_path)
                ));
            }
        } else {
            ownership.insert(key, entry);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Helper: extract component payloads from various input shapes
// ---------------------------------------------------------------------------

const REGISTRY_COMPONENT_ALLOWED_KEYS: &[&str] = &[
    "project_id",
    "semantic_id",
    "logical_id",
    "name",
    "symbol",
    "module",
    "file_path",
    "path",
    "file",
    "kind",
    "exports",
    "exported",
    "imports",
    "dependencies",
    "hash",
    "figma_ref",
    "status",
    "_status",
    "inactive_reason",
    "_inactive_reason",
    "security_level",
];

const REGISTRY_DELTA_COLLECTION_ALLOWED_KEYS: &[&str] = &["project_id", "components", "deltas"];
const REGISTRY_DELTA_ALIAS_ALLOWED_KEYS: &[&str] = &["project_id", "component", "after", "value"];
const REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS: &[&str] = &["project_id", "components", "deltas"];
const REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS: &[&str] = &["project_id", "delta"];

fn validate_registry_upsert_input(obj: &serde_json::Map<String, Value>) -> Result<(), String> {
    assert_allowed_keys_any(
        obj,
        &[
            REGISTRY_COMPONENT_ALLOWED_KEYS,
            REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS,
            REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS,
        ],
        "upsert input",
    )?;

    if obj.contains_key("delta") {
        validate_registry_upsert_alias_envelope(obj, "upsert input")?;
        return Ok(());
    }

    if obj.contains_key("components") || obj.contains_key("deltas") {
        validate_registry_upsert_collection_envelope(obj, "upsert input")?;
        return Ok(());
    }

    if looks_like_component(obj) {
        validate_registry_component_payload(obj, "upsert input")?;
        return Ok(());
    }

    Err("components or deltas are required".into())
}

fn validate_registry_upsert_collection_envelope(
    obj: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<(), String> {
    validate_registry_collection_envelope(obj, REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS, label)
}

fn validate_registry_upsert_alias_envelope(
    obj: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<(), String> {
    assert_allowed_keys(obj, REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS, label)?;
    let delta = obj
        .get("delta")
        .ok_or_else(|| format!("{label}.delta is required"))?;
    validate_registry_delta_envelope_value(delta, &format!("{label}.delta"))
}

fn validate_registry_delta_collection_envelope(
    obj: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<(), String> {
    validate_registry_collection_envelope(obj, REGISTRY_DELTA_COLLECTION_ALLOWED_KEYS, label)
}

fn validate_registry_delta_alias_envelope(
    obj: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<(), String> {
    assert_allowed_keys(obj, REGISTRY_DELTA_ALIAS_ALLOWED_KEYS, label)?;

    let alias_keys = ["component", "after", "value"];
    let present_aliases: Vec<&str> = alias_keys
        .iter()
        .copied()
        .filter(|key| obj.contains_key(*key))
        .collect();

    if present_aliases.len() != 1 {
        return Err(format!(
            "{label} must specify exactly one of component/after/value"
        ));
    }

    let alias_key = present_aliases[0];
    let payload = obj.get(alias_key).expect("present alias key");
    let component = payload
        .as_object()
        .ok_or_else(|| format!("{label}.{alias_key} must be an object"))?;
    validate_registry_component_payload(component, &format!("{label}.{alias_key}"))
}

fn validate_registry_collection_envelope(
    obj: &serde_json::Map<String, Value>,
    allowed_keys: &[&str],
    label: &str,
) -> Result<(), String> {
    assert_allowed_keys(obj, allowed_keys, label)?;

    if let Some(value) = obj.get("components") {
        let components = value
            .as_array()
            .ok_or_else(|| format!("{label}.components must be an array"))?;
        for (index, component) in components.iter().enumerate() {
            let component = component
                .as_object()
                .ok_or_else(|| format!("{label}.components[{index}] must be an object"))?;
            validate_registry_component_payload(
                component,
                &format!("{label}.components[{index}]"),
            )?;
        }
    }

    if let Some(value) = obj.get("deltas") {
        let deltas = value
            .as_array()
            .ok_or_else(|| format!("{label}.deltas must be an array"))?;
        for (index, delta) in deltas.iter().enumerate() {
            validate_registry_delta_item_payload(delta, &format!("{label}.deltas[{index}]"))?;
        }
    }

    Ok(())
}

fn validate_registry_delta_envelope_value(value: &Value, label: &str) -> Result<(), String> {
    if let Some(entries) = value.as_array() {
        if entries.is_empty() {
            return Err(format!("{label} must not be empty"));
        }
        for (index, entry) in entries.iter().enumerate() {
            validate_registry_delta_item_payload(entry, &format!("{label}[{index}]"))?;
        }
        return Ok(());
    }

    let envelope = value
        .as_object()
        .ok_or_else(|| format!("{label} must be an object or array"))?;

    if envelope.contains_key("components") || envelope.contains_key("deltas") {
        validate_registry_delta_collection_envelope(envelope, label)?;
        return Ok(());
    }

    if envelope.contains_key("component")
        || envelope.contains_key("after")
        || envelope.contains_key("value")
    {
        validate_registry_delta_alias_envelope(envelope, label)?;
        return Ok(());
    }

    if looks_like_component(envelope) {
        validate_registry_component_payload(envelope, label)?;
        return Ok(());
    }

    Err(format!(
        "{label} must contain components, deltas, or exactly one of component/after/value"
    ))
}

fn validate_registry_delta_item_payload(value: &Value, label: &str) -> Result<(), String> {
    let item = value
        .as_object()
        .ok_or_else(|| format!("{label} must be an object"))?;

    if item.contains_key("component") || item.contains_key("after") || item.contains_key("value") {
        validate_registry_delta_alias_envelope(item, label)?;
        return Ok(());
    }

    validate_registry_component_payload(item, label)
}

fn validate_registry_component_payload(
    obj: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<(), String> {
    assert_allowed_keys(obj, REGISTRY_COMPONENT_ALLOWED_KEYS, label)
}

fn assert_allowed_keys_any(
    obj: &serde_json::Map<String, Value>,
    allowed_key_sets: &[&[&str]],
    label: &str,
) -> Result<(), String> {
    let unexpected: Vec<&str> = obj
        .keys()
        .map(String::as_str)
        .filter(|key| !allowed_key_sets.iter().any(|allowed| allowed.contains(key)))
        .collect();
    if unexpected.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{label} contains unexpected keys: {}",
            unexpected.join(", ")
        ))
    }
}

fn assert_allowed_keys(
    obj: &serde_json::Map<String, Value>,
    allowed_keys: &[&str],
    label: &str,
) -> Result<(), String> {
    let unexpected: Vec<&str> = obj
        .keys()
        .map(String::as_str)
        .filter(|key| !allowed_keys.contains(key))
        .collect();
    if unexpected.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{label} contains unexpected keys: {}",
            unexpected.join(", ")
        ))
    }
}

fn extract_component_payloads(
    input: &serde_json::Map<String, Value>,
    project_id: &str,
) -> Result<Vec<Value>, String> {
    let mut collected: Vec<Value> = Vec::new();

    if let Some(Value::Array(components)) = input.get("components") {
        collected.extend(components.iter().cloned());
    }

    if let Some(Value::Array(deltas)) = input.get("deltas") {
        for delta in deltas {
            collected.push(unwrap_delta_item(delta, project_id)?);
        }
    }

    if let Some(delta) = input.get("delta") {
        match delta {
            Value::Array(arr) => {
                for entry in arr {
                    collected.push(unwrap_delta_item(entry, project_id)?);
                }
            }
            Value::Object(_) => {
                let items = extract_delta_envelope_items(delta, project_id)?;
                collected.extend(items);
            }
            _ => {}
        }
    }

    if !collected.is_empty() {
        return Ok(collected);
    }

    // Check if the input itself looks like a component.
    if looks_like_component(input) {
        return Ok(vec![Value::Object(input.clone())]);
    }

    Ok(Vec::new())
}

fn unwrap_delta_item(delta: &Value, project_id: &str) -> Result<Value, String> {
    if let Some(obj) = delta.as_object() {
        validate_project_id_matches(project_id, obj)?;
        if let Some(payload) = resolve_single_delta_alias(obj, project_id)? {
            return Ok(payload);
        }
    }
    Ok(delta.clone())
}

fn extract_delta_envelope_items(delta: &Value, project_id: &str) -> Result<Vec<Value>, String> {
    let obj = delta
        .as_object()
        .ok_or_else(|| "delta must be an object".to_string())?;
    validate_project_id_matches(project_id, obj)?;

    let alias_payload = resolve_single_delta_alias(obj, project_id)?;

    let mut collected: Vec<Value> = Vec::new();

    if let Some(Value::Array(components)) = obj.get("components") {
        collected.extend(components.iter().cloned());
    }
    if let Some(Value::Array(deltas)) = obj.get("deltas") {
        for d in deltas {
            collected.push(unwrap_delta_item(d, project_id)?);
        }
    }
    if let Some(payload) = alias_payload {
        collected.push(payload);
    }

    if !collected.is_empty() {
        return Ok(collected);
    }

    if looks_like_component(obj) {
        return Ok(vec![Value::Object(obj.clone())]);
    }

    Err(
        "delta envelope must contain components, deltas, or exactly one of component/after/value"
            .into(),
    )
}

fn resolve_single_delta_alias(
    obj: &serde_json::Map<String, Value>,
    project_id: &str,
) -> Result<Option<Value>, String> {
    let alias_keys = ["component", "after", "value"];
    let mut found: Vec<(&str, Value)> = Vec::new();

    for key in &alias_keys {
        if let Some(v) = obj.get(*key) {
            if !v.is_null() {
                if let Some(inner) = v.as_object() {
                    validate_project_id_matches(project_id, inner)?;
                }
                found.push((key, v.clone()));
            }
        }
    }

    match found.len() {
        0 => Ok(None),
        1 => Ok(Some(found[0].1.clone())),
        _ => Err("delta alias envelope must specify exactly one of component/after/value".into()),
    }
}

fn looks_like_component(obj: &serde_json::Map<String, Value>) -> bool {
    obj.contains_key("semantic_id")
        || obj.contains_key("logical_id")
        || obj.contains_key("module")
        || obj.contains_key("name")
        || obj.contains_key("symbol")
        || obj.contains_key("file_path")
        || obj.contains_key("path")
        || obj.contains_key("file")
}

// ---------------------------------------------------------------------------
// Helper: resolve semantic_id
// ---------------------------------------------------------------------------

fn resolve_semantic_id(obj: &serde_json::Map<String, Value>) -> Result<String, String> {
    let mut identifiers: Vec<String> = Vec::new();

    if let Some(sid) = get_present_exact_string(obj, "semantic_id")? {
        identifiers.push(normalize_identifier(&sid)?);
    }
    if let Some(lid) = get_present_exact_string(obj, "logical_id")? {
        identifiers.push(normalize_identifier(&lid)?);
    }

    let module = get_present_string(obj, "module")?;
    let name = get_present_string(obj, "name")?;
    let symbol = get_present_string(obj, "symbol")?;

    if let (Some(m), Some(n)) = (&module, &name) {
        identifiers.push(normalize_identifier(&format!("{m}:{n}"))?);
    }
    if let (Some(m), Some(s)) = (&module, &symbol) {
        identifiers.push(normalize_identifier(&format!("{m}:{s}"))?);
    }

    let unique: HashSet<&String> = identifiers.iter().collect();
    let unique: Vec<&String> = unique.into_iter().collect();

    match unique.len() {
        0 => Err("semantic_id is required".to_string()),
        1 => Ok(unique[0].clone()),
        _ => Err("identifier sources must resolve to the same semantic_id".to_string()),
    }
}

fn normalize_identifier(value: &str) -> Result<String, String> {
    // Must be "module:name" format (no whitespace, no extra colons).
    let re_check = value.contains(':')
        && !value.chars().any(char::is_whitespace)
        && value.matches(':').count() == 1
        && !value.starts_with(':')
        && !value.ends_with(':');
    if !re_check {
        return Err(format!(
            "identifier must use module:name format, got: {value}"
        ));
    }
    Ok(value.to_string())
}

fn extract_module_from_id(semantic_id: &str) -> String {
    match semantic_id.find(':') {
        Some(idx) if idx > 0 => semantic_id[..idx].to_string(),
        _ => "unknown".to_string(),
    }
}

fn extract_name_from_id(semantic_id: &str) -> String {
    match semantic_id.find(':') {
        Some(idx) if idx < semantic_id.len() - 1 => semantic_id[idx + 1..].to_string(),
        _ => semantic_id.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Helper: compact query response
// ---------------------------------------------------------------------------

fn compact_query_response(items: Vec<QueryItem>, total: i64) -> QueryResponse {
    let was_trimmed = items.len() > QUERY_RESPONSE_ITEM_LIMIT;
    let mut compact = if was_trimmed {
        items[..QUERY_RESPONSE_ITEM_LIMIT].to_vec()
    } else {
        items
    };
    let mut truncated = was_trimmed;

    let mut resp = build_query_response(&compact, total, truncated);

    while !compact.is_empty()
        && serde_json::to_string(&resp).map(|s| s.len()).unwrap_or(0) > QUERY_RESPONSE_CHAR_BUDGET
    {
        compact.pop();
        truncated = true;
        resp = build_query_response(&compact, total, truncated);
    }

    if serde_json::to_string(&resp).map(|s| s.len()).unwrap_or(0) > QUERY_RESPONSE_CHAR_BUDGET {
        return QueryResponse {
            items: Vec::new(),
            total,
            capsule: format!("matched:{total} returned:0 truncated:true"),
        };
    }

    resp
}

fn build_query_response(items: &[QueryItem], total: i64, truncated: bool) -> QueryResponse {
    let capsule = if truncated {
        format!("matched:{total} returned:{} truncated:true", items.len())
    } else {
        format!("matched:{total} returned:{}", items.len())
    };
    QueryResponse {
        items: items.to_vec(),
        total,
        capsule,
    }
}

// ---------------------------------------------------------------------------
// Helper: query status resolution
// ---------------------------------------------------------------------------

fn resolve_query_statuses(
    obj: &serde_json::Map<String, Value>,
) -> Result<Option<Vec<String>>, String> {
    let has_status = obj.contains_key("status");
    let has_statuses = obj.contains_key("statuses");

    if !has_status && !has_statuses {
        return Ok(None);
    }

    let single = if has_status {
        Some(vec![normalize_queryable_status(
            &get_present_exact_string(obj, "status")?.ok_or("status is required")?,
        )?])
    } else {
        None
    };

    let multi = if has_statuses {
        Some(normalize_status_array(obj.get("statuses"))?)
    } else {
        None
    };

    if let (Some(single_values), Some(multi_values)) = (&single, &multi) {
        let single_set: HashSet<&String> = single_values.iter().collect();
        let multi_set: HashSet<&String> = multi_values.iter().collect();
        if single_set != multi_set {
            return Err("status/statuses aliases must match".to_string());
        }
    }

    Ok(multi.or(single))
}

fn normalize_status_array(value: Option<&Value>) -> Result<Vec<String>, String> {
    let arr = value
        .and_then(|v| v.as_array())
        .ok_or_else(|| "statuses must be an array".to_string())?;
    let mut result: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for (i, item) in arr.iter().enumerate() {
        let s = item
            .as_str()
            .ok_or_else(|| format!("statuses[{i}] must be string"))?;
        let normalized = normalize_queryable_status(s)?;
        if seen.insert(normalized.clone()) {
            result.push(normalized);
        }
    }
    Ok(result)
}

fn normalize_mutable_status(status: &str) -> Result<String, String> {
    let s = status.trim();
    if s.is_empty() {
        return Err("status must not be blank".to_string());
    }
    if MUTABLE_STATUSES.contains(&s) {
        return Ok(s.to_string());
    }
    Err(format!(
        "status must be one of: {}",
        MUTABLE_STATUSES.join(", ")
    ))
}

fn normalize_queryable_status(status: &str) -> Result<String, String> {
    let s = status.trim();
    if s.is_empty() {
        return Err("status must not be blank".to_string());
    }
    if QUERYABLE_STATUSES.contains(&s) {
        return Ok(s.to_string());
    }
    Err(format!(
        "status must be one of: {}",
        QUERYABLE_STATUSES.join(", ")
    ))
}

// ---------------------------------------------------------------------------
// Helper: input validation
// ---------------------------------------------------------------------------

fn validate_project_id_match(
    ctx: &ServerContext,
    obj: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    validate_project_id_matches(&ctx.project_id, obj)
}

fn validate_project_id_matches(
    expected: &str,
    obj: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    if let Some(pid) = get_present_string(obj, "project_id")? {
        if pid != expected {
            return Err("project_id must match context project_id".to_string());
        }
    }
    Ok(())
}

fn as_required_object(
    value: &Value,
    field: &str,
) -> Result<serde_json::Map<String, Value>, String> {
    value
        .as_object()
        .cloned()
        .ok_or_else(|| format!("{field} must be an object"))
}

fn get_present_string(
    obj: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, String> {
    match obj.get(key) {
        None => Ok(None),
        Some(Value::Null) => Err(format!("field '{}' must not be null", key)),
        Some(Value::String(s)) if !s.trim().is_empty() => Ok(Some(s.trim().to_string())),
        Some(Value::String(_)) => Err(format!("field '{}' must not be blank", key)),
        Some(other) => Err(format!("field '{}' must be a string, got {}", key, other)),
    }
}

fn get_present_exact_string(
    obj: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, String> {
    match obj.get(key) {
        None => Ok(None),
        Some(Value::Null) => Err(format!("field '{}' must not be null", key)),
        Some(Value::String(s)) if s.trim().is_empty() => {
            Err(format!("field '{}' must not be blank", key))
        }
        Some(Value::String(s)) => Ok(Some(s.to_string())),
        Some(other) => Err(format!("field '{}' must be a string, got {}", key, other)),
    }
}

fn get_required_string(obj: &serde_json::Map<String, Value>, key: &str) -> Result<String, String> {
    get_present_exact_string(obj, key)?.ok_or_else(|| format!("{key} is required"))
}

fn get_alias_string(
    obj: &serde_json::Map<String, Value>,
    keys: &[&str],
) -> Result<Option<String>, String> {
    let mut found: Option<(String, &str)> = None; // (value, key_that_set_it)
    for &key in keys {
        if let Some(s) = get_present_string(obj, key)? {
            if let Some((ref existing_val, ref existing_key)) = found {
                if *existing_val != s {
                    return Err(format!(
                        "inconsistent values: '{}' = {:?} vs '{}' = {:?}",
                        existing_key, existing_val, key, s
                    ));
                }
            } else {
                found = Some((s, key));
            }
        }
    }
    Ok(found.map(|(v, _)| v))
}

fn get_exact_alias_string(
    obj: &serde_json::Map<String, Value>,
    keys: &[&str],
) -> Result<Option<String>, String> {
    let mut found: Option<(String, &str)> = None;
    for &key in keys {
        if let Some(s) = get_present_exact_string(obj, key)? {
            if let Some((ref existing_val, ref existing_key)) = found {
                if *existing_val != s {
                    return Err(format!(
                        "inconsistent values: '{}' = {:?} vs '{}' = {:?}",
                        existing_key, existing_val, key, s
                    ));
                }
            } else {
                found = Some((s, key));
            }
        }
    }
    Ok(found.map(|(v, _)| v))
}

fn get_array_alias_string(
    obj: &serde_json::Map<String, Value>,
    keys: &[&str],
) -> Result<Option<Vec<String>>, String> {
    let mut found: Option<(Vec<String>, &str)> = None;
    for &key in keys {
        let Some(value) = obj.get(key) else {
            continue;
        };
        let arr = match value {
            Value::Null => return Err(format!("field '{}' must not be null", key)),
            Value::Array(arr) => arr,
            other => return Err(format!("field '{}' must be an array, got {}", key, other)),
        };
        let mut strings: Vec<String> = Vec::new();
        for (index, item) in arr.iter().enumerate() {
            match item {
                Value::String(value) => strings.push(value.to_string()),
                other => {
                    return Err(format!(
                        "field '{}[{}]' must be a string, got {}",
                        key, index, other
                    ));
                }
            }
        }
        if let Some((ref existing, ref existing_key)) = found {
            if *existing != strings {
                return Err(format!(
                    "inconsistent array values: '{}' vs '{}'",
                    existing_key, key
                ));
            }
        } else {
            found = Some((strings, key));
        }
    }
    Ok(found.map(|(v, _)| v))
}

fn vec_to_json_string(v: Option<Vec<String>>) -> String {
    match v {
        Some(strings) => {
            let arr: Vec<Value> = strings.into_iter().map(Value::String).collect();
            stable_stringify(&Value::Array(arr))
        }
        None => "[]".to_string(),
    }
}

fn parse_optional_int(
    obj: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<i64>, String> {
    match obj.get(key) {
        None => Ok(None),
        Some(Value::Null) => Err(format!("{key} must not be null")),
        Some(Value::Number(n)) => n
            .as_i64()
            .ok_or_else(|| format!("{key} must be an integer"))
            .map(Some),
        Some(Value::String(s)) => s
            .parse::<i64>()
            .map(Some)
            .map_err(|_| format!("{key} must be an integer")),
        _ => Err(format!("{key} must be an integer")),
    }
}

fn looks_like_path_target(input: &str) -> bool {
    crate::util::looks_like_path_target(input)
}

fn normalize_path_prefix(input: &str) -> String {
    let replaced = input.trim().replace('\\', "/");
    let preserve_trailing_slash = replaced.ends_with('/') || replaced.ends_with('\\');
    let mut normalized = canonicalize_path_like(&replaced);
    if preserve_trailing_slash && !normalized.is_empty() && !normalized.ends_with('/') {
        normalized.push('/');
    }
    normalized
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

    fn make_component(semantic_id: &str, file_path: &str) -> Value {
        serde_json::json!({
            "semantic_id": semantic_id,
            "file_path": file_path,
            "kind": "function",
        })
    }

    fn upsert_one(ctx: &ServerContext, semantic_id: &str, file_path: &str) -> Value {
        let input = serde_json::json!({
            "components": [make_component(semantic_id, file_path)]
        });
        handle_upsert(ctx, &input).unwrap()
    }

    // -- Upsert tests --

    #[test]
    fn test_upsert_new_component() {
        let ctx = test_ctx("proj1");
        let result = upsert_one(&ctx, "mod:foo", "src/foo.rs");
        assert_eq!(result["applied"], true);
        assert_eq!(result["new_count"], 1);
        assert_eq!(result["updated_count"], 0);
    }

    #[test]
    fn test_upsert_update_existing_component() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        // Update with different kind
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:foo",
                "file_path": "src/foo.rs",
                "kind": "struct",
            }]
        });
        let result = handle_upsert(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["updated_count"], 1);
        assert_eq!(result["new_count"], 0);
    }

    #[test]
    fn test_upsert_idempotent_same_data() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:foo",
                "file_path": "src/foo.rs",
                "kind": "function",
            }]
        });
        handle_upsert(&ctx, &input).unwrap();
        let result = handle_upsert(&ctx, &input).unwrap();
        // Second call with same data should not apply
        assert_eq!(result["applied"], false);
        assert_eq!(result["new_count"], 0);
        assert_eq!(result["updated_count"], 0);
    }

    #[test]
    fn test_upsert_with_metadata() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:bar",
                "file_path": "src/bar.rs",
                "kind": "function",
                "exports": ["fn_a", "fn_b"],
                "imports": ["dep_x"],
                "figma_ref": "figma:123",
                "security_level": "high",
            }]
        });
        let result = handle_upsert(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["new_count"], 1);
    }

    #[test]
    fn test_upsert_multiple_components() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "components": [
                make_component("mod:alpha", "src/alpha.rs"),
                make_component("mod:beta", "src/beta.rs"),
                make_component("mod:gamma", "src/gamma.rs"),
            ]
        });
        let result = handle_upsert(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["new_count"], 3);
    }

    #[test]
    fn test_upsert_duplicate_semantic_id_in_batch_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "components": [
                make_component("mod:dup", "src/a.rs"),
                make_component("mod:dup", "src/b.rs"),
            ]
        });
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("duplicate semantic_id"));
    }

    #[test]
    fn test_upsert_empty_components_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({});
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
    }

    #[test]
    fn test_upsert_project_id_mismatch_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "project_id": "other_project",
            "components": [make_component("mod:foo", "src/foo.rs")]
        });
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("project_id"));
    }

    #[test]
    fn registry_upsert_rejects_malformed_and_mixed_envelopes() {
        let ctx = test_ctx("proj1");

        let mixed_collection = handle_upsert(
            &ctx,
            &serde_json::json!({
                "components": [make_component("mod:component", "src/component.rs")],
                "deltas": [{"after": make_component("mod:delta", "src/delta.rs")}],
            }),
        )
        .unwrap();
        assert_eq!(mixed_collection["new_count"], 2);

        let mixed_nested_collection = handle_upsert(
            &ctx,
            &serde_json::json!({
                "delta": {
                    "components": [make_component("mod:nested_component", "src/nested_component.rs")],
                    "deltas": [{"value": make_component("mod:nested_delta", "src/nested_delta.rs")}],
                }
            }),
        )
        .unwrap();
        assert_eq!(mixed_nested_collection["new_count"], 2);

        for input in [
            serde_json::json!({
                "delta": make_component("mod:alias", "src/alias.rs"),
                "components": [make_component("mod:sibling", "src/sibling.rs")],
            }),
            serde_json::json!({
                "components": [make_component("mod:collection", "src/collection.rs")],
                "semantic_id": "mod:top",
                "file_path": "src/top.rs",
            }),
            serde_json::json!({
                "delta": {
                    "components": [make_component("mod:nested", "src/nested.rs")],
                    "after": make_component("mod:after", "src/after.rs"),
                }
            }),
            serde_json::json!({
                "delta": {
                    "component": make_component("mod:component_alias", "src/component_alias.rs"),
                    "after": make_component("mod:after_alias", "src/after_alias.rs"),
                }
            }),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_upsert_rejects_non_array_components_and_deltas() {
        let ctx = test_ctx("proj1");

        for input in [
            serde_json::json!({"components": make_component("mod:bad_components", "src/bad_components.rs")}),
            serde_json::json!({"deltas": make_component("mod:bad_deltas", "src/bad_deltas.rs")}),
            serde_json::json!({"delta": {"components": make_component("mod:bad_nested_components", "src/bad_nested_components.rs")}}),
            serde_json::json!({"delta": {"deltas": make_component("mod:bad_nested_deltas", "src/bad_nested_deltas.rs")}}),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_upsert_rejects_empty_delta_nested_envelope_mix_and_unexpected_keys() {
        let ctx = test_ctx("proj1");

        for input in [
            serde_json::json!({"delta": []}),
            serde_json::json!({"delta": {}}),
            serde_json::json!({
                "delta": {
                    "components": [make_component("mod:nested", "src/nested.rs")],
                    "value": make_component("mod:value", "src/value.rs"),
                }
            }),
            serde_json::json!({
                "components": [make_component("mod:unexpected", "src/unexpected.rs")],
                "unexpected": true,
            }),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    // -- Query tests --

    #[test]
    fn test_query_empty_result() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({});
        let result = handle_query(&ctx, &input).unwrap();
        assert_eq!(result["total"], 0);
        assert!(result["items"].as_array().unwrap().is_empty());
    }

    #[test]
    fn test_query_returns_upserted_components() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");
        upsert_one(&ctx, "mod:bar", "src/bar.rs");

        let input = serde_json::json!({});
        let result = handle_query(&ctx, &input).unwrap();
        assert_eq!(result["total"], 2);
    }

    #[test]
    fn test_query_filter_by_kind() {
        let ctx = test_ctx("proj1");
        let input1 = serde_json::json!({
            "components": [{
                "semantic_id": "mod:foo",
                "file_path": "src/foo.rs",
                "kind": "function",
            }]
        });
        handle_upsert(&ctx, &input1).unwrap();

        let input2 = serde_json::json!({
            "components": [{
                "semantic_id": "mod:bar",
                "file_path": "src/bar.rs",
                "kind": "struct",
            }]
        });
        handle_upsert(&ctx, &input2).unwrap();

        let query = serde_json::json!({"kind": "struct"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);
        assert_eq!(result["items"][0]["kind"], "struct");
    }

    #[test]
    fn test_query_filter_by_status() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        // Default status is "active"
        let query = serde_json::json!({"status": "active"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);

        let query = serde_json::json!({"status": "deprecated"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 0);
    }

    #[test]
    fn test_query_filter_by_name_pattern() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foobar", "src/foobar.rs");
        upsert_one(&ctx, "mod:bazqux", "src/bazqux.rs");

        let query = serde_json::json!({"name_partial": "foo"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);
    }

    #[test]
    fn registry_query_exact_semantic_id_and_name_exact() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "core:UserService", "src/user.rs");
        upsert_one(&ctx, "core:UserServiceExtra", "src/user-extra.rs");

        let exact_by_id = handle_query(
            &ctx,
            &serde_json::json!({"semantic_id": "core:UserService"}),
        )
        .unwrap();
        assert_eq!(
            exact_by_id["items"][0]["semantic_id"].as_str().unwrap(),
            "core:UserService"
        );
        assert_eq!(exact_by_id["total"], 1);

        let exact_by_name =
            handle_query(&ctx, &serde_json::json!({"name_exact": "UserService"})).unwrap();
        assert_eq!(
            exact_by_name["items"][0]["semantic_id"].as_str().unwrap(),
            "core:UserService"
        );
        assert_eq!(exact_by_name["total"], 1);

        let partial_by_name =
            handle_query(&ctx, &serde_json::json!({"name": "UserService"})).unwrap();
        assert_eq!(partial_by_name["total"], 2);
    }

    #[test]
    fn registry_query_rejects_invalid_present_exact_contract_fields() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "core:UserService", "src/user.rs");

        for input in [
            serde_json::json!({"semantic_id": null}),
            serde_json::json!({"semantic_id": 42}),
            serde_json::json!({"semantic_id": ""}),
            serde_json::json!({"semantic_id": "   "}),
            serde_json::json!({"name_exact": null}),
            serde_json::json!({"nameExact": 42}),
            serde_json::json!({"symbol_exact": ""}),
            serde_json::json!({"symbolExact": "   "}),
            serde_json::json!({"status": null}),
            serde_json::json!({"status": 42}),
            serde_json::json!({"status": ""}),
            serde_json::json!({"path_prefix": ""}),
        ] {
            let result = handle_query(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_query_rejects_blank_present_optional_query_fields() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "core:UserService", "src/user.rs");

        for input in [
            serde_json::json!({"kind": ""}),
            serde_json::json!({"kind": "   "}),
            serde_json::json!({"name": ""}),
            serde_json::json!({"name_partial": "   "}),
            serde_json::json!({"namePartial": ""}),
            serde_json::json!({"symbol": "   "}),
        ] {
            let result = handle_query(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
            assert!(result.unwrap_err().contains("blank"));
        }
    }

    #[test]
    fn registry_query_rejects_status_and_statuses_mismatch() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "core:UserService", "src/user.rs");

        let result = handle_query(
            &ctx,
            &serde_json::json!({
                "status": "active",
                "statuses": ["active", "deleted"]
            }),
        );

        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("status/statuses aliases must match"));
    }

    #[test]
    fn registry_query_accepts_matching_status_and_statuses_aliases() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "core:UserService", "src/user.rs");

        let result = handle_query(
            &ctx,
            &serde_json::json!({
                "status": "active",
                "statuses": ["active"]
            }),
        )
        .unwrap();

        assert_eq!(result["total"], 1);
    }

    #[test]
    fn registry_mutations_reject_invalid_present_identifier_and_status_fields() {
        let ctx = test_ctx("proj1");
        for input in [
            serde_json::json!({
                "components": [{
                    "semantic_id": null,
                    "file_path": "src/user.rs",
                    "kind": "function"
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "logical_id": "",
                    "file_path": "src/user.rs",
                    "kind": "function"
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "status": ""
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "_status": null
                }]
            }),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_upsert_rejects_invalid_component_status_values() {
        let ctx = test_ctx("proj1");
        for input in [
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "status": "not-a-status"
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "status": "active",
                    "_status": "deleted"
                }]
            }),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_upsert_rejects_invalid_array_alias_shapes() {
        let ctx = test_ctx("proj1");
        for input in [
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "exports": null
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "imports": "dep"
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "dependencies": [42]
                }]
            }),
            serde_json::json!({
                "components": [{
                    "semantic_id": "core:UserService",
                    "file_path": "src/user.rs",
                    "kind": "function",
                    "exports": ["a"],
                    "exported": ["b"]
                }]
            }),
        ] {
            let result = handle_upsert(&ctx, &input);
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_rejects_identifier_with_non_space_whitespace() {
        let ctx = test_ctx("proj1");

        for input in [
            serde_json::json!({"semantic_id": "core:\tUserService"}),
            serde_json::json!({
                "components": [{
                    "logical_id": "core:\nUserService",
                    "file_path": "src/user.rs",
                    "kind": "function"
                }]
            }),
        ] {
            let result = if input.get("components").is_some() {
                handle_upsert(&ctx, &input)
            } else {
                handle_query(&ctx, &input)
            };
            assert!(result.is_err(), "input should fail closed: {input}");
        }
    }

    #[test]
    fn registry_query_rejects_exact_alias_mismatch() {
        let ctx = test_ctx("proj1");
        let result = handle_query(
            &ctx,
            &serde_json::json!({
                "name_exact": "UserService",
                "nameExact": "OtherService"
            }),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("inconsistent values"));
    }

    #[test]
    fn test_query_with_limit_and_offset() {
        let ctx = test_ctx("proj1");
        for i in 0..5 {
            upsert_one(&ctx, &format!("mod:item{i}"), &format!("src/item{i}.rs"));
        }

        let query = serde_json::json!({"limit": 2, "offset": 0});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 5);
        assert!(result["items"].as_array().unwrap().len() <= 2);

        let query = serde_json::json!({"limit": 2, "offset": 3});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 5);
        assert!(result["items"].as_array().unwrap().len() <= 2);
    }

    #[test]
    fn test_query_isolates_projects() {
        let ctx1 = test_ctx("proj1");
        let ctx2 = test_ctx("proj2");
        upsert_one(&ctx1, "mod:foo", "src/foo.rs");
        upsert_one(&ctx2, "mod:bar", "src/bar.rs");

        let query = serde_json::json!({});
        let r1 = handle_query(&ctx1, &query).unwrap();
        let r2 = handle_query(&ctx2, &query).unwrap();
        assert_eq!(r1["total"], 1);
        assert_eq!(r2["total"], 1);
    }

    // -- Set Status tests --

    #[test]
    fn test_set_status_active_to_deprecated() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        let input = serde_json::json!({
            "semantic_id": "mod:foo",
            "status": "deprecated",
            "reason": "no longer needed"
        });
        let result = handle_set_status(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["old_status"], "active");
        assert_eq!(result["new_status"], "deprecated");
    }

    #[test]
    fn test_set_status_nonexistent_component_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "semantic_id": "mod:nonexistent",
            "status": "deprecated"
        });
        let result = handle_set_status(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    #[test]
    fn test_set_status_invalid_status_errors() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        let input = serde_json::json!({
            "semantic_id": "mod:foo",
            "status": "invalid_status"
        });
        let result = handle_set_status(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("status must be one of"));
    }

    // -- Delete tests --

    #[test]
    fn test_delete_existing_component() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        let input = serde_json::json!({
            "semantic_id": "mod:foo"
        });
        let result = handle_delete(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["semantic_id"], "mod:foo");

        // Verify it's soft-deleted (not returned in active query)
        let query = serde_json::json!({"status": "active"});
        let qr = handle_query(&ctx, &query).unwrap();
        assert_eq!(qr["total"], 0);
    }

    #[test]
    fn test_delete_nonexistent_component_errors() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "semantic_id": "mod:nonexistent"
        });
        let result = handle_delete(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    #[test]
    fn test_delete_idempotent() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");

        let input = serde_json::json!({
            "semantic_id": "mod:foo",
            "reason": "cleanup"
        });
        handle_delete(&ctx, &input).unwrap();
        // Second delete with same reason should not fail
        let result = handle_delete(&ctx, &input).unwrap();
        assert_eq!(result["semantic_id"], "mod:foo");
    }

    #[test]
    fn test_query_deleted_components() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/foo.rs");
        upsert_one(&ctx, "mod:bar", "src/bar.rs");

        let del_input = serde_json::json!({"semantic_id": "mod:foo"});
        handle_delete(&ctx, &del_input).unwrap();

        // Query for deleted status
        let query = serde_json::json!({"status": "deleted"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);

        // Query for active status
        let query = serde_json::json!({"status": "active"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);
    }

    // -- Misc tests --

    #[test]
    fn test_upsert_via_single_component_shape() {
        // Input that looks like a single component (no "components" array)
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "semantic_id": "mod:solo",
            "file_path": "src/solo.rs",
            "kind": "function",
        });
        let result = handle_upsert(&ctx, &input).unwrap();
        assert_eq!(result["applied"], true);
        assert_eq!(result["new_count"], 1);
    }

    #[test]
    fn test_query_path_prefix_filter() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:foo", "src/core/foo.rs");
        upsert_one(&ctx, "mod:bar", "src/util/bar.rs");

        let query = serde_json::json!({"path_prefix": "src/core/"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);
        assert_eq!(result["items"][0]["path"], "src/core/foo.rs");
    }

    #[test]
    fn registry_path_prefix_uses_range_scan() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "mod:zeta", "src/core/zeta.rs");
        upsert_one(&ctx, "mod:alpha", "src/core/alpha.rs");
        upsert_one(&ctx, "mod:other", "src/other.rs");

        let query = serde_json::json!({"path_prefix": "src/core/"});
        let result = handle_query(&ctx, &query).unwrap();
        let items = result["items"].as_array().unwrap();
        assert_eq!(result["total"], 2);
        assert_eq!(items[0]["path"], "src/core/alpha.rs");
        assert_eq!(items[1]["path"], "src/core/zeta.rs");
    }

    #[test]
    fn registry_path_prefix_boundary_excludes_sibling_prefixes() {
        let ctx = test_ctx("proj1");
        upsert_one(&ctx, "ui:Button", "src/app/Button.tsx");
        upsert_one(&ctx, "ui:ButtonGhost", "src/app/ButtonGhost.tsx");
        upsert_one(&ctx, "ui:App2Thing", "src/app2/Thing.tsx");

        let query = serde_json::json!({"path_prefix": "src/app/"});
        let result = handle_query(&ctx, &query).unwrap();
        let semantic_ids: Vec<&str> = result["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["semantic_id"].as_str().unwrap())
            .collect();

        assert_eq!(result["total"], 2);
        assert_eq!(semantic_ids, vec!["ui:Button", "ui:ButtonGhost"]);
    }

    #[test]
    fn test_query_path_prefix_normalizes_variants() {
        let ctx = test_ctx("proj1");
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "./apps/web/src/page.tsx:HomePage",
                "module": "./apps/web/src/page.tsx",
                "file_path": "apps\\web//src/page.tsx",
                "kind": "component",
            }]
        });
        handle_upsert(&ctx, &input).unwrap();

        let query = serde_json::json!({"path_prefix": "./apps\\web//"});
        let result = handle_query(&ctx, &query).unwrap();
        assert_eq!(result["total"], 1);
        assert_eq!(result["items"][0]["path"], "apps/web/src/page.tsx");
    }

    #[test]
    fn registry_rejects_repo_root_path_escape() {
        let repo_root = unique_temp_dir("registry-path-escape");
        let ctx = test_ctx_with_repo_root("proj1", repo_root);
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:escape",
                "file_path": "../escape.rs",
                "kind": "function",
            }]
        });
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("file_path must not traverse"));
    }

    #[test]
    fn registry_rejects_path_like_module_escape() {
        let repo_root = unique_temp_dir("registry-module-escape");
        let ctx = test_ctx_with_repo_root("proj1", repo_root);
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "src/file.rs:Thing",
                "module": "../outside.rs",
                "file_path": "src/file.rs",
                "kind": "function",
            }]
        });
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("module must not traverse"));
    }

    #[cfg(unix)]
    #[test]
    fn registry_rejects_symlink_escape() {
        use std::os::unix::fs::symlink;

        let repo_root = unique_temp_dir("registry-symlink");
        let outside = unique_temp_dir("registry-symlink-outside");
        std::fs::create_dir_all(repo_root.join("links")).unwrap();
        symlink(&outside, repo_root.join("links/outside")).unwrap();
        let ctx = test_ctx_with_repo_root("proj1", repo_root);
        let input = serde_json::json!({
            "components": [{
                "semantic_id": "mod:escape",
                "file_path": "links/outside/file.rs",
                "kind": "function",
            }]
        });
        let result = handle_upsert(&ctx, &input);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("symlinks"));
    }
}
