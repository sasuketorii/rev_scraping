// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! JSON-RPC 2.0 wire types used by the MCP server.
//!
//! The MCP transport is line-delimited JSON-RPC 2.0 (one object per line on
//! stdin/stdout). We model only the subset we need: `initialize`,
//! `tools/list`, `tools/call`, plus the `notifications/initialized`
//! notification (no response expected).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// JSON-RPC id: either a string or a number. `null` is allowed by the spec
/// but treated as "notification" here.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum RpcId {
    Num(i64),
    Str(String),
}

#[derive(Debug, Clone, Deserialize)]
pub struct JsonRpcRequest {
    #[serde(default = "default_jsonrpc")]
    pub jsonrpc: String,
    pub id: Option<RpcId>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

fn default_jsonrpc() -> String {
    "2.0".to_string()
}

#[derive(Debug, Clone, Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: &'static str,
    pub id: Option<RpcId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Clone, Serialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl JsonRpcResponse {
    pub fn ok(id: Option<RpcId>, result: Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: Option<RpcId>, code: i32, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data: None,
            }),
        }
    }
}

/// Standard JSON-RPC error codes (RFC + MCP extensions).
pub mod error_codes {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
}

/// Parse a single line of input into a request. Returns `None` for blank
/// lines (which are tolerated as keepalives).
pub fn parse_request(line: &str) -> Result<Option<JsonRpcRequest>, serde_json::Error> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_str(trimmed)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_jsonrpc_request_parse() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#;
        let req = parse_request(line).unwrap().unwrap();
        assert_eq!(req.method, "tools/list");
        assert_eq!(req.id, Some(RpcId::Num(1)));
    }

    #[test]
    fn test_jsonrpc_request_parse_string_id() {
        let line = r#"{"jsonrpc":"2.0","id":"abc","method":"initialize"}"#;
        let req = parse_request(line).unwrap().unwrap();
        assert_eq!(req.id, Some(RpcId::Str("abc".into())));
    }

    #[test]
    fn test_jsonrpc_request_parse_blank_is_none() {
        assert!(parse_request("   ").unwrap().is_none());
    }

    #[test]
    fn test_jsonrpc_response_serialization_ok() {
        let resp = JsonRpcResponse::ok(Some(RpcId::Num(7)), json!({"k":"v"}));
        let s = serde_json::to_string(&resp).unwrap();
        assert!(s.contains("\"jsonrpc\":\"2.0\""));
        assert!(s.contains("\"id\":7"));
        assert!(s.contains("\"result\":{\"k\":\"v\"}"));
        assert!(!s.contains("\"error\""));
    }

    #[test]
    fn test_jsonrpc_response_serialization_err() {
        let resp = JsonRpcResponse::err(
            Some(RpcId::Str("x".into())),
            error_codes::METHOD_NOT_FOUND,
            "no such method",
        );
        let s = serde_json::to_string(&resp).unwrap();
        assert!(s.contains("\"error\""));
        assert!(s.contains("-32601"));
        assert!(!s.contains("\"result\""));
    }
}
