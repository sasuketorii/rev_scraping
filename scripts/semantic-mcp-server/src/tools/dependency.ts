import type { PreflightInput } from "../types.js";
export type { DependencyVerdict } from "../types.js";

export function toPreflightInput(input: unknown): PreflightInput {
  if (input === null || typeof input !== "object") {
    return {} as PreflightInput;
  }

  return input as PreflightInput;
}
