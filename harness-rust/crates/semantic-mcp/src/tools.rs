//! Tool definitions and dispatch for the semantic MCP server.
//!
//! Provides the central `call_tool` dispatcher and JSON Schema definitions
//! for all MCP tools.

use serde_json::Value;

use crate::admin_gc;
use crate::capsule;
use crate::context::ServerContext;
use crate::context_top_k;
use crate::health;
use crate::preflight;
use crate::registry;
use crate::search;
use crate::symbols_search;

/// Tool names as constants.
pub const TOOL_PREFLIGHT: &str = "sem.preflight";
pub const TOOL_CAPSULE: &str = "sem.capsule";
pub const TOOL_CONTEXT_TOP_K: &str = "sem.context.top_k";
pub const TOOL_REGISTRY_UPSERT: &str = "sem.registry.upsert";
pub const TOOL_REGISTRY_QUERY: &str = "sem.registry.query";
pub const TOOL_REGISTRY_SET_STATUS: &str = "sem.registry.set_status";
pub const TOOL_REGISTRY_DELETE: &str = "sem.registry.delete";
pub const TOOL_SEARCH: &str = "sem.search";
pub const TOOL_SYMBOLS_SEARCH: &str = "sem.symbols.search";
pub const TOOL_HEALTH: &str = "sem.health";
pub const TOOL_ADMIN_GC: &str = "sem.admin.gc";

const PREFLIGHT_KEYS: &[&str] = &[
    "project_id",
    "task_id",
    "scope",
    "proposed_components",
    "deleted_paths",
    "removed_symbols",
    "move_candidates",
    "adjacency_path",
    "dependency_verdict",
];
const CAPSULE_KEYS: &[&str] = &[
    "project_id",
    "task_id",
    "phase",
    "budget",
    "context",
    "context_token",
    "top_k_symbols",
];
const CONTEXT_TOP_K_KEYS: &[&str] = &[
    "project_id",
    "task_id",
    "phase",
    "changed_files",
    "k",
    "max_depth",
    "max_nodes",
];
const REGISTRY_UPSERT_KEYS: &[&str] = &[
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
    "components",
    "deltas",
    "delta",
];
const REGISTRY_QUERY_KEYS: &[&str] = &[
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
    "offset",
];
const REGISTRY_SET_STATUS_KEYS: &[&str] = &[
    "project_id",
    "semantic_id",
    "logical_id",
    "module",
    "name",
    "symbol",
    "status",
    "inactive_reason",
    "reason",
];
const REGISTRY_DELETE_KEYS: &[&str] = &[
    "project_id",
    "semantic_id",
    "logical_id",
    "module",
    "name",
    "symbol",
    "reason",
    "inactive_reason",
];
const SEARCH_KEYS: &[&str] = &[
    "project_id",
    "query",
    "scope_paths",
    "scopePaths",
    "kind",
    "limit",
    "capsule_budget_tokens",
    "capsuleBudgetTokens",
];
const SYMBOLS_SEARCH_KEYS: &[&str] = &[
    "project_id",
    "query",
    "kind",
    "language",
    "path_prefix",
    "limit",
    "capsule_budget_tokens",
];
const HEALTH_KEYS: &[&str] = &[];
const ADMIN_GC_KEYS: &[&str] = &["older_than_days", "dry_run", "force", "ignore_active_lock"];

/// Return JSON Schema definitions for all tools.
pub fn tool_definitions() -> Vec<Value> {
    vec![
        serde_json::json!({
            "name": TOOL_PREFLIGHT,
            "description": "Validate planned semantic changes before applying updates.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "task_id": { "type": "string" },
                    "scope": { "type": "array", "items": { "type": "string" } },
                    "proposed_components": { "type": "array", "items": { "type": "string" } },
                    "deleted_paths": { "type": "array", "items": { "type": "string" } },
                    "removed_symbols": { "type": "array", "items": { "type": "string" } },
                    "move_candidates": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "old_path": { "type": "string" },
                                "new_path": { "type": "string" }
                            },
                            "required": ["old_path", "new_path"],
                            "additionalProperties": false
                        }
                    },
                    "adjacency_path": { "type": "string" },
                    "dependency_verdict": {
                        "type": "object",
                        "properties": {
                            "status": { "type": "string", "enum": ["pass", "warn", "block"] },
                            "issues": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "package": { "type": "string" },
                                        "severity": { "type": "string", "enum": ["critical", "high", "medium", "low"] },
                                        "message": { "type": "string" }
                                    },
                                    "required": ["package", "severity", "message"],
                                    "additionalProperties": false
                                }
                            },
                            "checked_at": { "type": "string" }
                        },
                        "required": ["status", "issues", "checked_at"],
                        "additionalProperties": false
                    }
                },
                "required": ["project_id", "task_id", "scope", "proposed_components"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_CAPSULE,
            "description": "Generate a compact semantic capsule from a server-issued context_token.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "task_id": { "type": "string" },
                    "phase": { "type": "string" },
                    "budget": { "type": "integer" },
                    "context_token": { "type": "string" },
                    "context": {
                        "type": "object",
                        "properties": {
                            "changed_symbols": { "type": "array", "items": { "type": "string" } },
                            "preflight_verdict": { "type": "string" }
                        },
                        "additionalProperties": false
                    }
                },
                "required": ["project_id", "task_id", "phase", "context_token"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_CONTEXT_TOP_K,
            "description": "Issue a fresh context_token and server-ranked top-k symbols for changed repo-relative files.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "task_id": { "type": "string" },
                    "phase": { "type": "string" },
                    "changed_files": {
                        "type": "array",
                        "items": { "type": "string" },
                        "minItems": 1,
                        "maxItems": 512
                    },
                    "k": { "type": "integer", "minimum": 1, "maximum": 32 },
                    "max_depth": { "type": "integer", "minimum": 1, "maximum": 5 },
                    "max_nodes": { "type": "integer", "minimum": 1, "maximum": 1024 }
                },
                "required": ["project_id", "task_id", "phase", "changed_files"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_REGISTRY_UPSERT,
            "description": "Apply registry delta updates with idempotency tracking.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "semantic_id": { "type": "string" },
                    "logical_id": { "type": "string" },
                    "name": { "type": "string" },
                    "symbol": { "type": "string" },
                    "module": { "type": "string" },
                    "file_path": { "type": "string" },
                    "path": { "type": "string" },
                    "file": { "type": "string" },
                    "kind": { "type": "string" },
                    "exports": { "type": "array" },
                    "exported": { "type": "array" },
                    "imports": { "type": "array" },
                    "dependencies": { "type": "array" },
                    "hash": { "type": "string" },
                    "figma_ref": { "type": "string" },
                    "status": { "type": "string" },
                    "inactive_reason": { "type": "string" },
                    "security_level": { "type": "string" },
                    "components": { "type": "array" },
                    "deltas": { "type": "array" },
                    "delta": {}
                },
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_REGISTRY_QUERY,
            "description": "Query semantic registry entries with compact result fields.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "semantic_id": { "type": "string" },
                    "kind": { "type": "string" },
                    "path_prefix": { "type": "string" },
                    "pathPrefix": { "type": "string" },
                    "path": { "type": "string" },
                    "name": { "type": "string" },
                    "symbol": { "type": "string" },
                    "name_exact": { "type": "string" },
                    "nameExact": { "type": "string" },
                    "symbol_exact": { "type": "string" },
                    "symbolExact": { "type": "string" },
                    "name_partial": { "type": "string" },
                    "namePartial": { "type": "string" },
                    "status": { "type": "string" },
                    "statuses": { "type": "array", "items": { "type": "string" } },
                    "limit": {},
                    "offset": {}
                },
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_REGISTRY_SET_STATUS,
            "description": "Set component lifecycle status in semantic registry.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "semantic_id": { "type": "string" },
                    "logical_id": { "type": "string" },
                    "module": { "type": "string" },
                    "name": { "type": "string" },
                    "symbol": { "type": "string" },
                    "status": {
                        "type": "string",
                        "enum": ["active", "inactive", "incomplete", "buggy", "deprecated"]
                    },
                    "inactive_reason": { "type": "string" },
                    "reason": { "type": "string" }
                },
                "required": ["status"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_REGISTRY_DELETE,
            "description": "Logically delete semantic registry entries by identifier.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "semantic_id": { "type": "string" },
                    "logical_id": { "type": "string" },
                    "module": { "type": "string" },
                    "name": { "type": "string" },
                    "symbol": { "type": "string" },
                    "reason": { "type": "string" },
                    "inactive_reason": { "type": "string" }
                },
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_SEARCH,
            "description": "Bounded advisory semantic search over explicit repo-relative scopes.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "query": { "type": "string" },
                    "scope_paths": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
                    "scopePaths": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
                    "kind": { "type": "string" },
                    "limit": { "anyOf": [{ "type": "integer" }, { "type": "string", "pattern": "^-?\\d+$" }] },
                    "capsule_budget_tokens": { "anyOf": [{ "type": "integer" }, { "type": "string", "pattern": "^-?\\d+$" }] },
                    "capsuleBudgetTokens": { "anyOf": [{ "type": "integer" }, { "type": "string", "pattern": "^-?\\d+$" }] }
                },
                "required": ["query"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_SYMBOLS_SEARCH,
            "description": "Read-only advisory free-form search over the tree-sitter symbols index by name or qualified_name substring.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project_id": { "type": "string" },
                    "query": { "type": "string" },
                    "kind": { "type": "string" },
                    "language": { "type": "string" },
                    "path_prefix": { "type": "string" },
                    "limit": { "anyOf": [{ "type": "integer" }, { "type": "string", "pattern": "^-?\\d+$" }] },
                    "capsule_budget_tokens": { "anyOf": [{ "type": "integer" }, { "type": "string", "pattern": "^-?\\d+$" }] }
                },
                "required": ["query"],
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_HEALTH,
            "description": "Check server health, database connectivity, and table readiness.",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }
        }),
        serde_json::json!({
            "name": TOOL_ADMIN_GC,
            "description": "Dry-run or force-delete stale managed semantic MCP databases.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "older_than_days": { "type": "integer", "minimum": 1 },
                    "dry_run": { "type": "boolean" },
                    "force": { "type": "boolean" },
                    "ignore_active_lock": { "type": "boolean" }
                },
                "additionalProperties": false
            }
        }),
    ]
}

/// Dispatch a tool call to the appropriate handler.
///
/// Returns the tool result as a JSON value on success, or an error message string.
pub fn call_tool(ctx: &ServerContext, name: &str, args: &Value) -> Result<Value, String> {
    validate_tool_arguments(name, args)?;
    match name {
        TOOL_HEALTH => health::handle_health(ctx),
        TOOL_PREFLIGHT => preflight::handle_preflight(ctx, args),
        TOOL_CAPSULE => capsule::handle_capsule(ctx, args),
        TOOL_CONTEXT_TOP_K => context_top_k::handle_context_top_k(ctx, args),
        TOOL_REGISTRY_UPSERT => registry::handle_upsert(ctx, args),
        TOOL_REGISTRY_QUERY => registry::handle_query(ctx, args),
        TOOL_REGISTRY_SET_STATUS => registry::handle_set_status(ctx, args),
        TOOL_REGISTRY_DELETE => registry::handle_delete(ctx, args),
        TOOL_SEARCH => search::handle_search(ctx, args),
        TOOL_SYMBOLS_SEARCH => symbols_search::handle_symbols_search(ctx, args),
        TOOL_ADMIN_GC => admin_gc::handle_admin_gc(ctx, args),
        _ => Err(format!("Unknown tool: {name}")),
    }
}

pub fn validate_tool_arguments(name: &str, args: &Value) -> Result<(), String> {
    let allowed_keys = match name {
        TOOL_PREFLIGHT => PREFLIGHT_KEYS,
        TOOL_CAPSULE => CAPSULE_KEYS,
        TOOL_CONTEXT_TOP_K => CONTEXT_TOP_K_KEYS,
        TOOL_REGISTRY_UPSERT => REGISTRY_UPSERT_KEYS,
        TOOL_REGISTRY_QUERY => REGISTRY_QUERY_KEYS,
        TOOL_REGISTRY_SET_STATUS => REGISTRY_SET_STATUS_KEYS,
        TOOL_REGISTRY_DELETE => REGISTRY_DELETE_KEYS,
        TOOL_SEARCH => SEARCH_KEYS,
        TOOL_SYMBOLS_SEARCH => SYMBOLS_SEARCH_KEYS,
        TOOL_HEALTH => HEALTH_KEYS,
        TOOL_ADMIN_GC => ADMIN_GC_KEYS,
        _ => return Ok(()),
    };

    let obj = args
        .as_object()
        .ok_or_else(|| "tool arguments must be an object".to_string())?;
    let unexpected: Vec<&str> = obj
        .keys()
        .map(String::as_str)
        .filter(|key| !allowed_keys.contains(key))
        .collect();
    if !unexpected.is_empty() {
        return Err(format!(
            "tool arguments contain unexpected key(s): {}",
            unexpected.join(", ")
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_list_schema_additional_properties_false_and_exact_query_fields() {
        let tools = tool_definitions();
        let query_tool = tools
            .iter()
            .find(|tool| tool["name"] == TOOL_REGISTRY_QUERY)
            .expect("registry query tool");
        let schema = &query_tool["inputSchema"];
        assert_eq!(schema["additionalProperties"], false);
        let props = schema["properties"].as_object().unwrap();
        for key in [
            "semantic_id",
            "name_exact",
            "nameExact",
            "symbol_exact",
            "symbolExact",
        ] {
            assert!(props.contains_key(key), "missing exact query field {key}");
        }
    }

    #[test]
    fn no_top_level_conditional_keywords_in_tool_schemas() {
        let banned = [
            "anyOf",
            "oneOf",
            "allOf",
            "enum",
            "not",
            "$ref",
            "$dynamicRef",
        ];
        for tool in tool_definitions() {
            let name = tool["name"].as_str().unwrap_or("<unknown>");
            let schema = tool["inputSchema"]
                .as_object()
                .unwrap_or_else(|| panic!("inputSchema of {} must be an object", name));
            assert_eq!(
                schema.get("type").and_then(|v| v.as_str()),
                Some("object"),
                "inputSchema.type of {} must be \"object\"",
                name
            );
            for key in &banned {
                assert!(
                    !schema.contains_key(*key),
                    "inputSchema of {} has banned top-level keyword {:?}; OpenAI Responses API rejects this",
                    name,
                    key
                );
            }
        }
    }

    #[test]
    fn validates_unexpected_tool_argument_keys() {
        let result = validate_tool_arguments(
            TOOL_REGISTRY_QUERY,
            &serde_json::json!({"project_id": "test", "unexpected": true}),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("unexpected key"));
    }
}
