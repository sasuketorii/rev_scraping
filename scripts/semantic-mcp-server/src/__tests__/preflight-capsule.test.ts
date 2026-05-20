import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DatabaseContext } from "../db/connection.js";
import { runMigrations } from "../db/migrations.js";
import { handleHealth } from "../tools/health.js";
import { handleCapsule } from "../tools/capsule.js";
import { handlePreflight } from "../tools/preflight.js";
import { handleRegistryUpsert } from "../tools/registry.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";
const TOKEN_CHAR_RATIO = 3;
const DEFAULT_RESPONSE_TOKEN_BUDGET = 220;

describe("preflight + capsule tools", () => {
  let context: DatabaseContext;
  let tempDir = "";
  let cleanup: (() => void) | null = null;

  beforeEach(() => {
    const created = createTestContext();
    context = created.context;
    tempDir = created.tempDir;
    cleanup = created.cleanup;
  });

  afterEach(() => {
    cleanup?.();
    cleanup = null;
  });

  it("returns BLOCK when proposed component already exists in registry", () => {
    handleRegistryUpsert(context, {
      components: [
        {
          logical_id: "core:UserService",
          name: "UserService",
          module: "core",
          file_path: "src/core/user-service.ts",
          kind: "class",
          exports: ["UserService"],
          imports: []
        }
      ]
    });

    const response = handlePreflight(context, {
      project_id: PROJECT_ID,
      task_id: "task-block",
      scope: ["src/core/new-user-service.ts"],
      proposed_components: ["core:UserService"]
    });

    expect(response.verdict).toBe("BLOCK");
    expect(response.conflicts).toHaveLength(1);
    expect(response.conflicts[0]).toMatchObject({
      semantic_id: "core:UserService"
    });
    expect(JSON.stringify(response).length).toBeLessThanOrEqual(
      DEFAULT_RESPONSE_TOKEN_BUDGET * TOKEN_CHAR_RATIO
    );
  });

  it("returns WARN when scope overlaps with active preflight task", () => {
    context.db
      .prepare(
        `
        INSERT INTO capsules (
          project_id,
          task_id,
          phase,
          content,
          token_count,
          created_at
        )
        VALUES (?, ?, 'preflight', ?, ?, datetime('now'))
      `
      )
      .run(
        PROJECT_ID,
        "task-existing",
        "TASK=task-existing\nPHASE=preflight\nVERDICT=PASS\nSCOPE=src/shared.ts|src/other.ts",
        30
      );

    const response = handlePreflight(context, {
      project_id: PROJECT_ID,
      task_id: "task-warn",
      scope: ["src/shared.ts"],
      proposed_components: ["core:BrandNewService"]
    });

    expect(response.verdict).toBe("WARN");
    expect(response.conflicts).toEqual([]);
  });

  it("keeps WARNINGS marker when WARN capsule is trimmed", () => {
    const insertCapsule = context.db.prepare(
      `
        INSERT INTO capsules (
          project_id,
          task_id,
          phase,
          content,
          token_count,
          created_at
        )
        VALUES (?, ?, 'preflight', ?, ?, datetime('now'))
      `
    );

    for (let index = 0; index < 3; index += 1) {
      const taskId = `task-overlap-${index}-${"x".repeat(220)}`;
      insertCapsule.run(
        PROJECT_ID,
        taskId,
        `TASK=${taskId}\nPHASE=preflight\nVERDICT=PASS\nSCOPE=src/shared-trim.ts`,
        200
      );
    }

    const response = handlePreflight(context, {
      project_id: PROJECT_ID,
      task_id: "task-warn-trimmed-capsule",
      scope: ["src/shared-trim.ts"],
      proposed_components: ["core:TrimmedWarningService"]
    });

    expect(response.verdict).toBe("WARN");
    expect(response.capsule).toContain("WARNINGS=");
    expect(response.capsule).toContain("WARNINGS=truncated");
  });

  it("merges removed_symbols into reverse-dependency impact summary", () => {
    const adjacencyPath = join(tempDir, "adjacency.jsonl");
    writeFileSync(
      adjacencyPath,
      `${JSON.stringify({
        source_logical_id: "ui:Dashboard",
        target_logical_id: "core:LegacyService",
        relation_type: "symbol_ref"
      })}\n`,
      "utf8"
    );

    const response = handlePreflight(context, {
      project_id: PROJECT_ID,
      task_id: "task-delete-impact",
      scope: ["src/core/legacy-service.ts"],
      proposed_components: ["core:ReplacementService"],
      removed_symbols: ["core:LegacyService"],
      adjacency_path: "adjacency.jsonl",
      dependency_verdict: {
        status: "warn",
        issues: [
          {
            package: "left-pad",
            severity: "low",
            message: "outdated"
          }
        ],
        checked_at: "2026-02-24T00:00:00Z"
      }
    });

    expect(response.verdict).toBe("PASS");
    expect(response.delete_impacts_summary).toContain("impacts=1");
    expect(response.dependency_verdict?.status).toBe("warn");
  });

  it("rejects repo-external adjacency_path before delete-impact ingestion", () => {
    expect(() =>
      handlePreflight(context, {
        project_id: PROJECT_ID,
        task_id: "task-delete-impact-external-adjacency",
        scope: ["src/core/legacy-service.ts"],
        proposed_components: ["core:ReplacementService"],
        removed_symbols: ["core:LegacyService"],
        adjacency_path: "/tmp/adjacency.jsonl"
      })
    ).toThrow(/adjacency_path must be repo-relative/);

    mkdirSync(join(tempDir, "links"), { recursive: true });
    symlinkSync(tmpdir(), join(tempDir, "links", "escape"));
    expect(() =>
      handlePreflight(context, {
        project_id: PROJECT_ID,
        task_id: "task-delete-impact-symlink-adjacency",
        scope: ["src/core/legacy-service.ts"],
        proposed_components: ["core:ReplacementService"],
        removed_symbols: ["core:LegacyService"],
        adjacency_path: "links/escape/adjacency.jsonl"
      })
    ).toThrow(/adjacency_path must not escape repo root through symlinks/);
  });

  it("fails closed on malformed authoritative adjacency rows", () => {
    writeFileSync(join(tempDir, "malformed-adjacency.jsonl"), "{\"source_logical_id\":\n", "utf8");

    expect(() =>
      handlePreflight(context, {
        project_id: PROJECT_ID,
        task_id: "task-delete-impact-malformed-adjacency",
        scope: ["src/core/legacy-service.ts"],
        proposed_components: ["core:ReplacementService"],
        removed_symbols: ["core:LegacyService"],
        adjacency_path: "malformed-adjacency.jsonl"
      })
    ).toThrow(/malformed adjacency JSON/);

    writeFileSync(
      join(tempDir, "missing-field-adjacency.jsonl"),
      `${JSON.stringify({ source_logical_id: "ui:Dashboard" })}\n`,
      "utf8"
    );

    expect(() =>
      handlePreflight(context, {
        project_id: PROJECT_ID,
        task_id: "task-delete-impact-missing-field-adjacency",
        scope: ["src/core/legacy-service.ts"],
        proposed_components: ["core:ReplacementService"],
        removed_symbols: ["core:LegacyService"],
        adjacency_path: "missing-field-adjacency.jsonl"
      })
    ).toThrow(/malformed adjacency row/);
  });

  it("fails closed on newline-less adjacency rows that exceed the bounded line guard", () => {
    writeFileSync(
      join(tempDir, "huge-adjacency.jsonl"),
      `{"source_logical_id":"${"x".repeat(1024 * 1024)}","target_logical_id":"core:LegacyService"}`,
      "utf8"
    );

    expect(() =>
      handlePreflight(context, {
        project_id: PROJECT_ID,
        task_id: "task-delete-impact-huge-adjacency",
        scope: ["src/core/legacy-service.ts"],
        proposed_components: ["core:ReplacementService"],
        removed_symbols: ["core:LegacyService"],
        adjacency_path: "huge-adjacency.jsonl"
      })
    ).toThrow(/adjacency line exceeds/);
  });

  it("builds capsule response under budget and persists it", () => {
    const response = handleCapsule(context, {
      project_id: PROJECT_ID,
      task_id: "task-capsule",
      phase: "impl",
      context: {
        changed_symbols: ["core:UserService", "core:AuthService"],
        top_k_symbols: ["core:UserService", "core:BillingService"],
        preflight_verdict: "PASS"
      }
    });

    expect(response.capsule).toContain("TASK=task-capsule");
    expect(response.constraints.length).toBeGreaterThan(0);
    expect(Array.isArray(response.hints)).toBe(true);
    expect(JSON.stringify(response).length).toBeLessThanOrEqual(
      DEFAULT_RESPONSE_TOKEN_BUDGET * TOKEN_CHAR_RATIO
    );

    const row = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM capsules
        WHERE project_id = ? AND task_id = ? AND phase = ?
      `
      )
      .get(PROJECT_ID, "task-capsule", "impl") as { total: number } | undefined;

    expect(row?.total ?? 0).toBe(1);
  });

  it("fails closed when capsule budget cannot fit minimum payload", () => {
    expect(() =>
      handleCapsule(context, {
        project_id: PROJECT_ID,
        task_id: "task-tight-budget",
        phase: "impl",
        budget: 21
      })
    ).toThrow(/fail-closed/i);
  });

  it("prunes capsule history only after threshold-driven writes and exposes health visibility", () => {
    const insertCapsule = context.db.prepare(
      `
        INSERT INTO capsules (
          project_id,
          task_id,
          phase,
          content,
          token_count,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      `
    );

    for (let index = 0; index < 256; index += 1) {
      insertCapsule.run(
        PROJECT_ID,
        "task-retention",
        "impl",
        `old-${index}`,
        1,
        `2026-01-01T00:${String(index % 60).padStart(2, "0")}:00Z`
      );
    }

    const beforeReadHealth = handleHealth(context);
    expect(beforeReadHealth.capsule_retention).toMatchObject({
      mode: "threshold-driven-on-write",
      trigger_project_row_count: 256,
      project_hard_cap: 256,
      preflight_keep_latest_per_task: 1,
      non_preflight_keep_latest_per_task_phase: 3,
      current_project_row_count: 256
    });
    expect(beforeReadHealth.capsule_retention.prune_eligible_row_count).toBeGreaterThan(0);

    const countAfterRead = context.db
      .prepare("SELECT COUNT(*) AS total FROM capsules WHERE project_id = ?")
      .get(PROJECT_ID) as { total: number };
    expect(countAfterRead.total).toBe(256);

    handleCapsule(context, {
      project_id: PROJECT_ID,
      task_id: "task-retention",
      phase: "impl",
      context: {
        changed_symbols: ["core:Latest"]
      }
    });

    const implRows = context.db
      .prepare(
        `
        SELECT content
        FROM capsules
        WHERE project_id = ? AND task_id = ? AND phase = ?
        ORDER BY created_at DESC, id DESC
      `
      )
      .all(PROJECT_ID, "task-retention", "impl") as Array<{ content: string }>;
    expect(implRows).toHaveLength(3);
    expect(implRows[0].content).toContain("TASK=task-retention");

    for (let index = 0; index < 260; index += 1) {
      insertCapsule.run(
        PROJECT_ID,
        "task-preflight-retention",
        "preflight",
        `preflight-${index}`,
        1,
        `2026-02-01T00:${String(index % 60).padStart(2, "0")}:00Z`
      );
    }

    handlePreflight(context, {
      project_id: PROJECT_ID,
      task_id: "task-preflight-retention",
      scope: ["src/preflight-retention.ts"],
      proposed_components: ["core:PreflightRetention"]
    });

    const preflightRows = context.db
      .prepare(
        `
        SELECT content
        FROM capsules
        WHERE project_id = ? AND task_id = ? AND phase = 'preflight'
        ORDER BY created_at DESC, id DESC
      `
      )
      .all(PROJECT_ID, "task-preflight-retention") as Array<{ content: string }>;
    expect(preflightRows).toHaveLength(1);
    expect(preflightRows[0].content).toContain("TASK=task-preflight-retention");
  });

  it("bounds capsule history project-wide when task ids grow beyond the retention threshold", () => {
    const insertCapsule = context.db.prepare(
      `
        INSERT INTO capsules (
          project_id,
          task_id,
          phase,
          content,
          token_count,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
      `
    );

    for (let index = 0; index < 300; index += 1) {
      insertCapsule.run(
        PROJECT_ID,
        `task-distinct-${String(index).padStart(3, "0")}`,
        "impl",
        `distinct-${index}`,
        1,
        `2026-03-01T00:${String(index % 60).padStart(2, "0")}:00Z`
      );
    }

    handleCapsule(context, {
      project_id: PROJECT_ID,
      task_id: "task-distinct-trigger",
      phase: "impl",
      context: {
        changed_symbols: ["core:ProjectWideCap"]
      }
    });

    const countAfterWrite = context.db
      .prepare("SELECT COUNT(*) AS total FROM capsules WHERE project_id = ?")
      .get(PROJECT_ID) as { total: number };
    expect(countAfterWrite.total).toBeLessThanOrEqual(256);
    expect(handleHealth(context).capsule_retention.current_project_row_count).toBeLessThanOrEqual(
      256
    );
  });
});

function createTestContext(): {
  context: DatabaseContext;
  tempDir: string;
  cleanup: () => void;
} {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-preflight-test-"));
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
    tempDir,
    cleanup: () => {
      db.close();
      rmSync(tempDir, { recursive: true, force: true });
    }
  };
}
