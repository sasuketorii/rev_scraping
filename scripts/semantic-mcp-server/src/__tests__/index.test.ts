import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DatabaseContext } from "../db/connection.js";
import { runMigrations } from "../db/migrations.js";
import { resolveProjectId } from "../index.js";
import { handleRegistryUpsert } from "../tools/registry.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;
const PROJECT_ID = "test-project";

describe("semantic mcp server startup args", () => {
  it("fails closed when --project-id is omitted", () => {
    expect(() => resolveProjectId([])).toThrow(
      /project_id is required: use --project-id <id>/
    );
  });

  it("fails closed when --project-id is followed by another flag", () => {
    expect(() => resolveProjectId(["--project-id", "--project-id"])).toThrow(
      /--project-id requires a value; received another flag: --project-id/
    );
  });

  it("fails closed when an unknown positional argument is present", () => {
    expect(() => resolveProjectId(["bogus", "--project-id", "demo"])).toThrow(
      /unknown positional argument: bogus/
    );
  });

  it("fails closed when an unknown flag is present", () => {
    expect(() => resolveProjectId(["--bogus", "--project-id", "demo"])).toThrow(
      /unknown flag: --bogus/
    );
  });

  it("fails closed when --project-id is repeated", () => {
    expect(() =>
      resolveProjectId(["--project-id", "good", "--project-id", "bad"])
    ).toThrow(/duplicate flag: --project-id/);
  });

  it("fails closed when --project-id= is repeated", () => {
    expect(() =>
      resolveProjectId(["--project-id=good", "--project-id=bad"])
    ).toThrow(/duplicate flag: --project-id/);
  });
});

describe("semantic mcp registry indexes", () => {
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

  it("creates named exact-name and capsule retention indexes with expected columns", () => {
    const componentIndexes = listIndexes(context, "components");
    expect(componentIndexes).toContain("idx_components_project_name_status_updated");
    expect(componentIndexes).toContain("idx_components_project_file_path");
    expect(componentIndexes.some((name) => name.startsWith("sqlite_autoindex_components"))).toBe(
      true
    );

    expect(indexColumns(context, "idx_components_project_name_status_updated")).toEqual([
      "project_id",
      "name",
      "status",
      "updated_at",
      "semantic_id"
    ]);
    expect(indexColumns(context, "idx_components_project_file_path")).toEqual([
      "project_id",
      "file_path",
      "semantic_id"
    ]);

    const capsuleIndexes = listIndexes(context, "capsules");
    expect(capsuleIndexes).toContain("idx_capsules_project_task_phase_created_at");
    expect(indexColumns(context, "idx_capsules_project_task_phase_created_at")).toEqual([
      "project_id",
      "task_id",
      "phase",
      "created_at",
      "id"
    ]);
  });

  it("uses indexes for exact-id, exact-name, and path-prefix lookup query plans", () => {
    handleRegistryUpsert(context, {
      components: [
        {
          semantic_id: "core:UserService",
          name: "UserService",
          module: "core",
          file_path: "src/core/user-service.ts",
          kind: "class"
        },
        {
          semantic_id: "core:AuditService",
          name: "AuditService",
          module: "core",
          file_path: "src/core/audit-service.ts",
          kind: "class"
        }
      ]
    });

    const exactIdPlan = explainQueryPlan(
      context,
      `
      SELECT semantic_id
      FROM components
      WHERE project_id = ? AND semantic_id = ?
      ORDER BY updated_at DESC, semantic_id ASC
      LIMIT 4
      `,
      [PROJECT_ID, "core:UserService"]
    );
    expect(exactIdPlan).toMatch(/USING INDEX sqlite_autoindex_components_|USING COVERING INDEX sqlite_autoindex_components_/);
    expect(exactIdPlan).not.toMatch(/SCAN components/);

    const exactNamePlan = explainQueryPlan(
      context,
      `
      SELECT semantic_id
      FROM components
      WHERE project_id = ? AND name = ? AND status IN (?)
      ORDER BY updated_at DESC, semantic_id ASC
      LIMIT 4
      `,
      [PROJECT_ID, "UserService", "active"]
    );
    expect(exactNamePlan).toMatch(/USING INDEX idx_components_project_name_status_updated|USING COVERING INDEX idx_components_project_name_status_updated/);
    expect(exactNamePlan).not.toMatch(/SCAN components/);

    const pathPrefixPlan = explainQueryPlan(
      context,
      `
      SELECT semantic_id
      FROM components
      WHERE project_id = ? AND file_path >= ? AND file_path < ?
      ORDER BY file_path ASC, semantic_id ASC
      LIMIT 4
      `,
      [PROJECT_ID, "src/core/", "src/core0"]
    );
    expect(pathPrefixPlan).toMatch(/USING INDEX idx_components_project_file_path|USING COVERING INDEX idx_components_project_file_path/);
    expect(pathPrefixPlan).not.toMatch(/SCAN components/);
    expect(pathPrefixPlan).not.toMatch(/USE TEMP B-TREE/);
  });

  it("fails closed when durable schema columns cannot be repaired completely", () => {
    const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-bad-schema-test-"));
    const dbPath = join(tempDir, "semantic.db");
    const db = new BetterSqlite3(dbPath);

    try {
      db.exec(`
        CREATE TABLE components (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id TEXT NOT NULL,
          semantic_id TEXT NOT NULL,
          name TEXT NOT NULL
        );
      `);

      expect(() => runMigrations(db)).toThrow(/durable schema|Cannot create index/);
    } finally {
      db.close();
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it("fails closed when durable schema table structure cannot be repaired completely", () => {
    const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-bad-structure-test-"));
    const dbPath = join(tempDir, "semantic.db");
    const db = new BetterSqlite3(dbPath);

    try {
      runMigrations(db);
      db.exec(`
        DROP TABLE registry_deltas;
        CREATE TABLE registry_deltas (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id TEXT NOT NULL,
          idempotency_key TEXT NOT NULL,
          delta_type TEXT NOT NULL,
          semantic_id TEXT,
          payload TEXT NOT NULL,
          applied_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'
        );
        PRAGMA user_version = 0;
      `);

      expect(() => runMigrations(db)).toThrow(/durable schema validation failed/);
      expect(db.pragma("user_version", { simple: true })).toBe(0);
    } finally {
      db.close();
      rmSync(tempDir, { recursive: true, force: true });
    }
  });
});

function createTestContext(): {
  context: DatabaseContext;
  cleanup: () => void;
} {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-index-test-"));
  const dbPath = join(tempDir, "semantic.db");
  const db = new BetterSqlite3(dbPath);
  runMigrations(db);

  db.prepare(
    `
      INSERT INTO projects (id, name, root_path, created_at, updated_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `
  ).run(PROJECT_ID, "Test Project", tempDir);

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

function listIndexes(context: DatabaseContext, tableName: string): string[] {
  return (context.db.prepare(`PRAGMA index_list('${tableName}')`).all() as Array<{ name: string }>)
    .map((row) => row.name);
}

function indexColumns(context: DatabaseContext, indexName: string): string[] {
  return (
    context.db.prepare(`PRAGMA index_info('${indexName}')`).all() as Array<{ name: string }>
  ).map((row) => row.name);
}

function explainQueryPlan(
  context: DatabaseContext,
  sql: string,
  params: unknown[]
): string {
  return (
    context.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...params) as Array<{ detail: string }>
  )
    .map((row) => row.detail)
    .join("\n");
}
