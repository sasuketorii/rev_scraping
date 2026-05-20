// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! `stealth-mcp` binary entrypoint.
//!
//! Wires up the line-delimited JSON-RPC 2.0 stdio loop. Logs go to stderr
//! (stdout is reserved for protocol frames).

#![forbid(unsafe_code)]

use stealth_mcp::{Server, ServerConfig};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    tracing::info!(
        protocol = stealth_mcp::MCP_PROTOCOL_VERSION,
        server = stealth_mcp::SERVER_NAME,
        version = stealth_mcp::SERVER_VERSION,
        "stealth-mcp starting on stdio"
    );
    let server = Server::new(ServerConfig::default());
    server.run_stdio().await
}

fn init_tracing() {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .try_init();
}
