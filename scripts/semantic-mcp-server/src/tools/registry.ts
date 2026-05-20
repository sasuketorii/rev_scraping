import { createHash } from "node:crypto";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { posix, resolve } from "node:path";
import type { DatabaseContext } from "../db/connection.js";
import {
  REGISTRY_COMPONENT_ALLOWED_KEYS,
  REGISTRY_DELETE_ALLOWED_KEYS,
  REGISTRY_DELTA_ALIAS_ALLOWED_KEYS,
  REGISTRY_DELTA_COLLECTION_ALLOWED_KEYS,
  REGISTRY_QUERY_ALLOWED_KEYS,
  REGISTRY_SET_STATUS_ALLOWED_KEYS,
  REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS,
  REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS,
  RegistryDeleteResponse,
  RegistryQueryItem,
  RegistryQueryResponse,
  RegistrySetStatusResponse,
  RegistrySemanticId,
  RegistryUpsertResponse
} from "../types.js";

const MUTABLE_STATUSES = [
  "active",
  "inactive",
  "incomplete",
  "buggy",
  "deprecated"
] as const;
const QUERYABLE_STATUSES = [...MUTABLE_STATUSES, "deleted"] as const;
type MutableStatus = (typeof MUTABLE_STATUSES)[number];
type QueryableStatus = (typeof QUERYABLE_STATUSES)[number];
const MUTABLE_STATUS_SET = new Set<string>(MUTABLE_STATUSES);
const QUERYABLE_STATUS_SET = new Set<string>(QUERYABLE_STATUSES);
const QUERY_RESPONSE_ITEM_LIMIT = 4;
// Conservative estimate for compact JSON/alphanumeric payloads: 200 tokens ~= 600 chars.
const QUERY_RESPONSE_CHAR_BUDGET = 600;
const UPSERT_DELTA_TYPE = "upsert";
const SET_STATUS_DELTA_TYPE = "set_status";
const DELETE_DELTA_TYPE = "delete";
const REGISTRY_UPSERT_TOP_LEVEL_ALLOWED_KEYS = [
  ...REGISTRY_COMPONENT_ALLOWED_KEYS,
  ...REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS,
  ...REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS
];

interface JsonObject {
  [key: string]: unknown;
}

interface NormalizedComponent {
  semantic_id: RegistrySemanticId;
  name: string;
  module: string;
  file_path: string;
  kind: string;
  exports_json: string;
  imports_json: string;
  hash: string;
  figma_ref: string | null;
  status: QueryableStatus;
  inactive_reason: string | null;
  security_level: string | null;
  idem: string;
}

interface ComponentRowSnapshot {
  name: string;
  module: string;
  file_path: string;
  kind: string;
  exports: string;
  imports: string;
  hash: string;
  figma_ref: string | null;
  status: string;
  inactive_reason: string | null;
  security_level: string | null;
  idem: string;
}

interface UpsertDbResult {
  applied: boolean;
  new_count: number;
  updated_count: number;
}

interface RegistryOwnershipRow {
  semantic_id: string;
  file_path: string;
}

interface QueryFilters {
  semanticId?: string;
  kind?: string;
  pathPrefix?: string;
  nameExact?: string;
  namePartial?: string;
  statuses?: string[];
  limit: number;
  offset: number;
}

function isComponentRowInSync(row: ComponentRowSnapshot, component: NormalizedComponent): boolean {
  return (
    row.name === component.name &&
    row.module === component.module &&
    row.file_path === component.file_path &&
    row.kind === component.kind &&
    row.exports === component.exports_json &&
    row.imports === component.imports_json &&
    row.hash === component.hash &&
    row.figma_ref === component.figma_ref &&
    row.status === component.status &&
    row.inactive_reason === component.inactive_reason &&
    row.security_level === component.security_level &&
    row.idem === component.idem
  );
}

function canonicalizeUpsertComponents(components: NormalizedComponent[]): NormalizedComponent[] {
  const canonical = [...components].sort((left, right) =>
    left.semantic_id.localeCompare(right.semantic_id)
  );
  const seenSemanticIds = new Set<string>();

  for (const component of canonical) {
    if (seenSemanticIds.has(component.semantic_id)) {
      throw new Error(`upsert input contains duplicate semantic_id: ${component.semantic_id}`);
    }
    seenSemanticIds.add(component.semantic_id);
  }

  return canonical;
}

function normalizePathLockValue(value: string): string {
  const normalized = posix
    .normalize(
      value
        .trim()
        .replace(/\\/g, "/")
        .replace(/\/+/g, "/")
    )
    .replace(/^(?:\.\/)+/, "")
    .replace(/\/$/, "");

  return normalized.toLowerCase();
}

function buildOwnershipKey(name: string, filePath: string): string {
  return `${name.trim()}|${normalizePathLockValue(filePath)}`;
}

function looksLikePathLockTarget(value: string): boolean {
  const normalized = normalizePathLockValue(value);
  return normalized.includes("/") || normalized.startsWith("../");
}

function assertTargetLockContract(component: NormalizedComponent): void {
  if (!looksLikePathLockTarget(component.module)) {
    return;
  }

  const normalizedModule = normalizePathLockValue(component.module);
  const normalizedPath = normalizePathLockValue(component.file_path);
  if (normalizedModule !== normalizedPath) {
    throw new Error(
      `component ${component.semantic_id} target_lock mismatch: module ${component.module} expects file_path ${component.module}, received ${component.file_path}`
    );
  }
}

function assertRegistryOwnershipLock(params: {
  entry: NormalizedComponent;
  currentRow: ComponentRowSnapshot | undefined;
  context: DatabaseContext;
}): void {
  const { entry, currentRow, context } = params;
  const normalizedRequestedPath = normalizePathLockValue(entry.file_path);

  if (
    currentRow &&
    currentRow.status !== "deleted" &&
    normalizePathLockValue(currentRow.file_path) !== normalizedRequestedPath
  ) {
    throw new Error(
      `component ${entry.semantic_id} registry ownership mismatch: existing file_path ${currentRow.file_path}, requested ${entry.file_path}`
    );
  }

  const conflictingOwners = context.db
    .prepare(
      `
      SELECT semantic_id, file_path
      FROM components
      WHERE project_id = ?
        AND name = ?
        AND semantic_id != ?
        AND status != 'deleted'
      ORDER BY updated_at DESC, semantic_id ASC
    `
    )
    .all(
      context.projectId,
      entry.name,
      entry.semantic_id
    ) as RegistryOwnershipRow[];

  const conflictingOwner = conflictingOwners.find(
    (row) => normalizePathLockValue(row.file_path) === normalizedRequestedPath
  );

  if (conflictingOwner) {
    throw new Error(
      `component ${entry.semantic_id} registry ownership mismatch: ${conflictingOwner.semantic_id} already owns ${conflictingOwner.file_path}`
    );
  }
}

function assertNoDuplicateOwnershipEntries(entries: NormalizedComponent[]): void {
  const ownershipByKey = new Map<string, NormalizedComponent>();

  for (const entry of entries) {
    const ownershipKey = buildOwnershipKey(entry.name, entry.file_path);
    const existingOwner = ownershipByKey.get(ownershipKey);
    if (!existingOwner) {
      ownershipByKey.set(ownershipKey, entry);
      continue;
    }

    if (existingOwner.semantic_id === entry.semantic_id) {
      continue;
    }

    throw new Error(
      `registry ownership mismatch: ${existingOwner.semantic_id} and ${entry.semantic_id} both claim ${normalizePathLockValue(entry.file_path)}`
    );
  }
}

export function handleRegistryUpsert(
  context: DatabaseContext,
  rawInput: unknown
): RegistryUpsertResponse {
  try {
    const input = asObjectOrEmpty(rawInput);
    validateRegistryUpsertInput(input);
    assertProjectIdMatchesContext(context, input);
    const components = canonicalizeUpsertComponents(
      extractComponentPayloads(input, context.projectId).map((payload) =>
        normalizeComponentPayload(payload, context)
      )
    );
    assertNoDuplicateOwnershipEntries(components);

    for (const component of components) {
      assertTargetLockContract(component);
    }

    if (components.length === 0) {
      throw new Error("components or deltas are required");
    }

    const normalizedDeltaPayload = stableStringify({
      delta_type: UPSERT_DELTA_TYPE,
      components: components.map((component) => ({
        semantic_id: component.semantic_id,
        name: component.name,
        module: component.module,
        file_path: component.file_path,
        kind: component.kind,
        exports: JSON.parse(component.exports_json) as unknown[],
        imports: JSON.parse(component.imports_json) as unknown[],
        hash: component.hash,
        figma_ref: component.figma_ref,
        status: component.status,
        inactive_reason: component.inactive_reason,
        security_level: component.security_level,
        idem: component.idem
      }))
    });
    const idempotencyKey = resolveIdempotencyKey(normalizedDeltaPayload);
    const primarySemanticId = components.length === 1 ? components[0].semantic_id : null;

    const transaction = context.db.transaction(
      (entries: NormalizedComponent[]): UpsertDbResult => {
        const currentRowStatement = context.db.prepare(
          `
          SELECT
            name,
            module,
            file_path,
            kind,
            exports,
            imports,
            hash,
            figma_ref,
            status,
            inactive_reason,
            security_level,
            idem
          FROM components
          WHERE project_id = ? AND semantic_id = ?
          LIMIT 1
        `
        );
        const currentRows = entries.map((entry) => ({
          entry,
          currentRow: currentRowStatement.get(context.projectId, entry.semantic_id) as
            | ComponentRowSnapshot
            | undefined
        }));
        for (const { entry, currentRow } of currentRows) {
          assertRegistryOwnershipLock({
            entry,
            currentRow,
            context
          });
        }
        const hasPendingRepair = currentRows.some(
          ({ entry, currentRow }) => !currentRow || !isComponentRowInSync(currentRow, entry)
        );
        const deltaChanges = insertRegistryDelta({
          context,
          idempotencyKey,
          deltaType: UPSERT_DELTA_TYPE,
          semanticId: primarySemanticId,
          payload: normalizedDeltaPayload
        });

        if (deltaChanges === 0 && !hasPendingRepair) {
          return {
            applied: false,
            new_count: 0,
            updated_count: 0
          };
        }

        const upsertStatement = context.db.prepare(`
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
            figma_ref,
            status,
            inactive_reason,
            security_level,
            idem,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
          ON CONFLICT(project_id, semantic_id) DO UPDATE SET
            name = excluded.name,
            module = excluded.module,
            file_path = excluded.file_path,
            kind = excluded.kind,
            exports = excluded.exports,
            imports = excluded.imports,
            hash = excluded.hash,
            figma_ref = excluded.figma_ref,
            status = excluded.status,
            inactive_reason = excluded.inactive_reason,
            security_level = excluded.security_level,
            idem = excluded.idem,
            updated_at = datetime('now')
        `);

        let newCount = 0;
        let updatedCount = 0;

        for (const { entry, currentRow } of currentRows) {
          if (currentRow && isComponentRowInSync(currentRow, entry)) {
            continue;
          }

          upsertStatement.run(
            context.projectId,
            entry.semantic_id,
            entry.name,
            entry.module,
            entry.file_path,
            entry.kind,
            entry.exports_json,
            entry.imports_json,
            entry.hash,
            entry.figma_ref,
            entry.status,
            entry.inactive_reason,
            entry.security_level,
            entry.idem
          );

          if (currentRow) {
            updatedCount += 1;
          } else {
            newCount += 1;
          }
        }

        return {
          applied: deltaChanges > 0 || hasPendingRepair,
          new_count: newCount,
          updated_count: updatedCount
        };
      }
    );

    return transaction(components);
  } catch (error) {
    throw new Error(`sem.registry.upsert failed: ${toErrorMessage(error)}`);
  }
}

export function handleRegistryQuery(
  context: DatabaseContext,
  rawInput: unknown
): RegistryQueryResponse {
  try {
    const input = asObjectOrEmpty(rawInput);
    validateRegistryQueryInput(input);
    assertProjectIdMatchesContext(context, input);
    const filters = normalizeQueryFilters(input);
    const whereClauses: string[] = ["project_id = ?"];
    const queryParams: unknown[] = [context.projectId];

    if (filters.kind) {
      whereClauses.push("kind = ?");
      queryParams.push(filters.kind);
    }

    if (filters.semanticId) {
      whereClauses.push("semantic_id = ?");
      queryParams.push(filters.semanticId);
    }

    if (filters.pathPrefix) {
      const upperBound = buildPrefixUpperBound(filters.pathPrefix);
      if (upperBound) {
        whereClauses.push("file_path >= ? AND file_path < ?");
        queryParams.push(filters.pathPrefix, upperBound);
      } else {
        whereClauses.push("file_path >= ?");
        queryParams.push(filters.pathPrefix);
      }
    }

    if (filters.nameExact) {
      whereClauses.push("name = ?");
      queryParams.push(filters.nameExact);
    }

    if (filters.namePartial) {
      whereClauses.push("name LIKE ?");
      queryParams.push(`%${filters.namePartial}%`);
    }

    if (filters.statuses && filters.statuses.length > 0) {
      whereClauses.push(`status IN (${filters.statuses.map(() => "?").join(", ")})`);
      queryParams.push(...filters.statuses);
    }

    const whereStatement = whereClauses.join(" AND ");
    const totalRow = context.db
      .prepare(`SELECT COUNT(*) AS total FROM components WHERE ${whereStatement}`)
      .get(...queryParams) as { total: number } | undefined;
    const total = totalRow?.total ?? 0;
    const orderByStatement = resolveQueryOrderBy(filters);

    const rows = context.db
      .prepare(
        `
        SELECT semantic_id, file_path, name, kind
        FROM components
        WHERE ${whereStatement}
        ORDER BY ${orderByStatement}
        LIMIT ? OFFSET ?
      `
      )
      .all(...queryParams, filters.limit, filters.offset) as Array<{
      semantic_id: string;
      file_path: string;
      name: string;
      kind: string;
    }>;
    const items: RegistryQueryItem[] = rows.map((row) => ({
      semantic_id: row.semantic_id,
      path: row.file_path,
      symbol: row.name,
      kind: row.kind
    }));

    return compactQueryResponse(items, total);
  } catch (error) {
    throw new Error(`sem.registry.query failed: ${toErrorMessage(error)}`);
  }
}

export function handleRegistrySetStatus(
  context: DatabaseContext,
  rawInput: unknown
): RegistrySetStatusResponse {
  try {
    const input = asRequiredObject(rawInput, "input");
    validateRegistrySetStatusInput(input);
    assertProjectIdMatchesContext(context, input);
    const semanticId = resolveSemanticId(input);
    const requestedStatus = getRequiredExactString(input, "status");
    const newStatus = normalizeMutableStatus(requestedStatus);
    const requestedReason = getConsistentOptionalStringAlias(
      input,
      ["inactive_reason", "reason"],
      "inactive_reason/reason"
    );

    const transaction = context.db.transaction(() => {
      const currentRow = context.db
        .prepare(
          `
          SELECT status, inactive_reason, updated_at
          FROM components
          WHERE project_id = ? AND semantic_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, semanticId) as
        | {
            status: string;
            inactive_reason: string | null;
            updated_at: string;
          }
        | undefined;

      if (!currentRow) {
        throw new Error(`component not found: ${semanticId}`);
      }

      const nextReason =
        newStatus === "active"
          ? null
          : requestedReason ?? (currentRow.inactive_reason ?? null);
      const deltaPayload = stableStringify({
        semantic_id: semanticId,
        status: newStatus,
        inactive_reason: nextReason
      });
      const idempotencyKey = sha256(`${SET_STATUS_DELTA_TYPE}:${deltaPayload}`);

      if (currentRow.status === newStatus && currentRow.inactive_reason === nextReason) {
        const deltaChanges = insertRegistryDelta({
          context,
          idempotencyKey,
          deltaType: SET_STATUS_DELTA_TYPE,
          semanticId,
          payload: deltaPayload
        });

        return {
          applied: deltaChanges > 0,
          semantic_id: semanticId,
          old_status: currentRow.status,
          new_status: newStatus,
          updated_at: currentRow.updated_at
        };
      }

      const updateResult = context.db
        .prepare(
          `
          UPDATE components
          SET status = ?, inactive_reason = ?, updated_at = datetime('now')
          WHERE project_id = ? AND semantic_id = ?
        `
        )
        .run(newStatus, nextReason, context.projectId, semanticId);

      const updatedRow = context.db
        .prepare(
          `
          SELECT updated_at
          FROM components
          WHERE project_id = ? AND semantic_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, semanticId) as { updated_at: string } | undefined;

      if (!updatedRow) {
        throw new Error(`component update verification failed: ${semanticId}`);
      }

      const deltaChanges = insertRegistryDelta({
        context,
        idempotencyKey,
        deltaType: SET_STATUS_DELTA_TYPE,
        semanticId,
        payload: deltaPayload
      });
      const applied = updateResult.changes > 0 || deltaChanges > 0;

      return {
        applied,
        semantic_id: semanticId,
        old_status: currentRow.status,
        new_status: newStatus,
        updated_at: updatedRow.updated_at
      };
    });

    return transaction();
  } catch (error) {
    throw new Error(`sem.registry.set_status failed: ${toErrorMessage(error)}`);
  }
}

export function handleRegistryDelete(
  context: DatabaseContext,
  rawInput: unknown
): RegistryDeleteResponse {
  try {
    const input = asRequiredObject(rawInput, "input");
    validateRegistryDeleteInput(input);
    assertProjectIdMatchesContext(context, input);
    const semanticId = resolveSemanticId(input);
    const reason =
      getConsistentOptionalStringAlias(
        input,
        ["inactive_reason", "reason"],
        "inactive_reason/reason"
      ) ?? "deleted via sem.registry.delete";

    const transaction = context.db.transaction(() => {
      const currentRow = context.db
        .prepare(
          `
          SELECT status, inactive_reason, updated_at
          FROM components
          WHERE project_id = ? AND semantic_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, semanticId) as
        | {
            status: string;
            inactive_reason: string | null;
            updated_at: string;
          }
        | undefined;

      if (!currentRow) {
        throw new Error(`component not found: ${semanticId}`);
      }

      const deltaPayload = stableStringify({
        semantic_id: semanticId,
        inactive_reason: reason,
        status: "deleted"
      });
      const idempotencyKey = sha256(`${DELETE_DELTA_TYPE}:${deltaPayload}`);

      if (currentRow.status === "deleted" && currentRow.inactive_reason === reason) {
        const deltaChanges = insertRegistryDelta({
          context,
          idempotencyKey,
          deltaType: DELETE_DELTA_TYPE,
          semanticId,
          payload: deltaPayload
        });

        return {
          applied: deltaChanges > 0,
          semantic_id: semanticId,
          deleted_at: currentRow.updated_at
        };
      }

      const updateResult = context.db
        .prepare(
          `
          UPDATE components
          SET status = 'deleted', inactive_reason = ?, updated_at = datetime('now')
          WHERE project_id = ? AND semantic_id = ?
        `
        )
        .run(reason, context.projectId, semanticId);

      if (updateResult.changes === 0) {
        throw new Error(`component not found: ${semanticId}`);
      }

      const deletedRow = context.db
        .prepare(
          `
          SELECT updated_at
          FROM components
          WHERE project_id = ? AND semantic_id = ?
          LIMIT 1
        `
        )
        .get(context.projectId, semanticId) as { updated_at: string } | undefined;

      if (!deletedRow) {
        throw new Error(`component delete verification failed: ${semanticId}`);
      }

      const deltaChanges = insertRegistryDelta({
        context,
        idempotencyKey,
        deltaType: DELETE_DELTA_TYPE,
        semanticId,
        payload: deltaPayload
      });

      const deletedAt = deletedRow.updated_at;
      const timestamp = new Date().toISOString();
      console.error(
        `[semantic-mcp-server] ${timestamp} sem.registry.delete project_id=${context.projectId} semantic_id=${semanticId} reason=${reason}`
      );
      const applied = updateResult.changes > 0 || deltaChanges > 0;

      return {
        applied,
        semantic_id: semanticId,
        deleted_at: deletedAt
      };
    });

    return transaction();
  } catch (error) {
    throw new Error(`sem.registry.delete failed: ${toErrorMessage(error)}`);
  }
}

export function logicalIdToSemanticId(logicalId: string): RegistrySemanticId {
  return normalizeIdentifier(logicalId, "logical_id");
}

export function semanticIdToLogicalId(semanticId: string): RegistrySemanticId {
  return normalizeIdentifier(semanticId, "semantic_id");
}

function normalizeQueryFilters(input: JsonObject): QueryFilters {
  const semanticIdValue = getPresentExactString(input, "semantic_id");
  const semanticId = semanticIdValue
    ? normalizeIdentifier(semanticIdValue, "semantic_id")
    : undefined;
  const kind = getPresentString(input, "kind");
  const pathPrefix = getConsistentOptionalStringAlias(
    input,
    ["path_prefix", "pathPrefix", "path"],
    "path_prefix/pathPrefix/path"
  );
  const nameExact = getConsistentOptionalStringAlias(
    input,
    ["name_exact", "nameExact", "symbol_exact", "symbolExact"],
    "name_exact/nameExact/symbol_exact/symbolExact"
  );
  const namePartial = getConsistentOptionalStringAlias(
    input,
    ["name_partial", "namePartial", "name", "symbol"],
    "name_partial/namePartial/name/symbol"
  );
  const statuses = resolveQueryStatuses(input);
  const limit = clamp(parseInteger(input.limit, "limit") ?? 8, 1, 25);
  const offset = clamp(parseInteger(input.offset, "offset") ?? 0, 0, 10000);

  return {
    semanticId,
    kind,
    pathPrefix,
    nameExact,
    namePartial,
    statuses,
    limit,
    offset
  };
}

function resolveQueryOrderBy(filters: QueryFilters): string {
  if (
    filters.pathPrefix &&
    !filters.semanticId &&
    !filters.nameExact &&
    !filters.namePartial
  ) {
    return "file_path ASC, semantic_id ASC";
  }

  return "updated_at DESC, semantic_id ASC";
}

function buildPrefixUpperBound(prefix: string): string | undefined {
  if (prefix.length === 0) {
    return undefined;
  }

  const codePoints = Array.from(prefix);
  const last = codePoints[codePoints.length - 1];
  if (!last) {
    return undefined;
  }

  const next = String.fromCodePoint(last.codePointAt(0)! + 1);
  return `${codePoints.slice(0, -1).join("")}${next}`;
}

function compactQueryResponse(items: RegistryQueryItem[], total: number): RegistryQueryResponse {
  const wasTrimmedByItemLimit = items.length > QUERY_RESPONSE_ITEM_LIMIT;
  let compactItems = wasTrimmedByItemLimit
    ? items.slice(0, QUERY_RESPONSE_ITEM_LIMIT)
    : [...items];
  let truncated = wasTrimmedByItemLimit;
  let response = buildQueryResponse(compactItems, total, truncated);

  while (compactItems.length > 0 && JSON.stringify(response).length > QUERY_RESPONSE_CHAR_BUDGET) {
    compactItems = compactItems.slice(0, -1);
    truncated = true;
    response = buildQueryResponse(compactItems, total, truncated);
  }

  if (JSON.stringify(response).length > QUERY_RESPONSE_CHAR_BUDGET) {
    return {
      items: [],
      total,
      capsule: `matched:${total} returned:0 truncated:true`
    };
  }

  return response;
}

function buildQueryResponse(
  items: RegistryQueryItem[],
  total: number,
  truncated = false
): RegistryQueryResponse {
  const capsule = truncated
    ? `matched:${total} returned:${items.length} truncated:true`
    : `matched:${total} returned:${items.length}`;

  return {
    items,
    total,
    capsule
  };
}

function validateRegistryUpsertInput(input: JsonObject): void {
  assertAllowedKeys(input, REGISTRY_UPSERT_TOP_LEVEL_ALLOWED_KEYS, "upsert input");

  if (hasOwnKey(input, "delta")) {
    validateRegistryUpsertAliasEnvelope(input, "upsert input");
    return;
  }

  if (hasOwnKey(input, "components") || hasOwnKey(input, "deltas")) {
    validateRegistryUpsertCollectionEnvelope(input, "upsert input");
    return;
  }

  if (looksLikeComponentPayload(input)) {
    validateRegistryComponentPayload(input, "upsert input");
    return;
  }

  if (Object.keys(input).length === 0) {
    throw new Error("components or deltas are required");
  }

  throw new Error("components or deltas are required");
}

function validateRegistryQueryInput(input: JsonObject): void {
  assertAllowedKeys(input, REGISTRY_QUERY_ALLOWED_KEYS, "query input");
}

function validateRegistrySetStatusInput(input: JsonObject): void {
  assertAllowedKeys(input, REGISTRY_SET_STATUS_ALLOWED_KEYS, "set_status input");
}

function validateRegistryDeleteInput(input: JsonObject): void {
  assertAllowedKeys(input, REGISTRY_DELETE_ALLOWED_KEYS, "delete input");
}

function validateRegistryUpsertCollectionEnvelope(input: JsonObject, label: string): void {
  validateRegistryCollectionEnvelope(input, REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS, label);
}

function validateRegistryUpsertAliasEnvelope(input: JsonObject, label: string): void {
  assertAllowedKeys(input, REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS, label);
  if (!hasOwnKey(input, "delta")) {
    throw new Error(`${label}.delta is required`);
  }

  validateRegistryDeltaEnvelopeValue(input.delta, `${label}.delta`);
}

function validateRegistryDeltaCollectionEnvelope(input: JsonObject, label: string): void {
  validateRegistryCollectionEnvelope(input, REGISTRY_DELTA_COLLECTION_ALLOWED_KEYS, label);
}

function validateRegistryDeltaAliasEnvelope(input: JsonObject, label: string): void {
  assertAllowedKeys(input, REGISTRY_DELTA_ALIAS_ALLOWED_KEYS, label);

  const aliasKeys = ["component", "after", "value"] as const;
  const presentAliases = aliasKeys.filter((key) => hasOwnKey(input, key));

  if (presentAliases.length !== 1) {
    throw new Error(`${label} must specify exactly one of component/after/value`);
  }

  const aliasKey = presentAliases[0];
  validateRegistryComponentPayload(
    asRequiredObject(input[aliasKey], `${label}.${aliasKey}`),
    `${label}.${aliasKey}`
  );
}

function validateRegistryCollectionEnvelope(
  input: JsonObject,
  allowedKeys: readonly string[],
  label: string
): void {
  assertAllowedKeys(input, allowedKeys, label);

  if (hasOwnKey(input, "components")) {
    const components = input.components;
    if (!Array.isArray(components)) {
      throw new Error(`${label}.components must be an array`);
    }

    components.forEach((component, index) => {
      validateRegistryComponentPayload(
        asRequiredObject(component, `${label}.components[${index}]`),
        `${label}.components[${index}]`
      );
    });
  }

  if (hasOwnKey(input, "deltas")) {
    const deltas = input.deltas;
    if (!Array.isArray(deltas)) {
      throw new Error(`${label}.deltas must be an array`);
    }

    deltas.forEach((delta, index) => {
      validateRegistryDeltaItemPayload(delta, `${label}.deltas[${index}]`);
    });
  }
}

function validateRegistryDeltaEnvelopeValue(value: unknown, label: string): void {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      throw new Error(`${label} must not be empty`);
    }

    value.forEach((entry, index) => {
      validateRegistryDeltaItemPayload(entry, `${label}[${index}]`);
    });
    return;
  }

  const envelope = asRequiredObject(value, label);

  if (hasOwnKey(envelope, "components") || hasOwnKey(envelope, "deltas")) {
    validateRegistryDeltaCollectionEnvelope(envelope, label);
    return;
  }

  if (hasOwnKey(envelope, "component") || hasOwnKey(envelope, "after") || hasOwnKey(envelope, "value")) {
    validateRegistryDeltaAliasEnvelope(envelope, label);
    return;
  }

  validateRegistryComponentPayload(envelope, label);
}

function validateRegistryDeltaItemPayload(value: unknown, label: string): void {
  const item = asRequiredObject(value, label);

  if (hasOwnKey(item, "component") || hasOwnKey(item, "after") || hasOwnKey(item, "value")) {
    validateRegistryDeltaAliasEnvelope(item, label);
    return;
  }

  validateRegistryComponentPayload(item, label);
}

function validateRegistryComponentPayload(payload: JsonObject, label: string): void {
  assertAllowedKeys(payload, REGISTRY_COMPONENT_ALLOWED_KEYS, label);
}

function resolveQueryStatuses(input: JsonObject): string[] | undefined {
  const hasStatus = hasOwnKey(input, "status");
  const hasStatuses = hasOwnKey(input, "statuses");

  const normalizedStatus = hasStatus
    ? normalizeQueryStatusValue(getPresentExactString(input, "status"))
    : undefined;
  const normalizedStatuses = hasStatuses
    ? normalizeStatusArrayFilter(input.statuses)
    : undefined;

  if (!hasStatus && !hasStatuses) {
    return undefined;
  }

  if (hasStatus && hasStatuses) {
    if (!areStringArraySetsEqual(normalizedStatus ?? [], normalizedStatuses ?? [])) {
      throw new Error("status/statuses aliases must resolve to the same effective set");
    }
  }

  return normalizedStatuses ?? normalizedStatus;
}

function normalizeQueryStatusValue(value: string | undefined): string[] | undefined {
  if (value === undefined) {
    return undefined;
  }

  return [normalizeQueryableStatus(value)];
}

function normalizeStatusArrayFilter(rawStatuses: unknown): string[] {
  if (!Array.isArray(rawStatuses)) {
    throw new Error("statuses must be an array");
  }

  const normalized = rawStatuses.map((status, index) => {
    if (typeof status !== "string") {
      throw new Error(`statuses[${index}] must be string`);
    }

    return normalizeQueryableStatus(status);
  });

  return Array.from(new Set(normalized));
}

function areStringArraySetsEqual(left: readonly string[], right: readonly string[]): boolean {
  if (left.length !== right.length) {
    return false;
  }

  const rightSet = new Set(right);
  return left.every((value) => rightSet.has(value));
}

function assertAllowedKeys(
  payload: JsonObject,
  allowedKeys: readonly string[],
  label: string
): void {
  const allowedKeySet = new Set(allowedKeys);
  const unexpectedKeys = Object.keys(payload).filter((key) => !allowedKeySet.has(key));

  if (unexpectedKeys.length > 0) {
    throw new Error(`${label} contains unexpected keys: ${unexpectedKeys.join(", ")}`);
  }
}

function normalizeComponentPayload(payload: unknown, context: DatabaseContext): NormalizedComponent {
  const source = asRequiredObject(payload, "component");
  validateRegistryComponentPayload(source, "component");
  assertProjectIdMatchesProjectId(context.projectId, source, "component.project_id");
  const semanticId = resolveSemanticId(source);
  const symbol =
    getConsistentOptionalStringAlias(source, ["name", "symbol"], "name/symbol") ??
    extractNameFromIdentifier(semanticId);
  const moduleName = getPresentString(source, "module") ?? extractModuleFromIdentifier(semanticId);
  const filePath = getConsistentOptionalStringAlias(
    source,
    ["file_path", "path", "file"],
    "file_path/path/file"
  );

  if (!filePath) {
    throw new Error(`component ${semanticId} is missing file_path`);
  }
  const normalizedFilePath = normalizeRepoRelativePath(context, filePath, "file_path");
  const normalizedModule = looksLikePathLockTarget(moduleName)
    ? normalizeRepoRelativePath(context, moduleName, "module")
    : moduleName;

  const kind = getPresentString(source, "kind") ?? "unknown";
  const normalizedStatus =
    getConsistentOptionalStatusAlias(source, ["status", "_status"], "status/_status") ?? "active";
  const exportsJson = getConsistentArrayAliasString(
    source,
    ["exports", "exported"],
    "exports/exported"
  );
  const importsJson = getConsistentArrayAliasString(
    source,
    ["imports", "dependencies"],
    "imports/dependencies"
  );
  const figmaRef = getPresentString(source, "figma_ref") ?? null;
  const inactiveReason =
    getConsistentOptionalStringAlias(
      source,
      ["inactive_reason", "_inactive_reason"],
      "inactive_reason/_inactive_reason"
    ) ?? null;
  const securityLevel = getPresentString(source, "security_level") ?? null;
  const componentHash =
    getPresentString(source, "hash") ??
    sha256(
      stableStringify({
        semantic_id: semanticId,
        name: symbol,
        module: normalizedModule,
        file_path: normalizedFilePath,
        kind,
        exports: JSON.parse(exportsJson) as unknown[],
        imports: JSON.parse(importsJson) as unknown[],
        figma_ref: figmaRef,
        status: normalizedStatus,
        inactive_reason: inactiveReason,
        security_level: securityLevel
      })
    );
  const idem = sha256(
    stableStringify({
      semantic_id: semanticId,
      hash: componentHash,
      status: normalizedStatus
    })
  );

  return {
    semantic_id: semanticId,
    name: symbol,
    module: normalizedModule,
    file_path: normalizedFilePath,
    kind,
    exports_json: exportsJson,
    imports_json: importsJson,
    hash: componentHash,
    figma_ref: figmaRef,
    status: normalizedStatus,
    inactive_reason: inactiveReason,
    security_level: securityLevel,
    idem
  };
}

function normalizeRepoRelativePath(
  context: DatabaseContext,
  value: string,
  field: string
): string {
  const raw = value.trim().replace(/\\/g, "/");
  if (
    raw.startsWith("/") ||
    raw.startsWith("//") ||
    /^[A-Za-z]:\//.test(raw)
  ) {
    throw new Error(`${field} must be repo-relative`);
  }

  const normalized = posix
    .normalize(raw.replace(/\/+/g, "/"))
    .replace(/^(?:\.\/)+/, "")
    .replace(/\/$/, "");

  if (
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith("../") ||
    normalized.includes("/../")
  ) {
    throw new Error(`${field} must not traverse outside repo root`);
  }

  const repoRoot = resolve(context.repoRoot ?? process.cwd());
  const realRepoRoot = realpathIfExists(repoRoot);
  const absolutePath = resolve(realRepoRoot, normalized);
  if (!isPathInside(realRepoRoot, absolutePath)) {
    throw new Error(`${field} must stay inside repo root`);
  }

  assertNoSymlinkEscape(realRepoRoot, normalized, field);
  return normalized;
}

function assertNoSymlinkEscape(repoRoot: string, relativePath: string, field: string): void {
  let currentPath = repoRoot;
  for (const segment of relativePath.split("/").filter(Boolean)) {
    const nextPath = resolve(currentPath, segment);
    if (!existsSync(nextPath)) {
      currentPath = nextPath;
      continue;
    }

    const stat = lstatSync(nextPath);
    currentPath = stat.isSymbolicLink() ? realpathSync(nextPath) : nextPath;
    if (!isPathInside(repoRoot, currentPath)) {
      throw new Error(`${field} must not escape repo root through symlinks`);
    }
  }
}

function realpathIfExists(path: string): string {
  return existsSync(path) ? realpathSync(path) : path;
}

function isPathInside(root: string, candidate: string): boolean {
  const relative = posix.normalize(candidate.replace(/\\/g, "/")).slice(
    posix.normalize(root.replace(/\\/g, "/")).length
  );
  return candidate === root || (relative.startsWith("/") && !relative.startsWith("/../"));
}

function extractComponentPayloads(input: JsonObject, projectId: string): unknown[] {
  const collected: unknown[] = [];
  const components = input.components;
  if (Array.isArray(components)) {
    collected.push(...components);
  }

  const deltas = input.deltas;
  if (Array.isArray(deltas)) {
    collected.push(...deltas.map((delta) => unwrapDeltaItem(delta, projectId)));
  }

  const delta = input.delta;
  if (Array.isArray(delta)) {
    collected.push(...delta.map((entry) => unwrapDeltaItem(entry, projectId)));
  } else if (isObject(delta)) {
    collected.push(...extractDeltaEnvelopeItems(delta, projectId));
  }

  if (collected.length > 0) {
    return collected;
  }

  if (looksLikeComponentPayload(input)) {
    return [input];
  }

  return [];
}

function unwrapDeltaItem(delta: unknown, projectId: string): unknown {
  if (!isObject(delta)) {
    return delta;
  }

  assertProjectIdMatchesProjectId(projectId, delta, "delta.project_id");
  const resolvedAlias = resolveSingleDeltaAliasPayload(delta, projectId);
  if (resolvedAlias !== undefined) {
    return resolvedAlias;
  }

  return delta;
}

function extractDeltaEnvelopeItems(delta: JsonObject, projectId: string): unknown[] {
  assertProjectIdMatchesProjectId(projectId, delta, "delta.project_id");

  const nestedComponents = delta.components;
  const nestedDeltas = delta.deltas;
  const hasComponents = Array.isArray(nestedComponents);
  const hasDeltas = Array.isArray(nestedDeltas);
  const singleAliasPayload = resolveSingleDeltaAliasPayload(delta, projectId);

  if ((hasComponents || hasDeltas) && singleAliasPayload !== undefined) {
    throw new Error(
      "delta envelope must not mix components/deltas with component/after/value branches"
    );
  }

  const collected: unknown[] = [];
  if (hasComponents) {
    collected.push(...nestedComponents);
  }
  if (hasDeltas) {
    collected.push(...nestedDeltas.map((entry) => unwrapDeltaItem(entry, projectId)));
  }
  if (singleAliasPayload !== undefined) {
    collected.push(singleAliasPayload);
  }

  if (collected.length > 0) {
    return collected;
  }

  if (looksLikeComponentPayload(delta)) {
    return [delta];
  }

  throw new Error("delta envelope must contain components, deltas, or exactly one of component/after/value");
}

function resolveSingleDeltaAliasPayload(delta: JsonObject, projectId: string): unknown | undefined {
  const aliasKeys = ["component", "after", "value"] as const;
  const presentAliases: Array<{ key: (typeof aliasKeys)[number]; payload: JsonObject }> = [];

  for (const key of aliasKeys) {
    const value = delta[key];
    if (value === undefined || value === null) {
      continue;
    }

    if (!isObject(value)) {
      throw new Error(`delta.${key} must be an object`);
    }

    assertProjectIdMatchesProjectId(projectId, value, `delta.${key}.project_id`);
    presentAliases.push({ key, payload: value });
  }

  if (presentAliases.length === 0) {
    return undefined;
  }

  if (presentAliases.length > 1) {
    throw new Error("delta alias envelope must specify exactly one of component/after/value");
  }

  return presentAliases[0].payload;
}

function looksLikeComponentPayload(value: JsonObject): boolean {
  return (
    value.semantic_id !== undefined ||
    value.logical_id !== undefined ||
    value.module !== undefined ||
    value.name !== undefined ||
    value.symbol !== undefined ||
    value.file_path !== undefined ||
    value.path !== undefined ||
    value.file !== undefined
  );
}

function assertProjectIdMatchesContext(context: DatabaseContext, input: JsonObject): void {
  assertProjectIdMatchesProjectId(context.projectId, input, "project_id");
}

function assertProjectIdMatchesProjectId(
  expectedProjectId: string,
  input: JsonObject,
  field: string
): void {
  const requestedProjectId = getPresentString(input, "project_id");
  if (!requestedProjectId) {
    return;
  }

  if (requestedProjectId !== expectedProjectId) {
    throw new Error(`${field} must match context project_id`);
  }
}

function getConsistentOptionalStringAlias(
  payload: JsonObject,
  keys: readonly string[],
  label: string
): string | undefined {
  const values: string[] = [];

  for (const key of keys) {
    const value = getPresentString(payload, key);
    if (value !== undefined) {
      values.push(value);
    }
  }

  if (values.length === 0) {
    return undefined;
  }

  for (const value of values.slice(1)) {
    if (value !== values[0]) {
      throw new Error(`${label} aliases must match`);
    }
  }

  return values[0];
}

function getConsistentOptionalStatusAlias(
  payload: JsonObject,
  keys: readonly string[],
  label: string
): QueryableStatus | undefined {
  const values: QueryableStatus[] = [];

  for (const key of keys) {
    const value = getPresentExactString(payload, key);
    if (value !== undefined) {
      values.push(normalizeQueryableStatus(value));
    }
  }

  if (values.length === 0) {
    return undefined;
  }

  for (const value of values.slice(1)) {
    if (value !== values[0]) {
      throw new Error(`${label} aliases must match`);
    }
  }

  return values[0];
}

function getConsistentArrayAliasString(
  payload: JsonObject,
  keys: readonly string[],
  label: string
): string {
  const values: string[] = [];

  for (const key of keys) {
    const value = payload[key];
    if (value === undefined) {
      continue;
    }

    if (value === null) {
      throw new Error(`${key} must not be null`);
    }

    values.push(toJsonArrayString(value, key));
  }

  if (values.length === 0) {
    return "[]";
  }

  for (const value of values.slice(1)) {
    if (value !== values[0]) {
      throw new Error(`${label} aliases must match`);
    }
  }

  return values[0];
}

function resolveSemanticId(payload: JsonObject): RegistrySemanticId {
  const identifiers: string[] = [];
  const semanticId = getPresentExactString(payload, "semantic_id");
  if (semanticId) {
    identifiers.push(semanticIdToLogicalId(semanticId));
  }

  const logicalId = getPresentExactString(payload, "logical_id");
  if (logicalId) {
    identifiers.push(logicalIdToSemanticId(logicalId));
  }

  const moduleName = getPresentString(payload, "module");
  const name = getPresentString(payload, "name");
  const symbol = getPresentString(payload, "symbol");

  if (moduleName && name) {
    identifiers.push(logicalIdToSemanticId(`${moduleName}:${name}`));
  }

  if (moduleName && symbol) {
    identifiers.push(logicalIdToSemanticId(`${moduleName}:${symbol}`));
  }

  const uniqueIdentifiers = Array.from(new Set(identifiers));
  if (uniqueIdentifiers.length === 0) {
    throw new Error("semantic_id is required");
  }

  if (uniqueIdentifiers.length > 1) {
    throw new Error("identifier sources must resolve to the same semantic_id");
  }

  return uniqueIdentifiers[0] as RegistrySemanticId;
}

function normalizeMutableStatus(status: string): MutableStatus {
  if (status.trim().length === 0) {
    throw new Error("status must not be blank");
  }
  if (!MUTABLE_STATUS_SET.has(status)) {
    throw new Error(`status must be one of: ${MUTABLE_STATUSES.join(", ")}`);
  }

  return status as MutableStatus;
}

function normalizeQueryableStatus(status: string): QueryableStatus {
  if (status.trim().length === 0) {
    throw new Error("status must not be blank");
  }
  if (!QUERYABLE_STATUS_SET.has(status)) {
    throw new Error(`status must be one of: ${QUERYABLE_STATUSES.join(", ")}`);
  }

  return status as QueryableStatus;
}

function parseInteger(value: unknown, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (value === null) {
    throw new Error(`${field} must not be null`);
  }

  if (typeof value === "number") {
    if (!Number.isInteger(value)) {
      throw new Error(`${field} must be an integer`);
    }
    return value;
  }

  if (typeof value === "string") {
    if (!/^-?\d+$/.test(value)) {
      throw new Error(`${field} must be an integer`);
    }

    return Number(value);
  }

  throw new Error(`${field} must be an integer`);
}

function insertRegistryDelta(params: {
  context: DatabaseContext;
  idempotencyKey: string;
  deltaType: string;
  semanticId: string | null;
  payload: string;
}): number {
  const { context, idempotencyKey, deltaType, semanticId, payload } = params;

  try {
    const result = context.db
      .prepare(
        `
        INSERT OR IGNORE INTO registry_deltas (
          project_id,
          idempotency_key,
          delta_type,
          semantic_id,
          payload,
          applied_at
        )
        VALUES (?, ?, ?, ?, ?, datetime('now'))
      `
      )
      .run(context.projectId, idempotencyKey, deltaType, semanticId, payload);

    return result.changes;
  } catch (error) {
    if (!isMissingColumnError(error, "semantic_id")) {
      throw error;
    }

    const fallbackResult = context.db
      .prepare(
        `
        INSERT OR IGNORE INTO registry_deltas (
          project_id,
          idempotency_key,
          delta_type,
          payload,
          applied_at
        )
        VALUES (?, ?, ?, ?, datetime('now'))
      `
      )
      .run(context.projectId, idempotencyKey, deltaType, payload);

    return fallbackResult.changes;
  }
}

function resolveIdempotencyKey(payload: string): string {
  return sha256(payload);
}

function toJsonArrayString(value: unknown, field = "value"): string {
  if (value === undefined || value === null) {
    return "[]";
  }

  if (Array.isArray(value)) {
    return stableStringify(value);
  }

  throw new Error(`${field} must be an array`);
}

function normalizeIdentifier(
  value: string,
  field: "logical_id" | "semantic_id"
): RegistrySemanticId {
  if (!/^[^:\s]+:[^:\s]+$/.test(value)) {
    throw new Error(`${field} must use module:name format`);
  }

  return value as RegistrySemanticId;
}

function extractModuleFromIdentifier(semanticId: string): string {
  const separatorIndex = semanticId.indexOf(":");
  if (separatorIndex <= 0) {
    return "unknown";
  }
  return semanticId.slice(0, separatorIndex);
}

function extractNameFromIdentifier(semanticId: string): string {
  const separatorIndex = semanticId.indexOf(":");
  if (separatorIndex < 0 || separatorIndex >= semanticId.length - 1) {
    return semanticId;
  }
  return semanticId.slice(separatorIndex + 1);
}

function stableStringify(value: unknown): string {
  return JSON.stringify(normalizeJsonValue(value));
}

function normalizeJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => normalizeJsonValue(item));
  }

  if (isObject(value)) {
    const normalized: JsonObject = {};
    const entries = Object.entries(value).filter(([, entryValue]) => entryValue !== undefined);
    entries.sort(([left], [right]) => left.localeCompare(right));

    for (const [key, entryValue] of entries) {
      normalized[key] = normalizeJsonValue(entryValue);
    }

    return normalized;
  }

  return value;
}

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function asObjectOrEmpty(value: unknown): JsonObject {
  if (value === undefined || value === null) {
    return {};
  }

  return asRequiredObject(value, "arguments");
}

function asRequiredObject(value: unknown, field: string): JsonObject {
  if (!isObject(value)) {
    throw new Error(`${field} must be an object`);
  }

  return value;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOwnKey(payload: JsonObject, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(payload, key);
}

function getPresentString(payload: JsonObject, key: string): string | undefined {
  const value = payload[key];

  if (value === undefined) {
    return undefined;
  }

  if (value === null) {
    throw new Error(`${key} must not be null`);
  }

  if (typeof value !== "string") {
    throw new Error(`${key} must be a string`);
  }

  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error(`${key} must not be blank`);
  }

  return trimmed;
}

function getPresentExactString(payload: JsonObject, key: string): string | undefined {
  const value = payload[key];

  if (value === undefined) {
    return undefined;
  }

  if (value === null) {
    throw new Error(`${key} must not be null`);
  }

  if (typeof value !== "string") {
    throw new Error(`${key} must be a string`);
  }

  if (value.trim().length === 0) {
    throw new Error(`${key} must not be blank`);
  }

  return value;
}

function getRequiredString(payload: JsonObject, key: string): string {
  const value = getPresentString(payload, key);
  if (!value) {
    throw new Error(`${key} is required`);
  }
  return value;
}

function getRequiredExactString(payload: JsonObject, key: string): string {
  const value = getPresentExactString(payload, key);
  if (!value) {
    throw new Error(`${key} is required`);
  }
  return value;
}

function isMissingColumnError(error: unknown, column: string): boolean {
  const message = toErrorMessage(error).toLowerCase();
  return message.includes("no column named") && message.includes(column.toLowerCase());
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
