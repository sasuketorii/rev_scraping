import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type BetterSqlite3Module from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DatabaseContext } from "../db/connection.js";
import { runMigrations } from "../db/migrations.js";
import {
  REGISTRY_COMPONENT_SCHEMA,
  REGISTRY_DELTA_ITEM_SCHEMA,
  REGISTRY_INTEGER_INPUT_SCHEMA,
  REGISTRY_INTEGER_STRING_SCHEMA,
  REGISTRY_DELETE_INPUT_SCHEMA,
  REGISTRY_NON_EMPTY_STRING_SCHEMA,
  REGISTRY_SEMANTIC_ID_SCHEMA,
  REGISTRY_QUERY_INPUT_SCHEMA,
  REGISTRY_SET_STATUS_INPUT_SCHEMA,
  REGISTRY_UPSERT_ENVELOPE_SCHEMA,
  REGISTRY_UPSERT_INPUT_SCHEMA
} from "../server.js";
import {
  handleRegistryDelete,
  handleRegistryQuery,
  handleRegistrySetStatus,
  handleRegistryUpsert,
  logicalIdToSemanticId,
  semanticIdToLogicalId
} from "../tools/registry.js";

const require = createRequire(import.meta.url);
type BetterSqlite3Constructor = new (
  filename?: string | Buffer,
  options?: Record<string, unknown>
) => BetterSqlite3Module.Database;
const BetterSqlite3 = require("better-sqlite3") as BetterSqlite3Constructor;

const PROJECT_ID = "test-project";
const COMPONENT_INPUT = {
  logical_id: "core:UserService",
  name: "UserService",
  module: "core",
  file_path: "src/core/user-service.ts",
  kind: "class",
  exports: ["UserService"],
  imports: ["dep:logger"]
};

const SECOND_COMPONENT_INPUT = {
  logical_id: "core:AuditService",
  name: "AuditService",
  module: "core",
  file_path: "src/core/audit-service.ts",
  kind: "class",
  exports: ["AuditService"],
  imports: ["dep:logger"]
};

describe("registry tools", () => {
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

  it("upsert is idempotent for the same delta", () => {
    const first = handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(first).toEqual({
      applied: true,
      new_count: 1,
      updated_count: 0
    });

    const second = handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(second).toEqual({
      applied: false,
      new_count: 0,
      updated_count: 0
    });
  });

  it("upsert is idempotent when equivalent multi-component batches are replayed in a different order", () => {
    const first = handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT, SECOND_COMPONENT_INPUT]
    });

    expect(first).toEqual({
      applied: true,
      new_count: 2,
      updated_count: 0
    });

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ?
      `
      )
      .get(PROJECT_ID, "upsert") as { total: number };
    expect(deltaCountBefore.total).toBe(1);

    const second = handleRegistryUpsert(context, {
      components: [SECOND_COMPONENT_INPUT, COMPONENT_INPUT]
    });

    expect(second).toEqual({
      applied: false,
      new_count: 0,
      updated_count: 0
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ?
      `
      )
      .get(PROJECT_ID, "upsert") as { total: number };
    expect(deltaCountAfter.total).toBe(1);
  });

  it("upsert reports applied when it repairs a drifted row after delta was already recorded", () => {
    const first = handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(first).toEqual({
      applied: true,
      new_count: 1,
      updated_count: 0
    });

    const driftTimestamp = "2001-02-03 04:05:06";
    context.db
      .prepare(
        `
        UPDATE components
        SET name = ?, updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run("UserServiceDrifted", driftTimestamp, PROJECT_ID, "core:UserService");

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "upsert", "core:UserService") as { total: number };
    expect(deltaCountBefore.total).toBe(1);

    const repaired = handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(repaired).toEqual({
      applied: true,
      new_count: 0,
      updated_count: 1
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "upsert", "core:UserService") as { total: number };
    expect(deltaCountAfter.total).toBe(1);

    const row = context.db
      .prepare(
        `
        SELECT name, updated_at
        FROM components
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "core:UserService") as {
      name: string;
      updated_at: string;
    };
    expect(row.name).toBe("UserService");
    expect(row.updated_at).not.toBe(driftTimestamp);
  });

  it("rejects duplicate semantic_id values within a single upsert batch", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          COMPONENT_INPUT,
          {
            semantic_id: "core:UserService",
            file_path: "src/core/user-service-copy.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/upsert input contains duplicate semantic_id: core:UserService/);
  });

  it("round-trips logical_id and semantic_id", () => {
    const logicalId = "core:UserService";
    const semanticId = logicalIdToSemanticId(logicalId);
    const restoredLogicalId = semanticIdToLogicalId(semanticId);

    expect(semanticId).toBe(logicalId);
    expect(restoredLogicalId).toBe(logicalId);
  });

  it("accepts top-level raw component input for upsert", () => {
    const upserted = handleRegistryUpsert(context, {
      module: "core",
      name: "RawTopLevelService",
      file_path: "src/core/raw-top-level-service.ts",
      kind: "class"
    });

    expect(upserted).toEqual({
      applied: true,
      new_count: 1,
      updated_count: 0
    });

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      name: "RawTopLevelService"
    });

    expect(queried.total).toBe(1);
    expect(queried.items[0]).toMatchObject({
      semantic_id: "core:RawTopLevelService",
      path: "src/core/raw-top-level-service.ts",
      symbol: "RawTopLevelService"
    });
  });

  it("rejects unexpected keys on direct registry handler calls", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [COMPONENT_INPUT],
        idempotency_key: "a".repeat(64)
      })
    ).toThrow(/upsert input contains unexpected keys: idempotency_key/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            idem: "idem-a"
          }
        ]
      })
    ).toThrow(/upsert input\.components\[0\] contains unexpected keys: idem/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            _idem: "idem-b"
          }
        ]
      })
    ).toThrow(/upsert input\.components\[0\] contains unexpected keys: _idem/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [COMPONENT_INPUT],
        module: "core",
        name: "MixedService",
        file_path: "src/core/mixed-service.ts"
      })
    ).toThrow(/upsert input contains unexpected keys: module, name, file_path/);

    expect(() =>
      handleRegistryUpsert(context, {
        delta: {
          components: [COMPONENT_INPUT],
          module: "core",
          name: "MixedService",
          file_path: "src/core/mixed-service.ts"
        }
      })
    ).toThrow(/upsert input\.delta contains unexpected keys: module, name, file_path/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        name: "UserService",
        unexpected: true
      })
    ).toThrow(/query input contains unexpected keys: unexpected/);

    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: "inactive",
        unexpected: "value"
      })
    ).toThrow(/set_status input contains unexpected keys: unexpected/);

    expect(() =>
      handleRegistryDelete(context, {
        logical_id: "core:UserService",
        reason: "deprecated component",
        unexpected: "value"
      })
    ).toThrow(/delete input contains unexpected keys: unexpected/);
  });

  it("rejects blank-string direct-handler inputs instead of silently dropping them", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:BlankModuleService",
            module: "",
            file_path: "src/core/blank-module-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/module must not be blank/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:BlankKindService",
            file_path: "src/core/blank-kind-service.ts",
            kind: ""
          }
        ]
      })
    ).toThrow(/kind must not be blank/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:BlankHashService",
            file_path: "src/core/blank-hash-service.ts",
            kind: "class",
            hash: ""
          }
        ]
      })
    ).toThrow(/hash must not be blank/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:BlankFigmaRefService",
            file_path: "src/core/blank-figma-ref-service.ts",
            kind: "class",
            figma_ref: ""
          }
        ]
      })
    ).toThrow(/figma_ref must not be blank/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:BlankSecurityLevelService",
            file_path: "src/core/blank-security-level-service.ts",
            kind: "class",
            security_level: ""
          }
        ]
      })
    ).toThrow(/security_level must not be blank/);

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: "inactive",
        reason: ""
      })
    ).toThrow(/reason must not be blank/);

    expect(() =>
      handleRegistryDelete(context, {
        logical_id: "core:UserService",
        inactive_reason: ""
      })
    ).toThrow(/inactive_reason must not be blank/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        path_prefix: ""
      })
    ).toThrow(/path_prefix must not be blank/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        name: ""
      })
    ).toThrow(/name must not be blank/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        kind: ""
      })
    ).toThrow(/kind must not be blank/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        status: ""
      })
    ).toThrow(/status must not be blank/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        statuses: [""]
      })
    ).toThrow(/status must not be blank/);
  });

  it("rejects null direct-handler inputs instead of silently absorbing them", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            module: null
          }
        ]
      })
    ).toThrow(/module must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            kind: null
          }
        ]
      })
    ).toThrow(/kind must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            hash: null
          }
        ]
      })
    ).toThrow(/hash must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            figma_ref: null
          }
        ]
      })
    ).toThrow(/figma_ref must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            security_level: null
          }
        ]
      })
    ).toThrow(/security_level must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            exports: null
          }
        ]
      })
    ).toThrow(/exports must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            exported: null
          }
        ]
      })
    ).toThrow(/exported must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            imports: null
          }
        ]
      })
    ).toThrow(/imports must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            ...COMPONENT_INPUT,
            dependencies: null
          }
        ]
      })
    ).toThrow(/dependencies must not be null/);

    expect(() =>
      handleRegistryUpsert(context, {
        project_id: null,
        components: [COMPONENT_INPUT]
      })
    ).toThrow(/project_id must not be null/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        status: null
      })
    ).toThrow(/status must not be null/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: null,
        name: "UserService"
      })
    ).toThrow(/project_id must not be null/);

    expect(() =>
      handleRegistrySetStatus(context, {
        project_id: null,
        logical_id: "core:UserService",
        status: "inactive"
      })
    ).toThrow(/project_id must not be null/);

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: "inactive",
        reason: null
      })
    ).toThrow(/reason must not be null/);

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: "inactive",
        inactive_reason: null
      })
    ).toThrow(/inactive_reason must not be null/);

    expect(() =>
      handleRegistryDelete(context, {
        project_id: null,
        logical_id: "core:UserService"
      })
    ).toThrow(/project_id must not be null/);

    expect(() =>
      handleRegistryDelete(context, {
        logical_id: "core:UserService",
        reason: null
      })
    ).toThrow(/reason must not be null/);

    expect(() =>
      handleRegistryDelete(context, {
        logical_id: "core:UserService",
        inactive_reason: null
      })
    ).toThrow(/inactive_reason must not be null/);
  });

  it("rejects exact-format identifier and status values that deviate from the public contract", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core: UserService",
            file_path: "src/core/user-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/semantic_id must use module:name format/);

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: " core:UserService",
        status: "inactive"
      })
    ).toThrow(/logical_id must use module:name format/);

    expect(() =>
      handleRegistryDelete(context, {
        semantic_id: "core:UserService ",
        reason: "deprecated component"
      })
    ).toThrow(/semantic_id must use module:name format/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:StatusService",
            file_path: "src/core/status-service.ts",
            kind: "class",
            status: " INACTIVE "
          }
        ]
      })
    ).toThrow(/status must be one of: active, inactive, incomplete, buggy, deprecated, deleted/);

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: " ACTIVE "
      })
    ).toThrow(/status must be one of: active, inactive, incomplete, buggy, deprecated/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        semantic_id: "core: UserService"
      })
    ).toThrow(/semantic_id must use module:name format/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        status: " ACTIVE "
      })
    ).toThrow(/status must be one of: active, inactive, incomplete, buggy, deprecated, deleted/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        statuses: [" active "]
      })
    ).toThrow(/status must be one of: active, inactive, incomplete, buggy, deprecated, deleted/);
  });

  it("pins registry upsert input schema to reject empty envelopes and mixed collection-plus-alias envelopes", () => {
    expect(REGISTRY_COMPONENT_SCHEMA.additionalProperties).toBe(false);

    const upsertInputProperties = REGISTRY_UPSERT_INPUT_SCHEMA.properties as Record<
      string,
      unknown
    >;
    expect(REGISTRY_UPSERT_INPUT_SCHEMA.type).toBe("object");
    expect(REGISTRY_UPSERT_INPUT_SCHEMA.additionalProperties).toBe(false);
    expect(REGISTRY_UPSERT_INPUT_SCHEMA).not.toHaveProperty("oneOf");
    expect(REGISTRY_UPSERT_INPUT_SCHEMA).not.toHaveProperty("anyOf");
    expect(upsertInputProperties.semantic_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(upsertInputProperties.logical_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(upsertInputProperties).not.toHaveProperty("idempotency_key");
    expect(upsertInputProperties.components).toMatchObject({
      type: "array",
      items: REGISTRY_COMPONENT_SCHEMA
    });
    expect(upsertInputProperties.deltas).toMatchObject({
      type: "array",
      items: REGISTRY_DELTA_ITEM_SCHEMA
    });
    expect(upsertInputProperties).toHaveProperty("delta");

    const upsertEnvelopeBranches = REGISTRY_UPSERT_ENVELOPE_SCHEMA.oneOf as ReadonlyArray<
      Record<string, unknown>
    >;
    expect(upsertEnvelopeBranches).toHaveLength(2);

    const collectionBranch = upsertEnvelopeBranches[0];
    expect(collectionBranch.additionalProperties).toBe(false);
    expect((collectionBranch.properties as Record<string, unknown>)).not.toHaveProperty(
      "idempotency_key"
    );
    expect(collectionBranch.anyOf).toEqual([
      {
        required: ["components"],
        properties: {
          components: {
            type: "array",
            minItems: 1
          }
        }
      },
      {
        required: ["deltas"],
        properties: {
          deltas: {
            type: "array",
            minItems: 1
          }
        }
      }
    ]);
    expect((collectionBranch.properties as Record<string, unknown>)).not.toHaveProperty("delta");

    const aliasBranch = upsertEnvelopeBranches[1];
    expect(aliasBranch.additionalProperties).toBe(false);
    expect(aliasBranch.required).toEqual(["delta"]);
    expect((aliasBranch.properties as Record<string, unknown>)).not.toHaveProperty(
      "idempotency_key"
    );
    expect((aliasBranch.properties as Record<string, unknown>)).not.toHaveProperty("components");
    expect((aliasBranch.properties as Record<string, unknown>)).not.toHaveProperty("deltas");

    const aliasDeltaSchema = (aliasBranch.properties as Record<string, unknown>).delta as Record<
      string,
      unknown
    >;
    const aliasDeltaVariants = aliasDeltaSchema.oneOf as ReadonlyArray<Record<string, unknown>>;
    expect(aliasDeltaVariants).toHaveLength(4);
    expect(aliasDeltaVariants[1]).toMatchObject({
      type: "array",
      minItems: 1
    });

    const deltaItemBranches = REGISTRY_DELTA_ITEM_SCHEMA.oneOf as ReadonlyArray<
      Record<string, unknown>
    >;
    expect(deltaItemBranches).toHaveLength(2);
    expect(deltaItemBranches[0]).toBe(REGISTRY_COMPONENT_SCHEMA);
    expect(deltaItemBranches[1].additionalProperties).toBe(false);
    expect(deltaItemBranches[1].oneOf).toEqual([
      { required: ["component"] },
      { required: ["after"] },
      { required: ["value"] }
    ]);
    expect(upsertEnvelopeBranches[0].additionalProperties).toBe(false);
    expect(upsertEnvelopeBranches[0].anyOf).toEqual(collectionBranch.anyOf);
    expect(upsertEnvelopeBranches[1].additionalProperties).toBe(false);
  });

  it("pins registry schemas to identifier pattern, non-blank string fields, and integer strings", () => {
    const componentProperties = REGISTRY_COMPONENT_SCHEMA.properties as Record<string, unknown>;
    const queryProperties = REGISTRY_QUERY_INPUT_SCHEMA.properties as Record<string, unknown>;
    const setStatusProperties = REGISTRY_SET_STATUS_INPUT_SCHEMA.properties as Record<
      string,
      unknown
    >;
    const deleteProperties = REGISTRY_DELETE_INPUT_SCHEMA.properties as Record<string, unknown>;

    expect(REGISTRY_QUERY_INPUT_SCHEMA.additionalProperties).toBe(false);
    expect(componentProperties.semantic_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(componentProperties.logical_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(componentProperties.kind).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(componentProperties.hash).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(componentProperties.figma_ref).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(componentProperties.security_level).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(componentProperties).not.toHaveProperty("idem");
    expect(componentProperties).not.toHaveProperty("_idem");
    expect(queryProperties.kind).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.semantic_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(queryProperties.path_prefix).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.pathPrefix).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.path).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.name).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.symbol).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.name_exact).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.nameExact).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.symbol_exact).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.symbolExact).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.name_partial).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(queryProperties.namePartial).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(setStatusProperties.semantic_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(setStatusProperties.logical_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(setStatusProperties.module).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(setStatusProperties.name).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(setStatusProperties.symbol).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(setStatusProperties.inactive_reason).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(setStatusProperties.reason).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(REGISTRY_SET_STATUS_INPUT_SCHEMA).not.toHaveProperty("anyOf");
    expect(deleteProperties.semantic_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(deleteProperties.logical_id).toBe(REGISTRY_SEMANTIC_ID_SCHEMA);
    expect(deleteProperties.module).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(deleteProperties.name).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(deleteProperties.symbol).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(deleteProperties.reason).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(deleteProperties.inactive_reason).toBe(REGISTRY_NON_EMPTY_STRING_SCHEMA);
    expect(REGISTRY_DELETE_INPUT_SCHEMA).not.toHaveProperty("anyOf");
    expect(queryProperties.limit).toBe(REGISTRY_INTEGER_INPUT_SCHEMA);
    expect(queryProperties.offset).toBe(REGISTRY_INTEGER_INPUT_SCHEMA);
    expect(REGISTRY_INTEGER_INPUT_SCHEMA.anyOf).toEqual([
      { type: "integer" },
      REGISTRY_INTEGER_STRING_SCHEMA
    ]);
    expect(REGISTRY_INTEGER_STRING_SCHEMA.pattern).toBe("^-?\\d+$");
  });

  it("returns upserted item via query", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const queried = handleRegistryQuery(context, {
      name: "UserService"
    });

    expect(queried.total).toBe(1);
    expect(queried.items).toHaveLength(1);
    expect(queried.items[0]).toMatchObject({
      semantic_id: "core:UserService",
      path: "src/core/user-service.ts",
      symbol: "UserService",
      kind: "class"
    });
  });

  it("separates exact semantic_id and exact symbol query from partial search aliases", () => {
    handleRegistryUpsert(context, {
      components: [
        COMPONENT_INPUT,
        {
          module: "core",
          name: "UserServiceHelper",
          file_path: "src/core/user-service-helper.ts",
          kind: "class"
        }
      ]
    });

    const exactById = handleRegistryQuery(context, {
      semantic_id: "core:UserService"
    });
    expect(exactById.total).toBe(1);
    expect(exactById.items.map((item) => item.semantic_id)).toEqual(["core:UserService"]);

    const exactByName = handleRegistryQuery(context, {
      name_exact: "UserService"
    });
    expect(exactByName.total).toBe(1);
    expect(exactByName.items.map((item) => item.semantic_id)).toEqual(["core:UserService"]);

    const partialByName = handleRegistryQuery(context, {
      name: "UserService"
    });
    expect(partialByName.total).toBe(2);
    expect(partialByName.items.map((item) => item.semantic_id).sort()).toEqual([
      "core:UserService",
      "core:UserServiceHelper"
    ]);
  });

  it("rejects repo-external, traversal, and symlink-escape registry paths", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AbsolutePathService",
            file_path: "/tmp/absolute-path-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/file_path must be repo-relative/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "TraversalService",
            file_path: "../outside.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/file_path must not traverse outside repo root/);

    mkdirSync(join(context.repoRoot!, "src"), { recursive: true });
    symlinkSync(tmpdir(), join(context.repoRoot!, "src", "escape"));
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "src/escape",
            name: "SymlinkEscapeService",
            file_path: "src/escape/outside.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/must not escape repo root through symlinks/);
  });

  it("rejects empty upsert envelopes", () => {
    expect(() => handleRegistryUpsert(context, {})).toThrow(
      /components or deltas are required/
    );
    expect(() => handleRegistryUpsert(context, { components: [] })).toThrow(
      /components or deltas are required/
    );
    expect(() => handleRegistryUpsert(context, { deltas: [] })).toThrow(
      /components or deltas are required/
    );
    expect(() => handleRegistryUpsert(context, { delta: [] })).toThrow(/must not be empty/);
  });

  it("updates status and reports old/new status", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const updated = handleRegistrySetStatus(context, {
      project_id: PROJECT_ID,
      module: "core",
      symbol: "UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(updated.applied).toBe(true);
    expect(updated.semantic_id).toBe("core:UserService");
    expect(updated.old_status).toBe("active");
    expect(updated.new_status).toBe("inactive");
    expect(updated.updated_at).toEqual(expect.any(String));
  });

  it("set_status retry is idempotent and preserves updated_at", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const first = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    const preservedTimestamp = "2001-02-03 04:05:06";
    context.db
      .prepare(
        `
        UPDATE components
        SET updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run(preservedTimestamp, PROJECT_ID, "core:UserService");

    const second = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(first.applied).toBe(true);
    expect(second).toMatchObject({
      applied: false,
      semantic_id: "core:UserService",
      old_status: "inactive",
      new_status: "inactive",
      updated_at: preservedTimestamp
    });

    const row = context.db
      .prepare(
        `
        SELECT updated_at
        FROM components
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "core:UserService") as { updated_at: string };
    expect(row.updated_at).toBe(preservedTimestamp);
  });

  it("set_status reports applied when it records the delta for an already-matching row", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const preservedTimestamp = "2001-02-03 04:05:06";
    context.db
      .prepare(
        `
        UPDATE components
        SET status = ?, inactive_reason = ?, updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run(
        "inactive",
        "temporarily disabled",
        preservedTimestamp,
        PROJECT_ID,
        "core:UserService"
      );

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "set_status", "core:UserService") as { total: number };
    expect(deltaCountBefore.total).toBe(0);

    const first = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(first).toMatchObject({
      applied: true,
      semantic_id: "core:UserService",
      old_status: "inactive",
      new_status: "inactive",
      updated_at: preservedTimestamp
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "set_status", "core:UserService") as { total: number };
    expect(deltaCountAfter.total).toBe(1);

    const second = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(second).toMatchObject({
      applied: false,
      semantic_id: "core:UserService",
      old_status: "inactive",
      new_status: "inactive",
      updated_at: preservedTimestamp
    });
  });

  it("set_status reports applied when it restores a drifted row after delta was already recorded", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const first = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(first.applied).toBe(true);

    const driftTimestamp = "2001-02-03 04:05:06";
    context.db
      .prepare(
        `
        UPDATE components
        SET status = ?, inactive_reason = ?, updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run("active", null, driftTimestamp, PROJECT_ID, "core:UserService");

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "set_status", "core:UserService") as { total: number };
    expect(deltaCountBefore.total).toBe(1);

    const restored = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });

    expect(restored).toMatchObject({
      applied: true,
      semantic_id: "core:UserService",
      old_status: "active",
      new_status: "inactive",
      updated_at: expect.any(String)
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "set_status", "core:UserService") as { total: number };
    expect(deltaCountAfter.total).toBe(1);

    const row = context.db
      .prepare(
        `
        SELECT status, inactive_reason
        FROM components
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "core:UserService") as {
      status: string;
      inactive_reason: string | null;
    };
    expect(row).toMatchObject({
      status: "inactive",
      inactive_reason: "temporarily disabled"
    });
  });

  it("marks component as deleted and query can include deleted status", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const deleted = handleRegistryDelete(context, {
      project_id: PROJECT_ID,
      semantic_id: "core:UserService",
      reason: "deprecated component"
    });
    expect(deleted.applied).toBe(true);
    expect(deleted.semantic_id).toBe("core:UserService");

    const queriedDeleted = handleRegistryQuery(context, {
      status: "deleted"
    });

    expect(queriedDeleted.total).toBe(1);
    expect(queriedDeleted.items).toHaveLength(1);
    expect(queriedDeleted.items[0].semantic_id).toBe("core:UserService");
  });

  it("delete retry is idempotent and preserves updated_at", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const first = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    const preservedTimestamp = "2002-03-04 05:06:07";
    context.db
      .prepare(
        `
        UPDATE components
        SET updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run(preservedTimestamp, PROJECT_ID, "core:UserService");

    const second = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    expect(first.applied).toBe(true);
    expect(second).toMatchObject({
      applied: false,
      semantic_id: "core:UserService",
      deleted_at: preservedTimestamp
    });

    const row = context.db
      .prepare(
        `
        SELECT updated_at
        FROM components
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "core:UserService") as { updated_at: string };
    expect(row.updated_at).toBe(preservedTimestamp);
  });

  it("delete reports applied when it restores a drifted row after delta was already recorded", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const first = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    expect(first.applied).toBe(true);

    const driftTimestamp = "2002-03-04 05:06:07";
    context.db
      .prepare(
        `
        UPDATE components
        SET status = 'active', inactive_reason = NULL, updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run(driftTimestamp, PROJECT_ID, "core:UserService");

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "delete", "core:UserService") as { total: number };
    expect(deltaCountBefore.total).toBe(1);

    const restored = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    expect(restored).toMatchObject({
      applied: true,
      semantic_id: "core:UserService",
      deleted_at: expect.any(String)
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "delete", "core:UserService") as { total: number };
    expect(deltaCountAfter.total).toBe(1);

    const row = context.db
      .prepare(
        `
        SELECT status, inactive_reason
        FROM components
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "core:UserService") as {
      status: string;
      inactive_reason: string | null;
    };
    expect(row).toMatchObject({
      status: "deleted",
      inactive_reason: "deprecated component"
    });
  });

  it("delete reports applied when it records the delta for an already-deleted row", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    const preservedTimestamp = "2002-03-04 05:06:07";
    context.db
      .prepare(
        `
        UPDATE components
        SET status = 'deleted', inactive_reason = ?, updated_at = ?
        WHERE project_id = ? AND semantic_id = ?
      `
      )
      .run(
        "deprecated component",
        preservedTimestamp,
        PROJECT_ID,
        "core:UserService"
      );

    const deltaCountBefore = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "delete", "core:UserService") as { total: number };
    expect(deltaCountBefore.total).toBe(0);

    const first = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    expect(first).toMatchObject({
      applied: true,
      semantic_id: "core:UserService",
      deleted_at: preservedTimestamp
    });

    const deltaCountAfter = context.db
      .prepare(
        `
        SELECT COUNT(*) AS total
        FROM registry_deltas
        WHERE project_id = ? AND delta_type = ? AND semantic_id = ?
      `
      )
      .get(PROJECT_ID, "delete", "core:UserService") as { total: number };
    expect(deltaCountAfter.total).toBe(1);

    const second = handleRegistryDelete(context, {
      logical_id: "core:UserService",
      reason: "deprecated component"
    });

    expect(second).toMatchObject({
      applied: false,
      semantic_id: "core:UserService",
      deleted_at: preservedTimestamp
    });
  });

  it("accepts matching inactive_reason/reason aliases and rejects conflicts", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT, SECOND_COMPONENT_INPUT]
    });

    const updated = handleRegistrySetStatus(context, {
      logical_id: "core:UserService",
      status: "inactive",
      inactive_reason: "temporarily disabled",
      reason: "temporarily disabled"
    });

    expect(updated).toMatchObject({
      applied: true,
      semantic_id: "core:UserService",
      new_status: "inactive"
    });

    expect(() =>
      handleRegistrySetStatus(context, {
        logical_id: "core:UserService",
        status: "inactive",
        inactive_reason: "temporarily disabled",
        reason: "different reason"
      })
    ).toThrow(/inactive_reason\/reason aliases must match/);

    const deleted = handleRegistryDelete(context, {
      logical_id: "core:AuditService",
      reason: "deprecated component",
      inactive_reason: "deprecated component"
    });

    expect(deleted).toMatchObject({
      applied: true,
      semantic_id: "core:AuditService"
    });

    expect(() =>
      handleRegistryDelete(context, {
        logical_id: "core:AuditService",
        reason: "one",
        inactive_reason: "two"
      })
    ).toThrow(/inactive_reason\/reason aliases must match/);
  });

  it("supports delta aliases and idempotent upsert for normalized components", () => {
    const first = handleRegistryUpsert(context, {
      project_id: PROJECT_ID,
      delta: {
        after: {
          module: "core",
          symbol: "BillingService",
          file: "src/core/billing-service.ts",
          kind: "class",
          exported: ["BillingService"],
          dependencies: ["dep:clock"],
          _status: "inactive",
          _inactive_reason: "warming up"
        }
      }
    });

    expect(first).toEqual({
      applied: true,
      new_count: 1,
      updated_count: 0
    });

    const second = handleRegistryUpsert(context, {
      project_id: PROJECT_ID,
      delta: {
        after: {
          module: "core",
          symbol: "BillingService",
          file: "src/core/billing-service.ts",
          kind: "class",
          exported: ["BillingService"],
          dependencies: ["dep:clock"],
          _status: "inactive",
          _inactive_reason: "warming up"
        }
      }
    });

    expect(second).toEqual({
      applied: false,
      new_count: 0,
      updated_count: 0
    });

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      status: "inactive",
      path: "src/core/",
      symbol: "Billing"
    });

    expect(queried.total).toBe(1);
    expect(queried.items[0]).toMatchObject({
      semantic_id: "core:BillingService",
      path: "src/core/billing-service.ts",
      symbol: "BillingService"
    });
  });

  it.each([
    {
      field: "exports",
      overrides: { exports: "UserService" },
      expected: /exports must be an array/
    },
    {
      field: "exported",
      overrides: { exported: "UserService" },
      expected: /exported must be an array/
    },
    {
      field: "imports",
      overrides: { imports: "dep:logger" },
      expected: /imports must be an array/
    },
    {
      field: "dependencies",
      overrides: { dependencies: "dep:clock" },
      expected: /dependencies must be an array/
    }
  ])("rejects non-array $field alias payloads", ({ overrides, expected }) => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "ArrayContractService",
            file_path: "src/core/array-contract-service.ts",
            kind: "class",
            ...overrides
          }
        ]
      })
    ).toThrow(expected);
  });

  it("rejects nested delta envelope project_id mismatches before unwrap", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        project_id: PROJECT_ID,
        delta: {
          project_id: "other-project",
          components: [COMPONENT_INPUT]
        }
      })
    ).toThrow(/delta\.project_id must match context project_id/);

    expect(() =>
      handleRegistryUpsert(context, {
        project_id: PROJECT_ID,
        delta: {
          deltas: [
            {
              project_id: "other-project",
              after: {
                module: "core",
                symbol: "BillingService",
                file: "src/core/billing-service.ts",
                kind: "class"
              }
            }
          ]
        }
      })
    ).toThrow(/delta\.project_id must match context project_id/);

    expect(() =>
      handleRegistryUpsert(context, {
        project_id: PROJECT_ID,
        delta: {
          value: {
            project_id: "other-project",
            module: "core",
            symbol: "BillingService",
            file: "src/core/billing-service.ts",
            kind: "class"
          }
        }
      })
    ).toThrow(/delta\.value\.project_id must match context project_id/);
  });

  it("rejects multi-branch delta envelopes that would otherwise ignore sibling branches", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        project_id: PROJECT_ID,
        delta: {
          components: [COMPONENT_INPUT],
          after: {
            module: "core",
            symbol: "ShadowService",
            file: "src/core/shadow-service.ts",
            kind: "class"
          }
        }
      })
    ).toThrow(/upsert input\.delta contains unexpected keys: after/);

    expect(() =>
      handleRegistryUpsert(context, {
        project_id: PROJECT_ID,
        delta: {
          component: {
            module: "core",
            name: "BranchA",
            file_path: "src/core/branch-a.ts",
            kind: "class"
          },
          after: {
            module: "core",
            name: "BranchB",
            file_path: "src/core/branch-b.ts",
            kind: "class"
          }
        }
      })
    ).toThrow(/upsert input\.delta must specify exactly one of component\/after\/value/);
  });

  it("collects both delta.components and delta.deltas in a mixed envelope", () => {
    const result = handleRegistryUpsert(context, {
      project_id: PROJECT_ID,
      delta: {
        components: [
          {
            module: "core",
            name: "BillingService",
            file_path: "src/core/billing-service.ts",
            kind: "class"
          }
        ],
        deltas: [
          {
            after: {
              module: "core",
              symbol: "AuditTrailService",
              file: "src/core/audit-trail-service.ts",
              kind: "class"
            }
          }
        ]
      }
    });

    expect(result).toEqual({
      applied: true,
      new_count: 2,
      updated_count: 0
    });

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      pathPrefix: "src/core/",
      statuses: ["active"]
    });

    expect(queried.total).toBe(2);
    expect(queried.items.map((item) => item.semantic_id).sort()).toEqual([
      "core:AuditTrailService",
      "core:BillingService"
    ]);
  });

  it("rejects alias collisions instead of silently dropping component data", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            symbol: "OtherAliasService",
            file_path: "src/core/alias-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/identifier sources must resolve to the same semantic_id/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            file_path: "src/core/alias-service.ts",
            path: "src/core/other-alias-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/file_path\/path\/file aliases must match/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            file_path: "src/core/alias-service.ts",
            exports: ["AliasService"],
            exported: ["OtherAliasService"]
          }
        ]
      })
    ).toThrow(/exports\/exported aliases must match/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            file_path: "src/core/alias-service.ts",
            imports: ["dep:logger"],
            dependencies: ["dep:clock"]
          }
        ]
      })
    ).toThrow(/imports\/dependencies aliases must match/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            file_path: "src/core/alias-service.ts",
            status: "active",
            _status: "inactive"
          }
        ]
      })
    ).toThrow(/status\/_status aliases must match/);

    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            module: "core",
            name: "AliasService",
            file_path: "src/core/alias-service.ts",
            inactive_reason: "one",
            _inactive_reason: "two",
            status: "inactive"
          }
        ]
      })
    ).toThrow(/inactive_reason\/_inactive_reason aliases must match/);
  });

  it("supports query aliases with status filtering and limit-offset normalization", () => {
    handleRegistryUpsert(context, {
      components: [
        COMPONENT_INPUT,
        SECOND_COMPONENT_INPUT,
        {
          module: "core",
          name: "BillingService",
          path: "src/core/billing-service.ts",
          kind: "class",
          status: "inactive"
        }
      ]
    });

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      pathPrefix: "src/core/",
      namePartial: "Service",
      statuses: ["active", "inactive"],
      limit: "1",
      offset: "1"
    });

    expect(queried.total).toBe(3);
    expect(queried.items).toHaveLength(1);
    expect(queried.items[0]).toMatchObject({
      semantic_id: "core:BillingService",
      path: "src/core/billing-service.ts",
      symbol: "BillingService"
    });
  });

  it("rejects partial numeric query strings and accepts full integer strings", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        limit: "1abc"
      })
    ).toThrow(/limit must be an integer/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        offset: "12xyz"
      })
    ).toThrow(/offset must be an integer/);

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      limit: "1",
      offset: "0",
      name: "UserService"
    });

    expect(queried.total).toBe(1);
    expect(queried.items).toHaveLength(1);
  });

  it("rejects null query pagination values", () => {
    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        limit: null
      })
    ).toThrow(/limit must not be null/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        offset: null
      })
    ).toThrow(/offset must not be null/);
  });

  it("requires matching values across query aliases", () => {
    handleRegistryUpsert(context, {
      components: [
        COMPONENT_INPUT,
        SECOND_COMPONENT_INPUT,
        {
          module: "core",
          name: "BillingService",
          path: "src/core/billing-service.ts",
          kind: "class",
          status: "inactive"
        }
      ]
    });

    const queried = handleRegistryQuery(context, {
      project_id: PROJECT_ID,
      path_prefix: "src/core/",
      pathPrefix: "src/core/",
      path: "src/core/",
      name_partial: "Service",
      namePartial: "Service",
      name: "Service",
      symbol: "Service",
      status: "active",
      statuses: ["active"]
    });

    expect(queried.total).toBe(2);
    expect(queried.items.map((item) => item.semantic_id).sort()).toEqual([
      "core:AuditService",
      "core:UserService"
    ]);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        path_prefix: "src/core/",
        path: "src/other/"
      })
    ).toThrow(/path_prefix\/pathPrefix\/path aliases must match/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        name_partial: "Service",
        symbol: "Widget"
      })
    ).toThrow(/name_partial\/namePartial\/name\/symbol aliases must match/);

    expect(() =>
      handleRegistryQuery(context, {
        project_id: PROJECT_ID,
        status: "active",
        statuses: ["inactive"]
      })
    ).toThrow(/status\/statuses aliases must resolve to the same effective set/);
  });

  it("rejects explicit project_id mismatches across registry handlers", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        project_id: "other-project",
        components: [COMPONENT_INPUT]
      })
    ).toThrow(/project_id must match context project_id/);

    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistryQuery(context, {
        project_id: "other-project",
        name: "UserService"
      })
    ).toThrow(/project_id must match context project_id/);
    expect(() =>
      handleRegistrySetStatus(context, {
        project_id: "other-project",
        logical_id: "core:UserService",
        status: "inactive"
      })
    ).toThrow(/project_id must match context project_id/);
    expect(() =>
      handleRegistryDelete(context, {
        project_id: "other-project",
        logical_id: "core:UserService"
      })
    ).toThrow(/project_id must match context project_id/);
  });

  it("rejects identifier-less upsert components to match runtime contract", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            file_path: "src/core/missing-identifier.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/semantic_id is required/);

    expect(() =>
      handleRegistryUpsert(context, {
        file_path: "src/core/missing-identifier-top-level.ts",
        kind: "class"
      })
    ).toThrow(/semantic_id is required/);
  });

  it("rejects identifier-less set_status and delete payloads", () => {
    expect(() =>
      handleRegistrySetStatus(context, {
        status: "inactive"
      })
    ).toThrow(/semantic_id is required/);

    expect(() =>
      handleRegistryDelete(context, {
        reason: "deprecated component"
      })
    ).toThrow(/semantic_id is required/);
  });

  it("rejects conflicting identifier sources across upsert and mutation handlers", () => {
    expect(() =>
      handleRegistryUpsert(context, {
        components: [
          {
            semantic_id: "core:UserService",
            logical_id: "core:AuditService",
            module: "core",
            name: "UserService",
            file_path: "src/core/user-service.ts",
            kind: "class"
          }
        ]
      })
    ).toThrow(/identifier sources must resolve to the same semantic_id/);

    handleRegistryUpsert(context, {
      components: [COMPONENT_INPUT]
    });

    expect(() =>
      handleRegistrySetStatus(context, {
        semantic_id: "core:UserService",
        logical_id: "core:AuditService",
        status: "inactive"
      })
    ).toThrow(/identifier sources must resolve to the same semantic_id/);

    expect(() =>
      handleRegistryDelete(context, {
        semantic_id: "core:UserService",
        module: "core",
        name: "AuditService"
      })
    ).toThrow(/identifier sources must resolve to the same semantic_id/);
  });
});

function createTestContext(): {
  context: DatabaseContext;
  cleanup: () => void;
} {
  const tempDir = mkdtempSync(join(tmpdir(), "semantic-mcp-registry-test-"));
  const dbPath = join(tempDir, "semantic.db");
  const db = new BetterSqlite3(dbPath);
  runMigrations(db);

  db.prepare(
    `
      INSERT INTO projects (id, name, root_path, created_at, updated_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `
  ).run(PROJECT_ID, "Test Project", "/tmp/test-project");

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
