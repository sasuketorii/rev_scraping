import type { DatabaseContext } from "../db/connection.js";
import { assertRequiredTables } from "../db/migrations.js";
import { SERVER_VERSION, TOOL_NAMES, type HealthResponse } from "../types.js";
import { getCapsuleRetentionStatus } from "./capsule.js";

export function handleHealth(context: DatabaseContext): HealthResponse {
  try {
    context.db.prepare("SELECT 1").get();
    const tables = assertRequiredTables(context.db);

    return {
      status: "ok",
      tables,
      version: SERVER_VERSION,
      tool_count: Object.keys(TOOL_NAMES).length,
      capsule_retention: getCapsuleRetentionStatus(context)
    };
  } catch (error) {
    throw new Error(`sem.health failed: ${toErrorMessage(error)}`);
  }
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
