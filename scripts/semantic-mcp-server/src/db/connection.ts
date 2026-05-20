import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import type BetterSqlite3 from "better-sqlite3";
import { validateProjectId } from "../utils/project-id.js";

const require = createRequire(import.meta.url);
const BETTER_SQLITE_REBUILD_HINT =
  'Failed to load better-sqlite3 native binding. Run "npm rebuild better-sqlite3" and make sure Node.js matches package.json engines.';
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3.Database;

export interface DatabaseContext {
  projectId: string;
  dbPath: string;
  repoRoot?: string;
  db: BetterSqlite3.Database;
}

function loadBetterSqlite3(): BetterSqlite3Constructor {
  try {
    return require("better-sqlite3") as BetterSqlite3Constructor;
  } catch (error) {
    throw new Error(`${BETTER_SQLITE_REBUILD_HINT} ${toErrorMessage(error)}`);
  }
}

export function resolveDatabasePath(projectId: string): string {
  const safeProjectId = validateProjectId(projectId);
  return join(homedir(), ".semantic-mcp", safeProjectId, "semantic.db");
}

export function openDatabase(projectId: string, repoRoot: string = process.cwd()): DatabaseContext {
  let db: BetterSqlite3.Database | null = null;

  try {
    const safeProjectId = validateProjectId(projectId);
    const dbPath = resolveDatabasePath(safeProjectId);
    mkdirSync(dirname(dbPath), { recursive: true });

    const BetterSqlite3 = loadBetterSqlite3();
    const openedDb = new BetterSqlite3(dbPath);
    openedDb.pragma("journal_mode = WAL");
    openedDb.pragma("synchronous = NORMAL");
    openedDb.pragma("busy_timeout = 5000");
    assertDatabaseConnection(openedDb);
    db = openedDb;

    return {
      projectId: safeProjectId,
      dbPath,
      repoRoot: resolve(repoRoot),
      db: openedDb
    };
  } catch (error) {
    if (db !== null && db.open) {
      try {
        db.close();
      } catch {
        // ignore secondary close errors while handling startup failures
      }
    }

    throw new Error(`Failed to open database: ${toErrorMessage(error)}`);
  }
}

export function closeDatabase(context: DatabaseContext): void {
  try {
    context.db.close();
  } catch (error) {
    throw new Error(`Failed to close database: ${toErrorMessage(error)}`);
  }
}

function assertDatabaseConnection(db: BetterSqlite3.Database): void {
  try {
    db.prepare("SELECT 1").get();
  } catch (error) {
    throw new Error(`database connection test failed: ${toErrorMessage(error)}`);
  }
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
