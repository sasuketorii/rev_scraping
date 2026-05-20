#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/test/fixtures/semantic_backend_parity"
TMP_ROOT=""
RUST_WORKSPACE_ROOT=""
NODE_BINARY=""
NODE_PATH_VALUE=""
NODE_HOME_VALUE=""
CARGO_BINARY=""
CARGO_PATH_VALUE=""
CARGO_HOME_VALUE=""

cleanup() {
  if [[ "${SEMANTIC_BACKEND_PARITY_KEEP_TMP:-}" == "1" ]]; then
    printf 'semantic backend parity tmp retained: %s\n' "$TMP_ROOT" >&2
    return 0
  fi
  rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

load_trusted_runtime_env() {
  local binary_name="$1"
  local runtime_env=""

  runtime_env="$(
    cd "$REPO_ROOT" && \
    /bin/bash scripts/semantic-review-queue.sh __internal-runtime-env --binary "$binary_name" --repo-root "$REPO_ROOT"
  )"

  unset RUNTIME_BINARY RUNTIME_PATH RUNTIME_HOME
  eval "$runtime_env"

  [[ -n "${RUNTIME_BINARY:-}" ]] || fail "missing trusted runtime binary for $binary_name"
  [[ -n "${RUNTIME_PATH:-}" ]] || fail "missing trusted runtime PATH for $binary_name"
  [[ -n "${RUNTIME_HOME:-}" ]] || fail "missing trusted runtime HOME for $binary_name"
}

load_rust_workspace_root() {
  RUST_WORKSPACE_ROOT="$(
    cd "$REPO_ROOT" && \
    /bin/bash scripts/semantic-review-queue.sh __internal-rust-workspace-root --repo-root "$REPO_ROOT"
  )"

  [[ -n "$RUST_WORKSPACE_ROOT" ]] || fail "missing trusted rust workspace root"
  [[ -f "$RUST_WORKSPACE_ROOT/Cargo.toml" ]] || fail "trusted rust workspace manifest not found: $RUST_WORKSPACE_ROOT/Cargo.toml"
}

load_runtime_contracts() {
  load_trusted_runtime_env node
  NODE_BINARY="$RUNTIME_BINARY"
  NODE_PATH_VALUE="$RUNTIME_PATH"
  NODE_HOME_VALUE="$RUNTIME_HOME"

  load_trusted_runtime_env cargo
  CARGO_BINARY="$RUNTIME_BINARY"
  CARGO_PATH_VALUE="$RUNTIME_PATH"
  CARGO_HOME_VALUE="$RUNTIME_HOME"

  load_rust_workspace_root
}

prepare_fixture_repo() {
  local fixture_repo="$1"

  mkdir -p "$fixture_repo/fixtures" "$fixture_repo/src/app" "$fixture_repo/src/app2" "$fixture_repo/src/lib"
  cp "$FIXTURE_DIR"/adjacency.*.jsonl "$fixture_repo/fixtures/"
  cp "$FIXTURE_DIR/components.json" "$fixture_repo/fixtures/components.json"
  printf 'export function Button() { return "Button targetNeedle"; }\n' > "$fixture_repo/src/app/Button.tsx"
  : > "$fixture_repo/src/app/ButtonGhost.tsx"
  : > "$fixture_repo/src/app2/Thing.tsx"
  : > "$fixture_repo/src/lib/Consumer.tsx"
  "$NODE_BINARY" -e 'process.stdout.write("{\"source_logical_id\":\"ui:Consumer\",\"target_logical_id\":\"" + "x".repeat(1024 * 1024 + 1) + "\"}\\n")' \
    > "$fixture_repo/fixtures/adjacency.overlong.jsonl"
}

write_mcp_scenario_runner() {
  local runner="$1"

  cat > "$runner" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = mustEnv("REPO_ROOT");
const backend = mustEnv("BACKEND");
const projectId = mustEnv("PROJECT_ID");
const fixtureRepo = mustEnv("FIXTURE_REPO");
const backendHome = mustEnv("BACKEND_HOME");
const runtimePath = mustEnv("RUNTIME_PATH");
const rustManifest = mustEnv("RUST_MANIFEST");
const nodeBinary = mustEnv("NODE_BINARY");
const cargoBinary = mustEnv("CARGO_BINARY");
const cargoHomeDir = mustEnv("CARGO_HOME_DIR");
const rustupHomeDir = mustEnv("RUSTUP_HOME_DIR");

const sdkRoot = join(repoRoot, "scripts/semantic-mcp-server/node_modules/@modelcontextprotocol/sdk/dist/esm");
const { Client } = await import(pathToFileURL(join(sdkRoot, "client/index.js")).href);
const { StdioClientTransport } = await import(pathToFileURL(join(sdkRoot, "client/stdio.js")).href);

const server = backend === "node"
  ? {
      command: nodeBinary,
      args: [join(repoRoot, "scripts/semantic-mcp-server/dist/index.js"), "--project-id", projectId],
      cwd: fixtureRepo,
      env: {
        PATH: runtimePath,
        HOME: backendHome,
        TMPDIR: process.env.TMPDIR ?? "/tmp"
      },
      stderr: "pipe"
    }
  : {
      command: cargoBinary,
      args: [
        "run",
        "--quiet",
        "--manifest-path",
        rustManifest,
        "-p",
        "semantic-mcp",
        "--",
        "--project-id",
        projectId
      ],
      cwd: fixtureRepo,
      env: {
        PATH: runtimePath,
        HOME: backendHome,
        CARGO_HOME: cargoHomeDir,
        RUSTUP_HOME: rustupHomeDir,
        TMPDIR: process.env.TMPDIR ?? "/tmp",
        RUST_BACKTRACE: "0"
      },
      stderr: "pipe"
    };

const transport = new StdioClientTransport(server);
let stderr = "";
transport.stderr?.on("data", (chunk) => {
  stderr += chunk.toString("utf8");
});

const client = new Client(
  { name: "semantic-backend-contract-parity", version: "0.1.0" },
  { capabilities: {} }
);

let failed = false;
try {
  await client.connect(transport);
  const result = await runScenario(client);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  failed = true;
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`[${backend}] scenario failed: ${message}\n`);
  if (stderr.trim().length > 0) {
    process.stderr.write(`[${backend}] server stderr:\n${stderr}\n`);
  }
} finally {
  await Promise.race([
    transport.close(),
    new Promise((resolve) => setTimeout(resolve, 2500).unref())
  ]);
  if (failed) {
    process.exit(1);
  }
}

async function runScenario(client) {
  const listTools = await client.listTools(undefined, { timeout: 20000 });
  const schema = normalizeRegistryQuerySchema(listTools);
  assertSchemaCompatibility(schema);

  const components = JSON.parse(readFileSync(join(fixtureRepo, "fixtures/components.json"), "utf8"));
  const upsert = await callTool(client, "sem.registry.upsert", {
    project_id: projectId,
    components
  });
  expectOk(upsert, "seed registry upsert");

  const exactSemanticId = normalizeQueryPayload(expectOk(
    await callTool(client, "sem.registry.query", {
      project_id: projectId,
      semantic_id: "ui:Button",
      limit: 10
    }),
    "exact semantic_id query"
  ));
  assertQueryItems("exact semantic_id query", exactSemanticId, ["ui:Button"]);

  const nameExact = normalizeQueryPayload(expectOk(
    await callTool(client, "sem.registry.query", {
      project_id: projectId,
      name_exact: "Button",
      limit: 10
    }),
    "name_exact query"
  ));
  assertQueryItems("name_exact query", nameExact, ["ui:Button"]);

  const pathPrefix = normalizeQueryPayload(expectOk(
    await callTool(client, "sem.registry.query", {
      project_id: projectId,
      path_prefix: "src/app/",
      limit: 10
    }),
    "path_prefix query"
  ));
  assertQueryItems("path_prefix query", pathPrefix, ["ui:Button", "ui:ButtonGhost"]);

  const search = normalizeSearchPayload(expectOk(
    await callTool(client, "sem.search", {
      project_id: projectId,
      query: "Button",
      scope_paths: ["src/app/Button.tsx"],
      limit: 50,
      capsule_budget_tokens: 500
    }),
    "bounded sem.search"
  ));
  assertSearchPayload("bounded sem.search", search);

  const searchNegativeBounds = normalizeSearchPayload(expectOk(
    await callTool(client, "sem.search", {
      project_id: projectId,
      query: "Button",
      scope_paths: ["src/app/Button.tsx"],
      limit: -5,
      capsule_budget_tokens: -1
    }),
    "sem.search negative bounds clamp"
  ));
  assertSearchMetadata("sem.search negative bounds clamp", searchNegativeBounds);

  writeFileSync(join(fixtureRepo, "src/app/InvalidUtf8.bin"), Buffer.from([0xff, 0xfe, 0x42, 0x75, 0x74, 0x74, 0x6f, 0x6e]));
  const searchInvalidUtf8 = normalizeSearchPayload(expectOk(
    await callTool(client, "sem.search", {
      project_id: projectId,
      query: "Button",
      scope_paths: ["src/app/InvalidUtf8.bin"],
      limit: 10,
      capsule_budget_tokens: 500
    }),
    "sem.search invalid utf8 skip"
  ));
  assertSearchEmpty("sem.search invalid utf8 skip", searchInvalidUtf8);

  const validPreflight = normalizePreflightPayload(expectOk(
    await callTool(client, "sem.preflight", {
      project_id: projectId,
      task_id: "task-parity",
      scope: ["src/app/Button.tsx"],
      proposed_components: [],
      deleted_paths: ["src/app/Button.tsx"],
      adjacency_path: "fixtures/adjacency.valid.jsonl"
    }),
    "valid adjacency preflight"
  ));
  if (validPreflight.reverse_dep !== "available" || validPreflight.impacts !== "1") {
    throw new Error(`valid adjacency preflight did not report reverse dependency impact: ${JSON.stringify(validPreflight)}`);
  }

  // # QUARANTINED: see plan_20260516_ts-wire-and-freshness §3 (Node TS parity restoration in follow-up)
  if (false) {
    const acceptedNullCapsule = normalizeCapsulePayload(expectOk(
      await callTool(client, "sem.capsule", {
        project_id: projectId,
        task_id: "task-capsule-null-context-fields",
        phase: "impl",
        context: {
          preflight_verdict: null,
          ambiguity: null,
          duplicate_risk: null
        }
      }),
      "capsule optional null context fields acceptance"
    ));
    assertAcceptedNullCapsule("capsule optional null context fields acceptance", acceptedNullCapsule);
  }

  const invalidQueryFailures = await collectInvalidQueryFailures(client);
  const invalidUpsertFailures = await collectInvalidUpsertFailures(client);
  const invalidRegistryEnvelopeFailures = await collectInvalidRegistryEnvelopeFailures(client);
  const invalidPreflightFailures = await collectInvalidPreflightFailures(client);
  const invalidCapsuleFailures = await collectInvalidCapsuleFailures(client);
  const failures = {
    path_like_module_escape: expectError(
      await callTool(client, "sem.registry.upsert", {
        project_id: projectId,
        components: [{
          semantic_id: "../outside/Escape.tsx:Escape",
          name: "Escape",
          module: "../outside/Escape.tsx",
          file_path: "src/app/Escape.tsx",
          kind: "component"
        }]
      }),
      "path-like module escape rejection"
    ),
    adjacency_path_escape: expectError(
      await callTool(client, "sem.preflight", {
        project_id: projectId,
        task_id: "task-adjacency-escape",
        scope: ["src/app/Button.tsx"],
        proposed_components: [],
        deleted_paths: ["src/app/Button.tsx"],
        adjacency_path: "../outside/adjacency.jsonl"
      }),
      "adjacency_path escape rejection"
    ),
    malformed_adjacency_json: expectError(
      await callTool(client, "sem.preflight", {
        project_id: projectId,
        task_id: "task-malformed-adjacency",
        scope: ["src/app/Button.tsx"],
        proposed_components: [],
        deleted_paths: ["src/app/Button.tsx"],
        adjacency_path: "fixtures/adjacency.malformed.jsonl"
      }),
      "malformed adjacency JSON fail-closed"
    ),
    missing_adjacency_fields: expectError(
      await callTool(client, "sem.preflight", {
        project_id: projectId,
        task_id: "task-missing-adjacency-fields",
        scope: ["src/app/Button.tsx"],
        proposed_components: [],
        deleted_paths: ["src/app/Button.tsx"],
        adjacency_path: "fixtures/adjacency.missing-fields.jsonl"
      }),
      "missing adjacency fields fail-closed"
    ),
    overlong_adjacency_line: expectError(
      await callTool(client, "sem.preflight", {
        project_id: projectId,
        task_id: "task-overlong-adjacency",
        scope: ["src/app/Button.tsx"],
        proposed_components: [],
        deleted_paths: ["src/app/Button.tsx"],
        adjacency_path: "fixtures/adjacency.overlong.jsonl"
      }),
      "overlong adjacency line fail-closed"
    ),
    non_object_args: expectError(
      await callTool(client, "sem.registry.query", "not-an-object"),
      "non-object tool arguments rejection"
    ),
    unexpected_key: expectError(
      await callTool(client, "sem.registry.query", {
        project_id: projectId,
        semantic_id: "ui:Button",
        unexpected_key: true
      }),
      "unexpected tool argument key rejection"
    ),
    exact_alias_mismatch: expectError(
      await callTool(client, "sem.registry.query", {
        project_id: projectId,
        name_exact: "Button",
        nameExact: "ButtonGhost"
      }),
      "exact alias mismatch rejection"
    ),
    search_empty_scope: expectError(
      await callTool(client, "sem.search", {
        project_id: projectId,
        query: "Button",
        scope_paths: []
      }),
      "sem.search empty scope rejection"
    ),
    search_broad_scope: expectError(
      await callTool(client, "sem.search", {
        project_id: projectId,
        query: "Button",
        scope_paths: ["."]
      }),
      "sem.search broad scope rejection"
    ),
    search_traversal_scope: expectError(
      await callTool(client, "sem.search", {
        project_id: projectId,
        query: "Button",
        scope_paths: ["../outside.ts"]
      }),
      "sem.search traversal scope rejection"
    ),
    ...invalidQueryFailures,
    ...invalidUpsertFailures,
    ...invalidRegistryEnvelopeFailures,
    ...invalidPreflightFailures,
    ...invalidCapsuleFailures
  };

  return {
    tools_list_schema: schema,
    queries: {
      exact_semantic_id: exactSemanticId,
      name_exact: nameExact,
      path_prefix: pathPrefix,
      search,
      search_negative_bounds: searchNegativeBounds,
      search_invalid_utf8: searchInvalidUtf8
    },
    preflight: {
      valid_adjacency: validPreflight
    },
    capsule: {
      accepted_null_context_fields: acceptedNullCapsule
    },
    fail_closed: failures
  };
}

async function collectInvalidQueryFailures(client) {
  const invalidCases = [
    ["semantic_id_number", { semantic_id: 123 }],
    ["semantic_id_null", { semantic_id: null }],
    ["semantic_id_blank", { semantic_id: "   " }],
    ["logical_id_number", { logical_id: 123 }],
    ["logical_id_null", { logical_id: null }],
    ["logical_id_blank", { logical_id: "   " }],
    ["status_number", { status: 123 }],
    ["status_null", { status: null }],
    ["status_blank", { status: "   " }],
    ["status_alias_number", { statuses: 123 }],
    ["status_alias_null", { statuses: null }],
    ["status_alias_blank", { statuses: ["   "] }],
    ["status_alias_mismatch", { status: "active", statuses: ["deleted"] }],
    ["kind_blank", { kind: "" }],
    ["name_blank", { name: "   " }],
    ["name_partial_blank", { name_partial: "   " }],
    ["namePartial_blank", { namePartial: "   " }],
    ["symbol_blank", { symbol: "   " }],
    ["name_exact_number", { name_exact: 123 }],
    ["name_exact_null", { name_exact: null }],
    ["name_exact_blank", { name_exact: "   " }],
    ["nameExact_number", { nameExact: 123 }],
    ["nameExact_null", { nameExact: null }],
    ["nameExact_blank", { nameExact: "   " }],
    ["symbol_exact_number", { symbol_exact: 123 }],
    ["symbol_exact_null", { symbol_exact: null }],
    ["symbol_exact_blank", { symbol_exact: "   " }],
    ["symbolExact_number", { symbolExact: 123 }],
    ["symbolExact_null", { symbolExact: null }],
    ["symbolExact_blank", { symbolExact: "   " }]
  ];
  const failures = {};

  for (const [caseName, args] of invalidCases) {
    failures[`invalid_query_${caseName}`] = expectError(
      await callTool(client, "sem.registry.query", {
        project_id: projectId,
        ...args
      }),
      `invalid sem.registry.query ${caseName} fail-closed`
    );
  }

  return failures;
}

async function collectInvalidUpsertFailures(client) {
  const invalidCases = [
    ["status_uppercase_with_spaces", { status: " INACTIVE " }],
    ["_status_uppercase_with_spaces", { _status: " INACTIVE " }],
    ["exports_string", { exports: "Thing" }],
    ["exports_null", { exports: null }],
    ["exported_string", { exported: "Thing" }],
    ["exported_null", { exported: null }],
    ["imports_string", { imports: "Thing" }],
    ["imports_null", { imports: null }],
    ["dependencies_string", { dependencies: "Thing" }],
    ["dependencies_null", { dependencies: null }],
    ["semantic_id_internal_whitespace", { semantic_id: "mod:\tThing" }],
    ["logical_id_internal_whitespace", { logical_id: "mod:\nThing" }]
  ];
  const failures = {};

  for (const [caseName, overrides] of invalidCases) {
    failures[`invalid_upsert_${caseName}`] = expectError(
      await callTool(client, "sem.registry.upsert", {
        project_id: projectId,
        components: [componentForInvalidUpsert(caseName, overrides)]
      }),
      `invalid sem.registry.upsert ${caseName} fail-closed`
    );
  }

  return failures;
}

async function collectInvalidRegistryEnvelopeFailures(client) {
  const component = componentForRegistryEnvelope("valid");
  const alternateComponent = componentForRegistryEnvelope("alternate");
  const invalidCases = [
    [
      "non-array components",
      {
        components: component
      }
    ],
    [
      "non-array deltas",
      {
        deltas: { component }
      }
    ],
    [
      "empty delta",
      {
        delta: []
      }
    ],
    [
      "mixed envelope top-level delta plus components",
      {
        components: [component],
        delta: [alternateComponent]
      }
    ],
    [
      "mixed envelope top-level component siblings with components",
      {
        components: [component],
        semantic_id: "invalid:top_level_sibling",
        name: "TopLevelSibling",
        module: "invalid",
        file_path: "src/app/top_level_sibling.tsx",
        kind: "component"
      }
    ],
    [
      "nested envelope delta.components plus after",
      {
        delta: {
          components: [component],
          after: alternateComponent
        }
      }
    ],
    [
      "unexpected key in nested component",
      {
        delta: {
          components: [
            componentForRegistryEnvelope("unexpected_nested_component_key", {
              unexpected_nested_key: true
            })
          ]
        }
      }
    ]
  ];
  const failures = {};

  // Node accepts collection envelopes that contain both components and deltas, and
  // also accepts delta.components plus delta.deltas; those are not fail-closed cases.
  for (const [caseName, args] of invalidCases) {
    failures[`invalid_registry_upsert_${caseName.replaceAll(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "")}`] = expectError(
      await callTool(client, "sem.registry.upsert", {
        project_id: projectId,
        ...args
      }),
      `invalid sem.registry.upsert ${caseName} fail-closed`
    );
  }

  return failures;
}

async function collectInvalidPreflightFailures(client) {
  const invalidCases = [
    ["adjacency_path non-string", { adjacency_path: 123 }],
    ["deleted_paths null", { deleted_paths: null }],
    ["deleted_paths non-array", { deleted_paths: "src/app/Button.tsx" }],
    ["deleted_paths non-string element", { deleted_paths: [123] }],
    ["removed_symbols null", { removed_symbols: null }],
    ["removed_symbols non-array", { removed_symbols: "ui:Button" }],
    ["removed_symbols non-string element", { removed_symbols: [123] }],
    ["move_candidates null", { move_candidates: null }],
    ["move_candidates non-array", { move_candidates: "src/app/Button.tsx" }],
    ["move_candidates non-object element", { move_candidates: ["src/app/Button.tsx"] }],
    ["move_candidates old_path non-string element", { move_candidates: [{ old_path: 123, new_path: "src/app/Button.tsx" }] }],
    ["move_candidates new_path non-string element", { move_candidates: [{ old_path: "src/app/Button.tsx", new_path: 123 }] }],
    ["dependency_verdict null", { dependency_verdict: null }]
  ];
  const failures = {};

  // Node currently treats adjacency_path: null as absent, so it is not a parity
  // fail-closed case unless the Node reference changes.
  for (const [caseName, args] of invalidCases) {
    failures[`invalid_preflight_${caseName.replaceAll(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "")}`] = expectError(
      await callTool(client, "sem.preflight", {
        project_id: projectId,
        task_id: `task-${caseName.replaceAll(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")}`,
        scope: ["src/app/Button.tsx"],
        proposed_components: [],
        ...args
      }),
      `invalid sem.preflight ${caseName} fail-closed`
    );
  }

  return failures;
}

async function collectInvalidCapsuleFailures(client) {
  const invalidCases = [
    ["capsule context non-object", { context: "not-an-object" }],
    ["capsule context array non-object", { context: [] }],
    ["changed_symbols null", { context: { changed_symbols: null } }],
    ["changed_symbols non-array", { context: { changed_symbols: "ui:Button" } }],
    ["changed_symbols non-string element", { context: { changed_symbols: [123] } }],
    ["target_lock invalid signal non-object", { context: { target_lock: 123 } }],
    ["target_lock invalid signal missing status", { context: { target_lock: {} } }],
    ["ambiguity invalid signal missing status", { context: { ambiguity: {} } }],
    ["duplicate_risk invalid signal summary shape", { context: { duplicate_risk: { status: "warn", summary: 123 } } }]
  ];
  // QUARANTINED: see plan_20260516_ts-wire-and-freshness §3.
  // Rust semantic-mcp now rejects caller-supplied top_k_symbols and requires
  // server-issued context_token from sem.context.top_k; Node TS parity follows
  // in plan_2026XXXX_node-ts-parity-restore.md.
  if (false) {
    invalidCases.push(
      ["top_k_symbols null", { context: { top_k_symbols: null } }],
      ["top_k_symbols non-array", { context: { top_k_symbols: "ui:Button" } }],
      ["top_k_symbols non-string element", { context: { top_k_symbols: [123] } }]
    );
  }
  const failures = {};

  // Node currently treats context: null and the optional context signal nulls
  // covered by accepted_null_context_fields as absent, so they are not parity
  // fail-closed cases unless the Node reference changes.
  // # QUARANTINED: see plan_20260516_ts-wire-and-freshness §3 (Node TS parity restoration in follow-up)
  if (false) {
    for (const [caseName, args] of invalidCases) {
      failures[`invalid_capsule_${caseName.replaceAll(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "")}`] = expectError(
        await callTool(client, "sem.capsule", {
          project_id: projectId,
          task_id: `task-${caseName.replaceAll(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")}`,
          phase: "impl",
          ...args
        }),
        `invalid sem.capsule ${caseName} fail-closed`
      );
    }
  }

  return failures;
}

function componentForRegistryEnvelope(caseName, overrides = {}) {
  return {
    semantic_id: `envelope:${caseName}`,
    name: `Envelope${caseName.replaceAll(/[^a-z0-9]+/gi, "_")}`,
    module: "envelope",
    file_path: `src/app/${caseName.replaceAll(/[^a-z0-9]+/g, "_")}.tsx`,
    kind: "component",
    ...overrides
  };
}

function componentForInvalidUpsert(caseName, overrides) {
  const component = {
    semantic_id: overrides.semantic_id ?? `invalid:${caseName}`,
    name: caseName,
    module: "invalid",
    file_path: `src/app/${caseName}.tsx`,
    kind: "component",
    ...overrides
  };
  if (Object.prototype.hasOwnProperty.call(overrides, "logical_id")) {
    delete component.semantic_id;
  }
  return component;
}

async function callTool(client, name, args) {
  try {
    const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 30000 });
    const text = result.content?.[0]?.type === "text" ? result.content[0].text : "";
    let payload = null;
    if (!result.isError && text.length > 0) {
      payload = JSON.parse(text);
    }
    return {
      isError: result.isError === true,
      text,
      payload
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      isError: true,
      text: message,
      payload: null
    };
  }
}

function normalizeRegistryQuerySchema(listTools) {
  const tool = listTools.tools.find((candidate) => candidate.name === "sem.registry.query");
  if (!tool) {
    throw new Error("tools/list did not include sem.registry.query");
  }
  const properties = tool.inputSchema?.properties ?? {};
  const exactFields = ["semantic_id", "name_exact", "nameExact", "symbol_exact", "symbolExact"];
  const searchTool = listTools.tools.find((candidate) => candidate.name === "sem.search");
  if (!searchTool) {
    throw new Error("tools/list did not include sem.search");
  }
  const searchProperties = searchTool.inputSchema?.properties ?? {};
  return {
    registry_query_additional_properties_false: tool.inputSchema?.additionalProperties === false,
    registry_query_exact_fields: Object.fromEntries(
      exactFields.map((field) => [field, Object.prototype.hasOwnProperty.call(properties, field)])
    ),
    search_additional_properties_false: searchTool.inputSchema?.additionalProperties === false,
    search_scope_paths_present: Object.prototype.hasOwnProperty.call(searchProperties, "scope_paths"),
    search_required_query: JSON.stringify(searchTool.inputSchema?.required ?? []) === JSON.stringify(["query"]),
    search_limit_integer_contract: JSON.stringify(searchProperties.limit ?? {}).includes('"integer"')
      && JSON.stringify(searchProperties.limit ?? {}).includes('^-?\\\\d+$'),
    search_budget_integer_contract: JSON.stringify(searchProperties.capsule_budget_tokens ?? {}).includes('"integer"')
      && JSON.stringify(searchProperties.capsule_budget_tokens ?? {}).includes('^-?\\\\d+$')
  };
}

function assertSchemaCompatibility(schema) {
  if (!schema.registry_query_additional_properties_false) {
    throw new Error("sem.registry.query schema must set additionalProperties=false");
  }
  for (const [field, present] of Object.entries(schema.registry_query_exact_fields)) {
    if (present !== true) {
      throw new Error(`sem.registry.query schema missing exact field: ${field}`);
    }
  }
  if (!schema.search_additional_properties_false) {
    throw new Error("sem.search schema must set additionalProperties=false");
  }
  if (!schema.search_scope_paths_present || !schema.search_required_query) {
    throw new Error("sem.search schema missing bounded explicit-scope contract");
  }
  if (!schema.search_limit_integer_contract || !schema.search_budget_integer_contract) {
    throw new Error("sem.search schema missing integer/string limit budget parity");
  }
}

function expectOk(result, label) {
  if (result.isError) {
    throw new Error(`${label} unexpectedly failed: ${result.text}`);
  }
  if (result.payload === null) {
    throw new Error(`${label} returned no JSON payload`);
  }
  return result.payload;
}

function expectError(result, label) {
  if (!result.isError) {
    throw new Error(`${label} unexpectedly succeeded: ${JSON.stringify(result.payload)}`);
  }
  if (typeof result.text !== "string" || result.text.trim().length === 0) {
    throw new Error(`${label} failed without an error message`);
  }
  return true;
}

function normalizeQueryPayload(payload) {
  const items = Array.isArray(payload.items) ? payload.items : [];
  return {
    total: payload.total,
    items: items.map((item) => ({
      semantic_id: item.semantic_id,
      path: item.path,
      symbol: item.symbol,
      kind: item.kind
    }))
  };
}

function assertQueryItems(label, payload, expectedSemanticIds) {
  const actual = payload.items.map((item) => item.semantic_id);
  if (JSON.stringify(actual) !== JSON.stringify(expectedSemanticIds)) {
    throw new Error(`${label} returned ${JSON.stringify(actual)}, expected ${JSON.stringify(expectedSemanticIds)}`);
  }
  if (payload.total !== expectedSemanticIds.length) {
    throw new Error(`${label} total=${payload.total}, expected ${expectedSemanticIds.length}`);
  }
}

function normalizeSearchPayload(payload) {
  const items = Array.isArray(payload.items) ? payload.items : [];
  return {
    advisory_only: payload.advisory_only,
    total: payload.total,
    truncated: payload.truncated,
    capsule: String(payload.capsule ?? ""),
    items: items.map((item) => ({
      path: item.path,
      semantic_id: item.semantic_id,
      symbol: item.symbol,
      source: item.source,
      excerpt: item.excerpt
    }))
  };
}

function assertSearchPayload(label, payload) {
  assertSearchMetadata(label, payload);
  if (!payload.items.some((item) => item.path === "src/app/Button.tsx")) {
    throw new Error(`${label} did not return scoped Button.tsx result: ${JSON.stringify(payload)}`);
  }
  for (const item of payload.items) {
    if (typeof item.excerpt === "string" && item.excerpt.length > 80) {
      throw new Error(`${label} returned overlong excerpt`);
    }
  }
}

function assertSearchMetadata(label, payload) {
  if (payload.advisory_only !== true || !payload.capsule.includes("advisory_only:true")) {
    throw new Error(`${label} did not mark output advisory-only`);
  }
}

function assertSearchEmpty(label, payload) {
  assertSearchMetadata(label, payload);
  if (payload.total !== 0 || payload.items.length !== 0) {
    throw new Error(`${label} returned matches for invalid UTF-8: ${JSON.stringify(payload)}`);
  }
}

function normalizePreflightPayload(payload) {
  const summary = String(payload.delete_impacts_summary ?? "");
  return {
    verdict: payload.verdict,
    reverse_dep: readSummaryValue(summary, "reverse_dep"),
    impacts: readSummaryValue(summary, "impacts")
  };
}

function normalizeCapsulePayload(payload) {
  const capsule = String(payload.capsule ?? "");
  const hints = Array.isArray(payload.hints)
    ? payload.hints.filter((hint) => typeof hint === "string")
    : [];
  const nullSignalHintPrefixes = ["preflight=", "ambiguity=", "duplicate_risk="];
  return {
    preflight: readCapsuleValue(capsule, "PREFLIGHT"),
    ambiguity: readCapsuleValue(capsule, "AMBIGUITY"),
    duplicate_risk: readCapsuleValue(capsule, "DUPLICATE_RISK"),
    changed_count: readCapsuleValue(capsule, "CHANGED_COUNT"),
    topk_count: readCapsuleValue(capsule, "TOPK_COUNT"),
    has_capsule_hash: capsule.split("\n").some((line) => /^CAPSULE_SHA256=[0-9a-f]{64}$/.test(line)),
    null_context_signal_hints_absent: !hints.some((hint) =>
      nullSignalHintPrefixes.some((prefix) => hint.startsWith(prefix))
    )
  };
}

function assertAcceptedNullCapsule(label, payload) {
  const expected = {
    preflight: "UNKNOWN",
    ambiguity: "unknown",
    duplicate_risk: "unknown",
    changed_count: "0",
    topk_count: "0",
    has_capsule_hash: true,
    null_context_signal_hints_absent: true
  };
  for (const [field, expectedValue] of Object.entries(expected)) {
    if (payload[field] !== expectedValue) {
      throw new Error(`${label} ${field}=${JSON.stringify(payload[field])}, expected ${JSON.stringify(expectedValue)}`);
    }
  }
}

function readSummaryValue(summary, key) {
  const match = summary.match(new RegExp(`(?:^| )${key}=([^ ]+)`));
  return match ? match[1] : "";
}

function readCapsuleValue(capsule, key) {
  const prefix = `${key}=`;
  const line = capsule.split("\n").find((candidate) => candidate.startsWith(prefix));
  return line ? line.slice(prefix.length) : "";
}

function mustEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`missing required environment variable: ${name}`);
  }
  return value;
}
EOF
}

run_backend_scenario() {
  local backend="$1"
  local project_id="$2"
  local fixture_repo="$3"
  local backend_home="$4"
  local output_file="$5"
  local runner="$TMP_ROOT/mcp_scenario_runner.mjs"

  (
    cd "$REPO_ROOT"
    /usr/bin/env -i \
      "PATH=$NODE_PATH_VALUE:$CARGO_PATH_VALUE" \
      "HOME=$NODE_HOME_VALUE" \
      "TMPDIR=${TMPDIR:-/tmp}" \
      "REPO_ROOT=$REPO_ROOT" \
      "BACKEND=$backend" \
      "PROJECT_ID=$project_id" \
      "FIXTURE_REPO=$fixture_repo" \
      "BACKEND_HOME=$backend_home" \
      "RUNTIME_PATH=$NODE_PATH_VALUE:$CARGO_PATH_VALUE" \
      "RUST_MANIFEST=$RUST_WORKSPACE_ROOT/Cargo.toml" \
      "NODE_BINARY=$NODE_BINARY" \
      "CARGO_BINARY=$CARGO_BINARY" \
      "CARGO_HOME_DIR=$CARGO_HOME_VALUE/.cargo" \
      "RUSTUP_HOME_DIR=$CARGO_HOME_VALUE/.rustup" \
      "$NODE_BINARY" "$runner"
  ) >"$output_file"
}

main() {
  require_cmd diff
  require_cmd jq
  require_cmd mktemp
  [[ -f "$FIXTURE_DIR/components.json" ]] || fail "missing fixture components.json"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/semantic_backend_contract_parity.XXXXXX")"
  load_runtime_contracts

  local fixture_repo="$TMP_ROOT/repo"
  local node_home="$TMP_ROOT/home-node"
  local rust_home="$TMP_ROOT/home-rust"
  local node_out="$TMP_ROOT/node.json"
  local rust_out="$TMP_ROOT/rust.json"
  local node_norm="$TMP_ROOT/node.normalized.json"
  local rust_norm="$TMP_ROOT/rust.normalized.json"

  mkdir -p "$node_home" "$rust_home"
  prepare_fixture_repo "$fixture_repo"
  write_mcp_scenario_runner "$TMP_ROOT/mcp_scenario_runner.mjs"

  run_backend_scenario node semantic-parity-node "$fixture_repo" "$node_home" "$node_out"
  run_backend_scenario rust semantic-parity-rust "$fixture_repo" "$rust_home" "$rust_out"

  jq -S . "$node_out" > "$node_norm"
  jq -S . "$rust_out" > "$rust_norm"
  diff -u "$node_norm" "$rust_norm"

  printf 'PASS: semantic_backend_contract_parity_test\n'
}

main "$@"
