//! Review queue and review-run CLI operations.
//!
//! These helpers back the Rust CLI surface and intentionally mirror the
//! authoritative TypeScript semantics closely enough for fail-closed queue
//! coordination and release-gate checks.

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::{Component, Path, PathBuf};
use uuid::Uuid;

use crate::util::{canonicalize_path_like, sha256_hex, stable_stringify};

const SOURCE_MAX_LEN: usize = 32;
const LEASE_OWNER_MAX_LEN: usize = 128;
const RUN_ID_MAX_LEN: usize = 128;
const DEFAULT_LEASE_SECONDS: i64 = 900;
const MAX_LEASE_SECONDS: i64 = 86_400;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Single item in the review queue.
#[derive(Debug, Clone, Serialize)]
pub struct QueueItem {
    pub event_id: Option<String>,
    pub dedupe_key: String,
    pub file_path: String,
    pub source: String,
    pub queue_state: String,
    pub first_enqueued_at: String,
    pub last_enqueued_at: String,
    pub lease_owner: Option<String>,
    pub leased_at: Option<String>,
    pub lease_expires_at: Option<String>,
    pub acknowledged_at: Option<String>,
    pub retry_count: i64,
    pub last_error: Option<String>,
}

/// Result of enqueue operation.
#[derive(Debug, Serialize)]
pub struct EnqueueResult {
    pub queued: bool,
    pub duplicate: bool,
    pub item: QueueItem,
}

/// Result of lease operation.
#[derive(Debug, Serialize)]
pub struct LeaseResult {
    pub project_id: String,
    pub lease_owner: Option<String>,
    pub leased_at: String,
    pub lease_expires_at: Option<String>,
    pub leased_count: usize,
    pub items: Vec<QueueItem>,
}

/// Result of complete operation.
#[derive(Debug, Serialize)]
pub struct QueueCompleteResult {
    pub project_id: String,
    pub lease_owner: String,
    pub completed_at: String,
    pub completed_count: usize,
    pub items: Vec<QueueItem>,
}

/// Result of requeue operation.
#[derive(Debug, Serialize)]
pub struct QueueRequeueResult {
    pub project_id: String,
    pub lease_owner: String,
    pub requeued_at: String,
    pub requeued_count: usize,
    pub items: Vec<QueueItem>,
}

/// Exported queue snapshot.
#[derive(Debug, Serialize)]
pub struct QueueExport {
    pub project_id: String,
    pub exported_at: String,
    pub pending_count: usize,
    pub leased_count: usize,
    pub pending_review: bool,
    pub changed_files: Vec<String>,
    pub last_change: String,
    pub items: Vec<QueueItem>,
}

/// Normalized review-run record input.
#[derive(Debug, Clone)]
pub struct ReviewRunRecordInput {
    pub run_id: String,
    pub phase: String,
    pub iteration: i64,
    pub kind: String,
    pub status: String,
    pub queued_files: Vec<String>,
    pub summary: Option<String>,
    pub blocker_summary: Option<String>,
    pub report_body: Option<String>,
    pub report_hash: Option<String>,
    pub findings: Vec<Value>,
    pub consumer: Option<String>,
    pub reviewer: Option<String>,
    pub error_message: Option<String>,
    pub metadata: Value,
}

/// Result of review-run record.
#[derive(Debug, Serialize)]
pub struct ReviewRunRecordResult {
    pub project_id: String,
    pub run_id: String,
    pub phase: String,
    pub iteration: i64,
    pub kind: String,
    pub status: String,
    pub queued_file_count: usize,
    pub report_hash: String,
    pub created_at: String,
}

#[derive(Debug, Clone)]
struct QueueRow {
    id: i64,
    event_id: Option<String>,
    dedupe_key: Option<String>,
    file_path: String,
    queue_state: String,
    first_enqueued_at: String,
    last_enqueued_at: String,
    last_enqueue_source: String,
    lease_run_id: Option<String>,
    lease_event_id: Option<String>,
    lease_owner: Option<String>,
    leased_at: Option<String>,
    lease_expires_at: Option<String>,
    acknowledged_at: Option<String>,
    retry_count: Option<i64>,
    last_error: Option<String>,
}

#[derive(Debug, Clone)]
struct StoredReviewRunRow {
    project_id: String,
    run_id: String,
    phase: Option<String>,
    iteration: Option<i64>,
    kind: Option<String>,
    status: String,
    consumer: Option<String>,
    reviewer: Option<String>,
    file_count: i64,
    files_json: String,
    findings_json: String,
    summary: Option<String>,
    result_summary: Option<String>,
    blocker_summary: Option<String>,
    report_body: Option<String>,
    report_hash: Option<String>,
    error_message: Option<String>,
    metadata_json: String,
    created_at: String,
}

// ---------------------------------------------------------------------------
// Queue operations
// ---------------------------------------------------------------------------

/// Enqueue a file for review.
pub fn enqueue(
    conn: &Connection,
    project_id: &str,
    repo_root: &Path,
    file_path: &str,
    source: &str,
) -> Result<EnqueueResult, String> {
    let file_path = validate_enqueue_file_path(repo_root, file_path)?;
    let source = validate_source(source)?;
    let dedupe_key = file_path.clone();
    let event_id = Uuid::new_v4().to_string();
    let now = current_timestamp(conn)?;

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("enqueue: {e}"))?;

    let existing = select_by_file_path(&tx, project_id, &file_path)?;
    if let Some(existing) = existing {
        if existing.queue_state == "pending" {
            let item = select_item_by_id(&tx, existing.id)?;
            tx.commit().map_err(|e| format!("commit: {e}"))?;
            return Ok(EnqueueResult {
                queued: false,
                duplicate: true,
                item,
            });
        }

        let was_done = existing.queue_state == "done";
        let new_state = if was_done {
            "pending"
        } else {
            existing.queue_state.as_str()
        };
        let first_enqueued_at = if was_done {
            now.as_str()
        } else {
            existing.first_enqueued_at.as_str()
        };

        tx.execute(
            "UPDATE review_queue_items
             SET event_id = ?1,
                 dedupe_key = ?2,
                 queue_state = ?3,
                 first_enqueued_at = ?4,
                 last_enqueued_at = ?5,
                 last_enqueue_source = ?6,
                 payload = '{}',
                 lease_run_id = ?7,
                 lease_event_id = ?8,
                 lease_owner = ?9,
                 leased_at = ?10,
                 lease_expires_at = ?11,
                 acknowledged_at = NULL,
                 completed_at = NULL,
                 completed_run_id = NULL,
                 last_error = NULL,
                 attempt_count = CASE
                   WHEN ?12 = 'done' THEN 0
                   ELSE attempt_count
                 END,
                 retry_count = CASE
                   WHEN ?12 = 'done' THEN 0
                   ELSE retry_count
                 END
             WHERE id = ?13",
            params![
                event_id,
                dedupe_key,
                new_state,
                first_enqueued_at,
                now,
                source,
                if existing.queue_state == "leased" {
                    existing.lease_run_id.clone()
                } else {
                    None
                },
                if existing.queue_state == "leased" {
                    existing.lease_event_id.clone()
                } else {
                    None
                },
                if existing.queue_state == "leased" {
                    existing.lease_owner.clone()
                } else {
                    None
                },
                if existing.queue_state == "leased" {
                    existing.leased_at.clone()
                } else {
                    None
                },
                if existing.queue_state == "leased" {
                    existing.lease_expires_at.clone()
                } else {
                    None
                },
                existing.queue_state,
                existing.id
            ],
        )
        .map_err(|e| format!("enqueue update: {e}"))?;

        let item = select_item_by_id(&tx, existing.id)?;
        tx.commit().map_err(|e| format!("commit: {e}"))?;
        return Ok(EnqueueResult {
            queued: true,
            duplicate: false,
            item,
        });
    }

    tx.execute(
        "INSERT INTO review_queue_items (
            project_id,
            event_id,
            dedupe_key,
            file_path,
            queue_state,
            first_enqueued_at,
            last_enqueued_at,
            last_enqueue_source,
            payload,
            lease_run_id,
            lease_event_id,
            lease_owner,
            leased_at,
            lease_expires_at,
            acknowledged_at,
            completed_at,
            completed_run_id,
            last_error,
            attempt_count,
            retry_count
        )
        VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?5, ?6, '{}', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, 0)",
        params![project_id, event_id, dedupe_key, file_path, now, source],
    )
    .map_err(|e| format!("enqueue insert: {e}"))?;

    let item = select_item_by_id(&tx, tx.last_insert_rowid())?;
    tx.commit().map_err(|e| format!("commit: {e}"))?;

    Ok(EnqueueResult {
        queued: true,
        duplicate: false,
        item,
    })
}

/// Lease all eligible queue items.
pub fn lease(
    conn: &Connection,
    project_id: &str,
    lease_run_id: Option<&str>,
    lease_seconds: Option<i64>,
) -> Result<LeaseResult, String> {
    let lease_run_id = validate_optional_run_id(lease_run_id)?;
    let lease_seconds = normalize_lease_seconds(lease_seconds)?;
    let leased_at = current_timestamp(conn)?;
    let lease_expires_at = plus_seconds(&leased_at, lease_seconds)?;
    let lease_owner = Uuid::new_v4().to_string();

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("lease: {e}"))?;
    let rows = select_lease_candidates(&tx, project_id, &leased_at)?;

    if rows.is_empty() {
        tx.commit().map_err(|e| format!("commit: {e}"))?;
        return Ok(LeaseResult {
            project_id: project_id.to_string(),
            lease_owner: None,
            leased_at,
            lease_expires_at: None,
            leased_count: 0,
            items: Vec::new(),
        });
    }

    let mut update = tx
        .prepare(
            "UPDATE review_queue_items
             SET queue_state = 'leased',
                 lease_run_id = ?1,
                 lease_event_id = ?2,
                 lease_owner = ?3,
                 leased_at = ?4,
                 lease_expires_at = ?5,
                 acknowledged_at = NULL,
                 completed_at = NULL,
                 completed_run_id = NULL,
                 last_error = NULL,
                 attempt_count = attempt_count + 1,
                 retry_count = CASE
                   WHEN queue_state = 'leased' THEN retry_count + 1
                   ELSE retry_count
                 END
             WHERE id = ?6
               AND event_id IS ?7
               AND (
                 queue_state = 'pending'
                 OR (
                   queue_state = 'leased'
                   AND lease_expires_at IS NOT NULL
                   AND lease_expires_at <= ?8
                 )
               )",
        )
        .map_err(|e| format!("lease prepare: {e}"))?;

    let mut leased_rows = Vec::with_capacity(rows.len());
    for row in rows {
        let changes = update
            .execute(params![
                lease_run_id,
                row.event_id.clone(),
                lease_owner,
                leased_at,
                lease_expires_at,
                row.id,
                row.event_id.clone(),
                leased_at
            ])
            .map_err(|e| format!("lease update: {e}"))?;

        if changes != 1 {
            return Err(format!("atomic lease failed for queue row id={}", row.id));
        }

        leased_rows.push(map_queue_row(QueueRow {
            queue_state: "leased".to_string(),
            lease_run_id: lease_run_id.clone(),
            lease_event_id: row.event_id.clone(),
            lease_owner: Some(lease_owner.clone()),
            leased_at: Some(leased_at.clone()),
            lease_expires_at: Some(lease_expires_at.clone()),
            acknowledged_at: None,
            retry_count: Some(if row.queue_state == "leased" {
                row.retry_count.unwrap_or(0) + 1
            } else {
                row.retry_count.unwrap_or(0)
            }),
            last_error: None,
            ..row
        }));
    }

    drop(update);
    tx.commit().map_err(|e| format!("commit: {e}"))?;

    Ok(LeaseResult {
        project_id: project_id.to_string(),
        lease_owner: Some(lease_owner),
        leased_at,
        lease_expires_at: Some(lease_expires_at),
        leased_count: leased_rows.len(),
        items: leased_rows,
    })
}

/// Complete a lease while preserving strict expected-file semantics.
pub fn complete(
    conn: &Connection,
    project_id: &str,
    lease_owner: &str,
    lease_run_id: Option<&str>,
    expected_files: Option<&[String]>,
) -> Result<QueueCompleteResult, String> {
    let lease_owner = validate_lease_owner(lease_owner)?;
    let lease_run_id = validate_optional_run_id(lease_run_id)?;
    let expected_files = validate_optional_expected_files(expected_files)?;
    let completed_at = current_timestamp(conn)?;

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("complete: {e}"))?;
    let rows = select_lease_rows_for_finalization(
        &tx,
        project_id,
        &lease_owner,
        lease_run_id.as_deref(),
        expected_files.as_deref(),
    )?;

    if rows.is_empty() && expected_files.is_none() {
        return Err(format!("lease_owner not found: {lease_owner}"));
    }

    let mut update = tx
        .prepare(
            "UPDATE review_queue_items
             SET queue_state = 'done',
                 lease_run_id = NULL,
                 lease_event_id = NULL,
                 lease_expires_at = NULL,
                 acknowledged_at = ?1,
                 completed_at = ?2,
                 last_error = NULL
             WHERE id = ?3
               AND project_id = ?4
               AND queue_state = 'leased'
               AND lease_owner = ?5
               AND lease_event_id IS event_id
               AND (?6 IS NULL OR lease_run_id IS ?6)",
        )
        .map_err(|e| format!("complete prepare: {e}"))?;
    let mut release_stale = tx
        .prepare(
            "UPDATE review_queue_items
             SET queue_state = 'pending',
                 lease_run_id = NULL,
                 lease_event_id = NULL,
                 lease_owner = NULL,
                 leased_at = NULL,
                 lease_expires_at = NULL,
                 acknowledged_at = NULL,
                 completed_at = NULL,
                 completed_run_id = NULL,
                 last_error = NULL
             WHERE id = ?1
               AND project_id = ?2
               AND queue_state = 'leased'
               AND lease_owner = ?3
               AND NOT (lease_event_id IS event_id)
               AND (?4 IS NULL OR lease_run_id IS ?4)",
        )
        .map_err(|e| format!("complete stale prepare: {e}"))?;

    let mut items = Vec::with_capacity(rows.len());
    let mut completed_count = 0usize;

    for row in rows {
        let changes = update
            .execute(params![
                completed_at,
                completed_at,
                row.id,
                project_id,
                lease_owner,
                lease_run_id
            ])
            .map_err(|e| format!("complete update: {e}"))?;

        if changes == 1 {
            completed_count += 1;
            items.push(map_queue_row(QueueRow {
                queue_state: "done".to_string(),
                lease_run_id: None,
                lease_event_id: None,
                lease_expires_at: None,
                acknowledged_at: Some(completed_at.clone()),
                last_error: None,
                ..row
            }));
            continue;
        }

        let stale_changes = release_stale
            .execute(params![row.id, project_id, lease_owner, lease_run_id])
            .map_err(|e| format!("complete stale update: {e}"))?;
        if stale_changes != 1 {
            return Err(format!("complete failed for queue row id={}", row.id));
        }

        items.push(map_queue_row(QueueRow {
            queue_state: "pending".to_string(),
            lease_run_id: None,
            lease_event_id: None,
            lease_owner: None,
            leased_at: None,
            lease_expires_at: None,
            acknowledged_at: None,
            last_error: None,
            ..row
        }));
    }

    drop(update);
    drop(release_stale);
    tx.commit().map_err(|e| format!("commit: {e}"))?;

    Ok(QueueCompleteResult {
        project_id: project_id.to_string(),
        lease_owner,
        completed_at,
        completed_count,
        items,
    })
}

/// Requeue a lease while preserving strict expected-file semantics.
pub fn requeue(
    conn: &Connection,
    project_id: &str,
    lease_owner: &str,
    lease_run_id: Option<&str>,
    expected_files: Option<&[String]>,
    error_message: Option<&str>,
) -> Result<QueueRequeueResult, String> {
    let lease_owner = validate_lease_owner(lease_owner)?;
    let lease_run_id = validate_optional_run_id(lease_run_id)?;
    let expected_files = validate_optional_expected_files(expected_files)?;
    let error_message = validate_optional_error_message(error_message)?;
    let requeued_at = current_timestamp(conn)?;

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("requeue: {e}"))?;
    let rows = select_lease_rows_for_finalization(
        &tx,
        project_id,
        &lease_owner,
        lease_run_id.as_deref(),
        expected_files.as_deref(),
    )?;

    if rows.is_empty() && expected_files.is_none() {
        return Err(format!("lease_owner not found: {lease_owner}"));
    }

    let mut update = tx
        .prepare(
            "UPDATE review_queue_items
             SET queue_state = 'pending',
                 lease_run_id = NULL,
                 lease_event_id = NULL,
                 lease_owner = NULL,
                 leased_at = NULL,
                 lease_expires_at = NULL,
                 acknowledged_at = NULL,
                 completed_at = NULL,
                 completed_run_id = NULL,
                 last_error = ?1,
                 retry_count = retry_count + 1
             WHERE id = ?2
               AND project_id = ?3
               AND queue_state = 'leased'
               AND lease_owner = ?4
               AND lease_event_id IS event_id
               AND (?5 IS NULL OR lease_run_id IS ?5)",
        )
        .map_err(|e| format!("requeue prepare: {e}"))?;
    let mut release_stale = tx
        .prepare(
            "UPDATE review_queue_items
             SET queue_state = 'pending',
                 lease_run_id = NULL,
                 lease_event_id = NULL,
                 lease_owner = NULL,
                 leased_at = NULL,
                 lease_expires_at = NULL,
                 acknowledged_at = NULL,
                 completed_at = NULL,
                 completed_run_id = NULL,
                 last_error = NULL
             WHERE id = ?1
               AND project_id = ?2
               AND queue_state = 'leased'
               AND lease_owner = ?3
               AND NOT (lease_event_id IS event_id)
               AND (?4 IS NULL OR lease_run_id IS ?4)",
        )
        .map_err(|e| format!("requeue stale prepare: {e}"))?;

    let mut items = Vec::with_capacity(rows.len());
    let mut requeued_count = 0usize;

    for row in rows {
        let changes = update
            .execute(params![
                error_message,
                row.id,
                project_id,
                lease_owner,
                lease_run_id
            ])
            .map_err(|e| format!("requeue update: {e}"))?;

        if changes == 1 {
            requeued_count += 1;
            items.push(map_queue_row(QueueRow {
                queue_state: "pending".to_string(),
                lease_run_id: None,
                lease_event_id: None,
                lease_owner: None,
                leased_at: None,
                lease_expires_at: None,
                acknowledged_at: None,
                retry_count: Some(row.retry_count.unwrap_or(0) + 1),
                last_error: error_message.clone(),
                ..row
            }));
            continue;
        }

        let stale_changes = release_stale
            .execute(params![row.id, project_id, lease_owner, lease_run_id])
            .map_err(|e| format!("requeue stale update: {e}"))?;
        if stale_changes != 1 {
            return Err(format!("requeue failed for queue row id={}", row.id));
        }

        items.push(map_queue_row(QueueRow {
            queue_state: "pending".to_string(),
            lease_run_id: None,
            lease_event_id: None,
            lease_owner: None,
            leased_at: None,
            lease_expires_at: None,
            acknowledged_at: None,
            last_error: None,
            ..row
        }));
    }

    drop(update);
    drop(release_stale);
    tx.commit().map_err(|e| format!("commit: {e}"))?;

    Ok(QueueRequeueResult {
        project_id: project_id.to_string(),
        lease_owner,
        requeued_at,
        requeued_count,
        items,
    })
}

/// Export the review queue as JSON.
pub fn export_json(conn: &Connection, project_id: &str) -> Result<QueueExport, String> {
    let exported_at = current_timestamp(conn)?;
    let rows = select_export_rows(conn, project_id)?;
    let items: Vec<QueueItem> = rows.into_iter().map(map_queue_row).collect();
    let changed_files: Vec<String> = items.iter().map(|item| item.file_path.clone()).collect();
    let pending_count = items
        .iter()
        .filter(|item| item.queue_state == "pending")
        .count();
    let leased_count = items
        .iter()
        .filter(|item| item.queue_state == "leased")
        .count();
    let last_change = items
        .iter()
        .map(|item| {
            if item.leased_at.as_deref().unwrap_or("") > item.last_enqueued_at.as_str() {
                item.leased_at.clone().unwrap_or_default()
            } else {
                item.last_enqueued_at.clone()
            }
        })
        .max()
        .unwrap_or_default();

    Ok(QueueExport {
        project_id: project_id.to_string(),
        exported_at,
        pending_count,
        leased_count,
        pending_review: !items.is_empty(),
        changed_files,
        last_change,
        items,
    })
}

// ---------------------------------------------------------------------------
// Review-run record
// ---------------------------------------------------------------------------

/// Parse CLI JSON payload into a normalized review-run input.
pub fn parse_review_run_record_input(raw: &Value) -> Result<ReviewRunRecordInput, String> {
    let input = unwrap_review_run_input(raw)?;

    let run_id = read_identifier(input, "run_id")?;
    let phase = read_identifier(input, "phase")?;
    let kind = read_identifier(input, "kind")?;
    let status = read_status(input.get("status"))?;
    let iteration = read_iteration(input.get("iteration"))?;
    let queued_files = read_string_array(input.get("queued_files"), "queued_files")?;
    let summary = read_optional_string(input.get("summary"), "summary")?;
    let blocker_summary = read_optional_string(input.get("blocker_summary"), "blocker_summary")?;
    let report_body = read_optional_string(input.get("report_body"), "report_body")?;
    let report_hash = read_optional_hash(input.get("report_hash"))?;
    if report_body.is_none() && report_hash.is_none() {
        return Err("review-run input requires report_body or report_hash".to_string());
    }

    Ok(ReviewRunRecordInput {
        run_id,
        phase,
        iteration,
        kind,
        status,
        queued_files,
        summary,
        blocker_summary,
        report_body,
        report_hash,
        findings: read_optional_array(input.get("findings"), "findings")?.unwrap_or_default(),
        consumer: read_optional_string(input.get("consumer"), "consumer")?,
        reviewer: read_optional_string(input.get("reviewer"), "reviewer")?,
        error_message: read_optional_string(input.get("error_message"), "error_message")?,
        metadata: read_optional_object(input.get("metadata"), "metadata")?
            .cloned()
            .unwrap_or_else(|| Value::Object(Default::default())),
    })
}

/// Record a finalized review run idempotently.
pub fn record_review_run(
    conn: &Connection,
    project_id: &str,
    raw: &Value,
) -> Result<ReviewRunRecordResult, String> {
    let input = parse_review_run_record_input(raw)?;
    let report_hash = resolve_report_hash(&input)?;
    let queued_files_json = serde_json::to_string(&input.queued_files)
        .map_err(|e| format!("queued_files json: {e}"))?;
    let findings_json = stable_stringify(&Value::Array(input.findings.clone()));
    let metadata_json = stable_stringify(&input.metadata);

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("review-run record: {e}"))?;

    if let Some(existing) = select_stored_run(&tx, project_id, &input.run_id)? {
        let replay_action = classify_stored_run_replay(
            &existing,
            &input,
            &report_hash,
            &queued_files_json,
            &findings_json,
            &metadata_json,
        )?;
        let stored = match replay_action {
            StoredRunReplay::Exact => existing,
            StoredRunReplay::UpgradeLegacy => {
                upgrade_legacy_review_run(
                    &tx,
                    project_id,
                    &input,
                    &report_hash,
                    &queued_files_json,
                    &findings_json,
                    &metadata_json,
                )?;
                select_stored_run(&tx, project_id, &input.run_id)?
                    .ok_or_else(|| "review run not found after legacy upgrade".to_string())?
            }
        };
        tx.commit().map_err(|e| format!("commit: {e}"))?;
        return Ok(to_record_result(&stored));
    }

    let timestamp = current_timestamp(&tx)?;
    tx.execute(
        "INSERT INTO review_runs (
            project_id,
            run_id,
            status,
            phase,
            iteration,
            kind,
            consumer,
            reviewer,
            file_count,
            files_json,
            findings_json,
            summary,
            result_summary,
            blocker_summary,
            report_body,
            report_hash,
            error_message,
            metadata_json,
            started_at,
            completed_at,
            created_at,
            updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?18, ?18, ?18)",
        params![
            project_id,
            input.run_id,
            input.status,
            input.phase,
            input.iteration,
            input.kind,
            input.consumer,
            input.reviewer,
            input.queued_files.len() as i64,
            queued_files_json,
            findings_json,
            input.summary,
            input.blocker_summary,
            input.report_body,
            report_hash,
            input.error_message,
            metadata_json,
            timestamp
        ],
    )
    .map_err(|e| format!("review-run insert: {e}"))?;

    let stored = select_stored_run(&tx, project_id, &input.run_id)?
        .ok_or_else(|| "review run not found after write".to_string())?;
    tx.commit().map_err(|e| format!("commit: {e}"))?;

    Ok(to_record_result(&stored))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn current_timestamp(conn: &Connection) -> Result<String, String> {
    conn.query_row("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')", [], |row| {
        row.get(0)
    })
    .map_err(|e| format!("timestamp: {e}"))
}

fn plus_seconds(timestamp: &str, seconds: i64) -> Result<String, String> {
    let parsed = DateTime::parse_from_rfc3339(timestamp)
        .map_err(|e| format!("invalid lease timestamp {timestamp}: {e}"))?;
    Ok((parsed.with_timezone(&Utc) + Duration::seconds(seconds))
        .to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn normalize_lease_seconds(value: Option<i64>) -> Result<i64, String> {
    match value {
        None => Ok(DEFAULT_LEASE_SECONDS),
        Some(seconds) if (1..=MAX_LEASE_SECONDS).contains(&seconds) => Ok(seconds),
        Some(_) => Err(format!(
            "lease_seconds must be an integer between 1 and {MAX_LEASE_SECONDS}"
        )),
    }
}

fn validate_enqueue_file_path(repo_root: &Path, file_path: &str) -> Result<String, String> {
    let normalized = canonicalize_path_like(file_path);
    if normalized.trim().is_empty() || normalized == "." {
        return Err("file_path must not be empty".to_string());
    }
    if file_path.chars().any(|ch| ch.is_control()) {
        return Err("file_path must not contain control bytes".to_string());
    }
    if is_absolute_path_like(&normalized) {
        return Err("file_path must be repo-relative".to_string());
    }

    let canonical_repo_root = repo_root
        .canonicalize()
        .map_err(|e| format!("repo_root must resolve to an existing directory: {e}"))?;
    if !canonical_repo_root.is_dir() {
        return Err("repo_root must resolve to an existing directory".to_string());
    }

    let canonical_relative = canonicalize_relative_path(&normalized, file_path)?;
    assert_no_symlink_components(&canonical_repo_root, &canonical_relative, file_path)?;

    let resolved_path = canonical_repo_root.join(&canonical_relative);
    let relative = resolved_path
        .strip_prefix(&canonical_repo_root)
        .map_err(|_| format!("file_path resolves outside repo_root: {file_path}"))?;

    let stored = canonicalize_path_like(&relative.to_string_lossy());
    if stored.is_empty() || stored == "." {
        return Err("file_path must not be empty".to_string());
    }
    Ok(stored)
}

fn validate_file_path(file_path: &str) -> Result<String, String> {
    let normalized = canonicalize_path_like(file_path);
    if normalized.trim().is_empty() {
        return Err("file_path must not be empty".to_string());
    }
    if file_path.chars().any(|ch| ch.is_control()) {
        return Err("file_path must not contain control bytes".to_string());
    }
    Ok(normalized)
}

fn canonicalize_relative_path(normalized_path: &str, raw_path: &str) -> Result<PathBuf, String> {
    let mut relative = PathBuf::new();

    for component in Path::new(normalized_path).components() {
        match component {
            Component::CurDir => {}
            Component::Normal(segment) => {
                if segment.to_string_lossy().starts_with('-') {
                    return Err(format!(
                        "file_path must not contain leading-dash components: {raw_path}"
                    ));
                }
                relative.push(segment)
            }
            Component::ParentDir => {
                return Err(format!(
                    "file_path must not contain traversal components: {raw_path}"
                ))
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err("file_path must be repo-relative".to_string())
            }
        }
    }

    if relative.as_os_str().is_empty() {
        return Err("file_path must not be empty".to_string());
    }

    Ok(relative)
}

fn assert_no_symlink_components(
    repo_root: &Path,
    relative_path: &Path,
    raw_path: &str,
) -> Result<(), String> {
    let mut current = PathBuf::from(repo_root);

    for component in relative_path.components() {
        let Component::Normal(segment) = component else {
            continue;
        };
        current.push(segment);

        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!(
                    "file_path resolves through a symlinked path: {raw_path}"
                ))
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "failed to inspect file_path within repo_root: {error}"
                ))
            }
        }
    }

    Ok(())
}

fn is_absolute_path_like(path_value: &str) -> bool {
    Path::new(path_value).is_absolute()
        || matches!(path_value.as_bytes(), [drive, b':', b'/', ..] if drive.is_ascii_alphabetic())
}

fn validate_source(source: &str) -> Result<String, String> {
    let normalized = source.trim();
    if normalized.is_empty()
        || normalized.len() > SOURCE_MAX_LEN
        || !normalized
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
    {
        return Err(
            "source must contain only letters, numbers, '_' or '-' and be <= 32 characters"
                .to_string(),
        );
    }
    Ok(normalized.to_string())
}

fn validate_lease_owner(lease_owner: &str) -> Result<String, String> {
    let normalized = lease_owner.trim();
    if normalized.is_empty()
        || normalized.len() > LEASE_OWNER_MAX_LEN
        || !normalized
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-')
    {
        return Err("lease_owner must contain only letters, numbers, or '-'".to_string());
    }
    Ok(normalized.to_string())
}

fn validate_optional_run_id(run_id: Option<&str>) -> Result<Option<String>, String> {
    let Some(run_id) = run_id else {
        return Ok(None);
    };
    let normalized = run_id.trim();
    if normalized.is_empty()
        || normalized.len() > RUN_ID_MAX_LEN
        || !normalized
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | ':' | '-'))
    {
        return Err(
            "lease_run_id must contain only letters, numbers, '.', '_', ':' or '-' and be <= 128 characters"
                .to_string(),
        );
    }
    Ok(Some(normalized.to_string()))
}

fn validate_optional_expected_files(
    file_paths: Option<&[String]>,
) -> Result<Option<Vec<String>>, String> {
    let Some(file_paths) = file_paths else {
        return Ok(None);
    };

    let mut normalized = Vec::with_capacity(file_paths.len());
    for file_path in file_paths {
        normalized.push(validate_file_path(file_path)?);
    }
    Ok(Some(normalized))
}

fn validate_optional_error_message(error_message: Option<&str>) -> Result<Option<String>, String> {
    let Some(error_message) = error_message else {
        return Ok(None);
    };
    let normalized = error_message.trim();
    if normalized.is_empty() {
        return Err("error must not be empty".to_string());
    }
    Ok(Some(normalized.to_string()))
}

fn map_queue_row(row: QueueRow) -> QueueItem {
    QueueItem {
        event_id: row.event_id,
        dedupe_key: row.dedupe_key.unwrap_or_else(|| row.file_path.clone()),
        file_path: row.file_path,
        source: row.last_enqueue_source,
        queue_state: row.queue_state,
        first_enqueued_at: row.first_enqueued_at,
        last_enqueued_at: row.last_enqueued_at,
        lease_owner: row.lease_owner,
        leased_at: row.leased_at,
        lease_expires_at: row.lease_expires_at,
        acknowledged_at: row.acknowledged_at,
        retry_count: row.retry_count.unwrap_or(0),
        last_error: row.last_error,
    }
}

fn select_queue_rows(
    conn: &Connection,
    sql: &str,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<QueueRow>, String> {
    let mut stmt = conn.prepare(sql).map_err(|e| format!("queue query: {e}"))?;
    let rows = stmt
        .query_map(params, |row| {
            Ok(QueueRow {
                id: row.get(0)?,
                event_id: row.get(1)?,
                dedupe_key: row.get(2)?,
                file_path: row.get(3)?,
                queue_state: row.get(4)?,
                first_enqueued_at: row.get(5)?,
                last_enqueued_at: row.get(6)?,
                last_enqueue_source: row.get(7)?,
                lease_run_id: row.get(8)?,
                lease_event_id: row.get(9)?,
                lease_owner: row.get(10)?,
                leased_at: row.get(11)?,
                lease_expires_at: row.get(12)?,
                acknowledged_at: row.get(13)?,
                retry_count: row.get(14)?,
                last_error: row.get(15)?,
            })
        })
        .map_err(|e| format!("queue query: {e}"))?;

    let mut collected = Vec::new();
    for row in rows {
        collected.push(row.map_err(|e| format!("queue row: {e}"))?);
    }
    Ok(collected)
}

fn select_by_file_path(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> Result<Option<QueueRow>, String> {
    let mut rows = select_queue_rows(
        conn,
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE project_id = ?1 AND file_path = ?2
         LIMIT 1",
        &[&project_id, &file_path],
    )?;
    Ok(rows.pop())
}

fn select_item_by_id(conn: &Connection, id: i64) -> Result<QueueItem, String> {
    let mut rows = select_queue_rows(
        conn,
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE id = ?1
         LIMIT 1",
        &[&id],
    )?;
    let row = rows
        .pop()
        .ok_or_else(|| "queue row not found after write".to_string())?;
    Ok(map_queue_row(row))
}

fn select_lease_candidates(
    conn: &Connection,
    project_id: &str,
    leased_at: &str,
) -> Result<Vec<QueueRow>, String> {
    select_queue_rows(
        conn,
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE project_id = ?1
           AND (
             queue_state = 'pending'
             OR (
               queue_state = 'leased'
               AND lease_expires_at IS NOT NULL
               AND lease_expires_at <= ?2
             )
           )
         ORDER BY first_enqueued_at ASC, id ASC",
        &[&project_id, &leased_at],
    )
}

fn select_export_rows(conn: &Connection, project_id: &str) -> Result<Vec<QueueRow>, String> {
    select_queue_rows(
        conn,
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE project_id = ?1 AND queue_state IN ('pending', 'leased')
         ORDER BY first_enqueued_at ASC, id ASC",
        &[&project_id],
    )
}

fn select_leased_rows(
    conn: &Connection,
    project_id: &str,
    lease_owner: &str,
) -> Result<Vec<QueueRow>, String> {
    select_queue_rows(
        conn,
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE project_id = ?1
           AND queue_state = 'leased'
           AND lease_owner = ?2
         ORDER BY first_enqueued_at ASC, id ASC",
        &[&project_id, &lease_owner],
    )
}

fn select_lease_rows_for_finalization(
    conn: &Connection,
    project_id: &str,
    lease_owner: &str,
    lease_run_id: Option<&str>,
    expected_files: Option<&[String]>,
) -> Result<Vec<QueueRow>, String> {
    match expected_files {
        None => select_leased_rows(conn, project_id, lease_owner),
        Some(expected_files) => {
            select_expected_leased_rows(conn, project_id, lease_owner, lease_run_id, expected_files)
        }
    }
}

fn select_expected_leased_rows(
    conn: &Connection,
    project_id: &str,
    lease_owner: &str,
    lease_run_id: Option<&str>,
    expected_files: &[String],
) -> Result<Vec<QueueRow>, String> {
    if expected_files.is_empty() {
        return Ok(Vec::new());
    }

    let placeholders = expected_files
        .iter()
        .enumerate()
        .map(|(idx, _)| format!("?{}", idx + 2))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT
             id, event_id, dedupe_key, file_path, queue_state,
             first_enqueued_at, last_enqueued_at, last_enqueue_source,
             lease_run_id, lease_event_id, lease_owner, leased_at,
             lease_expires_at, acknowledged_at, retry_count, last_error
         FROM review_queue_items
         WHERE project_id = ?1
           AND file_path IN ({placeholders})
         ORDER BY first_enqueued_at ASC, id ASC"
    );

    let mut bind: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(expected_files.len() + 1);
    bind.push(&project_id);
    for file_path in expected_files {
        bind.push(file_path);
    }

    let rows = select_queue_rows(conn, &sql, &bind)?;
    let mut lost_files = Vec::new();
    let mut matched_rows = Vec::with_capacity(expected_files.len());

    for expected_file in expected_files {
        let row = rows.iter().find(|row| row.file_path == *expected_file);
        let Some(row) = row else {
            lost_files.push(expected_file.clone());
            continue;
        };

        if row.queue_state != "leased"
            || row.lease_owner.as_deref() != Some(lease_owner)
            || row.lease_run_id.as_deref() != lease_run_id
        {
            lost_files.push(expected_file.clone());
            continue;
        }

        matched_rows.push(row.clone());
    }

    if !lost_files.is_empty() {
        let run_segment = lease_run_id
            .map(|run_id| format!(" for run_id {run_id}"))
            .unwrap_or_default();
        return Err(format!(
            "lost queue lease ownership{run_segment}: {}",
            lost_files.join(", ")
        ));
    }

    Ok(matched_rows)
}

fn unwrap_review_run_input(raw: &Value) -> Result<&serde_json::Map<String, Value>, String> {
    let object = raw
        .as_object()
        .ok_or_else(|| "review-run input must be an object".to_string())?;
    if let Some(inner) = object.get("input") {
        return inner
            .as_object()
            .ok_or_else(|| "review-run input.input must be an object".to_string());
    }
    Ok(object)
}

fn read_identifier(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<String, String> {
    let value = read_optional_string(payload.get(field), field)?;
    let value = value.ok_or_else(|| format!("{field} is required"))?;
    if value.len() > RUN_ID_MAX_LEN
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | ':' | '-'))
    {
        return Err(format!(
            "{field} must contain only letters, numbers, '.', '_', ':' or '-' and be <= 128 characters"
        ));
    }
    Ok(value)
}

fn read_status(value: Option<&Value>) -> Result<String, String> {
    let value = read_optional_string(value, "status")?;
    let value = value.ok_or_else(|| "status is required".to_string())?;
    match value.as_str() {
        "completed" | "failed" => Ok(value),
        _ => Err("status must be one of: completed, failed".to_string()),
    }
}

fn read_iteration(value: Option<&Value>) -> Result<i64, String> {
    match value.and_then(Value::as_i64) {
        Some(iteration) if iteration >= 0 => Ok(iteration),
        _ => Err("iteration must be a non-negative integer".to_string()),
    }
}

fn read_string_array(value: Option<&Value>, field: &str) -> Result<Vec<String>, String> {
    let array = value
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{field} must be an array"))?;
    let mut result = Vec::with_capacity(array.len());
    for (idx, entry) in array.iter().enumerate() {
        let entry = read_optional_string(Some(entry), &format!("{field}[{idx}]"))?
            .ok_or_else(|| format!("{field}[{idx}] must not be empty"))?;
        result.push(entry);
    }
    Ok(result)
}

fn read_optional_array(value: Option<&Value>, field: &str) -> Result<Option<Vec<Value>>, String> {
    match value {
        None => Ok(None),
        Some(Value::Array(values)) => Ok(Some(values.clone())),
        Some(_) => Err(format!("{field} must be an array")),
    }
}

fn read_optional_object<'a>(
    value: Option<&'a Value>,
    field: &str,
) -> Result<Option<&'a Value>, String> {
    match value {
        None => Ok(None),
        Some(Value::Object(_)) => Ok(value),
        Some(_) => Err(format!("{field} must be an object")),
    }
}

fn read_optional_hash(value: Option<&Value>) -> Result<Option<String>, String> {
    let Some(value) = read_optional_string(value, "report_hash")? else {
        return Ok(None);
    };
    if value.len() != 64 || !value.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err("report_hash must be a 64-character hex sha256".to_string());
    }
    Ok(Some(value.to_ascii_lowercase()))
}

fn read_optional_string(value: Option<&Value>, field: &str) -> Result<Option<String>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let value = value
        .as_str()
        .ok_or_else(|| format!("{field} must be a string"))?;
    let normalized = value.trim();
    if normalized.is_empty() {
        return Err(format!("{field} must not be empty"));
    }
    Ok(Some(normalized.to_string()))
}

fn resolve_report_hash(input: &ReviewRunRecordInput) -> Result<String, String> {
    match (&input.report_body, &input.report_hash) {
        (Some(report_body), Some(report_hash)) => {
            let derived_hash = sha256_hex(report_body);
            if derived_hash != *report_hash {
                return Err(
                    "report_hash must match the sha256 of report_body when both are supplied"
                        .to_string(),
                );
            }
            Ok(report_hash.clone())
        }
        (Some(report_body), None) => Ok(sha256_hex(report_body)),
        (None, Some(report_hash)) => Ok(report_hash.clone()),
        (None, None) => Err("review-run input requires report_body or report_hash".to_string()),
    }
}

fn select_stored_run(
    conn: &Connection,
    project_id: &str,
    run_id: &str,
) -> Result<Option<StoredReviewRunRow>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT
                 project_id,
                 run_id,
                 phase,
                 iteration,
                 kind,
                 status,
                 consumer,
                 reviewer,
                file_count,
                files_json,
                findings_json,
                summary,
                result_summary,
                blocker_summary,
                report_body,
                report_hash,
                error_message,
                 metadata_json,
                 created_at
             FROM review_runs
             WHERE project_id = ?1 AND run_id = ?2
             LIMIT 1",
        )
        .map_err(|e| format!("review-run select: {e}"))?;
    let mut rows = stmt
        .query(params![project_id, run_id])
        .map_err(|e| format!("review-run select: {e}"))?;
    let Some(row) = rows.next().map_err(|e| format!("review-run row: {e}"))? else {
        return Ok(None);
    };

    Ok(Some(StoredReviewRunRow {
        project_id: row.get(0).map_err(|e| format!("review-run row: {e}"))?,
        run_id: row.get(1).map_err(|e| format!("review-run row: {e}"))?,
        phase: row.get(2).map_err(|e| format!("review-run row: {e}"))?,
        iteration: row.get(3).map_err(|e| format!("review-run row: {e}"))?,
        kind: row.get(4).map_err(|e| format!("review-run row: {e}"))?,
        status: row.get(5).map_err(|e| format!("review-run row: {e}"))?,
        consumer: row.get(6).map_err(|e| format!("review-run row: {e}"))?,
        reviewer: row.get(7).map_err(|e| format!("review-run row: {e}"))?,
        file_count: row.get(8).map_err(|e| format!("review-run row: {e}"))?,
        files_json: row.get(9).map_err(|e| format!("review-run row: {e}"))?,
        findings_json: row.get(10).map_err(|e| format!("review-run row: {e}"))?,
        summary: row.get(11).map_err(|e| format!("review-run row: {e}"))?,
        result_summary: row.get(12).map_err(|e| format!("review-run row: {e}"))?,
        blocker_summary: row.get(13).map_err(|e| format!("review-run row: {e}"))?,
        report_body: row.get(14).map_err(|e| format!("review-run row: {e}"))?,
        report_hash: row.get(15).map_err(|e| format!("review-run row: {e}"))?,
        error_message: row.get(16).map_err(|e| format!("review-run row: {e}"))?,
        metadata_json: row.get(17).map_err(|e| format!("review-run row: {e}"))?,
        created_at: row.get(18).map_err(|e| format!("review-run row: {e}"))?,
    }))
}

enum StoredRunReplay {
    Exact,
    UpgradeLegacy,
}

fn classify_stored_run_replay(
    existing: &StoredReviewRunRow,
    input: &ReviewRunRecordInput,
    report_hash: &str,
    queued_files_json: &str,
    findings_json: &str,
    metadata_json: &str,
) -> Result<StoredRunReplay, String> {
    let stored_summary = existing
        .result_summary
        .as_deref()
        .or(existing.summary.as_deref());
    let same_payload = existing.phase.as_deref() == Some(input.phase.as_str())
        && existing.iteration == Some(input.iteration)
        && existing.kind.as_deref() == Some(input.kind.as_str())
        && existing.status == input.status
        && existing.consumer == input.consumer
        && existing.reviewer == input.reviewer
        && existing.file_count == input.queued_files.len() as i64
        && normalized_json_string(&existing.files_json)
            == normalized_json_string(queued_files_json)
        && normalized_json_string(&existing.findings_json) == normalized_json_string(findings_json)
        && stored_summary == input.summary.as_deref()
        && existing.blocker_summary == input.blocker_summary
        && existing.report_body == input.report_body
        && existing.report_hash.as_deref() == Some(report_hash)
        && existing.error_message == input.error_message
        && normalized_json_string(&existing.metadata_json) == normalized_json_string(metadata_json);

    if same_payload {
        return Ok(StoredRunReplay::Exact);
    }

    if is_sparse_legacy_review_run(existing)
        && stored_summary.is_some()
        && stored_summary == input.summary.as_deref()
    {
        return Ok(StoredRunReplay::UpgradeLegacy);
    }

    Err(format!(
        "run_id already exists with different payload: {}",
        input.run_id
    ))
}

fn normalized_json_string(raw: &str) -> String {
    serde_json::from_str::<Value>(raw)
        .map(|value| stable_stringify(&value))
        .unwrap_or_else(|_| raw.to_string())
}

fn is_sparse_legacy_review_run(existing: &StoredReviewRunRow) -> bool {
    existing.phase.is_none()
        && existing.iteration.is_none()
        && existing.kind.is_none()
        && existing.status == "started"
        && existing.consumer.is_none()
        && existing.reviewer.is_none()
        && existing.file_count == 0
        && normalized_json_string(&existing.files_json) == "[]"
        && normalized_json_string(&existing.findings_json) == "[]"
        && existing.blocker_summary.is_none()
        && existing.report_body.is_none()
        && existing.report_hash.is_none()
        && existing.error_message.is_none()
        && normalized_json_string(&existing.metadata_json) == "{}"
}

fn upgrade_legacy_review_run(
    conn: &Connection,
    project_id: &str,
    input: &ReviewRunRecordInput,
    report_hash: &str,
    queued_files_json: &str,
    findings_json: &str,
    metadata_json: &str,
) -> Result<(), String> {
    let timestamp = current_timestamp(conn)?;
    conn.execute(
        "UPDATE review_runs
         SET status = ?1,
             phase = ?2,
             iteration = ?3,
             kind = ?4,
             consumer = ?5,
             reviewer = ?6,
             file_count = ?7,
             files_json = ?8,
             findings_json = ?9,
             summary = NULL,
             result_summary = ?10,
             blocker_summary = ?11,
             report_body = ?12,
             report_hash = ?13,
             error_message = ?14,
             metadata_json = ?15,
             completed_at = CASE
               WHEN ?1 IN ('completed', 'failed') THEN COALESCE(completed_at, ?16)
               ELSE completed_at
             END,
             updated_at = ?16
         WHERE project_id = ?17 AND run_id = ?18",
        params![
            input.status.as_str(),
            input.phase.as_str(),
            input.iteration,
            input.kind.as_str(),
            input.consumer.as_deref(),
            input.reviewer.as_deref(),
            input.queued_files.len() as i64,
            queued_files_json,
            findings_json,
            input.summary.as_deref(),
            input.blocker_summary.as_deref(),
            input.report_body.as_deref(),
            report_hash,
            input.error_message.as_deref(),
            metadata_json,
            timestamp,
            project_id,
            input.run_id.as_str(),
        ],
    )
    .map_err(|e| format!("legacy review-run upgrade: {e}"))?;
    Ok(())
}

fn to_record_result(row: &StoredReviewRunRow) -> ReviewRunRecordResult {
    ReviewRunRecordResult {
        project_id: row.project_id.clone(),
        run_id: row.run_id.clone(),
        phase: row.phase.clone().unwrap_or_default(),
        iteration: row.iteration.unwrap_or_default(),
        kind: row.kind.clone().unwrap_or_default(),
        status: row.status.clone(),
        queued_file_count: row.file_count as usize,
        report_hash: row.report_hash.clone().unwrap_or_default(),
        created_at: row.created_at.clone(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use serde_json::json;
    use std::path::Path;
    use std::sync::OnceLock;

    fn test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        conn
    }

    fn test_repo_root() -> &'static Path {
        static REPO_ROOT: OnceLock<PathBuf> = OnceLock::new();
        REPO_ROOT
            .get_or_init(|| {
                let path = std::env::temp_dir().join(format!(
                    "semantic-mcp-review-queue-tests-{}",
                    Uuid::new_v4()
                ));
                std::fs::create_dir_all(&path).unwrap();
                path
            })
            .as_path()
    }

    fn enqueue_for_test(
        conn: &Connection,
        project_id: &str,
        file_path: &str,
        source: &str,
    ) -> Result<EnqueueResult, String> {
        enqueue(conn, project_id, test_repo_root(), file_path, source)
    }

    #[test]
    fn test_enqueue_new_item() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "src/main.rs", "hook").unwrap();
        assert!(result.queued);
        assert!(!result.duplicate);
        assert_eq!(result.item.file_path, "src/main.rs");
        assert_eq!(result.item.queue_state, "pending");
        assert_eq!(result.item.source, "hook");
    }

    #[test]
    fn test_enqueue_duplicate_returns_duplicate() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/main.rs", "hook").unwrap();
        let result = enqueue_for_test(&conn, "proj1", "src/main.rs", "hook").unwrap();
        assert!(!result.queued);
        assert!(result.duplicate);
        assert_eq!(result.item.file_path, "src/main.rs");
    }

    #[test]
    fn test_enqueue_empty_path_returns_error() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "", "hook");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("must not be empty"));
    }

    #[test]
    fn test_enqueue_blank_source_is_rejected() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "src/lib.rs", "  ");
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("source must contain only letters"));
    }

    #[test]
    fn test_lease_complete_and_requeue_lifecycle() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/a.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj1", "src/b.rs", "hook").unwrap();

        let leased = lease(&conn, "proj1", Some("run-1"), Some(60)).unwrap();
        assert_eq!(leased.leased_count, 2);
        let lease_owner = leased.lease_owner.clone().unwrap();
        let expected = leased
            .items
            .iter()
            .map(|item| item.file_path.clone())
            .collect::<Vec<_>>();

        let completed =
            complete(&conn, "proj1", &lease_owner, Some("run-1"), Some(&expected)).unwrap();
        assert_eq!(completed.completed_count, 2);
        assert!(completed
            .items
            .iter()
            .all(|item| item.queue_state == "done"));

        enqueue_for_test(&conn, "proj1", "src/c.rs", "hook").unwrap();
        let leased = lease(&conn, "proj1", Some("run-2"), Some(60)).unwrap();
        let lease_owner = leased.lease_owner.clone().unwrap();
        let expected = leased
            .items
            .iter()
            .map(|item| item.file_path.clone())
            .collect::<Vec<_>>();

        let requeued = requeue(
            &conn,
            "proj1",
            &lease_owner,
            Some("run-2"),
            Some(&expected),
            Some("transient"),
        )
        .unwrap();
        assert_eq!(requeued.requeued_count, 1);
        assert_eq!(requeued.items[0].queue_state, "pending");
        assert_eq!(requeued.items[0].retry_count, 1);
        assert_eq!(requeued.items[0].last_error.as_deref(), Some("transient"));
    }

    #[test]
    fn test_complete_fails_closed_on_partial_lease_loss() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/a.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj1", "src/b.rs", "hook").unwrap();

        let first = lease(&conn, "proj1", Some("run-1"), Some(60)).unwrap();
        let owner = first.lease_owner.clone().unwrap();
        conn.execute(
            "UPDATE review_queue_items SET lease_expires_at = '2000-01-01T00:00:00Z'
             WHERE project_id = ?1 AND file_path = ?2",
            params!["proj1", "src/a.rs"],
        )
        .unwrap();

        let second = lease(&conn, "proj1", Some("run-2"), Some(60)).unwrap();
        assert_eq!(second.leased_count, 1);

        let expected = first
            .items
            .iter()
            .map(|item| item.file_path.clone())
            .collect::<Vec<_>>();
        let error = complete(&conn, "proj1", &owner, Some("run-1"), Some(&expected)).unwrap_err();
        assert!(error.contains("lost queue lease ownership"));
        assert!(error.contains("run-1"));
    }

    #[test]
    fn test_complete_releases_changed_file_back_to_pending() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/changed.rs", "hook").unwrap();

        let leased = lease(&conn, "proj1", None, Some(60)).unwrap();
        let owner = leased.lease_owner.clone().unwrap();
        enqueue_for_test(&conn, "proj1", "src/changed.rs", "hook").unwrap();

        let expected = vec!["src/changed.rs".to_string()];
        let completed = complete(&conn, "proj1", &owner, None, Some(&expected)).unwrap();
        assert_eq!(completed.completed_count, 0);
        assert_eq!(completed.items[0].queue_state, "pending");

        let leased_again = lease(&conn, "proj1", None, Some(60)).unwrap();
        assert_eq!(leased_again.leased_count, 1);
        assert_ne!(leased_again.lease_owner, leased.lease_owner);
    }

    #[test]
    fn test_export_json_empty_queue() {
        let conn = test_db();
        let export = export_json(&conn, "proj1").unwrap();
        assert_eq!(export.project_id, "proj1");
        assert_eq!(export.pending_count, 0);
        assert_eq!(export.leased_count, 0);
        assert!(!export.pending_review);
        assert!(export.items.is_empty());
        assert!(export.changed_files.is_empty());
    }

    #[test]
    fn test_export_json_with_items() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/a.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj1", "src/b.rs", "hook").unwrap();
        let export = export_json(&conn, "proj1").unwrap();
        assert_eq!(export.pending_count, 2);
        assert!(export.pending_review);
        assert_eq!(export.changed_files.len(), 2);
    }

    #[test]
    fn test_export_json_isolates_projects() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/a.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj2", "src/b.rs", "hook").unwrap();
        let export1 = export_json(&conn, "proj1").unwrap();
        let export2 = export_json(&conn, "proj2").unwrap();
        assert_eq!(export1.pending_count, 1);
        assert_eq!(export2.pending_count, 1);
        assert_eq!(export1.changed_files[0], "src/a.rs");
        assert_eq!(export2.changed_files[0], "src/b.rs");
    }

    #[test]
    fn test_export_json_fifo_ordering() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "src/c.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj1", "src/a.rs", "hook").unwrap();
        enqueue_for_test(&conn, "proj1", "src/b.rs", "hook").unwrap();
        let export = export_json(&conn, "proj1").unwrap();
        assert_eq!(export.items[0].file_path, "src/c.rs");
        assert_eq!(export.items[1].file_path, "src/a.rs");
        assert_eq!(export.items[2].file_path, "src/b.rs");
    }

    #[test]
    fn test_enqueue_retry_count_starts_at_zero() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "src/main.rs", "hook").unwrap();
        assert_eq!(result.item.retry_count, 0);
    }

    #[test]
    fn test_enqueue_generates_event_id() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "src/main.rs", "hook").unwrap();
        assert!(result.item.event_id.is_some());
        assert_eq!(result.item.event_id.unwrap().len(), 36);
    }

    #[test]
    fn test_enqueue_normalizes_native_layout_paths() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "./apps\\web//src/main.ts", "hook").unwrap();
        assert_eq!(result.item.file_path, "apps/web/src/main.ts");
        assert_eq!(result.item.dedupe_key, "apps/web/src/main.ts");
    }

    #[test]
    fn test_enqueue_deduplicates_path_variants() {
        let conn = test_db();
        enqueue_for_test(&conn, "proj1", "./packages/ui/src/button.tsx", "hook").unwrap();
        let result =
            enqueue_for_test(&conn, "proj1", "packages\\ui//src/button.tsx", "hook").unwrap();
        assert!(result.duplicate);
        assert_eq!(result.item.file_path, "packages/ui/src/button.tsx");
    }

    #[test]
    fn test_enqueue_rejects_absolute_paths() {
        let conn = test_db();
        let absolute = test_repo_root().join("outside").join("proof.txt");
        let result = enqueue(
            &conn,
            "proj1",
            test_repo_root(),
            absolute.to_string_lossy().as_ref(),
            "hook",
        );
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("file_path must be repo-relative"));
    }

    #[test]
    fn test_enqueue_rejects_traversal_paths() {
        let conn = test_db();
        let result = enqueue(
            &conn,
            "proj1",
            test_repo_root(),
            "../outside/proof.txt",
            "hook",
        );
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("file_path must not contain traversal components"));
    }

    #[test]
    fn test_enqueue_rejects_leading_dash_path_components() {
        let conn = test_db();
        let result = enqueue(
            &conn,
            "proj1",
            test_repo_root(),
            "--pathspec-from-file=.claude/tmp/pathspec.txt",
            "hook",
        );
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("file_path must not contain leading-dash components"));
    }

    #[cfg(unix)]
    #[test]
    fn test_enqueue_rejects_repo_external_symlink_paths() {
        use std::os::unix::fs::symlink;

        let conn = test_db();
        let outside_root = std::env::temp_dir().join(format!(
            "semantic-mcp-review-queue-outside-{}",
            Uuid::new_v4()
        ));
        std::fs::create_dir_all(&outside_root).unwrap();
        let symlink_path = test_repo_root().join("outside-link");
        let _ = std::fs::remove_file(&symlink_path);
        symlink(&outside_root, &symlink_path).unwrap();

        let result = enqueue(
            &conn,
            "proj1",
            test_repo_root(),
            "outside-link/proof.txt",
            "hook",
        );
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("file_path resolves through a symlinked path"));

        std::fs::remove_file(&symlink_path).unwrap();
        std::fs::remove_dir_all(&outside_root).unwrap();
    }

    #[test]
    fn test_enqueue_persists_canonical_repo_relative_paths() {
        let conn = test_db();
        let result = enqueue_for_test(&conn, "proj1", "./src\\valid.rs", "hook").unwrap();
        assert_eq!(result.item.file_path, "src/valid.rs");
        assert_eq!(result.item.dedupe_key, "src/valid.rs");
    }

    #[test]
    fn test_record_review_run_keeps_summary_and_blocker_distinct() {
        let conn = test_db();
        let result = record_review_run(
            &conn,
            "proj1",
            &json!({
                "run_id": "run-001",
                "phase": "review",
                "iteration": 2,
                "kind": "batch",
                "status": "completed",
                "queued_files": ["src/a.ts", "src/b.ts"],
                "summary": "2 files reviewed",
                "blocker_summary": "none",
                "report_body": "all clear",
                "findings": [{"severity": "low"}],
                "metadata": {"source": "test"}
            }),
        )
        .unwrap();

        assert_eq!(result.project_id, "proj1");
        assert_eq!(result.queued_file_count, 2);

        let row = conn
            .query_row(
                "SELECT summary, result_summary, blocker_summary, report_body
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                params!["proj1", "run-001"],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .unwrap();

        assert_eq!(row.0, None);
        assert_eq!(row.1.as_deref(), Some("2 files reviewed"));
        assert_eq!(row.2.as_deref(), Some("none"));
        assert_eq!(row.3.as_deref(), Some("all clear"));
    }

    #[test]
    fn test_record_review_run_accepts_matching_report_body_and_hash() {
        let conn = test_db();
        let report_body = "verified body";
        let report_hash = sha256_hex(report_body);

        let result = record_review_run(
            &conn,
            "proj1",
            &json!({
                "run_id": "run-report-match",
                "phase": "review",
                "iteration": 1,
                "kind": "batch",
                "status": "completed",
                "queued_files": ["src/hash.ts"],
                "report_body": report_body,
                "report_hash": report_hash
            }),
        )
        .unwrap();

        assert_eq!(result.report_hash, report_hash);

        let stored_hash = conn
            .query_row(
                "SELECT report_hash
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                params!["proj1", "run-report-match"],
                |row| row.get::<_, Option<String>>(0),
            )
            .unwrap();
        assert_eq!(stored_hash.as_deref(), Some(report_hash.as_str()));
    }

    #[test]
    fn test_record_review_run_rejects_mismatched_report_body_and_hash() {
        let conn = test_db();
        let err = record_review_run(
            &conn,
            "proj1",
            &json!({
                "run_id": "run-report-mismatch",
                "phase": "review",
                "iteration": 1,
                "kind": "batch",
                "status": "completed",
                "queued_files": ["src/hash.ts"],
                "report_body": "verified body",
                "report_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }),
        )
        .unwrap_err();

        assert!(err.contains("report_hash must match the sha256 of report_body"));
    }

    #[test]
    fn test_record_review_run_rejects_conflicting_payload() {
        let conn = test_db();
        let input = json!({
            "run_id": "run-003",
            "phase": "review",
            "iteration": 4,
            "kind": "batch",
            "status": "completed",
            "queued_files": ["src/d.ts"],
            "summary": "first summary",
            "report_body": "first body"
        });
        record_review_run(&conn, "proj1", &input).unwrap();

        let err = record_review_run(
            &conn,
            "proj1",
            &json!({
                "run_id": "run-003",
                "phase": "review",
                "iteration": 4,
                "kind": "batch",
                "status": "completed",
                "queued_files": ["src/d.ts"],
                "summary": "second summary",
                "report_body": "second body"
            }),
        )
        .unwrap_err();

        assert!(err.contains("run_id already exists with different payload: run-003"));
    }

    #[test]
    fn test_record_review_run_accepts_legacy_nested_input() {
        let conn = test_db();
        let result = record_review_run(
            &conn,
            "proj1",
            &json!({
                "input": {
                    "run_id": "run-nested",
                    "phase": "review",
                    "iteration": 1,
                    "kind": "batch",
                    "status": "completed",
                    "queued_files": ["src/nested.ts"],
                    "report_body": "ok"
                }
            }),
        )
        .unwrap();
        assert_eq!(result.run_id, "run-nested");
    }

    #[test]
    fn test_record_review_run_accepts_legacy_summary_only_migration_replay() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "
            CREATE TABLE review_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                summary TEXT
            );
            INSERT INTO review_runs (
                project_id,
                run_id,
                summary
            ) VALUES (
                'proj1',
                'legacy-run',
                'legacy summary'
            );
            ",
        )
        .unwrap();
        crate::db::run_migrations(&conn).unwrap();

        let migrated = conn
            .query_row(
                "SELECT status, summary, result_summary, file_count, files_json, findings_json, metadata_json
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                params!["proj1", "legacy-run"],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                    ))
                },
            )
            .unwrap();

        assert_eq!(migrated.0, "started");
        assert_eq!(migrated.1.as_deref(), Some("legacy summary"));
        assert_eq!(migrated.2.as_deref(), Some("legacy summary"));
        assert_eq!(migrated.3, 0);
        assert_eq!(migrated.4, "[]");
        assert_eq!(migrated.5, "[]");
        assert_eq!(migrated.6, "{}");

        let report_body = "legacy body";
        let report_hash = sha256_hex(report_body);
        let replay_payload = json!({
            "run_id": "legacy-run",
            "phase": "review",
            "iteration": 1,
            "kind": "batch",
            "status": "completed",
            "queued_files": ["src/legacy.ts"],
            "summary": "legacy summary",
            "report_body": report_body,
            "findings": [],
            "metadata": {}
        });

        let result = record_review_run(&conn, "proj1", &replay_payload).unwrap();
        let replay = record_review_run(&conn, "proj1", &replay_payload).unwrap();

        assert_eq!(result.run_id, "legacy-run");
        assert_eq!(result.report_hash, report_hash);
        assert_eq!(replay.run_id, "legacy-run");
        assert_eq!(replay.report_hash, report_hash);

        let row = conn
            .query_row(
                "SELECT
                    phase,
                    iteration,
                    kind,
                    status,
                    summary,
                    result_summary,
                    file_count,
                    files_json,
                    findings_json,
                    report_body,
                    report_hash,
                    metadata_json
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                params!["proj1", "legacy-run"],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, Option<String>>(10)?,
                        row.get::<_, String>(11)?,
                    ))
                },
            )
            .unwrap();

        assert_eq!(row.0.as_deref(), Some("review"));
        assert_eq!(row.1, Some(1));
        assert_eq!(row.2.as_deref(), Some("batch"));
        assert_eq!(row.3, "completed");
        assert_eq!(row.4, None);
        assert_eq!(row.5.as_deref(), Some("legacy summary"));
        assert_eq!(row.6, 1);
        assert_eq!(row.7, "[\"src/legacy.ts\"]");
        assert_eq!(row.8, "[]");
        assert_eq!(row.9.as_deref(), Some(report_body));
        assert_eq!(row.10.as_deref(), Some(report_hash.as_str()));
        assert_eq!(row.11, "{}");
    }

    #[test]
    fn test_record_review_run_accepts_reordered_json_keys_on_replay() {
        let conn = test_db();
        let first_payload = json!({
            "run_id": "run-json-order",
            "phase": "review",
            "iteration": 1,
            "kind": "batch",
            "status": "completed",
            "queued_files": ["src/json-order.ts"],
            "summary": "stable json",
            "report_body": "stable body",
            "findings": [{
                "severity": "low",
                "details": {
                    "z": 2,
                    "a": 1
                }
            }],
            "metadata": {
                "nested": {
                    "z": true,
                    "a": false
                },
                "b": 2,
                "a": 1
            }
        });
        record_review_run(&conn, "proj1", &first_payload).unwrap();

        let replay_payload = json!({
            "run_id": "run-json-order",
            "phase": "review",
            "iteration": 1,
            "kind": "batch",
            "status": "completed",
            "queued_files": ["src/json-order.ts"],
            "summary": "stable json",
            "report_body": "stable body",
            "findings": [{
                "details": {
                    "a": 1,
                    "z": 2
                },
                "severity": "low"
            }],
            "metadata": {
                "a": 1,
                "nested": {
                    "a": false,
                    "z": true
                },
                "b": 2
            }
        });
        let replay = record_review_run(&conn, "proj1", &replay_payload).unwrap();
        assert_eq!(replay.run_id, "run-json-order");

        let stored = conn
            .query_row(
                "SELECT findings_json, metadata_json
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                params!["proj1", "run-json-order"],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .unwrap();

        assert_eq!(
            stored.0,
            crate::util::stable_stringify(&first_payload["findings"])
        );
        assert_eq!(
            stored.1,
            crate::util::stable_stringify(&first_payload["metadata"])
        );
    }
}
