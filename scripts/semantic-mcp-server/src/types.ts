export const SERVER_NAME = "semantic-mcp-server";
export const SERVER_VERSION = "0.1.0";

export const TOOL_NAMES = {
  PREFLIGHT: "sem.preflight",
  CAPSULE: "sem.capsule",
  REGISTRY_UPSERT: "sem.registry.upsert",
  REGISTRY_QUERY: "sem.registry.query",
  REGISTRY_SET_STATUS: "sem.registry.set_status",
  REGISTRY_DELETE: "sem.registry.delete",
  SEARCH: "sem.search",
  HEALTH: "sem.health"
} as const;

export type ToolName = (typeof TOOL_NAMES)[keyof typeof TOOL_NAMES];

export const REQUIRED_TABLES = [
  "projects",
  "components",
  "registry_deltas",
  "capsules",
  "outbox_queue",
  "review_queue_items",
  "review_runs"
] as const;

export type RequiredTable = (typeof REQUIRED_TABLES)[number];

export interface HealthResponse {
  status: "ok";
  tables: string[];
  version: string;
  tool_count: number;
  capsule_retention: {
    mode: "threshold-driven-on-write";
    trigger_project_row_count: number;
    project_hard_cap: number;
    preflight_keep_latest_per_task: number;
    non_preflight_keep_latest_per_task_phase: number;
    current_project_row_count: number;
    prune_eligible_row_count: number;
  };
}

export interface StubResponse {
  status: "not_implemented";
  message: "not implemented yet";
  tool: ToolName;
}

export interface DependencyVerdict {
  status: "pass" | "warn" | "block";
  issues: Array<{
    package: string;
    severity: "critical" | "high" | "medium" | "low";
    message: string;
  }>;
  checked_at: string;
}

export interface MoveCandidate {
  old_path: string;
  new_path: string;
}

export interface PreflightInput {
  project_id: string;
  task_id: string;
  scope: string[];
  proposed_components: string[];
  deleted_paths?: string[];
  removed_symbols?: string[];
  move_candidates?: MoveCandidate[];
  adjacency_path?: string;
  dependency_verdict?: DependencyVerdict;
}

export type PreflightVerdict = "BLOCK" | "WARN" | "PASS";

export interface PreflightConflict {
  semantic_id: string;
  reason: string;
}

export interface PreflightSignal {
  status: "none" | "clear" | "warn" | "blocked";
  summary: string;
}

export interface PreflightResponse {
  verdict: PreflightVerdict;
  conflicts: PreflightConflict[];
  delete_impacts_summary: string;
  capsule: string;
  target_lock: PreflightSignal;
  ambiguity: PreflightSignal;
  duplicate_risk: PreflightSignal;
  dependency_verdict?: DependencyVerdict;
}

export interface CapsuleInput {
  project_id: string;
  task_id: string;
  phase: string;
  budget?: number;
  context?: {
    changed_symbols?: string[];
    top_k_symbols?: string[];
    preflight_verdict?: string;
    target_lock?: PreflightSignal | string;
    ambiguity?: PreflightSignal | string;
    duplicate_risk?: PreflightSignal | string;
  };
}

export interface CapsuleResponse {
  capsule: string;
  constraints: string[];
  hints: string[];
}

export type RegistryStatus =
  | "active"
  | "inactive"
  | "incomplete"
  | "buggy"
  | "deprecated"
  | "deleted";

export type RegistrySemanticId = `${string}:${string}`;

export const REGISTRY_COMPONENT_ALLOWED_KEYS = [
  "project_id",
  "semantic_id",
  "logical_id",
  "name",
  "symbol",
  "module",
  "file_path",
  "path",
  "file",
  "kind",
  "exports",
  "exported",
  "imports",
  "dependencies",
  "hash",
  "figma_ref",
  "status",
  "_status",
  "inactive_reason",
  "_inactive_reason",
  "security_level",
] as const;

export const REGISTRY_DELTA_COLLECTION_ALLOWED_KEYS = [
  "project_id",
  "components",
  "deltas"
] as const;

export const REGISTRY_DELTA_ALIAS_ALLOWED_KEYS = [
  "project_id",
  "component",
  "after",
  "value"
] as const;

export const REGISTRY_UPSERT_COLLECTION_ALLOWED_KEYS = [
  "project_id",
  "components",
  "deltas"
] as const;

export const REGISTRY_UPSERT_ALIAS_ALLOWED_KEYS = [
  "project_id",
  "delta"
] as const;

export const REGISTRY_QUERY_ALLOWED_KEYS = [
  "project_id",
  "semantic_id",
  "kind",
  "path_prefix",
  "pathPrefix",
  "path",
  "name",
  "symbol",
  "name_exact",
  "nameExact",
  "symbol_exact",
  "symbolExact",
  "name_partial",
  "namePartial",
  "status",
  "statuses",
  "limit",
  "offset"
] as const;

export const REGISTRY_SET_STATUS_ALLOWED_KEYS = [
  "project_id",
  "semantic_id",
  "logical_id",
  "module",
  "name",
  "symbol",
  "status",
  "inactive_reason",
  "reason"
] as const;

export const REGISTRY_DELETE_ALLOWED_KEYS = [
  "project_id",
  "semantic_id",
  "logical_id",
  "module",
  "name",
  "symbol",
  "reason",
  "inactive_reason"
] as const;

export const SEARCH_ALLOWED_KEYS = [
  "project_id",
  "query",
  "scope_paths",
  "scopePaths",
  "kind",
  "limit",
  "capsule_budget_tokens",
  "capsuleBudgetTokens"
] as const;

export interface RegistryComponentBaseInput {
  project_id?: RegistryNonBlankString;
  semantic_id?: RegistrySemanticId;
  logical_id?: RegistrySemanticId;
  name?: RegistryNonBlankString;
  symbol?: RegistryNonBlankString;
  module?: RegistryNonBlankString;
  file_path?: RegistryNonBlankString;
  path?: RegistryNonBlankString;
  file?: RegistryNonBlankString;
  kind?: RegistryNonBlankString;
  exports?: unknown[];
  exported?: unknown[];
  imports?: unknown[];
  dependencies?: unknown[];
  hash?: RegistryNonBlankString;
  figma_ref?: RegistryNonBlankString;
  status?: RegistryStatus;
  _status?: RegistryStatus;
  inactive_reason?: RegistryNonBlankString;
  _inactive_reason?: RegistryNonBlankString;
  security_level?: RegistryNonBlankString;
}

export type RegistryComponentInput = RegistryIdentifierInput & RegistryComponentBaseInput;

export type RegistryIntegerString = `${bigint}`;
export type RegistryNonBlankString = string & {
  readonly __registryNonBlankString: "registryNonBlankString";
};

export type RegistryDeltaAliasEnvelopeInput =
  | {
      project_id?: RegistryNonBlankString;
      component: RegistryComponentInput;
      after?: never;
      value?: never;
    }
  | {
      project_id?: RegistryNonBlankString;
      after: RegistryComponentInput;
      component?: never;
      value?: never;
    }
  | {
      project_id?: RegistryNonBlankString;
      value: RegistryComponentInput;
      component?: never;
      after?: never;
    };

export type RegistryDeltaItemInput = RegistryComponentInput | RegistryDeltaAliasEnvelopeInput;

export type RegistryDeltaInput =
  | {
      project_id?: RegistryNonBlankString;
      components: RegistryComponentInput[];
      deltas?: RegistryDeltaItemInput[];
    }
  | {
      project_id?: RegistryNonBlankString;
      deltas: RegistryDeltaItemInput[];
      components?: RegistryComponentInput[];
    };

export type RegistryIdentifierInput =
  | {
      semantic_id: RegistrySemanticId;
    }
  | {
      logical_id: RegistrySemanticId;
    }
  | {
      module: RegistryNonBlankString;
      name: RegistryNonBlankString;
    }
  | {
      module: RegistryNonBlankString;
      symbol: RegistryNonBlankString;
    };

export type RegistryUpsertCollectionEnvelopeInput =
  | {
      project_id?: RegistryNonBlankString;
      components: RegistryComponentInput[];
      deltas?: RegistryDeltaItemInput[];
      delta?: never;
    }
  | {
      project_id?: RegistryNonBlankString;
      deltas: RegistryDeltaItemInput[];
      components?: RegistryComponentInput[];
      delta?: never;
    };

export interface RegistryUpsertAliasEnvelopeInput {
  project_id?: RegistryNonBlankString;
  delta: RegistryDeltaItemInput | RegistryDeltaItemInput[] | RegistryDeltaInput;
  components?: never;
  deltas?: never;
}

export type RegistryUpsertEnvelopeInput =
  | RegistryUpsertCollectionEnvelopeInput
  | RegistryUpsertAliasEnvelopeInput;

export type RegistryUpsertInput = RegistryComponentInput | RegistryUpsertEnvelopeInput;

export interface RegistryQueryInput {
  project_id?: RegistryNonBlankString;
  semantic_id?: RegistrySemanticId;
  kind?: RegistryNonBlankString;
  path_prefix?: RegistryNonBlankString;
  pathPrefix?: RegistryNonBlankString;
  path?: RegistryNonBlankString;
  name?: RegistryNonBlankString;
  symbol?: RegistryNonBlankString;
  name_exact?: RegistryNonBlankString;
  nameExact?: RegistryNonBlankString;
  symbol_exact?: RegistryNonBlankString;
  symbolExact?: RegistryNonBlankString;
  name_partial?: RegistryNonBlankString;
  namePartial?: RegistryNonBlankString;
  status?: RegistryStatus;
  statuses?: RegistryStatus[];
  limit?: number | RegistryIntegerString;
  offset?: number | RegistryIntegerString;
}

export type RegistrySetStatusInput = RegistryIdentifierInput & {
  project_id?: RegistryNonBlankString;
  status: Exclude<RegistryStatus, "deleted">;
  inactive_reason?: RegistryNonBlankString;
  reason?: RegistryNonBlankString;
};

export type RegistryDeleteInput = RegistryIdentifierInput & {
  project_id?: RegistryNonBlankString;
  reason?: RegistryNonBlankString;
  inactive_reason?: RegistryNonBlankString;
};

export interface RegistryUpsertResponse {
  applied: boolean;
  new_count: number;
  updated_count: number;
}

export interface RegistryQueryItem {
  semantic_id: string;
  path: string;
  symbol: string;
  kind: string;
}

export interface RegistryQueryResponse {
  items: RegistryQueryItem[];
  total: number;
  capsule: string;
}

export interface RegistrySetStatusResponse {
  applied: boolean;
  semantic_id: string;
  old_status: string;
  new_status: Exclude<RegistryStatus, "deleted">;
  updated_at: string;
}

export interface RegistryDeleteResponse {
  applied: boolean;
  semantic_id: string;
  deleted_at: string;
}

export interface SearchInput {
  project_id?: RegistryNonBlankString;
  query: RegistryNonBlankString;
  scope_paths?: RegistryNonBlankString[];
  scopePaths?: RegistryNonBlankString[];
  kind?: RegistryNonBlankString;
  limit?: number | RegistryIntegerString;
  capsule_budget_tokens?: number | RegistryIntegerString;
  capsuleBudgetTokens?: number | RegistryIntegerString;
}

export interface SearchItem {
  path: string;
  symbol?: string;
  semantic_id?: string;
  kind?: string;
  line?: number;
  excerpt?: string;
  source: "registry" | "filesystem" | "registry+filesystem";
}

export interface SearchResponse {
  items: SearchItem[];
  total: number;
  truncated: boolean;
  capsule: string;
  advisory_only: true;
}

export type ToolPayload =
  | HealthResponse
  | StubResponse
  | PreflightResponse
  | CapsuleResponse
  | RegistryUpsertResponse
  | RegistryQueryResponse
  | RegistrySetStatusResponse
  | RegistryDeleteResponse
  | SearchResponse;
