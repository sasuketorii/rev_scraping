import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { runCli, type CliDependencies } from "../cli.js";
import { runMigrations } from "../db/migrations.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";

describe("semantic cli", () => {
  let harness: CliHarness;

  beforeEach(() => {
    harness = createCliHarness();
  });

  afterEach(() => {
    harness.cleanup();
  });

  it("project-id validate rejects the legacy agent_base literal", () => {
    expect(() =>
      harness.exec(["project-id", "validate", "--value", "agent_base"])
    ).toThrow(/project_id literal 'agent_base' is forbidden/);
  });

  it("project-id validate trims surrounding whitespace", () => {
    expect(
      harness.exec(["project-id", "validate", "--value", " demo "])
    ).toEqual({
      ok: true,
      project_id: "demo"
    });
  });

  it("queue enqueue dedupes by file_path", () => {
    const first = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/a.ts",
      "--source",
      "hook"
    ]);

    expect(first).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        dedupe_key: "src/review/a.ts",
        file_path: "src/review/a.ts",
        source: "hook",
        queue_state: "pending",
        retry_count: 0
      }
    });

    const second = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/a.ts",
      "--source",
      "hook"
    ]);

    expect(second).toMatchObject({
      queued: false,
      duplicate: true,
      item: {
        file_path: "src/review/a.ts",
        queue_state: "pending",
        retry_count: 0
      }
    });

    expect(countQueueRows(harness)).toBe(1);
  });

  it("queue enqueue canonicalizes slash variants before dedupe and export", () => {
    const first = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/win.ts",
      "--source",
      "hook"
    ]);

    expect(first).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        dedupe_key: "src/win.ts",
        file_path: "src/win.ts",
        source: "hook"
      }
    });

    const second = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "./src\\win.ts",
      "--source",
      "hook"
    ]);

    expect(second).toMatchObject({
      queued: false,
      duplicate: true,
      item: {
        dedupe_key: "src/win.ts",
        file_path: "src/win.ts",
        source: "hook"
      }
    });

    const exportedPath = join(harness.tempDir, "snapshots", "queue-canonicalized.json");
    const exportResponse = harness.exec([
      "queue",
      "export-json",
      "--project-id",
      PROJECT_ID,
      "--output",
      exportedPath
    ]);

    expect(exportResponse).toEqual({
      project_id: PROJECT_ID,
      output: resolve(exportedPath),
      pending_count: 1,
      leased_count: 0
    });

    const exported = JSON.parse(readFileSync(exportedPath, "utf8")) as {
      changed_files: string[];
      items: Array<{
        file_path: string;
        dedupe_key: string;
      }>;
    };

    expect(exported.changed_files).toEqual(["src/win.ts"]);
    expect(exported.items).toHaveLength(1);
    expect(exported.items[0]).toMatchObject({
      file_path: "src/win.ts",
      dedupe_key: "src/win.ts"
    });
    expect(countQueueRows(harness)).toBe(1);
  });

  it("queue enqueue can export the authoritative snapshot without reopening the backend", () => {
    const exportedPath = join(harness.tempDir, "snapshots", "queue-after-enqueue.json");
    const countsBefore = harness.databaseCallCounts();

    const result = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "./src\\single-call.ts",
      "--source",
      "hook",
      "--export-json",
      exportedPath
    ]);

    const countsAfter = harness.databaseCallCounts();

    expect(result).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/single-call.ts",
        dedupe_key: "src/single-call.ts",
        source: "hook",
        queue_state: "pending"
      }
    });
    expect(countsAfter).toEqual({
      open: countsBefore.open + 1,
      close: countsBefore.close + 1
    });

    const exported = JSON.parse(readFileSync(exportedPath, "utf8")) as {
      pending_count: number;
      leased_count: number;
      pending_review: boolean;
      changed_files: string[];
      items: Array<{
        file_path: string;
        dedupe_key: string;
        source: string;
        queue_state: string;
      }>;
    };

    expect(exported).toMatchObject({
      pending_count: 1,
      leased_count: 0,
      pending_review: true,
      changed_files: ["src/single-call.ts"],
      items: [
        {
          file_path: "src/single-call.ts",
          dedupe_key: "src/single-call.ts",
          source: "hook",
          queue_state: "pending"
        }
      ]
    });
  });

  it("queue enqueue rejects absolute file paths", () => {
    expect(() =>
      harness.exec([
        "queue",
        "enqueue",
        "--project-id",
        PROJECT_ID,
        "--file-path",
        resolve(harness.tempDir, "outside", "proof.txt")
      ])
    ).toThrow(/file_path must be repo-relative/);

    expect(countQueueRows(harness)).toBe(0);
  });

  it("queue enqueue rejects traversal file paths", () => {
    expect(() =>
      harness.exec([
        "queue",
        "enqueue",
        "--project-id",
        PROJECT_ID,
        "--file-path",
        "../outside/proof.txt"
      ])
    ).toThrow(/file_path must not contain traversal components/);

    expect(countQueueRows(harness)).toBe(0);
  });

  it("queue enqueue rejects repo-external symlink paths", () => {
    const outsideDir = mkdtempSync(join(tmpdir(), "semantic-mcp-cli-outside-"));
    try {
      symlinkSync(outsideDir, join(harness.tempDir, "outside-link"));

      expect(() =>
        harness.exec([
          "queue",
          "enqueue",
          "--project-id",
          PROJECT_ID,
          "--file-path",
          "outside-link/proof.txt"
        ])
      ).toThrow(/file_path resolves through a symlinked path/);

      expect(countQueueRows(harness)).toBe(0);
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
    }
  });

  it("queue enqueue persists canonical repo-relative file paths", () => {
    const result = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "./src\\valid.ts"
    ]);

    expect(result).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/valid.ts",
        dedupe_key: "src/valid.ts"
      }
    });
    expect(countQueueRows(harness)).toBe(1);
  });

  it("queue lease marks rows leased without acknowledging them", () => {
    enqueueTwoFiles(harness);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);

    expect(leased).toMatchObject({
      project_id: PROJECT_ID,
      lease_run_id: null,
      leased_count: 2,
      expected_files: ["src/review/a.ts", "src/review/b.ts"],
      items: [
        { file_path: "src/review/a.ts", queue_state: "leased", retry_count: 0 },
        { file_path: "src/review/b.ts", queue_state: "leased", retry_count: 0 }
      ]
    });
    expect(typeof leased.lease_owner).toBe("string");
    expect(leased.lease_owner.length).toBeGreaterThan(0);
    expect(leased.lease_expires_at).toEqual(expect.any(String));

    const db = harness.openReadOnlyDb();
    try {
      const rows = db
        .prepare(
          `
            SELECT file_path, queue_state, lease_owner, leased_at, lease_expires_at, acknowledged_at, completed_at, retry_count
            FROM review_queue_items
            WHERE project_id = ?
            ORDER BY file_path ASC
          `
        )
        .all(PROJECT_ID) as Array<{
        file_path: string;
        queue_state: string;
        lease_owner: string;
        leased_at: string;
        lease_expires_at: string;
        acknowledged_at: string | null;
        completed_at: string | null;
        retry_count: number;
      }>;

      expect(rows).toEqual([
        {
          file_path: "src/review/a.ts",
          queue_state: "leased",
          lease_owner: leased.lease_owner,
          leased_at: leased.leased_at,
          lease_expires_at: leased.lease_expires_at,
          acknowledged_at: null,
          completed_at: null,
          retry_count: 0
        },
        {
          file_path: "src/review/b.ts",
          queue_state: "leased",
          lease_owner: leased.lease_owner,
          leased_at: leased.leased_at,
          lease_expires_at: leased.lease_expires_at,
          acknowledged_at: null,
          completed_at: null,
          retry_count: 0
        }
      ]);
    } finally {
      db.close();
    }
  });

  it("queue lease rejects trailing junk in --lease-seconds fail-closed", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/strict-integer.ts"
    ]);

    expect(() =>
      harness.exec([
        "queue",
        "lease",
        "--project-id",
        PROJECT_ID,
        "--lease-seconds",
        "60junk"
      ])
    ).toThrow(/--lease-seconds must be an integer/);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID
    ]);

    expect(leased).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 1,
      items: [{ file_path: "src/review/strict-integer.ts", queue_state: "leased" }]
    });
  });

  it("queue complete acknowledges work only after explicit success", () => {
    enqueueTwoFiles(harness);
    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-run-id",
      "cli-complete-1"
    ]);

    const completed = harness.exec(
      appendExpectedFiles(
        [
          "queue",
          "complete",
          "--project-id",
          PROJECT_ID,
          "--lease-owner",
          leased.lease_owner,
          "--lease-run-id",
          "cli-complete-1"
        ],
        leased.expected_files
      )
    );

    expect(completed).toMatchObject({
      project_id: PROJECT_ID,
      lease_owner: leased.lease_owner,
      completed_count: 2,
      items: [
        { file_path: "src/review/a.ts", queue_state: "done" },
        { file_path: "src/review/b.ts", queue_state: "done" }
      ]
    });

    const leasedAgain = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID
    ]);
    expect(leasedAgain).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 0,
      items: []
    });

    const db = harness.openReadOnlyDb();
    try {
      const rows = db
        .prepare(
          `
            SELECT file_path, queue_state, lease_owner, acknowledged_at, completed_at, retry_count
            FROM review_queue_items
            WHERE project_id = ?
            ORDER BY file_path ASC
          `
        )
        .all(PROJECT_ID) as Array<{
        file_path: string;
        queue_state: string;
        lease_owner: string;
        acknowledged_at: string;
        completed_at: string;
        retry_count: number;
      }>;

      expect(rows).toEqual([
        {
          file_path: "src/review/a.ts",
          queue_state: "done",
          lease_owner: leased.lease_owner,
          acknowledged_at: completed.completed_at,
          completed_at: completed.completed_at,
          retry_count: 0
        },
        {
          file_path: "src/review/b.ts",
          queue_state: "done",
          lease_owner: leased.lease_owner,
          acknowledged_at: completed.completed_at,
          completed_at: completed.completed_at,
          retry_count: 0
        }
      ]);
    } finally {
      db.close();
    }
  });

  it("queue requeue returns leased work to pending and increments retry count", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/retry.ts"
    ]);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-run-id",
      "cli-requeue-1"
    ]);
    const requeued = harness.exec(
      appendExpectedFiles(
        [
          "queue",
          "requeue",
          "--project-id",
          PROJECT_ID,
          "--lease-owner",
          leased.lease_owner,
          "--lease-run-id",
          "cli-requeue-1",
          "--error",
          "transient failure"
        ],
        leased.expected_files
      )
    );

    expect(requeued).toMatchObject({
      project_id: PROJECT_ID,
      lease_owner: leased.lease_owner,
      requeued_count: 1,
      items: [
        {
          file_path: "src/review/retry.ts",
          queue_state: "pending",
          retry_count: 1,
          last_error: "transient failure"
        }
      ]
    });

    const exportedPath = join(harness.tempDir, "snapshots", "queue.json");
    const exportResponse = harness.exec([
      "queue",
      "export-json",
      "--project-id",
      PROJECT_ID,
      "--output",
      exportedPath
    ]);

    expect(exportResponse).toEqual({
      project_id: PROJECT_ID,
      output: resolve(exportedPath),
      pending_count: 1,
      leased_count: 0
    });

    const exported = JSON.parse(readFileSync(exportedPath, "utf8")) as {
      pending_count: number;
      leased_count: number;
      pending_review: boolean;
      changed_files: string[];
      items: Array<Record<string, unknown>>;
    };

    expect(exported.pending_count).toBe(1);
    expect(exported.leased_count).toBe(0);
    expect(exported.pending_review).toBe(true);
    expect(exported.changed_files).toEqual(["src/review/retry.ts"]);
    expect(exported.items[0]).toMatchObject({
      file_path: "src/review/retry.ts",
      queue_state: "pending",
      retry_count: 1,
      last_error: "transient failure"
    });
  });

  it("queue lease reclaims expired leases instead of dropping work after a crash", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/recover.ts"
    ]);

    const firstLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);

    const db = harness.openWritableDb();
    try {
      db.prepare(
        `
          UPDATE review_queue_items
          SET lease_expires_at = '2000-01-01T00:00:00Z'
          WHERE project_id = ? AND lease_owner = ?
        `
      ).run(PROJECT_ID, firstLease.lease_owner);
    } finally {
      db.close();
    }

    const secondLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);

    expect(secondLease).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 1,
      items: [
        {
          file_path: "src/review/recover.ts",
          queue_state: "leased",
          retry_count: 1
        }
      ]
    });
    expect(secondLease.lease_owner).not.toBe(firstLease.lease_owner);
  });

  it("queue drain remains a backward-compatible alias for queue lease", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/alias.ts"
    ]);

    const leased = harness.exec([
      "queue",
      "drain",
      "--project-id",
      PROJECT_ID
    ]);

    expect(leased).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 1,
      items: [
        {
          file_path: "src/review/alias.ts",
          queue_state: "leased",
          acknowledged_at: null
        }
      ]
    });
  });

  it("queue complete keeps a file pending when it changes during an active lease", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/release-after-change.ts",
      "--source",
      "hook"
    ]);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);
    const reenqueued = harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/release-after-change.ts",
      "--source",
      "hook"
    ]);

    expect(reenqueued).toMatchObject({
      queued: true,
      duplicate: false,
      item: {
        file_path: "src/review/release-after-change.ts",
        queue_state: "leased",
        lease_owner: leased.lease_owner
      }
    });

    const completed = harness.exec(
      appendExpectedFiles(
        [
          "queue",
          "complete",
          "--project-id",
          PROJECT_ID,
          "--lease-owner",
          leased.lease_owner
        ],
        leased.expected_files
      )
    );

    expect(completed).toMatchObject({
      project_id: PROJECT_ID,
      lease_owner: leased.lease_owner,
      completed_count: 0,
      items: [
        {
          file_path: "src/review/release-after-change.ts",
          queue_state: "pending",
          acknowledged_at: null
        }
      ]
    });

    const leasedAgain = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);

    expect(leasedAgain).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 1,
      items: [
        {
          file_path: "src/review/release-after-change.ts",
          queue_state: "leased",
          retry_count: 0
        }
      ]
    });
    expect(leasedAgain.lease_owner).not.toBe(leased.lease_owner);
  });

  it("queue complete rejects non-strict finalization without expected files", () => {
    harness.exec([
      "queue",
      "enqueue",
      "--project-id",
      PROJECT_ID,
      "--file-path",
      "src/review/strict-required.ts"
    ]);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID
    ]);

    expect(() =>
      harness.exec([
        "queue",
        "complete",
        "--project-id",
        PROJECT_ID,
        "--lease-owner",
        leased.lease_owner
      ])
    ).toThrow(/queue complete requires strict expected files/);
  });

  it("queue complete fails closed when a CLI lease loses only part of its files", () => {
    enqueueTwoFiles(harness);

    const firstLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);
    expect(firstLease.expected_files).toEqual(["src/review/a.ts", "src/review/b.ts"]);

    const db = harness.openWritableDb();
    try {
      db.prepare(
        `
          UPDATE review_queue_items
          SET lease_expires_at = '2000-01-01T00:00:00Z'
          WHERE project_id = ? AND file_path = ?
        `
      ).run(PROJECT_ID, "src/review/a.ts");
    } finally {
      db.close();
    }

    const secondLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);
    expect(secondLease).toMatchObject({
      leased_count: 1,
      expected_files: ["src/review/a.ts"],
      items: [{ file_path: "src/review/a.ts", queue_state: "leased" }]
    });

    expect(() =>
      harness.exec(
        appendExpectedFiles([
          "queue",
          "complete",
          "--project-id",
          PROJECT_ID,
          "--lease-owner",
          firstLease.lease_owner
        ], firstLease.expected_files)
      )
    ).toThrow(/lost queue lease ownership/);
  });

  it("queue requeue fails closed when a run-scoped CLI lease loses only part of its files", () => {
    enqueueTwoFiles(harness);

    const firstLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-run-id",
      "cli-partial-1",
      "--lease-seconds",
      "60"
    ]);

    const db = harness.openWritableDb();
    try {
      db.prepare(
        `
          UPDATE review_queue_items
          SET lease_expires_at = '2000-01-01T00:00:00Z'
          WHERE project_id = ? AND file_path = ?
        `
      ).run(PROJECT_ID, "src/review/a.ts");
    } finally {
      db.close();
    }

    const secondLease = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-run-id",
      "cli-partial-2",
      "--lease-seconds",
      "60"
    ]);
    expect(secondLease).toMatchObject({
      leased_count: 1,
      lease_run_id: "cli-partial-2",
      expected_files: ["src/review/a.ts"],
      items: [{ file_path: "src/review/a.ts", queue_state: "leased" }]
    });

    expect(() =>
      harness.exec(
        appendExpectedFiles([
          "queue",
          "requeue",
          "--project-id",
          PROJECT_ID,
          "--lease-owner",
          firstLease.lease_owner,
          "--lease-run-id",
          "cli-partial-1",
          "--error",
          "stale lease"
        ], firstLease.expected_files)
      )
    ).toThrow(/lost queue lease ownership.*cli-partial-1/);
  });

  it("runMigrations upgrades legacy review tables before creating review indexes", () => {
    const db = harness.openWritableDb();
    try {
      createLegacyReviewSchema(db);
      db.prepare(
        `
          INSERT INTO review_queue_items (
            project_id,
            file_path,
            queue_state,
            first_enqueued_at,
            last_enqueued_at,
            last_enqueue_source,
            payload,
            attempt_count
          )
          VALUES (?, ?, 'pending', ?, ?, ?, '{}', 0)
        `
      ).run(
        PROJECT_ID,
        "src/review/legacy.ts",
        "2026-04-01T00:00:00Z",
        "2026-04-01T00:00:00Z",
        "legacy"
      );

      expect(() => runMigrations(db)).not.toThrow();

      expect(listTableColumns(db, "registry_deltas")).toEqual(
        expect.arrayContaining(["semantic_id"])
      );
      expect(listTableColumns(db, "review_queue_items")).toEqual(
        expect.arrayContaining([
          "event_id",
          "dedupe_key",
          "lease_event_id",
          "acknowledged_at",
          "retry_count"
        ])
      );
      expect(listTableColumns(db, "review_runs")).toEqual(
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

      const indexes = db
        .prepare(
          `
            SELECT name
            FROM sqlite_master
            WHERE type = 'index' AND name IN (
              'idx_review_queue_items_project_event',
              'idx_review_queue_items_project_dedupe_active',
              'idx_review_runs_project_updated',
              'idx_review_runs_project_phase_kind'
            )
            ORDER BY name ASC
          `
        )
        .all() as Array<{ name: string }>;
      const queueRow = db
        .prepare(
          `
            SELECT dedupe_key, retry_count
            FROM review_queue_items
            WHERE project_id = ? AND file_path = ?
          `
        )
        .get(PROJECT_ID, "src/review/legacy.ts") as {
        dedupe_key: string;
        retry_count: number;
      };

      expect(indexes).toEqual([
        { name: "idx_review_queue_items_project_dedupe_active" },
        { name: "idx_review_queue_items_project_event" },
        { name: "idx_review_runs_project_phase_kind" },
        { name: "idx_review_runs_project_updated" }
      ]);
      expect(queueRow).toEqual({
        dedupe_key: "src/review/legacy.ts",
        retry_count: 0
      });
    } finally {
      db.close();
    }
  });

  it("review-run record keeps summary distinct from blocker_summary", () => {
    const inputPath = join(harness.tempDir, "review-run.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-001",
        phase: "review",
        iteration: 2,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/a.ts", "src/review/b.ts"],
        summary: "2 files reviewed",
        blocker_summary: "none",
        report_body: "all clear",
        findings: [{ severity: "low", message: "nit" }],
        consumer: "auto_orchestrate",
        reviewer: "codex",
        metadata: { source: "test" }
      }),
      "utf8"
    );

    const response = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    expect(response).toMatchObject({
      project_id: PROJECT_ID,
      run_id: "run-001",
      phase: "review",
      iteration: 2,
      kind: "batch",
      status: "completed",
      queued_file_count: 2
    });
    expect(response.report_hash).toMatch(/^[a-f0-9]{64}$/);

    const db = harness.openReadOnlyDb();
    try {
      const row = db
        .prepare(
          `
            SELECT
              phase,
              iteration,
              kind,
              status,
              file_count,
              files_json,
              findings_json,
              summary,
              result_summary,
              blocker_summary,
              report_body,
              report_hash
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "run-001") as {
        phase: string;
        iteration: number;
        kind: string;
        status: string;
        file_count: number;
        files_json: string;
        findings_json: string;
        summary: string | null;
        result_summary: string;
        blocker_summary: string;
        report_body: string;
        report_hash: string;
      };

      expect(row).toMatchObject({
        phase: "review",
        iteration: 2,
        kind: "batch",
        status: "completed",
        file_count: 2,
        summary: null,
        result_summary: "2 files reviewed",
        blocker_summary: "none",
        report_body: "all clear",
        report_hash: response.report_hash
      });
      expect(JSON.parse(row.files_json)).toEqual(["src/review/a.ts", "src/review/b.ts"]);
      expect(JSON.parse(row.findings_json)).toEqual([{ severity: "low", message: "nit" }]);
    } finally {
      db.close();
    }
  });

  it("review-run record accepts legacy nested input payloads", () => {
    const inputPath = join(harness.tempDir, "review-run-nested.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        input: {
          run_id: "run-nested-cli",
          phase: "review",
          iteration: 3,
          kind: "batch",
          status: "completed",
          queued_files: ["src/review/nested-cli.ts"],
          summary: "nested payload",
          blocker_summary: "none",
          report_body: "ok",
          findings: [],
          metadata: { source: "legacy" }
        }
      }),
      "utf8"
    );

    const response = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    expect(response).toMatchObject({
      project_id: PROJECT_ID,
      run_id: "run-nested-cli",
      phase: "review",
      iteration: 3,
      kind: "batch",
      status: "completed",
      queued_file_count: 1
    });
  });

  it("review-run record accepts reordered JSON keys on replay", () => {
    const inputPath = join(harness.tempDir, "review-run-json-order.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-json-order-cli",
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
      }),
      "utf8"
    );

    harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-json-order-cli",
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
      }),
      "utf8"
    );

    const replay = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    expect(replay).toMatchObject({
      project_id: PROJECT_ID,
      run_id: "run-json-order-cli",
      status: "completed"
    });

    const db = harness.openReadOnlyDb();
    try {
      const row = db
        .prepare(
          `
            SELECT findings_json, metadata_json
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "run-json-order-cli") as {
        findings_json: string;
        metadata_json: string;
      };

      expect(row.findings_json).toBe('[{"details":{"a":1,"z":2},"severity":"low"}]');
      expect(row.metadata_json).toBe('{"a":1,"b":2,"nested":{"a":false,"z":true}}');
    } finally {
      db.close();
    }
  });

  it("review-run record upgrades legacy summary-only rows on replay", () => {
    const db = harness.openWritableDb();
    try {
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
      ).run(PROJECT_ID, "legacy-run-cli", "legacy summary");
    } finally {
      db.close();
    }

    const inputPath = join(harness.tempDir, "review-run-legacy-summary.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "legacy-run-cli",
        phase: "review",
        iteration: 1,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/legacy-summary.ts"],
        summary: "legacy summary",
        report_body: "legacy body",
        findings: [],
        metadata: {}
      }),
      "utf8"
    );

    const first = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);
    const replay = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    expect(first).toMatchObject({
      project_id: PROJECT_ID,
      run_id: "legacy-run-cli",
      status: "completed"
    });
    expect(replay.report_hash).toBe(first.report_hash);

    const readDb = harness.openReadOnlyDb();
    try {
      const row = readDb
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
        .get(PROJECT_ID, "legacy-run-cli") as {
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
        files_json: "[\"src/review/legacy-summary.ts\"]",
        findings_json: "[]",
        report_body: "legacy body",
        report_hash: first.report_hash,
        metadata_json: "{}"
      });
    } finally {
      readDb.close();
    }
  });

  it("migrations backfill legacy review_runs.result_summary before unrelated CLI work", () => {
    const db = harness.openWritableDb();
    try {
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
      ).run(PROJECT_ID, "legacy-backfill-cli", "legacy summary");
    } finally {
      db.close();
    }

    const exportedPath = join(harness.tempDir, "review-runs-backfill.json");
    harness.exec([
      "queue",
      "export-json",
      "--project-id",
      PROJECT_ID,
      "--output",
      exportedPath
    ]);

    const readDb = harness.openReadOnlyDb();
    try {
      const row = readDb
        .prepare(
          `
            SELECT summary, result_summary
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "legacy-backfill-cli") as {
        summary: string | null;
        result_summary: string | null;
      };

      expect(row).toEqual({
        summary: "legacy summary",
        result_summary: "legacy summary"
      });
    } finally {
      readDb.close();
    }
  });

  it("review-run record rejects mismatched report_body and report_hash", () => {
    const inputPath = join(harness.tempDir, "review-run-mismatch.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-mismatch-cli",
        phase: "review",
        iteration: 3,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/mismatch.ts"],
        report_body: "verified body",
        report_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }),
      "utf8"
    );

    expect(() =>
      harness.exec([
        "review-run",
        "record",
        "--project-id",
        PROJECT_ID,
        "--input",
        inputPath
      ])
    ).toThrow(/report_hash must match the sha256 of report_body/);
  });

  it("review-run record does not backfill result_summary from blocker_summary", () => {
    const inputPath = join(harness.tempDir, "review-run-blocker-only.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-002",
        phase: "review",
        iteration: 3,
        kind: "batch",
        status: "failed",
        queued_files: ["src/review/c.ts"],
        blocker_summary: "needs follow-up",
        report_body: "blocked"
      }),
      "utf8"
    );

    harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    const db = harness.openReadOnlyDb();
    try {
      const row = db
        .prepare(
          `
            SELECT summary, result_summary, blocker_summary
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "run-002") as {
        summary: string | null;
        result_summary: string | null;
        blocker_summary: string | null;
      };

      expect(row).toEqual({
        summary: null,
        result_summary: null,
        blocker_summary: "needs follow-up"
      });
    } finally {
      db.close();
    }
  });

  it("review-run record rejects conflicting reuse of a finalized run_id", () => {
    const inputPath = join(harness.tempDir, "review-run-conflict.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-003",
        phase: "review",
        iteration: 4,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/d.ts"],
        summary: "first summary",
        report_body: "first body"
      }),
      "utf8"
    );

    harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-003",
        phase: "review",
        iteration: 4,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/d.ts"],
        summary: "second summary",
        report_body: "second body"
      }),
      "utf8"
    );

    expect(() =>
      harness.exec([
        "review-run",
        "record",
        "--project-id",
        PROJECT_ID,
        "--input",
        inputPath
      ])
    ).toThrow(/run_id already exists with different payload: run-003/);

    const db = harness.openReadOnlyDb();
    try {
      const row = db
        .prepare(
          `
            SELECT result_summary, report_body
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "run-003") as {
        result_summary: string;
        report_body: string;
      };

      expect(row).toEqual({
        result_summary: "first summary",
        report_body: "first body"
      });
    } finally {
      db.close();
    }
  });

  it("migrates legacy review tables before queue lease and review-run record touch new columns", () => {
    seedLegacyReviewSchema(harness);

    const leased = harness.exec([
      "queue",
      "lease",
      "--project-id",
      PROJECT_ID,
      "--lease-seconds",
      "60"
    ]);

    expect(leased).toMatchObject({
      project_id: PROJECT_ID,
      leased_count: 1,
      items: [
        {
          file_path: "src/review/legacy.ts",
          dedupe_key: "src/review/legacy.ts",
          queue_state: "leased",
          retry_count: 0,
          acknowledged_at: null
        }
      ]
    });
    expect(leased.lease_owner).toEqual(expect.any(String));
    expect(leased.lease_expires_at).toEqual(expect.any(String));

    const inputPath = join(harness.tempDir, "legacy-review-run.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "legacy-run-001",
        phase: "review",
        iteration: 1,
        kind: "batch",
        status: "completed",
        queued_files: ["src/review/legacy.ts"],
        summary: "legacy migration ok",
        report_body: "review completed",
        findings: []
      }),
      "utf8"
    );

    const recorded = harness.exec([
      "review-run",
      "record",
      "--project-id",
      PROJECT_ID,
      "--input",
      inputPath
    ]);

    expect(recorded).toMatchObject({
      project_id: PROJECT_ID,
      run_id: "legacy-run-001",
      phase: "review",
      iteration: 1,
      kind: "batch",
      status: "completed",
      queued_file_count: 1
    });

    const db = harness.openReadOnlyDb();
    try {
      const queueColumns = db
        .prepare("PRAGMA table_info(review_queue_items)")
        .all() as Array<{ name: string }>;
      const runColumns = db
        .prepare("PRAGMA table_info(review_runs)")
        .all() as Array<{ name: string }>;
      const queueIndexes = db
        .prepare(
          `
            SELECT name
            FROM sqlite_master
            WHERE type = 'index' AND tbl_name = 'review_queue_items'
            ORDER BY name ASC
          `
        )
        .all() as Array<{ name: string }>;
      const runIndexes = db
        .prepare(
          `
            SELECT name
            FROM sqlite_master
            WHERE type = 'index' AND tbl_name = 'review_runs'
            ORDER BY name ASC
          `
        )
        .all() as Array<{ name: string }>;
      const legacyQueueRow = db
        .prepare(
          `
            SELECT dedupe_key, lease_event_id, lease_expires_at, retry_count
            FROM review_queue_items
            WHERE project_id = ? AND file_path = ?
          `
        )
        .get(PROJECT_ID, "src/review/legacy.ts") as {
        dedupe_key: string | null;
        lease_event_id: string | null;
        lease_expires_at: string | null;
        retry_count: number;
      };
      const storedRun = db
        .prepare(
          `
            SELECT phase, iteration, kind, result_summary, report_body, updated_at
            FROM review_runs
            WHERE project_id = ? AND run_id = ?
          `
        )
        .get(PROJECT_ID, "legacy-run-001") as {
        phase: string;
        iteration: number;
        kind: string;
        result_summary: string | null;
        report_body: string | null;
        updated_at: string;
      };

      expect(queueColumns.map((column) => column.name)).toEqual(
        expect.arrayContaining([
          "event_id",
          "dedupe_key",
          "lease_event_id",
          "lease_expires_at",
          "acknowledged_at",
          "retry_count"
        ])
      );
      expect(runColumns.map((column) => column.name)).toEqual(
        expect.arrayContaining([
          "phase",
          "iteration",
          "kind",
          "result_summary",
          "report_body",
          "report_hash",
          "updated_at"
        ])
      );
      expect(queueIndexes.map((index) => index.name)).toEqual(
        expect.arrayContaining([
          "idx_review_queue_items_project_event",
          "idx_review_queue_items_project_dedupe_active"
        ])
      );
      expect(runIndexes.map((index) => index.name)).toEqual(
        expect.arrayContaining([
          "idx_review_runs_project_updated",
          "idx_review_runs_project_phase_kind"
        ])
      );
      expect(legacyQueueRow).toMatchObject({
        dedupe_key: "src/review/legacy.ts",
        lease_event_id: null,
        lease_expires_at: leased.lease_expires_at,
        retry_count: 0
      });
      expect(storedRun).toMatchObject({
        phase: "review",
        iteration: 1,
        kind: "batch",
        result_summary: "legacy migration ok",
        report_body: "review completed",
        updated_at: expect.any(String)
      });
    } finally {
      db.close();
    }
  });

  it("fails closed on malformed review-run input", () => {
    const inputPath = join(harness.tempDir, "invalid-review-run.json");
    writeFileSync(
      inputPath,
      JSON.stringify({
        run_id: "run-invalid",
        phase: "review",
        iteration: "not-an-int",
        kind: "batch",
        status: "completed",
        queued_files: []
      }),
      "utf8"
    );

    expect(() =>
      harness.exec([
        "review-run",
        "record",
        "--project-id",
        PROJECT_ID,
        "--input",
        inputPath
      ])
    ).toThrow(/iteration must be a non-negative integer/);
  });

  it("queue export-json works on a stamped current schema without replaying full migrations", () => {
    const db = harness.openWritableDb();
    try {
      expect(runMigrations(db)).toEqual({
        path: "full",
        schemaVersion: 1
      });
      expect(runMigrations(db)).toEqual({
        path: "fast-path",
        schemaVersion: 1
      });
    } finally {
      db.close();
    }

    const exportedPath = join(harness.tempDir, "snapshots", "queue-fast-path.json");
    const result = harness.exec([
      "queue",
      "export-json",
      "--project-id",
      PROJECT_ID,
      "--output",
      exportedPath
    ]);

    expect(result).toEqual({
      project_id: PROJECT_ID,
      output: resolve(exportedPath),
      pending_count: 0,
      leased_count: 0
    });

    const checkDb = harness.openWritableDb();
    try {
      expect(checkDb.pragma("user_version", { simple: true })).toBe(1);
    } finally {
      checkDb.close();
    }
  });
});

interface CliHarness {
  tempDir: string;
  exec(argv: string[]): any;
  databaseCallCounts(): { open: number; close: number };
  openReadOnlyDb(): BetterSqlite3Module.Database;
  openWritableDb(): BetterSqlite3Module.Database;
  cleanup(): void;
}

function createCliHarness(): CliHarness {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-cli-test-"));
  const dbPath = join(tempDir, "semantic.db");
  const outputs: string[] = [];
  let openDatabaseCount = 0;
  let closeDatabaseCount = 0;

  const dependencies: CliDependencies = {
    openDatabase: (projectId, repoRoot) => {
      openDatabaseCount += 1;
      return {
        projectId,
        dbPath,
        repoRoot: repoRoot ?? tempDir,
        db: new BetterSqlite3(dbPath)
      };
    },
    closeDatabase: (context) => {
      closeDatabaseCount += 1;
      context.db.close();
    },
    runMigrations,
    readFile: (path) => readFileSync(path, "utf8"),
    ensureDirectory: (path) => mkdirSync(path, { recursive: true }),
    writeFile: (path, contents) => {
      writeFileSync(path, contents, "utf8");
    },
    stdout: (text) => {
      outputs.push(text);
    },
    stderr: () => {
      // direct runCli tests expect throws instead of stderr-based handling
    }
  };

  return {
    tempDir,
    exec(argv: string[]) {
      outputs.length = 0;
      const effectiveArgv =
        argv[0] === "queue" && argv[1] === "enqueue" && !argv.includes("--repo-root")
          ? argv.concat(["--repo-root", tempDir])
          : argv;
      runCli(effectiveArgv, dependencies);
      return JSON.parse(outputs.join("")) as unknown;
    },
    databaseCallCounts() {
      return {
        open: openDatabaseCount,
        close: closeDatabaseCount
      };
    },
    openReadOnlyDb() {
      return new BetterSqlite3(dbPath, { readonly: true });
    },
    openWritableDb() {
      return new BetterSqlite3(dbPath);
    },
    cleanup() {
      rmSync(tempDir, { recursive: true, force: true });
    }
  };
}

function enqueueTwoFiles(harness: CliHarness): void {
  harness.exec([
    "queue",
    "enqueue",
    "--project-id",
    PROJECT_ID,
    "--file-path",
    "src/review/a.ts"
  ]);
  harness.exec([
    "queue",
    "enqueue",
    "--project-id",
    PROJECT_ID,
    "--file-path",
    "src/review/b.ts"
  ]);
}

function appendExpectedFiles(argv: string[], expectedFiles: string[]): string[] {
  return argv.concat(expectedFiles.flatMap((filePath) => ["--expected-file", filePath]));
}

function createLegacyReviewSchema(db: BetterSqlite3Module.Database): void {
  db.exec(`
    CREATE TABLE registry_deltas (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      delta_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      applied_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(project_id, idempotency_key)
    );

    CREATE TABLE review_queue_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id TEXT NOT NULL,
      file_path TEXT NOT NULL,
      queue_state TEXT NOT NULL DEFAULT 'pending',
      first_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      last_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
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
      UNIQUE(project_id, file_path),
      CHECK(queue_state IN ('pending', 'leased', 'done'))
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
}

function listTableColumns(
  db: BetterSqlite3Module.Database,
  tableName: string
): string[] {
  return (
    db.prepare(`PRAGMA table_info(${tableName})`).all() as Array<{ name: string }>
  ).map((column) => column.name);
}

function countQueueRows(harness: CliHarness): number {
  const db = harness.openReadOnlyDb();
  try {
    const row = db
      .prepare(
        `
          SELECT COUNT(*) AS total
          FROM review_queue_items
          WHERE project_id = ?
        `
      )
      .get(PROJECT_ID) as { total: number };

    return row.total;
  } finally {
    db.close();
  }
}

function seedLegacyReviewSchema(harness: CliHarness): void {
  const db = harness.openWritableDb();
  try {
    db.exec(`
      CREATE TABLE review_queue_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        queue_state TEXT NOT NULL DEFAULT 'pending',
        UNIQUE(project_id, file_path)
      );

      CREATE TABLE review_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'started',
        UNIQUE(project_id, run_id)
      );
    `);

    db.prepare(
      `
        INSERT INTO review_queue_items (project_id, file_path, queue_state)
        VALUES (?, ?, 'pending')
      `
    ).run(PROJECT_ID, "src/review/legacy.ts");
  } finally {
    db.close();
  }
}
