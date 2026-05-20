use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

use criterion::{criterion_group, criterion_main, Criterion};
use rusqlite::Connection;
use semantic_mcp::{db, registry, search, ServerContext};
use serde_json::json;
use tempfile::TempDir;

const PROJECT_ID: &str = "bench-search";
const ITERATIONS: usize = 100;
const COMPONENTS: usize = 1_000;

struct SearchFixture {
    ctx: ServerContext,
    _repo: TempDir,
}

#[derive(Debug, Clone)]
struct Stats {
    p50_ns: u128,
    p95_ns: u128,
    p99_ns: u128,
}

impl SearchFixture {
    fn new() -> Self {
        let repo = tempfile::tempdir().expect("create search bench repo");
        let src = repo.path().join("src");
        std::fs::create_dir_all(&src).expect("create src dir");
        let conn = Connection::open_in_memory().expect("open search bench db");
        db::run_migrations(&conn).expect("semantic migrations");
        let repo_root = repo.path().canonicalize().expect("canonical repo root");
        let ctx = ServerContext::new(conn, PROJECT_ID.to_string(), repo_root);

        let mut components = Vec::with_capacity(COMPONENTS);
        for index in 0..COMPONENTS {
            let name = format!("Component{index:04}");
            let file_path = format!("src/component_{index:04}.rs");
            std::fs::write(
                repo.path().join(&file_path),
                format!("pub struct {name};\nimpl {name} {{ pub fn id(&self) -> usize {{ {index} }} }}\n"),
            )
            .expect("write component file");
            components.push(json!({
                "semantic_id": format!("fixture:{name}"),
                "name": name,
                "module": "fixture",
                "file_path": file_path,
                "kind": "struct"
            }));
        }
        registry::handle_upsert(&ctx, &json!({ "components": components }))
            .expect("populate component registry");

        Self { ctx, _repo: repo }
    }

    fn search(&self, kind: &str) {
        let args = json!({
            "project_id": PROJECT_ID,
            "query": "Component0500",
            "kind": kind,
            "scope_paths": ["src"],
            "limit": 10,
            "capsule_budget_tokens": 2_000
        });
        black_box(search::handle_search(&self.ctx, &args).expect("search bench query"));
    }
}

fn measure_search(fixture: &SearchFixture, kind: &str) -> Stats {
    let mut samples = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let start = Instant::now();
        fixture.search(kind);
        samples.push(start.elapsed().as_nanos());
    }
    Stats::from_samples(samples)
}

impl Stats {
    fn from_samples(mut samples: Vec<u128>) -> Self {
        samples.sort_unstable();
        Self {
            p50_ns: percentile(&samples, 0.50),
            p95_ns: percentile(&samples, 0.95),
            p99_ns: percentile(&samples, 0.99),
        }
    }
}

fn percentile(samples: &[u128], pct: f64) -> u128 {
    let idx = ((samples.len() as f64 * pct).ceil() as usize)
        .saturating_sub(1)
        .min(samples.len().saturating_sub(1));
    samples[idx]
}

fn artifact_dir() -> PathBuf {
    std::env::var_os("REVHARNESS_BENCH_ART_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::current_dir()
                .expect("current dir")
                .join(".claude/tmp/frontier-push")
        })
}

fn write_json(fts5: &Stats, legacy_like: &Stats) {
    let dir = artifact_dir();
    std::fs::create_dir_all(&dir).expect("create artifact dir");
    let ratio = legacy_like.p95_ns as f64 / fts5.p95_ns.max(1) as f64;
    let body = format!(
        concat!(
            "{{\n",
            "  \"bench\": \"search_fts5\",\n",
            "  \"iterations\": {},\n",
            "  \"fixture\": {{ \"components\": {} }},\n",
            "  \"fts5\": {{ \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }},\n",
            "  \"legacy_like\": {{ \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }},\n",
            "  \"ratio_p95_legacy_like_over_fts5\": {:.3}\n",
            "}}\n"
        ),
        ITERATIONS,
        COMPONENTS,
        fts5.p50_ns,
        fts5.p95_ns,
        fts5.p99_ns,
        legacy_like.p50_ns,
        legacy_like.p95_ns,
        legacy_like.p99_ns,
        ratio
    );
    std::fs::write(dir.join("bench_search.json"), body).expect("write bench_search.json");
}

fn bench_search(c: &mut Criterion) {
    let fixture = SearchFixture::new();
    let fts5 = measure_search(&fixture, "fts5");
    let legacy_like = measure_search(&fixture, "legacy-like");
    write_json(&fts5, &legacy_like);

    let mut group = c.benchmark_group("search_fts5");
    group.sample_size(10);
    group.bench_function("fts5", |b| b.iter(|| fixture.search("fts5")));
    group.bench_function("legacy_like", |b| b.iter(|| fixture.search("legacy-like")));
    group.finish();
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
