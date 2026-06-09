use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

use criterion::{criterion_group, criterion_main, Criterion};
use rusqlite::Connection;
use tempfile::TempDir;
use tree_sitter_index::{db, incremental, IndexConfig};

const PROJECT_ID: &str = "bench-index";
const ITERATIONS: usize = 100;
const FILES: usize = 100;
const LOC_PER_FILE: usize = 1_000;

struct IndexFixture {
    _repo: TempDir,
    files: Vec<(PathBuf, PathBuf, String, String)>,
    config: IndexConfig,
}

#[derive(Debug, Clone)]
struct Stats {
    p50_ns: u128,
    p95_ns: u128,
    p99_ns: u128,
}

impl IndexFixture {
    fn new() -> Self {
        let repo = tempfile::tempdir().expect("create index bench repo");
        let src = repo.path().join("src");
        std::fs::create_dir_all(&src).expect("create src dir");
        let mut files = Vec::with_capacity(FILES);
        for index in 0..FILES {
            let path = src.join(format!("fixture_{index:04}.rs"));
            std::fs::write(&path, rust_file(index)).expect("write rust fixture");
            let index_key = PathBuf::from(format!("src/fixture_{index:04}.rs"));
            files.push((path, index_key, "rust".to_string(), format!("hash-{index:04}")));
        }
        Self {
            _repo: repo,
            files,
            config: IndexConfig {
                max_file_size: 2 * 1024 * 1024,
                parse_failure_threshold: 0.1,
                exclude_patterns: Vec::new(),
            },
        }
    }

    fn cold_once(&self) {
        let mut conn = Connection::open_in_memory().expect("open cold db");
        db::run_tree_sitter_migrations(&conn).expect("tree-sitter migrations");
        let result =
            incremental::index_files(&mut conn, PROJECT_ID, &self.files, &self.config, true)
                .expect("cold index files");
        black_box(result);
    }

    fn warm_conn(&self) -> Connection {
        let mut conn = Connection::open_in_memory().expect("open warm db");
        db::run_tree_sitter_migrations(&conn).expect("tree-sitter migrations");
        incremental::index_files(&mut conn, PROJECT_ID, &self.files, &self.config, true)
            .expect("prime warm index");
        conn
    }

    fn warm_once(&self, conn: &mut Connection) {
        let result = incremental::index_files(conn, PROJECT_ID, &self.files, &self.config, true)
            .expect("warm index files");
        black_box(result);
    }
}

fn rust_file(index: usize) -> String {
    let mut content =
        format!("pub mod fixture_{index:04} {{\n    pub fn entry() -> usize {{ {index} }}\n");
    for _ in 0..(LOC_PER_FILE - 3) {
        content.push('\n');
    }
    content.push_str("}\n");
    content
}

fn measure_cold(fixture: &IndexFixture) -> Stats {
    let mut samples = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let start = Instant::now();
        fixture.cold_once();
        samples.push(start.elapsed().as_nanos());
    }
    Stats::from_samples(samples)
}

fn measure_warm(fixture: &IndexFixture) -> Stats {
    let mut conn = fixture.warm_conn();
    let mut samples = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let start = Instant::now();
        fixture.warm_once(&mut conn);
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

fn write_json(cold: &Stats, warm: &Stats) {
    let dir = artifact_dir();
    std::fs::create_dir_all(&dir).expect("create artifact dir");
    let body = format!(
        concat!(
            "{{\n",
            "  \"bench\": \"index_files\",\n",
            "  \"iterations\": {},\n",
            "  \"fixture\": {{ \"rust_files\": {}, \"loc_per_file\": {} }},\n",
            "  \"cold\": {{ \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }},\n",
            "  \"warm\": {{ \"p50_ns\": {}, \"p95_ns\": {}, \"p99_ns\": {} }}\n",
            "}}\n"
        ),
        ITERATIONS,
        FILES,
        LOC_PER_FILE,
        cold.p50_ns,
        cold.p95_ns,
        cold.p99_ns,
        warm.p50_ns,
        warm.p95_ns,
        warm.p99_ns
    );
    std::fs::write(dir.join("bench_index.json"), body).expect("write bench_index.json");
}

fn bench_index_files(c: &mut Criterion) {
    let fixture = IndexFixture::new();
    let cold = measure_cold(&fixture);
    let warm = measure_warm(&fixture);
    write_json(&cold, &warm);

    let mut group = c.benchmark_group("index_files");
    group.sample_size(10);
    group.bench_function("cold", |b| b.iter(|| fixture.cold_once()));
    let mut warm_conn = fixture.warm_conn();
    group.bench_function("warm", |b| b.iter(|| fixture.warm_once(&mut warm_conn)));
    group.finish();
}

criterion_group!(benches, bench_index_files);
criterion_main!(benches);
