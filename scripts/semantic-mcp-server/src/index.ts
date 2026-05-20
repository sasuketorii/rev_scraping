import { pathToFileURL } from "node:url";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  closeDatabase,
  openDatabase,
  type DatabaseContext
} from "./db/connection.js";
import { runMigrations } from "./db/migrations.js";
import { createSemanticServer } from "./server.js";
import { validateProjectId } from "./utils/project-id.js";

const PROJECT_ID_FLAG = "--project-id";

async function main(): Promise<void> {
  let dbContext: DatabaseContext | null = null;

  try {
    const projectId = resolveProjectId(process.argv.slice(2));
    dbContext = openDatabase(projectId);
    runMigrations(dbContext.db);

    const server = createSemanticServer(dbContext);
    const transport = new StdioServerTransport();

    await server.connect(transport);

    console.error(
      `[semantic-mcp-server] started project_id=${projectId} db_path=${dbContext.dbPath}`
    );

    process.on("SIGINT", () => shutdown(dbContext));
    process.on("SIGTERM", () => shutdown(dbContext));
  } catch (error) {
    console.error(`[semantic-mcp-server] startup failed: ${toErrorMessage(error)}`);

    if (dbContext !== null) {
      try {
        closeDatabase(dbContext);
      } catch (closeError) {
        console.error(`[semantic-mcp-server] close failed: ${toErrorMessage(closeError)}`);
      }
    }

    process.exit(1);
  }
}

export function resolveProjectId(argv: string[]): string {
  try {
    const projectId = parseProjectIdArg(argv);

    if (!projectId) {
      if (process.env.SEMANTIC_MCP_PROJECT_ID || process.env.PROJECT_ID) {
        throw new Error(
          "project_id must be provided via --project-id <id>; env-based project_id is not supported"
        );
      }

      throw new Error(
        "project_id is required: use --project-id <id>"
      );
    }

    return validateProjectId(projectId);
  } catch (error) {
    throw new Error(`Failed to resolve project_id: ${toErrorMessage(error)}`);
  }
}

function parseProjectIdArg(argv: string[]): string | null {
  try {
    let projectId: string | null = null;

    for (let index = 0; index < argv.length; index += 1) {
      const current = argv[index];
      if (current === PROJECT_ID_FLAG) {
        const next = argv[index + 1];
        if (next === undefined) {
          return null;
        }

        if (next.startsWith("--")) {
          throw new Error(
            `${PROJECT_ID_FLAG} requires a value; received another flag: ${next}`
          );
        }

        if (projectId !== null) {
          throw new Error(`duplicate flag: ${PROJECT_ID_FLAG}`);
        }

        projectId = next;
        index += 1;
        continue;
      }

      if (current.startsWith(`${PROJECT_ID_FLAG}=`)) {
        if (projectId !== null) {
          throw new Error(`duplicate flag: ${PROJECT_ID_FLAG}`);
        }

        projectId = current.slice(`${PROJECT_ID_FLAG}=`.length);
        continue;
      }

      if (current.startsWith("--")) {
        throw new Error(`unknown flag: ${current}`);
      }

      throw new Error(`unknown positional argument: ${current}`);
    }

    return projectId;
  } catch (error) {
    throw new Error(`Failed to parse project_id flag: ${toErrorMessage(error)}`);
  }
}

function shutdown(dbContext: DatabaseContext | null): void {
  try {
    if (dbContext && dbContext.db.open) {
      closeDatabase(dbContext);
    }
  } catch (error) {
    console.error(`[semantic-mcp-server] shutdown close failed: ${toErrorMessage(error)}`);
  } finally {
    process.exit(0);
  }
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  void main();
}
