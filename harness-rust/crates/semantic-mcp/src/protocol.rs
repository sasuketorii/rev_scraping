//! MCP JSON-RPC 2.0 protocol over stdio.
//!
//! Reads newline-delimited JSON from stdin, dispatches to tool handlers,
//! and writes JSON responses to stdout.  All logging goes to stderr.

use std::io::{self, BufRead, Write};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::context::ServerContext;
use crate::tools;

/// Server name reported in `initialize` response.
const SERVER_NAME: &str = "semantic-mcp-server";
/// Server version reported in `initialize` response.
const SERVER_VERSION: &str = "0.1.0";

// ---------------------------------------------------------------------------
// JSON-RPC types
// ---------------------------------------------------------------------------

/// JSON-RPC 2.0 request (incoming).
#[derive(Debug, Deserialize)]
pub struct JsonRpcRequest {
    /// Must be "2.0".
    #[allow(dead_code)]
    pub jsonrpc: String,
    /// Request identifier (may be null for notifications).
    pub id: Option<Value>,
    /// Method name.
    pub method: String,
    /// Optional parameters.
    pub params: Option<Value>,
}

/// JSON-RPC 2.0 response (outgoing).
#[derive(Debug, Serialize)]
pub struct JsonRpcResponse {
    /// Always "2.0".
    pub jsonrpc: String,
    /// Echo of the request id.
    pub id: Option<Value>,
    /// Result payload (mutually exclusive with `error`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Error payload (mutually exclusive with `result`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

/// JSON-RPC 2.0 error object.
#[derive(Debug, Serialize)]
pub struct JsonRpcError {
    /// Numeric error code.
    pub code: i64,
    /// Human-readable error message.
    pub message: String,
    /// Optional structured data.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

// ---------------------------------------------------------------------------
// Standard error codes
// ---------------------------------------------------------------------------

const METHOD_NOT_FOUND: i64 = -32601;
#[allow(dead_code)]
const INTERNAL_ERROR: i64 = -32603;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Run the MCP server loop reading from stdin, writing to stdout.
///
/// This function blocks until stdin is closed or a fatal error occurs.
/// It never returns `Err` for recoverable per-request errors; those
/// are sent back as JSON-RPC error responses.
pub fn run_stdio_server(ctx: &ServerContext) -> Result<(), String> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let reader = stdin.lock();
    let mut writer = stdout.lock();

    for line_result in reader.lines() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let request: JsonRpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("invalid JSON-RPC request: {e}");
                let resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id: None,
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("parse error: {e}"),
                        data: None,
                    }),
                };
                write_response(&mut writer, &resp)?;
                continue;
            }
        };

        // Notifications (no id) do not get a response.
        if request.id.is_none() {
            tracing::debug!("notification: {}", request.method);
            continue;
        }

        let response = dispatch(ctx, &request);
        write_response(&mut writer, &response)?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn dispatch(ctx: &ServerContext, req: &JsonRpcRequest) -> JsonRpcResponse {
    match req.method.as_str() {
        "initialize" => handle_initialize(req),
        "tools/list" => handle_tools_list(req),
        "tools/call" => handle_tools_call(ctx, req),
        "notifications/initialized" => {
            // Acknowledged silently; if it had an id, respond with empty result.
            JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id: req.id.clone(),
                result: Some(Value::Object(serde_json::Map::new())),
                error: None,
            }
        }
        _ => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: req.id.clone(),
            result: None,
            error: Some(JsonRpcError {
                code: METHOD_NOT_FOUND,
                message: format!("method not found: {}", req.method),
                data: None,
            }),
        },
    }
}

// ---------------------------------------------------------------------------
// Method handlers
// ---------------------------------------------------------------------------

fn handle_initialize(req: &JsonRpcRequest) -> JsonRpcResponse {
    let result = serde_json::json!({
        "protocolVersion": "2024-11-05",
        "capabilities": {
            "tools": {}
        },
        "serverInfo": {
            "name": SERVER_NAME,
            "version": SERVER_VERSION
        }
    });

    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id: req.id.clone(),
        result: Some(result),
        error: None,
    }
}

fn handle_tools_list(req: &JsonRpcRequest) -> JsonRpcResponse {
    let tools = tools::tool_definitions();
    let result = serde_json::json!({ "tools": tools });

    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id: req.id.clone(),
        result: Some(result),
        error: None,
    }
}

fn handle_tools_call(ctx: &ServerContext, req: &JsonRpcRequest) -> JsonRpcResponse {
    let params = req.params.as_ref().and_then(|p| p.as_object());
    let tool_name = params
        .and_then(|p| p.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let arguments = params
        .and_then(|p| p.get("arguments"))
        .cloned()
        .unwrap_or(Value::Object(serde_json::Map::new()));

    match tools::call_tool(ctx, tool_name, &arguments) {
        Ok(payload) => {
            let content = serde_json::json!({
                "content": [{
                    "type": "text",
                    "text": serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string())
                }]
            });
            JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id: req.id.clone(),
                result: Some(content),
                error: None,
            }
        }
        Err(e) => {
            tracing::error!("tool error: {e}");
            let content = serde_json::json!({
                "isError": true,
                "content": [{
                    "type": "text",
                    "text": e
                }]
            });
            JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id: req.id.clone(),
                result: Some(content),
                error: None,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

fn write_response(writer: &mut impl Write, resp: &JsonRpcResponse) -> Result<(), String> {
    let json =
        serde_json::to_string(resp).map_err(|e| format!("failed to serialize response: {e}"))?;
    writeln!(writer, "{json}").map_err(|e| format!("stdout write error: {e}"))?;
    writer
        .flush()
        .map_err(|e| format!("stdout flush error: {e}"))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    type TestContext = crate::context::ServerContext;

    fn test_ctx() -> TestContext {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
        crate::context::ServerContext::new(
            conn,
            "test".to_string(),
            std::env::current_dir().unwrap(),
        )
    }

    #[test]
    fn test_parse_valid_jsonrpc_request() {
        let json = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
        let req: JsonRpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "initialize");
        assert_eq!(req.id, Some(Value::from(1)));
        assert_eq!(req.jsonrpc, "2.0");
    }

    #[test]
    fn test_parse_request_with_string_id() {
        let json = r#"{"jsonrpc":"2.0","id":"abc-123","method":"tools/list"}"#;
        let req: JsonRpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "tools/list");
        assert_eq!(req.id, Some(Value::String("abc-123".into())));
    }

    #[test]
    fn test_parse_notification_no_id() {
        let json = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        let req: JsonRpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "notifications/initialized");
        assert!(req.id.is_none());
    }

    #[test]
    fn test_parse_invalid_json_fails() {
        let json = r#"{"not valid json"#;
        let result = serde_json::from_str::<JsonRpcRequest>(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_missing_method_fails() {
        let json = r#"{"jsonrpc":"2.0","id":1}"#;
        let result = serde_json::from_str::<JsonRpcRequest>(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_success_response_serialization() {
        let resp = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(42)),
            result: Some(serde_json::json!({"status": "ok"})),
            error: None,
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["jsonrpc"], "2.0");
        assert_eq!(parsed["id"], 42);
        assert_eq!(parsed["result"]["status"], "ok");
        // error should be absent (skip_serializing_if)
        assert!(parsed.get("error").is_none());
    }

    #[test]
    fn test_error_response_serialization() {
        let resp = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            result: None,
            error: Some(JsonRpcError {
                code: -32601,
                message: "method not found".to_string(),
                data: None,
            }),
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["error"]["code"], -32601);
        assert_eq!(parsed["error"]["message"], "method not found");
        assert!(parsed.get("result").is_none());
    }

    #[test]
    fn test_dispatch_initialize() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "initialize".to_string(),
            params: None,
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["serverInfo"]["name"], "semantic-mcp-server");
        assert_eq!(result["protocolVersion"], "2024-11-05");
    }

    #[test]
    fn test_dispatch_unknown_method() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "nonexistent".to_string(),
            params: None,
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, -32601);
    }

    #[test]
    fn test_dispatch_tools_list() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "tools/list".to_string(),
            params: None,
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 10);
    }

    #[test]
    fn test_dispatch_tools_call_health() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "sem.health",
                "arguments": {}
            })),
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        let content = result["content"].as_array().unwrap();
        assert!(!content.is_empty());
    }

    #[test]
    fn protocol_rejects_non_object_tool_arguments() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "sem.registry.query",
                "arguments": []
            })),
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["isError"], true);
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("arguments must be an object"));
    }

    #[test]
    fn protocol_rejects_unexpected_tool_argument_keys() {
        let ctx = test_ctx();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "sem.registry.query",
                "arguments": {
                    "project_id": "test",
                    "unexpected": true
                }
            })),
        };
        let resp = dispatch(&ctx, &req);
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["isError"], true);
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("unexpected key"));
    }

    #[test]
    fn test_write_response_outputs_json_line() {
        let resp = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            result: Some(Value::Null),
            error: None,
        };
        let mut buf: Vec<u8> = Vec::new();
        write_response(&mut buf, &resp).unwrap();
        let output = String::from_utf8(buf).unwrap();
        assert!(output.ends_with('\n'));
        let parsed: Value = serde_json::from_str(output.trim()).unwrap();
        assert_eq!(parsed["jsonrpc"], "2.0");
    }
}
