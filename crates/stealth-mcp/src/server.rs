// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! MCP server: read JSON-RPC frames from stdin, dispatch, write responses to stdout.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

use crate::auth_tools::{
    handle_auth_tool, is_auth_tool, AuthSessionRegistry, AuthToolConfig, AuthToolError,
};
use crate::cli::{resolve_cli_binary, ResolveError};
use crate::protocol::{error_codes, parse_request, JsonRpcRequest, JsonRpcResponse, RpcId};
use crate::recipe_tools::{default_store_dir, handle_recipe_tool, is_recipe_tool, RecipeError};
use crate::tools::{build_cli_argv, tool_definitions, ToolValidation};
use crate::{MCP_PROTOCOL_VERSION, SERVER_NAME, SERVER_VERSION};

#[derive(Debug, Clone, Default)]
pub struct ServerConfig {
    /// Optional override for the CLI binary path. When `None`, the server
    /// uses [`resolve_cli_binary`] on first use.
    pub cli_binary: Option<PathBuf>,
    /// Optional override for the site-recipe store dir. When `None`, the
    /// server uses `~/.rev_scraping/sites/`.
    pub recipe_store_dir: Option<PathBuf>,
    /// Optional override for the Phase 9e auth tool configuration. When
    /// `None`, the server uses [`AuthToolConfig::defaults`]. Set explicitly
    /// in tests to redirect the AuthStore directory.
    pub auth_tool_config: Option<AuthToolConfig>,
}

pub struct Server {
    config: ServerConfig,
    auth_sessions: Arc<AuthSessionRegistry>,
}

impl Server {
    pub fn new(config: ServerConfig) -> Self {
        Self {
            config,
            auth_sessions: Arc::new(AuthSessionRegistry::new()),
        }
    }

    /// Run the server loop on stdio until EOF.
    pub async fn run_stdio(&self) -> anyhow::Result<()> {
        let stdin = tokio::io::stdin();
        let mut stdout = tokio::io::stdout();
        let mut lines = BufReader::new(stdin).lines();

        while let Some(line) = lines.next_line().await? {
            let req = match parse_request(&line) {
                Ok(Some(r)) => r,
                Ok(None) => continue,
                Err(e) => {
                    let resp = JsonRpcResponse::err(
                        None,
                        error_codes::PARSE_ERROR,
                        format!("parse error: {e}"),
                    );
                    write_response(&mut stdout, &resp).await?;
                    continue;
                }
            };

            // Notifications have no id and expect no response.
            let is_notification = req.id.is_none();
            let resp_opt = self.dispatch(req).await;
            if let Some(resp) = resp_opt {
                if !is_notification {
                    write_response(&mut stdout, &resp).await?;
                }
            }
        }
        Ok(())
    }

    /// Dispatch one request. Returns `None` for notifications that should
    /// produce no reply, `Some(resp)` otherwise.
    pub async fn dispatch(&self, req: JsonRpcRequest) -> Option<JsonRpcResponse> {
        let id = req.id.clone();
        match req.method.as_str() {
            "initialize" => Some(JsonRpcResponse::ok(id, initialize_result())),
            "notifications/initialized" | "initialized" => None,
            "tools/list" => Some(JsonRpcResponse::ok(id, tools_list_result())),
            "tools/call" => Some(self.tools_call(id, &req.params).await),
            "ping" => Some(JsonRpcResponse::ok(id, json!({}))),
            _ => Some(JsonRpcResponse::err(
                id,
                error_codes::METHOD_NOT_FOUND,
                format!("method not found: {}", req.method),
            )),
        }
    }

    async fn tools_call(&self, id: Option<RpcId>, params: &Value) -> JsonRpcResponse {
        let name = match params.get("name").and_then(|v| v.as_str()) {
            Some(n) => n,
            None => {
                return JsonRpcResponse::err(
                    id,
                    error_codes::INVALID_PARAMS,
                    "missing required field: name",
                )
            }
        };
        let empty = json!({});
        let args = params.get("arguments").unwrap_or(&empty);

        // In-process auth tools (Phase 9e) — two-phase login + read-only
        // ProfileMeta. Cookie values are NEVER returned by this path.
        if is_auth_tool(name) {
            let cfg = self
                .config
                .auth_tool_config
                .clone()
                .unwrap_or_else(AuthToolConfig::defaults);
            return match handle_auth_tool(name, args, &self.auth_sessions, &cfg) {
                Ok(v) => JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": [{
                            "type": "text",
                            "text": serde_json::to_string(&v).unwrap_or_default()
                        }],
                        "structuredContent": v,
                        "isError": false,
                    }),
                ),
                Err(AuthToolError::MissingField(f)) => JsonRpcResponse::err(
                    id,
                    error_codes::INVALID_PARAMS,
                    format!("missing required argument: {f}"),
                ),
                Err(e) => JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": [{
                            "type": "text",
                            "text": format!("error: {e}")
                        }],
                        "isError": true,
                    }),
                ),
            };
        }

        // In-process recipe tools (Phase 7d) — operate directly on the
        // SiteRecipeStore, no subprocess.
        if is_recipe_tool(name) {
            let dir = self
                .config
                .recipe_store_dir
                .clone()
                .unwrap_or_else(default_store_dir);
            return match handle_recipe_tool(name, args, &dir) {
                Ok(v) => JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": [{
                            "type": "text",
                            "text": serde_json::to_string(&v).unwrap_or_default()
                        }],
                        "structuredContent": v,
                        "isError": false,
                    }),
                ),
                Err(RecipeError::MissingField(f)) => JsonRpcResponse::err(
                    id,
                    error_codes::INVALID_PARAMS,
                    format!("missing required argument: {f}"),
                ),
                Err(e) => JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": [{
                            "type": "text",
                            "text": format!("error: {e}")
                        }],
                        "isError": true,
                    }),
                ),
            };
        }

        let argv = match build_cli_argv(name, args) {
            Ok(v) => v,
            Err(ToolValidation::UnknownTool) => {
                return JsonRpcResponse::err(
                    id,
                    error_codes::METHOD_NOT_FOUND,
                    format!("unknown tool: {name}"),
                )
            }
            Err(ToolValidation::MissingField(f)) => {
                return JsonRpcResponse::err(
                    id,
                    error_codes::INVALID_PARAMS,
                    format!("missing required argument: {f}"),
                )
            }
            Err(ToolValidation::Ok) => unreachable!(),
        };

        let bin = match self.resolve_binary() {
            Ok(b) => b,
            Err(e) => {
                return JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": [{
                            "type": "text",
                            "text": format!("error: {e}")
                        }],
                        "isError": true,
                    }),
                );
            }
        };

        match Command::new(&bin).args(&argv).output().await {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout).to_string();
                let stderr = String::from_utf8_lossy(&out.stderr).to_string();
                let code = out.status.code().unwrap_or(-1);
                let is_error = !out.status.success();
                let text = if stdout.is_empty() && !stderr.is_empty() {
                    stderr.clone()
                } else {
                    stdout.clone()
                };
                let mut content = vec![json!({ "type": "text", "text": text })];
                if !stderr.is_empty() && !stdout.is_empty() {
                    content.push(json!({
                        "type": "text",
                        "text": format!("stderr:\n{stderr}")
                    }));
                }
                JsonRpcResponse::ok(
                    id,
                    json!({
                        "content": content,
                        "isError": is_error,
                        "exitCode": code,
                    }),
                )
            }
            Err(e) => JsonRpcResponse::ok(
                id,
                json!({
                    "content": [{
                        "type": "text",
                        "text": format!("subprocess spawn failed: {e}")
                    }],
                    "isError": true,
                }),
            ),
        }
    }

    fn resolve_binary(&self) -> Result<PathBuf, ResolveError> {
        if let Some(p) = &self.config.cli_binary {
            return Ok(p.clone());
        }
        resolve_cli_binary()
    }
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "capabilities": {
            "tools": { "listChanged": false }
        },
        "serverInfo": {
            "name": SERVER_NAME,
            "version": SERVER_VERSION,
        }
    })
}

fn tools_list_result() -> Value {
    let tools: Vec<Value> = tool_definitions().iter().map(|d| d.to_json()).collect();
    json!({ "tools": tools })
}

async fn write_response<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    resp: &JsonRpcResponse,
) -> std::io::Result<()> {
    let mut s = serde_json::to_string(resp).map_err(std::io::Error::other)?;
    s.push('\n');
    w.write_all(s.as_bytes()).await?;
    w.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::RpcId;

    fn req(method: &str, params: Value, id: i64) -> JsonRpcRequest {
        JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(RpcId::Num(id)),
            method: method.into(),
            params,
        }
    }

    #[tokio::test]
    async fn test_initialize_response_schema() {
        let s = Server::new(ServerConfig::default());
        let r = s.dispatch(req("initialize", json!({}), 1)).await.unwrap();
        let result = r.result.expect("must have result");
        assert_eq!(result["protocolVersion"], MCP_PROTOCOL_VERSION);
        assert_eq!(result["serverInfo"]["name"], SERVER_NAME);
        assert!(result["serverInfo"]["version"].is_string());
        assert!(result["capabilities"]["tools"].is_object());
    }

    #[tokio::test]
    async fn test_tools_list_returns_15_tools_via_dispatch() {
        let s = Server::new(ServerConfig::default());
        let r = s.dispatch(req("tools/list", json!({}), 2)).await.unwrap();
        let result = r.result.expect("result");
        let arr = result["tools"].as_array().expect("tools array");
        assert_eq!(arr.len(), 15);
    }

    #[tokio::test]
    async fn test_tools_call_recipe_list_inprocess() {
        let tmp = tempfile::TempDir::new().unwrap();
        let s = Server::new(ServerConfig {
            cli_binary: None,
            recipe_store_dir: Some(tmp.path().to_path_buf()),
            auth_tool_config: None,
        });
        let r = s
            .dispatch(req(
                "tools/call",
                json!({ "name": "recipe_list", "arguments": {} }),
                42,
            ))
            .await
            .unwrap();
        let result = r.result.expect("result");
        assert_eq!(result["isError"], false);
        assert_eq!(result["structuredContent"]["total"], 0);
    }

    #[tokio::test]
    async fn test_tools_call_recipe_show_missing_domain() {
        let tmp = tempfile::TempDir::new().unwrap();
        let s = Server::new(ServerConfig {
            cli_binary: None,
            recipe_store_dir: Some(tmp.path().to_path_buf()),
            auth_tool_config: None,
        });
        let r = s
            .dispatch(req(
                "tools/call",
                json!({ "name": "recipe_show", "arguments": {} }),
                43,
            ))
            .await
            .unwrap();
        let err = r.error.expect("error");
        assert_eq!(err.code, error_codes::INVALID_PARAMS);
        assert!(err.message.contains("domain"));
    }

    #[tokio::test]
    async fn test_dispatch_unknown_method() {
        let s = Server::new(ServerConfig::default());
        let r = s
            .dispatch(req("does/not/exist", json!({}), 3))
            .await
            .unwrap();
        let err = r.error.expect("error");
        assert_eq!(err.code, error_codes::METHOD_NOT_FOUND);
    }

    #[tokio::test]
    async fn test_tools_call_unknown_tool_returns_error() {
        let s = Server::new(ServerConfig::default());
        let r = s
            .dispatch(req(
                "tools/call",
                json!({ "name": "nope", "arguments": {} }),
                4,
            ))
            .await
            .unwrap();
        let err = r.error.expect("error");
        assert_eq!(err.code, error_codes::METHOD_NOT_FOUND);
    }

    #[tokio::test]
    async fn test_tools_call_invalid_input_validation() {
        let s = Server::new(ServerConfig::default());
        let r = s
            .dispatch(req(
                "tools/call",
                json!({ "name": "spider", "arguments": {} }),
                5,
            ))
            .await
            .unwrap();
        let err = r.error.expect("error");
        assert_eq!(err.code, error_codes::INVALID_PARAMS);
        assert!(err.message.contains("url"));
    }

    #[tokio::test]
    async fn test_initialized_notification_no_response() {
        let s = Server::new(ServerConfig::default());
        let mut r = req("notifications/initialized", json!({}), 0);
        r.id = None;
        assert!(s.dispatch(r).await.is_none());
    }

    #[tokio::test]
    async fn test_tools_call_missing_name() {
        let s = Server::new(ServerConfig::default());
        let r = s
            .dispatch(req("tools/call", json!({ "arguments": {} }), 6))
            .await
            .unwrap();
        let err = r.error.expect("error");
        assert_eq!(err.code, error_codes::INVALID_PARAMS);
    }
}
