import { createHash } from "node:crypto";
import type Database from "better-sqlite3";
import { validateProjectId } from "../utils/project-id.js";

const IDENTIFIER_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const RUN_STATUS_SET = new Set(["completed", "failed"]);

interface JsonRecord {
  [key: string]: unknown;
}

export interface ReviewRunRecordInput {
  run_id: string;
  phase: string;
  iteration: number;
  kind: string;
  status: "completed" | "failed";
  queued_files: string[];
  summary?: string;
  blocker_summary?: string;
  report_body?: string;
  report_hash?: string;
  findings?: unknown[];
  consumer?: string;
  reviewer?: string;
  error_message?: string;
  metadata?: JsonRecord;
}

export interface ReviewRunRecordResult {
  project_id: string;
  run_id: string;
  phase: string;
  iteration: number;
  kind: string;
  status: "completed" | "failed";
  queued_file_count: number;
  report_hash: string;
  created_at: string;
}

export function parseReviewRunRecordInput(raw: unknown): ReviewRunRecordInput {
  const input = unwrapReviewRunInput(raw);

  const runId = readIdentifier(input, "run_id");
  const phase = readIdentifier(input, "phase");
  const kind = readIdentifier(input, "kind");
  const status = readStatus(input.status);
  const iteration = readIteration(input.iteration);
  const queuedFiles = readStringArray(input.queued_files, "queued_files");
  const summary = readOptionalString(input.summary, "summary");
  const blockerSummary = readOptionalString(input.blocker_summary, "blocker_summary");
  const reportBody = readOptionalString(input.report_body, "report_body");
  const reportHash = readOptionalHash(input.report_hash);
  if (!reportBody && !reportHash) {
    throw new Error("review-run input requires report_body or report_hash");
  }

  const findings = readOptionalArray(input.findings, "findings");
  const metadata = readOptionalRecord(input.metadata, "metadata");

  return {
    run_id: runId,
    phase,
    iteration,
    kind,
    status,
    queued_files: queuedFiles,
    summary,
    blocker_summary: blockerSummary,
    report_body: reportBody,
    report_hash: reportHash,
    findings,
    consumer: readOptionalString(input.consumer, "consumer"),
    reviewer: readOptionalString(input.reviewer, "reviewer"),
    error_message: readOptionalString(input.error_message, "error_message"),
    metadata
  };
}

export function recordReviewRun(
  db: Database.Database,
  projectIdInput: string,
  input: ReviewRunRecordInput
): ReviewRunRecordResult {
  const projectId = validateProjectId(projectIdInput);
  const normalized = parseReviewRunRecordInput(input);
  const reportHash = resolveReportHash(normalized);
  const queuedFilesJson = JSON.stringify(normalized.queued_files);
  const findingsJson = stableStringify(normalized.findings ?? []);
  const metadataJson = stableStringify(normalized.metadata ?? {});

  return db.transaction(() => {
    const existing = selectStoredRun(db, projectId, normalized.run_id);
    if (existing) {
      const replay = classifyStoredRunReplay(
        existing,
        normalized,
        reportHash,
        queuedFilesJson,
        findingsJson,
        metadataJson
      );
      if (replay === "upgrade-legacy") {
        upgradeLegacyReviewRun(
          db,
          projectId,
          normalized,
          reportHash,
          queuedFilesJson,
          findingsJson,
          metadataJson
        );
      }

      const stored = selectStoredRun(db, projectId, normalized.run_id);
      if (!stored) {
        throw new Error("review run not found after legacy upgrade");
      }
      return toRecordResult(stored);
    }

    const timestamp = currentTimestamp(db);
    db.prepare(
      `
        INSERT INTO review_runs (
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `
    ).run(
      projectId,
      normalized.run_id,
      normalized.status,
      normalized.phase,
      normalized.iteration,
      normalized.kind,
      normalized.consumer ?? null,
      normalized.reviewer ?? null,
      normalized.queued_files.length,
      queuedFilesJson,
      findingsJson,
      null,
      normalized.summary ?? null,
      normalized.blocker_summary ?? null,
      normalized.report_body ?? null,
      reportHash,
      normalized.error_message ?? null,
      metadataJson,
      timestamp,
      timestamp,
      timestamp,
      timestamp
    );

    const row = selectStoredRun(db, projectId, normalized.run_id);
    if (!row) {
      throw new Error("review run not found after write");
    }

    return toRecordResult(row);
  })();
}

function currentTimestamp(db: Database.Database): string {
  const row = db
    .prepare("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now') AS now")
    .get() as { now: string };

  return row.now;
}

interface StoredReviewRunRow {
  project_id: string;
  run_id: string;
  phase: string | null;
  iteration: number | null;
  kind: string | null;
  status: "started" | "completed" | "failed";
  consumer: string | null;
  reviewer: string | null;
  file_count: number;
  files_json: string;
  findings_json: string;
  summary: string | null;
  result_summary: string | null;
  blocker_summary: string | null;
  report_body: string | null;
  report_hash: string | null;
  error_message: string | null;
  metadata_json: string;
  created_at: string;
}

function selectStoredRun(
  db: Database.Database,
  projectId: string,
  runId: string
): StoredReviewRunRow | undefined {
  return db
    .prepare(
      `
        SELECT
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
        WHERE project_id = ? AND run_id = ?
        LIMIT 1
      `
    )
    .get(projectId, runId) as StoredReviewRunRow | undefined;
}

function classifyStoredRunReplay(
  existing: StoredReviewRunRow,
  normalized: ReviewRunRecordInput,
  reportHash: string,
  queuedFilesJson: string,
  findingsJson: string,
  metadataJson: string
): "exact" | "upgrade-legacy" {
  const storedSummary = existing.result_summary ?? existing.summary;
  const samePayload =
    existing.phase === normalized.phase &&
    existing.iteration === normalized.iteration &&
    existing.kind === normalized.kind &&
    existing.status === normalized.status &&
    existing.consumer === (normalized.consumer ?? null) &&
    existing.reviewer === (normalized.reviewer ?? null) &&
    existing.file_count === normalized.queued_files.length &&
    normalizedJsonString(existing.files_json) === normalizedJsonString(queuedFilesJson) &&
    normalizedJsonString(existing.findings_json) === normalizedJsonString(findingsJson) &&
    storedSummary === (normalized.summary ?? null) &&
    existing.blocker_summary === (normalized.blocker_summary ?? null) &&
    existing.report_body === (normalized.report_body ?? null) &&
    existing.report_hash === reportHash &&
    existing.error_message === (normalized.error_message ?? null) &&
    normalizedJsonString(existing.metadata_json) === normalizedJsonString(metadataJson);

  if (samePayload) {
    return "exact";
  }

  if (
    isSparseLegacyReviewRun(existing) &&
    storedSummary !== null &&
    storedSummary === (normalized.summary ?? null)
  ) {
    return "upgrade-legacy";
  }

  throw new Error(`run_id already exists with different payload: ${normalized.run_id}`);
}

function normalizedJsonString(raw: string): string {
  try {
    return stableStringify(JSON.parse(raw) as unknown);
  } catch {
    return raw;
  }
}

function stableStringify(value: unknown): string {
  return JSON.stringify(normalizeJsonValue(value));
}

function normalizeJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => normalizeJsonValue(item));
  }

  if (isObject(value)) {
    const normalized: JsonRecord = {};
    const entries = Object.entries(value).filter(([, entryValue]) => entryValue !== undefined);
    entries.sort(([left], [right]) => left.localeCompare(right));
    for (const [key, entryValue] of entries) {
      normalized[key] = normalizeJsonValue(entryValue);
    }
    return normalized;
  }

  return value;
}

function isSparseLegacyReviewRun(existing: StoredReviewRunRow): boolean {
  return (
    existing.phase === null &&
    existing.iteration === null &&
    existing.kind === null &&
    existing.status === "started" &&
    existing.consumer === null &&
    existing.reviewer === null &&
    existing.file_count === 0 &&
    normalizedJsonString(existing.files_json) === "[]" &&
    normalizedJsonString(existing.findings_json) === "[]" &&
    existing.blocker_summary === null &&
    existing.report_body === null &&
    existing.report_hash === null &&
    existing.error_message === null &&
    normalizedJsonString(existing.metadata_json) === "{}"
  );
}

function upgradeLegacyReviewRun(
  db: Database.Database,
  projectId: string,
  normalized: ReviewRunRecordInput,
  reportHash: string,
  queuedFilesJson: string,
  findingsJson: string,
  metadataJson: string
): void {
  const timestamp = currentTimestamp(db);
  db.prepare(
    `
      UPDATE review_runs
      SET status = ?,
          phase = ?,
          iteration = ?,
          kind = ?,
          consumer = ?,
          reviewer = ?,
          file_count = ?,
          files_json = ?,
          findings_json = ?,
          summary = NULL,
          result_summary = ?,
          blocker_summary = ?,
          report_body = ?,
          report_hash = ?,
          error_message = ?,
          metadata_json = ?,
          completed_at = CASE
            WHEN ? IN ('completed', 'failed') THEN COALESCE(completed_at, ?)
            ELSE completed_at
          END,
          updated_at = ?
      WHERE project_id = ? AND run_id = ?
    `
  ).run(
    normalized.status,
    normalized.phase,
    normalized.iteration,
    normalized.kind,
    normalized.consumer ?? null,
    normalized.reviewer ?? null,
    normalized.queued_files.length,
    queuedFilesJson,
    findingsJson,
    normalized.summary ?? null,
    normalized.blocker_summary ?? null,
    normalized.report_body ?? null,
    reportHash,
    normalized.error_message ?? null,
    metadataJson,
    normalized.status,
    timestamp,
    timestamp,
    projectId,
    normalized.run_id
  );
}

function toRecordResult(row: StoredReviewRunRow): ReviewRunRecordResult {
  return {
    project_id: row.project_id,
    run_id: row.run_id,
    phase: row.phase ?? "",
    iteration: row.iteration ?? 0,
    kind: row.kind ?? "",
    status: row.status === "failed" ? "failed" : "completed",
    queued_file_count: row.file_count,
    report_hash: row.report_hash ?? "",
    created_at: row.created_at
  };
}

function hashReportBody(reportBody: string): string {
  return createHash("sha256").update(reportBody, "utf8").digest("hex");
}

function resolveReportHash(input: ReviewRunRecordInput): string {
  if (input.report_body && input.report_hash) {
    const derivedHash = hashReportBody(input.report_body);
    if (derivedHash !== input.report_hash) {
      throw new Error("report_hash must match the sha256 of report_body when both are supplied");
    }
    return input.report_hash;
  }

  if (input.report_body) {
    return hashReportBody(input.report_body);
  }

  if (input.report_hash) {
    return input.report_hash;
  }

  throw new Error("review-run input requires report_body or report_hash");
}

function isObject(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function unwrapReviewRunInput(raw: unknown): JsonRecord {
  if (!isObject(raw)) {
    throw new Error("review-run input must be an object");
  }

  if ("input" in raw) {
    if (!isObject(raw.input)) {
      throw new Error("review-run input.input must be an object");
    }

    return raw.input;
  }

  return raw;
}

function readIdentifier(payload: JsonRecord, field: string): string {
  const value = readOptionalString(payload[field], field);
  if (!value) {
    throw new Error(`${field} is required`);
  }

  if (!IDENTIFIER_PATTERN.test(value)) {
    throw new Error(
      `${field} must contain only letters, numbers, '.', '_', ':' or '-' and be <= 128 characters`
    );
  }

  return value;
}

function readStatus(value: unknown): "completed" | "failed" {
  const normalized = readOptionalString(value, "status");
  if (!normalized) {
    throw new Error("status is required");
  }

  if (!RUN_STATUS_SET.has(normalized)) {
    throw new Error("status must be one of: completed, failed");
  }

  return normalized as "completed" | "failed";
}

function readIteration(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error("iteration must be a non-negative integer");
  }

  return value;
}

function readStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value)) {
    throw new Error(`${field} must be an array`);
  }

  return value.map((entry, index) => {
    const normalized = readOptionalString(entry, `${field}[${index}]`);
    if (!normalized) {
      throw new Error(`${field}[${index}] must not be empty`);
    }

    return normalized;
  });
}

function readOptionalArray(value: unknown, field: string): unknown[] | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (!Array.isArray(value)) {
    throw new Error(`${field} must be an array`);
  }

  return value;
}

function readOptionalRecord(value: unknown, field: string): JsonRecord | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (!isObject(value)) {
    throw new Error(`${field} must be an object`);
  }

  return value;
}

function readOptionalHash(value: unknown): string | undefined {
  const normalized = readOptionalString(value, "report_hash");
  if (!normalized) {
    return undefined;
  }

  if (!/^[A-Fa-f0-9]{64}$/.test(normalized)) {
    throw new Error("report_hash must be a 64-character hex sha256");
  }

  return normalized.toLowerCase();
}

function readOptionalString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }

  const normalized = value.trim();
  if (normalized.length === 0) {
    throw new Error(`${field} must not be empty`);
  }

  return normalized;
}
