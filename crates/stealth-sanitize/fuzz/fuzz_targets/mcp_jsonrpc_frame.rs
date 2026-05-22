// SPDX-License-Identifier: MIT
// Lane K K.5 — MCP JSON-RPC frame parser fuzz target.
//
// Feeds arbitrary UTF-8 bytes through `stealth_mcp::protocol::parse_request`
// (line-delimited JSON-RPC 2.0). The property under test: the parser
// never panics and either returns a well-formed `JsonRpcRequest` or a
// `serde_json::Error`.

#![no_main]

use libfuzzer_sys::fuzz_target;
use stealth_mcp::protocol::parse_request;

fuzz_target!(|data: &[u8]| {
    let Ok(line) = std::str::from_utf8(data) else {
        return;
    };
    // The parser is expected to return Result; either Ok(Some), Ok(None),
    // or Err. None of these must panic on adversarial input.
    let _ = parse_request(line);
});
