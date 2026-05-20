//! Semantic MCP server and CLI entrypoint.
//!
//! The binary has two modes:
//! - stdio MCP server mode: `semantic-mcp [--project-id <id> | --project-id=<id>] [--repo-root <path>]`
//! - CLI mode: `semantic-mcp <group> <command> ...`
//!
//! All logging goes to stderr; CLI JSON results are written to stdout.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::Serialize;
use serde_json::{json, Value};
use shared::semantic_lock::SemanticDbLock;

use crate::admin_gc::{self, GcOptions};
use crate::context::ServerContext;
use crate::db;
use crate::protocol;
use crate::review_queue;
use crate::review_queue::{parse_review_run_record_input, record_review_run, QueueExport};

pub fn run() -> ExitCode {
    init_logging();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match classify_mode(&args) {
        InvocationMode::Cli => run_cli(&args),
        InvocationMode::Server => run_server(&args),
    };

    if let Err(error) = result {
        match classify_mode(&args) {
            InvocationMode::Cli => eprintln!("[semantic-mcp-cli] {error}"),
            InvocationMode::Server => eprintln!("[semantic-mcp-server] startup failed: {error}"),
        }
        return ExitCode::FAILURE;
    }

    ExitCode::SUCCESS
}

#[derive(Clone, Copy)]
enum InvocationMode {
    Cli,
    Server,
}

fn classify_mode(args: &[String]) -> InvocationMode {
    match args.first().map(String::as_str) {
        Some(first) if first.starts_with('-') => InvocationMode::Server,
        Some(_) => InvocationMode::Cli,
        None => InvocationMode::Server,
    }
}

fn run_server(args: &[String]) -> Result<(), String> {
    let project_id = resolve_project_id_from_args(args)?;
    let repo_root = resolve_repo_root_from_args(args)?;
    let (conn, db_path) = db::open_project_connection(&project_id)?;
    let _db_lock = match SemanticDbLock::try_acquire(&db_path) {
        Ok(lock) => Some(lock),
        Err(error) => {
            eprintln!(
                "[semantic-mcp-server] warning: active db lock unavailable db_path={} error={error}",
                db_path.display()
            );
            None
        }
    };

    let db_path_str = db_path.display().to_string();
    eprintln!(
        "[semantic-mcp-server] started project_id={project_id} db_path={db_path_str} repo_root={}",
        repo_root.display()
    );

    install_signal_handlers();

    let ctx = ServerContext::new(conn, project_id, repo_root).with_db_path(db_path_str);

    protocol::run_stdio_server(&ctx).map_err(|e| format!("server error: {e}"))
}

fn run_cli(args: &[String]) -> Result<(), String> {
    if args.first().map(String::as_str) == Some("gc") {
        return handle_gc(&args[1..]);
    }
    if args.len() < 2 {
        return Err("expected <group> <command>".to_string());
    }

    match (args[0].as_str(), args[1].as_str()) {
        ("project-id", "validate") => handle_project_id_validate(&args[2..]),
        ("queue", "enqueue") => handle_queue_enqueue(&args[2..]),
        ("queue", "lease") | ("queue", "drain") => handle_queue_lease(&args[2..]),
        ("queue", "complete") => handle_queue_complete(&args[2..]),
        ("queue", "requeue") => handle_queue_requeue(&args[2..]),
        ("queue", "export-json") => handle_queue_export_json(&args[2..]),
        ("review-run", "record") => handle_review_run_record(&args[2..]),
        (group, command) => Err(format!("unknown command: {group} {command}")),
    }
}

fn handle_gc(args: &[String]) -> Result<(), String> {
    let options = parse_gc_options(args)?;
    write_json(&admin_gc::run_gc(options)?)
}

fn handle_project_id_validate(args: &[String]) -> Result<(), String> {
    let flags = parse_flags(args, &["--value"], &["--value"])?;
    let project_id = flags
        .values
        .get("--value")
        .ok_or_else(|| "missing required flag: --value".to_string())?;
    let normalized_project_id = validate_project_id(project_id)?;
    write_json(&json!({
        "ok": true,
        "project_id": normalized_project_id,
    }))
}

fn handle_queue_enqueue(args: &[String]) -> Result<(), String> {
    let flags = parse_flags(
        args,
        &[
            "--project-id",
            "--repo-root",
            "--file-path",
            "--source",
            "--export-json",
        ],
        &["--project-id", "--repo-root", "--file-path"],
    )?;
    let project_id = required_flag_value(&flags, "--project-id")?;
    let repo_root = required_flag_value(&flags, "--repo-root")?;
    let file_path = required_flag_value(&flags, "--file-path")?;
    let source = flags
        .values
        .get("--source")
        .map(String::as_str)
        .unwrap_or("manual");
    let export_path = flags
        .values
        .get("--export-json")
        .map(|value| resolve_output_path(value))
        .transpose()?;

    let result = with_database(project_id, |conn, validated_project_id| {
        let enqueue_result = review_queue::enqueue(
            conn,
            validated_project_id,
            Path::new(repo_root),
            file_path,
            source,
        )?;

        if let Some(path) = export_path.as_ref() {
            let snapshot = review_queue::export_json(conn, validated_project_id)?;
            write_queue_snapshot(path, &snapshot)?;
        }

        Ok(enqueue_result)
    })?;

    write_json(&result)
}

#[derive(Serialize)]
struct QueueLeaseCliOutput {
    #[serde(flatten)]
    result: review_queue::LeaseResult,
    lease_run_id: Option<String>,
    expected_files: Vec<String>,
}

fn handle_queue_lease(args: &[String]) -> Result<(), String> {
    let flags = parse_flags(
        args,
        &["--project-id", "--lease-seconds", "--lease-run-id"],
        &["--project-id"],
    )?;
    let project_id = required_flag_value(&flags, "--project-id")?;
    let lease_seconds =
        parse_optional_integer(flags.values.get("--lease-seconds"), "--lease-seconds")?;
    let lease_run_id = flags.values.get("--lease-run-id").cloned();

    let result = with_database(project_id, |conn, validated_project_id| {
        review_queue::lease(
            conn,
            validated_project_id,
            lease_run_id.as_deref(),
            lease_seconds,
        )
    })?;

    write_json(&QueueLeaseCliOutput {
        expected_files: result
            .items
            .iter()
            .map(|item| item.file_path.clone())
            .collect(),
        result,
        lease_run_id,
    })
}

fn handle_queue_complete(args: &[String]) -> Result<(), String> {
    let flags = parse_flags_with_repeats(
        args,
        &[
            "--project-id",
            "--lease-owner",
            "--lease-run-id",
            "--expected-file",
        ],
        &["--project-id", "--lease-owner"],
        &["--expected-file"],
    )?;
    let expected_files = require_repeated_flag(
        &flags.repeated,
        "--expected-file",
        "queue complete requires strict expected files via --expected-file",
    )?;

    let project_id = required_flag_value(&flags, "--project-id")?;
    let lease_owner = required_flag_value(&flags, "--lease-owner")?;
    let lease_run_id = flags.values.get("--lease-run-id").map(String::as_str);

    let result = with_database(project_id, |conn, validated_project_id| {
        review_queue::complete(
            conn,
            validated_project_id,
            lease_owner,
            lease_run_id,
            Some(&expected_files),
        )
    })?;

    write_json(&result)
}

fn handle_queue_requeue(args: &[String]) -> Result<(), String> {
    let flags = parse_flags_with_repeats(
        args,
        &[
            "--project-id",
            "--lease-owner",
            "--lease-run-id",
            "--expected-file",
            "--error",
        ],
        &["--project-id", "--lease-owner"],
        &["--expected-file"],
    )?;
    let expected_files = require_repeated_flag(
        &flags.repeated,
        "--expected-file",
        "queue requeue requires strict expected files via --expected-file",
    )?;

    let project_id = required_flag_value(&flags, "--project-id")?;
    let lease_owner = required_flag_value(&flags, "--lease-owner")?;
    let lease_run_id = flags.values.get("--lease-run-id").map(String::as_str);
    let error_message = flags.values.get("--error").map(String::as_str);

    let result = with_database(project_id, |conn, validated_project_id| {
        review_queue::requeue(
            conn,
            validated_project_id,
            lease_owner,
            lease_run_id,
            Some(&expected_files),
            error_message,
        )
    })?;

    write_json(&result)
}

#[derive(Serialize)]
struct QueueExportCliOutput {
    project_id: String,
    output: String,
    pending_count: usize,
    leased_count: usize,
}

fn handle_queue_export_json(args: &[String]) -> Result<(), String> {
    let flags = parse_flags(
        args,
        &["--project-id", "--output"],
        &["--project-id", "--output"],
    )?;
    let project_id = required_flag_value(&flags, "--project-id")?;
    let output = required_flag_value(&flags, "--output")?;
    let output_path = resolve_output_path(output)?;

    let snapshot = with_database(project_id, |conn, validated_project_id| {
        review_queue::export_json(conn, validated_project_id)
    })?;

    write_queue_snapshot(&output_path, &snapshot)?;
    write_json(&QueueExportCliOutput {
        project_id: snapshot.project_id.clone(),
        output: output_path.display().to_string(),
        pending_count: snapshot.pending_count,
        leased_count: snapshot.leased_count,
    })
}

fn handle_review_run_record(args: &[String]) -> Result<(), String> {
    let flags = parse_flags(
        args,
        &["--project-id", "--input"],
        &["--project-id", "--input"],
    )?;
    let project_id = required_flag_value(&flags, "--project-id")?;
    let input_path = required_flag_value(&flags, "--input")?;
    let payload = read_json_file(input_path)?;
    parse_review_run_record_input(&payload)?;

    let result = with_database(project_id, |conn, validated_project_id| {
        record_review_run(conn, validated_project_id, &payload)
    })?;

    write_json(&result)
}

fn with_database<T, F>(project_id: &str, f: F) -> Result<T, String>
where
    F: FnOnce(&rusqlite::Connection, &str) -> Result<T, String>,
{
    let normalized_project_id = validate_project_id(project_id)?;
    let (conn, _) = db::open_project_connection(&normalized_project_id)?;
    f(&conn, &normalized_project_id)
}

fn read_json_file(path: &str) -> Result<Value, String> {
    let raw = fs::read_to_string(path).map_err(|e| format!("failed to read JSON input: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("failed to parse JSON input: {e}"))
}

fn write_queue_snapshot(path: &Path, snapshot: &QueueExport) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "failed to create output directory {}: {e}",
                parent.display()
            )
        })?;
    }
    let payload = serde_json::to_string_pretty(snapshot)
        .map_err(|e| format!("failed to encode queue export JSON: {e}"))?;
    fs::write(path, format!("{payload}\n"))
        .map_err(|e| format!("failed to write queue export {}: {e}", path.display()))
}

fn resolve_output_path(output: &str) -> Result<PathBuf, String> {
    let normalized = output.trim();
    if normalized.is_empty() {
        return Err("output must not be empty".to_string());
    }

    let path = PathBuf::from(normalized);
    if path.is_absolute() {
        return Ok(path);
    }

    std::env::current_dir()
        .map(|cwd| cwd.join(path))
        .map_err(|e| format!("failed to resolve output path: {e}"))
}

#[derive(Debug, Default)]
struct ParsedFlags {
    values: BTreeMap<String, String>,
    repeated: BTreeMap<String, Vec<String>>,
}

fn parse_flags(
    args: &[String],
    allowed_flags: &[&str],
    required_flags: &[&str],
) -> Result<ParsedFlags, String> {
    parse_flags_with_repeats(args, allowed_flags, required_flags, &[])
}

fn parse_flags_with_repeats(
    args: &[String],
    allowed_flags: &[&str],
    required_flags: &[&str],
    repeatable_flags: &[&str],
) -> Result<ParsedFlags, String> {
    let allowed = allowed_flags
        .iter()
        .copied()
        .collect::<std::collections::HashSet<_>>();
    let repeatable = repeatable_flags
        .iter()
        .copied()
        .collect::<std::collections::HashSet<_>>();
    let mut parsed = ParsedFlags::default();
    let mut index = 0usize;

    while index < args.len() {
        let token = &args[index];
        if !token.starts_with("--") {
            return Err(format!("unexpected positional argument: {token}"));
        }
        if !allowed.contains(token.as_str()) {
            return Err(format!("unknown flag: {token}"));
        }

        let value = args
            .get(index + 1)
            .ok_or_else(|| format!("missing value for {token}"))?;
        if value.starts_with("--") {
            return Err(format!("missing value for {token}"));
        }

        if repeatable.contains(token.as_str()) {
            parsed
                .repeated
                .entry(token.clone())
                .or_default()
                .push(value.clone());
        } else if parsed.values.insert(token.clone(), value.clone()).is_some() {
            return Err(format!("duplicate flag: {token}"));
        }

        index += 2;
    }

    for required in required_flags {
        if !parsed.values.contains_key(*required) {
            return Err(format!("missing required flag: {required}"));
        }
    }

    Ok(parsed)
}

fn required_flag_value<'a>(flags: &'a ParsedFlags, flag: &str) -> Result<&'a str, String> {
    flags
        .values
        .get(flag)
        .map(String::as_str)
        .ok_or_else(|| format!("missing required flag: {flag}"))
}

fn require_repeated_flag(
    repeated: &BTreeMap<String, Vec<String>>,
    flag: &str,
    error_message: &str,
) -> Result<Vec<String>, String> {
    repeated
        .get(flag)
        .filter(|values| !values.is_empty())
        .cloned()
        .ok_or_else(|| error_message.to_string())
}

fn parse_optional_integer(value: Option<&String>, field: &str) -> Result<Option<i64>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    value
        .parse::<i64>()
        .map(Some)
        .map_err(|_| format!("{field} must be an integer"))
}

fn parse_gc_options(args: &[String]) -> Result<GcOptions, String> {
    let mut options = GcOptions::default();
    let mut index = 0usize;
    while index < args.len() {
        let token = &args[index];
        if token == "--older-than" {
            let value = args
                .get(index + 1)
                .ok_or_else(|| "--older-than requires a value".to_string())?;
            options.older_than_days = parse_days_duration(value, "--older-than")?;
            index += 2;
            continue;
        }
        if let Some(value) = token.strip_prefix("--older-than=") {
            options.older_than_days = parse_days_duration(value, "--older-than")?;
            index += 1;
            continue;
        }
        if token == "--dry-run" {
            options.dry_run = true;
            index += 1;
            continue;
        }
        if let Some(value) = token.strip_prefix("--dry-run=") {
            options.dry_run = parse_bool(value, "--dry-run")?;
            index += 1;
            continue;
        }
        if token == "--force" {
            options.force = true;
            index += 1;
            continue;
        }
        return Err(format!("unknown gc flag: {token}"));
    }
    Ok(options)
}

fn parse_days_duration(value: &str, field: &str) -> Result<u64, String> {
    let raw = value.trim();
    let days = raw.strip_suffix('d').unwrap_or(raw);
    let parsed = days
        .parse::<u64>()
        .map_err(|_| format!("{field} must be a day duration like 30d"))?;
    if parsed == 0 {
        return Err(format!("{field} must be >= 1d"));
    }
    Ok(parsed)
}

fn parse_bool(value: &str, field: &str) -> Result<bool, String> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(format!("{field} must be true or false")),
    }
}

fn write_json<T: Serialize>(payload: &T) -> Result<(), String> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer_pretty(&mut handle, payload)
        .map_err(|e| format!("failed to encode JSON output: {e}"))?;
    handle
        .write_all(b"\n")
        .map_err(|e| format!("failed to write JSON output: {e}"))
}

/// Initialise tracing subscriber writing to stderr.
fn init_logging() {
    use tracing_subscriber::EnvFilter;

    let filter = if let Ok(level) = std::env::var("LOG_LEVEL") {
        EnvFilter::new(level)
    } else {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
    };

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .with_writer(std::io::stderr)
        .try_init();
}

fn resolve_project_id_from_args(args: &[String]) -> Result<String, String> {
    let mut project_id: Option<String> = None;
    let mut index = 0usize;

    while index < args.len() {
        let current = &args[index];

        if current == "--project-id" {
            let next = args
                .get(index + 1)
                .ok_or_else(|| "--project-id requires a value".to_string())?;
            if next.starts_with("--") {
                return Err(format!(
                    "--project-id requires a value; received another flag: {next}"
                ));
            }
            if project_id.is_some() {
                return Err("duplicate flag: --project-id".to_string());
            }
            project_id = Some(next.clone());
            index += 2;
            continue;
        }
        if let Some(stripped) = current.strip_prefix("--project-id=") {
            if project_id.is_some() {
                return Err("duplicate flag: --project-id".to_string());
            }
            project_id = Some(stripped.to_string());
            index += 1;
            continue;
        }

        if current == "--repo-root" {
            let next = args
                .get(index + 1)
                .ok_or_else(|| "--repo-root requires a value".to_string())?;
            if next.starts_with("--") {
                return Err(format!(
                    "--repo-root requires a value; received another flag: {next}"
                ));
            }
            index += 2;
            continue;
        }
        if current.strip_prefix("--repo-root=").is_some() {
            index += 1;
            continue;
        }

        if current.starts_with("--") {
            return Err(format!("unknown flag: {current}"));
        }

        return Err(format!("unknown positional argument: {current}"));
    }

    let project_id = project_id.ok_or_else(|| {
        if std::env::var("SEMANTIC_MCP_PROJECT_ID").is_ok()
            || std::env::var("PROJECT_ID").is_ok()
        {
            "project_id must be provided via --project-id <id>; env-based project_id is not supported".to_string()
        } else {
            "project_id is required: use --project-id <id>".to_string()
        }
    })?;
    validate_project_id(&project_id)
}

fn resolve_repo_root_from_args(args: &[String]) -> Result<PathBuf, String> {
    let mut repo_root: Option<String> = None;
    let mut index = 0usize;

    while index < args.len() {
        let current = &args[index];
        if current == "--repo-root" {
            let next = args
                .get(index + 1)
                .ok_or_else(|| "--repo-root requires a value".to_string())?;
            if next.starts_with("--") {
                return Err(format!(
                    "--repo-root requires a value; received another flag: {next}"
                ));
            }
            if repo_root.is_some() {
                return Err("duplicate flag: --repo-root".to_string());
            }
            repo_root = Some(next.clone());
            index += 2;
            continue;
        }
        if let Some(stripped) = current.strip_prefix("--repo-root=") {
            if repo_root.is_some() {
                return Err("duplicate flag: --repo-root".to_string());
            }
            repo_root = Some(stripped.to_string());
            index += 1;
            continue;
        }
        if current == "--project-id" {
            index += 2;
            continue;
        }
        if current.strip_prefix("--project-id=").is_some() {
            index += 1;
            continue;
        }
        index += 1;
    }

    let root = match repo_root {
        Some(value) if value.trim().is_empty() => {
            return Err("--repo-root must not be blank".into())
        }
        Some(value) => PathBuf::from(value),
        None => std::env::current_dir().map_err(|e| format!("failed to resolve cwd: {e}"))?,
    };
    validate_repo_root(&root)
}

fn validate_repo_root(path: &Path) -> Result<PathBuf, String> {
    if !path.exists() {
        return Err(format!("repo_root does not exist: {}", path.display()));
    }
    let metadata = fs::symlink_metadata(path)
        .map_err(|e| format!("failed to inspect repo_root {}: {e}", path.display()))?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "repo_root must not be a symlink: {}",
            path.display()
        ));
    }
    if !metadata.is_dir() {
        return Err(format!("repo_root must be a directory: {}", path.display()));
    }
    path.canonicalize()
        .map_err(|e| format!("failed to canonicalize repo_root {}: {e}", path.display()))
}

fn validate_project_id(id: &str) -> Result<String, String> {
    let normalized = id.trim();

    if normalized.is_empty() {
        return Err("project_id must not be empty".into());
    }
    if normalized.len() > 64 {
        return Err("project_id must be <= 64 characters".into());
    }
    if !normalized
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("project_id must contain only letters, numbers, '_' or '-'".into());
    }
    if normalized == "agent_base" {
        return Err(
            "project_id literal 'agent_base' is forbidden; bootstrap a repo-local immutable id"
                .into(),
        );
    }
    Ok(normalized.to_string())
}

/// Install handlers for SIGPIPE so broken pipes do not crash the stdio server.
fn install_signal_handlers() {
    #[cfg(unix)]
    unsafe {
        extern "C" {
            fn signal(sig: i32, handler: usize) -> usize;
        }
        const SIGPIPE: i32 = 13;
        const SIG_IGN: usize = 1;
        signal(SIGPIPE, SIG_IGN);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn classify_queue_commands_as_cli() {
        assert!(matches!(
            classify_mode(&["queue".to_string(), "lease".to_string()]),
            InvocationMode::Cli
        ));
        assert!(matches!(
            classify_mode(&["review-run".to_string(), "record".to_string()]),
            InvocationMode::Cli
        ));
    }

    #[test]
    fn keep_server_mode_for_flag_only_invocations() {
        assert!(matches!(
            classify_mode(&["--project-id".to_string(), "demo".to_string()]),
            InvocationMode::Server
        ));
    }

    #[test]
    fn classify_unknown_leading_positional_tokens_as_cli() {
        assert!(matches!(
            classify_mode(&["bogus".to_string(), "cmd".to_string()]),
            InvocationMode::Cli
        ));
    }

    #[test]
    fn run_cli_rejects_unknown_leading_positional_tokens() {
        let error = run_cli(&[
            "bogus".into(),
            "cmd".into(),
            "--project-id".into(),
            "demo".into(),
        ])
        .unwrap_err();
        assert_eq!(error, "unknown command: bogus cmd");
    }

    #[test]
    fn project_id_validate_trims_before_returning_json() {
        let _guard = ENV_LOCK.lock().unwrap();
        let previous_home = std::env::var_os("HOME");
        let previous_userprofile = std::env::var_os("USERPROFILE");
        let temp_root = unique_temp_dir("semantic-mcp-cli-project-id-trim");
        let home_root = temp_root.join("home");
        fs::create_dir_all(&home_root).unwrap();
        std::env::set_var("HOME", &home_root);
        std::env::remove_var("USERPROFILE");

        let result = run_cli(&[
            "project-id".into(),
            "validate".into(),
            "--value".into(),
            " demo ".into(),
        ]);

        match previous_home {
            Some(value) => std::env::set_var("HOME", value),
            None => std::env::remove_var("HOME"),
        }
        match previous_userprofile {
            Some(value) => std::env::set_var("USERPROFILE", value),
            None => std::env::remove_var("USERPROFILE"),
        }

        assert!(
            result.is_ok(),
            "project-id validate failed: {:?}",
            result.err()
        );
        fs::remove_dir_all(&temp_root).unwrap();
    }

    #[test]
    fn validate_project_id_rejects_legacy_agent_base_literal_with_node_parity() {
        let error = validate_project_id("agent_base").unwrap_err();
        assert_eq!(
            error,
            "project_id literal 'agent_base' is forbidden; bootstrap a repo-local immutable id"
        );
    }

    #[test]
    fn parse_flags_rejects_unknown_flag() {
        let error = parse_flags(
            &[
                "--project-id".into(),
                "demo".into(),
                "--bogus".into(),
                "x".into(),
            ],
            &["--project-id"],
            &["--project-id"],
        )
        .unwrap_err();
        assert!(error.contains("unknown flag"));
    }

    #[test]
    fn resolve_project_id_from_args_rejects_duplicate_split_flags() {
        let error = resolve_project_id_from_args(&[
            "--project-id".into(),
            "good".into(),
            "--project-id".into(),
            "bad".into(),
        ])
        .unwrap_err();
        assert_eq!(error, "duplicate flag: --project-id");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_duplicate_equals_flags() {
        let error =
            resolve_project_id_from_args(&["--project-id=good".into(), "--project-id=bad".into()])
                .unwrap_err();
        assert_eq!(error, "duplicate flag: --project-id");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_unknown_flag_after_project_id() {
        let error =
            resolve_project_id_from_args(&["--project-id".into(), "demo".into(), "--bogus".into()])
                .unwrap_err();
        assert_eq!(error, "unknown flag: --bogus");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_unknown_positional_after_project_id() {
        let error = resolve_project_id_from_args(&[
            "--project-id".into(),
            "demo".into(),
            "stray-positional".into(),
        ])
        .unwrap_err();
        assert_eq!(error, "unknown positional argument: stray-positional");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_unknown_flag_before_project_id() {
        let error =
            resolve_project_id_from_args(&["--bogus".into(), "--project-id".into(), "demo".into()])
                .unwrap_err();
        assert_eq!(error, "unknown flag: --bogus");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_unknown_positional_before_project_id() {
        let error =
            resolve_project_id_from_args(&["bogus".into(), "--project-id".into(), "demo".into()])
                .unwrap_err();
        assert_eq!(error, "unknown positional argument: bogus");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_missing_split_value() {
        let error = resolve_project_id_from_args(&["--project-id".into()]).unwrap_err();
        assert_eq!(error, "--project-id requires a value");
    }

    #[test]
    fn resolve_project_id_from_args_rejects_mixed_duplicate_flags() {
        let error = resolve_project_id_from_args(&[
            "--project-id".into(),
            "good".into(),
            "--project-id=bad".into(),
        ])
        .unwrap_err();
        assert_eq!(error, "duplicate flag: --project-id");
    }

    #[test]
    fn run_cli_queue_enqueue_can_export_snapshot_in_same_invocation() {
        let _guard = ENV_LOCK.lock().unwrap();
        let temp_root = unique_temp_dir("semantic-mcp-cli-enqueue-export");
        let repo_root = temp_root.join("repo");
        let home_root = temp_root.join("home");
        let output_path = temp_root.join("queue-export.json");
        let source_path = repo_root.join("src").join("review.rs");
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::create_dir_all(&home_root).unwrap();
        fs::write(&source_path, "fn main() {}\n").unwrap();

        let previous_home = std::env::var_os("HOME");
        let previous_userprofile = std::env::var_os("USERPROFILE");
        std::env::set_var("HOME", &home_root);
        std::env::remove_var("USERPROFILE");

        let result = run_cli(&[
            "queue".into(),
            "enqueue".into(),
            "--project-id".into(),
            "rust-cli-enqueue-export".into(),
            "--repo-root".into(),
            repo_root.display().to_string(),
            "--file-path".into(),
            "src/review.rs".into(),
            "--source".into(),
            "hook".into(),
            "--export-json".into(),
            output_path.display().to_string(),
        ]);

        match previous_home {
            Some(value) => std::env::set_var("HOME", value),
            None => std::env::remove_var("HOME"),
        }
        match previous_userprofile {
            Some(value) => std::env::set_var("USERPROFILE", value),
            None => std::env::remove_var("USERPROFILE"),
        }

        assert!(result.is_ok(), "queue enqueue failed: {:?}", result.err());

        let exported: Value =
            serde_json::from_str(&fs::read_to_string(&output_path).unwrap()).unwrap();
        assert_eq!(exported["project_id"], "rust-cli-enqueue-export");
        assert_eq!(exported["pending_count"], 1);
        assert_eq!(exported["leased_count"], 0);
        assert_eq!(exported["pending_review"], true);
        assert_eq!(exported["changed_files"], json!(["src/review.rs"]));
        assert_eq!(exported["items"][0]["file_path"], "src/review.rs");
        assert_eq!(exported["items"][0]["dedupe_key"], "src/review.rs");
        assert_eq!(exported["items"][0]["source"], "hook");

        fs::remove_dir_all(&temp_root).unwrap();
    }

    fn unique_temp_dir(prefix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("{prefix}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
