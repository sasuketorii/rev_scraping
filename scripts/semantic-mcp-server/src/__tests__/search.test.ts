import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DatabaseContext } from "../db/connection.js";
import { runMigrations } from "../db/migrations.js";
import { SEARCH_INPUT_SCHEMA } from "../server.js";
import { handleRegistryUpsert } from "../tools/registry.js";
import { handleSearch } from "../tools/search.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";

describe("sem.search", () => {
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

  it("exposes a bounded explicit-scope schema", () => {
    expect(SEARCH_INPUT_SCHEMA.additionalProperties).toBe(false);
    expect(SEARCH_INPUT_SCHEMA.required).toEqual(["query"]);
    expect(SEARCH_INPUT_SCHEMA.anyOf).toEqual([
      { required: ["scope_paths"] },
      { required: ["scopePaths"] }
    ]);
  });

  it("returns advisory registry and filesystem matches within bounds", () => {
    writeRepoFile(context, "src/core/user-service.ts", [
      "export class UserService {",
      `  ${"x".repeat(120)} targetNeedle`,
      "}"
    ].join("\n"));
    handleRegistryUpsert(context, {
      components: [{
        semantic_id: "core:UserService",
        name: "UserService",
        module: "core",
        file_path: "src/core/user-service.ts",
        kind: "class"
      }]
    });

    const result = handleSearch(context, {
      project_id: PROJECT_ID,
      query: "UserService",
      scope_paths: ["src/core/user-service.ts"],
      limit: 50,
      capsule_budget_tokens: 500
    });

    expect(result.advisory_only).toBe(true);
    expect(result.items.length).toBeLessThanOrEqual(10);
    expect(result.capsule).toContain("advisory_only:true");
    expect(result.items[0]).toMatchObject({
      path: "src/core/user-service.ts",
      semantic_id: "core:UserService",
      source: "registry+filesystem"
    });

    const filesystemResult = handleSearch(context, {
      project_id: PROJECT_ID,
      query: "targetNeedle",
      scope_paths: ["src/core/user-service.ts"],
      capsule_budget_tokens: 500
    });
    expect(filesystemResult.items[0]).toMatchObject({
      path: "src/core/user-service.ts",
      source: "filesystem"
    });
    expect(filesystemResult.items[0].excerpt?.length ?? 0).toBeLessThanOrEqual(80);
  });

  it("rejects empty, broad, absolute, traversal, and symlink scopes", () => {
    writeRepoFile(context, "src/core/user-service.ts", "targetNeedle");
    symlinkSync(join(context.repoRoot!, "src/core/user-service.ts"), join(context.repoRoot!, "linked.ts"));

    for (const scope_paths of [[], ["."], ["*"], ["/tmp/file.ts"], ["../outside.ts"], ["linked.ts"]]) {
      expect(() =>
        handleSearch(context, {
          query: "targetNeedle",
          scope_paths
        })
      ).toThrow(/sem\.search failed/);
    }
  });

  it("rejects unbounded scope lists and skips invalid utf8 like Rust", () => {
    const paths = Array.from({ length: 41 }, (_, index) => `src/core/file-${index}.ts`);
    for (const path of paths) {
      writeRepoFile(context, path, "targetNeedle");
    }

    expect(() =>
      handleSearch(context, {
        query: "targetNeedle",
        scope_paths: paths
      })
    ).toThrow(/at most 40 entries/);

    const invalidUtf8Path = "src/core/invalid-utf8.bin";
    writeRepoFile(context, invalidUtf8Path, Buffer.from([0xff, 0xfe, 0x74, 0x61, 0x72, 0x67, 0x65, 0x74]));
    const result = handleSearch(context, {
      query: "target",
      scope_paths: [invalidUtf8Path]
    });
    expect(result.items).toEqual([]);
    expect(result.total).toBe(0);
  });

  it("rejects mismatched aliases and mismatched project ids", () => {
    writeRepoFile(context, "src/core/user-service.ts", "targetNeedle");

    expect(() =>
      handleSearch(context, {
        query: "targetNeedle",
        scope_paths: ["src/core/user-service.ts"],
        scopePaths: ["src/core/other.ts"]
      })
    ).toThrow(/aliases must match/);

    expect(() =>
      handleSearch(context, {
        project_id: "other-project",
        query: "targetNeedle",
        scope_paths: ["src/core/user-service.ts"]
      })
    ).toThrow(/project_id mismatch/);
  });
});

function createTestContext(): {
  context: DatabaseContext;
  cleanup: () => void;
} {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-search-test-"));
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

function writeRepoFile(context: DatabaseContext, relativePath: string, content: string | Buffer): void {
  const absolutePath = join(context.repoRoot!, relativePath);
  mkdirSync(dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, content);
}
