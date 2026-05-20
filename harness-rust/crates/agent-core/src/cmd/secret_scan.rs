//! Secret scan implementation for agent-core.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use clap::{ArgGroup, ValueEnum};
use regex::Regex;
use serde::Serialize;
use sha2::{Digest, Sha256};
use shared::error::{AgentError, Result};

const DEFAULT_ALLOWLIST: &str = ".harness-secret-allowlist";
const ZERO_OID: &str = "0000000000000000000000000000000000000000";
const FINGERPRINT_PREFIX: &str = "revharness-secret-v1\0";

#[derive(clap::Args, Debug)]
#[command(group(
    ArgGroup::new("scan_mode")
        .required(true)
        .multiple(false)
        .args(["staged_only", "ref_range", "files", "hook_stdin"]),
))]
pub struct ScanArgs {
    /// Scan staged added lines from git diff --cached.
    #[arg(long)]
    pub staged_only: bool,
    /// Scan patches for commits in the given git revision range.
    #[arg(long = "ref", value_name = "range")]
    pub ref_range: Option<String>,
    /// Scan the complete content of specific files.
    #[arg(long, num_args = 1.., value_name = "paths")]
    pub files: Vec<PathBuf>,
    /// Parse a git hook stdin format.
    #[arg(long, value_enum)]
    pub hook_stdin: Option<HookStdinMode>,
    /// Remote name used for pre-push new-branch range calculation.
    #[arg(long, default_value = "origin", hide = true)]
    pub remote: String,
    /// Allowlist file path. Defaults to .harness-secret-allowlist at repo root.
    #[arg(long)]
    pub allowlist: Option<PathBuf>,
    /// Emit stable JSON schema v1.
    #[arg(long)]
    pub json: bool,
}

#[derive(Clone, Debug, ValueEnum)]
pub enum HookStdinMode {
    PrePush,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, Copy)]
enum PatternKind {
    Path,
    Content,
}

#[derive(Debug, Clone, Copy)]
struct PatternSpec {
    id: &'static str,
    regex: &'static str,
    severity: Severity,
    kind: PatternKind,
}

const PATH_PATTERNS: &[PatternSpec] = &[
    PatternSpec {
        id: "path-env-file",
        regex: r"(?i)(^|/)\.env(\.[a-z0-9]+)?$",
        severity: Severity::Error,
        kind: PatternKind::Path,
    },
    PatternSpec {
        id: "path-private-key-file",
        regex: r"(?i)(^|/)(.*\.pem|.*\.key|id_(rsa|dsa|ecdsa|ed25519))$",
        severity: Severity::Error,
        kind: PatternKind::Path,
    },
    PatternSpec {
        id: "path-keystore-file",
        regex: r"(?i)(^|/).*\.(p12|pfx|jks|keystore)$",
        severity: Severity::Error,
        kind: PatternKind::Path,
    },
    PatternSpec {
        id: "path-credentials-file",
        regex: r"(?i)(^|/)(credentials|secrets)(\.json)?$",
        severity: Severity::Error,
        kind: PatternKind::Path,
    },
];

const CONTENT_PATTERNS: &[PatternSpec] = &[
    PatternSpec {
        id: "aws-access-key",
        regex: r"AKIA[0-9A-Z]{16}",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "github-pat",
        regex: r"ghp_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{82}",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "npm-token",
        regex: r"npm_[a-zA-Z0-9]{36}",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "private-key-block",
        regex: r"-----BEGIN (RSA |DSA |EC |OPENSSH |)PRIVATE KEY-----",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "anthropic-api-key",
        regex: r"sk-ant-[a-zA-Z0-9_-]{32,}",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "openai-api-key",
        regex: r"sk-[a-zA-Z0-9]{48}|sk-proj-[a-zA-Z0-9_-]{40,}",
        severity: Severity::Error,
        kind: PatternKind::Content,
    },
    PatternSpec {
        id: "generic-secret-assignment",
        regex: r#"(?i)^\s*[A-Z_][A-Z0-9_]*(API_KEY|SECRET|TOKEN|PASSWORD)\s*[:=]\s*['"]?[A-Za-z0-9_+/=-]{20,}"#,
        severity: Severity::Warning,
        kind: PatternKind::Content,
    },
];

#[derive(Debug)]
struct CompiledPattern {
    spec: PatternSpec,
    regex: Regex,
}

#[derive(Debug, Serialize)]
struct ScanOutput {
    schema_version: u8,
    scan_mode: String,
    scanned_files: usize,
    findings: Vec<Finding>,
    suppressed_count: usize,
    tool_errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct Finding {
    fingerprint: String,
    path: String,
    line: usize,
    pattern_id: String,
    severity: Severity,
    redacted_preview: String,
    suppressed: bool,
}

#[derive(Default)]
struct ScanState {
    findings: Vec<Finding>,
    scanned_paths: HashSet<String>,
    tool_errors: Vec<String>,
}

#[derive(Default)]
struct Allowlist {
    entries: HashSet<String>,
    collisions: HashSet<String>,
    fatal_errors: Vec<String>,
}

pub fn run_scan_cli(args: ScanArgs) -> Result<i32> {
    let repo_root = repo_root()?;
    let allowlist = load_allowlist(args.allowlist.as_deref(), &repo_root)?;
    let mut state = ScanState::default();
    state.tool_errors.extend(allowlist.fatal_errors.clone());
    state
        .tool_errors
        .extend(allowlist.collisions.iter().map(|fingerprint| {
            format!("allowlist collision for fingerprint {fingerprint}: suppression disabled")
        }));

    let scan_mode = if args.staged_only {
        scan_staged(&repo_root, &mut state)?;
        "staged"
    } else if let Some(range) = args.ref_range.as_deref() {
        scan_ref_range(&repo_root, range, &mut state)?;
        "ref-range"
    } else if !args.files.is_empty() {
        scan_files(&repo_root, &args.files, &mut state)?;
        "files"
    } else if matches!(args.hook_stdin, Some(HookStdinMode::PrePush)) {
        scan_pre_push_stdin(&repo_root, &args.remote, &mut state)?;
        "ref-range"
    } else {
        return Err(AgentError::Validation("scan mode is required".to_string()));
    };

    apply_allowlist(&mut state.findings, &allowlist);
    let suppressed_count = state
        .findings
        .iter()
        .filter(|finding| finding.suppressed)
        .count();
    let output = ScanOutput {
        schema_version: 1,
        scan_mode: scan_mode.to_string(),
        scanned_files: state.scanned_paths.len(),
        findings: state.findings,
        suppressed_count,
        tool_errors: state.tool_errors,
    };

    render_output(&output, args.json)?;
    Ok(exit_code(&output, !allowlist.fatal_errors.is_empty()))
}

fn repo_root() -> Result<PathBuf> {
    match shared::git::git_repo_root() {
        Ok(root) => Ok(root),
        Err(_) => std::env::current_dir().map_err(AgentError::Io),
    }
}

fn compiled_path_patterns() -> &'static [CompiledPattern] {
    static PATTERNS: OnceLock<Vec<CompiledPattern>> = OnceLock::new();
    PATTERNS.get_or_init(|| compile_patterns(PATH_PATTERNS))
}

fn compiled_content_patterns() -> &'static [CompiledPattern] {
    static PATTERNS: OnceLock<Vec<CompiledPattern>> = OnceLock::new();
    PATTERNS.get_or_init(|| compile_patterns(CONTENT_PATTERNS))
}

fn compile_patterns(specs: &[PatternSpec]) -> Vec<CompiledPattern> {
    specs
        .iter()
        .map(|spec| CompiledPattern {
            spec: *spec,
            regex: Regex::new(spec.regex).expect("valid secret regex"),
        })
        .collect()
}

fn scan_files(repo_root: &Path, paths: &[PathBuf], state: &mut ScanState) -> Result<()> {
    for input_path in paths {
        let full_path = normalize_input_path(input_path)?;
        let repo_path = repo_relative_path(repo_root, &full_path);
        scan_path_name(&repo_path, state);
        let content = fs::read_to_string(&full_path).map_err(|error| {
            AgentError::Io(io::Error::new(
                error.kind(),
                format!("cannot read '{}': {error}", display_path(&repo_path)),
            ))
        })?;
        state.scanned_paths.insert(repo_path.clone());
        for (idx, line) in content.lines().enumerate() {
            scan_line(&repo_path, idx + 1, line, state);
        }
    }
    Ok(())
}

fn scan_staged(repo_root: &Path, state: &mut ScanState) -> Result<()> {
    let names = git_output(repo_root, &["diff", "--cached", "--name-only", "-z"])?;
    for path in split_nul_paths(&names) {
        scan_path_name(&path, state);
        state.scanned_paths.insert(path);
    }
    let patch = git_output(
        repo_root,
        &["diff", "--cached", "--unified=0", "--no-color"],
    )?;
    scan_patch_text(&patch, state);
    Ok(())
}

fn scan_ref_range(repo_root: &Path, range: &str, state: &mut ScanState) -> Result<()> {
    for oid in rev_list(repo_root, &[range])? {
        scan_commit(repo_root, &oid, state)?;
    }
    Ok(())
}

fn scan_pre_push_stdin(repo_root: &Path, remote: &str, state: &mut ScanState) -> Result<()> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(AgentError::Io)?;
    for line in input.lines().filter(|line| !line.trim().is_empty()) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() != 4 {
            return Err(AgentError::Validation(
                "invalid pre-push stdin line: expected 4 fields".to_string(),
            ));
        }
        let local_oid = fields[1];
        let remote_oid = fields[3];
        if local_oid == ZERO_OID {
            continue;
        }
        let commits = if remote_oid == ZERO_OID {
            rev_list(
                repo_root,
                &[local_oid, "--not", &format!("--remotes={remote}")],
            )?
        } else {
            rev_list(repo_root, &[&format!("{remote_oid}..{local_oid}")])?
        };
        for oid in commits {
            scan_commit(repo_root, &oid, state)?;
        }
    }
    Ok(())
}

fn scan_commit(repo_root: &Path, oid: &str, state: &mut ScanState) -> Result<()> {
    let patch = git_output(repo_root, &["show", "--pretty=", "--no-color", oid])?;
    scan_patch_text(&patch, state);
    Ok(())
}

fn rev_list(repo_root: &Path, args: &[&str]) -> Result<Vec<String>> {
    let mut git_args = vec!["rev-list"];
    git_args.extend_from_slice(args);
    let output = git_output(repo_root, &git_args)?;
    Ok(output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect())
}

fn scan_patch_text(patch: &str, state: &mut ScanState) {
    let mut current_path: Option<String> = None;
    let mut next_line: usize = 0;
    for line in patch.lines() {
        if let Some(path) = parse_patch_path(line) {
            scan_path_name(&path, state);
            state.scanned_paths.insert(path.clone());
            current_path = Some(path);
            continue;
        }
        if let Some(start) = parse_new_hunk_start(line) {
            next_line = start;
            continue;
        }
        if line.starts_with("+++") || line.starts_with("---") || line.starts_with("diff --git ") {
            continue;
        }
        if let Some(added) = line.strip_prefix('+') {
            if let Some(path) = current_path.as_deref() {
                scan_line(path, next_line, added, state);
            }
            next_line = next_line.saturating_add(1);
        } else if line.starts_with('-') || line.starts_with("\\ No newline") {
            continue;
        } else if current_path.is_some() && next_line > 0 {
            next_line = next_line.saturating_add(1);
        }
    }
}

fn parse_patch_path(line: &str) -> Option<String> {
    let path = line.strip_prefix("+++ ")?;
    if path == "/dev/null" {
        return None;
    }
    Some(path.strip_prefix("b/").unwrap_or(path).to_string())
}

fn parse_new_hunk_start(line: &str) -> Option<usize> {
    let header = line.strip_prefix("@@ ")?;
    let plus = header.find('+')?;
    let after_plus = &header[plus + 1..];
    let number = after_plus
        .split(|ch: char| !ch.is_ascii_digit())
        .next()
        .unwrap_or("");
    number.parse::<usize>().ok()
}

fn scan_path_name(path: &str, state: &mut ScanState) {
    if is_env_example_path(path) {
        return;
    }
    for pattern in compiled_path_patterns() {
        if pattern.regex.is_match(path) {
            state.findings.push(path_finding(path, pattern));
        }
    }
}

fn scan_line(path: &str, line_number: usize, line: &str, state: &mut ScanState) {
    for pattern in compiled_content_patterns() {
        debug_assert!(matches!(pattern.spec.kind, PatternKind::Content));
        for matched in pattern.regex.find_iter(line) {
            state.findings.push(content_finding(
                path,
                line_number,
                line,
                matched.as_str(),
                pattern,
            ));
        }
    }
}

fn path_finding(path: &str, pattern: &CompiledPattern) -> Finding {
    Finding {
        fingerprint: fingerprint(pattern.spec.id, path, "", 0),
        path: path.to_string(),
        line: 0,
        pattern_id: pattern.spec.id.to_string(),
        severity: pattern.spec.severity,
        redacted_preview: "file-level path match (len=0)".to_string(),
        suppressed: false,
    }
}

fn content_finding(
    path: &str,
    line_number: usize,
    line: &str,
    matched: &str,
    pattern: &CompiledPattern,
) -> Finding {
    let normalized = normalized_redacted_line(line, matched);
    Finding {
        fingerprint: fingerprint(pattern.spec.id, path, &normalized, matched.len()),
        path: path.to_string(),
        line: line_number,
        pattern_id: pattern.spec.id.to_string(),
        severity: pattern.spec.severity,
        redacted_preview: redacted_preview(matched),
        suppressed: false,
    }
}

fn fingerprint(pattern_id: &str, path: &str, normalized_line: &str, match_len: usize) -> String {
    let mut hasher = Sha256::new();
    hasher.update(FINGERPRINT_PREFIX.as_bytes());
    hasher.update(pattern_id.as_bytes());
    hasher.update(b"\0");
    hasher.update(path.as_bytes());
    hasher.update(b"\0");
    hasher.update(normalized_line.as_bytes());
    hasher.update(b"\0");
    hasher.update(match_length_class(match_len).as_bytes());
    let digest = hasher.finalize();
    hex::encode(digest)[..16].to_string()
}

fn match_length_class(len: usize) -> &'static str {
    match len {
        0..=31 => "<32",
        32..=64 => "32-64",
        65..=128 => "64-128",
        _ => ">128",
    }
}

fn normalized_redacted_line(line: &str, matched: &str) -> String {
    let marker = format!("[REDACTED:{}]", matched.len());
    compress_whitespace(&line.replacen(matched, &marker, 1))
}

fn compress_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn redacted_preview(secret: &str) -> String {
    let prefix: String = secret.chars().take(4).collect();
    let suffix_vec: Vec<char> = secret.chars().rev().take(4).collect();
    let suffix: String = suffix_vec.into_iter().rev().collect();
    format!("{prefix}****{suffix} (len={})", secret.len())
}

fn is_env_example_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".env.example")
        || lower.ends_with(".env.sample")
        || lower.ends_with(".env.template")
}

fn load_allowlist(path: Option<&Path>, repo_root: &Path) -> Result<Allowlist> {
    let allowlist_path = path
        .map(Path::to_path_buf)
        .unwrap_or_else(|| repo_root.join(DEFAULT_ALLOWLIST));
    if !allowlist_path.exists() {
        return Ok(Allowlist::default());
    }
    let content = fs::read_to_string(&allowlist_path).map_err(AgentError::Io)?;
    Ok(parse_allowlist(&content))
}

fn parse_allowlist(content: &str) -> Allowlist {
    let mut allowlist = Allowlist::default();
    let mut counts: HashMap<String, usize> = HashMap::new();
    for (idx, line) in content.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if line_contains_raw_secret(trimmed) {
            allowlist.fatal_errors.push(format!(
                "allowlist line {} rejected: raw secret-like value is not allowed",
                idx + 1
            ));
            continue;
        }
        let Some(captures) = allowlist_line_regex().captures(trimmed) else {
            allowlist
                .fatal_errors
                .push(format!("allowlist line {} is invalid", idx + 1));
            continue;
        };
        let fingerprint = captures[1].to_string();
        allowlist.entries.insert(fingerprint.clone());
        *counts.entry(fingerprint).or_insert(0) += 1;
    }
    for (fingerprint, count) in counts {
        if count > 1 {
            allowlist.collisions.insert(fingerprint);
        }
    }
    allowlist
}

fn line_contains_raw_secret(line: &str) -> bool {
    compiled_content_patterns()
        .iter()
        .any(|pattern| pattern.regex.is_match(line))
}

fn allowlist_line_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"^([0-9a-fA-F]{16})\s+(\S+)\s+(\S+)\s+(.+)$").expect("valid allowlist regex")
    })
}

fn apply_allowlist(findings: &mut [Finding], allowlist: &Allowlist) {
    for finding in findings {
        finding.suppressed = allowlist.entries.contains(&finding.fingerprint)
            && !allowlist.collisions.contains(&finding.fingerprint);
    }
}

fn exit_code(output: &ScanOutput, fatal_allowlist_error: bool) -> i32 {
    if fatal_allowlist_error {
        return 2;
    }
    if output
        .findings
        .iter()
        .any(|finding| finding.severity == Severity::Error && !finding.suppressed)
    {
        1
    } else {
        0
    }
}

fn render_output(output: &ScanOutput, json: bool) -> Result<()> {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(output).map_err(AgentError::Json)?
        );
        return Ok(());
    }
    println!("schema_version\t{}", output.schema_version);
    println!("scan_mode\t{}", output.scan_mode);
    println!("scanned_files\t{}", output.scanned_files);
    println!("findings\t{}", output.findings.len());
    println!("suppressed_count\t{}", output.suppressed_count);
    for finding in &output.findings {
        println!(
            "{}\t{}\t{}\t{}\t{:?}\t{}\tsuppressed={}",
            finding.fingerprint,
            finding.path,
            finding.line,
            finding.pattern_id,
            finding.severity,
            finding.redacted_preview,
            finding.suppressed
        );
    }
    if !output.tool_errors.is_empty() {
        println!("tool_errors");
        for error in &output.tool_errors {
            println!("  {error}");
        }
    }
    Ok(())
}

fn normalize_input_path(path: &Path) -> Result<PathBuf> {
    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_err(AgentError::Io)?.join(path)
    };
    candidate.canonicalize().map_err(AgentError::Io)
}

fn repo_relative_path(repo_root: &Path, path: &Path) -> String {
    let relative = path.strip_prefix(repo_root).unwrap_or(path);
    normalize_separators(relative)
}

fn normalize_separators(path: &Path) -> String {
    path.components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn display_path(path: &str) -> String {
    path.replace('\n', "\\n")
}

fn split_nul_paths(value: &str) -> Vec<String> {
    value
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn git_output(repo_root: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root)
        .output()
        .map_err(AgentError::Io)?;
    if !output.status.success() {
        return Err(AgentError::Git(format!(
            "git {} failed with exit code {:?}",
            args.join(" "),
            output.status.code()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_is_stable_for_same_inputs() {
        let first = fingerprint("aws-access-key", "src/main.rs", "key=[REDACTED:20]", 20);
        let second = fingerprint("aws-access-key", "src/main.rs", "key=[REDACTED:20]", 20);
        assert_eq!(first, second);
        assert_eq!(first.len(), 16);
    }

    #[test]
    fn env_example_path_is_not_path_blocked() {
        let mut state = ScanState::default();
        scan_path_name("config/.env.example", &mut state);
        assert!(state.findings.is_empty());
    }
}
