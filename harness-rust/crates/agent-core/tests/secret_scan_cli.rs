use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use serde_json::Value;

const ZERO_OID: &str = "0000000000000000000000000000000000000000";

fn aws_secret() -> String {
    format!("AKIA{}", "1234567890ABCDEF")
}

fn github_pat() -> String {
    format!("ghp_{}", "a".repeat(36))
}

fn npm_token() -> String {
    format!("npm_{}", "b".repeat(36))
}

fn private_key() -> String {
    ["-----BEGIN OPEN", "SSH PRIVATE KEY-----"].concat()
}

fn anthropic_key() -> String {
    format!("sk-ant-{}", "c".repeat(32))
}

fn openai_key() -> String {
    format!("sk-{}", "d".repeat(48))
}

fn generic_secret() -> String {
    format!("SERVICE_{}={}", "API_KEY", "e".repeat(24))
}

fn agent_core() -> Command {
    Command::new(env!("CARGO_BIN_EXE_agent-core"))
}

fn run_agent_core(args: &[&str], cwd: &Path) -> Output {
    agent_core()
        .args(args)
        .current_dir(cwd)
        .output()
        .expect("run agent-core")
}

fn run_agent_core_with_stdin(args: &[&str], cwd: &Path, stdin: &str) -> Output {
    let mut child = agent_core()
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn agent-core");
    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(stdin.as_bytes())
        .expect("write stdin");
    child.wait_with_output().expect("wait agent-core")
}

fn json_stdout(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).expect("stdout json")
}

fn write_file(repo: &Path, path: &str, content: &str) {
    let file_path = repo.join(path);
    fs::create_dir_all(file_path.parent().expect("file parent")).expect("create parent");
    fs::write(file_path, content).expect("write file");
}

fn init_git_repo(repo: &Path) {
    git(repo, &["init", "-b", "main"]);
    git(repo, &["config", "user.email", "test@example.invalid"]);
    git(repo, &["config", "user.name", "Test User"]);
    write_file(repo, "README.md", "baseline\n");
    git(repo, &["add", "README.md"]);
    git(repo, &["commit", "-m", "initial"]);
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn scan_file_with_content(path: &str, content: &str) -> (tempfile::TempDir, Output) {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), path, content);
    let output = run_agent_core(&["secret", "scan", "--files", path, "--json"], repo.path());
    (repo, output)
}

fn first_finding(json: &Value) -> &Value {
    &json["findings"].as_array().expect("findings array")[0]
}

#[test]
fn positive_aws_access_key_detected() {
    let (_repo, output) = scan_file_with_content("src/aws.txt", &aws_secret());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "aws-access-key"
    );
}

#[test]
fn positive_github_pat_detected() {
    let (_repo, output) = scan_file_with_content("src/github.txt", &github_pat());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "github-pat"
    );
}

#[test]
fn positive_npm_token_detected() {
    let (_repo, output) = scan_file_with_content("src/npm.txt", &npm_token());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "npm-token"
    );
}

#[test]
fn positive_private_key_block_detected() {
    let (_repo, output) = scan_file_with_content("src/key.txt", &private_key());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "private-key-block"
    );
}

#[test]
fn positive_anthropic_key_detected() {
    let (_repo, output) = scan_file_with_content("src/anthropic.txt", &anthropic_key());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "anthropic-api-key"
    );
}

#[test]
fn positive_openai_key_detected() {
    let (_repo, output) = scan_file_with_content("src/openai.txt", &openai_key());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "openai-api-key"
    );
}

#[test]
fn positive_generic_secret_assignment_warning_only() {
    let (_repo, output) = scan_file_with_content("src/generic.txt", &generic_secret());
    assert_eq!(output.status.code(), Some(0));
    let json = json_stdout(&output);
    assert_eq!(
        first_finding(&json)["pattern_id"],
        "generic-secret-assignment"
    );
    assert_eq!(first_finding(&json)["severity"], "warning");
}

#[test]
fn path_env_file_detected() {
    let (_repo, output) = scan_file_with_content(".env.local", "PLACEHOLDER=value\n");
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "path-env-file"
    );
}

#[test]
fn path_env_example_content_scanned_path_not_blocked() {
    let (_repo, output) = scan_file_with_content(".env.example", &aws_secret());
    assert_eq!(output.status.code(), Some(1));
    let json = json_stdout(&output);
    assert_eq!(json["findings"].as_array().expect("findings").len(), 1);
    assert_eq!(first_finding(&json)["pattern_id"], "aws-access-key");
}

#[test]
fn path_private_key_file_detected() {
    let (_repo, output) = scan_file_with_content("keys/id_rsa", "placeholder\n");
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "path-private-key-file"
    );
}

#[test]
fn redaction_human_output_never_contains_raw_secret() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    let secret = aws_secret();
    write_file(repo.path(), "src/aws.txt", &secret);
    let output = run_agent_core(&["secret", "scan", "--files", "src/aws.txt"], repo.path());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stdout.contains(&secret));
    assert!(!stderr.contains(&secret));
}

#[test]
fn redaction_json_output_never_contains_raw_secret() {
    let secret = aws_secret();
    let (_repo, output) = scan_file_with_content("src/aws.txt", &secret);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stdout.contains(&secret));
    assert!(!stderr.contains(&secret));
}

#[test]
fn redacted_preview_format_prefix4_suffix4() {
    let secret = aws_secret();
    let (_repo, output) = scan_file_with_content("src/aws.txt", &secret);
    let json = json_stdout(&output);
    let preview = first_finding(&json)["redacted_preview"]
        .as_str()
        .expect("preview");
    assert!(preview.starts_with("AKIA"));
    assert!(preview.contains("CDEF"));
    assert!(preview.contains("(len=20)"));
    assert!(!preview.contains(&secret));
}

#[test]
fn allowlist_suppresses_finding_by_fingerprint() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/aws.txt", &aws_secret());
    let first = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    let fingerprint = first_finding(&json_stdout(&first))["fingerprint"]
        .as_str()
        .expect("fingerprint")
        .to_string();
    write_file(
        repo.path(),
        ".harness-secret-allowlist",
        &format!("{fingerprint}  src/aws.txt:1  aws-access-key  test fixture\n"),
    );
    let output = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    assert_eq!(output.status.code(), Some(0));
    let json = json_stdout(&output);
    assert_eq!(json["suppressed_count"], 1);
    assert_eq!(first_finding(&json)["suppressed"], true);
}

#[test]
fn allowlist_collision_emits_tool_error_no_suppress() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/aws.txt", &aws_secret());
    let first = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    let fingerprint = first_finding(&json_stdout(&first))["fingerprint"]
        .as_str()
        .expect("fingerprint")
        .to_string();
    write_file(
        repo.path(),
        ".harness-secret-allowlist",
        &format!(
            "{fingerprint}  src/aws.txt:1  aws-access-key  first\n{fingerprint}  src/aws.txt:1  aws-access-key  second\n"
        ),
    );
    let output = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    assert_eq!(output.status.code(), Some(1));
    let json = json_stdout(&output);
    assert_eq!(first_finding(&json)["suppressed"], false);
    assert!(json["tool_errors"][0]
        .as_str()
        .expect("tool error")
        .contains("collision"));
}

#[test]
fn allowlist_raw_secret_line_rejected_as_tool_error() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "clean.txt", "clean\n");
    write_file(
        repo.path(),
        ".harness-secret-allowlist",
        &format!(
            "1a2b3c4d5e6f7890  clean.txt:1  aws-access-key  {}\n",
            aws_secret()
        ),
    );
    let output = run_agent_core(
        &["secret", "scan", "--files", "clean.txt", "--json"],
        repo.path(),
    );
    assert_eq!(output.status.code(), Some(2));
    let json = json_stdout(&output);
    assert!(json["tool_errors"][0]
        .as_str()
        .expect("tool error")
        .contains("raw secret"));
}

#[test]
fn staged_only_scans_git_diff_cached() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/staged.txt", &aws_secret());
    git(repo.path(), &["add", "src/staged.txt"]);
    let output = run_agent_core(&["secret", "scan", "--staged-only", "--json"], repo.path());
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "aws-access-key"
    );
}

#[test]
fn files_mode_scans_full_file_content() {
    let (_repo, output) = scan_file_with_content("src/full.txt", &aws_secret());
    let json = json_stdout(&output);
    assert_eq!(json["scan_mode"], "files");
    assert_eq!(json["scanned_files"], 1);
}

#[test]
fn mutually_exclusive_scan_modes_exit_2() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/aws.txt", &aws_secret());
    let output = run_agent_core(
        &["secret", "scan", "--staged-only", "--files", "src/aws.txt"],
        repo.path(),
    );
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn fingerprint_deterministic_across_two_scans() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/aws.txt", &aws_secret());
    let first = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    let second = run_agent_core(
        &["secret", "scan", "--files", "src/aws.txt", "--json"],
        repo.path(),
    );
    assert_eq!(
        first_finding(&json_stdout(&first))["fingerprint"],
        first_finding(&json_stdout(&second))["fingerprint"]
    );
}

#[test]
fn exit_0_when_no_findings() {
    let (_repo, output) = scan_file_with_content("src/clean.txt", "clean\n");
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn exit_1_when_unsuppressed_error_finding() {
    let (_repo, output) = scan_file_with_content("src/aws.txt", &aws_secret());
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn exit_2_when_usage_error() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    let output = run_agent_core(&["secret", "scan"], repo.path());
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn hook_stdin_pre_push_parses_ref_ranges() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    let base = git(repo.path(), &["rev-parse", "HEAD"]);
    write_file(repo.path(), "src/hook.txt", &aws_secret());
    git(repo.path(), &["add", "src/hook.txt"]);
    git(repo.path(), &["commit", "-m", "secret"]);
    let head = git(repo.path(), &["rev-parse", "HEAD"]);
    let stdin = format!("refs/heads/main {head} refs/heads/main {base}\n");
    let output = run_agent_core_with_stdin(
        &["secret", "scan", "--hook-stdin", "pre-push", "--json"],
        repo.path(),
        &stdin,
    );
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "aws-access-key"
    );
}

#[test]
fn hook_stdin_pre_push_zero_remote_oid_uses_not_remotes() {
    let repo = tempfile::tempdir().expect("repo tempdir");
    init_git_repo(repo.path());
    write_file(repo.path(), "src/new_branch.txt", &aws_secret());
    git(repo.path(), &["add", "src/new_branch.txt"]);
    git(repo.path(), &["commit", "-m", "secret"]);
    let head = git(repo.path(), &["rev-parse", "HEAD"]);
    let stdin = format!("refs/heads/topic {head} refs/heads/topic {ZERO_OID}\n");
    let output = run_agent_core_with_stdin(
        &["secret", "scan", "--hook-stdin", "pre-push", "--json"],
        repo.path(),
        &stdin,
    );
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        first_finding(&json_stdout(&output))["pattern_id"],
        "aws-access-key"
    );
}
