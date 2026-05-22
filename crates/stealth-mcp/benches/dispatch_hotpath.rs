// SPDX-License-Identifier: MIT
//
// Lane K K.7 — criterion microbench for stealth-mcp dispatch hot path.
//
// Measures `Server::dispatch` for in-process methods that DO NOT shell
// out to the CLI binary or touch the filesystem in a meaningful way:
//   - tools/list  : returns the static tool catalogue
//   - ping        : returns an empty object
//   - initialize  : returns the server capability set
//
// External-side-effect tools (tools/call against any tool that runs the
// rev-stealth CLI or hits the network) are intentionally excluded from
// the microbench so the number reflects dispatch overhead, not subprocess
// cost.
//
// Run locally:
//   cargo bench -p stealth-mcp --bench dispatch_hotpath

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use serde_json::Value;
use stealth_mcp::{JsonRpcRequest, RpcId, Server, ServerConfig};
use tokio::runtime::Runtime;

fn rt() -> Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
}

fn req(method: &str, id: i64) -> JsonRpcRequest {
    JsonRpcRequest {
        jsonrpc: "2.0".to_string(),
        id: Some(RpcId::Num(id)),
        method: method.to_string(),
        params: Value::Null,
    }
}

fn bench_dispatch(c: &mut Criterion) {
    let rt = rt();
    let server = Server::new(ServerConfig::default());

    let mut group = c.benchmark_group("mcp_dispatch");

    group.bench_function("ping", |b| {
        b.iter(|| {
            let resp = rt.block_on(server.dispatch(black_box(req("ping", 1))));
            black_box(resp);
        });
    });

    group.bench_function("initialize", |b| {
        b.iter(|| {
            let resp = rt.block_on(server.dispatch(black_box(req("initialize", 2))));
            black_box(resp);
        });
    });

    group.bench_function("tools_list", |b| {
        b.iter(|| {
            let resp = rt.block_on(server.dispatch(black_box(req("tools/list", 3))));
            black_box(resp);
        });
    });

    group.finish();
}

criterion_group!(benches, bench_dispatch);
criterion_main!(benches);
