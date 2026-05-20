//! Lease registry validation and lifecycle mutation for Rev Harness gates.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use clap::{Args, Subcommand};
use serde::Serialize;
use serde_json::{Map, Value};
use tempfile::NamedTempFile;

use shared::error::{AgentError, Result};

const REGISTRY_SCHEMA_VERSION: &str = "rev-harness-agent-lease-registry/v1";
const GUARD_SCHEMA_VERSION: &str = "rev-harness-lease-guard/v1";
const LIFECYCLE_SCHEMA_VERSION: &str = "rev-harness-lease-lifecycle/v1";

#[derive(Subcommand, Debug)]
pub enum LeaseAction {
    /// Validate that every lease in a registry is closed.
    Validate {
        /// Lease registry JSON file.
        #[arg(long)]
        file: PathBuf,
        /// Repository root used to resolve artifact paths.
        #[arg(long)]
        repo_root: Option<PathBuf>,
        /// Emit JSON output compatible with rev-harness-lease-guard.sh.
        #[arg(long)]
        json: bool,
    },
    /// Append a running lease to a registry.
    Open(OpenArgs),
    /// Refresh the heartbeat timestamp for a running lease.
    Heartbeat(LeaseIdArgs),
    /// Close a running lease as completed with traceable artifacts.
    Close(ArtifactCloseArgs),
    /// Close a running lease as blocked with traceable artifacts.
    Block(ArtifactCloseArgs),
    /// Reap stale running leases using a deterministic age threshold.
    Reap(ReapArgs),
}

#[derive(Debug, Serialize)]
struct GuardResult {
    schema_version: &'static str,
    status: &'static str,
    file: String,
    repo_root: String,
    completion_allowed: bool,
    violations: Vec<String>,
}

#[derive(Args, Debug)]
pub struct OpenArgs {
    /// Lease registry JSON file.
    #[arg(long)]
    file: PathBuf,
    /// Repository root used to resolve registry and artifact paths.
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Stable lease identifier.
    #[arg(long)]
    lease_id: String,
    /// Agent provider that owns the lease.
    #[arg(long)]
    provider: String,
    /// Model label used by the worker.
    #[arg(long)]
    model: Option<String>,
    /// Human-readable purpose for the lease.
    #[arg(long)]
    purpose: String,
    /// Expected artifact path. May be repeated.
    #[arg(long = "artifact")]
    artifacts: Vec<String>,
    /// Override current time for deterministic tests.
    #[arg(long)]
    now: Option<String>,
    /// Emit JSON lifecycle output.
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
pub struct LeaseIdArgs {
    /// Lease registry JSON file.
    #[arg(long)]
    file: PathBuf,
    /// Repository root used to resolve registry and artifact paths.
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Stable lease identifier.
    #[arg(long)]
    lease_id: String,
    /// Override current time for deterministic tests.
    #[arg(long)]
    now: Option<String>,
    /// Emit JSON lifecycle output.
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
pub struct ArtifactCloseArgs {
    /// Lease registry JSON file.
    #[arg(long)]
    file: PathBuf,
    /// Repository root used to resolve registry and artifact paths.
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Stable lease identifier.
    #[arg(long)]
    lease_id: String,
    /// Traceable artifact path. May be repeated.
    #[arg(long = "artifact", required = true)]
    artifacts: Vec<String>,
    /// Override current time for deterministic tests.
    #[arg(long)]
    now: Option<String>,
    /// Emit JSON lifecycle output.
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
pub struct ReapArgs {
    /// Lease registry JSON file.
    #[arg(long)]
    file: PathBuf,
    /// Repository root used to resolve registry and artifact paths.
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Reap running leases older than this many seconds.
    #[arg(long)]
    stale_seconds: i64,
    /// Traceable artifact path for every reaped lease. May be repeated.
    #[arg(long = "artifact", required = true)]
    artifacts: Vec<String>,
    /// Override current time for deterministic tests.
    #[arg(long)]
    now: Option<String>,
    /// Emit JSON lifecycle output.
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Serialize)]
struct LifecycleResult {
    schema_version: &'static str,
    status: &'static str,
    action: &'static str,
    file: String,
    repo_root: String,
    changed: bool,
    lease_ids: Vec<String>,
}

pub fn run(action: LeaseAction) -> Result<()> {
    match action {
        LeaseAction::Validate {
            file,
            repo_root,
            json,
        } => {
            let repo_root = canonical_repo_root(repo_root.as_deref())?;
            let result = validate_registry(&file, &repo_root);
            emit_result(&result, &file, &repo_root, json)?;
            if result.is_empty() {
                Ok(())
            } else {
                std::process::exit(1);
            }
        }
        LeaseAction::Open(args) => {
            let repo_root = canonical_repo_root(args.repo_root.as_deref())?;
            let now = parse_now(args.now.as_deref())?;
            let mut registry = load_registry_for_mutation(&args.file, &repo_root, true)?;
            ensure_provider(&args.provider)?;
            ensure_non_empty("lease-id", &args.lease_id)?;
            ensure_non_empty("purpose", &args.purpose)?;
            validate_expected_artifacts(&args.artifacts, &repo_root)?;
            let leases = leases_array_mut(&mut registry)?;
            if find_lease_index(leases, &args.lease_id).is_some() {
                return Err(AgentError::Validation(format!(
                    "lease already exists: {}",
                    args.lease_id
                )));
            }
            let now_s = fmt_time(now);
            let mut lease = Map::new();
            lease.insert("lease_id".to_string(), Value::String(args.lease_id.clone()));
            lease.insert("provider".to_string(), Value::String(args.provider));
            lease.insert("state".to_string(), Value::String("running".to_string()));
            if let Some(model) = args.model {
                ensure_non_empty("model", &model)?;
                lease.insert("model".to_string(), Value::String(model));
            }
            lease.insert("purpose".to_string(), Value::String(args.purpose));
            lease.insert("started_at".to_string(), Value::String(now_s.clone()));
            lease.insert("last_heartbeat_at".to_string(), Value::String(now_s));
            lease.insert(
                "artifact_paths".to_string(),
                Value::Array(args.artifacts.into_iter().map(Value::String).collect()),
            );
            leases.push(Value::Object(lease));
            atomic_write_registry(&args.file, &repo_root, &registry)?;
            emit_lifecycle_result(
                "open",
                &args.file,
                &repo_root,
                true,
                vec![args.lease_id],
                args.json,
            )
        }
        LeaseAction::Heartbeat(args) => {
            let repo_root = canonical_repo_root(args.repo_root.as_deref())?;
            let now = parse_now(args.now.as_deref())?;
            let mut registry = load_registry_for_mutation(&args.file, &repo_root, false)?;
            let lease = find_running_lease_mut(&mut registry, &args.lease_id)?;
            lease.insert(
                "last_heartbeat_at".to_string(),
                Value::String(fmt_time(now)),
            );
            atomic_write_registry(&args.file, &repo_root, &registry)?;
            emit_lifecycle_result(
                "heartbeat",
                &args.file,
                &repo_root,
                true,
                vec![args.lease_id],
                args.json,
            )
        }
        LeaseAction::Close(args) => close_lease(args, "completed", "completed_at", "close"),
        LeaseAction::Block(args) => close_lease(args, "blocked", "blocked_at", "block"),
        LeaseAction::Reap(args) => reap_leases(args),
    }
}

fn close_lease(
    args: ArtifactCloseArgs,
    state: &'static str,
    timestamp_field: &'static str,
    action: &'static str,
) -> Result<()> {
    let repo_root = canonical_repo_root(args.repo_root.as_deref())?;
    let now = parse_now(args.now.as_deref())?;
    validate_existing_artifacts(&args.artifacts, &repo_root)?;
    let mut registry = load_registry_for_mutation(&args.file, &repo_root, false)?;
    let lease = find_running_lease_mut(&mut registry, &args.lease_id)?;
    lease.insert("state".to_string(), Value::String(state.to_string()));
    lease.insert(timestamp_field.to_string(), Value::String(fmt_time(now)));
    lease.insert(
        "artifact_paths".to_string(),
        Value::Array(args.artifacts.into_iter().map(Value::String).collect()),
    );
    atomic_write_registry(&args.file, &repo_root, &registry)?;
    emit_lifecycle_result(
        action,
        &args.file,
        &repo_root,
        true,
        vec![args.lease_id],
        args.json,
    )
}

fn reap_leases(args: ReapArgs) -> Result<()> {
    if args.stale_seconds < 0 {
        return Err(AgentError::Validation(
            "--stale-seconds must be non-negative".to_string(),
        ));
    }
    let repo_root = canonical_repo_root(args.repo_root.as_deref())?;
    let now = parse_now(args.now.as_deref())?;
    validate_existing_artifacts(&args.artifacts, &repo_root)?;
    let mut registry = load_registry_for_mutation(&args.file, &repo_root, false)?;
    let leases = leases_array_mut(&mut registry)?;
    let mut reaped = Vec::new();
    for lease in leases.iter_mut().filter_map(Value::as_object_mut) {
        if non_empty_str(lease.get("state")) != Some("running") {
            continue;
        }
        let Some(lease_id) = non_empty_str(lease.get("lease_id")).map(ToOwned::to_owned) else {
            continue;
        };
        let timestamp = non_empty_str(lease.get("last_heartbeat_at"))
            .or_else(|| non_empty_str(lease.get("started_at")))
            .ok_or_else(|| {
                AgentError::Validation(format!(
                    "running lease missing last_heartbeat_at/started_at: {lease_id}"
                ))
            })?;
        let observed = parse_rfc3339(timestamp)?;
        if now.signed_duration_since(observed).num_seconds() >= args.stale_seconds {
            lease.insert("state".to_string(), Value::String("reaped".to_string()));
            lease.insert("reaped_at".to_string(), Value::String(fmt_time(now)));
            lease.insert(
                "artifact_paths".to_string(),
                Value::Array(args.artifacts.iter().cloned().map(Value::String).collect()),
            );
            reaped.push(lease_id);
        }
    }
    let changed = !reaped.is_empty();
    if changed {
        atomic_write_registry(&args.file, &repo_root, &registry)?;
    }
    emit_lifecycle_result("reap", &args.file, &repo_root, changed, reaped, args.json)
}

fn validate_registry(file: &Path, repo_root: &Path) -> Vec<String> {
    let mut violations = Vec::new();
    let Ok(raw) = fs::read_to_string(file) else {
        violations.push(format!("file must be readable: {}", file.display()));
        return violations;
    };
    let Ok(manifest) = serde_json::from_str::<Value>(&raw) else {
        violations.push("manifest is not valid JSON".to_string());
        return violations;
    };

    let Some(leases) = validate_manifest_shape(&manifest, &mut violations) else {
        return violations;
    };

    if leases.is_empty() {
        violations.push("leases array must not be empty for a completion gate".to_string());
        return violations;
    }

    for (idx, lease) in leases.iter().enumerate() {
        validate_lease(idx, lease, repo_root, &mut violations);
    }

    violations
}

fn load_registry_for_mutation(file: &Path, repo_root: &Path, create: bool) -> Result<Value> {
    ensure_registry_file_path(file, repo_root)?;
    if !file.exists() {
        if create {
            let mut manifest = Map::new();
            manifest.insert(
                "schema_version".to_string(),
                Value::String(REGISTRY_SCHEMA_VERSION.to_string()),
            );
            manifest.insert("leases".to_string(), Value::Array(Vec::new()));
            return Ok(Value::Object(manifest));
        }
        return Err(AgentError::Validation(format!(
            "lease registry file must exist: {}",
            file.display()
        )));
    }
    let raw = fs::read_to_string(file)?;
    let manifest = serde_json::from_str::<Value>(&raw)?;
    let mut violations = Vec::new();
    if let Some(leases) = validate_manifest_shape(&manifest, &mut violations) {
        validate_existing_leases_for_mutation(leases, repo_root, &mut violations);
    }
    if !violations.is_empty() {
        return Err(AgentError::Validation(violations.join("; ")));
    }
    Ok(manifest)
}

fn validate_manifest_shape<'a>(
    manifest: &'a Value,
    violations: &mut Vec<String>,
) -> Option<&'a Vec<Value>> {
    let valid = manifest.is_object()
        && manifest
            .get("schema_version")
            .and_then(Value::as_str)
            .is_some_and(|schema| schema == REGISTRY_SCHEMA_VERSION)
        && manifest.get("leases").is_some_and(Value::is_array)
        && manifest
            .get("leases")
            .and_then(Value::as_array)
            .is_some_and(|leases| leases.iter().all(Value::is_object));

    if !valid {
        violations.push(
            "manifest must use schema_version rev-harness-agent-lease-registry/v1 and leases array"
                .to_string(),
        );
        return None;
    }

    manifest.get("leases").and_then(Value::as_array)
}

fn leases_array_mut(manifest: &mut Value) -> Result<&mut Vec<Value>> {
    manifest
        .get_mut("leases")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| {
            AgentError::Validation(
                "manifest must use schema_version rev-harness-agent-lease-registry/v1 and leases array"
                    .to_string(),
            )
        })
}

fn find_lease_index(leases: &[Value], lease_id: &str) -> Option<usize> {
    leases
        .iter()
        .position(|lease| non_empty_str(lease.get("lease_id")) == Some(lease_id))
}

fn find_running_lease_mut<'a>(
    manifest: &'a mut Value,
    lease_id: &str,
) -> Result<&'a mut Map<String, Value>> {
    ensure_non_empty("lease-id", lease_id)?;
    let leases = leases_array_mut(manifest)?;
    let idx = find_lease_index(leases, lease_id)
        .ok_or_else(|| AgentError::Validation(format!("lease not found: {lease_id}")))?;
    let lease = leases[idx]
        .as_object_mut()
        .ok_or_else(|| AgentError::Validation(format!("lease must be an object: {lease_id}")))?;
    match non_empty_str(lease.get("state")) {
        Some("running") => Ok(lease),
        Some(state) => Err(AgentError::Validation(format!(
            "lease is not running: {lease_id} state={state}"
        ))),
        None => Err(AgentError::Validation(format!(
            "lease state must be a non-empty string: {lease_id}"
        ))),
    }
}

fn validate_lease(idx: usize, lease: &Value, repo_root: &Path, violations: &mut Vec<String>) {
    let lease_id = match non_empty_str(lease.get("lease_id")) {
        Some(value) => value.to_string(),
        None => {
            violations.push(format!("lease[{idx}] missing lease_id"));
            String::new()
        }
    };
    let lease_label = || {
        if lease_id.is_empty() {
            "<missing>"
        } else {
            lease_id.as_str()
        }
    };

    match non_empty_str(lease.get("provider")) {
        Some("codex" | "claude") => {}
        Some(provider) => {
            violations.push(format!("lease[{idx}] has unsupported provider: {provider}"))
        }
        None => violations.push(format!(
            "lease[{idx}] {} provider must be a non-empty string",
            lease_label()
        )),
    }

    match non_empty_str(lease.get("state")) {
        Some("completed" | "blocked" | "reaped") => {}
        Some("running" | "stale" | "failed") => violations.push(format!(
            "lease[{idx}] {} is not closed: {}",
            lease_label(),
            non_empty_str(lease.get("state")).unwrap_or_default()
        )),
        Some(state) => violations.push(format!(
            "lease[{idx}] {} has unknown state: {state}",
            lease_label()
        )),
        None => violations.push(format!(
            "lease[{idx}] {} state must be a non-empty string",
            lease_label()
        )),
    }

    let Some(artifacts) = lease.get("artifact_paths").and_then(Value::as_array) else {
        violations.push(format!(
            "lease[{idx}] {} must include at least one artifact path",
            lease_label()
        ));
        return;
    };
    if artifacts.is_empty() {
        violations.push(format!(
            "lease[{idx}] {} must include at least one artifact path",
            lease_label()
        ));
        return;
    }
    if !artifacts
        .iter()
        .all(|artifact| non_empty_str(Some(artifact)).is_some())
    {
        violations.push(format!(
            "lease[{idx}] {} artifact paths must be non-empty strings",
            lease_label()
        ));
        return;
    }

    for artifact in artifacts.iter().filter_map(Value::as_str) {
        let Some(abs) = artifact_abs_path(artifact, repo_root) else {
            violations.push(format!(
                "lease[{idx}] {} artifact is missing or unsafe: {}",
                lease_label(),
                if artifact.is_empty() {
                    "<empty>"
                } else {
                    artifact
                }
            ));
            continue;
        };
        if !is_under_or_equal(&abs, repo_root) {
            violations.push(format!(
                "lease[{idx}] {} artifact escapes repo root: {artifact}",
                lease_label()
            ));
        }
    }
}

fn validate_existing_leases_for_mutation(
    leases: &[Value],
    repo_root: &Path,
    violations: &mut Vec<String>,
) {
    let mut seen = HashSet::new();
    for (idx, lease) in leases.iter().enumerate() {
        let Some(lease_obj) = lease.as_object() else {
            violations.push(format!("lease[{idx}] must be an object"));
            continue;
        };
        let lease_id = match non_empty_str(lease_obj.get("lease_id")) {
            Some(value) => {
                if !seen.insert(value.to_string()) {
                    violations.push(format!("lease[{idx}] duplicate lease_id: {value}"));
                }
                value.to_string()
            }
            None => {
                violations.push(format!("lease[{idx}] missing lease_id"));
                String::new()
            }
        };
        let lease_label = || {
            if lease_id.is_empty() {
                "<missing>"
            } else {
                lease_id.as_str()
            }
        };

        match non_empty_str(lease_obj.get("provider")) {
            Some("codex" | "claude") => {}
            Some(provider) => {
                violations.push(format!("lease[{idx}] has unsupported provider: {provider}"))
            }
            None => violations.push(format!(
                "lease[{idx}] {} provider must be a non-empty string",
                lease_label()
            )),
        }

        let state = match non_empty_str(lease_obj.get("state")) {
            Some("completed" | "blocked" | "reaped" | "running" | "stale" | "failed") => {
                non_empty_str(lease_obj.get("state")).unwrap_or_default()
            }
            Some(state) => {
                violations.push(format!(
                    "lease[{idx}] {} has unknown state: {state}",
                    lease_label()
                ));
                ""
            }
            None => {
                violations.push(format!(
                    "lease[{idx}] {} state must be a non-empty string",
                    lease_label()
                ));
                ""
            }
        };

        let Some(artifacts) = lease_obj.get("artifact_paths").and_then(Value::as_array) else {
            violations.push(format!(
                "lease[{idx}] {} must include at least one artifact path",
                lease_label()
            ));
            continue;
        };
        if artifacts.is_empty() {
            violations.push(format!(
                "lease[{idx}] {} must include at least one artifact path",
                lease_label()
            ));
            continue;
        }
        if !artifacts
            .iter()
            .all(|artifact| non_empty_str(Some(artifact)).is_some())
        {
            violations.push(format!(
                "lease[{idx}] {} artifact paths must be non-empty strings",
                lease_label()
            ));
            continue;
        }

        for artifact in artifacts.iter().filter_map(Value::as_str) {
            let abs = if matches!(state, "completed" | "blocked" | "reaped") {
                artifact_abs_path(artifact, repo_root)
            } else {
                expected_artifact_abs_path(artifact, repo_root)
            };
            let Some(abs) = abs else {
                violations.push(format!(
                    "lease[{idx}] {} artifact is missing or unsafe: {}",
                    lease_label(),
                    if artifact.is_empty() {
                        "<empty>"
                    } else {
                        artifact
                    }
                ));
                continue;
            };
            if !is_under_or_equal(&abs, repo_root) {
                violations.push(format!(
                    "lease[{idx}] {} artifact escapes repo root: {artifact}",
                    lease_label()
                ));
            }
        }
    }
}

fn non_empty_str(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn ensure_non_empty(name: &str, value: &str) -> Result<()> {
    if value.is_empty() {
        return Err(AgentError::Validation(format!("{name} must be non-empty")));
    }
    Ok(())
}

fn ensure_provider(provider: &str) -> Result<()> {
    match provider {
        "codex" | "claude" => Ok(()),
        _ => Err(AgentError::Validation(format!(
            "provider must be codex or claude: {provider}"
        ))),
    }
}

fn canonical_repo_root(input: Option<&Path>) -> Result<PathBuf> {
    let raw = match input {
        Some(path) => path.to_path_buf(),
        None => std::env::current_dir()?,
    };
    let canonical = fs::canonicalize(&raw).map_err(|_| {
        AgentError::Validation(format!(
            "--repo-root must be an existing directory: {}",
            raw.display()
        ))
    })?;
    if !canonical.is_dir() {
        return Err(AgentError::Validation(format!(
            "--repo-root must be an existing directory: {}",
            raw.display()
        )));
    }
    Ok(canonical)
}

fn artifact_abs_path(artifact: &str, repo_root: &Path) -> Option<PathBuf> {
    if artifact.is_empty() || has_unsafe_dot_component(artifact) {
        return None;
    }

    let raw = Path::new(artifact);
    let abs = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        repo_root.join(raw)
    };

    let metadata = fs::symlink_metadata(&abs).ok()?;
    if metadata.file_type().is_symlink() {
        return None;
    }

    if metadata.is_dir() {
        return fs::canonicalize(&abs).ok();
    }

    let parent = abs.parent()?;
    let base = abs.file_name()?;
    if base.is_empty() {
        return None;
    }
    let parent_real = fs::canonicalize(parent).ok()?;
    Some(parent_real.join(base))
}

fn expected_artifact_abs_path(artifact: &str, repo_root: &Path) -> Option<PathBuf> {
    if artifact.is_empty() || has_unsafe_dot_component(artifact) {
        return None;
    }

    let raw = Path::new(artifact);
    let abs = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        repo_root.join(raw)
    };
    let parent = abs.parent()?;
    let base = abs.file_name()?;
    if base.is_empty() {
        return None;
    }
    if fs::symlink_metadata(&abs)
        .ok()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        return None;
    }
    let parent_real = fs::canonicalize(parent).ok()?;
    Some(parent_real.join(base))
}

fn validate_expected_artifacts(artifacts: &[String], repo_root: &Path) -> Result<()> {
    if artifacts.is_empty() {
        return Err(AgentError::Validation(
            "at least one --artifact is required".to_string(),
        ));
    }
    for artifact in artifacts {
        let Some(abs) = expected_artifact_abs_path(artifact, repo_root) else {
            return Err(AgentError::Validation(format!(
                "artifact path is missing or unsafe: {artifact}"
            )));
        };
        if !is_under_or_equal(&abs, repo_root) {
            return Err(AgentError::Validation(format!(
                "artifact escapes repo root: {artifact}"
            )));
        }
    }
    Ok(())
}

fn validate_existing_artifacts(artifacts: &[String], repo_root: &Path) -> Result<()> {
    if artifacts.is_empty() {
        return Err(AgentError::Validation(
            "at least one --artifact is required".to_string(),
        ));
    }
    for artifact in artifacts {
        let Some(abs) = artifact_abs_path(artifact, repo_root) else {
            return Err(AgentError::Validation(format!(
                "artifact is missing or unsafe: {artifact}"
            )));
        };
        if !is_under_or_equal(&abs, repo_root) {
            return Err(AgentError::Validation(format!(
                "artifact escapes repo root: {artifact}"
            )));
        }
    }
    Ok(())
}

fn ensure_registry_file_path(file: &Path, repo_root: &Path) -> Result<()> {
    let path = if file.is_absolute() {
        file.to_path_buf()
    } else {
        repo_root.join(file)
    };
    let parent = path.parent().ok_or_else(|| {
        AgentError::Validation(format!(
            "registry file must have a parent: {}",
            file.display()
        ))
    })?;
    let parent_real = fs::canonicalize(parent).map_err(|_| {
        AgentError::Validation(format!(
            "registry parent must be an existing directory: {}",
            parent.display()
        ))
    })?;
    if !is_under_or_equal(&parent_real, repo_root) {
        return Err(AgentError::Validation(format!(
            "registry file must be under repo root: {}",
            file.display()
        )));
    }
    if fs::symlink_metadata(&path)
        .ok()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(AgentError::Validation(format!(
            "registry file must not be a symlink: {}",
            file.display()
        )));
    }
    Ok(())
}

fn atomic_write_registry(file: &Path, repo_root: &Path, manifest: &Value) -> Result<()> {
    ensure_registry_file_path(file, repo_root)?;
    let target = if file.is_absolute() {
        file.to_path_buf()
    } else {
        repo_root.join(file)
    };
    let parent = target.parent().ok_or_else(|| {
        AgentError::Validation(format!(
            "registry file must have a parent: {}",
            file.display()
        ))
    })?;
    let json = format!("{}\n", serde_json::to_string_pretty(manifest)?);
    let mut tmp = NamedTempFile::new_in(parent)?;
    tmp.write_all(json.as_bytes())?;
    tmp.as_file().sync_all()?;
    tmp.persist(&target)
        .map_err(|error| AgentError::Io(error.error))?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn parse_now(input: Option<&str>) -> Result<DateTime<Utc>> {
    match input {
        Some(value) => parse_rfc3339(value),
        None => Ok(Utc::now()),
    }
}

fn parse_rfc3339(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|_| AgentError::Validation(format!("timestamp must be RFC3339: {value}")))
}

fn fmt_time(value: DateTime<Utc>) -> String {
    value.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn has_unsafe_dot_component(path: &str) -> bool {
    path == "."
        || path == ".."
        || path.starts_with("./")
        || path.starts_with("../")
        || path.ends_with("/.")
        || path.ends_with("/..")
        || path.contains("/./")
        || path.contains("/../")
}

fn is_under_or_equal(path: &Path, base: &Path) -> bool {
    path == base || path.starts_with(base)
}

fn emit_result(violations: &[String], file: &Path, repo_root: &Path, json: bool) -> Result<()> {
    let status = if violations.is_empty() {
        "PASS"
    } else {
        "BLOCK"
    };
    if json {
        let result = GuardResult {
            schema_version: GUARD_SCHEMA_VERSION,
            status,
            file: file.to_string_lossy().into_owned(),
            repo_root: repo_root.to_string_lossy().into_owned(),
            completion_allowed: violations.is_empty(),
            violations: violations.to_vec(),
        };
        println!("{}", serde_json::to_string(&result)?);
        return Ok(());
    }

    println!("status: {status}");
    println!("completion_allowed: {}", violations.is_empty());
    if !violations.is_empty() {
        println!("violations:");
        for violation in violations {
            println!("- {violation}");
        }
    }
    Ok(())
}

fn emit_lifecycle_result(
    action: &'static str,
    file: &Path,
    repo_root: &Path,
    changed: bool,
    lease_ids: Vec<String>,
    json: bool,
) -> Result<()> {
    if json {
        let result = LifecycleResult {
            schema_version: LIFECYCLE_SCHEMA_VERSION,
            status: "PASS",
            action,
            file: file.to_string_lossy().into_owned(),
            repo_root: repo_root.to_string_lossy().into_owned(),
            changed,
            lease_ids,
        };
        println!("{}", serde_json::to_string(&result)?);
        return Ok(());
    }

    println!("status: PASS");
    println!("action: {action}");
    println!("changed: {changed}");
    if !lease_ids.is_empty() {
        println!("lease_ids:");
        for lease_id in lease_ids {
            println!("- {lease_id}");
        }
    }
    Ok(())
}
