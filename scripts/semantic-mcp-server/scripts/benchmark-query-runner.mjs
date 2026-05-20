#!/usr/bin/env node
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const require = createRequire(import.meta.url);
const Database = require("better-sqlite3");

const args = parseArgs(process.argv.slice(2));
const fixtureRoot = resolve(args.fixture);
const mode = args.mode;
const tempDir = mkdtempSync(join(tmpdir(), "semantic-index-benchmark-"));
const dbPath = join(tempDir, "semantic.db");

try {
  const db = new Database(dbPath);
  setupSchema(db);
  const datasetCardinality = seedComponents(db, join(fixtureRoot, "seed.components.jsonl"));
  const result = mode === "compare"
    ? runComparison(db, datasetCardinality)
    : runSingleQuery(db, mode, datasetCardinality);
  db.close();
  process.stdout.write(`${JSON.stringify(result)}\n`);
} finally {
  rmSync(tempDir, { recursive: true, force: true });
}

function parseArgs(argv) {
  const parsed = {
    fixture: "",
    mode: ""
  };

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    const next = argv[index + 1];
    if (current === "--fixture") {
      parsed.fixture = requireValue(current, next);
      index += 1;
      continue;
    }
    if (current === "--mode") {
      parsed.mode = requireValue(current, next);
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${current}`);
  }

  if (!parsed.fixture) {
    throw new Error("--fixture is required");
  }
  if (!["partial", "exact", "compare"].includes(parsed.mode)) {
    throw new Error("--mode must be partial, exact, or compare");
  }

  return parsed;
}

function requireValue(flag, value) {
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function setupSchema(db) {
  db.exec(`
    CREATE TABLE components (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id TEXT NOT NULL,
      semantic_id TEXT NOT NULL,
      name TEXT NOT NULL,
      module TEXT NOT NULL,
      file_path TEXT NOT NULL,
      kind TEXT NOT NULL,
      exports TEXT DEFAULT '[]',
      imports TEXT DEFAULT '[]',
      hash TEXT NOT NULL,
      figma_ref TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      inactive_reason TEXT,
      security_level TEXT,
      idem TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(project_id, semantic_id)
    );
    CREATE INDEX idx_components_project_file_path
      ON components(project_id, file_path, semantic_id ASC);
    CREATE INDEX idx_components_project_name_status_updated
      ON components(project_id, name, status, updated_at DESC, semantic_id ASC);
  `);
}

function seedComponents(db, seedPath) {
  const insert = db.prepare(`
    INSERT INTO components (
      project_id,
      semantic_id,
      name,
      module,
      file_path,
      kind,
      exports,
      imports,
      hash,
      status,
      idem,
      updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, '[]', '[]', ?, ?, ?, ?)
  `);
  const transaction = db.transaction((rows) => {
    for (const row of rows) {
      insert.run(
        row.project_id,
        row.semantic_id,
        row.name,
        row.module,
        row.file_path,
        row.kind,
        row.hash,
        row.status,
        row.idem,
        row.updated_at
      );
    }
  });
  const rows = parseJsonl(seedPath);
  transaction(rows);
  return rows.length;
}

function parseJsonl(path) {
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
}

function runSingleQuery(db, mode, datasetCardinality) {
  const querySpec = JSON.parse(
    readFileSync(join(fixtureRoot, `query_${mode}.json`), "utf8")
  );
  const result = measureQuery(db, mode, querySpec);

  return {
    mode,
    dataset_cardinality: datasetCardinality,
    query_path_only: true,
    ...result
  };
}

function runComparison(db, datasetCardinality) {
  const partialSpec = JSON.parse(readFileSync(join(fixtureRoot, "query_partial.json"), "utf8"));
  const exactSpec = JSON.parse(readFileSync(join(fixtureRoot, "query_exact.json"), "utf8"));
  const partial = measureQuery(db, "partial", partialSpec);
  const exact = measureQuery(db, "exact", exactSpec);

  return {
    mode: "compare",
    same_process_pid: process.pid,
    same_dataset: true,
    dataset_cardinality: datasetCardinality,
    result_cardinality_match: partial.total === exact.total,
    partial,
    exact
  };
}

function measureQuery(db, mode, querySpec) {
  const projectId = readRequiredString(querySpec, "project_id");
  const limit = Number.isInteger(querySpec.limit) ? querySpec.limit : 8;
  let rows;

  const started = process.hrtime.bigint();
  if (mode === "exact") {
    const semanticId = readRequiredString(querySpec, "semantic_id");
    const nameExact = readRequiredString(querySpec, "name_exact");
    rows = db.prepare(`
      SELECT semantic_id, file_path, name, kind
      FROM components
      WHERE project_id = ? AND semantic_id = ? AND name = ?
      ORDER BY updated_at DESC, semantic_id ASC
      LIMIT ?
    `).all(projectId, semanticId, nameExact, limit);
  } else {
    const namePartial = readRequiredString(querySpec, "name_partial");
    rows = db.prepare(`
      SELECT semantic_id, file_path, name, kind
      FROM components
      WHERE project_id = ? AND name LIKE ?
      ORDER BY updated_at DESC, semantic_id ASC
      LIMIT ?
    `).all(projectId, `%${namePartial}%`, limit);
  }
  const elapsedNs = process.hrtime.bigint() - started;

  return {
    mode,
    total: rows.length,
    elapsed_ns: elapsedNs.toString(),
    semantic_ids: rows.map((row) => row.semantic_id)
  };
}

function readRequiredString(payload, key) {
  const value = payload[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${key} is required`);
  }
  return value;
}
