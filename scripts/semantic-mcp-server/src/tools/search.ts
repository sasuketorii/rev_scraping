import {
  existsSync,
  lstatSync,
  readdirSync,
  readFileSync,
  realpathSync
} from "node:fs";
import { relative, resolve } from "node:path";
import type { DatabaseContext } from "../db/connection.js";
import {
  SEARCH_ALLOWED_KEYS,
  type SearchItem,
  type SearchResponse
} from "../types.js";

const MAX_LIMIT = 10;
const DEFAULT_LIMIT = 8;
const MAX_CAPSULE_BUDGET_TOKENS = 200;
const DEFAULT_CAPSULE_BUDGET_TOKENS = 120;
const MAX_EXCERPT_CHARS = 80;
const MAX_SCOPE_PATHS = 40;
const MAX_FILES_PER_SEARCH = 40;
const MAX_SEARCH_FILE_BYTES = 256 * 1024;
const SKIP_DIRS = new Set([".git", "node_modules", "target", "dist", ".claude"]);

interface JsonObject {
  [key: string]: unknown;
}

interface NormalizedSearchInput {
  projectId: string;
  query: string;
  scopePaths: string[];
  kind?: string;
  limit: number;
  capsuleBudgetTokens: number;
}

interface RegistryRow {
  semantic_id: string;
  file_path: string;
  name: string;
  kind: string;
}

export function handleSearch(context: DatabaseContext, rawInput: unknown): SearchResponse {
  try {
    const input = normalizeSearchInput(context, rawInput);
    const files = resolveScopeFiles(context, input.scopePaths);
    const registryItems = queryRegistryItems(context, input);
    const filesystemItems = searchFiles(context, files, input.query);
    const merged = mergeSearchItems(registryItems, filesystemItems);
    const sorted = merged.sort(compareSearchItems);
    const limited = sorted.slice(0, input.limit);
    const truncated = sorted.length > limited.length;
    return compactSearchResponse(limited, sorted.length, truncated, input.capsuleBudgetTokens);
  } catch (error) {
    throw new Error(`sem.search failed: ${toErrorMessage(error)}`);
  }
}

function normalizeSearchInput(context: DatabaseContext, rawInput: unknown): NormalizedSearchInput {
  const input = asRequiredObject(rawInput, "search input");
  assertAllowedKeys(input, SEARCH_ALLOWED_KEYS, "search input");
  assertProjectIdMatchesContext(context, input);

  const query = getRequiredString(input, "query");
  const scopePaths = getScopePaths(input);
  const kind = getOptionalString(input, "kind");
  const limit = clamp(parseInteger(input.limit, "limit") ?? DEFAULT_LIMIT, 1, MAX_LIMIT);
  const capsuleBudgetTokens = clamp(
    parseInteger(
      getConsistentOptionalAlias(
        input,
        ["capsule_budget_tokens", "capsuleBudgetTokens"],
        "capsule_budget_tokens/capsuleBudgetTokens"
      ),
      "capsule_budget_tokens"
    ) ?? DEFAULT_CAPSULE_BUDGET_TOKENS,
    1,
    MAX_CAPSULE_BUDGET_TOKENS
  );

  return {
    projectId: context.projectId,
    query,
    scopePaths,
    kind,
    limit,
    capsuleBudgetTokens
  };
}

function getScopePaths(input: JsonObject): string[] {
  const rawValue = getConsistentOptionalAlias(input, ["scope_paths", "scopePaths"], "scope_paths/scopePaths");
  if (!Array.isArray(rawValue) || rawValue.length === 0) {
    throw new Error("scope_paths must be a non-empty array");
  }

  if (rawValue.length > MAX_SCOPE_PATHS) {
    throw new Error(`scope_paths must contain at most ${MAX_SCOPE_PATHS} entries`);
  }

  return rawValue.map((entry, index) => {
    if (typeof entry !== "string" || entry.trim().length === 0) {
      throw new Error(`scope_paths[${index}] must be a non-blank string`);
    }
    const normalized = entry.trim().replace(/\\/g, "/").replace(/^\.\/+/, "").replace(/\/+$/, "");
    if (normalized === "." || normalized === "" || normalized === "*" || normalized === "**") {
      throw new Error("scope_paths must not request broad default scans");
    }
    if (normalized.startsWith("/") || normalized.includes("..")) {
      throw new Error("scope_paths must be repo-relative and must not traverse outside repo root");
    }
    return normalized;
  });
}

function resolveScopeFiles(context: DatabaseContext, scopePaths: string[]): string[] {
  const repoRoot = realpathSync(resolve(context.repoRoot ?? process.cwd()));
  const repoRealPath = realpathSync(repoRoot);
  const files: string[] = [];

  for (const scopePath of scopePaths) {
    const absolutePath = resolve(repoRoot, scopePath);
    const initialStat = lstatSync(absolutePath);
    if (initialStat.isSymbolicLink()) {
      throw new Error("scope_paths must not include symlinks");
    }
    const realPath = realpathSync(absolutePath);
    assertInsideRepo(repoRealPath, realPath, "scope_paths");
    const stat = lstatSync(realPath);

    if (stat.isDirectory()) {
      collectDirectoryFiles(repoRealPath, realPath, files);
      continue;
    }

    if (stat.isFile()) {
      files.push(realPath);
    }
  }

  if (files.length === 0) {
    throw new Error("scope_paths did not resolve to searchable files");
  }

  return [...new Set(files)].sort((left, right) => left.localeCompare(right)).slice(0, MAX_FILES_PER_SEARCH);
}

function collectDirectoryFiles(repoRoot: string, directory: string, files: string[]): void {
  const entries = readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name));

  for (const entry of entries) {
    if (SKIP_DIRS.has(entry.name)) {
      continue;
    }
    if (entry.isSymbolicLink()) {
      throw new Error("scope_paths must not include symlinks");
    }

    const child = resolve(directory, entry.name);
    const initialStat = lstatSync(child);
    if (initialStat.isSymbolicLink()) {
      throw new Error("scope_paths must not include symlinks");
    }
    const childRealPath = realpathSync(child);
    assertInsideRepo(repoRoot, childRealPath, "scope_paths");
    if (entry.isDirectory()) {
      collectDirectoryFiles(repoRoot, childRealPath, files);
    } else if (entry.isFile()) {
      files.push(childRealPath);
    }
  }
}

function queryRegistryItems(context: DatabaseContext, input: NormalizedSearchInput): SearchItem[] {
  const like = `%${escapeLike(input.query)}%`;
  const scopeClauses = input.scopePaths.map(() => "(file_path = ? OR file_path LIKE ? ESCAPE '\\')");
  const whereClauses = [
    "project_id = ?",
    "status != 'deleted'",
    "(name LIKE ? ESCAPE '\\' OR semantic_id LIKE ? ESCAPE '\\' OR file_path LIKE ? ESCAPE '\\')",
    `(${scopeClauses.join(" OR ")})`
  ];
  const params: unknown[] = [context.projectId, like, like, like];

  for (const scopePath of input.scopePaths) {
    params.push(scopePath, `${escapeLike(scopePath.replace(/\/+$/, ""))}/%`);
  }

  if (input.kind) {
    whereClauses.push("kind = ?");
    params.push(input.kind);
  }

  const rows = context.db
    .prepare(
      `
      SELECT semantic_id, file_path, name, kind
      FROM components
      WHERE ${whereClauses.join(" AND ")}
      ORDER BY updated_at DESC, semantic_id ASC
      LIMIT ?
    `
    )
    .all(...params, MAX_LIMIT) as RegistryRow[];

  return rows.map((row) => ({
    path: row.file_path,
    semantic_id: row.semantic_id,
    symbol: row.name,
    kind: row.kind,
    source: "registry"
  }));
}

function searchFiles(context: DatabaseContext, files: string[], query: string): SearchItem[] {
  const needle = query.toLowerCase();
  const items: SearchItem[] = [];
  const repoRoot = realpathSync(resolve(context.repoRoot ?? process.cwd()));

  for (const file of files) {
    if (!existsSync(file)) {
      continue;
    }

    const stat = lstatSync(file);
    if (stat.size > MAX_SEARCH_FILE_BYTES) {
      continue;
    }

    const bytes = readFileSync(file);
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let content: string;
    try {
      content = decoder.decode(bytes);
    } catch {
      continue;
    }
    const lines = content.split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (!line.toLowerCase().includes(needle)) {
        continue;
      }
      items.push({
        path: toRepoRelative(repoRoot, file),
        line: index + 1,
        excerpt: truncate(line.trim(), MAX_EXCERPT_CHARS),
        source: "filesystem"
      });
      break;
    }
  }

  return items;
}

function mergeSearchItems(registryItems: SearchItem[], filesystemItems: SearchItem[]): SearchItem[] {
  const byPath = new Map<string, SearchItem>();
  for (const item of registryItems) {
    byPath.set(item.path, item);
  }

  for (const item of filesystemItems) {
    const existing = byPath.get(item.path);
    if (existing) {
      byPath.set(item.path, {
        ...existing,
        line: item.line,
        excerpt: item.excerpt,
        source: "registry+filesystem"
      });
      continue;
    }
    byPath.set(item.path, item);
  }

  return [...byPath.values()];
}

function compactSearchResponse(
  items: SearchItem[],
  total: number,
  truncated: boolean,
  capsuleBudgetTokens: number
): SearchResponse {
  let compactItems = [...items];
  let response = buildSearchResponse(compactItems, total, truncated);
  const charBudget = capsuleBudgetTokens * 3;

  while (compactItems.length > 0 && JSON.stringify(response).length > charBudget) {
    compactItems = compactItems.slice(0, -1);
    response = buildSearchResponse(compactItems, total, true);
  }

  if (JSON.stringify(response).length > charBudget) {
    return buildSearchResponse([], total, true);
  }

  return response;
}

function buildSearchResponse(items: SearchItem[], total: number, truncated: boolean): SearchResponse {
  return {
    items,
    total,
    truncated,
    capsule: `matched:${total} returned:${items.length} truncated:${truncated} advisory_only:true`,
    advisory_only: true
  };
}

function compareSearchItems(left: SearchItem, right: SearchItem): number {
  const leftRegistry = left.source.includes("registry") ? 0 : 1;
  const rightRegistry = right.source.includes("registry") ? 0 : 1;
  if (leftRegistry !== rightRegistry) {
    return leftRegistry - rightRegistry;
  }

  const leftDepth = left.path.split("/").length;
  const rightDepth = right.path.split("/").length;
  if (leftDepth !== rightDepth) {
    return leftDepth - rightDepth;
  }

  return left.path.localeCompare(right.path);
}

function asRequiredObject(value: unknown, label: string): JsonObject {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as JsonObject;
}

function assertAllowedKeys(input: JsonObject, allowedKeys: readonly string[], label: string): void {
  const unexpectedKeys = Object.keys(input).filter((key) => !allowedKeys.includes(key));
  if (unexpectedKeys.length > 0) {
    throw new Error(`${label} contains unexpected keys: ${unexpectedKeys.join(", ")}`);
  }
}

function assertProjectIdMatchesContext(context: DatabaseContext, input: JsonObject): void {
  const projectId = getOptionalString(input, "project_id");
  if (projectId && projectId !== context.projectId) {
    throw new Error(`project_id mismatch: expected ${context.projectId}, received ${projectId}`);
  }
}

function getRequiredString(input: JsonObject, key: string): string {
  const value = getOptionalString(input, key);
  if (!value) {
    throw new Error(`${key} is required`);
  }
  return value;
}

function getOptionalString(input: JsonObject, key: string): string | undefined {
  const value = input[key];
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${key} must be a non-blank string`);
  }
  return value.trim();
}

function getConsistentOptionalAlias(
  input: JsonObject,
  keys: readonly string[],
  label: string
): unknown {
  const present = keys.filter((key) => Object.hasOwn(input, key));
  if (present.length === 0) {
    return undefined;
  }
  const first = input[present[0]];
  for (const key of present.slice(1)) {
    if (JSON.stringify(input[key]) !== JSON.stringify(first)) {
      throw new Error(`${label} aliases must match`);
    }
  }
  return first;
}

function parseInteger(value: unknown, label: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value === "number" && Number.isInteger(value)) {
    return value;
  }
  if (typeof value === "string" && /^-?\d+$/.test(value.trim())) {
    return Number.parseInt(value, 10);
  }
  throw new Error(`${label} must be an integer`);
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function assertInsideRepo(repoRoot: string, target: string, label: string): void {
  const relativePath = relative(repoRoot, target);
  if (relativePath === "" || (!relativePath.startsWith("..") && !relativePath.startsWith("/"))) {
    return;
  }
  throw new Error(`${label} must stay inside repo root`);
}

function toRepoRelative(repoRoot: string, file: string): string {
  return relative(repoRoot, file).replace(/\\/g, "/");
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (match) => `\\${match}`);
}

function truncate(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : value.slice(0, maxChars);
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
