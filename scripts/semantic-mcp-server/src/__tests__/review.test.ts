import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DatabaseContext } from "../db/connection.js";
import { runMigrations } from "../db/migrations.js";
import {
  handleReviewQueueDrain,
  handleReviewQueueEnqueue,
  handleReviewRunRecord
} from "../tools/review.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";

describe("review tools", () => {
  let context: DatabaseContext;
  let cleanup: (() => void) | null = null;

  beforeEach(() => {
    const created = createTestContext();
    context = created.context;
    cleanup = created.cleanup;
  });

  afterEach(() => {
    cleanup?.();
    cleanup = null;
  });

  it("completes leased work only after explicit completed status", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/a.ts",
      source: "hook"
    });
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/b.ts",
      source: "hook"
    });

    const drained = handleReviewQueueDrain(context, {
      run_id: "run-complete",
      consumer: "tool-consumer",
      limit: 1
    });

    expect(drained).toMatchObject({
      run_id: "run-complete",
      consumer: "tool-consumer",
      leased_count: 1,
      files: ["src/review/a.ts"]
    });

    const recorded = handleReviewRunRecord(context, {
      run_id: "run-complete",
      status: "completed",
      findings: [],
      summary: "completed"
    });

    expect(recorded).toMatchObject({
      run_id: "run-complete",
      status: "completed",
      completed_count: 1,
      requeued_count: 0
    });

    const rows = context.db
      .prepare(
        `
          SELECT file_path, queue_state, acknowledged_at, completed_at, retry_count
          FROM review_queue_items
          WHERE project_id = ?
          ORDER BY file_path ASC
        `
      )
      .all(PROJECT_ID) as Array<{
      file_path: string;
      queue_state: string;
      acknowledged_at: string | null;
      completed_at: string | null;
      retry_count: number;
    }>;

    expect(rows).toEqual([
      {
        file_path: "src/review/a.ts",
        queue_state: "done",
        acknowledged_at: recorded.completed_at,
        completed_at: recorded.completed_at,
        retry_count: 0
      },
      {
        file_path: "src/review/b.ts",
        queue_state: "pending",
        acknowledged_at: null,
        completed_at: null,
        retry_count: 0
      }
    ]);
  });

  it("requeues failed work through the shared queue helpers", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/retry.ts"
    });

    handleReviewQueueDrain(context, {
      run_id: "run-requeue",
      consumer: "tool-consumer"
    });

    const recorded = handleReviewRunRecord(context, {
      run_id: "run-requeue",
      status: "failed",
      findings: [],
      error_message: "transient failure"
    });

    expect(recorded).toMatchObject({
      run_id: "run-requeue",
      status: "failed",
      completed_count: 0,
      requeued_count: 1
    });

    const row = context.db
      .prepare(
        `
          SELECT file_path, queue_state, acknowledged_at, completed_at, retry_count, last_error
          FROM review_queue_items
          WHERE project_id = ? AND file_path = ?
        `
      )
      .get(PROJECT_ID, "src/review/retry.ts") as {
      file_path: string;
      queue_state: string;
      acknowledged_at: string | null;
      completed_at: string | null;
      retry_count: number;
      last_error: string | null;
    };

    expect(row).toEqual({
      file_path: "src/review/retry.ts",
      queue_state: "pending",
      acknowledged_at: null,
      completed_at: null,
      retry_count: 1,
      last_error: "transient failure"
    });
  });

  it("fails closed when a failed review tries to disable requeue", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/fail-closed.ts"
    });

    handleReviewQueueDrain(context, {
      run_id: "run-fail-closed",
      consumer: "tool-consumer"
    });

    expect(() =>
      handleReviewRunRecord(context, {
        run_id: "run-fail-closed",
        status: "failed",
        findings: [],
        requeue: false,
        error_message: "hard failure"
      })
    ).toThrow(/failed review runs must set requeue=true/);

    const queueRow = context.db
      .prepare(
        `
          SELECT queue_state, acknowledged_at, completed_at, last_error
          FROM review_queue_items
          WHERE project_id = ? AND file_path = ?
        `
      )
      .get(PROJECT_ID, "src/review/fail-closed.ts") as {
      queue_state: string;
      acknowledged_at: string | null;
      completed_at: string | null;
      last_error: string | null;
    };
    expect(queueRow).toEqual({
      queue_state: "leased",
      acknowledged_at: null,
      completed_at: null,
      last_error: null
    });

    const runRow = context.db
      .prepare(
        `
          SELECT status, completed_at, error_message
          FROM review_runs
          WHERE project_id = ? AND run_id = ?
        `
      )
      .get(PROJECT_ID, "run-fail-closed") as {
      status: string;
      completed_at: string | null;
      error_message: string | null;
    };
    expect(runRow).toEqual({
      status: "started",
      completed_at: null,
      error_message: null
    });
  });

  it("restores lease_run_id attribution for active review leases", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/attribution.ts"
    });

    handleReviewQueueDrain(context, {
      run_id: "run-attribution",
      consumer: "tool-consumer"
    });

    const queueRow = context.db
      .prepare(
        `
          SELECT lease_run_id, queue_state
          FROM review_queue_items
          WHERE project_id = ? AND file_path = ?
        `
      )
      .get(PROJECT_ID, "src/review/attribution.ts") as {
      lease_run_id: string | null;
      queue_state: string;
    };

    expect(queueRow).toEqual({
      lease_run_id: "run-attribution",
      queue_state: "leased"
    });
  });
});

function createTestContext(): {
  context: DatabaseContext;
  cleanup: () => void;
} {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-review-test-"));
  const dbPath = join(tempDir, "semantic.db");
  const db = new BetterSqlite3(dbPath);
  runMigrations(db);

  db.prepare(
    `
      INSERT INTO projects (id, name, root_path, created_at, updated_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `
  ).run(PROJECT_ID, "Test Project", "/tmp/test-project");

  return {
    context: {
      projectId: PROJECT_ID,
      dbPath,
      repoRoot: tempDir,
      db
    },
    cleanup: () => {
      db.close();
      rmSync(tempDir, { recursive: true, force: true });
    }
  };
}
