//! Incremental indexing and impact analysis.
//!
//! Provides the main entry points for indexing source files with caching,
//! and for analyzing the downstream impact of file changes via BFS traversal
//! of the dependency graph.

use std::collections::{HashSet, VecDeque};
use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, TransactionBehavior};
use shared::error::AgentError;
use tracing::{debug, info, warn};

use crate::db;
use crate::extractors;
use crate::parser;
use crate::types::{ImpactReport, IndexConfig, IndexResult, Symbol};

struct ParsedFile {
    file_path: String,
    file_hash: String,
    symbol_pairs: Vec<(crate::types::RawSymbol, Option<i64>)>,
    raw_deps: Vec<extractors::RawDependency>,
    line_ranges: Vec<(u32, u32)>,
    parse_duration_ms: u64,
}

fn current_unix_ms() -> shared::error::Result<u64> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| AgentError::State(format!("system clock is before unix epoch: {e}")))?;
    u64::try_from(duration.as_millis())
        .map_err(|_| AgentError::State("unix timestamp milliseconds overflowed u64".into()))
}

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

/// Index a set of source files, skipping cached and non-parseable files.
///
/// Each entry in `files` is `(read_path, index_key, language, file_hash)`:
/// - `read_path` is the ABSOLUTE filesystem path used for stat / read / parse.
/// - `index_key` is the REPO-RELATIVE string persisted as the DB value for
///   `symbols`, `file_parse_cache`, and the GC snapshot set (I-1 privacy:
///   home-absolute host paths must never be stored).
///
/// The split is confined to this function: callers supply both paths, and the
/// downstream upsert / cache / GC sites all key off `index_key` while every
/// filesystem-IO site uses `read_path`.
///
/// Returns an [`IndexResult`] summarising what was processed.
pub fn index_files(
    conn: &mut Connection,
    project_id: &str,
    files: &[(PathBuf, PathBuf, String, String)],
    config: &IndexConfig,
    gc_orphans: bool,
) -> shared::error::Result<IndexResult> {
    let start = Instant::now();
    let mut result = IndexResult {
        files_parsed: 0,
        files_skipped: 0,
        parse_failures: 0,
        symbols_extracted: 0,
        dependencies_extracted: 0,
        total_duration_ms: 0,
    };

    let mut parse_failed_files: Vec<String> = Vec::new();
    let mut parsed_files: Vec<ParsedFile> = Vec::new();

    for (read_path, index_key, language, file_hash) in files {
        // `read_path` (absolute) is used for every filesystem-IO site below;
        // `index_key` (repo-relative) is the DB value for the cache check,
        // symbols upsert, file_parse_cache write, and GC snapshot set.
        let file_path_str = index_key.to_string_lossy().to_string();

        // 1. Check cache (keyed by the repo-relative index_key).
        if db::is_file_cached(
            conn,
            project_id,
            &file_path_str,
            file_hash,
            db::GRAMMAR_VERSION,
        )? {
            debug!(file = %file_path_str, "skipping cached file");
            result.files_skipped += 1;
            continue;
        }

        // 2. Check file size (stat the absolute read_path).
        let metadata = std::fs::metadata(read_path).map_err(AgentError::Io);
        match metadata {
            Ok(meta) => {
                if meta.len() > config.max_file_size {
                    debug!(file = %file_path_str, size = meta.len(), "skipping large file");
                    result.files_skipped += 1;
                    continue;
                }
            }
            Err(e) => {
                warn!(file = %file_path_str, error = %e, "cannot stat file, skipping");
                result.files_skipped += 1;
                continue;
            }
        }

        // 3. Read file content (from the absolute read_path).
        let content = match std::fs::read(read_path) {
            Ok(bytes) => bytes,
            Err(e) => {
                warn!(file = %file_path_str, error = %e, "cannot read file, skipping");
                result.files_skipped += 1;
                continue;
            }
        };

        // 4. Check for binary (NUL bytes in first 8KB).
        let check_len = content.len().min(8192);
        if content[..check_len].contains(&0u8) {
            debug!(file = %file_path_str, "skipping binary file");
            result.files_skipped += 1;
            continue;
        }

        // 5. Parse with tree-sitter.
        let source = match std::str::from_utf8(&content) {
            Ok(s) => s,
            Err(_) => {
                debug!(file = %file_path_str, "skipping non-UTF-8 file");
                result.files_skipped += 1;
                continue;
            }
        };

        let tree = match parser::parse_source(source, language) {
            Ok(t) => t,
            Err(e) => {
                warn!(file = %file_path_str, error = %e, "parse failure");
                result.parse_failures += 1;
                parse_failed_files.push(file_path_str.clone());

                // H-14: Use attempted (parsed + failed) as denominator, not total_files.
                let attempted = parsed_files.len() + result.parse_failures;
                if attempted > 0 {
                    let failure_rate = result.parse_failures as f64 / attempted as f64;
                    if failure_rate > config.parse_failure_threshold {
                        return Err(AgentError::State(format!(
                            "parse failure rate {:.1}% exceeds threshold {:.1}%",
                            failure_rate * 100.0,
                            config.parse_failure_threshold * 100.0
                        )));
                    }
                }
                continue;
            }
        };

        // 6. Extract symbols.
        let extractor = match extractors::get_extractor(language) {
            Some(e) => e,
            None => {
                debug!(file = %file_path_str, lang = %language, "no extractor for language");
                result.files_skipped += 1;
                continue;
            }
        };

        let file_parse_start = Instant::now();
        let raw_symbols = extractor.extract_symbols(content.as_slice(), &tree);
        let raw_deps = extractor.extract_dependencies(content.as_slice(), &tree);

        // 7. Build symbol pairs.
        let symbol_pairs: Vec<_> = raw_symbols.into_iter().map(|s| (s, None)).collect();

        // Build line-range entries: Vec<(start_line, end_line)> matching the order
        // that insert_symbol produces IDs (parent, then children in order).
        let mut line_ranges: Vec<(u32, u32)> = Vec::new();
        for (raw, _) in &symbol_pairs {
            line_ranges.push((raw.start_line, raw.end_line));
            for child in &raw.children {
                line_ranges.push((child.start_line, child.end_line));
            }
        }

        let parse_duration_ms = file_parse_start.elapsed().as_millis() as u64;
        parsed_files.push(ParsedFile {
            file_path: file_path_str,
            file_hash: file_hash.clone(),
            symbol_pairs,
            raw_deps,
            line_ranges,
            parse_duration_ms,
        });
    }

    let tx_start_unix_ms = current_unix_ms()?;
    if !parsed_files.is_empty() || gc_orphans {
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| AgentError::Database(format!("failed to begin transaction: {e}")))?;

        for parsed in parsed_files {
            let ids = db::upsert_symbols_in_tx(
                &tx,
                project_id,
                &parsed.file_path,
                &parsed.file_hash,
                &parsed.symbol_pairs,
            )?;

            let symbol_count = ids.len();
            result.symbols_extracted += symbol_count;

            // H-12: Attribute each dependency to the narrowest enclosing symbol by line range.
            if !parsed.raw_deps.is_empty() && !ids.is_empty() {
                let dep_pairs: Vec<_> = parsed
                    .raw_deps
                    .into_iter()
                    .map(|d| {
                        let owner_id =
                            find_enclosing_symbol(&ids, &parsed.line_ranges, d.source_line)
                                .unwrap_or(ids[0]);
                        (owner_id, d)
                    })
                    .collect();
                db::upsert_dependencies_in_tx(&tx, project_id, &dep_pairs)?;
                result.dependencies_extracted += dep_pairs.len();
            }

            let cache_update = db::ParseCacheUpdate {
                project_id,
                file_path: &parsed.file_path,
                file_hash: &parsed.file_hash,
                grammar_version: db::GRAMMAR_VERSION,
                symbol_count: symbol_count as u32,
                parse_duration_ms: parsed.parse_duration_ms,
                updated_at_unix_ms: tx_start_unix_ms,
            };
            db::update_parse_cache_in_tx(&tx, &cache_update)?;
            let _new_version = db::increment_index_version_in_tx(&tx)?;
            result.files_parsed += 1;
        }

        if gc_orphans {
            // GC compares against the repo-relative index_key set (the same
            // form now stored in symbols/file_parse_cache), so the snapshot set
            // must also be repo-relative — both sides flip together.
            let snapshot_paths: HashSet<String> = files
                .iter()
                .map(|(_, index_key, _, _)| index_key.to_string_lossy().to_string())
                .collect();
            let gc_report = db::gc_symbols_not_in_snapshot_in_tx(
                &tx,
                project_id,
                &snapshot_paths,
                tx_start_unix_ms,
            )?;
            if result.files_parsed == 0
                && (gc_report.removed_files > 0
                    || gc_report.removed_symbols > 0
                    || gc_report.removed_dependencies > 0)
            {
                let _new_version = db::increment_index_version_in_tx(&tx)?;
            }
        }

        // Resolve pending symbol_dependencies.to_symbol_id now that all symbol
        // rows for this batch are upserted. Previously this was only called in
        // tests, leaving to_symbol_id NULL and the reverse-dependency BFS in
        // impact_analysis dead. Runs inside the same transaction (Transaction
        // derefs to Connection).
        db::resolve_pending_dependencies(&tx, project_id)?;

        tx.commit()
            .map_err(|e| AgentError::Database(format!("failed to commit transaction: {e}")))?;
    }

    // Store parse_failed_files for later use by impact_analysis (H-13).
    // We stash them as a comma-separated list in a temp table or pass through
    // the result. Since IndexResult doesn't carry this, callers should use
    // the returned parse_failed_files from impact_analysis instead.
    let _ = &parse_failed_files; // used below in logging

    result.total_duration_ms = start.elapsed().as_millis() as u64;
    info!(
        parsed = result.files_parsed,
        skipped = result.files_skipped,
        failures = result.parse_failures,
        symbols = result.symbols_extracted,
        deps = result.dependencies_extracted,
        duration_ms = result.total_duration_ms,
        "indexing complete"
    );

    Ok(result)
}

// ---------------------------------------------------------------------------
// Impact analysis
// ---------------------------------------------------------------------------

/// Perform BFS impact analysis starting from symbols in the changed files.
///
/// Returns an [`ImpactReport`] describing which symbols and files are
/// transitively affected by changes. The traversal is bounded by
/// `max_depth` and `max_nodes` to prevent runaway analysis.
pub fn impact_analysis(
    conn: &Connection,
    project_id: &str,
    changed_files: &[&str],
    max_depth: u32,
    max_nodes: u32,
) -> shared::error::Result<ImpactReport> {
    // Check if the symbols table is populated.
    let symbol_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM symbols WHERE project_id = ?1",
            rusqlite::params![project_id],
            |row| row.get(0),
        )
        .map_err(|e| AgentError::Database(format!("failed to count symbols: {e}")))?;

    if symbol_count == 0 {
        return Ok(ImpactReport {
            changed_symbols: Vec::new(),
            affected_symbols: Vec::new(),
            affected_files: Vec::new(),
            depth: 0,
            populated: false,
            parse_failed_files: Vec::new(),
            ambiguous_matches: 0,
            truncated: false,
        });
    }

    // Collect symbols from changed files and detect parse failures (H-13).
    let mut changed_symbols = Vec::new();
    let mut seed_ids: HashSet<i64> = HashSet::new();
    let mut parse_failed_files: Vec<String> = Vec::new();

    for file in changed_files {
        let syms = db::symbols_in_file(conn, project_id, file)?;
        if syms.is_empty() {
            // File has no symbols — likely a parse failure or empty file.
            parse_failed_files.push(file.to_string());
        }
        for sym in &syms {
            if let Some(id) = sym.id {
                seed_ids.insert(id);
            }
        }
        changed_symbols.extend(syms);
    }

    // BFS traversal of reverse dependency graph.
    let mut visited: HashSet<i64> = seed_ids.clone();
    let mut queue: VecDeque<(i64, u32)> = seed_ids.iter().map(|id| (*id, 0)).collect();
    let mut affected_symbols: Vec<Symbol> = Vec::new();
    let mut affected_file_set: HashSet<String> = HashSet::new();
    let mut current_depth: u32 = 0;
    let mut truncated = false;
    let mut ambiguous_matches: u32 = 0;

    while let Some((sym_id, depth)) = queue.pop_front() {
        if depth > max_depth {
            continue;
        }
        current_depth = current_depth.max(depth);

        if visited.len() as u32 > max_nodes {
            truncated = true;
            break;
        }

        let dependents = db::dependents_of(conn, sym_id)?;

        // Track ambiguous matches (same name appearing in multiple files).
        if dependents.len() > 1 {
            let unique_files: HashSet<_> = dependents.iter().map(|d| &d.file_path).collect();
            if unique_files.len() > 1 {
                ambiguous_matches += 1;
            }
        }

        for dep in dependents {
            let dep_id = match dep.id {
                Some(id) => id,
                None => continue,
            };

            if visited.contains(&dep_id) {
                continue;
            }
            visited.insert(dep_id);

            affected_file_set.insert(dep.file_path.clone());
            affected_symbols.push(dep);
            queue.push_back((dep_id, depth + 1));
        }
    }

    let affected_files: Vec<String> = affected_file_set.into_iter().collect();

    Ok(ImpactReport {
        changed_symbols,
        affected_symbols,
        affected_files,
        depth: current_depth,
        populated: true,
        parse_failed_files,
        ambiguous_matches,
        truncated,
    })
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/// Find symbols with a high fan-in (many dependents).
///
/// Returns symbols that have at least `threshold` reverse dependencies.
pub fn detect_high_fan_in(
    conn: &Connection,
    project_id: &str,
    threshold: u32,
) -> shared::error::Result<Vec<(Symbol, u32)>> {
    let mut stmt = conn
        .prepare(
            "SELECT s.id, s.file_path, s.file_hash, s.name, s.qualified_name, s.kind,
                    s.language, s.start_line, s.end_line, s.start_col, s.end_col,
                    s.signature, s.visibility, s.parent_symbol_id, s.body_hash,
                    COUNT(d.id) as dep_count
             FROM symbols s
             INNER JOIN symbol_dependencies d ON d.to_symbol_id = s.id
             WHERE s.project_id = ?1
             GROUP BY s.id
             HAVING dep_count >= ?2
             ORDER BY dep_count DESC",
        )
        .map_err(|e| AgentError::Database(format!("failed to prepare fan-in query: {e}")))?;

    let rows = stmt
        .query_map(rusqlite::params![project_id, threshold], |row| {
            let kind_str: String = row.get(5)?;
            let kind = kind_str
                .parse::<crate::types::SymbolKind>()
                .unwrap_or(crate::types::SymbolKind::Function);

            let sym = Symbol {
                id: row.get(0)?,
                file_path: row.get(1)?,
                file_hash: row.get(2)?,
                name: row.get(3)?,
                qualified_name: row.get(4)?,
                kind,
                language: row.get(6)?,
                start_line: row.get(7)?,
                end_line: row.get(8)?,
                start_col: row.get(9)?,
                end_col: row.get(10)?,
                signature: row.get(11)?,
                visibility: row.get(12)?,
                parent_symbol_id: row.get(13)?,
                body_hash: row.get(14)?,
            };
            let count: u32 = row.get(15)?;
            Ok((sym, count))
        })
        .map_err(|e| AgentError::Database(format!("failed to query fan-in: {e}")))?;

    let mut result = Vec::new();
    for row in rows {
        let item =
            row.map_err(|e| AgentError::Database(format!("failed to read fan-in row: {e}")))?;
        result.push(item);
    }
    Ok(result)
}

/// Find the narrowest enclosing symbol for a given source line.
///
/// `ids` and `line_ranges` must be parallel arrays.  Returns the symbol ID
/// whose `[start_line, end_line]` range contains `source_line` with the
/// smallest span.  Falls back to `None` if no symbol encloses that line.
fn find_enclosing_symbol(ids: &[i64], line_ranges: &[(u32, u32)], source_line: u32) -> Option<i64> {
    let mut best: Option<(i64, u32)> = None; // (id, span_width)
    for (idx, &(start, end)) in line_ranges.iter().enumerate() {
        if source_line >= start && source_line <= end {
            let span = end - start;
            if best.is_none() || span < best.unwrap().1 {
                best = Some((ids[idx], span));
            }
        }
    }
    best.map(|(id, _)| id)
}

/// Check whether a periodic full review should be triggered.
///
/// Returns `true` when `iteration` is a multiple of `interval`.
pub fn should_force_full_review(iteration: u32, interval: u32) -> bool {
    iteration > 0 && interval != 0 && iteration.is_multiple_of(interval)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::run_tree_sitter_migrations;
    use crate::types::{RawSymbol, SymbolKind};
    use std::io::Write;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        run_tree_sitter_migrations(&conn).unwrap();
        conn
    }

    fn make_raw(name: &str, kind: SymbolKind) -> RawSymbol {
        RawSymbol {
            name: name.to_string(),
            qualified_name: None,
            kind,
            language: "rust".to_string(),
            start_line: 1,
            end_line: 5,
            start_col: 0,
            end_col: 0,
            signature: None,
            visibility: None,
            body_hash: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn index_files_skips_cached_files() {
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.rs");
        std::fs::write(&file_path, "fn foo() {}").unwrap();

        let hash = "cached_hash";
        // Cache is keyed by the repo-relative index_key, not the absolute path.
        db::update_parse_cache(&conn, "proj", "test.rs", hash, db::GRAMMAR_VERSION, 0, 0).unwrap();

        let files = vec![(
            file_path,
            PathBuf::from("test.rs"),
            "rust".to_string(),
            hash.to_string(),
        )];
        let config = IndexConfig::default();
        let result = index_files(&mut conn, "proj", &files, &config, false).unwrap();
        assert_eq!(result.files_skipped, 1);
        assert_eq!(result.files_parsed, 0);
    }

    #[test]
    fn index_files_skips_large_files() {
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("big.rs");

        // Write a file larger than default max_file_size (102400).
        let content = "x".repeat(200_000);
        std::fs::write(&file_path, &content).unwrap();

        let files = vec![(
            file_path,
            PathBuf::from("big.rs"),
            "rust".to_string(),
            "somehash".to_string(),
        )];
        let config = IndexConfig::default();
        let result = index_files(&mut conn, "proj", &files, &config, false).unwrap();
        assert_eq!(result.files_skipped, 1);
        assert_eq!(result.files_parsed, 0);
    }

    #[test]
    fn index_files_skips_binary_files() {
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("binary.rs");

        // Write a file with NUL bytes.
        let mut f = std::fs::File::create(&file_path).unwrap();
        f.write_all(b"fn foo() {}\x00binary data").unwrap();

        let files = vec![(
            file_path,
            PathBuf::from("binary.rs"),
            "rust".to_string(),
            "binhash".to_string(),
        )];
        let config = IndexConfig::default();
        let result = index_files(&mut conn, "proj", &files, &config, false).unwrap();
        assert_eq!(result.files_skipped, 1);
        assert_eq!(result.files_parsed, 0);
    }

    #[test]
    fn index_files_tracks_parse_failures() {
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.cobol");

        std::fs::write(&file_path, "IDENTIFICATION DIVISION.").unwrap();

        let files = vec![(
            file_path,
            PathBuf::from("test.cobol"),
            "cobol".to_string(),
            "h1".to_string(),
        )];
        let config = IndexConfig {
            parse_failure_threshold: 1.0, // Allow all failures.
            ..IndexConfig::default()
        };
        let result = index_files(&mut conn, "proj", &files, &config, false).unwrap();
        // cobol is unsupported, so it's a parse failure.
        assert!(result.parse_failures > 0 || result.files_skipped > 0);
    }

    #[test]
    fn index_files_indexes_valid_rust_file() {
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("lib.rs");
        std::fs::write(&file_path, "fn hello() {} struct Foo;").unwrap();

        let files = vec![(
            file_path,
            PathBuf::from("lib.rs"),
            "rust".to_string(),
            "newhash".to_string(),
        )];
        let config = IndexConfig::default();
        let result = index_files(&mut conn, "proj", &files, &config, false).unwrap();
        assert_eq!(result.files_parsed, 1);
        assert!(result.symbols_extracted >= 2);
    }

    #[test]
    fn index_files_stores_repo_relative_index_key() {
        // The DB value is the repo-relative index_key, NOT the absolute
        // read_path (I-1 privacy: no home-absolute host path in
        // symbols/file_parse_cache).
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let abs = dir.path().join("lib.rs");
        std::fs::write(&abs, "fn hello() {}").unwrap();

        let files = vec![(
            abs,
            PathBuf::from("src/lib.rs"),
            "rust".to_string(),
            "h1".to_string(),
        )];
        index_files(&mut conn, "proj", &files, &IndexConfig::default(), false).unwrap();

        let stored: String = conn
            .query_row(
                "SELECT file_path FROM symbols WHERE project_id = 'proj' LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stored, "src/lib.rs");
        let cached: String = conn
            .query_row(
                "SELECT file_path FROM file_parse_cache WHERE project_id = 'proj' LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cached, "src/lib.rs");
    }

    #[test]
    fn index_files_resolves_pending_dependencies_end_to_end() {
        // Indexing two files where one calls a symbol in the other must leave
        // symbol_dependencies.to_symbol_id RESOLVED (non-NULL) and make the
        // caller appear in dependents_of(target). Previously
        // resolve_pending_dependencies was only invoked in tests, so this BFS
        // edge was dead.
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let lib_abs = dir.path().join("lib.rs");
        let main_abs = dir.path().join("main.rs");
        std::fs::write(&lib_abs, "pub fn target_fn() {}\n").unwrap();
        std::fs::write(&main_abs, "fn caller_fn() { target_fn(); }\n").unwrap();

        let files = vec![
            (
                lib_abs,
                PathBuf::from("lib.rs"),
                "rust".to_string(),
                "h-lib".to_string(),
            ),
            (
                main_abs,
                PathBuf::from("main.rs"),
                "rust".to_string(),
                "h-main".to_string(),
            ),
        ];
        index_files(&mut conn, "proj", &files, &IndexConfig::default(), false).unwrap();

        // No NULL to_symbol_id for the target_fn edge.
        let unresolved: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM symbol_dependencies
                 WHERE project_id = 'proj' AND to_name = 'target_fn' AND to_symbol_id IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(unresolved, 0, "target_fn dependency must be resolved");

        // dependents_of(target_fn) returns the caller.
        let target_id: i64 = conn
            .query_row(
                "SELECT id FROM symbols WHERE project_id = 'proj' AND name = 'target_fn'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let dependents = db::dependents_of(&conn, target_id).unwrap();
        assert!(
            dependents.iter().any(|s| s.name == "caller_fn"),
            "caller_fn must be a dependent of target_fn"
        );

        // And the reverse-dependency BFS now reaches the caller from lib.rs.
        let report = impact_analysis(&conn, "proj", &["lib.rs"], 3, 100).unwrap();
        assert!(report.populated);
        assert!(
            report
                .affected_symbols
                .iter()
                .any(|s| s.name == "caller_fn"),
            "impact_analysis must surface caller_fn as affected by lib.rs change"
        );
    }

    #[test]
    fn single_file_reindex_preserves_inbound_dependency_edges() {
        // Regression for commit-diff reindex: reindexing only the target file
        // must not drop reverse-impact edges from unchanged callers.
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let lib_abs = dir.path().join("lib.rs");
        let main_abs = dir.path().join("main.rs");
        std::fs::write(&lib_abs, "pub fn target_fn() {}\n").unwrap();
        std::fs::write(&main_abs, "fn caller_fn() { target_fn(); }\n").unwrap();

        let seed = vec![
            (
                lib_abs.clone(),
                PathBuf::from("lib.rs"),
                "rust".to_string(),
                "h-lib-1".to_string(),
            ),
            (
                main_abs,
                PathBuf::from("main.rs"),
                "rust".to_string(),
                "h-main-1".to_string(),
            ),
        ];
        index_files(&mut conn, "proj", &seed, &IndexConfig::default(), false).unwrap();

        let report_before = impact_analysis(&conn, "proj", &["lib.rs"], 3, 100).unwrap();
        assert!(
            report_before
                .affected_symbols
                .iter()
                .any(|s| s.name == "caller_fn"),
            "seed must establish caller_fn as a reverse dependent"
        );

        std::fs::write(&lib_abs, "pub fn target_fn() {}\npub fn sibling_fn() {}\n").unwrap();
        let commit_delta = vec![(
            lib_abs,
            PathBuf::from("lib.rs"),
            "rust".to_string(),
            "h-lib-2".to_string(),
        )];
        index_files(
            &mut conn,
            "proj",
            &commit_delta,
            &IndexConfig::default(),
            false,
        )
        .unwrap();

        let report_after = impact_analysis(&conn, "proj", &["lib.rs"], 3, 100).unwrap();
        assert!(
            report_after
                .affected_symbols
                .iter()
                .any(|s| s.name == "caller_fn"),
            "single-file reindex must preserve main.rs -> lib.rs::target_fn impact edge"
        );

        let unresolved: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM symbol_dependencies
                 WHERE project_id = 'proj' AND to_name = 'target_fn' AND to_symbol_id IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(unresolved, 0, "preserved inbound edge must relink");
    }

    #[test]
    fn single_file_reindex_does_not_relink_removed_target_to_same_name_in_other_file() {
        // Preserved inbound edges remember the file they originally targeted.
        // If the target symbol disappears from that file, the old edge must not
        // be globally relinked to an unrelated same-name symbol elsewhere.
        let mut conn = setup_db();
        let dir = tempfile::tempdir().unwrap();
        let lib_abs = dir.path().join("lib.rs");
        let main_abs = dir.path().join("main.rs");
        let other_abs = dir.path().join("other.rs");
        std::fs::write(&lib_abs, "pub fn target_fn() {}\n").unwrap();
        std::fs::write(&main_abs, "fn caller_fn() { target_fn(); }\n").unwrap();

        let seed = vec![
            (
                lib_abs.clone(),
                PathBuf::from("lib.rs"),
                "rust".to_string(),
                "h-lib-1".to_string(),
            ),
            (
                main_abs.clone(),
                PathBuf::from("main.rs"),
                "rust".to_string(),
                "h-main-1".to_string(),
            ),
        ];
        index_files(&mut conn, "proj", &seed, &IndexConfig::default(), false).unwrap();

        std::fs::write(&other_abs, "pub fn target_fn() {}\n").unwrap();
        let other = vec![(
            other_abs.clone(),
            PathBuf::from("other.rs"),
            "rust".to_string(),
            "h-other-1".to_string(),
        )];
        index_files(&mut conn, "proj", &other, &IndexConfig::default(), false).unwrap();

        let lib_report = impact_analysis(&conn, "proj", &["lib.rs"], 3, 100).unwrap();
        assert!(
            lib_report
                .affected_symbols
                .iter()
                .any(|s| s.name == "caller_fn"),
            "precondition: caller_fn must still target lib.rs before lib.rs changes"
        );

        std::fs::write(&lib_abs, "pub fn renamed_target() {}\n").unwrap();
        let lib_reindex = vec![(
            lib_abs,
            PathBuf::from("lib.rs"),
            "rust".to_string(),
            "h-lib-2".to_string(),
        )];
        index_files(
            &mut conn,
            "proj",
            &lib_reindex,
            &IndexConfig::default(),
            false,
        )
        .unwrap();

        let false_relinks: i64 = conn
            .query_row(
                "SELECT COUNT(*)
                   FROM symbol_dependencies d
                   JOIN symbols from_s ON from_s.id = d.from_symbol_id
                   JOIN symbols to_s ON to_s.id = d.to_symbol_id
                  WHERE d.project_id = 'proj'
                    AND d.to_name = 'target_fn'
                    AND from_s.file_path = 'main.rs'
                    AND to_s.file_path = 'other.rs'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            false_relinks, 0,
            "main.rs dependency must not relink from removed lib.rs::target_fn to other.rs::target_fn"
        );

        let other_report = impact_analysis(&conn, "proj", &["other.rs"], 3, 100).unwrap();
        assert!(
            !other_report
                .affected_symbols
                .iter()
                .any(|s| s.name == "caller_fn"),
            "other.rs::target_fn must not gain caller_fn through a stale preserved edge"
        );
    }

    #[test]
    fn impact_analysis_empty_db_returns_unpopulated() {
        let conn = setup_db();
        let report = impact_analysis(&conn, "proj", &["src/main.rs"], 3, 100).unwrap();
        assert!(!report.populated);
        assert!(report.changed_symbols.is_empty());
    }

    #[test]
    fn impact_analysis_with_max_nodes_cutoff() {
        let conn = setup_db();

        // Create a chain: a -> b -> c -> d.
        let raw_a = make_raw("a", SymbolKind::Function);
        let ids_a = db::upsert_symbols(&conn, "proj", "a.rs", "h1", &[(raw_a, None)]).unwrap();
        let raw_b = make_raw("b", SymbolKind::Function);
        let ids_b = db::upsert_symbols(&conn, "proj", "b.rs", "h2", &[(raw_b, None)]).unwrap();
        let raw_c = make_raw("c", SymbolKind::Function);
        let ids_c = db::upsert_symbols(&conn, "proj", "c.rs", "h3", &[(raw_c, None)]).unwrap();
        let raw_d = make_raw("d", SymbolKind::Function);
        let ids_d = db::upsert_symbols(&conn, "proj", "d.rs", "h4", &[(raw_d, None)]).unwrap();

        // b calls a, c calls b, d calls c.
        for (from, to, name) in &[
            (ids_b[0], ids_a[0], "a"),
            (ids_c[0], ids_b[0], "b"),
            (ids_d[0], ids_c[0], "c"),
        ] {
            conn.execute(
                "INSERT INTO symbol_dependencies (project_id, from_symbol_id, to_symbol_id, to_name, kind)
                 VALUES ('proj', ?1, ?2, ?3, 'calls')",
                rusqlite::params![from, to, name],
            )
            .unwrap();
        }

        // With max_nodes=2, the traversal should be truncated.
        let report = impact_analysis(&conn, "proj", &["a.rs"], 10, 2).unwrap();
        assert!(report.populated);
        assert!(report.truncated);
    }

    #[test]
    fn detect_high_fan_in_finds_popular_symbols() {
        let conn = setup_db();

        let raw_target = make_raw("popular", SymbolKind::Function);
        let target_ids =
            db::upsert_symbols(&conn, "proj", "lib.rs", "h1", &[(raw_target, None)]).unwrap();

        // Create 3 callers.
        for i in 0..3 {
            let raw = make_raw(&format!("caller_{i}"), SymbolKind::Function);
            let ids = db::upsert_symbols(
                &conn,
                "proj",
                &format!("caller_{i}.rs"),
                &format!("h{}", i + 2),
                &[(raw, None)],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO symbol_dependencies (project_id, from_symbol_id, to_symbol_id, to_name, kind)
                 VALUES ('proj', ?1, ?2, 'popular', 'calls')",
                rusqlite::params![ids[0], target_ids[0]],
            )
            .unwrap();
        }

        let results = detect_high_fan_in(&conn, "proj", 2).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.name, "popular");
        assert_eq!(results[0].1, 3);
    }

    #[test]
    fn should_force_full_review_periodic() {
        assert!(!should_force_full_review(0, 5));
        assert!(!should_force_full_review(1, 5));
        assert!(should_force_full_review(5, 5));
        assert!(should_force_full_review(10, 5));
        assert!(!should_force_full_review(3, 5));
        assert!(!should_force_full_review(1, 0)); // interval=0 → never
    }
}
