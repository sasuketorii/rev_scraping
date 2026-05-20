import type Database from "better-sqlite3";
import { REQUIRED_TABLES } from "../types.js";

interface IndexDefinition {
  name: string;
  table: string;
  requiredColumns: string[];
  sql: string;
}

interface ColumnDefinition {
  table: string;
  column: string;
  sql: string;
}

interface TableStructureDefinition {
  table: string;
  requiredFragments: string[];
}

const LEGACY_TIMESTAMP_FALLBACK = "1970-01-01T00:00:00Z";
const CURRENT_SCHEMA_VERSION = 1;

type MigrationPath = "fast-path" | "full";

export interface MigrationResult {
  path: MigrationPath;
  schemaVersion: number;
}

const SCHEMA_SQL = `
-- projects: プロジェクト設定
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- components: レジストリ本体
CREATE TABLE IF NOT EXISTS components (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  semantic_id TEXT NOT NULL,  -- = logical_id (module:name)
  name TEXT NOT NULL,
  module TEXT NOT NULL,
  file_path TEXT NOT NULL,
  kind TEXT NOT NULL,
  exports TEXT DEFAULT '[]',  -- JSON array
  imports TEXT DEFAULT '[]',  -- JSON array
  hash TEXT NOT NULL,
  figma_ref TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  inactive_reason TEXT,
  security_level TEXT,
  idem TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(project_id, semantic_id)
);

-- registry_deltas: 差分更新記録
CREATE TABLE IF NOT EXISTS registry_deltas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  delta_type TEXT NOT NULL,  -- upsert/delete/set_status
  semantic_id TEXT,
  payload TEXT NOT NULL,     -- JSON
  applied_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(project_id, idempotency_key)
);

-- capsules: カプセルキャッシュ
CREATE TABLE IF NOT EXISTS capsules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  phase TEXT NOT NULL,
  content TEXT NOT NULL,
  token_count INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- outbox_queue: 将来同期用キュー
CREATE TABLE IF NOT EXISTS outbox_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- review_queue_items: レビューキューの authoritative state
CREATE TABLE IF NOT EXISTS review_queue_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  event_id TEXT,
  dedupe_key TEXT,
  file_path TEXT NOT NULL,
  queue_state TEXT NOT NULL DEFAULT 'pending',
  first_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  last_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
  payload TEXT NOT NULL DEFAULT '{}',
  lease_run_id TEXT,
  lease_event_id TEXT,
  lease_owner TEXT,
  leased_at TEXT,
  lease_expires_at TEXT,
  acknowledged_at TEXT,
  completed_at TEXT,
  completed_run_id TEXT,
  last_error TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  retry_count INTEGER NOT NULL DEFAULT 0,
  UNIQUE(project_id, file_path),
  CHECK(queue_state IN ('pending', 'leased', 'done'))
);

-- review_runs: レビュー実行トレース
CREATE TABLE IF NOT EXISTS review_runs (
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
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  UNIQUE(project_id, run_id),
  CHECK(status IN ('started', 'completed', 'failed'))
);
`;

const INDEX_DEFINITIONS: IndexDefinition[] = [
  {
    name: "idx_components_project_file_path",
    table: "components",
    requiredColumns: ["project_id", "file_path", "semantic_id"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_components_project_file_path
        ON components(project_id, file_path, semantic_id ASC)
    `
  },
  {
    name: "idx_components_project_status_updated",
    table: "components",
    requiredColumns: ["project_id", "status", "updated_at"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_components_project_status_updated
        ON components(project_id, status, updated_at DESC)
    `
  },
  {
    name: "idx_components_project_name_status_updated",
    table: "components",
    requiredColumns: ["project_id", "name", "status", "updated_at", "semantic_id"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_components_project_name_status_updated
        ON components(project_id, name, status, updated_at DESC, semantic_id ASC)
    `
  },
  {
    name: "idx_capsules_project_task_phase_created_at",
    table: "capsules",
    requiredColumns: ["project_id", "task_id", "phase", "created_at", "id"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_capsules_project_task_phase_created_at
        ON capsules(project_id, task_id, phase, created_at DESC, id DESC)
    `
  },
  {
    name: "idx_review_queue_items_project_state",
    table: "review_queue_items",
    requiredColumns: ["project_id", "queue_state", "first_enqueued_at", "id"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_state
        ON review_queue_items(project_id, queue_state, first_enqueued_at ASC, id ASC)
    `
  },
  {
    name: "idx_review_queue_items_project_lease_expiry",
    table: "review_queue_items",
    requiredColumns: ["project_id", "lease_expires_at"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_lease_expiry
        ON review_queue_items(project_id, lease_expires_at)
    `
  },
  {
    name: "idx_review_queue_items_project_event",
    table: "review_queue_items",
    requiredColumns: ["project_id", "event_id"],
    sql: `
      CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_event
        ON review_queue_items(project_id, event_id)
        WHERE event_id IS NOT NULL
    `
  },
  {
    name: "idx_review_queue_items_project_dedupe_active",
    table: "review_queue_items",
    requiredColumns: ["project_id", "dedupe_key", "queue_state"],
    sql: `
      CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_dedupe_active
        ON review_queue_items(project_id, dedupe_key)
        WHERE dedupe_key IS NOT NULL AND queue_state IN ('pending', 'leased')
    `
  },
  {
    name: "idx_review_runs_project_updated",
    table: "review_runs",
    requiredColumns: ["project_id", "updated_at", "id"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_review_runs_project_updated
        ON review_runs(project_id, updated_at DESC, id DESC)
    `
  },
  {
    name: "idx_review_runs_project_phase_kind",
    table: "review_runs",
    requiredColumns: ["project_id", "phase", "kind", "created_at"],
    sql: `
      CREATE INDEX IF NOT EXISTS idx_review_runs_project_phase_kind
        ON review_runs(project_id, phase, kind, created_at DESC)
    `
  }
];

const COLUMN_DEFINITIONS: ColumnDefinition[] = [
  {
    table: "registry_deltas",
    column: "semantic_id",
    sql: "ALTER TABLE registry_deltas ADD COLUMN semantic_id TEXT"
  },
  {
    table: "registry_deltas",
    column: "applied_at",
    sql: `ALTER TABLE registry_deltas ADD COLUMN applied_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  },
  {
    table: "review_queue_items",
    column: "event_id",
    sql: "ALTER TABLE review_queue_items ADD COLUMN event_id TEXT"
  },
  {
    table: "review_queue_items",
    column: "dedupe_key",
    sql: "ALTER TABLE review_queue_items ADD COLUMN dedupe_key TEXT"
  },
  {
    table: "review_queue_items",
    column: "queue_state",
    sql: "ALTER TABLE review_queue_items ADD COLUMN queue_state TEXT NOT NULL DEFAULT 'pending'"
  },
  {
    table: "review_queue_items",
    column: "first_enqueued_at",
    sql: `ALTER TABLE review_queue_items ADD COLUMN first_enqueued_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  },
  {
    table: "review_queue_items",
    column: "last_enqueued_at",
    sql: `ALTER TABLE review_queue_items ADD COLUMN last_enqueued_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  },
  {
    table: "review_queue_items",
    column: "last_enqueue_source",
    sql: "ALTER TABLE review_queue_items ADD COLUMN last_enqueue_source TEXT NOT NULL DEFAULT 'unknown'"
  },
  {
    table: "review_queue_items",
    column: "payload",
    sql: "ALTER TABLE review_queue_items ADD COLUMN payload TEXT NOT NULL DEFAULT '{}'"
  },
  {
    table: "review_queue_items",
    column: "lease_run_id",
    sql: "ALTER TABLE review_queue_items ADD COLUMN lease_run_id TEXT"
  },
  {
    table: "review_queue_items",
    column: "lease_event_id",
    sql: "ALTER TABLE review_queue_items ADD COLUMN lease_event_id TEXT"
  },
  {
    table: "review_queue_items",
    column: "lease_owner",
    sql: "ALTER TABLE review_queue_items ADD COLUMN lease_owner TEXT"
  },
  {
    table: "review_queue_items",
    column: "leased_at",
    sql: "ALTER TABLE review_queue_items ADD COLUMN leased_at TEXT"
  },
  {
    table: "review_queue_items",
    column: "lease_expires_at",
    sql: "ALTER TABLE review_queue_items ADD COLUMN lease_expires_at TEXT"
  },
  {
    table: "review_queue_items",
    column: "acknowledged_at",
    sql: "ALTER TABLE review_queue_items ADD COLUMN acknowledged_at TEXT"
  },
  {
    table: "review_queue_items",
    column: "completed_at",
    sql: "ALTER TABLE review_queue_items ADD COLUMN completed_at TEXT"
  },
  {
    table: "review_queue_items",
    column: "completed_run_id",
    sql: "ALTER TABLE review_queue_items ADD COLUMN completed_run_id TEXT"
  },
  {
    table: "review_queue_items",
    column: "last_error",
    sql: "ALTER TABLE review_queue_items ADD COLUMN last_error TEXT"
  },
  {
    table: "review_queue_items",
    column: "attempt_count",
    sql: "ALTER TABLE review_queue_items ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0"
  },
  {
    table: "review_queue_items",
    column: "retry_count",
    sql: "ALTER TABLE review_queue_items ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0"
  },
  {
    table: "review_runs",
    column: "status",
    sql: "ALTER TABLE review_runs ADD COLUMN status TEXT NOT NULL DEFAULT 'started'"
  },
  {
    table: "review_runs",
    column: "phase",
    sql: "ALTER TABLE review_runs ADD COLUMN phase TEXT"
  },
  {
    table: "review_runs",
    column: "iteration",
    sql: "ALTER TABLE review_runs ADD COLUMN iteration INTEGER"
  },
  {
    table: "review_runs",
    column: "kind",
    sql: "ALTER TABLE review_runs ADD COLUMN kind TEXT"
  },
  {
    table: "review_runs",
    column: "consumer",
    sql: "ALTER TABLE review_runs ADD COLUMN consumer TEXT"
  },
  {
    table: "review_runs",
    column: "reviewer",
    sql: "ALTER TABLE review_runs ADD COLUMN reviewer TEXT"
  },
  {
    table: "review_runs",
    column: "file_count",
    sql: "ALTER TABLE review_runs ADD COLUMN file_count INTEGER NOT NULL DEFAULT 0"
  },
  {
    table: "review_runs",
    column: "files_json",
    sql: "ALTER TABLE review_runs ADD COLUMN files_json TEXT NOT NULL DEFAULT '[]'"
  },
  {
    table: "review_runs",
    column: "findings_json",
    sql: "ALTER TABLE review_runs ADD COLUMN findings_json TEXT NOT NULL DEFAULT '[]'"
  },
  {
    table: "review_runs",
    column: "summary",
    sql: "ALTER TABLE review_runs ADD COLUMN summary TEXT"
  },
  {
    table: "review_runs",
    column: "result_summary",
    sql: "ALTER TABLE review_runs ADD COLUMN result_summary TEXT"
  },
  {
    table: "review_runs",
    column: "blocker_summary",
    sql: "ALTER TABLE review_runs ADD COLUMN blocker_summary TEXT"
  },
  {
    table: "review_runs",
    column: "report_body",
    sql: "ALTER TABLE review_runs ADD COLUMN report_body TEXT"
  },
  {
    table: "review_runs",
    column: "report_hash",
    sql: "ALTER TABLE review_runs ADD COLUMN report_hash TEXT"
  },
  {
    table: "review_runs",
    column: "error_message",
    sql: "ALTER TABLE review_runs ADD COLUMN error_message TEXT"
  },
  {
    table: "review_runs",
    column: "metadata_json",
    sql: "ALTER TABLE review_runs ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'"
  },
  {
    table: "review_runs",
    column: "started_at",
    sql: `ALTER TABLE review_runs ADD COLUMN started_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  },
  {
    table: "review_runs",
    column: "completed_at",
    sql: "ALTER TABLE review_runs ADD COLUMN completed_at TEXT"
  },
  {
    table: "review_runs",
    column: "created_at",
    sql: `ALTER TABLE review_runs ADD COLUMN created_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  },
  {
    table: "review_runs",
    column: "updated_at",
    sql: `ALTER TABLE review_runs ADD COLUMN updated_at TEXT NOT NULL DEFAULT '${LEGACY_TIMESTAMP_FALLBACK}'`
  }
];

const REQUIRED_TABLE_COLUMNS: Array<{ table: string; columns: string[] }> = [
  {
    table: "projects",
    columns: ["id", "name", "root_path", "created_at", "updated_at"]
  },
  {
    table: "components",
    columns: [
      "id",
      "project_id",
      "semantic_id",
      "name",
      "module",
      "file_path",
      "kind",
      "exports",
      "imports",
      "hash",
      "figma_ref",
      "status",
      "inactive_reason",
      "security_level",
      "idem",
      "updated_at"
    ]
  },
  {
    table: "registry_deltas",
    columns: ["id", "project_id", "idempotency_key", "delta_type", "semantic_id", "payload", "applied_at"]
  },
  {
    table: "capsules",
    columns: ["id", "project_id", "task_id", "phase", "content", "token_count", "created_at"]
  },
  {
    table: "outbox_queue",
    columns: ["id", "project_id", "event_type", "payload", "status", "created_at"]
  },
  {
    table: "review_queue_items",
    columns: [
      "id",
      "project_id",
      "event_id",
      "dedupe_key",
      "file_path",
      "queue_state",
      "first_enqueued_at",
      "last_enqueued_at",
      "last_enqueue_source",
      "payload",
      "lease_run_id",
      "lease_event_id",
      "lease_owner",
      "leased_at",
      "lease_expires_at",
      "acknowledged_at",
      "completed_at",
      "completed_run_id",
      "last_error",
      "attempt_count",
      "retry_count"
    ]
  },
  {
    table: "review_runs",
    columns: [
      "id",
      "project_id",
      "run_id",
      "status",
      "phase",
      "iteration",
      "kind",
      "consumer",
      "reviewer",
      "file_count",
      "files_json",
      "findings_json",
      "summary",
      "result_summary",
      "blocker_summary",
      "report_body",
      "report_hash",
      "error_message",
      "metadata_json",
      "started_at",
      "completed_at",
      "created_at",
      "updated_at"
    ]
  }
];

const REQUIRED_TABLE_STRUCTURES: TableStructureDefinition[] = [
  {
    table: "registry_deltas",
    requiredFragments: [
      "applied_at text not null default (datetime('now'))",
      "unique(project_id, idempotency_key)"
    ]
  },
  {
    table: "review_queue_items",
    requiredFragments: [
      "unique(project_id, file_path)",
      "check(queue_state in ('pending', 'leased', 'done'))"
    ]
  },
  {
    table: "review_runs",
    requiredFragments: [
      "unique(project_id, run_id)",
      "check(status in ('started', 'completed', 'failed'))"
    ]
  }
];

export function runMigrations(db: Database.Database): MigrationResult {
  try {
    if (getSchemaVersion(db) === CURRENT_SCHEMA_VERSION && isCurrentSchema(db)) {
      return {
        path: "fast-path",
        schemaVersion: CURRENT_SCHEMA_VERSION
      };
    }

    db.exec(SCHEMA_SQL);
    for (const definition of COLUMN_DEFINITIONS) {
      ensureColumn(db, definition.table, definition.column, definition.sql);
    }
    backfillLegacyReviewQueueColumns(db);
    backfillLegacyReviewRunColumns(db);
    repairKnownLegacyTableStructures(db);
    ensureIndexes(db);
    if (
      !hasRequiredTablesAndColumns(db) ||
      !hasRequiredTableStructures(db) ||
      !hasRequiredIndexes(db) ||
      !hasBackfilledLegacyData(db)
    ) {
      setSchemaVersion(db, 0);
      throw new Error("durable schema validation failed after migration");
    }

    setSchemaVersion(db, CURRENT_SCHEMA_VERSION);
    return {
      path: "full",
      schemaVersion: getSchemaVersion(db)
    };
  } catch (error) {
    throw new Error(`Failed to run migrations: ${toErrorMessage(error)}`);
  }
}

export function listTables(db: Database.Database): string[] {
  try {
    const rows = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
      .all() as Array<{ name: string }>;

    return rows
      .map((row) => row.name)
      .filter((name) => !name.startsWith("sqlite_"));
  } catch (error) {
    throw new Error(`Failed to list tables: ${toErrorMessage(error)}`);
  }
}

export function assertRequiredTables(db: Database.Database): string[] {
  try {
    const existing = new Set(listTables(db));
    const missing = REQUIRED_TABLES.filter((table) => !existing.has(table));

    if (missing.length > 0) {
      throw new Error(`Missing tables: ${missing.join(", ")}`);
    }

    return [...REQUIRED_TABLES];
  } catch (error) {
    throw new Error(`Required table check failed: ${toErrorMessage(error)}`);
  }
}

function ensureColumn(
  db: Database.Database,
  tableName: string,
  columnName: string,
  alterSql: string
): void {
  if (getTableColumns(db, tableName).includes(columnName)) {
    return;
  }

  db.exec(alterSql);
}

function backfillLegacyReviewQueueColumns(db: Database.Database): void {
  if (hasColumns(db, "review_queue_items", ["file_path", "dedupe_key"])) {
    db.prepare(
      `
        UPDATE review_queue_items
        SET dedupe_key = file_path
        WHERE dedupe_key IS NULL
      `
    ).run();
  }

  if (hasColumns(db, "review_queue_items", ["retry_count"])) {
    db.prepare(
      `
        UPDATE review_queue_items
        SET retry_count = 0
        WHERE retry_count IS NULL
      `
    ).run();
  }
}

function backfillLegacyReviewRunColumns(db: Database.Database): void {
  if (hasColumns(db, "review_runs", ["summary", "result_summary"])) {
    db.prepare(
      `
        UPDATE review_runs
        SET result_summary = summary
        WHERE result_summary IS NULL
          AND summary IS NOT NULL
      `
    ).run();
  }
}

function repairKnownLegacyTableStructures(db: Database.Database): void {
  repairLegacyReviewQueueItems(db);
  repairLegacyReviewRuns(db);
}

function repairLegacyReviewQueueItems(db: Database.Database): void {
  if (hasRequiredTableStructure(db, "review_queue_items")) {
    return;
  }
  if (!hasColumns(db, "review_queue_items", ["id", "project_id", "file_path"])) {
    return;
  }

  rebuildTable(db, {
    table: "review_queue_items",
    createSql: `
      CREATE TABLE review_queue_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL,
        event_id TEXT,
        dedupe_key TEXT,
        file_path TEXT NOT NULL,
        queue_state TEXT NOT NULL DEFAULT 'pending',
        first_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        last_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
        payload TEXT NOT NULL DEFAULT '{}',
        lease_run_id TEXT,
        lease_event_id TEXT,
        lease_owner TEXT,
        leased_at TEXT,
        lease_expires_at TEXT,
        acknowledged_at TEXT,
        completed_at TEXT,
        completed_run_id TEXT,
        last_error TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(project_id, file_path),
        CHECK(queue_state IN ('pending', 'leased', 'done'))
      )
    `,
    columns: [
      ["id", "id"],
      ["project_id", "project_id"],
      ["event_id", "NULL"],
      ["dedupe_key", "COALESCE(dedupe_key, file_path)"],
      ["file_path", "file_path"],
      ["queue_state", "'pending'"],
      ["first_enqueued_at", `'${LEGACY_TIMESTAMP_FALLBACK}'`],
      ["last_enqueued_at", `'${LEGACY_TIMESTAMP_FALLBACK}'`],
      ["last_enqueue_source", "'unknown'"],
      ["payload", "'{}'"],
      ["lease_run_id", "NULL"],
      ["lease_event_id", "NULL"],
      ["lease_owner", "NULL"],
      ["leased_at", "NULL"],
      ["lease_expires_at", "NULL"],
      ["acknowledged_at", "NULL"],
      ["completed_at", "NULL"],
      ["completed_run_id", "NULL"],
      ["last_error", "NULL"],
      ["attempt_count", "0"],
      ["retry_count", "0"]
    ]
  });
}

function repairLegacyReviewRuns(db: Database.Database): void {
  if (hasRequiredTableStructure(db, "review_runs")) {
    return;
  }
  if (!hasColumns(db, "review_runs", ["id", "project_id", "run_id"])) {
    return;
  }

  rebuildTable(db, {
    table: "review_runs",
    createSql: `
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
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(project_id, run_id),
        CHECK(status IN ('started', 'completed', 'failed'))
      )
    `,
    columns: [
      ["id", "id"],
      ["project_id", "project_id"],
      ["run_id", "run_id"],
      ["status", "'started'"],
      ["phase", "NULL"],
      ["iteration", "NULL"],
      ["kind", "NULL"],
      ["consumer", "NULL"],
      ["reviewer", "NULL"],
      ["file_count", "0"],
      ["files_json", "'[]'"],
      ["findings_json", "'[]'"],
      ["summary", "NULL"],
      ["result_summary", hasColumns(db, "review_runs", ["summary"]) ? "summary" : "NULL"],
      ["blocker_summary", "NULL"],
      ["report_body", "NULL"],
      ["report_hash", "NULL"],
      ["error_message", "NULL"],
      ["metadata_json", "'{}'"],
      ["started_at", `'${LEGACY_TIMESTAMP_FALLBACK}'`],
      ["completed_at", "NULL"],
      ["created_at", `'${LEGACY_TIMESTAMP_FALLBACK}'`],
      ["updated_at", `'${LEGACY_TIMESTAMP_FALLBACK}'`]
    ]
  });
}

function rebuildTable(
  db: Database.Database,
  definition: {
    table: string;
    createSql: string;
    columns: Array<[string, string]>;
  }
): void {
  const legacyTable = `${definition.table}__legacy_rebuild`;
  const existingColumns = new Set(getTableColumns(db, definition.table));
  const insertColumns = definition.columns.map(([column]) => column);
  const selectExpressions = definition.columns.map(([column, fallback]) => {
    if (existingColumns.has(column)) {
      return quoteIdentifier(column);
    }
    return `${fallback} AS ${quoteIdentifier(column)}`;
  });

  db.exec(`
    ALTER TABLE ${quoteIdentifier(definition.table)}
      RENAME TO ${quoteIdentifier(legacyTable)};
  `);

  try {
    db.exec(definition.createSql);
    db.exec(`
      INSERT INTO ${quoteIdentifier(definition.table)}
        (${insertColumns.map(quoteIdentifier).join(", ")})
      SELECT ${selectExpressions.join(", ")}
      FROM ${quoteIdentifier(legacyTable)}
    `);
    db.exec(`DROP TABLE ${quoteIdentifier(legacyTable)}`);
  } catch (error) {
    db.exec(`DROP TABLE IF EXISTS ${quoteIdentifier(definition.table)}`);
    db.exec(`
      ALTER TABLE ${quoteIdentifier(legacyTable)}
        RENAME TO ${quoteIdentifier(definition.table)};
    `);
    throw error;
  }
}

function ensureIndexes(db: Database.Database): void {
  for (const definition of INDEX_DEFINITIONS) {
    ensureIndex(db, definition);
  }
}

function ensureIndex(db: Database.Database, definition: IndexDefinition): void {
  if (!tableExists(db, definition.table)) {
    return;
  }

  const columns = new Set(getTableColumns(db, definition.table));
  const missingColumns = definition.requiredColumns.filter((column) => !columns.has(column));
  if (missingColumns.length > 0) {
    throw new Error(
      `Cannot create index ${definition.name}: missing columns ${missingColumns
        .map((column) => `${definition.table}.${column}`)
        .join(", ")}`
    );
  }

  const existing = db
    .prepare(
      `
        SELECT sql
        FROM sqlite_master
        WHERE type = 'index' AND name = ?
        LIMIT 1
      `
    )
    .get(definition.name) as { sql: string | null } | undefined;

  if (existing && normalizeSql(existing.sql) !== normalizeSql(definition.sql)) {
    db.exec(`DROP INDEX ${quoteIdentifier(definition.name)}`);
  }

  db.exec(definition.sql);
}

function quoteIdentifier(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}

function getSchemaVersion(db: Database.Database): number {
  return db.pragma("user_version", { simple: true }) as number;
}

function setSchemaVersion(db: Database.Database, version: number): void {
  db.pragma(`user_version = ${version}`);
}

function isCurrentSchema(db: Database.Database): boolean {
  if (!hasRequiredTablesAndColumns(db)) {
    return false;
  }

  if (!hasRequiredTableStructures(db)) {
    return false;
  }

  if (!hasRequiredIndexes(db)) {
    return false;
  }

  return hasBackfilledLegacyData(db);
}

function hasRequiredTablesAndColumns(db: Database.Database): boolean {
  return REQUIRED_TABLE_COLUMNS.every(({ table, columns }) =>
    tableExists(db, table) && hasColumns(db, table, columns)
  );
}

function hasRequiredIndexes(db: Database.Database): boolean {
  return INDEX_DEFINITIONS.every((definition) => {
    const row = db
      .prepare(
        `
          SELECT sql
          FROM sqlite_master
          WHERE type = 'index' AND name = ?
          LIMIT 1
        `
      )
      .get(definition.name) as { sql: string | null } | undefined;

    return normalizeSql(row?.sql) === normalizeSql(definition.sql);
  });
}

function hasRequiredTableStructures(db: Database.Database): boolean {
  return REQUIRED_TABLE_STRUCTURES.every((definition) =>
    hasRequiredTableStructure(db, definition.table)
  );
}

function hasRequiredTableStructure(db: Database.Database, tableName: string): boolean {
  const definition = REQUIRED_TABLE_STRUCTURES.find((entry) => entry.table === tableName);
  if (!definition) {
    return true;
  }

  const row = db
    .prepare(
      `
        SELECT sql
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1
      `
    )
    .get(definition.table) as { sql: string | null } | undefined;
  const normalized = normalizeSql(row?.sql);
  return definition.requiredFragments.every((fragment) =>
    normalized.includes(normalizeSql(fragment))
  );
}

function hasBackfilledLegacyData(db: Database.Database): boolean {
  const dedupeNullCount = db
    .prepare(
      `
        SELECT COUNT(*) AS count
        FROM review_queue_items
        WHERE dedupe_key IS NULL
      `
    )
    .get() as { count: number };
  if (dedupeNullCount.count > 0) {
    return false;
  }

  const retryNullCount = db
    .prepare(
      `
        SELECT COUNT(*) AS count
        FROM review_queue_items
        WHERE retry_count IS NULL
      `
    )
    .get() as { count: number };
  if (retryNullCount.count > 0) {
    return false;
  }

  const resultSummaryNullCount = db
    .prepare(
      `
        SELECT COUNT(*) AS count
        FROM review_runs
        WHERE result_summary IS NULL
          AND summary IS NOT NULL
      `
    )
    .get() as { count: number };
  return resultSummaryNullCount.count === 0;
}

function normalizeSql(sql: string | null | undefined): string {
  return (sql ?? "")
    .replace(/\bif not exists\b/gi, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function tableExists(db: Database.Database, tableName: string): boolean {
  const row = db
    .prepare(
      `
        SELECT 1 AS found
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1
      `
    )
    .get(tableName) as { found: 1 } | undefined;

  return row?.found === 1;
}

function hasColumns(db: Database.Database, tableName: string, columns: string[]): boolean {
  const existingColumns = new Set(getTableColumns(db, tableName));
  return columns.every((column) => existingColumns.has(column));
}

function getTableColumns(db: Database.Database, tableName: string): string[] {
  return (db.prepare(`PRAGMA table_info(${tableName})`).all() as Array<{ name: string }>).map(
    (column) => column.name
  );
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
