import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type Tool
} from "@modelcontextprotocol/sdk/types.js";
import type { DatabaseContext } from "./db/connection.js";
import { handleCapsule, toCapsuleInput } from "./tools/capsule.js";
import { handleHealth } from "./tools/health.js";
import { toPreflightInput } from "./tools/dependency.js";
import { handlePreflight } from "./tools/preflight.js";
import {
  handleRegistryDelete,
  handleRegistryQuery,
  handleRegistrySetStatus,
  handleRegistryUpsert
} from "./tools/registry.js";
import { handleSearch } from "./tools/search.js";
import {
  SERVER_NAME,
  SERVER_VERSION,
  TOOL_NAMES,
  type ToolName,
  type ToolPayload
} from "./types.js";

export const REGISTRY_STATUS_ENUM = [
  "active",
  "inactive",
  "incomplete",
  "buggy",
  "deprecated",
  "deleted"
] as const;

export const REGISTRY_MUTABLE_STATUS_ENUM = REGISTRY_STATUS_ENUM.filter(
  (status) => status !== "deleted"
);

export const REGISTRY_IDENTIFIER_REQUIREMENTS = [
  { required: ["semantic_id"] },
  { required: ["logical_id"] },
  { required: ["module", "name"] },
  { required: ["module", "symbol"] }
] as const;

export const REGISTRY_INTEGER_STRING_SCHEMA = {
  type: "string",
  pattern: "^-?\\d+$"
} as const;

export const REGISTRY_INTEGER_INPUT_SCHEMA = {
  anyOf: [{ type: "integer" }, REGISTRY_INTEGER_STRING_SCHEMA]
} as const;

export const REGISTRY_NON_EMPTY_STRING_SCHEMA = {
  type: "string",
  pattern: "\\S"
} as const;

export const REGISTRY_SEMANTIC_ID_SCHEMA = {
  type: "string",
  pattern: "^[^:\\s]+:[^:\\s]+$"
} as const;

const REGISTRY_NON_EMPTY_COMPONENTS_BRANCH = {
  required: ["components"],
  properties: {
    components: {
      type: "array",
      minItems: 1
    }
  }
} as const;

const REGISTRY_NON_EMPTY_DELTAS_BRANCH = {
  required: ["deltas"],
  properties: {
    deltas: {
      type: "array",
      minItems: 1
    }
  }
} as const;

export const REGISTRY_COMPONENT_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    semantic_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    logical_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    name: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbol: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    module: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    file_path: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    path: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    file: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    kind: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    exports: { type: "array" },
    exported: { type: "array" },
    imports: { type: "array" },
    dependencies: { type: "array" },
    hash: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    figma_ref: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    status: { type: "string", enum: REGISTRY_STATUS_ENUM },
    _status: { type: "string", enum: REGISTRY_STATUS_ENUM },
    inactive_reason: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    _inactive_reason: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    security_level: REGISTRY_NON_EMPTY_STRING_SCHEMA
  },
  anyOf: REGISTRY_IDENTIFIER_REQUIREMENTS,
  additionalProperties: false
} as const;

export const REGISTRY_DELTA_ALIAS_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    component: REGISTRY_COMPONENT_SCHEMA,
    after: REGISTRY_COMPONENT_SCHEMA,
    value: REGISTRY_COMPONENT_SCHEMA
  },
  oneOf: [
    { required: ["component"] },
    { required: ["after"] },
    { required: ["value"] }
  ],
  additionalProperties: false
} as const;

export const REGISTRY_DELTA_ITEM_SCHEMA = {
  oneOf: [
    REGISTRY_COMPONENT_SCHEMA,
    REGISTRY_DELTA_ALIAS_SCHEMA
  ]
} as const;

const REGISTRY_NON_EMPTY_DELTA_ITEMS_ARRAY_SCHEMA = {
  type: "array",
  items: REGISTRY_DELTA_ITEM_SCHEMA,
  minItems: 1
} as const;

export const REGISTRY_DELTA_COLLECTION_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    components: {
      type: "array",
      items: REGISTRY_COMPONENT_SCHEMA
    },
    deltas: {
      type: "array",
      items: REGISTRY_DELTA_ITEM_SCHEMA
    }
  },
  anyOf: [REGISTRY_NON_EMPTY_COMPONENTS_BRANCH, REGISTRY_NON_EMPTY_DELTAS_BRANCH],
  additionalProperties: false
} as const;

export const REGISTRY_UPSERT_COLLECTION_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    components: {
      type: "array",
      items: REGISTRY_COMPONENT_SCHEMA
    },
    deltas: {
      type: "array",
      items: REGISTRY_DELTA_ITEM_SCHEMA
    }
  },
  anyOf: [REGISTRY_NON_EMPTY_COMPONENTS_BRANCH, REGISTRY_NON_EMPTY_DELTAS_BRANCH],
  additionalProperties: false
} as const;

export const REGISTRY_UPSERT_ALIAS_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    delta: {
      oneOf: [
        REGISTRY_COMPONENT_SCHEMA,
        REGISTRY_NON_EMPTY_DELTA_ITEMS_ARRAY_SCHEMA,
        REGISTRY_DELTA_COLLECTION_SCHEMA,
        REGISTRY_DELTA_ALIAS_SCHEMA
      ]
    }
  },
  required: ["delta"],
  additionalProperties: false
} as const;

export const REGISTRY_UPSERT_ENVELOPE_SCHEMA = {
  oneOf: [REGISTRY_UPSERT_COLLECTION_SCHEMA, REGISTRY_UPSERT_ALIAS_SCHEMA]
} as const;

export const REGISTRY_UPSERT_INPUT_SCHEMA = {
  type: "object",
  properties: {
    ...REGISTRY_COMPONENT_SCHEMA.properties,
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    components: {
      type: "array",
      items: REGISTRY_COMPONENT_SCHEMA
    },
    deltas: {
      type: "array",
      items: REGISTRY_DELTA_ITEM_SCHEMA
    },
    delta: {
      oneOf: [
        REGISTRY_COMPONENT_SCHEMA,
        REGISTRY_NON_EMPTY_DELTA_ITEMS_ARRAY_SCHEMA,
        REGISTRY_DELTA_COLLECTION_SCHEMA,
        REGISTRY_DELTA_ALIAS_SCHEMA
      ]
    }
  },
  additionalProperties: false
} as const;

export const REGISTRY_QUERY_INPUT_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    semantic_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    kind: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    path_prefix: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    pathPrefix: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    path: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    name: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbol: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    name_exact: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    nameExact: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbol_exact: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbolExact: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    name_partial: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    namePartial: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    status: {
      type: "string",
      enum: REGISTRY_STATUS_ENUM
    },
    statuses: {
      type: "array",
      items: {
        type: "string",
        enum: REGISTRY_STATUS_ENUM
      }
    },
    limit: REGISTRY_INTEGER_INPUT_SCHEMA,
    offset: REGISTRY_INTEGER_INPUT_SCHEMA
  },
  additionalProperties: false
} as const;

export const REGISTRY_SET_STATUS_INPUT_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    semantic_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    logical_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    module: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    name: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbol: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    status: {
      type: "string",
      enum: REGISTRY_MUTABLE_STATUS_ENUM
    },
    inactive_reason: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    reason: REGISTRY_NON_EMPTY_STRING_SCHEMA
  },
  required: ["status"],
  additionalProperties: false
} as const;

export const REGISTRY_DELETE_INPUT_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    semantic_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    logical_id: REGISTRY_SEMANTIC_ID_SCHEMA,
    module: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    name: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    symbol: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    reason: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    inactive_reason: REGISTRY_NON_EMPTY_STRING_SCHEMA
  },
  additionalProperties: false
} as const;

export const SEARCH_INPUT_SCHEMA = {
  type: "object",
  properties: {
    project_id: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    query: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    scope_paths: {
      type: "array",
      items: REGISTRY_NON_EMPTY_STRING_SCHEMA,
      minItems: 1
    },
    scopePaths: {
      type: "array",
      items: REGISTRY_NON_EMPTY_STRING_SCHEMA,
      minItems: 1
    },
    kind: REGISTRY_NON_EMPTY_STRING_SCHEMA,
    limit: REGISTRY_INTEGER_INPUT_SCHEMA,
    capsule_budget_tokens: REGISTRY_INTEGER_INPUT_SCHEMA,
    capsuleBudgetTokens: REGISTRY_INTEGER_INPUT_SCHEMA
  },
  required: ["query"],
  anyOf: [
    { required: ["scope_paths"] },
    { required: ["scopePaths"] }
  ],
  additionalProperties: false
} as const;

const TOOL_DEFINITIONS = [
  {
    name: TOOL_NAMES.PREFLIGHT,
    description: "Validate planned semantic changes before applying updates.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string"
        },
        task_id: {
          type: "string"
        },
        scope: {
          type: "array",
          items: {
            type: "string"
          }
        },
        proposed_components: {
          type: "array",
          items: {
            type: "string"
          }
        },
        deleted_paths: {
          type: "array",
          items: {
            type: "string"
          }
        },
        removed_symbols: {
          type: "array",
          items: {
            type: "string"
          }
        },
        move_candidates: {
          type: "array",
          items: {
            type: "object",
            properties: {
              old_path: { type: "string" },
              new_path: { type: "string" }
            },
            required: ["old_path", "new_path"],
            additionalProperties: false
          }
        },
        adjacency_path: {
          type: "string"
        },
        dependency_verdict: {
          type: "object",
          properties: {
            status: {
              type: "string",
              enum: ["pass", "warn", "block"]
            },
            issues: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  package: { type: "string" },
                  severity: {
                    type: "string",
                    enum: ["critical", "high", "medium", "low"]
                  },
                  message: { type: "string" }
                },
                required: ["package", "severity", "message"],
                additionalProperties: false
              }
            },
            checked_at: { type: "string" }
          },
          required: ["status", "issues", "checked_at"],
          additionalProperties: false
        }
      },
      required: ["project_id", "task_id", "scope", "proposed_components"],
      additionalProperties: false
    }
  },
  {
    name: TOOL_NAMES.CAPSULE,
    description: "Generate a compact semantic capsule for current task context.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string"
        },
        task_id: {
          type: "string"
        },
        phase: {
          type: "string"
        },
        budget: {
          type: "integer"
        },
        context: {
          type: "object",
          properties: {
            changed_symbols: {
              type: "array",
              items: { type: "string" }
            },
            top_k_symbols: {
              type: "array",
              items: { type: "string" }
            },
            preflight_verdict: {
              type: "string"
            }
          },
          additionalProperties: false
        }
      },
      required: ["project_id", "task_id", "phase"],
      additionalProperties: false
    }
  },
  {
    name: TOOL_NAMES.REGISTRY_UPSERT,
    description: "Apply registry delta updates with idempotency tracking.",
    inputSchema: REGISTRY_UPSERT_INPUT_SCHEMA
  },
  {
    name: TOOL_NAMES.REGISTRY_QUERY,
    description: "Query semantic registry entries with compact result fields.",
    inputSchema: REGISTRY_QUERY_INPUT_SCHEMA
  },
  {
    name: TOOL_NAMES.REGISTRY_SET_STATUS,
    description: "Set component lifecycle status in semantic registry.",
    inputSchema: REGISTRY_SET_STATUS_INPUT_SCHEMA
  },
  {
    name: TOOL_NAMES.REGISTRY_DELETE,
    description: "Logically delete semantic registry entries by identifier.",
    inputSchema: REGISTRY_DELETE_INPUT_SCHEMA
  },
  {
    name: TOOL_NAMES.SEARCH,
    description: "Bounded advisory semantic search over explicit repo-relative scopes.",
    inputSchema: SEARCH_INPUT_SCHEMA
  },
  {
    name: TOOL_NAMES.HEALTH,
    description: "Check server health, database connectivity, and table readiness.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  }
];

export function createSemanticServer(context: DatabaseContext): Server {
  try {
    const server = new Server(
      {
        name: SERVER_NAME,
        version: SERVER_VERSION
      },
      {
        capabilities: {
          tools: {}
        }
      }
    );

    server.setRequestHandler(ListToolsRequestSchema, async () => {
      return { tools: TOOL_DEFINITIONS as Tool[] };
    });

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      try {
        const name = request.params.name as ToolName;
        const input = request.params.arguments;
        const payload = executeTool(name, context, input);
        return asCallToolResult(payload);
      } catch (error) {
        console.error(`[semantic-mcp-server] tool error: ${toErrorMessage(error)}`);
        return asCallToolError(toErrorMessage(error));
      }
    });

    return server;
  } catch (error) {
    throw new Error(`Failed to create server: ${toErrorMessage(error)}`);
  }
}

function executeTool(name: ToolName, context: DatabaseContext, input: unknown): ToolPayload {
  try {
    switch (name) {
      case TOOL_NAMES.PREFLIGHT:
        return handlePreflight(context, toPreflightInput(input));
      case TOOL_NAMES.CAPSULE:
        return handleCapsule(context, toCapsuleInput(input));
      case TOOL_NAMES.REGISTRY_UPSERT:
        return handleRegistryUpsert(context, input);
      case TOOL_NAMES.REGISTRY_QUERY:
        return handleRegistryQuery(context, input);
      case TOOL_NAMES.REGISTRY_SET_STATUS:
        return handleRegistrySetStatus(context, input);
      case TOOL_NAMES.REGISTRY_DELETE:
        return handleRegistryDelete(context, input);
      case TOOL_NAMES.SEARCH:
        return handleSearch(context, input);
      case TOOL_NAMES.HEALTH:
        return handleHealth(context);
      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    throw new Error(`Tool execution failed: ${toErrorMessage(error)}`);
  }
}

function asCallToolResult(payload: ToolPayload): { content: Array<{ type: "text"; text: string }> } {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload)
      }
    ]
  };
}

function asCallToolError(message: string): {
  isError: true;
  content: Array<{ type: "text"; text: string }>;
} {
  return {
    isError: true,
    content: [
      {
        type: "text",
        text: message
      }
    ]
  };
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
