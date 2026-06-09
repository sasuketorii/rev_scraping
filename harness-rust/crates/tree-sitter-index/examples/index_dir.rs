//! One-shot indexer for a real on-disk directory.
//!
//! Phase 3 (contact_dev install) helper:
//! Walks a repo, classifies files by extension, computes sha256 hash,
//! and invokes `index_files` against the project's semantic.db so the
//! full 6-language coverage gets persisted.
//!
//! Usage:
//!   cargo run --release --example index_dir -p tree-sitter-index -- \
//!     --project-id <pid> \
//!     --db <path/to/semantic.db> \
//!     --root <path/to/repo> \
//!     [--max-files N]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use rusqlite::Connection;
use sha2::{Digest, Sha256};
use tree_sitter_index::{db, incremental, IndexConfig};

const SKIP_DIRS: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    ".next",
    ".venv",
    "_codex_inputs",
    ".archive",
    "dist",
    "build",
    ".turbo",
    ".cache",
    ".rev-harness-state",
];

fn ext_to_lang(ext: &str) -> Option<&'static str> {
    match ext {
        "rs" => Some("rust"),
        "ts" => Some("typescript"),
        "tsx" => Some("typescript"),
        "js" => Some("javascript"),
        "jsx" => Some("javascript"),
        "py" => Some("python"),
        "go" => Some("go"),
        "sh" | "bash" => Some("shell"),
        "md" => Some("markdown"),
        _ => None,
    }
}

fn walk(root: &Path, skip_dirs: &[&str], out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    let entries = std::fs::read_dir(root)?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let file_name = entry.file_name();
        let name = file_name.to_string_lossy();
        let ft = entry.file_type()?;
        if ft.is_dir() {
            if skip_dirs.iter().any(|s| *s == name) {
                continue;
            }
            walk(&path, skip_dirs, out)?;
        } else if ft.is_file() {
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                if ext_to_lang(ext).is_some() {
                    out.push(path);
                }
            }
        }
    }
    Ok(())
}

fn sha256_file(path: &Path) -> std::io::Result<String> {
    let bytes = std::fs::read(path)?;
    let mut h = Sha256::new();
    h.update(&bytes);
    Ok(hex::encode(h.finalize()))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut project_id = String::new();
    let mut db_path = String::new();
    let mut root = String::new();
    let mut max_files: Option<usize> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--project-id" => {
                project_id = args[i + 1].clone();
                i += 2;
            }
            "--db" => {
                db_path = args[i + 1].clone();
                i += 2;
            }
            "--root" => {
                root = args[i + 1].clone();
                i += 2;
            }
            "--max-files" => {
                max_files = Some(args[i + 1].parse()?);
                i += 2;
            }
            other => {
                return Err(format!("unknown arg: {other}").into());
            }
        }
    }

    if project_id.is_empty() || db_path.is_empty() || root.is_empty() {
        return Err("--project-id, --db, and --root are required".into());
    }

    let root_path = PathBuf::from(&root);
    eprintln!("[index_dir] walking root={}", root_path.display());
    let walk_start = Instant::now();
    let mut files = Vec::new();
    walk(&root_path, SKIP_DIRS, &mut files)?;
    eprintln!(
        "[index_dir] found {} candidate files in {:.2?}",
        files.len(),
        walk_start.elapsed()
    );

    if let Some(n) = max_files {
        files.truncate(n);
        eprintln!("[index_dir] truncated to {n}");
    }

    // Classify + hash
    let mut by_lang: HashMap<&'static str, usize> = HashMap::new();
    let mut tuples: Vec<(PathBuf, PathBuf, String, String)> = Vec::with_capacity(files.len());
    let hash_start = Instant::now();
    for path in &files {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or_default();
        let Some(lang) = ext_to_lang(ext) else {
            continue;
        };
        match sha256_file(path) {
            Ok(hash) => {
                *by_lang.entry(lang).or_insert(0) += 1;
                // index_key is repo-relative (stripped from --root); read_path
                // stays the absolute walked path for filesystem IO.
                let index_key = path
                    .strip_prefix(&root_path)
                    .map(PathBuf::from)
                    .unwrap_or_else(|_| path.clone());
                tuples.push((path.clone(), index_key, lang.to_string(), hash));
            }
            Err(e) => {
                eprintln!("[index_dir] hash failed {}: {}", path.display(), e);
            }
        }
    }
    eprintln!(
        "[index_dir] hashed {} files in {:.2?}",
        tuples.len(),
        hash_start.elapsed()
    );
    eprintln!("[index_dir] per-language counts: {:?}", by_lang);

    // Open db and run migrations
    let mut conn = Connection::open(&db_path)?;
    db::run_tree_sitter_migrations(&conn)?;
    eprintln!("[index_dir] db open + migrations done: {}", db_path);

    let config = IndexConfig {
        max_file_size: 2 * 1024 * 1024,
        parse_failure_threshold: 0.25,
        exclude_patterns: Vec::new(),
    };

    let idx_start = Instant::now();
    let result = incremental::index_files(&mut conn, &project_id, &tuples, &config, false)?;
    eprintln!(
        "[index_dir] index_files done in {:.2?}: parsed={} skipped={} parse_failures={} symbols={} deps={}",
        idx_start.elapsed(),
        result.files_parsed,
        result.files_skipped,
        result.parse_failures,
        result.symbols_extracted,
        result.dependencies_extracted,
    );

    println!(
        "{{\"files_parsed\":{},\"files_skipped\":{},\"parse_failures\":{},\"symbols_extracted\":{},\"dependencies_extracted\":{},\"per_lang\":{}}}",
        result.files_parsed,
        result.files_skipped,
        result.parse_failures,
        result.symbols_extracted,
        result.dependencies_extracted,
        serde_json::to_string(&by_lang)?
    );

    Ok(())
}
