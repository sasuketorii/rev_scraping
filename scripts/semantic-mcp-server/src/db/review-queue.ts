import { randomUUID } from "node:crypto";
import { lstatSync, realpathSync } from "node:fs";
import { isAbsolute, posix, relative, resolve, sep } from "node:path";
import type Database from "better-sqlite3";
import { validateProjectId } from "../utils/project-id.js";

const SOURCE_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;
const LEASE_OWNER_PATTERN = /^[A-Za-z0-9-]{1,128}$/;
const RUN_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const CONTROL_BYTE_PATTERN = /[\u0000-\u001F\u007F]/u;
const WINDOWS_DRIVE_ABSOLUTE_PATTERN = /^[A-Za-z]:\//u;
const DEFAULT_LEASE_SECONDS = 900;
const MAX_LEASE_SECONDS = 86400;

interface ReviewQueueRow {
  id: number;
  project_id: string;
  event_id: string | null;
  dedupe_key: string | null;
  file_path: string;
  queue_state: "pending" | "leased" | "done";
  first_enqueued_at: string;
  last_enqueued_at: string;
  last_enqueue_source: string;
  lease_run_id: string | null;
  lease_event_id: string | null;
  lease_owner: string | null;
  leased_at: string | null;
  lease_expires_at: string | null;
  acknowledged_at: string | null;
  retry_count: number | null;
  last_error: string | null;
}

export interface QueueItem {
  event_id: string | null;
  dedupe_key: string;
  file_path: string;
  source: string;
  queue_state: "pending" | "leased" | "done";
  first_enqueued_at: string;
  last_enqueued_at: string;
  lease_owner: string | null;
  leased_at: string | null;
  lease_expires_at: string | null;
  acknowledged_at: string | null;
  retry_count: number;
  last_error: string | null;
}

export interface QueueEnqueueResult {
  queued: boolean;
  duplicate: boolean;
  item: QueueItem;
}

export interface QueueLeaseResult {
  project_id: string;
  lease_owner: string | null;
  leased_at: string;
  lease_expires_at: string | null;
  leased_count: number;
  items: QueueItem[];
}

export interface QueueCompleteResult {
  project_id: string;
  lease_owner: string;
  completed_at: string;
  completed_count: number;
  items: QueueItem[];
}

export interface QueueRequeueResult {
  project_id: string;
  lease_owner: string;
  requeued_at: string;
  requeued_count: number;
  items: QueueItem[];
}

export interface QueueExportJson {
  project_id: string;
  exported_at: string;
  pending_count: number;
  leased_count: number;
  pending_review: boolean;
  changed_files: string[];
  last_change: string;
  items: QueueItem[];
}

export interface EnqueueReviewQueueItemInput {
  projectId: string;
  repoRoot: string;
  filePath: string;
  source?: string;
}

export interface LeaseReviewQueueItemsInput {
  projectId: string;
  leaseRunId?: string;
  leaseSeconds?: number;
  limit?: number;
}

export interface CompleteReviewQueueLeaseInput {
  projectId: string;
  leaseOwner: string;
  leaseRunId?: string;
  expectedFiles?: string[];
}

export interface RequeueReviewQueueLeaseInput {
  projectId: string;
  leaseOwner: string;
  leaseRunId?: string;
  expectedFiles?: string[];
  errorMessage?: string;
}

export function enqueueReviewQueueItem(
  db: Database.Database,
  input: EnqueueReviewQueueItemInput
): QueueEnqueueResult {
  const projectId = validateProjectId(input.projectId);
  const filePath = validateEnqueueFilePath(input.repoRoot, input.filePath);
  const source = validateSource(input.source ?? "manual");
  const dedupeKey = filePath;
  const eventId = randomUUID();
  const now = currentTimestamp(db);

  return db.transaction(() => {
    const existing = selectByFilePath(db, projectId, filePath);
    if (existing && existing.queue_state === "pending") {
      return {
        queued: false,
        duplicate: true,
        item: mapQueueRow(existing)
      };
    }

    if (existing) {
      db.prepare(
        `
          UPDATE review_queue_items
          SET event_id = ?,
              dedupe_key = ?,
              queue_state = ?,
              first_enqueued_at = ?,
              last_enqueued_at = ?,
              last_enqueue_source = ?,
              payload = '{}',
              lease_run_id = ?,
              lease_event_id = ?,
              lease_owner = ?,
              leased_at = ?,
              lease_expires_at = ?,
              acknowledged_at = NULL,
              completed_at = NULL,
              completed_run_id = NULL,
              last_error = NULL,
              attempt_count = CASE
                WHEN ? = 'done' THEN 0
                ELSE attempt_count
              END,
              retry_count = CASE
                WHEN ? = 'done' THEN 0
                ELSE retry_count
              END
          WHERE id = ?
        `
      ).run(
        eventId,
        dedupeKey,
        existing.queue_state === "done" ? "pending" : existing.queue_state,
        existing.queue_state === "done" ? now : existing.first_enqueued_at,
        now,
        source,
        existing.queue_state === "leased" ? existing.lease_run_id : null,
        existing.queue_state === "leased" ? existing.lease_event_id : null,
        existing.queue_state === "leased" ? existing.lease_owner : null,
        existing.queue_state === "leased" ? existing.leased_at : null,
        existing.queue_state === "leased" ? existing.lease_expires_at : null,
        existing.queue_state,
        existing.queue_state,
        existing.id
      );

      return {
        queued: true,
        duplicate: false,
        item: mapQueueRow(requireQueueRow(selectById(db, existing.id)))
      };
    }

    const inserted = db
      .prepare(
        `
          INSERT INTO review_queue_items (
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
          VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, '{}', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, 0)
        `
      )
      .run(projectId, eventId, dedupeKey, filePath, now, now, source);

    return {
      queued: true,
      duplicate: false,
      item: mapQueueRow(requireQueueRow(selectById(db, Number(inserted.lastInsertRowid))))
    };
  })();
}

export function leaseReviewQueueItems(
  db: Database.Database,
  input: LeaseReviewQueueItemsInput
): QueueLeaseResult {
  const projectId = validateProjectId(input.projectId);
  const leaseRunId = validateOptionalRunId(input.leaseRunId);
  const leaseSeconds = normalizeLeaseSeconds(input.leaseSeconds);
  const limit = normalizeLeaseLimit(input.limit);
  const leasedAt = currentTimestamp(db);
  const leaseExpiresAt = plusSeconds(leasedAt, leaseSeconds);
  const leaseOwner = randomUUID();

  return db.transaction(() => {
    const rows = (
      limit === undefined
        ? db
            .prepare(
              `
                SELECT
                  id,
                  project_id,
                  event_id,
                  dedupe_key,
                  file_path,
                  queue_state,
                  first_enqueued_at,
                  last_enqueued_at,
                  last_enqueue_source,
                  lease_run_id,
                  lease_event_id,
                  lease_owner,
                  leased_at,
                  lease_expires_at,
                  acknowledged_at,
                  retry_count,
                  last_error
                FROM review_queue_items
                WHERE project_id = ?
                  AND (
                    queue_state = 'pending'
                    OR (
                      queue_state = 'leased'
                      AND lease_expires_at IS NOT NULL
                      AND lease_expires_at <= ?
                    )
                  )
                ORDER BY first_enqueued_at ASC, id ASC
              `
            )
            .all(projectId, leasedAt)
        : db
            .prepare(
              `
                SELECT
                  id,
                  project_id,
                  event_id,
                  dedupe_key,
                  file_path,
                  queue_state,
                  first_enqueued_at,
                  last_enqueued_at,
                  last_enqueue_source,
                  lease_run_id,
                  lease_event_id,
                  lease_owner,
                  leased_at,
                  lease_expires_at,
                  acknowledged_at,
                  retry_count,
                  last_error
                FROM review_queue_items
                WHERE project_id = ?
                  AND (
                    queue_state = 'pending'
                    OR (
                      queue_state = 'leased'
                      AND lease_expires_at IS NOT NULL
                      AND lease_expires_at <= ?
                    )
                  )
                ORDER BY first_enqueued_at ASC, id ASC
                LIMIT ?
              `
            )
            .all(projectId, leasedAt, limit)
    ) as ReviewQueueRow[];

    if (rows.length === 0) {
      return {
        project_id: projectId,
        lease_owner: null,
        leased_at: leasedAt,
        lease_expires_at: null,
        leased_count: 0,
        items: []
      };
    }

    const update = db.prepare(
      `
        UPDATE review_queue_items
        SET queue_state = 'leased',
            lease_run_id = ?,
            lease_event_id = ?,
            lease_owner = ?,
            leased_at = ?,
            lease_expires_at = ?,
            acknowledged_at = NULL,
            completed_at = NULL,
            completed_run_id = NULL,
            last_error = NULL,
            attempt_count = attempt_count + 1,
            retry_count = CASE
              WHEN queue_state = 'leased' THEN retry_count + 1
              ELSE retry_count
            END
        WHERE id = ?
          AND event_id IS ?
          AND (
            queue_state = 'pending'
            OR (
              queue_state = 'leased'
              AND lease_expires_at IS NOT NULL
              AND lease_expires_at <= ?
            )
          )
      `
    );

    const leasedRows: QueueItem[] = [];
    for (const row of rows) {
      const result = update.run(
        leaseRunId ?? null,
        row.event_id,
        leaseOwner,
        leasedAt,
        leaseExpiresAt,
        row.id,
        row.event_id,
        leasedAt
      );
      if (result.changes !== 1) {
        throw new Error(`atomic lease failed for queue row id=${row.id}`);
      }

      leasedRows.push(
        mapQueueRow({
          ...row,
          queue_state: "leased",
          lease_run_id: leaseRunId ?? null,
          lease_event_id: row.event_id,
          lease_owner: leaseOwner,
          leased_at: leasedAt,
          lease_expires_at: leaseExpiresAt,
          acknowledged_at: null,
          retry_count:
            row.queue_state === "leased" ? (row.retry_count ?? 0) + 1 : (row.retry_count ?? 0),
          last_error: null
        })
      );
    }

    return {
      project_id: projectId,
      lease_owner: leaseOwner,
      leased_at: leasedAt,
      lease_expires_at: leaseExpiresAt,
      leased_count: leasedRows.length,
      items: leasedRows
    };
  })();
}

export function completeReviewQueueLease(
  db: Database.Database,
  input: CompleteReviewQueueLeaseInput
): QueueCompleteResult {
  const projectId = validateProjectId(input.projectId);
  const leaseOwner = validateLeaseOwner(input.leaseOwner);
  const leaseRunId = validateOptionalRunId(input.leaseRunId);
  const expectedFiles = validateOptionalExpectedFiles(input.expectedFiles);
  const completedAt = currentTimestamp(db);

  return db.transaction(() => {
    const rows = selectLeaseRowsForFinalization(db, {
      projectId,
      leaseOwner,
      leaseRunId,
      expectedFiles
    });
    if (rows.length === 0 && !expectedFiles) {
      throw new Error(`lease_owner not found: ${leaseOwner}`);
    }

    const update = db.prepare(
      `
        UPDATE review_queue_items
        SET queue_state = 'done',
            lease_run_id = NULL,
            lease_event_id = NULL,
            lease_expires_at = NULL,
            acknowledged_at = ?,
            completed_at = ?,
            last_error = NULL
        WHERE id = ?
          AND project_id = ?
          AND queue_state = 'leased'
          AND lease_owner = ?
          AND lease_event_id IS event_id
          AND (? IS NULL OR lease_run_id IS ?)
      `
    );
    const releaseStaleLease = db.prepare(
      `
        UPDATE review_queue_items
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
        WHERE id = ?
          AND project_id = ?
          AND queue_state = 'leased'
          AND lease_owner = ?
          AND NOT (lease_event_id IS event_id)
          AND (? IS NULL OR lease_run_id IS ?)
      `
    );

    const completedItems: QueueItem[] = [];
    for (const row of rows) {
      const result = update.run(
        completedAt,
        completedAt,
        row.id,
        projectId,
        leaseOwner,
        leaseRunId ?? null,
        leaseRunId ?? null
      );
      if (result.changes === 1) {
        completedItems.push(
          mapQueueRow({
            ...row,
            queue_state: "done",
            lease_run_id: null,
            lease_event_id: null,
            lease_expires_at: null,
            acknowledged_at: completedAt,
            last_error: null
          })
        );
        continue;
      }

      const staleResult = releaseStaleLease.run(
        row.id,
        projectId,
        leaseOwner,
        leaseRunId ?? null,
        leaseRunId ?? null
      );
      if (staleResult.changes !== 1) {
        throw new Error(`complete failed for queue row id=${row.id}`);
      }

      completedItems.push(
        mapQueueRow({
          ...row,
          queue_state: "pending",
          lease_run_id: null,
          lease_event_id: null,
          lease_owner: null,
          leased_at: null,
          lease_expires_at: null,
          acknowledged_at: null,
          last_error: null
        })
      );
    }

    return {
      project_id: projectId,
      lease_owner: leaseOwner,
      completed_at: completedAt,
      completed_count: completedItems.filter((item) => item.queue_state === "done").length,
      items: completedItems
    };
  })();
}

export function requeueReviewQueueLease(
  db: Database.Database,
  input: RequeueReviewQueueLeaseInput
): QueueRequeueResult {
  const projectId = validateProjectId(input.projectId);
  const leaseOwner = validateLeaseOwner(input.leaseOwner);
  const leaseRunId = validateOptionalRunId(input.leaseRunId);
  const expectedFiles = validateOptionalExpectedFiles(input.expectedFiles);
  const errorMessage = validateOptionalErrorMessage(input.errorMessage);
  const requeuedAt = currentTimestamp(db);

  return db.transaction(() => {
    const rows = selectLeaseRowsForFinalization(db, {
      projectId,
      leaseOwner,
      leaseRunId,
      expectedFiles
    });
    if (rows.length === 0 && !expectedFiles) {
      throw new Error(`lease_owner not found: ${leaseOwner}`);
    }

    const update = db.prepare(
      `
        UPDATE review_queue_items
        SET queue_state = 'pending',
            lease_run_id = NULL,
            lease_event_id = NULL,
            lease_owner = NULL,
            leased_at = NULL,
            lease_expires_at = NULL,
            acknowledged_at = NULL,
            completed_at = NULL,
            completed_run_id = NULL,
            last_error = ?,
            retry_count = retry_count + 1
        WHERE id = ?
          AND project_id = ?
          AND queue_state = 'leased'
          AND lease_owner = ?
          AND lease_event_id IS event_id
          AND (? IS NULL OR lease_run_id IS ?)
      `
    );
    const releaseStaleLease = db.prepare(
      `
        UPDATE review_queue_items
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
        WHERE id = ?
          AND project_id = ?
          AND queue_state = 'leased'
          AND lease_owner = ?
          AND NOT (lease_event_id IS event_id)
          AND (? IS NULL OR lease_run_id IS ?)
      `
    );

    const requeuedItems: QueueItem[] = [];
    let requeuedCount = 0;
    for (const row of rows) {
      const result = update.run(
        errorMessage ?? null,
        row.id,
        projectId,
        leaseOwner,
        leaseRunId ?? null,
        leaseRunId ?? null
      );
      if (result.changes === 1) {
        requeuedCount += 1;
        requeuedItems.push(
          mapQueueRow({
            ...row,
            queue_state: "pending",
            lease_run_id: null,
            lease_event_id: null,
            lease_owner: null,
            leased_at: null,
            lease_expires_at: null,
            acknowledged_at: null,
            retry_count: (row.retry_count ?? 0) + 1,
            last_error: errorMessage ?? null
          })
        );
        continue;
      }

      const staleResult = releaseStaleLease.run(
        row.id,
        projectId,
        leaseOwner,
        leaseRunId ?? null,
        leaseRunId ?? null
      );
      if (staleResult.changes !== 1) {
        throw new Error(`requeue failed for queue row id=${row.id}`);
      }

      requeuedItems.push(
        mapQueueRow({
          ...row,
          queue_state: "pending",
          lease_run_id: null,
          lease_event_id: null,
          lease_owner: null,
          leased_at: null,
          lease_expires_at: null,
          acknowledged_at: null,
          last_error: null
        })
      );
    }

    return {
      project_id: projectId,
      lease_owner: leaseOwner,
      requeued_at: requeuedAt,
      requeued_count: requeuedCount,
      items: requeuedItems
    };
  })();
}

export function exportReviewQueueJson(
  db: Database.Database,
  projectIdInput: string
): QueueExportJson {
  const projectId = validateProjectId(projectIdInput);
  const exportedAt = currentTimestamp(db);
  const rows = db
    .prepare(
      `
        SELECT
          id,
          project_id,
          event_id,
          dedupe_key,
          file_path,
          queue_state,
          first_enqueued_at,
          last_enqueued_at,
          last_enqueue_source,
          lease_run_id,
          lease_event_id,
          lease_owner,
          leased_at,
          lease_expires_at,
          acknowledged_at,
          retry_count,
          last_error
        FROM review_queue_items
        WHERE project_id = ? AND queue_state IN ('pending', 'leased')
        ORDER BY first_enqueued_at ASC, id ASC
      `
    )
    .all(projectId) as ReviewQueueRow[];

  const items = rows.map(mapQueueRow);
  const changedFiles = items.map((item) => item.file_path);
  const lastChange = items.reduce((latest, item) => {
    const candidate = item.leased_at && item.leased_at > item.last_enqueued_at
      ? item.leased_at
      : item.last_enqueued_at;

    return candidate > latest ? candidate : latest;
  }, "");

  return {
    project_id: projectId,
    exported_at: exportedAt,
    pending_count: items.filter((item) => item.queue_state === "pending").length,
    leased_count: items.filter((item) => item.queue_state === "leased").length,
    pending_review: items.length > 0,
    changed_files: changedFiles,
    last_change: lastChange,
    items
  };
}

function selectByFilePath(
  db: Database.Database,
  projectId: string,
  filePath: string
): ReviewQueueRow | undefined {
  return db
    .prepare(
      `
        SELECT
          id,
          project_id,
          event_id,
          dedupe_key,
          file_path,
          queue_state,
          first_enqueued_at,
          last_enqueued_at,
          last_enqueue_source,
          lease_run_id,
          lease_event_id,
          lease_owner,
          leased_at,
          lease_expires_at,
          acknowledged_at,
          retry_count,
          last_error
        FROM review_queue_items
        WHERE project_id = ? AND file_path = ?
        LIMIT 1
      `
    )
    .get(projectId, filePath) as ReviewQueueRow | undefined;
}

function selectById(db: Database.Database, id: number): ReviewQueueRow | undefined {
  return db
    .prepare(
      `
        SELECT
          id,
          project_id,
          event_id,
          dedupe_key,
          file_path,
          queue_state,
          first_enqueued_at,
          last_enqueued_at,
          last_enqueue_source,
          lease_run_id,
          lease_event_id,
          lease_owner,
          leased_at,
          lease_expires_at,
          acknowledged_at,
          retry_count,
          last_error
        FROM review_queue_items
        WHERE id = ?
        LIMIT 1
      `
    )
    .get(id) as ReviewQueueRow | undefined;
}

function selectLeasedRows(
  db: Database.Database,
  projectId: string,
  leaseOwner: string
): ReviewQueueRow[] {
  return db
    .prepare(
      `
        SELECT
          id,
          project_id,
          event_id,
          dedupe_key,
          file_path,
          queue_state,
          first_enqueued_at,
          last_enqueued_at,
          last_enqueue_source,
          lease_run_id,
          lease_event_id,
          lease_owner,
          leased_at,
          lease_expires_at,
          acknowledged_at,
          retry_count,
          last_error
        FROM review_queue_items
        WHERE project_id = ? AND queue_state = 'leased' AND lease_owner = ?
        ORDER BY first_enqueued_at ASC, id ASC
      `
    )
    .all(projectId, leaseOwner) as ReviewQueueRow[];
}

function selectLeaseRowsForFinalization(
  db: Database.Database,
  input: {
    projectId: string;
    leaseOwner: string;
    leaseRunId?: string;
    expectedFiles?: string[];
  }
): ReviewQueueRow[] {
  if (!input.expectedFiles) {
    return selectLeasedRows(db, input.projectId, input.leaseOwner);
  }

  return selectExpectedLeasedRows(
    db,
    input.projectId,
    input.leaseOwner,
    input.leaseRunId,
    input.expectedFiles
  );
}

function selectExpectedLeasedRows(
  db: Database.Database,
  projectId: string,
  leaseOwner: string,
  leaseRunId: string | undefined,
  expectedFiles: string[]
): ReviewQueueRow[] {
  if (expectedFiles.length === 0) {
    return [];
  }

  const placeholders = expectedFiles.map(() => "?").join(", ");
  const rows = db
    .prepare(
      `
        SELECT
          id,
          project_id,
          event_id,
          dedupe_key,
          file_path,
          queue_state,
          first_enqueued_at,
          last_enqueued_at,
          last_enqueue_source,
          lease_run_id,
          lease_event_id,
          lease_owner,
          leased_at,
          lease_expires_at,
          acknowledged_at,
          retry_count,
          last_error
        FROM review_queue_items
        WHERE project_id = ?
          AND file_path IN (${placeholders})
        ORDER BY first_enqueued_at ASC, id ASC
      `
    )
    .all(projectId, ...expectedFiles) as ReviewQueueRow[];

  const rowByPath = new Map(rows.map((row) => [row.file_path, row]));
  const lostFiles = expectedFiles.filter((filePath) => {
    const row = rowByPath.get(filePath);
    if (!row) {
      return true;
    }

    return (
      row.queue_state !== "leased" ||
      row.lease_owner !== leaseOwner ||
      row.lease_run_id !== (leaseRunId ?? null)
    );
  });

  if (lostFiles.length > 0) {
    const runSegment = leaseRunId ? ` for run_id ${leaseRunId}` : "";
    throw new Error(`lost queue lease ownership${runSegment}: ${lostFiles.join(", ")}`);
  }

  return expectedFiles.map((filePath) => rowByPath.get(filePath) as ReviewQueueRow);
}

function mapQueueRow(row: ReviewQueueRow): QueueItem {
  return {
    event_id: row.event_id,
    dedupe_key: row.dedupe_key ?? row.file_path,
    file_path: row.file_path,
    source: row.last_enqueue_source,
    queue_state: row.queue_state,
    first_enqueued_at: row.first_enqueued_at,
    last_enqueued_at: row.last_enqueued_at,
    lease_owner: row.lease_owner,
    leased_at: row.leased_at,
    lease_expires_at: row.lease_expires_at,
    acknowledged_at: row.acknowledged_at,
    retry_count: row.retry_count ?? 0,
    last_error: row.last_error ?? null
  };
}

function requireQueueRow(row: ReviewQueueRow | undefined): ReviewQueueRow {
  if (!row) {
    throw new Error("queue row not found after write");
  }

  return row;
}

function currentTimestamp(db: Database.Database): string {
  const row = db
    .prepare("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now') AS now")
    .get() as { now: string };

  return row.now;
}

function plusSeconds(timestamp: string, seconds: number): string {
  return new Date(Date.parse(timestamp) + seconds * 1000)
    .toISOString()
    .replace(/\.\d{3}Z$/, "Z");
}

function normalizeLeaseSeconds(value: number | undefined): number {
  if (value === undefined) {
    return DEFAULT_LEASE_SECONDS;
  }

  if (!Number.isInteger(value) || value < 1 || value > MAX_LEASE_SECONDS) {
    throw new Error(`lease_seconds must be an integer between 1 and ${MAX_LEASE_SECONDS}`);
  }

  return value;
}

function normalizeLeaseLimit(value: number | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (!Number.isInteger(value) || value < 1) {
    throw new Error("limit must be a positive integer");
  }

  return value;
}

function validateEnqueueFilePath(repoRoot: string, filePath: string): string {
  const normalized = canonicalizePathLike(filePath);
  if (normalized.length === 0 || normalized === ".") {
    throw new Error("file_path must not be empty");
  }

  if (CONTROL_BYTE_PATTERN.test(filePath)) {
    throw new Error("file_path must not contain control bytes");
  }

  if (isAbsolutePathLike(normalized)) {
    throw new Error("file_path must be repo-relative");
  }

  const canonicalRepoRoot = validateRepoRoot(repoRoot);
  const canonicalRelativePath = canonicalizeRelativePath(normalized, filePath);
  const resolvedPath = resolve(canonicalRepoRoot, canonicalRelativePath);
  const relativePath = relative(canonicalRepoRoot, resolvedPath);

  if (relativePath.length === 0 || isRepoExternalPath(relativePath)) {
    throw new Error(`file_path resolves outside repo_root: ${filePath}`);
  }

  assertNoSymlinkComponents(canonicalRepoRoot, canonicalRelativePath, filePath);
  return relativePath.split(sep).join("/");
}

function validateFilePath(filePath: string): string {
  const normalized = canonicalizePathLike(filePath);
  if (normalized.length === 0) {
    throw new Error("file_path must not be empty");
  }

  if (CONTROL_BYTE_PATTERN.test(filePath)) {
    throw new Error("file_path must not contain control bytes");
  }

  return normalized;
}

function canonicalizePathLike(filePath: string): string {
  const replaced = filePath.trim().replaceAll("\\", "/");
  let collapsed = "";
  let previousSlash = false;

  for (const character of replaced) {
    if (character === "/") {
      if (!previousSlash) {
        collapsed += character;
      }
      previousSlash = true;
      continue;
    }

    collapsed += character;
    previousSlash = false;
  }

  let normalized = collapsed;
  while (normalized.startsWith("./")) {
    normalized = normalized.slice(2);
  }

  return normalized.replace(/\/+$/u, "");
}

function validateRepoRoot(repoRoot: string): string {
  const normalized = repoRoot.trim();
  if (normalized.length === 0) {
    throw new Error("repo_root is required");
  }

  try {
    const resolved = realpathSync.native(normalized);
    if (!lstatSync(resolved).isDirectory()) {
      throw new Error("repo_root must resolve to a directory");
    }
    return resolved;
  } catch (error) {
    throw new Error(`repo_root must resolve to an existing directory: ${toErrorMessage(error)}`);
  }
}

function canonicalizeRelativePath(normalizedPath: string, rawPath: string): string {
  const canonicalSegments: string[] = [];
  for (const segment of normalizedPath.split("/")) {
    if (segment.length === 0 || segment === ".") {
      continue;
    }

    if (segment === "..") {
      throw new Error(`file_path must not contain traversal components: ${rawPath}`);
    }

    if (segment.startsWith("-")) {
      throw new Error(`file_path must not contain leading-dash components: ${rawPath}`);
    }

    canonicalSegments.push(segment);
  }

  if (canonicalSegments.length === 0) {
    throw new Error("file_path must not be empty");
  }

  return canonicalSegments.join("/");
}

function assertNoSymlinkComponents(
  canonicalRepoRoot: string,
  relativePath: string,
  rawPath: string
): void {
  let currentPath = canonicalRepoRoot;

  for (const segment of relativePath.split("/")) {
    currentPath = resolve(currentPath, segment);
    try {
      if (lstatSync(currentPath).isSymbolicLink()) {
        throw new Error(`file_path resolves through a symlinked path: ${rawPath}`);
      }
    } catch (error) {
      if (isMissingPathError(error)) {
        continue;
      }

      throw error;
    }
  }
}

function isAbsolutePathLike(pathValue: string): boolean {
  return isAbsolute(pathValue) || WINDOWS_DRIVE_ABSOLUTE_PATTERN.test(pathValue);
}

function isRepoExternalPath(relativePath: string): boolean {
  return (
    relativePath === ".." ||
    relativePath.startsWith(`..${sep}`) ||
    isAbsolute(relativePath)
  );
}

function isMissingPathError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

function validateSource(source: string): string {
  const normalized = source.trim();
  if (!SOURCE_PATTERN.test(normalized)) {
    throw new Error(
      "source must contain only letters, numbers, '_' or '-' and be <= 32 characters"
    );
  }

  return normalized;
}

function validateLeaseOwner(leaseOwner: string): string {
  const normalized = leaseOwner.trim();
  if (!LEASE_OWNER_PATTERN.test(normalized)) {
    throw new Error("lease_owner must contain only letters, numbers, or '-'");
  }

  return normalized;
}

function validateOptionalRunId(runId: string | undefined): string | undefined {
  if (runId === undefined) {
    return undefined;
  }

  const normalized = runId.trim();
  if (!RUN_ID_PATTERN.test(normalized)) {
    throw new Error(
      "lease_run_id must contain only letters, numbers, '.', '_', ':' or '-' and be <= 128 characters"
    );
  }

  return normalized;
}

function validateOptionalExpectedFiles(filePaths: string[] | undefined): string[] | undefined {
  if (filePaths === undefined) {
    return undefined;
  }

  if (!Array.isArray(filePaths)) {
    throw new Error("expected_files must be an array");
  }

  return filePaths.map((filePath) => validateFilePath(filePath));
}

function validateOptionalErrorMessage(errorMessage: string | undefined): string | undefined {
  if (errorMessage === undefined) {
    return undefined;
  }

  const normalized = errorMessage.trim();
  if (normalized.length === 0) {
    throw new Error("error must not be empty");
  }

  return normalized;
}
