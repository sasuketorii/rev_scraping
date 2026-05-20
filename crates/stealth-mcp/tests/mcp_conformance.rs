// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 3 MCP server)
//
//! MCP stdio conformance integration test.
//!
//! Spawns the `stealth-mcp` binary as a subprocess, pumps JSON-RPC frames
//! over stdio, and validates the response schemas for `initialize`,
//! `tools/list`, and a malformed `tools/call`.
//!
//! Marked `#[ignore]` because it requires `cargo build -p stealth-mcp`
//! to have produced the binary; CI invokes with `cargo test -- --ignored`.

use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::Value;

fn locate_binary() -> std::path::PathBuf {
    // CARGO_BIN_EXE_<name> is set by cargo when running integration tests.
    let p = env!("CARGO_BIN_EXE_stealth-mcp");
    std::path::PathBuf::from(p)
}

#[test]
#[ignore]
fn mcp_stdio_conformance() {
    let bin = locate_binary();
    let mut child = Command::new(&bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("RUST_LOG", "warn")
        .spawn()
        .expect("spawn stealth-mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");

    // Send three frames.
    let frames = [
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spider","arguments":{}}}"#,
    ];
    for f in frames {
        writeln!(stdin, "{}", f).unwrap();
    }
    stdin.flush().unwrap();
    drop(stdin); // EOF

    // Read responses with a wall-clock guard.
    let reader = std::io::BufRead::lines(std::io::BufReader::new(stdout));
    let start = std::time::Instant::now();
    let mut responses: Vec<Value> = Vec::new();
    for line in reader {
        let line = line.expect("read line");
        let v: Value = serde_json::from_str(&line).expect("valid json frame");
        responses.push(v);
        if responses.len() == 3 || start.elapsed() > Duration::from_secs(10) {
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();

    assert_eq!(
        responses.len(),
        3,
        "expected 3 responses, got {responses:?}"
    );

    // initialize.
    assert_eq!(responses[0]["id"], 1);
    assert_eq!(
        responses[0]["result"]["protocolVersion"],
        stealth_mcp::MCP_PROTOCOL_VERSION
    );
    assert_eq!(responses[0]["result"]["serverInfo"]["name"], "stealth-mcp");

    // tools/list.
    assert_eq!(responses[1]["id"], 2);
    let tools = responses[1]["result"]["tools"]
        .as_array()
        .expect("tools array");
    assert_eq!(tools.len(), 5);

    // tools/call with missing required arg → JSON-RPC error -32602.
    assert_eq!(responses[2]["id"], 3);
    assert_eq!(responses[2]["error"]["code"], -32602);
}
