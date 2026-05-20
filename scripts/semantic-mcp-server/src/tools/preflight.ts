import { createHash } from "node:crypto";
import { closeSync, existsSync, lstatSync, openSync, readSync, realpathSync } from "node:fs";
import { posix, resolve } from "node:path";
import type { DatabaseContext } from "../db/connection.js";
import { applyCapsuleRetentionAfterWrite } from "./capsule.js";
import type {
  DependencyVerdict,
  MoveCandidate,
  PreflightConflict,
  PreflightInput,
  PreflightResponse,
  PreflightVerdict
} from "../types.js";

const TOKEN_CHAR_RATIO = 3;
const RESPONSE_TOKEN_BUDGET = 220;
const RESPONSE_CHAR_BUDGET = RESPONSE_TOKEN_BUDGET * TOKEN_CHAR_RATIO;
const CAPSULE_TOKEN_BUDGET = 200;
const CAPSULE_CHAR_BUDGET = CAPSULE_TOKEN_BUDGET * TOKEN_CHAR_RATIO;
// Conservative char-based approximation; replace with a tokenizer (e.g. tiktoken) if stricter token accounting is needed.
const DELETE_SUMMARY_CHAR_BUDGET = 360;
const OVERLAP_LOOKBACK_HOURS = 12;
const MAX_CONFLICTS = 4;
const MAX_CONFLICT_REASON_LENGTH = 72;
const MAX_ADJACENCY_LINE_CHARS = 1024 * 1024;
const TRUNCATED_WARNINGS_LINE = "WARNINGS=truncated";
const CAPSULE_TRIM_ORDER: CapsuleLineClass[] = [
  "other",
  "task_id",
  "delete_impacts",
  "conflicts",
  "warnings"
];
const LOCK_CANDIDATE_PATHS = [
  ".agent/registry/.lock",
  ".agent/.lock",
  ".claude/tmp/review_queue.lock"
] as const;

type CapsuleLineClass =
  | "verdict"
  | "signal"
  | "warnings"
  | "conflicts"
  | "delete_impacts"
  | "task_id"
  | "other";

interface NormalizedPreflightInput {
  project_id: string;
  task_id: string;
  scope: string[];
  proposed_components: string[];
  deleted_paths: string[];
  removed_symbols: string[];
  move_candidates: MoveCandidate[];
  adjacency_path?: string;
  dependency_verdict?: DependencyVerdict;
}

interface DeleteImpactAnalysis {
  reverse_dep: "available" | "unavailable" | "skipped";
  deleted_path_count: number;
  removed_symbol_count: number;
  deleted_symbol_count: number;
  impact_count: number;
  impacted_symbols: string[];
  reason: string;
}

interface ExistingComponentRow {
  semantic_id: string;
  name: string;
  file_path: string;
  status: string;
}

interface ProposedTarget {
  semantic_id: string;
  name: string;
  target_path?: string;
}

interface PreflightSignal {
  status: "none" | "clear" | "warn" | "blocked";
  summary: string;
}

interface TargetRiskAnalysis {
  conflicts: PreflightConflict[];
  target_lock: PreflightSignal;
  ambiguity: PreflightSignal;
  duplicate_risk: PreflightSignal;
}

interface RuntimePreflightResponse extends PreflightResponse {
  target_lock: PreflightSignal;
  ambiguity: PreflightSignal;
  duplicate_risk: PreflightSignal;
}

export function handlePreflight(
  context: DatabaseContext,
  rawInput: PreflightInput
): PreflightResponse {
  try {
    const input = normalizeInput(context, rawInput);
    const targetRisks = analyzeTargetRisks(context, input);
    const conflicts = dedupeConflicts([
      ...findConflicts(context, input.proposed_components),
      ...targetRisks.conflicts
    ]);
    const overlapTaskIds = findScopeOverlaps(context, input.task_id, input.scope);
    const lockSignals = detectLockSignals();
    const deleteImpact = analyzeDeleteImpacts(context, input);
    const deleteImpactsSummary = buildDeleteImpactsSummary(deleteImpact, input.move_candidates);
    const verdict = resolveVerdict(
      conflicts.length > 0,
      overlapTaskIds.length > 0,
      lockSignals.length > 0,
      targetRisks.duplicate_risk.status === "warn"
    );
    const capsule = buildPreflightCapsule({
      taskId: input.task_id,
      verdict,
      scope: input.scope,
      conflicts,
      deleteImpact,
      overlapTaskIds,
      lockSignals,
      targetLock: targetRisks.target_lock,
      ambiguity: targetRisks.ambiguity,
      duplicateRisk: targetRisks.duplicate_risk,
      dependencyVerdict: input.dependency_verdict
    });

    persistPreflightCapsule(context, input.task_id, capsule, input.scope);

    const response: RuntimePreflightResponse = {
      verdict,
      conflicts: compactConflicts(conflicts),
      delete_impacts_summary: truncate(deleteImpactsSummary, DELETE_SUMMARY_CHAR_BUDGET),
      capsule,
      target_lock: targetRisks.target_lock,
      ambiguity: targetRisks.ambiguity,
      duplicate_risk: targetRisks.duplicate_risk
    };

    if (input.dependency_verdict) {
      response.dependency_verdict = input.dependency_verdict;
    }

    return enforceResponseBudget(response);
  } catch (error) {
    throw new Error(`sem.preflight failed: ${toErrorMessage(error)}`);
  }
}

function normalizeInput(context: DatabaseContext, rawInput: PreflightInput): NormalizedPreflightInput {
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
  const scope = normalizeStringArray(rawInput.scope, "scope");
  const proposedComponents = normalizeStringArray(
    rawInput.proposed_components,
    "proposed_components"
  );
  const deletedPaths = normalizeOptionalStringArray(rawInput.deleted_paths, "deleted_paths");
  const removedSymbols = normalizeOptionalStringArray(rawInput.removed_symbols, "removed_symbols");
  const moveCandidates = normalizeMoveCandidates(rawInput.move_candidates);
  const adjacencyPath = normalizeOptionalString(rawInput.adjacency_path);
  const normalizedAdjacencyPath = adjacencyPath
    ? normalizeRepoRelativePath(context, adjacencyPath, "adjacency_path")
    : undefined;
  const dependencyVerdict = normalizeDependencyVerdict(rawInput.dependency_verdict);

  return {
    project_id: projectId,
    task_id: taskId,
    scope,
    proposed_components: proposedComponents,
    deleted_paths: deletedPaths,
    removed_symbols: removedSymbols,
    move_candidates: moveCandidates,
    adjacency_path: normalizedAdjacencyPath,
    dependency_verdict: dependencyVerdict
  };
}

function normalizeDependencyVerdict(
  input: DependencyVerdict | undefined
): DependencyVerdict | undefined {
  if (input === undefined) {
    return undefined;
  }

  const status = normalizeOptionalString(input.status);
  const checkedAt = normalizeOptionalString(input.checked_at);

  if (!status || !checkedAt || !Array.isArray(input.issues)) {
    throw new Error("dependency_verdict must include status, issues, checked_at");
  }

  return input;
}

function normalizeMoveCandidates(input: MoveCandidate[] | undefined): MoveCandidate[] {
  if (input === undefined) {
    return [];
  }

  if (!Array.isArray(input)) {
    throw new Error("move_candidates must be an array");
  }

  return input.map((candidate, index) => {
    if (!isObject(candidate)) {
      throw new Error(`move_candidates[${index}] must be an object`);
    }

    const oldPath = readRequiredString(candidate, "old_path");
    const newPath = readRequiredString(candidate, "new_path");
    return {
      old_path: oldPath,
      new_path: newPath
    };
  });
}

function normalizeStringArray(input: unknown, field: string): string[] {
  if (!Array.isArray(input)) {
    throw new Error(`${field} must be string[]`);
  }

  return normalizeOptionalStringArray(input, field);
}

function normalizeOptionalStringArray(input: unknown, field: string): string[] {
  if (input === undefined) {
    return [];
  }

  if (!Array.isArray(input)) {
    throw new Error(`${field} must be string[]`);
  }

  const normalized = input.map((value, index) => {
    if (typeof value !== "string") {
      throw new Error(`${field}[${index}] must be a string`);
    }
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      throw new Error(`${field}[${index}] must not be empty`);
    }
    return trimmed;
  });

  return Array.from(new Set(normalized));
}

function findConflicts(
  context: DatabaseContext,
  proposedComponents: string[]
): PreflightConflict[] {
  const conflicts: PreflightConflict[] = [];
  const seen = new Set<string>();
  const localDuplicates = new Set<string>();

  for (const semanticId of proposedComponents) {
    if (seen.has(semanticId)) {
      localDuplicates.add(semanticId);
    }
    seen.add(semanticId);
  }

  for (const semanticId of localDuplicates) {
    conflicts.push({
      semantic_id: semanticId,
      reason: "duplicate_proposed_component"
    });
  }

  if (proposedComponents.length === 0) {
    return conflicts;
  }

  const placeholders = proposedComponents.map(() => "?").join(", ");
  const rows = context.db
    .prepare(
      `
      SELECT semantic_id, status
      FROM components
      WHERE project_id = ? AND semantic_id IN (${placeholders}) AND status != 'deleted'
    `
    )
    .all(context.projectId, ...proposedComponents) as Array<{
    semantic_id: string;
    status: string;
  }>;

  for (const row of rows) {
    conflicts.push({
      semantic_id: row.semantic_id,
      reason: `already_exists:${row.status}`
    });
  }

  return dedupeConflicts(conflicts);
}

function analyzeTargetRisks(
  context: DatabaseContext,
  input: NormalizedPreflightInput
): TargetRiskAnalysis {
  const proposedTargets = collectProposedTargets(input.proposed_components);
  if (proposedTargets.length === 0) {
    return {
      conflicts: [],
      target_lock: { status: "none", summary: "none" },
      ambiguity: { status: "none", summary: "none" },
      duplicate_risk: { status: "none", summary: "none" }
    };
  }

  const scopeSet = new Set(input.scope.map((entry) => normalizePathLike(entry)));
  const moveTargetSet = new Set(
    input.move_candidates.map((candidate) => normalizePathLike(candidate.new_path))
  );
  const existingBySemanticId = loadExistingComponentsBySemanticId(
    context,
    proposedTargets.map((target) => target.semantic_id)
  );
  const existingByName = loadExistingComponentsByName(
    context,
    proposedTargets.map((target) => target.name)
  );

  const intraRequestDuplicates = findIntraRequestTargetDuplicates(proposedTargets);
  const targetLockSignals: string[] = [];
  const ambiguitySignals: string[] = [...intraRequestDuplicates.signals];
  const duplicateSignals: string[] = [];
  const conflicts: PreflightConflict[] = [...intraRequestDuplicates.conflicts];
  const lockableTargetsCount = proposedTargets.filter((target) => target.target_path).length;

  for (const proposedTarget of proposedTargets) {
    const lockResult = analyzeTargetLock(
      proposedTarget,
      scopeSet,
      moveTargetSet,
      existingBySemanticId.get(proposedTarget.semantic_id)
    );
    if (lockResult.signal) {
      targetLockSignals.push(lockResult.signal);
    }
    if (lockResult.conflict) {
      conflicts.push(lockResult.conflict);
    }

    const duplicateResult = analyzeDuplicateRisk(
      proposedTarget,
      input.scope,
      existingByName.get(proposedTarget.name) ?? []
    );
    if (duplicateResult.signal) {
      duplicateSignals.push(duplicateResult.signal);
    }
    if (duplicateResult.conflict) {
      ambiguitySignals.push(duplicateResult.signal ?? duplicateResult.conflict.reason);
      conflicts.push(duplicateResult.conflict);
    }
  }

  return {
    conflicts: dedupeConflicts(conflicts),
    target_lock: buildSignal(
      targetLockSignals.length > 0 ? "blocked" : lockableTargetsCount > 0 ? "clear" : "none",
      targetLockSignals,
      lockableTargetsCount > 0 ? "clear" : "none"
    ),
    ambiguity: buildSignal(
      ambiguitySignals.length > 0 ? "blocked" : "none",
      ambiguitySignals,
      "none"
    ),
    duplicate_risk: buildSignal(
      ambiguitySignals.length > 0
        ? "blocked"
        : duplicateSignals.length > 0
          ? "warn"
          : "none",
      [...ambiguitySignals, ...duplicateSignals],
      "none"
    )
  };
}

function analyzeTargetLock(
  proposedTarget: ProposedTarget,
  scopeSet: ReadonlySet<string>,
  moveTargetSet: ReadonlySet<string>,
  existingComponent: ExistingComponentRow | undefined
): {
  signal?: string;
  conflict?: PreflightConflict;
} {
  if (!proposedTarget.target_path) {
    return {};
  }

  const normalizedTargetPath = normalizePathLike(proposedTarget.target_path);
  if (scopeSet.size === 0) {
    const reason = `target_lock_scope_missing:${truncate(normalizedTargetPath, 40)}`;
    return {
      signal: `${proposedTarget.semantic_id}->${truncate(normalizedTargetPath, 32)}`,
      conflict: {
        semantic_id: proposedTarget.semantic_id,
        reason
      }
    };
  }

  const hasExplicitScope =
    scopeSet.has(normalizedTargetPath) || moveTargetSet.has(normalizedTargetPath);

  if (!hasExplicitScope) {
    const reason = `target_lock_scope_mismatch:${truncate(normalizedTargetPath, 40)}`;
    return {
      signal: `${proposedTarget.semantic_id}->${truncate(normalizedTargetPath, 32)}`,
      conflict: {
        semantic_id: proposedTarget.semantic_id,
        reason
      }
    };
  }

  if (
    existingComponent &&
    existingComponent.status !== "deleted" &&
    normalizePathLike(existingComponent.file_path) !== normalizedTargetPath
  ) {
    const existingPath = normalizePathLike(existingComponent.file_path);
    return {
      signal: `${proposedTarget.semantic_id}->${truncate(existingPath, 32)}`,
      conflict: {
        semantic_id: proposedTarget.semantic_id,
        reason: `target_lock_registry_mismatch:${truncate(existingPath, 40)}`
      }
    };
  }

  return {};
}

function analyzeDuplicateRisk(
  proposedTarget: ProposedTarget,
  scope: string[],
  existingMatches: ExistingComponentRow[]
): {
  signal?: string;
  conflict?: PreflightConflict;
} {
  const competingMatches = existingMatches.filter(
    (row) => row.semantic_id !== proposedTarget.semantic_id && row.status !== "deleted"
  );
  if (competingMatches.length === 0) {
    return {};
  }

  const normalizedTargetPath = proposedTarget.target_path
    ? normalizePathLike(proposedTarget.target_path)
    : undefined;
  const ownershipConflict = normalizedTargetPath
    ? competingMatches.find(
        (row) => normalizePathLike(row.file_path) === normalizedTargetPath
      )
    : undefined;
  if (ownershipConflict && normalizedTargetPath) {
    const signal = `${proposedTarget.name}@${truncate(normalizedTargetPath, 24)}`;
    return {
      signal,
      conflict: {
        semantic_id: proposedTarget.semantic_id,
        reason: `duplicate_target_owner:${truncate(ownershipConflict.semantic_id, 40)}`
      }
    };
  }

  const sample = competingMatches
    .slice(0, 2)
    .map((row) => truncate(normalizePathLike(row.file_path), 24))
    .join("|");
  const signal = `${proposedTarget.name}@${sample}`;
  if (!isTargetAmbiguous(scope, proposedTarget.target_path)) {
    return {
      signal
    };
  }

  return {
    signal,
    conflict: {
      semantic_id: proposedTarget.semantic_id,
      reason: `ambiguous_duplicate_risk:${truncate(signal, 40)}`
    }
  };
}

function isTargetAmbiguous(scope: string[], targetPath?: string): boolean {
  const normalizedScope = Array.from(new Set(scope.map((entry) => normalizePathLike(entry))));
  if (normalizedScope.length !== 1) {
    return true;
  }

  if (!targetPath) {
    return false;
  }

  return normalizedScope[0] !== normalizePathLike(targetPath);
}

function loadExistingComponentsBySemanticId(
  context: DatabaseContext,
  semanticIds: string[]
): Map<string, ExistingComponentRow> {
  if (semanticIds.length === 0) {
    return new Map();
  }

  const placeholders = semanticIds.map(() => "?").join(", ");
  const rows = context.db
    .prepare(
      `
      SELECT semantic_id, name, file_path, status
      FROM components
      WHERE project_id = ? AND semantic_id IN (${placeholders})
    `
    )
    .all(context.projectId, ...semanticIds) as ExistingComponentRow[];

  return new Map(rows.map((row) => [row.semantic_id, row]));
}

function loadExistingComponentsByName(
  context: DatabaseContext,
  names: string[]
): Map<string, ExistingComponentRow[]> {
  const normalizedNames = Array.from(new Set(names.map((entry) => entry.trim()).filter(Boolean)));
  if (normalizedNames.length === 0) {
    return new Map();
  }

  const placeholders = normalizedNames.map(() => "?").join(", ");
  const rows = context.db
    .prepare(
      `
      SELECT semantic_id, name, file_path, status
      FROM components
      WHERE project_id = ? AND name IN (${placeholders}) AND status != 'deleted'
      ORDER BY updated_at DESC, semantic_id ASC
    `
    )
    .all(context.projectId, ...normalizedNames) as ExistingComponentRow[];

  const grouped = new Map<string, ExistingComponentRow[]>();
  for (const row of rows) {
    const bucket = grouped.get(row.name) ?? [];
    bucket.push(row);
    grouped.set(row.name, bucket);
  }

  return grouped;
}

function findIntraRequestTargetDuplicates(
  proposedTargets: ProposedTarget[]
): {
  signals: string[];
  conflicts: PreflightConflict[];
} {
  const ownershipByKey = new Map<string, ProposedTarget>();
  const signals: string[] = [];
  const conflicts: PreflightConflict[] = [];

  for (const proposedTarget of proposedTargets) {
    if (!proposedTarget.target_path) {
      continue;
    }

    const ownershipKey = buildTargetOwnershipKey(proposedTarget);
    if (!ownershipKey) {
      continue;
    }

    const existingOwner = ownershipByKey.get(ownershipKey);
    if (!existingOwner) {
      ownershipByKey.set(ownershipKey, proposedTarget);
      continue;
    }

    if (existingOwner.semantic_id === proposedTarget.semantic_id) {
      continue;
    }

    const signal = `${proposedTarget.name}@${truncate(proposedTarget.target_path, 24)}`;
    const reason = `duplicate_request_target:${truncate(
      `${proposedTarget.name}@${proposedTarget.target_path}`,
      40
    )}`;
    signals.push(signal);
    conflicts.push(
      {
        semantic_id: existingOwner.semantic_id,
        reason
      },
      {
        semantic_id: proposedTarget.semantic_id,
        reason
      }
    );
  }

  return {
    signals,
    conflicts
  };
}

function collectProposedTargets(proposedComponents: string[]): ProposedTarget[] {
  return proposedComponents.map((semanticId) => {
    const separatorIndex = semanticId.indexOf(":");
    const moduleSegment = separatorIndex >= 0 ? semanticId.slice(0, separatorIndex) : semanticId;
    const symbolName =
      separatorIndex >= 0 && separatorIndex < semanticId.length - 1
        ? semanticId.slice(separatorIndex + 1)
        : semanticId;
    const normalizedTargetPath = looksLikePathTarget(moduleSegment)
      ? normalizePathLike(moduleSegment)
      : undefined;

    return {
      semantic_id: semanticId,
      name: symbolName,
      target_path: normalizedTargetPath
    };
  });
}

function buildTargetOwnershipKey(proposedTarget: ProposedTarget): string | undefined {
  if (!proposedTarget.target_path) {
    return undefined;
  }

  return `${proposedTarget.name.trim()}|${normalizePathLike(proposedTarget.target_path)}`;
}

function buildSignal(
  status: PreflightSignal["status"],
  values: string[],
  emptySummary: string
): PreflightSignal {
  if (values.length === 0) {
    return {
      status,
      summary: emptySummary
    };
  }

  return {
    status,
    summary: truncate(values.slice(0, 2).join(","), 120)
  };
}

function looksLikePathTarget(input: string): boolean {
  const normalized = normalizePathLike(input);
  return normalized.includes("/") || normalized.startsWith("../");
}

function normalizePathLike(input: string): string {
  const normalized = posix
    .normalize(
      input
        .trim()
        .replace(/\\/g, "/")
        .replace(/\/+/g, "/")
    )
    .replace(/^(?:\.\/)+/, "")
    .replace(/\/$/, "");

  return normalized.toLowerCase();
}

function normalizeScopeEntries(scope: string[]): string[] {
  return scope.map((entry) => normalizePathLike(entry));
}

function normalizeScopeStorage(scope: string[]): string {
  return normalizeScopeEntries(scope).join("|");
}

function normalizeScopeSet(scope: string[]): Set<string> {
  return new Set(normalizeScopeEntries(scope));
}

function normalizeScopeFromCapsule(rawScope: string): string[] {
  return rawScope
    .split("|")
    .map((entry) => normalizePathLike(entry))
    .filter((entry) => entry.length > 0);
}

function dedupeConflicts(conflicts: PreflightConflict[]): PreflightConflict[] {
  const seen = new Set<string>();
  const deduped: PreflightConflict[] = [];

  for (const conflict of conflicts) {
    const key = `${conflict.semantic_id}|${conflict.reason}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    deduped.push(conflict);
  }

  return deduped;
}

function findScopeOverlaps(
  context: DatabaseContext,
  taskId: string,
  scope: string[]
): string[] {
  if (scope.length === 0) {
    return [];
  }

  const scopeSet = normalizeScopeSet(scope);
  const rows = context.db
    .prepare(
      `
      SELECT task_id, content
      FROM capsules
      WHERE project_id = ?
        AND phase = 'preflight'
        AND task_id != ?
        AND created_at >= datetime('now', '-${OVERLAP_LOOKBACK_HOURS} hours')
      ORDER BY created_at DESC
      LIMIT 50
    `
    )
    .all(context.projectId, taskId) as Array<{
    task_id: string;
    content: string;
  }>;

  const overlapTaskIds = new Set<string>();

  for (const row of rows) {
    const priorScope = extractScopeFromCapsule(row.content);
    if (priorScope.length === 0) {
      continue;
    }

    const hasOverlap = priorScope.some((path) => scopeSet.has(path));
    if (hasOverlap) {
      overlapTaskIds.add(row.task_id);
    }
  }

  return Array.from(overlapTaskIds);
}

function extractScopeFromCapsule(capsule: string): string[] {
  for (const line of capsule.split(/\r?\n/)) {
    if (!line.startsWith("SCOPE=")) {
      continue;
    }

    const rawScope = line.slice("SCOPE=".length).trim();
    if (rawScope.length === 0) {
      return [];
    }

    return normalizeScopeFromCapsule(rawScope);
  }

  return [];
}

function detectLockSignals(): string[] {
  const lockSignals: string[] = [];

  for (const candidate of LOCK_CANDIDATE_PATHS) {
    const absolutePath = resolve(process.cwd(), candidate);
    if (!existsSync(absolutePath)) {
      continue;
    }

    try {
      lstatSync(absolutePath);
      lockSignals.push(candidate);
    } catch {
      // ignore inaccessible lock candidates
    }
  }

  return lockSignals;
}

function analyzeDeleteImpacts(
  context: DatabaseContext,
  input: NormalizedPreflightInput
): DeleteImpactAnalysis {
  const movedOldPaths = new Set(input.move_candidates.map((candidate) => candidate.old_path));
  const effectiveDeletedPaths = input.deleted_paths.filter((path) => !movedOldPaths.has(path));
  const deletedSymbolIds = new Set<string>(input.removed_symbols);

  if (effectiveDeletedPaths.length > 0) {
    const placeholders = effectiveDeletedPaths.map(() => "?").join(", ");
    const rows = context.db
      .prepare(
        `
        SELECT semantic_id
        FROM components
        WHERE project_id = ? AND file_path IN (${placeholders})
      `
      )
      .all(context.projectId, ...effectiveDeletedPaths) as Array<{ semantic_id: string }>;

    for (const row of rows) {
      deletedSymbolIds.add(row.semantic_id);
    }
  }

  const deletedSymbols = Array.from(deletedSymbolIds);
  const noDeleteSignals = effectiveDeletedPaths.length === 0 && deletedSymbols.length === 0;
  if (noDeleteSignals) {
    return {
      reverse_dep: "skipped",
      deleted_path_count: 0,
      removed_symbol_count: input.removed_symbols.length,
      deleted_symbol_count: 0,
      impact_count: 0,
      impacted_symbols: [],
      reason: "no_delete_signals"
    };
  }

  const adjacencyPath = input.adjacency_path;
  if (!adjacencyPath) {
    return {
      reverse_dep: "unavailable",
      deleted_path_count: effectiveDeletedPaths.length,
      removed_symbol_count: input.removed_symbols.length,
      deleted_symbol_count: deletedSymbols.length,
      impact_count: 0,
      impacted_symbols: [],
      reason: "adjacency_not_provided"
    };
  }

  const absoluteAdjacencyPath = resolve(context.repoRoot ?? process.cwd(), adjacencyPath);
  if (!existsSync(absoluteAdjacencyPath)) {
    return {
      reverse_dep: "unavailable",
      deleted_path_count: effectiveDeletedPaths.length,
      removed_symbol_count: input.removed_symbols.length,
      deleted_symbol_count: deletedSymbols.length,
      impact_count: 0,
      impacted_symbols: [],
      reason: "adjacency_missing"
    };
  }

  const targetSet = new Set(deletedSymbols);
  const impacted = new Set<string>();
  streamAdjacencyRows(absoluteAdjacencyPath, (parsed, lineNumber) => {
    if (
      typeof parsed.source_logical_id !== "string" ||
      typeof parsed.target_logical_id !== "string"
    ) {
      throw new Error(`malformed adjacency row at line ${lineNumber}`);
    }

    if (
      targetSet.has(parsed.target_logical_id) &&
      !targetSet.has(parsed.source_logical_id)
    ) {
      impacted.add(parsed.source_logical_id);
    }
  });

  return {
    reverse_dep: "available",
    deleted_path_count: effectiveDeletedPaths.length,
    removed_symbol_count: input.removed_symbols.length,
    deleted_symbol_count: deletedSymbols.length,
    impact_count: impacted.size,
    impacted_symbols: Array.from(impacted),
    reason: "ok"
  };
}

function buildDeleteImpactsSummary(
  analysis: DeleteImpactAnalysis,
  moveCandidates: MoveCandidate[]
): string {
  const parts = [
    `del_paths=${analysis.deleted_path_count}`,
    `rm_syms=${analysis.removed_symbol_count}`,
    `deleted_ids=${analysis.deleted_symbol_count}`,
    `reverse_dep=${analysis.reverse_dep}`,
    `impacts=${analysis.impact_count}`
  ];

  if (moveCandidates.length > 0) {
    parts.push(`moves=${moveCandidates.length}`);
  }

  if (analysis.impacted_symbols.length > 0) {
    const sample = analysis.impacted_symbols
      .slice(0, 3)
      .map((symbol) => truncate(symbol, 40))
      .join("|");
    parts.push(`sample=${sample}`);
  }

  if (analysis.reverse_dep !== "available") {
    parts.push(`reason=${analysis.reason}`);
  }

  return truncate(parts.join(" "), DELETE_SUMMARY_CHAR_BUDGET);
}

function resolveVerdict(
  hasConflicts: boolean,
  hasOverlap: boolean,
  hasLocks: boolean,
  hasDuplicateRiskWarning: boolean
): PreflightVerdict {
  if (hasConflicts) {
    return "BLOCK";
  }

  if (hasOverlap || hasLocks || hasDuplicateRiskWarning) {
    return "WARN";
  }

  return "PASS";
}

function buildPreflightCapsule(params: {
  taskId: string;
  verdict: PreflightVerdict;
  scope: string[];
  conflicts: PreflightConflict[];
  deleteImpact: DeleteImpactAnalysis;
  overlapTaskIds: string[];
  lockSignals: string[];
  targetLock: PreflightSignal;
  ambiguity: PreflightSignal;
  duplicateRisk: PreflightSignal;
  dependencyVerdict?: DependencyVerdict;
}): string {
  const warningSignals: string[] = [];
  if (params.overlapTaskIds.length > 0) {
    warningSignals.push(`overlap:${params.overlapTaskIds.slice(0, 3).join("|")}`);
  }
  if (params.lockSignals.length > 0) {
    warningSignals.push(`lock:${params.lockSignals.slice(0, 2).join("|")}`);
  }

  const baseLines = [
    `TASK=${sanitizeValue(params.taskId)}`,
    "PHASE=preflight",
    `VERDICT=${params.verdict}`,
    `SCOPE_COUNT=${params.scope.length}`,
    `SCOPE_SHA256=${sha256(params.scope.join("\n"))}`,
    `CONFLICT_COUNT=${params.conflicts.length}`,
    `IMPACT_COUNT=${params.deleteImpact.impact_count}`,
    `TARGET_LOCK=${sanitizeValue(params.targetLock.status)}`,
    `AMBIGUITY=${sanitizeValue(params.ambiguity.status)}`,
    `DUPLICATE_RISK=${sanitizeValue(params.duplicateRisk.status)}`,
    `DEP_STATUS=${params.dependencyVerdict?.status ?? "none"}`
  ];
  if (warningSignals.length > 0) {
    baseLines.push(`WARNINGS=${sanitizeValue(warningSignals.join(","))}`);
  }

  const trimmedLines = trimCapsuleLines(baseLines);
  return withCapsuleHash(trimmedLines);
}

function trimCapsuleLines(lines: string[]): string[] {
  const trimmed = [...lines];

  while (withCapsuleHash(trimmed).length > CAPSULE_CHAR_BUDGET) {
    let changed = false;

    for (const className of CAPSULE_TRIM_ORDER) {
      if (className === "warnings") {
        const warningIndex = findLineIndexByClass(trimmed, className);
        if (warningIndex >= 0 && trimmed[warningIndex] !== TRUNCATED_WARNINGS_LINE) {
          trimmed[warningIndex] = TRUNCATED_WARNINGS_LINE;
          changed = true;
          break;
        }
        continue;
      }

      const lineIndex = findLineIndexByClass(trimmed, className);
      if (lineIndex >= 0) {
        trimmed.splice(lineIndex, 1);
        changed = true;
        break;
      }
    }

    if (!changed) {
      break;
    }
  }

  if (withCapsuleHash(trimmed).length > CAPSULE_CHAR_BUDGET) {
    throw new Error("preflight capsule exceeded 200-token budget");
  }

  return trimmed;
}

function findLineIndexByClass(lines: string[], className: CapsuleLineClass): number {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (classifyCapsuleLine(lines[index]) === className) {
      return index;
    }
  }

  return -1;
}

function classifyCapsuleLine(line: string): CapsuleLineClass {
  if (line.startsWith("VERDICT=")) {
    return "verdict";
  }

  if (
    line.startsWith("TARGET_LOCK=") ||
    line.startsWith("AMBIGUITY=") ||
    line.startsWith("DUPLICATE_RISK=")
  ) {
    return "signal";
  }

  if (line.startsWith("WARNINGS=")) {
    return "warnings";
  }

  if (line.startsWith("CONFLICT_COUNT=") || line.startsWith("CONFLICTS=")) {
    return "conflicts";
  }

  if (line.startsWith("IMPACT_COUNT=") || line.startsWith("DELETE_IMPACTS=")) {
    return "delete_impacts";
  }

  if (line.startsWith("TASK=") || line.startsWith("TASK_ID=")) {
    return "task_id";
  }

  return "other";
}

function persistPreflightCapsule(
  context: DatabaseContext,
  taskId: string,
  responseCapsule: string,
  scope: string[]
): void {
  const storageCapsule = `${responseCapsule}\nSCOPE=${normalizeScopeStorage(scope)}`;
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
      VALUES (?, ?, 'preflight', ?, ?, datetime('now'))
    `
    )
    .run(
      context.projectId,
      taskId,
      storageCapsule,
      estimateTokens(storageCapsule)
    );
  applyCapsuleRetentionAfterWrite(context);
}

function streamAdjacencyRows(
  absolutePath: string,
  onRow: (row: Record<string, unknown>, lineNumber: number) => void
): void {
  const fd = openSync(absolutePath, "r");
  const buffer = Buffer.alloc(64 * 1024);
  let pending = "";
  let lineNumber = 0;

  try {
    while (true) {
      const bytesRead = readSync(fd, buffer, 0, buffer.length, null);
      if (bytesRead === 0) {
        break;
      }

      pending += buffer.subarray(0, bytesRead).toString("utf8");
      let newlineIndex = pending.search(/\r?\n/);
      while (newlineIndex >= 0) {
        const line = pending.slice(0, newlineIndex);
        const skip = pending[newlineIndex] === "\r" && pending[newlineIndex + 1] === "\n"
          ? 2
          : 1;
        pending = pending.slice(newlineIndex + skip);
        lineNumber += 1;
        parseAdjacencyLine(line, lineNumber, onRow);
        newlineIndex = pending.search(/\r?\n/);
      }

      if (pending.length > MAX_ADJACENCY_LINE_CHARS) {
        throw new Error(`adjacency line exceeds ${MAX_ADJACENCY_LINE_CHARS} characters`);
      }
    }

    if (pending.length > 0) {
      lineNumber += 1;
      parseAdjacencyLine(pending, lineNumber, onRow);
    }
  } finally {
    closeSync(fd);
  }
}

function parseAdjacencyLine(
  line: string,
  lineNumber: number,
  onRow: (row: Record<string, unknown>, lineNumber: number) => void
): void {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return;
  }
  if (line.length > MAX_ADJACENCY_LINE_CHARS) {
    throw new Error(`adjacency line exceeds ${MAX_ADJACENCY_LINE_CHARS} characters`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch (error) {
    throw new Error(`malformed adjacency JSON at line ${lineNumber}: ${toErrorMessage(error)}`);
  }

  if (!isObject(parsed)) {
    throw new Error(`malformed adjacency row at line ${lineNumber}`);
  }

  onRow(parsed, lineNumber);
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
  const normalizedRoot = posix.normalize(root.replace(/\\/g, "/"));
  const normalizedCandidate = posix.normalize(candidate.replace(/\\/g, "/"));
  const relative = normalizedCandidate.slice(normalizedRoot.length);
  return normalizedCandidate === normalizedRoot ||
    (relative.startsWith("/") && !relative.startsWith("/../"));
}

function compactConflicts(conflicts: PreflightConflict[]): PreflightConflict[] {
  return conflicts.slice(0, MAX_CONFLICTS).map((conflict) => ({
    semantic_id: conflict.semantic_id,
    reason: truncate(conflict.reason, MAX_CONFLICT_REASON_LENGTH)
  }));
}

function enforceResponseBudget(response: RuntimePreflightResponse): RuntimePreflightResponse {
  const compacted: RuntimePreflightResponse = {
    verdict: response.verdict,
    conflicts: compactConflicts(response.conflicts),
    delete_impacts_summary: truncate(response.delete_impacts_summary, DELETE_SUMMARY_CHAR_BUDGET),
    capsule: response.capsule,
    target_lock: {
      status: response.target_lock.status,
      summary: truncate(response.target_lock.summary, 120)
    },
    ambiguity: {
      status: response.ambiguity.status,
      summary: truncate(response.ambiguity.summary, 120)
    },
    duplicate_risk: {
      status: response.duplicate_risk.status,
      summary: truncate(response.duplicate_risk.summary, 120)
    }
  };

  if (response.dependency_verdict) {
    compacted.dependency_verdict = response.dependency_verdict;
  }

  while (JSON.stringify(compacted).length > RESPONSE_CHAR_BUDGET) {
    if (compacted.duplicate_risk.summary.length > 32) {
      compacted.duplicate_risk.summary = truncate(compacted.duplicate_risk.summary, 32);
      continue;
    }

    if (compacted.ambiguity.summary.length > 32) {
      compacted.ambiguity.summary = truncate(compacted.ambiguity.summary, 32);
      continue;
    }

    if (compacted.target_lock.summary.length > 32) {
      compacted.target_lock.summary = truncate(compacted.target_lock.summary, 32);
      continue;
    }

    if (compacted.delete_impacts_summary.length > 80) {
      compacted.delete_impacts_summary = truncate(compacted.delete_impacts_summary, 80);
      continue;
    }

    if (compacted.delete_impacts_summary.length > 32) {
      compacted.delete_impacts_summary = compactDeleteImpactsSummary(
        compacted.delete_impacts_summary
      );
      continue;
    }

    if (compacted.capsule.includes("\n")) {
      const compactedCapsule = compactPreflightCapsule(compacted.capsule);
      if (compactedCapsule !== compacted.capsule) {
        compacted.capsule = compactedCapsule;
        continue;
      }

      compacted.capsule = compactedCapsule;
    }

    if (compacted.conflicts.length > 0) {
      compacted.conflicts = compacted.conflicts.slice(0, compacted.conflicts.length - 1);
      continue;
    }

    throw new Error("preflight response exceeded 220-token budget");
  }

  return compacted;
}

function withCapsuleHash(lines: string[]): string {
  const body = lines.join("\n");
  const hash = sha256(body);
  return `${body}\nCAPSULE_SHA256=${hash}`;
}

function compactPreflightCapsule(capsule: string): string {
  const essentialLines = capsule
    .split(/\r?\n/)
    .filter((line) =>
      line.startsWith("VERDICT=") ||
      line.startsWith("TARGET_LOCK=") ||
      line.startsWith("AMBIGUITY=") ||
      line.startsWith("DUPLICATE_RISK=")
    );

  if (essentialLines.length === 0) {
    return capsule;
  }

  return withCapsuleHash(essentialLines);
}

function compactDeleteImpactsSummary(summary: string): string {
  const impacts = summary.match(/(?:^|\s)(impacts=\d+)/)?.[1];
  const reason = summary.match(/(?:^|\s)(reason=[^\s]+)/)?.[1];
  const reverseDep = summary.match(/(?:^|\s)(reverse_dep=[^\s]+)/)?.[1];
  const compactParts = [impacts, reason ?? reverseDep].filter(
    (part): part is string => Boolean(part)
  );

  if (compactParts.length > 0) {
    return truncate(compactParts.join(" "), 32);
  }

  return truncate(summary, 32);
}

function estimateTokens(input: string): number {
  return Math.ceil(input.length / TOKEN_CHAR_RATIO);
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

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function sanitizeValue(input: string): string {
  return input.replace(/\s+/g, "_").replace(/[\r\n=]/g, "_");
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

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
