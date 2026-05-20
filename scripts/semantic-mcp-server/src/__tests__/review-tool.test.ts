import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
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

describe("review tool regressions", () => {
  let context: DatabaseContext;
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(join(tmpdir(), "semantic-mcp-review-tool-root-"));
    const db = new BetterSqlite3(":memory:");
    runMigrations(db);
    context = {
      projectId: PROJECT_ID,
      dbPath: ":memory:",
      repoRoot,
      db
    };
  });

  afterEach(() => {
    context.db.close();
    rmSync(repoRoot, { recursive: true, force: true });
  });

  it("preserves an active lease when the same file is re-enqueued", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/tool.ts",
      source: "hook"
    });

    handleReviewQueueDrain(context, {
      run_id: "run-1",
      consumer: "worker-1",
      lease_seconds: 60
    });
    const leasedBeforeReenqueue = readQueueRow("src/review/tool.ts");

    handleReviewQueueEnqueue(context, {
      file_path: "src/review/tool.ts",
      source: "hook",
      metadata: { reason: "changed" }
    });

    const leasedAfterReenqueue = readQueueRow("src/review/tool.ts");
    expect(leasedAfterReenqueue.queue_state).toBe("leased");
    expect(leasedAfterReenqueue.lease_run_id).toBe("run-1");
    expect(leasedAfterReenqueue.lease_owner).toBeTruthy();
    expect(leasedAfterReenqueue.event_id).not.toBe(leasedBeforeReenqueue.event_id);
    expect(leasedAfterReenqueue.lease_event_id).toBe(leasedBeforeReenqueue.event_id);

    const recorded = handleReviewRunRecord(context, {
      run_id: "run-1",
      status: "completed",
      findings: []
    });
    expect(recorded.completed_count).toBe(0);
    expect(recorded.requeued_count).toBe(0);
    expect(recorded.snapshot).toEqual({
      pending_review: true,
      changed_files: ["src/review/tool.ts"],
      last_change: leasedAfterReenqueue.last_enqueued_at
    });

    expect(readQueueRow("src/review/tool.ts")).toMatchObject({
      queue_state: "pending",
      lease_owner: null,
      lease_event_id: null,
      retry_count: 0,
      last_error: null
    });

    const redrain = handleReviewQueueDrain(context, {
      run_id: "run-2",
      consumer: "worker-1",
      lease_seconds: 60
    });
    expect(redrain).toMatchObject({
      run_id: "run-2",
      leased_count: 1,
      files: ["src/review/tool.ts"]
    });
  });

  it("requeues failed work and increments retry_count", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/failure.ts"
    });
    handleReviewQueueDrain(context, {
      run_id: "run-fail",
      consumer: "worker-1",
      lease_seconds: 60
    });

    const recorded = handleReviewRunRecord(context, {
      run_id: "run-fail",
      status: "failed",
      error_message: "transient failure",
      findings: []
    });

    expect(recorded).toMatchObject({
      run_id: "run-fail",
      status: "failed",
      completed_count: 0,
      requeued_count: 1
    });
    expect(readQueueRow("src/review/failure.ts")).toMatchObject({
      queue_state: "pending",
      retry_count: 1,
      last_error: "transient failure"
    });
  });

  it("accepts legacy nested input payloads for tool entrypoints", () => {
    handleReviewQueueEnqueue(context, {
      input: {
        file_path: "src/review/nested.ts",
        source: "hook"
      }
    });

    const drained = handleReviewQueueDrain(context, {
      input: {
        run_id: "run-nested",
        consumer: "worker-1",
        lease_seconds: 60
      }
    });
    expect(drained).toMatchObject({
      run_id: "run-nested",
      leased_count: 1,
      files: ["src/review/nested.ts"]
    });
    expect(readQueueRow("src/review/nested.ts").lease_run_id).toBe("run-nested");

    const recorded = handleReviewRunRecord(context, {
      input: {
        run_id: "run-nested",
        status: "completed",
        findings: []
      }
    });
    expect(recorded).toMatchObject({
      run_id: "run-nested",
      status: "completed",
      completed_count: 1,
      requeued_count: 0
    });
  });

  it("rejects failed records that try to suppress requeue", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/no-requeue.ts"
    });
    handleReviewQueueDrain(context, {
      run_id: "run-no-requeue",
      consumer: "worker-1",
      lease_seconds: 60
    });

    expect(() =>
      handleReviewRunRecord(context, {
        run_id: "run-no-requeue",
        status: "failed",
        requeue: false,
        findings: []
      })
    ).toThrow(/require requeue=true/);

    expect(readQueueRow("src/review/no-requeue.ts")).toMatchObject({
      queue_state: "leased",
      lease_owner: expect.any(String)
    });
    expect(readRunStatus("run-no-requeue")).toBe("started");
  });

  it("rejects repo-external symlink enqueue paths", () => {
    const outsideRoot = mkdtempSync(join(tmpdir(), "semantic-mcp-review-tool-outside-"));
    try {
      symlinkSync(outsideRoot, join(repoRoot, "outside-link"));

      expect(() =>
        handleReviewQueueEnqueue(context, {
          file_path: "outside-link/proof.ts",
          source: "hook"
        })
      ).toThrow(/file_path resolves through a symlinked path/);
    } finally {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  });

  it("rejects leading-dash enqueue path components at the tool boundary", () => {
    expect(() =>
      handleReviewQueueEnqueue(context, {
        file_path: "--pathspec-from-file=.claude/tmp/pathspec.txt",
        source: "hook"
      })
    ).toThrow(/file_path must not contain leading-dash components/);
  });

  it("fails closed when a stale run tries to overwrite a newer lease", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/stale.ts"
    });
    handleReviewQueueDrain(context, {
      run_id: "run-stale-1",
      consumer: "worker-1",
      lease_seconds: 60
    });

    context.db
      .prepare(
        `
          UPDATE review_queue_items
          SET lease_expires_at = '2000-01-01T00:00:00Z'
          WHERE project_id = ? AND file_path = ?
        `
      )
      .run(PROJECT_ID, "src/review/stale.ts");

    const secondDrain = handleReviewQueueDrain(context, {
      run_id: "run-stale-2",
      consumer: "worker-2",
      lease_seconds: 60
    });
    expect(secondDrain.leased_count).toBe(1);
    expect(readQueueRow("src/review/stale.ts")).toMatchObject({
      queue_state: "leased",
      lease_owner: expect.any(String),
      retry_count: 1
    });

    expect(() =>
      handleReviewRunRecord(context, {
        run_id: "run-stale-1",
        status: "completed",
        findings: []
      })
    ).toThrow(/lost queue lease ownership/);

    expect(readQueueRow("src/review/stale.ts")).toMatchObject({
      queue_state: "leased",
      lease_owner: expect.any(String)
    });
    expect(readRunStatus("run-stale-1")).toBe("started");
  });

  it("rejects completion when a run loses only part of its leased file set", () => {
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/partial-a.ts"
    });
    handleReviewQueueEnqueue(context, {
      file_path: "src/review/partial-b.ts"
    });

    const firstDrain = handleReviewQueueDrain(context, {
      run_id: "run-partial-1",
      consumer: "worker-1",
      limit: 2,
      lease_seconds: 60
    });
    expect(firstDrain.leased_count).toBe(2);

    context.db
      .prepare(
        `
          UPDATE review_queue_items
          SET lease_expires_at = '2000-01-01T00:00:00Z'
          WHERE project_id = ? AND file_path = ?
        `
      )
      .run(PROJECT_ID, "src/review/partial-a.ts");

    const secondDrain = handleReviewQueueDrain(context, {
      run_id: "run-partial-2",
      consumer: "worker-2",
      limit: 1,
      lease_seconds: 60
    });
    expect(secondDrain).toMatchObject({
      run_id: "run-partial-2",
      leased_count: 1,
      files: ["src/review/partial-a.ts"]
    });

    expect(() =>
      handleReviewRunRecord(context, {
        run_id: "run-partial-1",
        status: "completed",
        findings: []
      })
    ).toThrow(/lost queue lease ownership/);

    const rows = context.db
      .prepare(
        `
          SELECT file_path, queue_state, lease_run_id, lease_owner
          FROM review_queue_items
          WHERE project_id = ?
          ORDER BY file_path ASC
        `
      )
      .all(PROJECT_ID) as Array<{
      file_path: string;
      queue_state: string;
      lease_run_id: string | null;
      lease_owner: string | null;
    }>;

    expect(rows).toEqual([
      {
        file_path: "src/review/partial-a.ts",
        queue_state: "leased",
        lease_run_id: "run-partial-2",
        lease_owner: expect.any(String)
      },
      {
        file_path: "src/review/partial-b.ts",
        queue_state: "leased",
        lease_run_id: "run-partial-1",
        lease_owner: expect.any(String)
      }
    ]);
    expect(readRunStatus("run-partial-1")).toBe("started");
  });

  function readQueueRow(filePath: string): {
    event_id: string | null;
    queue_state: string;
    last_enqueued_at: string;
    lease_run_id: string | null;
    lease_event_id: string | null;
    lease_owner: string | null;
    retry_count: number;
    last_error: string | null;
  } {
    return context.db
      .prepare(
        `
          SELECT
            event_id,
            queue_state,
            last_enqueued_at,
            lease_run_id,
            lease_event_id,
            lease_owner,
            retry_count,
            last_error
          FROM review_queue_items
          WHERE project_id = ? AND file_path = ?
          LIMIT 1
        `
      )
      .get(PROJECT_ID, filePath) as {
      event_id: string | null;
      queue_state: string;
      last_enqueued_at: string;
      lease_run_id: string | null;
      lease_event_id: string | null;
      lease_owner: string | null;
      retry_count: number;
      last_error: string | null;
    };
  }

  function readRunStatus(runId: string): string {
    return (
      context.db
        .prepare(
          `
            SELECT status
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
            LIMIT 1
          `
        )
        .get(PROJECT_ID, runId) as { status: string }
    ).status;
  }
});
