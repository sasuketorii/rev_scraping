import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { closeDatabase, openDatabase, type DatabaseContext } from "./db/connection.js";
import { runMigrations } from "./db/migrations.js";
import {
  completeReviewQueueLease,
  enqueueReviewQueueItem,
  exportReviewQueueJson,
  leaseReviewQueueItems,
  requeueReviewQueueLease
} from "./db/review-queue.js";
import {
  parseReviewRunRecordInput,
  recordReviewRun
} from "./db/review-runs.js";
import { validateProjectId } from "./utils/project-id.js";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface CliDependencies {
  openDatabase(projectId: string, repoRoot?: string): DatabaseContext;
  closeDatabase(context: DatabaseContext): void;
  runMigrations(db: DatabaseContext["db"]): void;
  readFile(path: string): string;
  ensureDirectory(path: string): void;
  writeFile(path: string, contents: string): void;
  stdout(text: string): void;
  stderr(text: string): void;
}

const DEFAULT_DEPENDENCIES: CliDependencies = {
  openDatabase,
  closeDatabase,
  runMigrations,
  readFile: (path) => readFileSync(path, "utf8"),
  ensureDirectory: (path) => mkdirSync(path, { recursive: true }),
  writeFile: (path, contents) => writeFileSync(path, contents, "utf8"),
  stdout: (text) => process.stdout.write(text),
  stderr: (text) => process.stderr.write(text)
};

export function runCli(argv: string[], dependencies: CliDependencies = DEFAULT_DEPENDENCIES): void {
  if (argv.length < 2) {
    throw new Error("expected <group> <command>");
  }

  const [group, command, ...rest] = argv;
  switch (`${group} ${command}`) {
    case "project-id validate":
      handleProjectIdValidate(rest, dependencies);
      return;
    case "queue enqueue":
      handleQueueEnqueue(rest, dependencies);
      return;
    case "queue lease":
      handleQueueLease(rest, dependencies);
      return;
    case "queue drain":
      handleQueueLease(rest, dependencies);
      return;
    case "queue complete":
      handleQueueComplete(rest, dependencies);
      return;
    case "queue requeue":
      handleQueueRequeue(rest, dependencies);
      return;
    case "queue export-json":
      handleQueueExportJson(rest, dependencies);
      return;
    case "review-run record":
      handleReviewRunRecord(rest, dependencies);
      return;
    default:
      throw new Error(`unknown command: ${group} ${command}`);
  }
}

function handleProjectIdValidate(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlags(argv, ["--value"], ["--value"]);
  writeJson(dependencies, {
    ok: true,
    project_id: validateProjectId(flags["--value"])
  });
}

function handleQueueEnqueue(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlags(
    argv,
    ["--project-id", "--file-path", "--source", "--repo-root", "--export-json"],
    ["--project-id", "--file-path", "--repo-root"]
  );
  const exportPath = flags["--export-json"] ? resolveOutputPath(flags["--export-json"]) : undefined;

  const result = withDatabase(dependencies, flags["--project-id"], (context) => {
    const enqueueResult = enqueueReviewQueueItem(context.db, {
      projectId: context.projectId,
      repoRoot: context.repoRoot ?? flags["--repo-root"],
      filePath: flags["--file-path"],
      source: flags["--source"]
    });

    if (exportPath) {
      writeQueueSnapshot(
        dependencies,
        exportPath,
        exportReviewQueueJson(context.db, context.projectId)
      );
    }

    return enqueueResult;
  },
    flags["--repo-root"]
  );

  writeJson(dependencies, result);
}

function handleQueueLease(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlags(
    argv,
    ["--project-id", "--lease-seconds", "--lease-run-id"],
    ["--project-id"]
  );
  const result = withDatabase(dependencies, flags["--project-id"], (context) =>
    leaseReviewQueueItems(context.db, {
      projectId: context.projectId,
      leaseRunId: flags["--lease-run-id"],
      leaseSeconds: parseOptionalInteger(flags["--lease-seconds"], "--lease-seconds")
    })
  );

  writeJson(dependencies, {
    ...result,
    lease_run_id: flags["--lease-run-id"] ?? null,
    expected_files: result.items.map((item) => item.file_path)
  });
}

function handleQueueComplete(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlagsWithRepeats(
    argv,
    ["--project-id", "--lease-owner", "--lease-run-id", "--expected-file"],
    ["--project-id", "--lease-owner"],
    ["--expected-file"]
  );
  const expectedFiles = requireRepeatedFlag(
    flags.repeated,
    "--expected-file",
    "queue complete requires strict expected files via --expected-file"
  );
  const result = withDatabase(dependencies, flags.values["--project-id"], (context) =>
    completeReviewQueueLease(context.db, {
      projectId: context.projectId,
      leaseOwner: flags.values["--lease-owner"],
      leaseRunId: flags.values["--lease-run-id"],
      expectedFiles
    })
  );

  writeJson(dependencies, result);
}

function handleQueueRequeue(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlagsWithRepeats(
    argv,
    ["--project-id", "--lease-owner", "--lease-run-id", "--expected-file", "--error"],
    ["--project-id", "--lease-owner"],
    ["--expected-file"]
  );
  const expectedFiles = requireRepeatedFlag(
    flags.repeated,
    "--expected-file",
    "queue requeue requires strict expected files via --expected-file"
  );
  const result = withDatabase(dependencies, flags.values["--project-id"], (context) =>
    requeueReviewQueueLease(context.db, {
      projectId: context.projectId,
      leaseOwner: flags.values["--lease-owner"],
      leaseRunId: flags.values["--lease-run-id"],
      expectedFiles,
      errorMessage: flags.values["--error"]
    })
  );

  writeJson(dependencies, result);
}

function handleQueueExportJson(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlags(
    argv,
    ["--project-id", "--output"],
    ["--project-id", "--output"]
  );
  const outputPath = resolveOutputPath(flags["--output"]);
  const snapshot = withDatabase(dependencies, flags["--project-id"], (context) =>
    exportReviewQueueJson(context.db, context.projectId)
  );

  writeQueueSnapshot(dependencies, outputPath, snapshot);

  writeJson(dependencies, {
    project_id: snapshot.project_id,
    output: outputPath,
    pending_count: snapshot.pending_count,
    leased_count: snapshot.leased_count
  });
}

function writeQueueSnapshot(
  dependencies: CliDependencies,
  outputPath: string,
  snapshot: ReturnType<typeof exportReviewQueueJson>
): void {
  dependencies.ensureDirectory(dirname(outputPath));
  dependencies.writeFile(outputPath, JSON.stringify(snapshot, null, 2));
}

function handleReviewRunRecord(argv: string[], dependencies: CliDependencies): void {
  const flags = parseFlags(
    argv,
    ["--project-id", "--input"],
    ["--project-id", "--input"]
  );
  const payload = readJsonFile(flags["--input"], dependencies);
  const parsed = parseReviewRunRecordInput(payload);
  const result = withDatabase(dependencies, flags["--project-id"], (context) =>
    recordReviewRun(context.db, context.projectId, parsed)
  );

  writeJson(dependencies, result);
}

function withDatabase<T>(
  dependencies: CliDependencies,
  projectId: string,
  fn: (context: DatabaseContext) => T,
  repoRoot?: string
): T {
  const context = dependencies.openDatabase(validateProjectId(projectId), repoRoot);
  try {
    dependencies.runMigrations(context.db);
    return fn(context);
  } finally {
    dependencies.closeDatabase(context);
  }
}

function readJsonFile(path: string, dependencies: CliDependencies): JsonValue {
  const raw = dependencies.readFile(path);
  try {
    return JSON.parse(raw) as JsonValue;
  } catch (error) {
    throw new Error(`failed to parse JSON input: ${toErrorMessage(error)}`);
  }
}

function resolveOutputPath(outputPath: string): string {
  const normalized = outputPath.trim();
  if (normalized.length === 0) {
    throw new Error("output must not be empty");
  }

  return resolve(normalized);
}

function parseFlags(
  argv: string[],
  allowedFlags: string[],
  requiredFlags: string[]
): Record<string, string> {
  return parseFlagsWithRepeats(argv, allowedFlags, requiredFlags).values;
}

function parseFlagsWithRepeats(
  argv: string[],
  allowedFlags: string[],
  requiredFlags: string[],
  repeatableFlags: string[] = []
): {
  values: Record<string, string>;
  repeated: Record<string, string[]>;
} {
  const allowed = new Set(allowedFlags);
  const repeatable = new Set(repeatableFlags);
  const parsed: Record<string, string> = {};
  const repeated: Record<string, string[]> = {};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      throw new Error(`unexpected positional argument: ${token}`);
    }

    if (!allowed.has(token)) {
      throw new Error(`unknown flag: ${token}`);
    }

    if (!repeatable.has(token) && parsed[token] !== undefined) {
      throw new Error(`duplicate flag: ${token}`);
    }

    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`missing value for ${token}`);
    }

    if (repeatable.has(token)) {
      repeated[token] ??= [];
      repeated[token].push(value);
    } else {
      if (parsed[token] !== undefined) {
        throw new Error(`duplicate flag: ${token}`);
      }

      parsed[token] = value;
    }
    index += 1;
  }

  for (const required of requiredFlags) {
    if (parsed[required] === undefined) {
      throw new Error(`missing required flag: ${required}`);
    }
  }

  return {
    values: parsed,
    repeated
  };
}

function requireRepeatedFlag(
  repeated: Record<string, string[]>,
  flag: string,
  message: string
): string[] {
  const values = repeated[flag];
  if (!values || values.length === 0) {
    throw new Error(message);
  }

  return values;
}

function writeJson(dependencies: CliDependencies, payload: unknown): void {
  dependencies.stdout(`${JSON.stringify(payload, null, 2)}\n`);
}

function parseOptionalInteger(value: string | undefined, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (!/^[+-]?\d+$/.test(value)) {
    throw new Error(`${field} must be an integer`);
  }

  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed)) {
    throw new Error(`${field} must be an integer`);
  }

  return parsed;
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

function main(): void {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    DEFAULT_DEPENDENCIES.stderr(`[semantic-mcp-cli] ${toErrorMessage(error)}\n`);
    process.exit(1);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main();
}
