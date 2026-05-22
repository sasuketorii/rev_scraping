// SPDX-License-Identifier: MIT
//
// Lane K K.7 — criterion microbench for SiteRecipeStore::load scaling.
//
// Measures the hot path the MCP server triggers on every `tools/call` to
// a site-aware tool: open the per-domain TOML file, deserialize a
// `SiteRecipe`, and return it. We sweep the on-disk store size at 10,
// 100, and 1000 recipes to confirm load latency is O(1) in store size
// (one file per domain; no directory scan on the read path).
//
// The bench writes a tempdir on setup and reuses it across iterations.
// Each iteration loads ONE recipe (by name), so the cost reflects a
// single file read + toml::from_str, not the scaling of the store.
//
// Run locally:
//   cargo bench -p stealth-sites --bench recipe_load_hotpath

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use stealth_sites::SiteRecipeStore;
use tempfile::TempDir;

const MINIMAL_RECIPE: &str = r#"
schema_version = 1
[site]
domain = "{DOMAIN}"
rendering = "spa"
"#;

fn populate(size: usize) -> (TempDir, Vec<String>) {
    let dir = TempDir::new().expect("tempdir");
    let mut domains = Vec::with_capacity(size);
    for i in 0..size {
        let domain = format!("bench-{i}.example");
        let body = MINIMAL_RECIPE.replace("{DOMAIN}", &domain);
        let path = dir.path().join(format!("{domain}.toml"));
        std::fs::write(&path, body).expect("write recipe");
        domains.push(domain);
    }
    (dir, domains)
}

fn bench_recipe_load(c: &mut Criterion) {
    let mut group = c.benchmark_group("recipe_load");

    for &size in &[10_usize, 100, 1000] {
        let (dir, domains) = populate(size);
        let store = SiteRecipeStore::open(dir.path()).expect("open store");
        // Always load the median entry so we don't hit a fs cache hot spot
        // at index 0 / last.
        let target = domains[size / 2].clone();
        group.bench_with_input(BenchmarkId::from_parameter(size), &target, |b, domain| {
            b.iter(|| {
                let r = store.load(black_box(domain.as_str())).expect("load ok");
                black_box(r);
            });
        });
        // Keep dir alive across iterations.
        drop(store);
        drop(dir);
    }

    group.finish();
}

criterion_group!(benches, bench_recipe_load);
criterion_main!(benches);
