// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! `stealth-mcp` — Minimal MCP (Model Context Protocol) server over stdio for
//! `rev_scraping`. Exposes the `stealth-cli` (`rev-stealth`) operations as
//! MCP tools that AI agents (codex / Claude Code) can invoke.
//!
//! Transport: line-delimited JSON-RPC 2.0 over stdin/stdout (DECISION #4).
//!
//! Why a hand-rolled JSON-RPC layer? The workspace pins `rmcp = "0.1"` but
//! the published crate has since diverged to 1.x with breaking API changes.
//! Per the ExecPlan §3.4 note ("subprocess は最終手段だが Phase 3 では許容"),
//! we keep this layer ~150 LoC and depend only on `serde_json` + `tokio`.

#![forbid(unsafe_code)]

pub mod auth_tools;
pub mod cli;
pub mod protocol;
pub mod recipe_tools;
pub mod server;
pub mod tools;

pub use protocol::{JsonRpcError, JsonRpcRequest, JsonRpcResponse, RpcId};
pub use server::{Server, ServerConfig};
pub use tools::{tool_definitions, ToolDefinition};

/// MCP protocol version advertised by this server.
///
/// Pinned to the 2024-11-05 schema which is what `rmcp` 0.1 and the Claude
/// Code / codex MCP clients implement as of Phase 3 (2026-05).
pub const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// Logical server name reported in `initialize` responses.
pub const SERVER_NAME: &str = "stealth-mcp";

/// Server version (mirrors workspace package version).
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
