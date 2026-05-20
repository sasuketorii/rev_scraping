import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import type { DatabaseContext } from "../db/connection.js";
import {
  completeReviewQueueLease,
  enqueueReviewQueueItem,
  exportReviewQueueJson,
  leaseReviewQueueItems,
  requeueReviewQueueLease
} from "../db/review-queue.js";

const DEFAULT_DRAIN_LIMIT = 200;
const MAX_DRAIN_LIMIT = 500;
const DEFAULT_LEASE_SECONDS = 900;
const MAX_LEASE_SECONDS = 86400;
const RUN_STATUS_SET = new Set<ReviewRunStatus>(["started", "completed", "failed"]);
const REVIEW_RUN_METADATA_LEASE_OWNER_KEY = "_queue_lease_owner";

type ReviewRunStatus = "started" | "completed" | "failed";

interface JsonObject {
  [key: string]: unknown;
}

interface ReviewRunRow {
  run_id: string;
  status: ReviewRunStatus;
  file_count: number;
  files_json: string;
  metadata_json: string;
}

interface NormalizedQueueEnqueueInput {
  file_path: string;
  source: string;
  metadata_json: string;
  export_path?: string;
}

interface NormalizedQueueDrainInput {
  run_id: string;
  consumer: string;
  limit: number;
  lease_seconds: number;
  export_path?: string;
}

interface NormalizedReviewRunRecordInput {
  run_id: string;
  status: Exclude<ReviewRunStatus, "started">;
  reviewer?: string;
  summary?: string;
  blocker_summary?: string;
  findings_json: string;
  metadata_json: string;
  error_message?: string;
  requeue: boolean;
  export_path?: string;
}

export interface ReviewQueueSnapshot {
  pending_review: boolean;
  changed_files: string[];
  last_change: string;
}

export interface ReviewQueueEnqueueResponse {
  queued: true;
  file_path: string;
  snapshot: ReviewQueueSnapshot;
}

export interface ReviewQueueDrainResponse {
  run_id: string;
  consumer: string;
  lease_expires_at: string;
  files: string[];
  leased_count: number;
  snapshot: ReviewQueueSnapshot;
}

export interface ReviewRunRecordResponse {
  run_id: string;
  status: Exclude<ReviewRunStatus, "started">;
  completed_at: string;
  completed_count: number;
  requeued_count: number;
  snapshot: ReviewQueueSnapshot;
}

export function handleReviewQueueEnqueue(
  context: DatabaseContext,
  rawInput: unknown
): ReviewQueueEnqueueResponse {
  try {
    const input = normalizeQueueEnqueueInput(rawInput);
    enqueueReviewQueueItem(context.db, {
      projectId: context.projectId,
      repoRoot: requireRepoRoot(context),
      filePath: input.file_path,
      source: input.source
    });
    const snapshot = exportReviewQueueSnapshot(context, input.export_path);

    return {
      queued: true,
      file_path: input.file_path,
      snapshot
    };
  } catch (error) {
    throw new Error(`review.queue.enqueue failed: ${toErrorMessage(error)}`);
  }
}

export function handleReviewQueueDrain(
  context: DatabaseContext,
  rawInput: unknown
): ReviewQueueDrainResponse {
  try {
    const input = normalizeQueueDrainInput(rawInput);
    const fallbackLeaseExpiresAt = plusSeconds(currentTimestamp(), input.lease_seconds);

    const transaction = context.db.transaction(() => {
      const existingRun = context.db
        .prepare(
          `
          SELECT run_id
          FROM review_runs
          WHERE project_id = ? AND run_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, input.run_id) as { run_id: string } | undefined;

      if (existingRun) {
        throw new Error(`run_id already exists: ${input.run_id}`);
      }

      const leased = leaseReviewQueueItems(context.db, {
        projectId: context.projectId,
        leaseRunId: input.run_id,
        leaseSeconds: input.lease_seconds,
        limit: input.limit
      });
      const files = leased.items.map((item) => item.file_path);

      if (files.length === 0 || !leased.lease_owner || !leased.lease_expires_at) {
        return {
          files,
          lease_expires_at: leased.lease_expires_at ?? fallbackLeaseExpiresAt
        };
      }

      context.db
        .prepare(
          `
          INSERT INTO review_runs (
            project_id,
            run_id,
            status,
            consumer,
            reviewer,
            file_count,
            files_json,
            findings_json,
            summary,
            result_summary,
            error_message,
            metadata_json,
            started_at,
            completed_at,
            created_at,
            updated_at
          )
          VALUES (?, ?, 'started', ?, NULL, ?, ?, '[]', NULL, NULL, NULL, ?, ?, NULL, ?, ?)
        `
        )
        .run(
          context.projectId,
          input.run_id,
          input.consumer,
          files.length,
          JSON.stringify(files),
          JSON.stringify({
            [REVIEW_RUN_METADATA_LEASE_OWNER_KEY]: leased.lease_owner
          }),
          leased.leased_at,
          leased.leased_at,
          leased.leased_at
        );

      return {
        files,
        lease_expires_at: leased.lease_expires_at
      };
    });

    const result = transaction();
    const snapshot = exportReviewQueueSnapshot(context, input.export_path);

    return {
      run_id: input.run_id,
      consumer: input.consumer,
      lease_expires_at: result.lease_expires_at,
      files: result.files,
      leased_count: result.files.length,
      snapshot
    };
  } catch (error) {
    throw new Error(`review.queue.drain failed: ${toErrorMessage(error)}`);
  }
}

export function handleReviewRunRecord(
  context: DatabaseContext,
  rawInput: unknown
): ReviewRunRecordResponse {
  try {
    const input = normalizeReviewRunRecordInput(rawInput);

    const transaction = context.db.transaction(() => {
      const runRow = context.db
        .prepare(
          `
          SELECT run_id, status, file_count, files_json, metadata_json
          FROM review_runs
          WHERE project_id = ? AND run_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, input.run_id) as ReviewRunRow | undefined;

      if (!runRow) {
        throw new Error(`run_id not found: ${input.run_id}`);
      }

      if (runRow.status !== "started") {
        throw new Error(`run_id already finalized: ${input.run_id}`);
      }

      if (input.status === "failed" && !input.requeue) {
        throw new Error(
          "failed review runs must set requeue=true; queue lease contract: require requeue=true"
        );
      }

      const existingMetadata = parseJsonRecord(runRow.metadata_json, "review_runs.metadata_json");
      const leaseOwner = readRunLeaseOwner(existingMetadata);
      const expectedFiles = parseStoredRunFiles(runRow.files_json);
      if (runRow.file_count !== expectedFiles.length) {
        throw new Error(
          `review_runs file_count mismatch for run_id ${input.run_id}: expected ${runRow.file_count}, got ${expectedFiles.length}`
        );
      }
      const queueResult =
        input.status === "completed"
          ? (() => {
              const completed = completeReviewQueueLease(context.db, {
                projectId: context.projectId,
                leaseOwner,
                leaseRunId: input.run_id,
                expectedFiles
              });

              return {
                completed_at: completed.completed_at,
                completed_count: completed.completed_count,
                requeued_count: 0
              };
            })()
          : (() => {
              const requeued = requeueReviewQueueLease(context.db, {
                projectId: context.projectId,
                leaseOwner,
                leaseRunId: input.run_id,
                expectedFiles,
                errorMessage: input.error_message ?? `review run failed: ${input.run_id}`
              });

              return {
                completed_at: requeued.requeued_at,
                completed_count: 0,
                requeued_count: requeued.requeued_count
              };
            })();

      const updateResult = context.db
        .prepare(
          `
          UPDATE review_runs
          SET status = ?,
              reviewer = COALESCE(?, reviewer),
              findings_json = ?,
              summary = NULL,
              result_summary = ?,
              blocker_summary = ?,
              error_message = ?,
              metadata_json = ?,
              completed_at = ?,
              updated_at = ?
          WHERE project_id = ? AND run_id = ? AND status = 'started'
        `
        )
        .run(
          input.status,
          input.reviewer ?? null,
          input.findings_json,
          input.summary ?? null,
          input.blocker_summary ?? null,
          input.error_message ?? null,
          mergeReviewRunMetadata(existingMetadata, input.metadata_json, leaseOwner),
          queueResult.completed_at,
          queueResult.completed_at,
          context.projectId,
          input.run_id
        );
      if (updateResult.changes !== 1) {
        throw new Error(`run_id became stale before finalization: ${input.run_id}`);
      }

      return queueResult;
    });

    const result = transaction();
    const snapshot = exportReviewQueueSnapshot(context, input.export_path);

    return {
      run_id: input.run_id,
      status: input.status,
      completed_at: result.completed_at,
      completed_count: result.completed_count,
      requeued_count: result.requeued_count,
      snapshot
    };
  } catch (error) {
    throw new Error(`review.run.record failed: ${toErrorMessage(error)}`);
  }
}

export function exportReviewQueueSnapshot(
  context: DatabaseContext,
  outputPath?: string
): ReviewQueueSnapshot {
  try {
    const snapshot = getReviewQueueSnapshot(context);

    if (outputPath) {
      writeTextFileAtomically(outputPath, JSON.stringify(snapshot));
    }

    return snapshot;
  } catch (error) {
    throw new Error(`review.queue.snapshot failed: ${toErrorMessage(error)}`);
  }
}

export function getReviewQueueSnapshot(context: DatabaseContext): ReviewQueueSnapshot {
  const snapshot = exportReviewQueueJson(context.db, context.projectId);

  return {
    pending_review: snapshot.pending_review,
    changed_files: snapshot.changed_files,
    last_change: snapshot.last_change
  };
}

function requireRepoRoot(context: DatabaseContext): string {
  if (typeof context.repoRoot === "string" && context.repoRoot.trim().length > 0) {
    return context.repoRoot;
  }

  throw new Error("review.queue.enqueue requires a repo_root-backed database context");
}

function normalizeQueueEnqueueInput(rawInput: unknown): NormalizedQueueEnqueueInput {
  const input = unwrapToolInput(rawInput);

  return {
    file_path: readRequiredString(input, "file_path"),
    source: readOptionalString(input, "source") ?? "unknown",
    metadata_json: normalizeJsonRecord(input.metadata, "metadata"),
    export_path: readOptionalString(input, "export_path") ?? readOptionalString(input, "output_path")
  };
}

function normalizeQueueDrainInput(rawInput: unknown): NormalizedQueueDrainInput {
  const input = unwrapToolInput(rawInput);
  const limit = clamp(
    readOptionalInteger(input.limit, "limit") ?? DEFAULT_DRAIN_LIMIT,
    1,
    MAX_DRAIN_LIMIT
  );
  const leaseSeconds = clamp(
    readOptionalInteger(input.lease_seconds, "lease_seconds") ??
      readOptionalInteger(input.leaseSeconds, "leaseSeconds") ??
      DEFAULT_LEASE_SECONDS,
    1,
    MAX_LEASE_SECONDS
  );

  return {
    run_id: readRequiredString(input, "run_id"),
    consumer: readOptionalString(input, "consumer") ?? "unknown",
    limit,
    lease_seconds: leaseSeconds,
    export_path: readOptionalString(input, "export_path") ?? readOptionalString(input, "output_path")
  };
}

function normalizeReviewRunRecordInput(rawInput: unknown): NormalizedReviewRunRecordInput {
  const input = unwrapToolInput(rawInput);
  const status = normalizeReviewRunStatus(readRequiredString(input, "status"));
  if (status === "started") {
    throw new Error("status must be completed or failed");
  }

  const findings = input.findings ?? [];
  if (!Array.isArray(findings)) {
    throw new Error("findings must be an array");
  }

  const metadataJson = normalizeJsonRecord(input.metadata, "metadata");
  const rawRequeue = input.requeue;
  const requeue =
    rawRequeue === undefined ? status === "failed" : readBoolean(rawRequeue, "requeue");

  return {
    run_id: readRequiredString(input, "run_id"),
    status,
    reviewer: readOptionalString(input, "reviewer"),
    summary: readOptionalString(input, "summary"),
    blocker_summary: readOptionalString(input, "blocker_summary"),
    findings_json: JSON.stringify(findings),
    metadata_json: metadataJson,
    error_message:
      readOptionalString(input, "error_message") ?? readOptionalString(input, "error"),
    requeue,
    export_path: readOptionalString(input, "export_path") ?? readOptionalString(input, "output_path")
  };
}

function normalizeReviewRunStatus(value: string): ReviewRunStatus {
  const normalized = value.trim().toLowerCase();
  if (!RUN_STATUS_SET.has(normalized as ReviewRunStatus)) {
    throw new Error("status must be one of: started, completed, failed");
  }

  return normalized as ReviewRunStatus;
}

function normalizeJsonRecord(value: unknown, field: string): string {
  if (value === undefined || value === null) {
    return "{}";
  }

  if (!isObject(value)) {
    throw new Error(`${field} must be an object`);
  }

  return JSON.stringify(value);
}

function parseJsonRecord(value: string, field: string): JsonObject {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!isObject(parsed)) {
      throw new Error("not an object");
    }

    return parsed;
  } catch (error) {
    throw new Error(`${field} is malformed: ${toErrorMessage(error)}`);
  }
}

function readRequiredString(payload: JsonObject, key: string): string {
  const value = readOptionalString(payload, key);
  if (!value) {
    throw new Error(`${key} is required`);
  }

  return value;
}

function readOptionalString(payload: JsonObject, key: string): string | undefined {
  const value = payload[key];
  if (value === undefined || value === null) {
    return undefined;
  }

  if (typeof value !== "string") {
    throw new Error(`${key} must be a string`);
  }

  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error(`${key} must not be empty`);
  }

  return trimmed;
}

function readOptionalInteger(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (typeof value === "number" && Number.isInteger(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isInteger(parsed)) {
      return parsed;
    }
  }

  throw new Error(`${field} must be an integer`);
}

function readBoolean(value: unknown, field: string): boolean {
  if (typeof value === "boolean") {
    return value;
  }

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (normalized === "true") {
      return true;
    }
    if (normalized === "false") {
      return false;
    }
  }

  throw new Error(`${field} must be a boolean`);
}

function readRunLeaseOwner(metadata: JsonObject): string {
  const leaseOwner = metadata[REVIEW_RUN_METADATA_LEASE_OWNER_KEY];
  if (typeof leaseOwner !== "string" || leaseOwner.trim().length === 0) {
    throw new Error(`review run metadata missing ${REVIEW_RUN_METADATA_LEASE_OWNER_KEY}`);
  }

  return leaseOwner;
}

function mergeReviewRunMetadata(
  existingMetadata: JsonObject,
  inputMetadataJson: string,
  leaseOwner: string
): string {
  return JSON.stringify({
    ...existingMetadata,
    ...parseJsonRecord(inputMetadataJson, "metadata_json"),
    [REVIEW_RUN_METADATA_LEASE_OWNER_KEY]: leaseOwner
  });
}

function parseStoredRunFiles(value: string): string[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) {
      throw new Error("not an array");
    }

    return parsed.map((entry, index) => {
      if (typeof entry !== "string" || entry.trim().length === 0) {
        throw new Error(`files_json[${index}] must be a non-empty string`);
      }

      return entry;
    });
  } catch (error) {
    throw new Error(`review_runs.files_json is malformed: ${toErrorMessage(error)}`);
  }
}

function asRequiredObject(value: unknown, field: string): JsonObject {
  if (!isObject(value)) {
    throw new Error(`${field} must be an object`);
  }

  return value;
}

function unwrapToolInput(rawInput: unknown): JsonObject {
  const payload = asRequiredObject(rawInput, "input");
  if ("input" in payload) {
    return asRequiredObject(payload.input, "input");
  }

  return payload;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function currentTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function plusSeconds(timestamp: string, seconds: number): string {
  return new Date(Date.parse(timestamp) + seconds * 1000)
    .toISOString()
    .replace(/\.\d{3}Z$/, "Z");
}

function writeTextFileAtomically(outputPath: string, content: string): void {
  const resolvedPath = resolve(outputPath);
  mkdirSync(dirname(resolvedPath), { recursive: true });

  const tempPath = `${resolvedPath}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tempPath, content, "utf8");
  renameSync(tempPath, resolvedPath);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
