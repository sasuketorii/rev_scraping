import { createHash } from "node:crypto";
import type { DatabaseContext } from "../db/connection.js";
import type { CapsuleInput, CapsuleResponse } from "../types.js";

const TOKEN_CHAR_RATIO = 3;
const DEFAULT_BUDGET = 220;
const MAX_BUDGET = 220;
const MAX_BODY_TOKENS = 200;
const META_TOKEN_RESERVE = 20;
const RETENTION_TRIGGER_PROJECT_ROW_COUNT = 256;
const RETENTION_PROJECT_HARD_CAP = 256;
const PREFLIGHT_KEEP_LATEST_PER_TASK = 1;
const NON_PREFLIGHT_KEEP_LATEST_PER_TASK_PHASE = 3;

export interface CapsuleRetentionStatus {
  mode: "threshold-driven-on-write";
  trigger_project_row_count: number;
  project_hard_cap: number;
  preflight_keep_latest_per_task: number;
  non_preflight_keep_latest_per_task_phase: number;
  current_project_row_count: number;
  prune_eligible_row_count: number;
}

interface NormalizedCapsuleInput {
  project_id: string;
  task_id: string;
  phase: string;
  budget: number;
  body_token_budget: number;
  context: {
    changed_symbols: string[];
    top_k_symbols: string[];
    preflight_verdict?: string;
    target_lock?: CapsuleSignal;
    ambiguity?: CapsuleSignal;
    duplicate_risk?: CapsuleSignal;
  };
}

interface CapsuleSignal {
  status: string;
  summary?: string;
}

export function toCapsuleInput(input: unknown): CapsuleInput {
  if (input === null || typeof input !== "object") {
    return {} as CapsuleInput;
  }

  return input as CapsuleInput;
}

export function handleCapsule(
  context: DatabaseContext,
  rawInput: unknown
): CapsuleResponse {
  try {
    const input = normalizeCapsuleInput(context, rawInput);
    const capsule = buildCapsuleBody(input);
    const constraints = [
      `total_tokens<=${input.budget}`,
      `capsule_tokens<=${input.body_token_budget}`,
      "format=key_value_scc",
      "hash=sha256"
    ];
    const hints = buildHints(input);
    const response = fitResponseToBudget(
      {
        capsule,
        constraints,
        hints
      },
      input.budget
    );

    persistCapsule(context, input, response.capsule);
    return response;
  } catch (error) {
    throw new Error(`sem.capsule failed: ${toErrorMessage(error)}`);
  }
}

function normalizeCapsuleInput(
  context: DatabaseContext,
  rawInput: unknown
): NormalizedCapsuleInput {
  if (!isObject(rawInput)) {
    throw new Error("arguments must be an object");
  }

  const projectId = readRequiredString(rawInput, "project_id");
  if (projectId !== context.projectId) {
    throw new Error(
      `project_id mismatch: expected ${context.projectId}, received ${projectId}`
    );
  }

  const taskId = readRequiredString(rawInput, "task_id");
  const phase = readRequiredString(rawInput, "phase");
  const requestedBudget = readOptionalInteger(rawInput.budget, "budget");
  const budget = Math.min(requestedBudget ?? DEFAULT_BUDGET, MAX_BUDGET);
  if (budget <= META_TOKEN_RESERVE) {
    throw new Error("budget too small: requires > 20 tokens");
  }

  const bodyTokenBudget = Math.min(MAX_BODY_TOKENS, budget - META_TOKEN_RESERVE);
  const contextValue = readOptionalObject(rawInput.context);
  const changedSymbols = normalizeOptionalStringArray(
    contextValue?.changed_symbols,
    "context.changed_symbols"
  );
  const topKSymbols = normalizeOptionalStringArray(
    contextValue?.top_k_symbols,
    "context.top_k_symbols"
  );
  const preflightVerdict = normalizeOptionalString(contextValue?.preflight_verdict)?.toUpperCase();
  const targetLock = normalizeOptionalSignal(contextValue?.target_lock, "context.target_lock");
  const ambiguity = normalizeOptionalSignal(contextValue?.ambiguity, "context.ambiguity");
  const duplicateRisk = normalizeOptionalSignal(
    contextValue?.duplicate_risk,
    "context.duplicate_risk"
  );

  return {
    project_id: projectId,
    task_id: taskId,
    phase,
    budget,
    body_token_budget: bodyTokenBudget,
    context: {
      changed_symbols: changedSymbols,
      top_k_symbols: topKSymbols,
      preflight_verdict: preflightVerdict,
      target_lock: targetLock,
      ambiguity,
      duplicate_risk: duplicateRisk
    }
  };
}

function buildCapsuleBody(input: NormalizedCapsuleInput): string {
  const changedDigest = sha256(input.context.changed_symbols.join("\n"));
  const topKDigest = sha256(input.context.top_k_symbols.join("\n"));

  const lines = [
    `TASK=${sanitizeValue(input.task_id)}`,
    `PHASE=${sanitizeValue(input.phase)}`,
    `PROJECT=${sanitizeValue(input.project_id)}`,
    `PREFLIGHT=${sanitizeValue(input.context.preflight_verdict ?? "UNKNOWN")}`,
    `TARGET_LOCK=${sanitizeValue(input.context.target_lock?.status ?? "unknown")}`,
    `AMBIGUITY=${sanitizeValue(input.context.ambiguity?.status ?? "unknown")}`,
    `DUPLICATE_RISK=${sanitizeValue(input.context.duplicate_risk?.status ?? "unknown")}`,
    `CHANGED_COUNT=${input.context.changed_symbols.length}`,
    `CHANGED_SHA256=${changedDigest}`,
    `TOPK_COUNT=${input.context.top_k_symbols.length}`,
    `TOPK_SHA256=${topKDigest}`
  ];

  if (input.context.changed_symbols.length > 0) {
    lines.push(`CHANGED_HEAD=${buildHead(input.context.changed_symbols)}`);
  }

  if (input.context.top_k_symbols.length > 0) {
    lines.push(`TOPK_HEAD=${buildHead(input.context.top_k_symbols)}`);
  }

  let capsule = withCapsuleHash(lines);
  const bodyCharBudget = input.body_token_budget * TOKEN_CHAR_RATIO;
  if (capsule.length > bodyCharBudget) {
    const reduced = [
      `TASK=${sanitizeValue(input.task_id)}`,
      `PHASE=${sanitizeValue(input.phase)}`,
      `PROJECT=${sanitizeValue(input.project_id)}`,
      `PREFLIGHT=${sanitizeValue(input.context.preflight_verdict ?? "UNKNOWN")}`,
      `TARGET_LOCK=${sanitizeValue(input.context.target_lock?.status ?? "unknown")}`,
      `AMBIGUITY=${sanitizeValue(input.context.ambiguity?.status ?? "unknown")}`,
      `DUPLICATE_RISK=${sanitizeValue(input.context.duplicate_risk?.status ?? "unknown")}`,
      `CHANGED_COUNT=${input.context.changed_symbols.length}`,
      `CHANGED_SHA256=${changedDigest}`,
      `TOPK_COUNT=${input.context.top_k_symbols.length}`,
      `TOPK_SHA256=${topKDigest}`
    ];
    capsule = withCapsuleHash(reduced);
  }

  if (capsule.length > bodyCharBudget) {
    throw new Error("capsule body exceeded token budget (fail-closed)");
  }

  return capsule;
}

function buildHints(input: NormalizedCapsuleInput): string[] {
  const hints: string[] = [];

  if (input.context.target_lock) {
    hints.push(`target_lock=${sanitizeValue(input.context.target_lock.status)}`);
  }

  if (input.context.ambiguity) {
    hints.push(`ambiguity=${sanitizeValue(input.context.ambiguity.status)}`);
  }

  if (input.context.duplicate_risk) {
    hints.push(`duplicate_risk=${sanitizeValue(input.context.duplicate_risk.status)}`);
  }

  if (input.context.preflight_verdict) {
    hints.push(`preflight=${sanitizeValue(input.context.preflight_verdict)}`);
  }

  if (input.context.changed_symbols.length > 0) {
    hints.push(`focus_changed=${sanitizeValue(input.context.changed_symbols[0])}`);
  }

  if (input.context.top_k_symbols.length > 0) {
    hints.push(`check_similar=${sanitizeValue(input.context.top_k_symbols[0])}`);
  }

  return hints;
}

function fitResponseToBudget(response: CapsuleResponse, budget: number): CapsuleResponse {
  const maxChars = budget * TOKEN_CHAR_RATIO;
  const compacted: CapsuleResponse = {
    capsule: response.capsule,
    constraints: [...response.constraints],
    hints: [...response.hints]
  };

  while (JSON.stringify(compacted).length > maxChars) {
    if (compacted.hints.length > 0) {
      compacted.hints = compacted.hints.slice(0, compacted.hints.length - 1);
      continue;
    }

    if (compacted.constraints.length > 1) {
      compacted.constraints = compacted.constraints.slice(0, compacted.constraints.length - 1);
      continue;
    }
    throw new Error("capsule response exceeded token budget (fail-closed)");
  }

  return compacted;
}

function persistCapsule(
  context: DatabaseContext,
  input: NormalizedCapsuleInput,
  capsule: string
): void {
  context.db
    .prepare(
      `
      INSERT INTO capsules (
        project_id,
        task_id,
        phase,
        content,
        token_count,
        created_at
      )
      VALUES (?, ?, ?, ?, ?, datetime('now'))
    `
    )
    .run(
      context.projectId,
      input.task_id,
      input.phase,
      capsule,
      estimateTokens(capsule)
    );
  applyCapsuleRetentionAfterWrite(context);
}

export function applyCapsuleRetentionAfterWrite(context: DatabaseContext): void {
  const currentRowCount = countProjectCapsules(context);
  if (currentRowCount <= RETENTION_TRIGGER_PROJECT_ROW_COUNT) {
    return;
  }

  context.db
    .prepare(
      `
      DELETE FROM capsules
      WHERE project_id = ?
        AND id IN (
          SELECT id
          FROM (
            SELECT
              id,
              phase,
              ROW_NUMBER() OVER (
                PARTITION BY task_id
                ORDER BY created_at DESC, id DESC
              ) AS preflight_row_number,
              ROW_NUMBER() OVER (
                PARTITION BY task_id, phase
                ORDER BY created_at DESC, id DESC
              ) AS phase_row_number,
              ROW_NUMBER() OVER (
                ORDER BY created_at DESC, id DESC
              ) AS project_row_number
            FROM capsules
            WHERE project_id = ?
          )
          WHERE (phase = 'preflight' AND preflight_row_number > ?)
             OR (phase != 'preflight' AND phase_row_number > ?)
             OR project_row_number > ?
        )
    `
    )
    .run(
      context.projectId,
      context.projectId,
      PREFLIGHT_KEEP_LATEST_PER_TASK,
      NON_PREFLIGHT_KEEP_LATEST_PER_TASK_PHASE,
      RETENTION_PROJECT_HARD_CAP
    );
}

export function getCapsuleRetentionStatus(context: DatabaseContext): CapsuleRetentionStatus {
  return {
    mode: "threshold-driven-on-write",
    trigger_project_row_count: RETENTION_TRIGGER_PROJECT_ROW_COUNT,
    project_hard_cap: RETENTION_PROJECT_HARD_CAP,
    preflight_keep_latest_per_task: PREFLIGHT_KEEP_LATEST_PER_TASK,
    non_preflight_keep_latest_per_task_phase: NON_PREFLIGHT_KEEP_LATEST_PER_TASK_PHASE,
    current_project_row_count: countProjectCapsules(context),
    prune_eligible_row_count: countPruneEligibleCapsules(context)
  };
}

function countProjectCapsules(context: DatabaseContext): number {
  const row = context.db
    .prepare(
      `
      SELECT COUNT(*) AS total
      FROM capsules
      WHERE project_id = ?
    `
    )
    .get(context.projectId) as { total: number } | undefined;

  return row?.total ?? 0;
}

function countPruneEligibleCapsules(context: DatabaseContext): number {
  const row = context.db
    .prepare(
      `
      SELECT COUNT(*) AS total
      FROM (
        SELECT id
        FROM (
          SELECT
            id,
            phase,
            ROW_NUMBER() OVER (
              PARTITION BY task_id
              ORDER BY created_at DESC, id DESC
            ) AS preflight_row_number,
            ROW_NUMBER() OVER (
              PARTITION BY task_id, phase
              ORDER BY created_at DESC, id DESC
            ) AS phase_row_number,
            ROW_NUMBER() OVER (
              ORDER BY created_at DESC, id DESC
            ) AS project_row_number
          FROM capsules
          WHERE project_id = ?
        )
        WHERE (phase = 'preflight' AND preflight_row_number > ?)
           OR (phase != 'preflight' AND phase_row_number > ?)
           OR project_row_number > ?
      )
    `
    )
    .get(
      context.projectId,
      PREFLIGHT_KEEP_LATEST_PER_TASK,
      NON_PREFLIGHT_KEEP_LATEST_PER_TASK_PHASE,
      RETENTION_PROJECT_HARD_CAP
    ) as { total: number } | undefined;

  return row?.total ?? 0;
}

function buildHead(values: string[]): string {
  return values
    .slice(0, 2)
    .map((value) => sanitizeValue(value))
    .join("|");
}

function withCapsuleHash(lines: string[]): string {
  const body = lines.join("\n");
  return `${body}\nCAPSULE_SHA256=${sha256(body)}`;
}

function estimateTokens(input: string): number {
  return Math.ceil(input.length / TOKEN_CHAR_RATIO);
}

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function normalizeOptionalStringArray(input: unknown, field: string): string[] {
  if (input === undefined) {
    return [];
  }

  if (!Array.isArray(input)) {
    throw new Error(`${field} must be string[]`);
  }

  const values = input.map((entry, index) => {
    if (typeof entry !== "string") {
      throw new Error(`${field}[${index}] must be a string`);
    }
    const trimmed = entry.trim();
    if (trimmed.length === 0) {
      throw new Error(`${field}[${index}] must not be empty`);
    }
    return trimmed;
  });

  return Array.from(new Set(values));
}

function readOptionalObject(
  input: unknown
): Record<string, unknown> | undefined {
  if (input === undefined || input === null) {
    return undefined;
  }

  if (!isObject(input)) {
    throw new Error("context must be an object");
  }

  return input;
}

function readOptionalInteger(input: unknown, field: string): number | undefined {
  if (input === undefined || input === null) {
    return undefined;
  }

  if (typeof input === "number" && Number.isInteger(input)) {
    return input;
  }

  if (typeof input === "string" && input.trim().length > 0) {
    const parsed = Number.parseInt(input, 10);
    if (Number.isInteger(parsed)) {
      return parsed;
    }
  }

  throw new Error(`${field} must be an integer`);
}

function readRequiredString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== "string") {
    throw new Error(`${key} is required`);
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error(`${key} is required`);
  }
  return trimmed;
}

function normalizeOptionalString(input: unknown): string | undefined {
  if (input === undefined || input === null) {
    return undefined;
  }
  if (typeof input !== "string") {
    throw new Error("expected string");
  }
  const trimmed = input.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeOptionalSignal(input: unknown, field: string): CapsuleSignal | undefined {
  if (input === undefined || input === null) {
    return undefined;
  }

  if (typeof input === "string") {
    const trimmed = input.trim();
    if (trimmed.length === 0) {
      return undefined;
    }
    return { status: trimmed };
  }

  if (!isObject(input)) {
    throw new Error(`${field} must be a string or object`);
  }

  const status = normalizeOptionalString(input.status);
  if (!status) {
    throw new Error(`${field}.status is required`);
  }

  const summary = normalizeOptionalString(input.summary);
  return {
    status,
    ...(summary ? { summary } : {})
  };
}

function truncate(input: string, maxLength: number): string {
  if (input.length <= maxLength) {
    return input;
  }

  if (maxLength <= 3) {
    return input.slice(0, maxLength);
  }

  return `${input.slice(0, maxLength - 3)}...`;
}

function sanitizeValue(input: string): string {
  return input.replace(/\s+/g, "_").replace(/[\r\n=]/g, "_");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
