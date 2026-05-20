use std::env;
use std::fs;
use std::io::{self, Read};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use clap::{Args, Parser, Subcommand};
use serde::Deserialize;
use serde_json::Value;

type Result<T> = std::result::Result<T, String>;

const CODE_EXTENSIONS: &[&str] = &[
    "sh", "py", "js", "ts", "tsx", "rs", "go", "java", "rb", "php", "c", "cpp", "h", "hpp",
];
const WRITE_TOOLS: &[&str] = &["Edit", "Write"];
const DEFAULT_QUEUE_REL: &str = ".claude/tmp/review_queue.json";
const DEFAULT_QUEUE_HELPER_REL: &str = "scripts/semantic-review-queue.sh";
const REPO_ROOT_ENV: &str = "AGENT_CORE_REPO_ROOT";

#[derive(Parser)]
#[command(
    name = "hook-review-queue",
    version,
    about = "Minimal review-queue hook ingress"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Hook {
        #[command(subcommand)]
        action: HookAction,
    },
}

#[derive(Subcommand)]
enum HookAction {
    ReviewQueue(ReviewQueueArgs),
}

#[derive(Args, Debug, Clone)]
struct ReviewQueueArgs {
    #[arg(long)]
    repo_root: Option<PathBuf>,

    #[arg(long)]
    queue_helper: Option<PathBuf>,

    #[arg(long)]
    queue_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Deserialize)]
struct HookInput {
    tool_name: Option<String>,
    tool_input: Option<ToolInput>,
}

#[derive(Debug, Clone, Deserialize)]
struct ToolInput {
    file_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HookResult {
    enqueued: bool,
    duplicate: bool,
    file_path: Option<String>,
    reason: String,
    log_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ReviewQueueConfig {
    repo_root: PathBuf,
    queue_helper: PathBuf,
    queue_file: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct EnqueueRequest {
    repo_root: PathBuf,
    queue_helper: PathBuf,
    queue_file: PathBuf,
    file_path: String,
    source: String,
}

enum NormalizedPath {
    RepoRelative(String),
    OutsideRepo(String),
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Hook { action } => run(action),
    }
}

fn run(action: HookAction) {
    match action {
        HookAction::ReviewQueue(args) => run_review_queue(args),
    }
}

fn run_review_queue(args: ReviewQueueArgs) {
    let config = match ReviewQueueConfig::from_args(args) {
        Ok(config) => config,
        Err(err) => {
            log_hook(&format!("ERROR: {err}"));
            std::process::exit(1);
        }
    };

    let mut input = String::new();
    if let Err(err) = io::stdin().read_to_string(&mut input) {
        log_hook(&format!(
            "ERROR: failed to read hook input from stdin: {err}"
        ));
        std::process::exit(1);
    }

    match process_hook_input(&input, &config) {
        Ok(result) => {
            if let Some(message) = result.log_message {
                log_hook(&message);
            }
        }
        Err(err) => {
            log_hook(&format!("ERROR: {err}"));
            std::process::exit(1);
        }
    }
}

fn log_hook(message: &str) {
    eprintln!("[review-hook] {message}");
}

impl ReviewQueueConfig {
    fn from_args(args: ReviewQueueArgs) -> Result<Self> {
        let repo_root = resolve_repo_root(args.repo_root)?;
        let queue_helper = args
            .queue_helper
            .unwrap_or_else(|| repo_root.join(DEFAULT_QUEUE_HELPER_REL));
        let queue_file = args
            .queue_file
            .unwrap_or_else(|| repo_root.join(DEFAULT_QUEUE_REL));

        Ok(Self {
            repo_root,
            queue_helper,
            queue_file,
        })
    }
}

fn resolve_repo_root(explicit: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Some(path) = env::var_os(REPO_ROOT_ENV) {
        return Ok(PathBuf::from(path));
    }
    env::current_dir().map_err(|err| format!("failed to resolve repo root: {err}"))
}

fn process_hook_input(input: &str, config: &ReviewQueueConfig) -> Result<HookResult> {
    process_hook_input_with(input, config, invoke_queue_helper)
}

fn process_hook_input_with<F>(
    input: &str,
    config: &ReviewQueueConfig,
    mut enqueue: F,
) -> Result<HookResult>
where
    F: FnMut(&EnqueueRequest) -> Result<String>,
{
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Ok(ignored("empty input", None));
    }

    let hook_input = match serde_json::from_str::<HookInput>(trimmed) {
        Ok(value) => value,
        Err(_) => return Ok(ignored("invalid hook input", None)),
    };

    match hook_input.tool_name.as_deref() {
        Some(name) if WRITE_TOOLS.contains(&name) => {}
        Some(name) => return Ok(ignored(&format!("tool '{name}' is not a write tool"), None)),
        None => return Ok(ignored("no tool_name in input", None)),
    };

    let raw_file_path = match hook_input
        .tool_input
        .as_ref()
        .and_then(|tool_input| tool_input.file_path.as_deref())
    {
        Some(path) if !path.is_empty() => path,
        _ => return Ok(ignored("no file_path in tool_input", None)),
    };

    let file_path = match normalize_file_path(raw_file_path, &config.repo_root)? {
        NormalizedPath::RepoRelative(path) => path,
        NormalizedPath::OutsideRepo(path) => {
            return Ok(HookResult {
                enqueued: false,
                duplicate: false,
                file_path: Some(path.clone()),
                reason: "outside repo".to_string(),
                log_message: Some(format!("Skipping file outside repo: {path}")),
            });
        }
    };

    if !is_code_file(&file_path) {
        return Ok(ignored("not a code file", Some(file_path)));
    }

    ensure_queue_helper_executable(&config.queue_helper)?;

    let enqueue_output = enqueue(&EnqueueRequest {
        repo_root: config.repo_root.clone(),
        queue_helper: config.queue_helper.clone(),
        queue_file: config.queue_file.clone(),
        file_path: file_path.clone(),
        source: "hook".to_string(),
    })?;

    let duplicate = parse_duplicate_flag(&enqueue_output);
    let log_message = if duplicate {
        format!("Already pending in DB review queue: {file_path}")
    } else {
        format!("Queued for review via DB authority: {file_path}")
    };

    Ok(HookResult {
        enqueued: true,
        duplicate,
        file_path: Some(file_path),
        reason: if duplicate {
            "already pending".to_string()
        } else {
            "enqueued".to_string()
        },
        log_message: Some(log_message),
    })
}

fn ignored(reason: &str, file_path: Option<String>) -> HookResult {
    HookResult {
        enqueued: false,
        duplicate: false,
        file_path,
        reason: reason.to_string(),
        log_message: None,
    }
}

fn normalize_file_path(file_path: &str, repo_root: &Path) -> Result<NormalizedPath> {
    let canonical_repo_root = canonical_repo_root(repo_root)?;
    let candidate = if Path::new(file_path).is_absolute() {
        PathBuf::from(file_path)
    } else {
        repo_root.join(file_path)
    };
    let normalized = normalize_candidate_path(&candidate, &canonical_repo_root)?;

    if !normalized.starts_with(&canonical_repo_root) {
        return Ok(NormalizedPath::OutsideRepo(file_path.to_string()));
    }

    let relative = normalized
        .strip_prefix(&canonical_repo_root)
        .map_err(|err| format!("failed to strip repo root prefix: {err}"))?
        .to_string_lossy()
        .to_string();

    Ok(NormalizedPath::RepoRelative(relative))
}

fn canonical_repo_root(repo_root: &Path) -> Result<PathBuf> {
    repo_root.canonicalize().map_err(|err| {
        format!(
            "failed to canonicalize repo root {}: {err}",
            repo_root.display()
        )
    })
}

fn normalize_candidate_path(candidate: &Path, canonical_repo_root: &Path) -> Result<PathBuf> {
    let mut normalized = PathBuf::new();

    for component in candidate.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(part) => {
                normalized.push(part);
                normalized = maybe_resolve_symlink(&normalized, canonical_repo_root)?;
            }
        }
    }

    Ok(normalized)
}

fn maybe_resolve_symlink(path: &Path, canonical_repo_root: &Path) -> Result<PathBuf> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            let resolved = path.canonicalize().map_err(|err| {
                format!("failed to canonicalize symlink {}: {err}", path.display())
            })?;

            if !resolved.starts_with(canonical_repo_root) {
                return Ok(resolved);
            }

            Ok(resolved)
        }
        Ok(_) => Ok(path.to_path_buf()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(path.to_path_buf()),
        Err(err) => Err(format!("failed to inspect path {}: {err}", path.display())),
    }
}

fn is_code_file(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| CODE_EXTENSIONS.contains(&ext))
        .unwrap_or(false)
}

fn ensure_queue_helper_executable(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path).map_err(|_| {
        format!(
            "queue helper not found or not executable: {}",
            path.display()
        )
    })?;

    if !metadata.is_file() {
        return Err(format!(
            "queue helper not found or not executable: {}",
            path.display()
        ));
    }

    #[cfg(unix)]
    {
        if metadata.permissions().mode() & 0o111 == 0 {
            return Err(format!(
                "queue helper not found or not executable: {}",
                path.display()
            ));
        }
    }

    Ok(())
}

fn invoke_queue_helper(request: &EnqueueRequest) -> Result<String> {
    let output = Command::new(&request.queue_helper)
        .arg("enqueue")
        .arg("--repo-root")
        .arg(&request.repo_root)
        .arg("--file-path")
        .arg(&request.file_path)
        .arg("--source")
        .arg(&request.source)
        .arg("--export-json")
        .arg(&request.queue_file)
        .output()
        .map_err(|err| {
            format!(
                "Failed to enqueue DB review queue item for: {} ({err})",
                request.file_path
            )
        })?;

    if !output.status.success() {
        return Err(format!(
            "Failed to enqueue DB review queue item for: {}",
            request.file_path
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn parse_duplicate_flag(output: &str) -> bool {
    serde_json::from_str::<Value>(output)
        .ok()
        .and_then(|value| value.get("duplicate").and_then(Value::as_bool))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn test_config() -> ReviewQueueConfig {
        let dir = tempdir().unwrap();
        let repo_root = dir.keep();
        let queue_helper = repo_root.join("scripts/semantic-review-queue.sh");
        let queue_file = repo_root.join(".claude/tmp/review_queue.json");
        fs::create_dir_all(queue_helper.parent().unwrap()).unwrap();
        fs::write(&queue_helper, "#!/usr/bin/env bash\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            let mut perms = fs::metadata(&queue_helper).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&queue_helper, perms).unwrap();
        }
        ReviewQueueConfig {
            repo_root,
            queue_helper,
            queue_file,
        }
    }

    #[test]
    fn test_is_code_file_matches_live_allowlist() {
        assert!(is_code_file("src/main.rs"));
        assert!(is_code_file("hooks/codex-review-hook.sh"));
        assert!(is_code_file("apps/web/page.tsx"));
        assert!(is_code_file("src/native.cpp"));
        assert!(!is_code_file("README.md"));
        assert!(!is_code_file("config.json"));
        assert!(!is_code_file("schema.yaml"));
        assert!(!is_code_file("src/component.jsx"));
    }

    #[test]
    fn test_invalid_json_is_ignored() {
        let config = test_config();
        let result = process_hook_input("not json", &config).unwrap();
        assert!(!result.enqueued);
        assert_eq!(result.reason, "invalid hook input");
    }

    #[test]
    fn test_non_write_tool_is_ignored() {
        let config = test_config();
        let input = r#"{"tool_name":"Bash","tool_input":{"file_path":"src/main.rs"}}"#;
        let result = process_hook_input(input, &config).unwrap();
        assert!(!result.enqueued);
        assert!(result.reason.contains("not a write tool"));
    }

    #[test]
    fn test_missing_file_path_is_ignored() {
        let config = test_config();
        let input = r#"{"tool_name":"Edit","tool_input":{}}"#;
        let result = process_hook_input(input, &config).unwrap();
        assert!(!result.enqueued);
        assert_eq!(result.reason, "no file_path in tool_input");
    }

    #[test]
    fn test_repo_external_absolute_path_is_skipped() {
        let config = test_config();
        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"/tmp/outside.rs"}}"#;
        let result = process_hook_input_with(input, &config, |_request| {
            panic!("repo-external path should not be enqueued")
        })
        .unwrap();

        assert!(!result.enqueued);
        assert_eq!(result.reason, "outside repo");
        assert_eq!(
            result.log_message,
            Some("Skipping file outside repo: /tmp/outside.rs".to_string())
        );
    }

    #[test]
    fn test_relative_traversal_outside_repo_is_skipped() {
        let config = test_config();
        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"../outside.rs"}}"#;
        let result = process_hook_input_with(input, &config, |_request| {
            panic!("relative traversal should not be enqueued")
        })
        .unwrap();

        assert!(!result.enqueued);
        assert_eq!(result.reason, "outside repo");
        assert_eq!(
            result.log_message,
            Some("Skipping file outside repo: ../outside.rs".to_string())
        );
    }

    #[test]
    fn test_repo_absolute_path_is_normalized_before_enqueue() {
        let config = test_config();
        let absolute_path = format!("{}/src/main.rs", config.repo_root.display());
        let input =
            format!(r#"{{"tool_name":"Edit","tool_input":{{"file_path":"{absolute_path}"}}}}"#);
        let mut request = None;

        let result = process_hook_input_with(&input, &config, |enqueue_request| {
            request = Some(enqueue_request.clone());
            Ok(r#"{"duplicate":false}"#.to_string())
        })
        .unwrap();

        let request = request.expect("expected enqueue request");
        assert!(result.enqueued);
        assert_eq!(request.file_path, "src/main.rs");
        assert_eq!(request.source, "hook");
        assert_eq!(
            result.log_message,
            Some("Queued for review via DB authority: src/main.rs".to_string())
        );
    }

    #[test]
    fn test_relative_path_is_normalized_before_enqueue() {
        let config = test_config();
        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"src/../main.rs"}}"#;
        let mut request = None;

        let result = process_hook_input_with(input, &config, |enqueue_request| {
            request = Some(enqueue_request.clone());
            Ok(r#"{"duplicate":false}"#.to_string())
        })
        .unwrap();

        let request = request.expect("expected enqueue request");
        assert!(result.enqueued);
        assert_eq!(request.file_path, "main.rs");
    }

    #[test]
    fn test_non_code_file_is_ignored() {
        let config = test_config();
        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}"#;
        let result = process_hook_input_with(input, &config, |_request| {
            panic!("non-code files should not be enqueued")
        })
        .unwrap();

        assert!(!result.enqueued);
        assert_eq!(result.file_path, Some("CLAUDE.md".to_string()));
        assert_eq!(result.reason, "not a code file");
    }

    #[test]
    fn test_duplicate_flag_is_parsed_from_helper_output() {
        let config = test_config();
        let input = r#"{"tool_name":"Write","tool_input":{"file_path":"src/lib.rs"}}"#;
        let result = process_hook_input_with(input, &config, |_request| {
            Ok(r#"{"duplicate":true}"#.to_string())
        })
        .unwrap();

        assert!(result.enqueued);
        assert!(result.duplicate);
        assert_eq!(
            result.log_message,
            Some("Already pending in DB review queue: src/lib.rs".to_string())
        );
    }

    #[test]
    fn test_missing_queue_helper_is_strict() {
        let mut config = test_config();
        config.queue_helper = config.repo_root.join("scripts/missing-review-queue.sh");
        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"src/main.rs"}}"#;
        let result = process_hook_input(input, &config);

        assert!(result.is_err());
        let error = result.unwrap_err();
        assert!(error.contains("queue helper not found or not executable"));
    }

    #[cfg(unix)]
    #[test]
    fn test_symlink_escape_is_skipped() {
        use std::os::unix::fs::symlink;

        let config = test_config();
        let outside_dir = tempdir().unwrap();
        let link_path = config.repo_root.join("escape-link");
        symlink(outside_dir.path(), &link_path).unwrap();

        let input = r#"{"tool_name":"Edit","tool_input":{"file_path":"escape-link/outside.rs"}}"#;
        let result = process_hook_input_with(input, &config, |_request| {
            panic!("symlink escape should not be enqueued")
        })
        .unwrap();

        assert!(!result.enqueued);
        assert_eq!(result.reason, "outside repo");
        assert_eq!(
            result.log_message,
            Some("Skipping file outside repo: escape-link/outside.rs".to_string())
        );
    }

    #[test]
    fn test_helper_output_without_duplicate_defaults_false() {
        let config = test_config();
        let input = r#"{"tool_name":"Write","tool_input":{"file_path":"src/lib.rs"}}"#;
        let result =
            process_hook_input_with(input, &config, |_request| Ok("not json".to_string())).unwrap();

        assert!(result.enqueued);
        assert!(!result.duplicate);
    }
}
