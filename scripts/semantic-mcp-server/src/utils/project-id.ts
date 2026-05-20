const PROJECT_ID_PATTERN = /^[A-Za-z0-9_-]+$/;
const MAX_PROJECT_ID_LENGTH = 64;
const FORBIDDEN_PROJECT_ID_LITERAL = "agent_base";

export function validateProjectId(projectId: string): string {
  const normalized = projectId.trim();

  if (normalized.length === 0) {
    throw new Error("project_id must not be empty");
  }

  if (normalized.length > MAX_PROJECT_ID_LENGTH) {
    throw new Error(`project_id must be <= ${MAX_PROJECT_ID_LENGTH} characters`);
  }

  if (!PROJECT_ID_PATTERN.test(normalized)) {
    throw new Error("project_id must contain only letters, numbers, '_' or '-'");
  }

  if (normalized === FORBIDDEN_PROJECT_ID_LITERAL) {
    throw new Error(
      `project_id literal '${FORBIDDEN_PROJECT_ID_LITERAL}' is forbidden; bootstrap a repo-local immutable id`
    );
  }

  return normalized;
}
