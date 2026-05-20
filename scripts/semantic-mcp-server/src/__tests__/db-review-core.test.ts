import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, describe, expect, it } from "vitest";
import { runMigrations } from "../db/migrations.js";
import {
  completeReviewQueueLease,
  enqueueReviewQueueItem,
  exportReviewQueueJson,
  leaseReviewQueueItems
} from "../db/review-queue.js";
import { recordReviewRun, type ReviewRunRecordInput } from "../db/review-runs.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";

describe("db review core regressions", () => {
  const databases: BetterSqlite3Module.Database[] = [];
  const repoRoots: string[] = [];

  afterEach(() => {
    while (databases.length > 0) {
      databases.pop()?.close();
    }
    while (repoRoots.length > 0) {
      rmSync(repoRoots.pop() ?? "", { recursive: true, force: true });
    }
  });

  it("upgrades legacy review tables before creating indexes on new review columns", () => {
    const db = createRawDb(databases);
    db.exec(`
      CREATE TABLE review_queue_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        queue_state TEXT NOT NULL DEFAULT 'pending',
        first_enqueued_at TEXT NOT NULL,
        last_enqueued_at TEXT NOT NULL,
        last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
        payload TEXT NOT NULL DEFAULT '{}',
        lease_run_id TEXT,
        lease_owner TEXT,
        leased_at TEXT,
        lease_expires_at TEXT,
        completed_at TEXT,
        completed_run_id TEXT,
        last_error TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(project_id, file_path)
      );

      CREATE TABLE review_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'started',
        consumer TEXT,
        reviewer TEXT,
        file_count INTEGER NOT NULL DEFAULT 0,
        files_json TEXT NOT NULL DEFAULT '[]',
        findings_json TEXT NOT NULL DEFAULT '[]',
        summary TEXT,
        error_message TEXT,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        completed_at TEXT,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(project_id, run_id),
        CHECK(status IN ('started', 'completed', 'failed'))
      );
    `);

    expect(() => runMigrations(db)).not.toThrow();

    const queueColumns = listColumns(db, "review_queue_items");
    expect(queueColumns).toEqual(
      expect.arrayContaining([
        "event_id",
        "dedupe_key",
        "lease_event_id",
        "acknowledged_at",
        "retry_count"
      ])
    );

    const runColumns = listColumns(db, "review_runs");
    expect(runColumns).toEqual(
      expect.arrayContaining([
        "phase",
        "iteration",
        "kind",
        "result_summary",
        "blocker_summary",
        "report_body",
        "report_hash"
      ])
    );

    const indexNames = listIndexes(db, ["review_queue_items", "review_runs"]);
    expect(indexNames).toEqual(
      expect.arrayContaining([
        "idx_review_queue_items_project_event",
        "idx_review_queue_items_project_dedupe_active",
        "idx_review_runs_project_phase_kind"
      ])
    );
  });

  it("backfills legacy review_runs.result_summary from summary during migration", () => {
    const db = createRawDb(databases);
    db.exec(`
      CREATE TABLE review_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        summary TEXT
      );
    `);
    db.prepare(
      `
        INSERT INTO review_runs (project_id, run_id, summary)
        VALUES (?, ?, ?)
      `
    ).run(PROJECT_ID, "legacy-migration-run", "legacy summary");

    runMigrations(db);

    const row = db
      .prepare(
        `
          SELECT summary, result_summary
          FROM review_runs
          WHERE project_id = ? AND run_id = ?
        `
      )
      .get(PROJECT_ID, "legacy-migration-run") as {
      summary: string | null;
      result_summary: string | null;
    };

    expect(row).toEqual({
      summary: "legacy summary",
      result_summary: "legacy summary"
    });
  });

  it("marks a fully migrated schema current and fast-paths subsequent runs", () => {
    const db = createRawDb(databases);

    const first = runMigrations(db);
    const second = runMigrations(db);

    expect(first).toEqual({
      path: "full",
      schemaVersion: 1
    });
    expect(second).toEqual({
      path: "fast-path",
      schemaVersion: 1
    });
    expect(db.pragma("user_version", { simple: true })).toBe(1);
  });

  it("replays safe migrations when a current marker is present on a mismatched legacy schema", () => {
    const db = createRawDb(databases);
    db.exec(`
      CREATE TABLE review_queue_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        queue_state TEXT NOT NULL DEFAULT 'pending',
        first_enqueued_at TEXT NOT NULL,
        last_enqueued_at TEXT NOT NULL,
        last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
        payload TEXT NOT NULL DEFAULT '{}',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(project_id, file_path)
      );

      CREATE TABLE review_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        summary TEXT
      );
    `);
    db.pragma("user_version = 1");

    const result = runMigrations(db);

    expect(result).toEqual({
      path: "full",
      schemaVersion: 1
    });
    expect(listColumns(db, "review_queue_items")).toEqual(
      expect.arrayContaining(["event_id", "dedupe_key", "lease_event_id", "acknowledged_at", "retry_count"])
    );
    expect(listColumns(db, "review_runs")).toEqual(
      expect.arrayContaining(["phase", "result_summary", "report_body", "updated_at"])
    );
    expect(db.pragma("user_version", { simple: true })).toBe(1);
  });

  it("fails closed on a stamped schema with unrepaired registry_deltas structure", () => {
    const db = createRawDb(databases);
    expect(runMigrations(db)).toEqual({
      path: "full",
      schemaVersion: 1
    });

    rebuildRegistryDeltasWithoutAppliedAt(db);
    db.pragma("user_version = 1");

    expect(() => runMigrations(db)).toThrow(/durable schema validation failed/);
    expect(db.pragma("user_version", { simple: true })).toBe(0);
    expect(listColumns(db, "registry_deltas")).toEqual(
      expect.arrayContaining(["semantic_id", "applied_at"])
    );
  });

  it("repairs a stamped legacy review_runs table missing canonical constraints", () => {
    const db = createRawDb(databases);
    expect(runMigrations(db)).toEqual({
      path: "full",
      schemaVersion: 1
    });

    rebuildReviewRunsWithoutConstraints(db);
    db.pragma("user_version = 1");

    const first = runMigrations(db);
    const second = runMigrations(db);

    expect(first).toEqual({
      path: "full",
      schemaVersion: 1
    });
    expect(second).toEqual({
      path: "fast-path",
      schemaVersion: 1
    });
    expect(readTableSql(db, "review_runs")).toMatch(/UNIQUE\(project_id, run_id\)/);
    expect(readTableSql(db, "review_runs")).toMatch(/CHECK\(status IN \('started', 'completed', 'failed'\)\)/);
  });

  it("keeps a re-enqueue that arrives during an active lease pending after completion", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/core.ts",
      source: "hook"
    });
    const firstLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseSeconds: 60
    });

    const reenqueue = enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/core.ts",
      source: "hook"
    });
    expect(reenqueue).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/review/core.ts",
        queue_state: "leased"
      }
    });

    const completed = completeReviewQueueLease(db, {
      projectId: PROJECT_ID,
      leaseOwner: firstLease.lease_owner ?? ""
    });
    expect(completed).toMatchObject({
      project_id: PROJECT_ID,
      completed_count: 0,
      items: [
        {
          file_path: "src/review/core.ts",
          queue_state: "pending"
        }
      ]
    });

    const snapshot = exportReviewQueueJson(db, PROJECT_ID);
    expect(snapshot).toMatchObject({
      pending_count: 1,
      leased_count: 0,
      pending_review: true,
      changed_files: ["src/review/core.ts"]
    });

    const secondLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseSeconds: 60
    });
    expect(secondLease).toMatchObject({
      leased_count: 1,
      items: [
        {
          file_path: "src/review/core.ts",
          queue_state: "leased",
          retry_count: 0
        }
      ]
    });

    const secondComplete = completeReviewQueueLease(db, {
      projectId: PROJECT_ID,
      leaseOwner: secondLease.lease_owner ?? ""
    });
    expect(secondComplete.completed_count).toBe(1);
    expect(exportReviewQueueJson(db, PROJECT_ID).pending_review).toBe(false);
  });

  it("canonicalizes slash variants before queue dedupe and export", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    const first = enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/win.ts",
      source: "hook"
    });
    const second = enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "./src\\win.ts",
      source: "hook"
    });

    expect(first).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/win.ts",
        dedupe_key: "src/win.ts"
      }
    });
    expect(second).toMatchObject({
      queued: false,
      duplicate: true,
      item: {
        file_path: "src/win.ts",
        dedupe_key: "src/win.ts"
      }
    });

    expect(
      db
        .prepare("SELECT COUNT(*) AS count FROM review_queue_items WHERE project_id = ?")
        .get(PROJECT_ID)
    ).toEqual({ count: 1 });

    expect(exportReviewQueueJson(db, PROJECT_ID)).toMatchObject({
      changed_files: ["src/win.ts"],
      items: [
        {
          file_path: "src/win.ts",
          dedupe_key: "src/win.ts"
        }
      ]
    });
  });

  it("rejects absolute enqueue file paths", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    expect(() =>
      enqueueReviewQueueItem(db, {
        projectId: PROJECT_ID,
        repoRoot,
        filePath: resolve(repoRoot, "outside", "proof.txt"),
        source: "hook"
      })
    ).toThrow(/file_path must be repo-relative/);
  });

  it("rejects traversal enqueue file paths", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    expect(() =>
      enqueueReviewQueueItem(db, {
        projectId: PROJECT_ID,
        repoRoot,
        filePath: "../outside/proof.txt",
        source: "hook"
      })
    ).toThrow(/file_path must not contain traversal components/);
  });

  it("rejects leading-dash enqueue path components", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    expect(() =>
      enqueueReviewQueueItem(db, {
        projectId: PROJECT_ID,
        repoRoot,
        filePath: "--pathspec-from-file=.claude/tmp/pathspec.txt",
        source: "hook"
      })
    ).toThrow(/file_path must not contain leading-dash components/);
  });

  it("rejects repo-external symlink enqueue file paths", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);
    const outsideRoot = createRepoRoot(repoRoots);
    symlinkSync(outsideRoot, join(repoRoot, "outside-link"));

    expect(() =>
      enqueueReviewQueueItem(db, {
        projectId: PROJECT_ID,
        repoRoot,
        filePath: "outside-link/proof.txt",
        source: "hook"
      })
    ).toThrow(/file_path resolves through a symlinked path/);
  });

  it("persists canonical repo-relative enqueue file paths", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    const result = enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "./src\\valid.ts",
      source: "hook"
    });

    expect(result).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/valid.ts",
        dedupe_key: "src/valid.ts"
      }
    });
  });

  it("fails closed when a run loses only part of its leased file set", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/partial-a.ts",
      source: "hook"
    });
    enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/partial-b.ts",
      source: "hook"
    });

    const firstLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseRunId: "run-partial-1",
      leaseSeconds: 60
    });
    expect(firstLease.leased_count).toBe(2);

    db.prepare(
      `
        UPDATE review_queue_items
        SET lease_expires_at = '2000-01-01T00:00:00Z'
        WHERE project_id = ? AND file_path = ?
      `
    ).run(PROJECT_ID, "src/review/partial-a.ts");

    const secondLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseRunId: "run-partial-2",
      leaseSeconds: 60,
      limit: 1
    });
    expect(secondLease).toMatchObject({
      leased_count: 1,
      items: [{ file_path: "src/review/partial-a.ts", queue_state: "leased" }]
    });

    expect(() =>
      completeReviewQueueLease(db, {
        projectId: PROJECT_ID,
        leaseOwner: firstLease.lease_owner ?? "",
        leaseRunId: "run-partial-1",
        expectedFiles: ["src/review/partial-a.ts", "src/review/partial-b.ts"]
      })
    ).toThrow(/lost queue lease ownership/);

    const rows = db
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
        lease_owner: secondLease.lease_owner ?? null
      },
      {
        file_path: "src/review/partial-b.ts",
        queue_state: "leased",
        lease_run_id: "run-partial-1",
        lease_owner: firstLease.lease_owner ?? null
      }
    ]);
  });

  it("fails closed with expectedFiles alone when an unscoped lease loses part of its file set", () => {
    const db = createMigratedDb(databases);
    const repoRoot = createRepoRoot(repoRoots);

    enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/unscoped-a.ts",
      source: "hook"
    });
    enqueueReviewQueueItem(db, {
      projectId: PROJECT_ID,
      repoRoot,
      filePath: "src/review/unscoped-b.ts",
      source: "hook"
    });

    const firstLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseSeconds: 60
    });
    expect(firstLease.leased_count).toBe(2);

    db.prepare(
      `
        UPDATE review_queue_items
        SET lease_expires_at = '2000-01-01T00:00:00Z'
        WHERE project_id = ? AND file_path = ?
      `
    ).run(PROJECT_ID, "src/review/unscoped-a.ts");

    const secondLease = leaseReviewQueueItems(db, {
      projectId: PROJECT_ID,
      leaseSeconds: 60,
      limit: 1
    });
    expect(secondLease).toMatchObject({
      leased_count: 1,
      items: [{ file_path: "src/review/unscoped-a.ts", queue_state: "leased" }]
    });

    expect(() =>
      completeReviewQueueLease(db, {
        projectId: PROJECT_ID,
        leaseOwner: firstLease.lease_owner ?? "",
        expectedFiles: ["src/review/unscoped-a.ts", "src/review/unscoped-b.ts"]
      })
    ).toThrow(/lost queue lease ownership/);
  });

  it("allows only truly idempotent duplicate review-run writes", () => {
    const db = createMigratedDb(databases);

    const input: ReviewRunRecordInput = {
      run_id: "run-001",
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      queued_files: ["src/review/core.ts"],
      summary: "all clear",
      blocker_summary: "none",
      report_body: "clean run",
      findings: [{ severity: "low", message: "nit" }],
      consumer: "auto_orchestrate",
      reviewer: "codex",
      metadata: { source: "test" }
    };

    const first = recordReviewRun(db, PROJECT_ID, input);
    const second = recordReviewRun(db, PROJECT_ID, input);
    expect(second).toEqual(first);

    expect(() =>
      recordReviewRun(db, PROJECT_ID, {
        ...input,
        blocker_summary: "changed"
      })
    ).toThrow(/run_id already exists with different payload/);
  });

  it("accepts reordered JSON keys on idempotent replay", () => {
    const db = createMigratedDb(databases);

    recordReviewRun(db, PROJECT_ID, {
      run_id: "run-json-order-node",
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      queued_files: ["src/review/json-order.ts"],
      summary: "stable json",
      report_body: "stable body",
      findings: [
        {
          severity: "low",
          details: {
            z: 2,
            a: 1
          }
        }
      ],
      metadata: {
        nested: {
          z: true,
          a: false
        },
        b: 2,
        a: 1
      }
    });

    const replay = recordReviewRun(db, PROJECT_ID, {
      run_id: "run-json-order-node",
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      queued_files: ["src/review/json-order.ts"],
      summary: "stable json",
      report_body: "stable body",
      findings: [
        {
          details: {
            a: 1,
            z: 2
          },
          severity: "low"
        }
      ],
      metadata: {
        a: 1,
        nested: {
          a: false,
          z: true
        },
        b: 2
      }
    });

    expect(replay.run_id).toBe("run-json-order-node");

    const stored = db
      .prepare(
        `
          SELECT findings_json, metadata_json
          FROM review_runs
          WHERE project_id = ? AND run_id = ?
        `
      )
      .get(PROJECT_ID, "run-json-order-node") as {
      findings_json: string;
      metadata_json: string;
    };

    expect(stored.findings_json).toBe(
      stableStringify([
        {
          severity: "low",
          details: {
            z: 2,
            a: 1
          }
        }
      ])
    );
    expect(stored.metadata_json).toBe(
      stableStringify({
        nested: {
          z: true,
          a: false
        },
        b: 2,
        a: 1
      })
    );
  });

  it("accepts legacy summary-only rows and upgrades them on replay", () => {
    const db = createRawDb(databases);
    db.exec(`
      CREATE TABLE review_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        summary TEXT
      );
    `);
    db.prepare(
      `
        INSERT INTO review_runs (project_id, run_id, summary)
        VALUES (?, ?, ?)
      `
    ).run(PROJECT_ID, "legacy-run-node", "legacy summary");

    runMigrations(db);

    const payload: ReviewRunRecordInput = {
      run_id: "legacy-run-node",
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      queued_files: ["src/legacy.ts"],
      summary: "legacy summary",
      report_body: "legacy body",
      findings: [],
      metadata: {}
    };

    const first = recordReviewRun(db, PROJECT_ID, payload);
    const replay = recordReviewRun(db, PROJECT_ID, payload);

    expect(first.run_id).toBe("legacy-run-node");
    expect(replay.report_hash).toBe(first.report_hash);

    const row = db
      .prepare(
        `
          SELECT
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
          WHERE project_id = ? AND run_id = ?
        `
      )
      .get(PROJECT_ID, "legacy-run-node") as {
      phase: string | null;
      iteration: number | null;
      kind: string | null;
      status: string;
      summary: string | null;
      result_summary: string | null;
      file_count: number;
      files_json: string;
      findings_json: string;
      report_body: string | null;
      report_hash: string | null;
      metadata_json: string;
    };

    expect(row).toEqual({
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      summary: null,
      result_summary: "legacy summary",
      file_count: 1,
      files_json: "[\"src/legacy.ts\"]",
      findings_json: "[]",
      report_body: "legacy body",
      report_hash: first.report_hash,
      metadata_json: "{}"
    });
  });

  it("rejects mismatched report_body and report_hash", () => {
    const db = createMigratedDb(databases);

    expect(() =>
      recordReviewRun(db, PROJECT_ID, {
        run_id: "run-report-mismatch-node",
        phase: "review",
        iteration: 1,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/core.ts"],
        report_body: "verified body",
        report_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    ).toThrow(/report_hash must match the sha256 of report_body/);
  });
});

function createRawDb(databases: BetterSqlite3Module.Database[]): BetterSqlite3Module.Database {
  const db = new BetterSqlite3(":memory:");
  databases.push(db);
  return db;
}

function createMigratedDb(databases: BetterSqlite3Module.Database[]): BetterSqlite3Module.Database {
  const db = createRawDb(databases);
  runMigrations(db);
  return db;
}

function createRepoRoot(repoRoots: string[]): string {
  const repoRoot = mkdtempSync(join(tmpdir(), "semantic-mcp-db-review-root-"));
  repoRoots.push(repoRoot);
  return repoRoot;
}

function rebuildRegistryDeltasWithoutAppliedAt(db: BetterSqlite3Module.Database): void {
  db.exec(`
    ALTER TABLE registry_deltas RENAME TO registry_deltas_old;
    CREATE TABLE registry_deltas (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      delta_type TEXT NOT NULL,
      semantic_id TEXT,
      payload TEXT NOT NULL,
      UNIQUE(project_id, idempotency_key)
    );
    INSERT INTO registry_deltas (id, project_id, idempotency_key, delta_type, semantic_id, payload)
    SELECT id, project_id, idempotency_key, delta_type, semantic_id, payload
    FROM registry_deltas_old;
    DROP TABLE registry_deltas_old;
  `);
}

function rebuildReviewRunsWithoutConstraints(db: BetterSqlite3Module.Database): void {
  db.exec(`
    ALTER TABLE review_runs RENAME TO review_runs_old;
    CREATE TABLE review_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id TEXT NOT NULL,
      run_id TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'started',
      phase TEXT,
      iteration INTEGER,
      kind TEXT,
      consumer TEXT,
      reviewer TEXT,
      file_count INTEGER NOT NULL DEFAULT 0,
      files_json TEXT NOT NULL DEFAULT '[]',
      findings_json TEXT NOT NULL DEFAULT '[]',
      summary TEXT,
      result_summary TEXT,
      blocker_summary TEXT,
      report_body TEXT,
      report_hash TEXT,
      error_message TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      completed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    INSERT INTO review_runs (
      id, project_id, run_id, status, phase, iteration, kind, consumer, reviewer, file_count,
      files_json, findings_json, summary, result_summary, blocker_summary, report_body, report_hash,
      error_message, metadata_json, started_at, completed_at, created_at, updated_at
    )
    SELECT
      id, project_id, run_id, status, phase, iteration, kind, consumer, reviewer, file_count,
      files_json, findings_json, summary, result_summary, blocker_summary, report_body, report_hash,
      error_message, metadata_json, started_at, completed_at, created_at, updated_at
    FROM review_runs_old;
    DROP TABLE review_runs_old;
  `);
}

function readTableSql(db: BetterSqlite3Module.Database, tableName: string): string {
  const row = db
    .prepare(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`)
    .get(tableName) as { sql: string };
  return row.sql;
}

function listColumns(db: BetterSqlite3Module.Database, tableName: string): string[] {
  return db
    .prepare(`PRAGMA table_info(${tableName})`)
    .all()
    .map((row) => (row as { name: string }).name);
}

function stableStringify(value: unknown): string {
  return JSON.stringify(normalizeJsonValue(value));
}

function normalizeJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => normalizeJsonValue(item));
  }

  if (isRecord(value)) {
    const normalized: Record<string, unknown> = {};
    const entries = Object.entries(value).filter(([, entryValue]) => entryValue !== undefined);
    entries.sort(([left], [right]) => left.localeCompare(right));
    for (const [key, entryValue] of entries) {
      normalized[key] = normalizeJsonValue(entryValue);
    }
    return normalized;
  }

  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function listIndexes(
  db: BetterSqlite3Module.Database,
  tableNames: string[]
): string[] {
  const placeholders = tableNames.map(() => "?").join(", ");
  return db
    .prepare(
      `
        SELECT name
        FROM sqlite_master
        WHERE type = 'index' AND tbl_name IN (${placeholders})
        ORDER BY name
      `
    )
    .all(...tableNames)
    .map((row) => (row as { name: string }).name);
}
