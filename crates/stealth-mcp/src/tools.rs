// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! Tool registry and CLI argument translation.
//!
//! Each MCP tool maps 1:1 to a `rev-stealth` subcommand. We accept the tool
//! call arguments, validate the minimum required fields, then translate them
//! into a CLI argv vector. AUP enforcement, allowlist checks, and JSON
//! schema validation of outputs are left to the CLI itself (see
//! ExecPlan §3.4 / S12); this layer is a thin forwarder.
//!
//! P4.1: inputSchemas hardened for OpenAI strict-mode compatibility:
//!   * `$schema` set to JSON Schema draft-07 at every schema root.
//!   * `additionalProperties: false` enforced at every schema root and on
//!     nested object properties (recipe_propose_endpoint.endpoint).
//!   * Every property carries a non-empty `description` so agents can
//!     reason about what/when/why without external docs.
//!   * `examples` are added on the most informative fields per tool so
//!     agents can ground their first invocation.
//!   * `enum` constraints applied where the CLI accepts a closed set
//!     (mobile_preset, vpn_rotate.strategy).
//!
//! P4.2: outputSchemas added for every tool. Source of truth lives in
//! `docs/json-schemas/<tool>.output.json` and is embedded via
//! `include_str!` at build time. We do NOT derive via schemars — the JSON
//! files are authored to match the actual tool response envelopes
//! (stealth-cli `{ok, operation, result}` for spider/relocate/cf-evaluate/
//! vpn-rotate; raw `DoctorReport` for doctor; direct handler payloads for
//! recipe_*/auth_* tools).

use serde_json::{json, Value};

/// A tool definition as advertised over `tools/list`.
#[derive(Debug, Clone)]
pub struct ToolDefinition {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,
    /// JSON Schema (draft-07) describing the tool's response shape.
    /// Authored in `docs/json-schemas/<tool>.output.json` and parsed at
    /// startup. Failing to parse here is a build-time invariant violation.
    pub output_schema: Value,
}

impl ToolDefinition {
    pub fn to_json(&self) -> Value {
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
            "outputSchema": self.output_schema,
        })
    }
}

/// JSON Schema draft-07 identifier used at every tool inputSchema root.
const DRAFT07: &str = "http://json-schema.org/draft-07/schema#";

/// Parse a `docs/json-schemas/*.output.json` embedded via `include_str!`.
/// We panic on malformed JSON because this is a build-time invariant: the
/// schema files ship in-tree and are validated by `cargo test`. A panic at
/// process start is preferable to silently shipping a malformed schema.
fn parse_output_schema(raw: &'static str, tool: &'static str) -> Value {
    serde_json::from_str(raw)
        .unwrap_or_else(|e| panic!("output schema for tool `{tool}` is malformed JSON: {e}"))
}

/// Output schema literals, embedded at compile time so the binary needs no
/// runtime file lookup. The relative path resolves from this source file
/// (`crates/stealth-mcp/src/tools.rs`) up to the workspace `docs/` dir.
const SPIDER_OUTPUT: &str = include_str!("../../../docs/json-schemas/spider.output.json");
const RELOCATE_OUTPUT: &str = include_str!("../../../docs/json-schemas/relocate.output.json");
const CF_EVALUATE_OUTPUT: &str = include_str!("../../../docs/json-schemas/cf_evaluate.output.json");
const DOCTOR_OUTPUT: &str = include_str!("../../../docs/json-schemas/doctor.output.json");
const VPN_ROTATE_OUTPUT: &str = include_str!("../../../docs/json-schemas/vpn_rotate.output.json");
const RECIPE_LIST_OUTPUT: &str = include_str!("../../../docs/json-schemas/recipe_list.output.json");
const RECIPE_SHOW_OUTPUT: &str = include_str!("../../../docs/json-schemas/recipe_show.output.json");
const RECIPE_REMOVE_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/recipe_remove.output.json");
const RECIPE_PROPOSE_ENDPOINT_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/recipe_propose_endpoint.output.json");
const RECIPE_EXPORT_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/recipe_export.output.json");
const RECIPE_IMPORT_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/recipe_import.output.json");
const AUTH_LOGIN_START_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/auth_login_start.output.json");
const AUTH_LOGIN_COMPLETE_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/auth_login_complete.output.json");
const AUTH_LIST_OUTPUT: &str = include_str!("../../../docs/json-schemas/auth_list.output.json");
const AUTH_STATUS_OUTPUT: &str = include_str!("../../../docs/json-schemas/auth_status.output.json");
const SESSION_SHOW_OUTPUT: &str =
    include_str!("../../../docs/json-schemas/session_show.output.json");

/// Returns the full set of MCP tools exposed by this server.
pub fn tool_definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: "spider",
            description:
                "Scrape a URL with stealth (obscura) + optional CF evaluation + adaptive relocate. AUP allowlist required.",
            output_schema: parse_output_schema(SPIDER_OUTPUT, "spider"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["url"],
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Target URL to scrape. Must be on the AUP allowlist; otherwise the CLI rejects the request.",
                        "examples": ["https://example.com", "https://example.com/products/42"]
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Optional UUIDv4 to correlate the spider call with a prior session; autogenerated when omitted.",
                        "examples": ["7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01"]
                    },
                    "mobile_preset": {
                        "type": "string",
                        "description": "Mobile fingerprint preset applied to the stealth (obscura) layer when scraping mobile-flavored UAs.",
                        "enum": ["iphone15pro","iphone15promax","ipadprom4","pixel9pro","pixel8a","galaxys24ultra"],
                        "examples": ["iphone15pro", "pixel9pro"]
                    },
                    "cf_evaluate": {
                        "type": "boolean",
                        "description": "When true, run the Cloudflare Turnstile resilience evaluator alongside the spider.",
                        "default": false,
                        "examples": [false, true]
                    },
                    "vpn": {
                        "type": "boolean",
                        "description": "When true, require an authenticated VPN egress (Surfshark/Gluetun) before the scrape begins.",
                        "default": false,
                        "examples": [false, true]
                    },
                    "stable_id": {
                        "type": "string",
                        "description": "Stable element ID emitted by a prior spider/relocate run. Enables adaptive relocate during this scrape.",
                        "examples": ["sid_8d3a"]
                    },
                    "threshold": {
                        "type": "number",
                        "description": "Similarity threshold in [0.0, 1.0] for adaptive relocate. Default 0.85 matches CLI default.",
                        "default": 0.85,
                        "examples": [0.85, 0.9]
                    },
                    "strict": {
                        "type": "boolean",
                        "description": "When true, fail closed on any non-canonical signal (mismatched UA, leaked DNS, etc.).",
                        "default": false,
                        "examples": [false, true]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "relocate",
            description: "Adaptive relocate a previously recorded element via stealth-parse.",
            output_schema: parse_output_schema(RELOCATE_OUTPUT, "relocate"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["session_id", "stable_id"],
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "UUIDv4 from the spider session that originally emitted the stable_id.",
                        "examples": ["7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01"]
                    },
                    "stable_id": {
                        "type": "string",
                        "description": "Stable element ID to re-locate inside a new HTML document or remote URL.",
                        "examples": ["sid_8d3a"]
                    },
                    "html": {
                        "type": "string",
                        "description": "Raw HTML to search in. Mutually exclusive with `url`; supply exactly one source.",
                        "examples": ["<html><body><div id=\"product\">...</div></body></html>"]
                    },
                    "url": {
                        "type": "string",
                        "description": "URL to fetch and search in. Mutually exclusive with `html`.",
                        "examples": ["https://example.com/products/42"]
                    },
                    "threshold": {
                        "type": "number",
                        "description": "Similarity threshold in [0.0, 1.0] for relocate scoring. Default 0.85.",
                        "default": 0.85,
                        "examples": [0.85, 0.92]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "cf_evaluate",
            description: "Evaluate Cloudflare Turnstile resilience on an authorized target.",
            output_schema: parse_output_schema(CF_EVALUATE_OUTPUT, "cf_evaluate"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["url"],
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Target URL to evaluate. Must be on the AUP allowlist.",
                        "examples": ["https://example.com/login"]
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Optional UUIDv4 to correlate with an existing spider session.",
                        "examples": ["7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "doctor",
            description: "Run leak-guard / vpn / captcha sidecar health diagnostics.",
            output_schema: parse_output_schema(DOCTOR_OUTPUT, "doctor"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "container": {
                        "type": "string",
                        "description": "VPN container name to probe (defaults to `gluetun`).",
                        "default": "gluetun",
                        "examples": ["gluetun"]
                    },
                    "expected_country": {
                        "type": "string",
                        "description": "ISO-3166 alpha-2 country code that the VPN egress should report (e.g. `JP`).",
                        "examples": ["JP", "US"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "recipe_list",
            description: "List all site recipes stored in ~/.rev_scraping/sites/.",
            output_schema: parse_output_schema(RECIPE_LIST_OUTPUT, "recipe_list"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "properties": {}
            }),
        },
        ToolDefinition {
            name: "recipe_show",
            description: "Return the full SiteRecipe JSON for a given domain.",
            output_schema: parse_output_schema(RECIPE_SHOW_OUTPUT, "recipe_show"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["domain"],
                "properties": {
                    "domain": {
                        "type": "string",
                        "description": "Recipe domain key, e.g. `example.com`. Must match an existing recipe file.",
                        "examples": ["example.com"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "recipe_remove",
            description: "Remove a recipe file. Preview unless confirm=true.",
            output_schema: parse_output_schema(RECIPE_REMOVE_OUTPUT, "recipe_remove"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["domain"],
                "properties": {
                    "domain": {
                        "type": "string",
                        "description": "Recipe domain key to remove.",
                        "examples": ["example.com"]
                    },
                    "confirm": {
                        "type": "boolean",
                        "description": "Must be true to actually delete; false (default) only previews.",
                        "default": false,
                        "examples": [false, true]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "recipe_propose_endpoint",
            description: "Append a new endpoint to an existing site recipe. Secret-leak rejected.",
            output_schema: parse_output_schema(
                RECIPE_PROPOSE_ENDPOINT_OUTPUT,
                "recipe_propose_endpoint",
            ),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["domain", "endpoint"],
                "properties": {
                    "domain": {
                        "type": "string",
                        "description": "Recipe domain key the endpoint will be appended to.",
                        "examples": ["example.com"]
                    },
                    "endpoint": {
                        "type": "object",
                        "additionalProperties": false,
                        "description": "Endpoint definition to append. Secret-bearing fields are rejected by the CLI.",
                        "examples": [{
                            "purpose": "search",
                            "path": "/api/v1/search",
                            "http_method": "GET",
                            "url_pattern": "^/api/v1/search"
                        }],
                        "required": ["purpose", "path"],
                        "properties": {
                            "purpose": {
                                "type": "string",
                                "description": "Short human label for the endpoint's role (e.g. `search`, `login`).",
                                "examples": ["search", "product_detail"]
                            },
                            "path": {
                                "type": "string",
                                "description": "URL path or path template relative to the recipe's base origin.",
                                "examples": ["/api/v1/search", "/products/{id}"]
                            },
                            "http_method": {
                                "type": "string",
                                "description": "HTTP method for the endpoint (defaults to GET).",
                                "default": "GET",
                                "examples": ["GET", "POST"]
                            },
                            "url_pattern": {
                                "type": "string",
                                "description": "Optional regex or glob pattern used to recognize matching URLs at runtime.",
                                "examples": ["^/products/\\d+$"]
                            }
                        }
                    }
                }
            }),
        },
        ToolDefinition {
            name: "recipe_export",
            description: "Export all recipes as a base64-encoded JSON array.",
            output_schema: parse_output_schema(RECIPE_EXPORT_OUTPUT, "recipe_export"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "properties": {}
            }),
        },
        ToolDefinition {
            name: "recipe_import",
            description: "Import recipes from a base64-encoded JSON array. Secret-rejected and path-traversal guarded.",
            output_schema: parse_output_schema(RECIPE_IMPORT_OUTPUT, "recipe_import"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["payload"],
                "properties": {
                    "payload": {
                        "type": "string",
                        "description": "Base64-encoded JSON array of SiteRecipe entries. Secret-bearing fields cause rejection.",
                        "examples": ["W3sieyJkb21haW4iOiJleGFtcGxlLmNvbSJ9XQ=="]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "auth_login_start",
            description: "Phase 1 of 2-phase login: AUP-enforce + spawn rev-auth helper. Returns a session_token. Cookie values are never returned.",
            output_schema: parse_output_schema(AUTH_LOGIN_START_OUTPUT, "auth_login_start"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["profile", "url"],
                "properties": {
                    "profile": {
                        "type": "string",
                        "description": "Auth profile name to store cookies under. Reused on subsequent auth_status/spider calls.",
                        "examples": ["example_main", "vendor_portal"]
                    },
                    "url": {
                        "type": "string",
                        "description": "Login start URL. Must be on the AUP allowlist.",
                        "examples": ["https://example.com/login"]
                    },
                    "domain": {
                        "type": "string",
                        "description": "Optional cookie scope domain. Defaults to the URL host when omitted.",
                        "examples": ["example.com"]
                    },
                    "completion_pattern": {
                        "type": "string",
                        "description": "Regex matched against post-login URL or DOM signal to detect login completion.",
                        "examples": ["^https://example\\.com/dashboard"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "auth_login_complete",
            description: "Phase 2 of 2-phase login: poll until rev-auth finishes, then return ProfileMeta. Single-use session_token. Cookie values never returned.",
            output_schema: parse_output_schema(AUTH_LOGIN_COMPLETE_OUTPUT, "auth_login_complete"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["session_token"],
                "properties": {
                    "session_token": {
                        "type": "string",
                        "description": "Single-use session token returned by auth_login_start. Invalidated after one successful complete call.",
                        "examples": ["sess_b2f9b1c0e2"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "auth_list",
            description: "List all stored auth profiles (ProfileMeta only, cookie values never disclosed).",
            output_schema: parse_output_schema(AUTH_LIST_OUTPUT, "auth_list"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "properties": {}
            }),
        },
        ToolDefinition {
            name: "auth_status",
            description: "Return freshness classification for an auth profile (Valid|PartiallyExpired|AllExpired|Missing).",
            output_schema: parse_output_schema(AUTH_STATUS_OUTPUT, "auth_status"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["profile"],
                "properties": {
                    "profile": {
                        "type": "string",
                        "description": "Auth profile name to check freshness for.",
                        "examples": ["example_main"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "session_show",
            description: "Return persisted metadata for a session id (VPN instance binding, started_at, recipe hits, auth profile if any). Cookie values are never disclosed.",
            output_schema: parse_output_schema(SESSION_SHOW_OUTPUT, "session_show"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "required": ["session_id"],
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Session id previously issued by spider/cf_evaluate or persisted via VPN rotation. Must match [A-Za-z0-9_-]{1,128}.",
                        "minLength": 1,
                        "maxLength": 128,
                        "examples": ["7e23b58c-9c2c-44bd-9a4d-7b6b32f04d1e"]
                    }
                }
            }),
        },
        ToolDefinition {
            name: "vpn_rotate",
            description: "Rotate VPN exit (Surfshark via Gluetun).",
            output_schema: parse_output_schema(VPN_ROTATE_OUTPUT, "vpn_rotate"),
            input_schema: json!({
                "$schema": DRAFT07,
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "provider": {
                        "type": "string",
                        "description": "VPN provider key. Currently only `surfshark` is supported by the CLI.",
                        "default": "surfshark",
                        "examples": ["surfshark"]
                    },
                    "strategy": {
                        "type": "string",
                        "description": "Rotation strategy. `lazy-on-fail` rotates only on detection; `every-n` rotates per N requests; `interval` rotates on a time budget.",
                        "enum": ["lazy-on-fail", "every-n", "interval"],
                        "default": "lazy-on-fail",
                        "examples": ["lazy-on-fail", "interval"]
                    },
                    "region": {
                        "type": "string",
                        "description": "Optional target region/country hint for the next exit (e.g. `JP`, `US`).",
                        "examples": ["JP", "US"]
                    },
                    "reason": {
                        "type": "string",
                        "description": "Free-form reason recorded with the rotation event for audit/observability.",
                        "examples": ["cf-challenge", "manual"]
                    }
                }
            }),
        },
    ]
}

/// Validation outcome for `tools/call` arguments.
#[derive(Debug)]
pub enum ToolValidation {
    Ok,
    UnknownTool,
    MissingField(&'static str),
}

/// Validate the tool name + arguments and return the argv vector that
/// should be passed to `rev-stealth`. Returns `Err` if validation fails.
pub fn build_cli_argv(tool: &str, args: &Value) -> Result<Vec<String>, ToolValidation> {
    let obj = args.as_object();
    let get_str = |k: &str| -> Option<String> {
        obj.and_then(|m| m.get(k))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    };
    let get_bool =
        |k: &str| -> Option<bool> { obj.and_then(|m| m.get(k)).and_then(|v| v.as_bool()) };
    let get_num = |k: &str| -> Option<f64> { obj.and_then(|m| m.get(k)).and_then(|v| v.as_f64()) };

    let mut argv: Vec<String> = vec!["--format".into(), "json".into()];

    match tool {
        "spider" => {
            let url = get_str("url").ok_or(ToolValidation::MissingField("url"))?;
            argv.push("spider".into());
            argv.push("--url".into());
            argv.push(url);
            if let Some(s) = get_str("session_id") {
                argv.push("--session-id".into());
                argv.push(s);
            }
            if let Some(s) = get_str("mobile_preset") {
                argv.push("--mobile-preset".into());
                argv.push(s);
            }
            if get_bool("cf_evaluate").unwrap_or(false) {
                argv.push("--cf-evaluate".into());
            }
            if get_bool("vpn").unwrap_or(false) {
                argv.push("--vpn".into());
            }
            if let Some(s) = get_str("stable_id") {
                argv.push("--stable-id".into());
                argv.push(s);
            }
            if let Some(t) = get_num("threshold") {
                argv.push("--threshold".into());
                argv.push(format!("{t}"));
            }
            if get_bool("strict").unwrap_or(false) {
                argv.push("--strict".into());
            }
        }
        "relocate" => {
            let session_id =
                get_str("session_id").ok_or(ToolValidation::MissingField("session_id"))?;
            let stable_id =
                get_str("stable_id").ok_or(ToolValidation::MissingField("stable_id"))?;
            argv.push("relocate".into());
            argv.push("--session-id".into());
            argv.push(session_id);
            argv.push("--stable-id".into());
            argv.push(stable_id);
            if let Some(s) = get_str("html") {
                argv.push("--html".into());
                argv.push(s);
            }
            if let Some(s) = get_str("url") {
                argv.push("--url".into());
                argv.push(s);
            }
            if let Some(t) = get_num("threshold") {
                argv.push("--threshold".into());
                argv.push(format!("{t}"));
            }
        }
        "cf_evaluate" => {
            let url = get_str("url").ok_or(ToolValidation::MissingField("url"))?;
            argv.push("cf-evaluate".into());
            argv.push("--url".into());
            argv.push(url);
            if let Some(s) = get_str("session_id") {
                argv.push("--session-id".into());
                argv.push(s);
            }
        }
        "doctor" => {
            argv.push("doctor".into());
            if let Some(s) = get_str("container") {
                argv.push("--container".into());
                argv.push(s);
            }
            if let Some(s) = get_str("expected_country") {
                argv.push("--expected-country".into());
                argv.push(s);
            }
            // Doctor uses --output-format instead of --format due to legacy
            // arg-name collision (see stealth-cli main.rs cli_tests).
            // We already pushed `--format json`; doctor honors it globally.
        }
        "vpn_rotate" => {
            argv.push("vpn".into());
            argv.push("rotate".into());
            if let Some(s) = get_str("provider") {
                argv.push("--provider".into());
                argv.push(s);
            }
            if let Some(s) = get_str("strategy") {
                argv.push("--strategy".into());
                argv.push(s);
            }
            if let Some(s) = get_str("region") {
                argv.push("--region".into());
                argv.push(s);
            }
            if let Some(s) = get_str("reason") {
                argv.push("--reason".into());
                argv.push(s);
            }
        }
        _ => return Err(ToolValidation::UnknownTool),
    }

    Ok(argv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tools_list_returns_16_tools() {
        // P9.1: bumped from 15 → 16 with the addition of `session_show`.
        let defs = tool_definitions();
        assert_eq!(defs.len(), 16);
        let names: Vec<&str> = defs.iter().map(|d| d.name).collect();
        assert!(names.contains(&"spider"));
        assert!(names.contains(&"relocate"));
        assert!(names.contains(&"cf_evaluate"));
        assert!(names.contains(&"doctor"));
        assert!(names.contains(&"vpn_rotate"));
        assert!(names.contains(&"recipe_list"));
        assert!(names.contains(&"recipe_show"));
        assert!(names.contains(&"recipe_remove"));
        assert!(names.contains(&"recipe_propose_endpoint"));
        assert!(names.contains(&"recipe_export"));
        assert!(names.contains(&"recipe_import"));
        assert!(names.contains(&"auth_login_start"));
        assert!(names.contains(&"auth_login_complete"));
        assert!(names.contains(&"auth_list"));
        assert!(names.contains(&"auth_status"));
        assert!(names.contains(&"session_show"));
    }

    #[test]
    fn mcp_tool_count_now_16() {
        // P9.1 explicit pin (per slice spec): the tool count surfaces as
        // exactly 16. Bumping this requires updating tools_list.json baseline
        // and the matching server-dispatch assertion below in lock-step.
        assert_eq!(tool_definitions().len(), 16);
    }

    #[test]
    fn test_tool_schemas_are_objects_with_type_object() {
        for d in tool_definitions() {
            let t = d.input_schema.get("type").and_then(|v| v.as_str());
            assert_eq!(
                t,
                Some("object"),
                "tool {} schema.type must be object",
                d.name
            );
        }
    }

    #[test]
    fn test_tools_call_unknown_tool_returns_error() {
        let res = build_cli_argv("nonexistent", &json!({}));
        assert!(matches!(res, Err(ToolValidation::UnknownTool)));
    }

    #[test]
    fn test_tools_call_invalid_input_validation_spider() {
        // spider requires url
        let res = build_cli_argv("spider", &json!({}));
        assert!(matches!(res, Err(ToolValidation::MissingField("url"))));
    }

    #[test]
    fn test_tools_call_invalid_input_validation_relocate() {
        let res = build_cli_argv("relocate", &json!({ "session_id": "s" }));
        assert!(matches!(
            res,
            Err(ToolValidation::MissingField("stable_id"))
        ));
    }

    #[test]
    fn test_build_argv_spider_full() {
        let argv = build_cli_argv(
            "spider",
            &json!({
                "url": "https://example.com",
                "session_id": "abc",
                "cf_evaluate": true,
                "strict": true,
                "threshold": 0.9
            }),
        )
        .unwrap();
        assert_eq!(&argv[0..2], &["--format", "json"]);
        assert!(argv.contains(&"spider".to_string()));
        assert!(argv.contains(&"--cf-evaluate".to_string()));
        assert!(argv.contains(&"--strict".to_string()));
        assert!(argv.contains(&"https://example.com".to_string()));
    }

    // ---------------------------------------------------------------
    // P4.1: OpenAI strict-mode / draft-07 inputSchema hardening checks.
    // ---------------------------------------------------------------

    #[test]
    fn all_16_tools_have_additional_properties_false() {
        let defs = tool_definitions();
        assert_eq!(defs.len(), 16);
        for d in &defs {
            let ap = d.input_schema.get("additionalProperties");
            assert_eq!(
                ap,
                Some(&Value::Bool(false)),
                "tool {} must declare additionalProperties:false at schema root",
                d.name
            );
        }
    }

    #[test]
    fn all_input_schemas_have_dollar_schema_draft07() {
        for d in tool_definitions() {
            let s = d
                .input_schema
                .get("$schema")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("tool {} missing $schema", d.name));
            assert_eq!(
                s, "http://json-schema.org/draft-07/schema#",
                "tool {} $schema must be draft-07",
                d.name
            );
        }
    }

    #[test]
    fn spider_field_descriptions_present_for_all_properties() {
        let defs = tool_definitions();
        let spider = defs
            .iter()
            .find(|d| d.name == "spider")
            .expect("spider tool");
        let props = spider
            .input_schema
            .get("properties")
            .and_then(|v| v.as_object())
            .expect("spider.properties is object");
        assert!(!props.is_empty(), "spider must have at least one property");
        for (field, schema) in props.iter() {
            let desc = schema
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("spider.{field} missing description"));
            assert!(
                !desc.trim().is_empty(),
                "spider.{field} description must be non-empty"
            );
        }
    }

    #[test]
    fn auth_login_start_examples_present() {
        let defs = tool_definitions();
        let tool = defs
            .iter()
            .find(|d| d.name == "auth_login_start")
            .expect("auth_login_start tool");
        let props = tool
            .input_schema
            .get("properties")
            .and_then(|v| v.as_object())
            .expect("auth_login_start.properties is object");

        // The two required fields must carry examples so an agent's first call
        // is grounded; together they cover ≥ 2 of the 3-5 example fields P4.1
        // expects per tool.
        for field in ["profile", "url"] {
            let examples = props
                .get(field)
                .and_then(|s| s.get("examples"))
                .and_then(|e| e.as_array())
                .unwrap_or_else(|| panic!("auth_login_start.{field} must have examples array"));
            assert!(
                !examples.is_empty(),
                "auth_login_start.{field} examples must be non-empty"
            );
        }
    }

    #[test]
    fn enum_constraints_applied_on_known_closed_sets() {
        let defs = tool_definitions();

        // spider.mobile_preset must be an enum of 6 known device presets.
        let spider = defs.iter().find(|d| d.name == "spider").unwrap();
        let mp = spider
            .input_schema
            .pointer("/properties/mobile_preset/enum")
            .and_then(|v| v.as_array())
            .expect("spider.mobile_preset.enum must exist");
        assert_eq!(mp.len(), 6, "spider.mobile_preset enum must list 6 presets");

        // vpn_rotate.strategy must be a 3-value enum.
        let vpn = defs.iter().find(|d| d.name == "vpn_rotate").unwrap();
        let strat = vpn
            .input_schema
            .pointer("/properties/strategy/enum")
            .and_then(|v| v.as_array())
            .expect("vpn_rotate.strategy.enum must exist");
        assert_eq!(
            strat.len(),
            3,
            "vpn_rotate.strategy enum must list 3 values"
        );
    }

    #[test]
    fn every_property_of_every_tool_has_examples() {
        // P4.1 agent-grounding bar: every property on every tool must carry a
        // non-empty `examples` array so the first invocation is grounded
        // without forcing the agent to read external docs.
        for d in tool_definitions() {
            let props = d
                .input_schema
                .get("properties")
                .and_then(|v| v.as_object())
                .unwrap_or_else(|| panic!("tool {} missing properties object", d.name));
            for (field, schema) in props.iter() {
                // Every property must carry a non-empty `examples` array,
                // including object-valued wrapper properties such as
                // recipe_propose_endpoint.endpoint. Object-valued properties
                // additionally have their inner fields checked recursively.
                let ex = schema
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .unwrap_or_else(|| panic!("{}.{field} missing examples array", d.name));
                assert!(
                    !ex.is_empty(),
                    "{}.{field} examples must be non-empty",
                    d.name
                );
                if schema.get("type").and_then(|v| v.as_str()) == Some("object") {
                    let inner = schema
                        .get("properties")
                        .and_then(|v| v.as_object())
                        .unwrap_or_else(|| panic!("{}.{field} object missing properties", d.name));
                    for (inner_field, inner_schema) in inner.iter() {
                        let iex = inner_schema
                            .get("examples")
                            .and_then(|v| v.as_array())
                            .unwrap_or_else(|| {
                                panic!("{}.{field}.{inner_field} missing examples", d.name)
                            });
                        assert!(
                            !iex.is_empty(),
                            "{}.{field}.{inner_field} examples must be non-empty",
                            d.name
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn nested_endpoint_object_also_enforces_strict_mode() {
        // recipe_propose_endpoint has a nested `endpoint` object; OpenAI
        // strict-mode requires additionalProperties:false on nested schemas too.
        let defs = tool_definitions();
        let tool = defs
            .iter()
            .find(|d| d.name == "recipe_propose_endpoint")
            .unwrap();
        let endpoint_ap = tool
            .input_schema
            .pointer("/properties/endpoint/additionalProperties");
        assert_eq!(
            endpoint_ap,
            Some(&Value::Bool(false)),
            "recipe_propose_endpoint.endpoint must declare additionalProperties:false"
        );
    }

    // ---------------------------------------------------------------
    // P4.2: outputSchema invariants (per-tool + draft-07 + strict-mode).
    // ---------------------------------------------------------------

    #[test]
    fn all_16_tools_have_output_schema() {
        // Every tool must expose a non-null, object-typed outputSchema, and
        // tools/list must echo it via to_json() under the `outputSchema` key.
        let defs = tool_definitions();
        assert_eq!(defs.len(), 16);
        for d in &defs {
            assert!(
                d.output_schema.is_object(),
                "tool {} output_schema must be a JSON object",
                d.name
            );
            let t = d.output_schema.get("type").and_then(|v| v.as_str());
            assert_eq!(
                t,
                Some("object"),
                "tool {} output_schema.type must be `object`",
                d.name
            );
            let json = d.to_json();
            let advertised = json
                .get("outputSchema")
                .expect("tools/list must echo outputSchema");
            assert!(
                advertised.is_object() && !advertised.as_object().unwrap().is_empty(),
                "tools/list outputSchema for {} must be a non-empty object",
                d.name
            );
        }
    }

    #[test]
    fn all_output_schemas_are_draft07() {
        for d in tool_definitions() {
            let s = d
                .output_schema
                .get("$schema")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("tool {} output_schema missing $schema", d.name));
            assert_eq!(
                s, "http://json-schema.org/draft-07/schema#",
                "tool {} output_schema $schema must be draft-07",
                d.name
            );
        }
    }

    #[test]
    fn all_output_schemas_have_additional_properties_false() {
        for d in tool_definitions() {
            let ap = d.output_schema.get("additionalProperties");
            assert_eq!(
                ap,
                Some(&Value::Bool(false)),
                "tool {} output_schema must declare additionalProperties:false at root",
                d.name
            );
        }
    }

    #[test]
    fn spider_output_schema_documents_recipe_result_shape() {
        // spider's outputSchema describes a two-variant envelope via `oneOf`:
        //   success: {ok:true, operation, result}
        //   failure: {ok:false, operation, exit_code, error}
        // The schema must document `result` as a top-level property, and the
        // `result` block must enumerate the major payload surfaces (session_id
        // / recipe / api_response / cf / vpn_monitor) an agent has to handle.
        let defs = tool_definitions();
        let spider = defs
            .iter()
            .find(|d| d.name == "spider")
            .expect("spider tool");

        for k in ["ok", "operation", "result", "exit_code", "error"] {
            assert!(
                spider
                    .output_schema
                    .pointer(&format!("/properties/{k}"))
                    .is_some(),
                "spider outputSchema must document `{k}`"
            );
        }

        // Root `required` must pin ok+operation (always present in both
        // variants). `result`, `exit_code`, `error` are required per-variant
        // via `oneOf`.
        let required = spider
            .output_schema
            .get("required")
            .and_then(|v| v.as_array())
            .expect("spider outputSchema must declare required");
        let names: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        for k in ["ok", "operation"] {
            assert!(
                names.contains(&k),
                "spider outputSchema root required must include `{k}`"
            );
        }

        // Confirm the success/failure split via `oneOf`.
        let one_of = spider
            .output_schema
            .get("oneOf")
            .and_then(|v| v.as_array())
            .expect("spider outputSchema must declare oneOf (success|failure)");
        assert_eq!(
            one_of.len(),
            2,
            "spider outputSchema oneOf must have 2 variants"
        );

        let result_props = spider
            .output_schema
            .pointer("/properties/result/properties")
            .and_then(|v| v.as_object())
            .expect("spider outputSchema.result.properties must be an object");
        for k in ["session_id", "recipe", "api_response", "cf", "vpn_monitor"] {
            assert!(
                result_props.contains_key(k),
                "spider outputSchema.result must document `{k}`"
            );
        }
    }

    #[test]
    fn output_schemas_examples_present() {
        // Agent-grounding bar: every top-level property of every output
        // schema must declare a non-empty `examples` array, so an agent
        // knows what the response actually looks like before invoking the
        // tool. Nested object properties are not required to have examples
        // (they are intentionally permissive on inner shape).
        for d in tool_definitions() {
            let props = d
                .output_schema
                .get("properties")
                .and_then(|v| v.as_object())
                .unwrap_or_else(|| panic!("tool {} output_schema must declare properties", d.name));
            assert!(
                !props.is_empty(),
                "tool {} output_schema properties must be non-empty",
                d.name
            );
            let mut with_examples = 0usize;
            for (_, schema) in props.iter() {
                if schema
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .map(|a| !a.is_empty())
                    .unwrap_or(false)
                {
                    with_examples += 1;
                }
            }
            assert!(
                with_examples >= 1,
                "tool {} output_schema must declare examples on at least one top-level property",
                d.name
            );
        }
    }
}
