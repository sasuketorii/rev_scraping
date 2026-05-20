use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Mutex, OnceLock};

use rusqlite::{params, Connection};
use serde_json::Value;

fn env_mutex() -> &'static Mutex<()> {
    static ENV_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_MUTEX.get_or_init(|| Mutex::new(()))
}

fn agent_core() -> Command {
    Command::new(env!("CARGO_BIN_EXE_agent-core"))
}

fn run_agent_core(args: &[&str], repo_root: &Path, semantic_home: &Path) -> Output {
    let mut command = agent_core();
    command
        .args(args)
        .current_dir(repo_root)
        .env("REVHARNESS_TEST_HARNESS", "1")
        .env("SEMANTIC_MCP_HOME", semantic_home);
    command.output().expect("run agent-core")
}

fn write_repo_project_id(repo_root: &Path, project_id: &str) {
    fs::create_dir_all(repo_root.join(".git")).expect("create .git");
    fs::create_dir_all(repo_root.join(".shared")).expect("create .shared");
    fs::write(
        repo_root.join(".shared/project_id"),
        format!("{project_id}\n"),
    )
    .expect("write project_id");
}

fn seed_db(semantic_home: &Path, project_id: &str, old: bool) -> PathBuf {
    let db_path = semantic_home
        .join("v1")
        .join(project_id)
        .join("semantic.db");
    fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
    let conn = Connection::open(&db_path).expect("open sqlite db");
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS _ts_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        ",
    )
    .expect("create metadata table");
    let seconds = current_unix_seconds() - if old { 40 * 24 * 60 * 60 } else { 60 };
    conn.execute(
        "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
        params![seconds.to_string()],
    )
    .expect("seed last_accessed");
    db_path
}

fn current_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time")
        .as_secs() as i64
}

fn parse_stdout_json(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).expect("stdout json")
}

#[test]
fn cli_help_shows_semantic_subcommand() {
    let _guard = env_mutex().lock().expect("env lock");
    let output = agent_core()
        .args(["semantic", "--help"])
        .output()
        .expect("run semantic help");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("gc"));
}

#[test]
fn cli_gc_help_shows_all_options() {
    let _guard = env_mutex().lock().expect("env lock");
    let output = agent_core()
        .args(["semantic", "gc", "--help"])
        .output()
        .expect("run gc help");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    for option in [
        "--older-than-days",
        "--dry-run",
        "--force",
        "--all-projects",
        "--ignore-active-lock",
        "--json",
    ] {
        assert!(stdout.contains(option), "missing option {option}");
    }
}

#[test]
fn cli_gc_dry_run_emits_v1_schema() {
    let _guard = env_mutex().lock().expect("env lock");
    let repo = tempfile::tempdir().expect("repo tempdir");
    let semantic_home = tempfile::tempdir().expect("semantic tempdir");
    write_repo_project_id(repo.path(), "project-a");

    let output = run_agent_core(
        &["semantic", "gc", "--dry-run", "--json"],
        repo.path(),
        semantic_home.path(),
    );
    assert!(output.status.success());
    let json = parse_stdout_json(&output);
    assert_eq!(json["schema_version"], 1);
    assert!(json["candidates"].is_array());
    assert!(json["deleted"].is_array());
    assert!(json["skipped_active"].is_array());
    assert!(json["tool_errors"].is_array());
    assert!(json["scanned"].is_number());
    assert!(json["freed_bytes"].is_number());
    assert_eq!(json["dry_run"], true);
}

#[test]
fn cli_gc_dry_run_and_force_simultaneous_usage_error_exit_2() {
    let _guard = env_mutex().lock().expect("env lock");
    let output = agent_core()
        .args(["semantic", "gc", "--dry-run", "--force"])
        .output()
        .expect("run conflict command");
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn cli_gc_older_than_days_zero_exit_non_zero() {
    let _guard = env_mutex().lock().expect("env lock");
    let repo = tempfile::tempdir().expect("repo tempdir");
    let semantic_home = tempfile::tempdir().expect("semantic tempdir");
    write_repo_project_id(repo.path(), "project-a");

    let output = run_agent_core(
        &["semantic", "gc", "--older-than-days", "0", "--json"],
        repo.path(),
        semantic_home.path(),
    );
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("older_than_days must be >= 1"));
}

#[test]
fn cli_gc_default_is_dry_run() {
    let _guard = env_mutex().lock().expect("env lock");
    let repo = tempfile::tempdir().expect("repo tempdir");
    let semantic_home = tempfile::tempdir().expect("semantic tempdir");
    write_repo_project_id(repo.path(), "project-a");
    let db_path = seed_db(semantic_home.path(), "project-a", true);

    let output = run_agent_core(
        &["semantic", "gc", "--json"],
        repo.path(),
        semantic_home.path(),
    );
    assert_eq!(output.status.code(), Some(1));
    let json = parse_stdout_json(&output);
    assert_eq!(json["dry_run"], true);
    assert_eq!(json["deleted"].as_array().expect("deleted array").len(), 0);
    assert!(db_path.exists());
}

#[test]
fn cli_gc_all_projects_flag_changes_scope() {
    let _guard = env_mutex().lock().expect("env lock");
    let repo = tempfile::tempdir().expect("repo tempdir");
    let semantic_home = tempfile::tempdir().expect("semantic tempdir");
    write_repo_project_id(repo.path(), "project-a");
    seed_db(semantic_home.path(), "project-a", true);
    seed_db(semantic_home.path(), "project-b", true);

    let scoped = run_agent_core(
        &["semantic", "gc", "--dry-run", "--json"],
        repo.path(),
        semantic_home.path(),
    );
    assert_eq!(scoped.status.code(), Some(1));
    let scoped_json = parse_stdout_json(&scoped);
    assert_eq!(
        scoped_json["candidates"]
            .as_array()
            .expect("scoped candidates")
            .len(),
        1
    );

    let all_projects = run_agent_core(
        &["semantic", "gc", "--dry-run", "--all-projects", "--json"],
        repo.path(),
        semantic_home.path(),
    );
    assert_eq!(all_projects.status.code(), Some(1));
    let all_json = parse_stdout_json(&all_projects);
    assert_eq!(
        all_json["candidates"]
            .as_array()
            .expect("all candidates")
            .len(),
        2
    );
}
