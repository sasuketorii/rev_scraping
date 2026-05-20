//! Capsule builder module — replaces `context_capsule.sh`.
//!
//! Builds token-budgeted prompt capsules for coder/reviewer handoff,
//! performs security-pin collection, and manages review-pattern memory
//! (JSONL) — all without shelling out to `jq`.

use clap::Subcommand;
use harness_cache::{capsule_cache_key, CacheManager};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use shared::freshness::snapshot as freshness_snapshot;
use std::fs;
use std::io::{BufRead, BufReader, Write as IoWrite};
use std::path::{Path, PathBuf};

use shared::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Hard upper limit for the entire capsule (body + meta), in tokens.
pub const MAX_CAPSULE_TOKENS: u32 = 220;

/// Token budget reserved for the capsule body.
pub const CAPSULE_BODY_BUDGET: u32 = 200;

/// Token budget reserved for capsule metadata / JSON framing.
pub const CAPSULE_META_BUDGET: u32 = 20;

/// Maximum length for escaped capsule values.
const MAX_ESCAPED_LEN: usize = 240;

// ---------------------------------------------------------------------------
// CLI subcommands
// ---------------------------------------------------------------------------

/// Capsule builder subcommands.
#[derive(Subcommand)]
pub enum CapsuleAction {
    /// Build a prompt capsule from a plan and changed files.
    Build {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Output path for the capsule JSON.
        #[arg(long)]
        output: String,
        /// Total token budget (default: 220).
        #[arg(long, default_value = "220")]
        budget: u32,
    },
    /// Estimate the token count of a text file.
    EstimateTokens {
        /// Path to the input text file.
        #[arg(long)]
        input: String,
    },
    /// Check whether files touch security-sensitive paths or symbols.
    SecurityCheck {
        /// File paths to check.
        #[arg(long)]
        files: Vec<String>,
    },
    /// Record a review pattern to the JSONL memory file.
    RecordPattern {
        /// Pattern category (e.g. "error-handling", "naming").
        #[arg(long)]
        category: String,
        /// Human-readable description.
        #[arg(long)]
        description: String,
        /// Severity level (e.g. "high", "medium", "low").
        #[arg(long)]
        severity: String,
    },
    /// Show the top-N most frequent review patterns.
    TopPatterns {
        /// Number of patterns to show.
        #[arg(long, default_value = "10")]
        count: usize,
    },
}

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

/// A token-budgeted prompt capsule for coder/reviewer handoff.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Capsule {
    /// Unique task identifier.
    pub task_id: String,
    /// Path to the execution plan that generated this capsule.
    pub plan_path: String,
    /// Files changed in this task.
    pub changed_files: Vec<String>,
    /// Condensed scope summary (body text).
    pub scope_summary: String,
    /// Security pins for sensitive paths/symbols.
    pub security_pins: Vec<SecurityPin>,
    /// Constraints extracted from the plan.
    pub constraints: Vec<String>,
    /// FILE_SHA_ROLLUP from the shared freshness snapshot.
    #[serde(default)]
    pub file_sha_rollup: String,
    /// Tree-sitter index version from the shared freshness snapshot.
    #[serde(default)]
    pub index_version: u64,
    /// SHA-256 digest of the capsule content for integrity checking.
    pub sha256: String,
    /// Estimated token count for the entire capsule.
    pub token_count: u32,
}

/// A security pin marking a sensitive file/symbol pair.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityPin {
    /// File path containing the sensitive symbol.
    pub file: String,
    /// Symbol or pattern name.
    pub symbol: String,
    /// Classification of the pin (e.g. "auth", "crypto", "secret").
    pub pin_type: String,
}

/// A review pattern recorded in the JSONL memory file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewPattern {
    /// Unique pattern identifier.
    pub pattern_id: String,
    /// Category (e.g. "error-handling", "naming").
    pub category: String,
    /// Human-readable description.
    pub description: String,
    /// How many times this pattern has been observed.
    pub frequency: u32,
    /// ISO-8601 timestamp of the last observation.
    pub last_seen: String,
}

// ---------------------------------------------------------------------------
// Security-sensitive patterns
// ---------------------------------------------------------------------------

/// Path substrings that indicate security sensitivity.
const SENSITIVE_PATH_PATTERNS: &[&str] = &[
    "auth",
    "crypto",
    "inject",
    "session",
    "token",
    "password",
    "passwd",
    "key",
    "secret",
    "permission",
    "credential",
    "oauth",
    "jwt",
    "saml",
    "acl",
    "rbac",
    "cert",
    "tls",
    "ssl",
    "encrypt",
    "decrypt",
    "hash",
    "sign",
    "verify",
    "sanitize",
    "escape",
    "xss",
    "csrf",
    "cors",
    "firewall",
    "policy",
];

/// Symbol substrings that indicate security sensitivity.
const SENSITIVE_SYMBOL_PATTERNS: &[&str] = &[
    "auth",
    "login",
    "logout",
    "password",
    "passwd",
    "token",
    "secret",
    "key",
    "encrypt",
    "decrypt",
    "hash",
    "sign",
    "verify",
    "session",
    "credential",
    "permission",
    "authorize",
    "authenticate",
    "sanitize",
    "escape",
    "validate_input",
    "check_access",
];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Estimate the token count of a text string.
///
/// Uses a simple heuristic: ASCII characters count as ~0.25 tokens each
/// (i.e. 4 chars per token), while non-ASCII characters count as ~0.67
/// tokens each (i.e. 1.5 chars per token). The result is rounded up.
pub fn estimate_tokens(text: &str) -> u32 {
    let mut ascii_chars: u32 = 0;
    let mut non_ascii_chars: u32 = 0;

    for ch in text.chars() {
        if ch.is_ascii() {
            ascii_chars += 1;
        } else {
            non_ascii_chars += 1;
        }
    }

    // ASCII: chars / 4, non-ASCII: chars / 1.5
    let ascii_tokens = (ascii_chars as f64) / 4.0;
    let non_ascii_tokens = (non_ascii_chars as f64) / 1.5;

    (ascii_tokens + non_ascii_tokens).ceil() as u32
}

/// Truncate text to fit within a token budget.
///
/// Removes characters from the end until the estimated token count is
/// within budget. Appends `"…"` if truncation occurred.
pub fn truncate_to_budget(text: &str, budget: u32) -> String {
    if estimate_tokens(text) <= budget {
        return text.to_string();
    }

    // Binary search for the right cutoff point
    let chars: Vec<char> = text.chars().collect();
    let mut lo: usize = 0;
    let mut hi: usize = chars.len();

    while lo < hi {
        let mid = (lo + hi) / 2;
        let candidate: String = chars[..mid].iter().collect();
        // Reserve 1 token for the ellipsis
        if estimate_tokens(&candidate) <= budget.saturating_sub(1) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    let cutoff = if lo > 0 { lo - 1 } else { 0 };
    let truncated: String = chars[..cutoff].iter().collect();
    format!("{truncated}\u{2026}")
}

/// Build a capsule from a plan and a list of changed files.
///
/// The capsule is constrained to `budget` tokens (fail-closed if
/// the serialized form exceeds [`MAX_CAPSULE_TOKENS`]).
pub fn build_capsule(plan_path: &Path, changed_files: &[String], budget: u32) -> Result<Capsule> {
    let plan_content = fs::read_to_string(plan_path)
        .map_err(|e| AgentError::NotFound(format!("plan file {}: {e}", plan_path.display())))?;

    let task_id = extract_task_id(&plan_content, plan_path);
    let constraints = extract_constraints(&plan_content);
    let security_pins = collect_security_pins(changed_files);

    // Build scope summary from plan, truncated to body budget
    let raw_summary = build_scope_summary(&plan_content, changed_files);
    let body_budget = budget
        .saturating_sub(CAPSULE_META_BUDGET)
        .min(CAPSULE_BODY_BUDGET);
    let scope_summary = truncate_to_budget(&raw_summary, body_budget);

    let mut capsule = Capsule {
        task_id,
        plan_path: plan_path.to_string_lossy().to_string(),
        changed_files: changed_files.to_vec(),
        scope_summary,
        security_pins,
        constraints,
        file_sha_rollup: String::new(),
        index_version: 0,
        sha256: String::new(),
        token_count: 0,
    };

    capsule.sha256 = capsule_sha256(&capsule);
    capsule.token_count = estimate_capsule_tokens(&capsule);

    validate_capsule_size(&capsule)?;

    Ok(capsule)
}

/// Build a capsule using tree-sitter impact analysis and the capsule cache.
///
/// The cache key is `SHA256(plan + changed_files + symbols_digest + freshness)`.
/// On a hit, the cached capsule is returned immediately and its LRU timestamp
/// is updated.
pub fn build_capsule_with_symbols(
    plan_path: &Path,
    changed_files: &[String],
    budget: u32,
    db_path: &Path,
    project_id: &str,
    mut cache: Option<&mut CacheManager>,
) -> Result<Capsule> {
    let plan_content = fs::read_to_string(plan_path)
        .map_err(|e| AgentError::NotFound(format!("plan file {}: {e}", plan_path.display())))?;

    let changed_refs: Vec<&str> = changed_files.iter().map(String::as_str).collect();
    let impact = tree_sitter_index::impact_analysis_at_path(
        &db_path.to_string_lossy(),
        project_id,
        &changed_refs,
        3,
        256,
    )?;
    let repo_root = resolve_repo_root()?;
    let conn = open_semantic_db(db_path)?;
    let freshness = freshness_snapshot(&conn, project_id, &repo_root, changed_files)
        .map_err(|e| AgentError::Database(format!("freshness snapshot failed for capsule: {e}")))?;

    let mut symbol_signatures: Vec<String> = impact
        .changed_symbols
        .iter()
        .chain(impact.affected_symbols.iter())
        .map(|symbol| {
            symbol
                .signature
                .clone()
                .or_else(|| symbol.qualified_name.clone())
                .unwrap_or_else(|| symbol.name.clone())
        })
        .filter(|value| !value.trim().is_empty())
        .collect();
    symbol_signatures.sort();
    symbol_signatures.dedup();

    let symbols_digest = {
        let mut hasher = Sha256::new();
        for signature in &symbol_signatures {
            hasher.update(signature.as_bytes());
        }
        hex::encode(hasher.finalize())
    };

    let context_hash = capsule_cache_key(
        &plan_content,
        changed_files,
        &symbols_digest,
        &freshness.file_sha_rollup,
        freshness.index_version,
    );

    if let Some(cache) = cache.as_deref_mut() {
        if let Some(hit) = cache.check_capsule(&context_hash) {
            let _ = cache.touch_capsule(&context_hash);
            match serde_json::from_str::<Capsule>(&hit.json) {
                Ok(capsule) => return Ok(capsule),
                Err(e) => {
                    tracing::warn!(error = %e, "cached capsule payload invalid; rebuilding");
                }
            }
        }
    }

    let task_id = extract_task_id(&plan_content, plan_path);
    let constraints = extract_constraints(&plan_content);
    let security_pins = collect_security_pins(changed_files);
    let raw_summary = if symbol_signatures.is_empty() {
        build_scope_summary(&plan_content, changed_files)
    } else {
        format!("Impacted symbols: {}", symbol_signatures.join(" ; "))
    };
    let body_budget = budget
        .saturating_sub(CAPSULE_META_BUDGET)
        .min(CAPSULE_BODY_BUDGET);
    let scope_summary = truncate_to_budget(&raw_summary, body_budget);

    let mut capsule = Capsule {
        task_id,
        plan_path: plan_path.to_string_lossy().to_string(),
        changed_files: changed_files.to_vec(),
        scope_summary,
        security_pins,
        constraints,
        file_sha_rollup: freshness.file_sha_rollup,
        index_version: freshness.index_version,
        sha256: String::new(),
        token_count: 0,
    };

    capsule.sha256 = capsule_sha256(&capsule);
    capsule.token_count = estimate_capsule_tokens(&capsule);
    validate_capsule_size(&capsule)?;

    if let Some(cache) = cache {
        match serde_json::to_string(&capsule) {
            Ok(json) => {
                if let Err(e) =
                    cache.store_capsule(&context_hash, &json, &capsule.sha256, capsule.token_count)
                {
                    tracing::warn!(error = %e, "failed to store capsule cache entry");
                }
            }
            Err(e) => {
                tracing::warn!(error = %e, "failed to serialize capsule for cache");
            }
        }
    }

    Ok(capsule)
}

/// Validate that a capsule's token count does not exceed [`MAX_CAPSULE_TOKENS`].
///
/// Returns an error (fail-closed / BLOCK) if the limit is exceeded.
pub fn validate_capsule_size(capsule: &Capsule) -> Result<()> {
    let tokens = estimate_capsule_tokens(capsule);
    if tokens > MAX_CAPSULE_TOKENS {
        return Err(AgentError::Validation(format!(
            "BLOCK: capsule exceeds {MAX_CAPSULE_TOKENS} token limit \
             (estimated {tokens} tokens)"
        )));
    }
    Ok(())
}

/// Compute the SHA-256 hex digest of a capsule's content fields.
///
/// The digest covers `task_id`, `plan_path`, `changed_files`,
/// `scope_summary`, and `constraints` — but not `sha256` or `token_count`
/// themselves (to avoid circularity).
pub fn capsule_sha256(capsule: &Capsule) -> String {
    let mut hasher = Sha256::new();
    hasher.update(capsule.task_id.as_bytes());
    hasher.update(capsule.plan_path.as_bytes());
    for f in &capsule.changed_files {
        hasher.update(f.as_bytes());
    }
    hasher.update(capsule.scope_summary.as_bytes());
    for c in &capsule.constraints {
        hasher.update(c.as_bytes());
    }
    hasher.update(capsule.file_sha_rollup.as_bytes());
    for pin in &capsule.security_pins {
        hasher.update(pin.file.as_bytes());
        hasher.update(pin.symbol.as_bytes());
        hasher.update(pin.pin_type.as_bytes());
    }
    hex::encode(hasher.finalize())
}

fn resolve_repo_root() -> Result<PathBuf> {
    shared::git::git_repo_root().or_else(|_| std::env::current_dir().map_err(AgentError::Io))
}

fn open_semantic_db(db_path: &Path) -> Result<rusqlite::Connection> {
    let conn = rusqlite::Connection::open(db_path)
        .map_err(|e| AgentError::Database(format!("open semantic db failed: {e}")))?;
    conn.pragma_update(None, "busy_timeout", 30000)
        .map_err(|e| AgentError::Database(format!("set semantic db busy_timeout failed: {e}")))?;
    Ok(conn)
}

/// Check whether a file path touches security-sensitive areas.
pub fn is_security_sensitive_path(path: &str) -> bool {
    let lower = path.to_lowercase();
    SENSITIVE_PATH_PATTERNS
        .iter()
        .any(|pat| lower.contains(pat))
}

/// Check whether a symbol name is security-sensitive.
pub fn is_security_sensitive_symbol(symbol: &str) -> bool {
    let lower = symbol.to_lowercase();
    SENSITIVE_SYMBOL_PATTERNS
        .iter()
        .any(|pat| lower.contains(pat))
}

/// Collect security pins for all files that match sensitive-path patterns.
///
/// For each sensitive file, emits a pin with the matching pattern as
/// the symbol and the classification as the pin type.
pub fn collect_security_pins(files: &[String]) -> Vec<SecurityPin> {
    let mut pins = Vec::new();

    for file in files {
        if !is_security_sensitive_path(file) {
            let file_stem = Path::new(file)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .map(str::to_lowercase);
            if let Some(stem) = file_stem
                .as_deref()
                .filter(|stem| is_security_sensitive_symbol(stem))
            {
                if let Some(pattern) = SENSITIVE_SYMBOL_PATTERNS
                    .iter()
                    .find(|pattern| stem.contains(**pattern))
                {
                    pins.push(SecurityPin {
                        file: file.clone(),
                        symbol: (*pattern).to_string(),
                        pin_type: classify_security_pattern(pattern),
                    });
                }
            }
            continue;
        }

        let lower = file.to_lowercase();
        for &pattern in SENSITIVE_PATH_PATTERNS {
            if lower.contains(pattern) {
                let pin_type = classify_security_pattern(pattern);
                pins.push(SecurityPin {
                    file: file.clone(),
                    symbol: pattern.to_string(),
                    pin_type,
                });
                // One pin per matching pattern per file
            }
        }
    }

    pins
}

/// Append a review pattern to a JSONL memory file.
///
/// If a pattern with the same `pattern_id` already exists, its frequency
/// is incremented and `last_seen` is updated. Otherwise a new line is
/// appended.
pub fn record_review_pattern(memory_file: &Path, pattern: ReviewPattern) -> Result<()> {
    // Read existing patterns
    let mut patterns = read_jsonl_patterns(memory_file)?;

    // Check for existing pattern with same ID
    let mut found = false;
    for existing in &mut patterns {
        if existing.pattern_id == pattern.pattern_id {
            existing.frequency += 1;
            existing.last_seen = pattern.last_seen.clone();
            found = true;
            break;
        }
    }

    if !found {
        patterns.push(pattern);
    }

    // Write back atomically
    write_jsonl_patterns(memory_file, &patterns)?;

    Ok(())
}

/// Read the top-N patterns from a JSONL memory file, sorted by frequency
/// descending.
pub fn get_top_patterns(memory_file: &Path, count: usize) -> Result<Vec<ReviewPattern>> {
    let mut patterns = read_jsonl_patterns(memory_file)?;
    patterns.sort_by_key(|pattern| std::cmp::Reverse(pattern.frequency));
    patterns.truncate(count);
    Ok(patterns)
}

/// Escape a capsule value: strip control characters and truncate to 240 chars.
pub fn escape_capsule_value(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect();

    if cleaned.chars().count() <= MAX_ESCAPED_LEN {
        cleaned
    } else {
        let truncated: String = cleaned.chars().take(MAX_ESCAPED_LEN).collect();
        truncated
    }
}

/// Entry point — dispatch a [`CapsuleAction`] subcommand.
///
/// This is the main entry called from `main.rs`.
pub fn run(action: CapsuleAction) -> Result<()> {
    execute(action)
}

/// Dispatch a [`CapsuleAction`] subcommand.
pub fn execute(action: CapsuleAction) -> Result<()> {
    match action {
        CapsuleAction::Build {
            plan,
            output,
            budget,
        } => {
            let plan_path = std::path::Path::new(&plan);

            // Collect changed files via git
            let changed = shared::git::git_changed_files().unwrap_or_default();

            let capsule = build_capsule(plan_path, &changed, budget)?;
            write_json_atomic(std::path::Path::new(&output), &capsule)?;
            tracing::info!(
                output = %output,
                tokens = capsule.token_count,
                sha256 = %capsule.sha256,
                "capsule built"
            );
            Ok(())
        }

        CapsuleAction::EstimateTokens { input } => {
            let text = fs::read_to_string(&input)
                .map_err(|e| AgentError::NotFound(format!("{input}: {e}")))?;
            let tokens = estimate_tokens(&text);
            println!("{tokens}");
            Ok(())
        }

        CapsuleAction::SecurityCheck { files } => {
            let pins = collect_security_pins(&files);
            let json = serde_json::to_string_pretty(&pins)?;
            println!("{json}");
            Ok(())
        }

        CapsuleAction::RecordPattern {
            category,
            description,
            severity: _,
        } => {
            let repo_root = shared::git::git_repo_root()?;
            let memory_file = repo_root.join(".agent/context/review_patterns.jsonl");

            let pattern_id = format!("{}-{}", category, &uuid::Uuid::new_v4().to_string()[..8]);

            let pattern = ReviewPattern {
                pattern_id,
                category,
                description,
                frequency: 1,
                last_seen: chrono::Utc::now().to_rfc3339(),
            };

            record_review_pattern(&memory_file, pattern)?;
            tracing::info!(memory_file = %memory_file.display(), "pattern recorded");
            Ok(())
        }

        CapsuleAction::TopPatterns { count } => {
            let repo_root = shared::git::git_repo_root()?;
            let memory_file = repo_root.join(".agent/context/review_patterns.jsonl");

            let patterns = get_top_patterns(&memory_file, count)?;
            let json = serde_json::to_string_pretty(&patterns)?;
            println!("{json}");
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Estimate total tokens for a serialized capsule.
fn estimate_capsule_tokens(capsule: &Capsule) -> u32 {
    // Estimate from the key content fields, not the JSON envelope
    let mut text = String::new();
    text.push_str(&capsule.task_id);
    text.push_str(&capsule.scope_summary);
    for f in &capsule.changed_files {
        text.push_str(f);
    }
    for c in &capsule.constraints {
        text.push_str(c);
    }
    for pin in &capsule.security_pins {
        text.push_str(&pin.file);
        text.push_str(&pin.symbol);
        text.push_str(&pin.pin_type);
    }

    let body_tokens = estimate_tokens(&text);
    // Add meta overhead for JSON framing
    let meta_tokens = CAPSULE_META_BUDGET.min(20);

    body_tokens + meta_tokens
}

/// Extract a task ID from plan content or derive from the file path.
fn extract_task_id(plan_content: &str, plan_path: &Path) -> String {
    // Try to find a task ID in the plan
    for line in plan_content.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("task_id:") {
            let id = rest.trim().trim_matches('"').trim();
            if !id.is_empty() {
                return id.to_string();
            }
        }
        if let Some(rest) = trimmed.strip_prefix("- task_id:") {
            let id = rest.trim().trim_matches('"').trim();
            if !id.is_empty() {
                return id.to_string();
            }
        }
    }

    // Fallback: derive from filename
    plan_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string()
}

/// Extract constraints from plan content.
fn extract_constraints(plan_content: &str) -> Vec<String> {
    let mut constraints = Vec::new();
    let mut in_constraints = false;

    for line in plan_content.lines() {
        let trimmed = line.trim();

        if trimmed.to_lowercase().contains("constraint")
            || trimmed.to_lowercase().contains("requirement")
        {
            in_constraints = true;
            continue;
        }

        if in_constraints {
            if trimmed.starts_with("- ") || trimmed.starts_with("* ") {
                let c = trimmed[2..].trim().to_string();
                if !c.is_empty() {
                    constraints.push(escape_capsule_value(&c));
                }
            } else if trimmed.starts_with('#') || trimmed.is_empty() {
                in_constraints = false;
            }
        }
    }

    constraints
}

/// Build a scope summary from plan content and changed files.
fn build_scope_summary(plan_content: &str, changed_files: &[String]) -> String {
    let mut summary = String::new();

    // Extract title/first heading from plan
    for line in plan_content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("# ") {
            summary.push_str(trimmed.strip_prefix("# ").unwrap_or(trimmed));
            summary.push('\n');
            break;
        }
    }

    // Add file count
    summary.push_str(&format!("Changed files: {}\n", changed_files.len()));

    // List files (abbreviated)
    let max_files = 10;
    for (i, file) in changed_files.iter().enumerate() {
        if i >= max_files {
            summary.push_str(&format!(
                "... and {} more\n",
                changed_files.len() - max_files
            ));
            break;
        }
        summary.push_str(&format!("- {file}\n"));
    }

    summary
}

/// Classify a security pattern into a broad category.
fn classify_security_pattern(pattern: &str) -> String {
    match pattern {
        "auth" | "authenticate" | "authorize" | "login" | "logout" | "oauth" | "saml" | "jwt" => {
            "auth".to_string()
        }
        "crypto" | "encrypt" | "decrypt" | "hash" | "sign" | "cert" | "tls" | "ssl" => {
            "crypto".to_string()
        }
        "inject" | "sanitize" | "escape" | "xss" | "csrf" | "cors" => "injection".to_string(),
        "token" | "secret" | "key" | "password" | "passwd" | "credential" => "secret".to_string(),
        "session" => "session".to_string(),
        "permission" | "acl" | "rbac" | "policy" | "firewall" => "access-control".to_string(),
        "verify" | "validate_input" | "check_access" => "validation".to_string(),
        _ => "general".to_string(),
    }
}

/// Read JSONL patterns from a file. Returns empty vec if file does not exist.
fn read_jsonl_patterns(path: &Path) -> Result<Vec<ReviewPattern>> {
    if !path.exists() {
        return Ok(Vec::new());
    }

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut patterns = Vec::new();

    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<ReviewPattern>(trimmed) {
            Ok(p) => patterns.push(p),
            Err(e) => {
                tracing::warn!(
                    line = trimmed,
                    error = %e,
                    "skipping malformed JSONL line"
                );
            }
        }
    }

    Ok(patterns)
}

/// Atomically write patterns as JSONL.
fn write_jsonl_patterns(path: &Path, patterns: &[ReviewPattern]) -> Result<()> {
    use tempfile::NamedTempFile;

    let parent = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;

    let mut tmp = NamedTempFile::new_in(parent)?;

    for pattern in patterns {
        let line = serde_json::to_string(pattern)?;
        writeln!(tmp, "{line}")?;
    }

    tmp.as_file().flush()?;
    tmp.persist(path).map_err(|e| e.error)?;

    Ok(())
}

/// Atomically write JSON to a file.
fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    use tempfile::NamedTempFile;

    let json = serde_json::to_string_pretty(value)?;

    let parent = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;

    let mut tmp = NamedTempFile::new_in(parent)?;
    tmp.write_all(json.as_bytes())?;
    tmp.persist(path).map_err(|e| e.error)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- estimate_tokens -------------------------------------------------------

    #[test]
    fn estimate_tokens_empty() {
        assert_eq!(estimate_tokens(""), 0);
    }

    #[test]
    fn estimate_tokens_ascii_only() {
        // 8 ASCII chars / 4 = 2 tokens
        assert_eq!(estimate_tokens("abcdefgh"), 2);
    }

    #[test]
    fn estimate_tokens_rounds_up() {
        // 5 ASCII chars / 4 = 1.25 → ceil = 2
        assert_eq!(estimate_tokens("hello"), 2);
    }

    #[test]
    fn estimate_tokens_non_ascii() {
        // 3 non-ASCII chars / 1.5 = 2 tokens
        assert_eq!(estimate_tokens("あいう"), 2);
    }

    #[test]
    fn estimate_tokens_mixed() {
        // "hello" = 5 ASCII / 4 = 1.25
        // "世界" = 2 non-ASCII / 1.5 ≈ 1.33
        // total = 2.58 → ceil = 3
        assert_eq!(estimate_tokens("hello世界"), 3);
    }

    // -- is_security_sensitive_path --------------------------------------------

    #[test]
    fn sensitive_path_auth() {
        assert!(is_security_sensitive_path("src/auth/login.rs"));
        assert!(is_security_sensitive_path("lib/oauth_handler.py"));
    }

    #[test]
    fn sensitive_path_crypto() {
        assert!(is_security_sensitive_path("crypto/aes.rs"));
        assert!(is_security_sensitive_path("utils/encrypt.ts"));
    }

    #[test]
    fn sensitive_path_secrets() {
        assert!(is_security_sensitive_path("config/secret.yaml"));
        assert!(is_security_sensitive_path("src/password_manager.rs"));
        assert!(is_security_sensitive_path("lib/token_store.ts"));
    }

    #[test]
    fn sensitive_path_injection() {
        assert!(is_security_sensitive_path("security/sanitize.rs"));
        assert!(is_security_sensitive_path("middleware/csrf_guard.py"));
    }

    #[test]
    fn non_sensitive_path() {
        assert!(!is_security_sensitive_path("src/main.rs"));
        assert!(!is_security_sensitive_path("lib/utils.ts"));
        assert!(!is_security_sensitive_path("tests/unit_test.py"));
    }

    // -- is_security_sensitive_symbol ------------------------------------------

    #[test]
    fn sensitive_symbol() {
        assert!(is_security_sensitive_symbol("authenticate_user"));
        assert!(is_security_sensitive_symbol("verify_token"));
        assert!(is_security_sensitive_symbol("encrypt_data"));
        assert!(is_security_sensitive_symbol("check_access"));
    }

    #[test]
    fn non_sensitive_symbol() {
        assert!(!is_security_sensitive_symbol("process_data"));
        assert!(!is_security_sensitive_symbol("render_page"));
        assert!(!is_security_sensitive_symbol("calculate_total"));
    }

    // -- truncate_to_budget ----------------------------------------------------

    #[test]
    fn truncate_no_op_when_within_budget() {
        let text = "short";
        assert_eq!(truncate_to_budget(text, 10), "short");
    }

    #[test]
    fn truncate_long_text() {
        // Create a string that exceeds 5 tokens (20+ ASCII chars)
        let text = "a".repeat(100); // 100/4 = 25 tokens
        let result = truncate_to_budget(&text, 5);
        assert!(result.ends_with('\u{2026}')); // ends with ellipsis
        assert!(estimate_tokens(&result) <= 5 + 1); // within budget + ellipsis tolerance
    }

    #[test]
    fn truncate_exact_budget() {
        let text = "abcd"; // 4 chars / 4 = 1 token
        assert_eq!(truncate_to_budget(text, 1), "abcd");
    }

    // -- escape_capsule_value --------------------------------------------------

    #[test]
    fn escape_preserves_normal_text() {
        assert_eq!(escape_capsule_value("hello world"), "hello world");
    }

    #[test]
    fn escape_strips_control_chars() {
        let input = "hello\x00world\x01!";
        let result = escape_capsule_value(input);
        assert_eq!(result, "helloworld!");
    }

    #[test]
    fn escape_preserves_newlines_and_tabs() {
        let input = "line1\nline2\ttab";
        assert_eq!(escape_capsule_value(input), "line1\nline2\ttab");
    }

    #[test]
    fn escape_truncates_long_values() {
        let long = "x".repeat(300);
        let result = escape_capsule_value(&long);
        assert_eq!(result.len(), MAX_ESCAPED_LEN);
    }

    // -- collect_security_pins -------------------------------------------------

    #[test]
    fn collect_pins_from_sensitive_files() {
        let files = vec![
            "src/auth/login.rs".to_string(),
            "src/main.rs".to_string(),
            "lib/crypto/aes.rs".to_string(),
        ];
        let pins = collect_security_pins(&files);
        assert!(!pins.is_empty());
        // auth file should produce at least one pin
        assert!(pins.iter().any(|p| p.file == "src/auth/login.rs"));
        // main.rs should not produce pins
        assert!(!pins.iter().any(|p| p.file == "src/main.rs"));
    }

    // -- capsule_sha256 --------------------------------------------------------

    #[test]
    fn capsule_sha256_deterministic() {
        let capsule = Capsule {
            task_id: "test-123".into(),
            plan_path: "plan.md".into(),
            changed_files: vec!["a.rs".into()],
            scope_summary: "test".into(),
            security_pins: vec![],
            constraints: vec![],
            file_sha_rollup: "rollup-1".into(),
            index_version: 7,
            sha256: String::new(),
            token_count: 0,
        };

        let hash1 = capsule_sha256(&capsule);
        let hash2 = capsule_sha256(&capsule);
        assert_eq!(hash1, hash2);
        assert_eq!(hash1.len(), 64); // SHA-256 hex = 64 chars
    }

    // -- record and read patterns -----------------------------------------------

    #[test]
    fn record_and_read_patterns() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("patterns.jsonl");

        let p1 = ReviewPattern {
            pattern_id: "p1".into(),
            category: "naming".into(),
            description: "Use snake_case".into(),
            frequency: 1,
            last_seen: "2025-01-01T00:00:00Z".into(),
        };

        record_review_pattern(&file, p1.clone()).unwrap();

        let patterns = get_top_patterns(&file, 10).unwrap();
        assert_eq!(patterns.len(), 1);
        assert_eq!(patterns[0].pattern_id, "p1");
        assert_eq!(patterns[0].frequency, 1);

        // Record same pattern again — frequency should increment
        let p1_again = ReviewPattern {
            pattern_id: "p1".into(),
            category: "naming".into(),
            description: "Use snake_case".into(),
            frequency: 1,
            last_seen: "2025-01-02T00:00:00Z".into(),
        };

        record_review_pattern(&file, p1_again).unwrap();
        let patterns = get_top_patterns(&file, 10).unwrap();
        assert_eq!(patterns.len(), 1);
        assert_eq!(patterns[0].frequency, 2);
        assert_eq!(patterns[0].last_seen, "2025-01-02T00:00:00Z");
    }

    #[test]
    fn top_patterns_sorted_by_frequency() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("patterns.jsonl");

        let patterns = vec![
            ReviewPattern {
                pattern_id: "low".into(),
                category: "style".into(),
                description: "Low freq".into(),
                frequency: 1,
                last_seen: "2025-01-01T00:00:00Z".into(),
            },
            ReviewPattern {
                pattern_id: "high".into(),
                category: "error".into(),
                description: "High freq".into(),
                frequency: 10,
                last_seen: "2025-01-01T00:00:00Z".into(),
            },
            ReviewPattern {
                pattern_id: "mid".into(),
                category: "naming".into(),
                description: "Mid freq".into(),
                frequency: 5,
                last_seen: "2025-01-01T00:00:00Z".into(),
            },
        ];

        write_jsonl_patterns(&file, &patterns).unwrap();

        let top = get_top_patterns(&file, 2).unwrap();
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].pattern_id, "high");
        assert_eq!(top[1].pattern_id, "mid");
    }

    // -- extract_task_id -------------------------------------------------------

    #[test]
    fn extract_task_id_from_plan() {
        let content = "# My Plan\ntask_id: my-task-42\nsome other stuff";
        let id = extract_task_id(content, Path::new("plan.md"));
        assert_eq!(id, "my-task-42");
    }

    #[test]
    fn extract_task_id_fallback_to_filename() {
        let content = "# My Plan\nno task id here";
        let id = extract_task_id(content, Path::new("plan_20250101_feat-foo.md"));
        assert_eq!(id, "plan_20250101_feat-foo");
    }
}
