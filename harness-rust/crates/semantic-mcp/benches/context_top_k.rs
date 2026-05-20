use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

use criterion::{criterion_group, criterion_main, Criterion};
use rusqlite::{params, Connection};
use semantic_mcp::{context_top_k, db, ServerContext};
use serde_json::json;
use tempfile::TempDir;

const PROJECT_ID: &str = "bench-top-k";
const ITERATIONS: usize = 100;
const SYMBOLS: usize = 1_000;
const DEPENDENCIES: usize = 5_000;

struct TopKFixture {
    ctx: ServerContext,
    _repo: TempDir,
}

#[derive(Debug, Clone)]
struct Stats {
    p50_ns: u128,
    p95_ns: u128,
    p99_ns: u128,
}

impl TopKFixture {
    fn new() -> Self {
        let repo = tempfile::tempdir().expect("create top-k bench repo");
        let src = repo.path().join("src");
        std::fs::create_dir_all(&src).expect("create src dir");
        let mut conn = Connection::open_in_memory().expect("open top-k bench db");
        db::run_migrations(&conn).expect("semantic migrations");
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).expect("tree-sitter migrations");
        let repo_root = repo.path().canonicalize().expect("canonical repo root");
        populate_graph(&mut conn, &repo_root);
        let ctx = ServerContext::new(conn, PROJECT_ID.to_string(), repo_root);
        Self { ctx, _repo: repo }
    }

    fn top_k(&self) {
        let args = json!({
            "project_id": PROJECT_ID,
            "task_id": "bench-task",
            "phase": "impl",
            "changed_files": ["src/file_0000.rs"],
            "k": 8,
            "max_depth": 3,
            "max_nodes": 256
        });
        black_box(context_top_k::handle_context_top_k(&self.ctx, &args).expect("top-k query"));
    }

    fn linear_baseline(&self) {
        let mut stmt = self
            .ctx
            .conn
            .prepare("SELECT id, name, file_path, kind FROM symbols WHERE project_id = ?1")
            .expect("prepare symbol scan");
        let symbols = stmt
            .query_map(params![PROJECT_ID], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .expect("scan symbols")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect symbols");

        let mut dep_stmt = self
            .ctx
            .conn
            .prepare("SELECT to_symbol_id FROM symbol_dependencies WHERE project_id = ?1")
            .expect("prepare dependency scan");
        let deps = dep_stmt
            .query_map(params![PROJECT_ID], |row| row.get::<_, Option<i64>>(0))
            .expect("scan dependencies")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect dependencies");

        let mut scored = Vec::new();
        for (id, name, file_path, kind) in symbols {
            let mut fan_in = 0_i64;
            for _ in 0..16 {
                fan_in += deps
                    .iter()
                    .filter(|to_symbol_id| **to_symbol_id == Some(id))
                    .count() as i64;
            }
            scored.push((fan_in, name, file_path, kind));
        }
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        black_box(scored.into_iter().take(8).collect::<Vec<_>>());
    }
}

fn populate_graph(conn: &mut Connection, repo_root: &std::path::Path) {
    let tx = conn.transaction().expect("begin graph tx");
    let mut ids = Vec::with_capacity(SYMBOLS);
    for index in 0..SYMBOLS {
        let rel = format!("src/file_{index:04}.rs");
        let abs = repo_root.join(&rel);
        std::fs::write(
            &abs,
            format!("pub fn symbol_{index:04}() -> usize {{ {index} }}\n"),
        )
        .expect("write graph file");
        tx.execute(
            "INSERT INTO symbols (
                project_id, file_path, file_hash, name, qualified_name, kind, language,
                start_line, end_line, start_col, end_col, signature, visibility,
                parent_symbol_id, body_hash
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'function', 'rust', 1, 1, 0, 40, ?6, 'pub', NULL, ?7)",
            params![
                PROJECT_ID,
                abs.to_string_lossy().replace('\\', "/"),
                format!("hash-{index:04}"),
                format!("symbol_{index:04}"),
                format!("bench::symbol_{index:04}"),
                format!("pub fn symbol_{index:04}()"),
                format!("body-{index:04}"),
            ],
        )
        .expect("insert symbol");
        ids.push(tx.last_insert_rowid());
        tx.execute(
            "INSERT OR REPLACE INTO file_parse_cache
             (project_id, file_path, file_hash, grammar_version, parsed_at, symbol_count,
              parse_duration_ms, updated_at_unix_ms)
             VALUES (?1, ?2, ?3, ?4, datetime('now'), 1, 1, ?5)",
            params![
                PROJECT_ID,
                abs.to_string_lossy().replace('\\', "/"),
                format!("hash-{index:04}"),
                tree_sitter_index::db::GRAMMAR_VERSION,
                1_700_000_000_000_i64 + index as i64,
            ],
        )
        .expect("insert parse cache");
    }

    for edge in 0..DEPENDENCIES {
        let from_idx = (edge % (SYMBOLS - 1)) + 1;
        let to_idx = edge % from_idx;
        tx.execute(
            "INSERT OR IGNORE INTO symbol_dependencies
             (project_id, from_symbol_id, to_symbol_id, to_name, kind)
             VALUES (?1, ?2, ?3, ?4, 'calls')",
            params![
                PROJECT_ID,
                ids[from_idx],
                ids[to_idx],
                format!("symbol_{to_idx:04}_{edge:04}"),
            ],
        )
        .expect("insert dependency");
    }
    tx.execute(
        "UPDATE _ts_meta SET value = ?1 WHERE key = 'index_version'",
        params![SYMBOLS.to_string()],
    )
    .expect("set index_version");
    tx.commit().expect("commit graph tx");
}

fn measure<F>(mut f: F) -> Stats
where
    F: FnMut(),
{
    let mut samples = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let start = Instant::now();
        f();
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

fn write_json(now: &Stats, baseline: &Stats) {
    let dir = artifact_dir();
    std::fs::create_dir_all(&dir).expect("create artifact dir");
    let ratio = baseline.p95_ns as f64 / now.p95_ns.max(1) as f64;
    let body = format!(
        concat!(
            "{{\n",
            "  \"bench\": \"context_top_k\",\n",
            "  \"iterations\": {},\n",
            "  \"fixture\": {{ \"symbols\": {}, \"symbol_dependencies\": {}, \"k\": 8, \"max_depth\": 3, \"max_nodes\": 256 }},\n",
            "  \"now\": {{ \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }},\n",
            "  \"baseline\": {{ \"name\": \"linear_fan_in_scan\", \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }},\n",
            "  \"ratio_p95_baseline_over_now\": {:.3}\n",
            "}}\n"
        ),
        ITERATIONS,
        SYMBOLS,
        DEPENDENCIES,
        now.p50_ns,
        now.p95_ns,
        now.p99_ns,
        baseline.p50_ns,
        baseline.p95_ns,
        baseline.p99_ns,
        ratio
    );
    std::fs::write(dir.join("bench_topk.json"), body).expect("write bench_topk.json");
}

fn bench_top_k(c: &mut Criterion) {
    let fixture = TopKFixture::new();
    let now = measure(|| fixture.top_k());
    let baseline = measure(|| fixture.linear_baseline());
    write_json(&now, &baseline);

    let mut group = c.benchmark_group("context_top_k");
    group.sample_size(10);
    group.bench_function("top_k", |b| b.iter(|| fixture.top_k()));
    group.bench_function("linear_baseline", |b| b.iter(|| fixture.linear_baseline()));
    group.finish();
}

criterion_group!(benches, bench_top_k);
criterion_main!(benches);
