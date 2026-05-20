//! Specialty manifest linting and thin SKILL.md projection.

use clap::Subcommand;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use shared::error::{AgentError, Result};

use crate::cmd::envelope::LintFinding;

const CANONICAL_ROLES: [&str; 3] = ["coder", "reviewer", "orchestrator"];
const RUNTIME_ROLES: [&str; 3] = ["coder", "high-coder", "reviewer"];
const BASELINE_MATRIX_FIELDS: [&str; 8] = [
    "task_class",
    "schema_profile",
    "change_surface",
    "in_scope",
    "out_of_scope",
    "required_checks",
    "evidence_destination",
    "completion_boundary",
];

const CODER_SPECIALTY_EXTRA_FIELDS: [&str; 5] = [
    "worker_outcome",
    "task_id",
    "slice_id",
    "prior_slice_id",
    "bug_class_candidate",
];
const REVIEWER_SPECIALTY_EXTRA_FIELDS: [&str; 8] = [
    "worker_outcome",
    "review_request_target",
    "reviewer_verdict",
    "task_id",
    "slice_id",
    "prior_slice_id",
    "verification_verdict",
    "release_verdict",
];
const ORCHESTRATOR_SPECIALTY_EXTRA_FIELDS: [&str; 10] = [
    "task_id",
    "slice_id",
    "prior_slice_id",
    "context_token",
    "review_request_target",
    "class_closure_applicability",
    "re_slice_delta_type",
    "re_slice_delta_summary",
    "rollback_boundary",
    "migration_verification",
];

#[derive(Subcommand, Debug)]
pub enum SpecialtyAction {
    /// Validate a specialty file's manifest and required-section structure.
    Lint(LintArgs),
    /// Generate thin SKILL.md projections for specialties whose
    /// thin_skill_projection.enabled is true.
    Project(ProjectArgs),
}

#[derive(clap::Args, Debug)]
pub struct LintArgs {
    /// Specialty markdown file path(s) to lint.
    #[arg(required = true, num_args = 1..)]
    pub files: Vec<PathBuf>,
    /// Also check generated SKILL.md projections under .claude/skills/<slug>/
    /// and .agents/skills/<slug>/ for drift vs manifest.
    #[arg(long)]
    pub check_projections: bool,
    /// Write lint report JSON to this path (default stdout).
    #[arg(long)]
    pub output_json: Option<PathBuf>,
}

#[derive(clap::Args, Debug)]
pub struct ProjectArgs {
    /// Specialty slug to project (or use --all).
    #[arg(long, conflicts_with = "all")]
    pub slug: Option<String>,
    /// Project all specialties whose manifest.thin_skill_projection.enabled is true.
    #[arg(long, conflicts_with = "slug")]
    pub all: bool,
    /// Provider target.
    #[arg(long, default_value = "all", value_parser = ["claude", "codex", "all"])]
    pub provider: String,
    /// Root of the repo (auto-detected if omitted).
    #[arg(long)]
    pub repo_root: Option<PathBuf>,
}

#[derive(Deserialize, Serialize, Debug, Clone, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema_version: u32,
    pub slug: String,
    pub canonical_role: String,
    pub allowed_runtime_roles: Vec<String>,
    pub required_output_sections: Vec<String>,
    pub matrix_fields_allowed: Vec<String>,
    pub thin_skill_projection: ThinSkillProjection,
    pub summary_oneline: String,
    pub deprecated_aliases_forbidden: bool,
}

#[derive(Deserialize, Serialize, Debug, Clone, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ThinSkillProjection {
    pub enabled: bool,
    pub description_seed: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct SpecialtyLintReport {
    pub schema_version: u8,
    pub findings: Vec<LintFinding>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub manifest_hashes: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct LoadedSpecialty {
    #[allow(dead_code)]
    pub path: PathBuf,
    pub relative_path: PathBuf,
    pub manifest: Manifest,
    pub manifest_hash: String,
}

pub fn specialty_required_matrix_fields() -> &'static [&'static str] {
    &BASELINE_MATRIX_FIELDS
}

pub fn specialty_extra_fields_for(canonical_role: &str) -> &'static [&'static str] {
    match canonical_role {
        "coder" => &CODER_SPECIALTY_EXTRA_FIELDS,
        "reviewer" => &REVIEWER_SPECIALTY_EXTRA_FIELDS,
        "orchestrator" => &ORCHESTRATOR_SPECIALTY_EXTRA_FIELDS,
        _ => &[],
    }
}

pub fn allowed_specialty_fields_for(canonical_role: &str) -> BTreeSet<String> {
    let mut fields = matrix_vocabulary_top_level_fields();
    fields.extend(
        specialty_required_matrix_fields()
            .iter()
            .map(|field| field.to_string()),
    );
    fields.extend(
        specialty_extra_fields_for(canonical_role)
            .iter()
            .map(|field| field.to_string()),
    );
    fields
}

#[derive(Debug)]
struct ParsedManifest {
    manifest: Manifest,
    manifest_hash: String,
    json_start_line: usize,
}

#[derive(Debug)]
struct JsonBlock {
    start_line: usize,
    body: String,
}

pub fn run(action: SpecialtyAction) -> Result<()> {
    match action {
        SpecialtyAction::Lint(args) => run_lint_cli(args),
        SpecialtyAction::Project(args) => run_project_cli(args),
    }
}

fn run_lint_cli(args: LintArgs) -> Result<()> {
    let (report, error_count) = lint_files(&args.files, args.check_projections, None)?;
    let json = serde_json::to_string_pretty(&report).map_err(AgentError::Json)?;
    if let Some(output_json) = &args.output_json {
        if output_json == Path::new("/dev/stdout") || output_json == Path::new("-") {
            println!("{json}");
        } else {
            fs::write(output_json, json).map_err(AgentError::Io)?;
        }
    } else {
        println!("{json}");
    }

    if error_count > 0 {
        std::process::exit(error_count.min(255) as i32);
    }
    Ok(())
}

fn run_project_cli(args: ProjectArgs) -> Result<()> {
    let repo_root = detect_repo_root(args.repo_root.as_deref())?;
    let loaded = if args.all {
        find_all_specialties(&repo_root)?
    } else if let Some(slug) = &args.slug {
        vec![load_specialty_by_slug(&repo_root, slug)?]
    } else {
        return Err(AgentError::Validation(
            "project requires --slug <slug> or --all".to_string(),
        ));
    };

    for specialty in loaded {
        if !specialty.manifest.thin_skill_projection.enabled {
            if args.all {
                eprintln!(
                    "skip {}: thin_skill_projection.enabled=false",
                    specialty.manifest.slug
                );
                continue;
            }
            return Err(AgentError::Validation(format!(
                "specialty `{}` has thin_skill_projection.enabled=false",
                specialty.manifest.slug
            )));
        }
        let written = project_specialty(&repo_root, &specialty, &args.provider)?;
        eprintln!(
            "projected {} hash={} paths={}",
            specialty.manifest.slug,
            specialty.manifest_hash,
            written
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok(())
}

pub fn load_specialty_by_slug(repo_root: &Path, slug: &str) -> Result<LoadedSpecialty> {
    if !valid_slug(slug) {
        return Err(AgentError::Validation(format!(
            "invalid specialty slug `{slug}`"
        )));
    }

    let mut matches = Vec::new();
    for role in CANONICAL_ROLES {
        let path = repo_root
            .join("docs")
            .join("roles")
            .join(role)
            .join("specialties")
            .join(format!("{slug}.md"));
        if path.exists() {
            matches.push(path);
        }
    }

    match matches.len() {
        0 => Err(AgentError::NotFound(format!(
            "specialty file for slug `{slug}` under docs/roles/*/specialties"
        ))),
        1 => load_specialty_file(repo_root, &matches[0]),
        _ => Err(AgentError::Validation(format!(
            "multiple specialty files found for slug `{slug}`"
        ))),
    }
}

pub fn find_all_specialties(repo_root: &Path) -> Result<Vec<LoadedSpecialty>> {
    let mut specialties = Vec::new();
    for role in CANONICAL_ROLES {
        let dir = repo_root
            .join("docs")
            .join("roles")
            .join(role)
            .join("specialties");
        if !dir.exists() {
            continue;
        }
        let mut entries = fs::read_dir(&dir)
            .map_err(AgentError::Io)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(AgentError::Io)?;
        entries.sort_by_key(|entry| entry.path());
        for entry in entries {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) == Some("md") {
                specialties.push(load_specialty_file(repo_root, &path)?);
            }
        }
    }
    Ok(specialties)
}

pub fn load_specialty_file(repo_root: &Path, path: &Path) -> Result<LoadedSpecialty> {
    let content = fs::read_to_string(path).map_err(AgentError::Io)?;
    let parsed = parse_manifest_from_content(path, &content).map_err(|e| {
        AgentError::Validation(format!(
            "invalid specialty manifest in {}: {e}",
            path.display()
        ))
    })?;
    let relative_path = path.strip_prefix(repo_root).unwrap_or(path).to_path_buf();
    Ok(LoadedSpecialty {
        path: path.to_path_buf(),
        relative_path,
        manifest: parsed.manifest,
        manifest_hash: parsed.manifest_hash,
    })
}

pub fn detect_repo_root(explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(root) = explicit {
        return Ok(root.to_path_buf());
    }

    let mut current = std::env::current_dir().map_err(AgentError::Io)?;
    loop {
        if current.join("docs").join("roles").is_dir() {
            return Ok(current);
        }
        if !current.pop() {
            break;
        }
    }
    Err(AgentError::NotFound(
        "could not auto-detect repo root containing docs/roles".to_string(),
    ))
}

pub fn project_specialty(
    repo_root: &Path,
    specialty: &LoadedSpecialty,
    provider: &str,
) -> Result<Vec<PathBuf>> {
    if !specialty.manifest.thin_skill_projection.enabled {
        return Err(AgentError::Validation(format!(
            "specialty `{}` has thin_skill_projection.enabled=false",
            specialty.manifest.slug
        )));
    }

    let body = skill_body(specialty);
    let mut targets = Vec::new();
    match provider {
        "claude" | "all" => targets.push(
            repo_root
                .join(".claude")
                .join("skills")
                .join(&specialty.manifest.slug)
                .join("SKILL.md"),
        ),
        _ => {}
    }
    match provider {
        "codex" | "all" => targets.push(
            repo_root
                .join(".agents")
                .join("skills")
                .join(&specialty.manifest.slug)
                .join("SKILL.md"),
        ),
        _ => {}
    }

    for target in &targets {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(AgentError::Io)?;
        }
        fs::write(target, &body).map_err(AgentError::Io)?;
    }
    Ok(targets)
}

pub fn skill_body(specialty: &LoadedSpecialty) -> String {
    let slug = &specialty.manifest.slug;
    let description = &specialty.manifest.thin_skill_projection.description_seed;
    let source = specialty.relative_path.to_string_lossy();
    let canonical = &specialty.manifest.canonical_role;
    let hash = &specialty.manifest_hash;
    let summary = &specialty.manifest.summary_oneline;
    let slug_yaml = yaml_quote(slug);
    let description_yaml = yaml_quote(description);
    let source_yaml = yaml_quote(source.as_ref());
    let canonical_yaml = yaml_quote(canonical);
    let hash_yaml = yaml_quote(hash);
    let (role_lens, invocation_intro, invocation_bullets) = match canonical.as_str() {
        "orchestrator" => (
            "Orchestrator-primary lens",
            format!(
                "This skill is a SELECTION HINT (lens), not a workflow owner. It is an \
Orchestrator-primary lens. For workflow execution, use auto-orchestrator / \
system-planner / review-workflow / codex-caller as appropriate. The \
orchestrator reads `{source}` directly; this skill auto-trigger is a discovery \
hint only."
            ),
            format!(
                "Orchestrator direct Read:\n\
- Read `{source}` directly and apply its required_output_sections.\n\
- Treat this skill auto-trigger as discovery only; do NOT use it as a substitute for workflow skills."
            ),
        ),
        "coder" => (
            "Coder lens",
            format!(
                "This skill is a SELECTION HINT (lens), not a workflow owner. It is a \
Coder lens. The orchestrator selects this specialty and invokes it via \
`scripts/codex-wrapper.sh --role coder --specialty {slug}` or \
`scripts/codex-wrapper.sh --role high-coder --specialty {slug}` for \
security-sensitive cases. This skill auto-trigger is a discovery hint; primary \
invocation is the wrapper flag."
            ),
            format!(
                "Coder wrapper flag:\n\
- Primary invocation: `scripts/codex-wrapper.sh --role coder --specialty {slug}`.\n\
- Use `scripts/codex-wrapper.sh --role high-coder --specialty {slug}` for security-sensitive cases.\n\
- The orchestrator still reads `{source}` as the canonical specialty file."
            ),
        ),
        "reviewer" => (
            "Reviewer lens",
            format!(
                "This skill is a SELECTION HINT (lens), not a workflow owner. It is a \
Reviewer lens. Primary invocation is \
`scripts/codex-wrapper.sh --role reviewer --specialty {slug}`. This skill \
auto-trigger is a discovery hint; primary invocation is the wrapper flag."
            ),
            format!(
                "Reviewer wrapper flag:\n\
- Primary invocation: `scripts/codex-wrapper.sh --role reviewer --specialty {slug}`.\n\
- The orchestrator selects this specialty before review and records `{source}` as the canonical source."
            ),
        ),
        _ => (
            "Specialty lens",
            format!(
                "This skill is a SELECTION HINT (lens), not a workflow owner. Read \
`{source}` directly and follow its required_output_sections."
            ),
            format!("- Read `{source}` directly and apply."),
        ),
    };

    format!(
        "---\n\
name: {slug_yaml}\n\
description: {description_yaml}\n\
source_specialty_file: {source_yaml}\n\
source_manifest_hash: {hash_yaml}\n\
canonical_role: {canonical_yaml}\n\
generated_by: agent-core specialty project\n\
---\n\
\n\
# {slug}\n\
\n\
{invocation_intro}\n\
\n\
## Summary\n\
\n\
{summary}\n\
\n\
Lens type: {role_lens}\n\
Canonical source: `{source}`\n\
\n\
## How to invoke\n\
\n\
{invocation_bullets}\n\
\n\
Specialty manifest hash: `{hash}`\n"
    )
}

fn yaml_quote(value: &str) -> String {
    serde_json::to_string(value).expect("YAML double-quoted scalar serialization cannot fail")
}

pub fn manifest_hash(manifest: &Manifest) -> Result<String> {
    let value = serde_json::to_value(manifest).map_err(AgentError::Json)?;
    let bytes = canonical_json_bytes(&value)?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(hex::encode(hasher.finalize()))
}

pub fn lint_files(
    files: &[PathBuf],
    check_projections: bool,
    repo_root: Option<&Path>,
) -> Result<(SpecialtyLintReport, usize)> {
    let root = match repo_root {
        Some(root) => Some(root.to_path_buf()),
        None => detect_repo_root(None).ok(),
    };
    let mut findings = Vec::new();
    let mut manifest_hashes = Vec::new();

    for file in files {
        if is_projection_skill_path(file) {
            continue;
        }
        let content = fs::read_to_string(file).map_err(AgentError::Io)?;
        if let Some(hash) = lint_content(
            file,
            &content,
            check_projections,
            root.as_deref(),
            &mut findings,
        ) {
            manifest_hashes.push(hash);
        }
    }

    let manifest_hash = if manifest_hashes.len() == 1 {
        Some(manifest_hashes[0].clone())
    } else {
        None
    };
    let error_count = findings.iter().filter(|f| f.severity == "error").count();
    Ok((
        SpecialtyLintReport {
            schema_version: 1,
            findings,
            manifest_hash,
            manifest_hashes,
        },
        error_count,
    ))
}

fn lint_content(
    file: &Path,
    content: &str,
    check_projections: bool,
    repo_root: Option<&Path>,
    findings: &mut Vec<LintFinding>,
) -> Option<String> {
    lint_manifest_block_position(file, content, findings);
    let parsed = match parse_manifest_from_content(file, content) {
        Ok(parsed) => parsed,
        Err(message) => {
            findings.push(finding(
                "specialty.manifest-valid",
                "error",
                file,
                1,
                1,
                message,
                "Add exactly one valid top-of-file JSON manifest block matching Manifest v0."
                    .to_string(),
            ));
            return None;
        }
    };

    lint_manifest_rules(file, content, &parsed, repo_root, findings);
    if check_projections {
        if let Some(root) = repo_root {
            lint_projection_drift(file, root, &parsed, findings);
        }
    }

    Some(parsed.manifest_hash)
}

fn lint_manifest_block_position(file: &Path, content: &str, findings: &mut Vec<LintFinding>) {
    let blocks = json_blocks(content);
    match blocks.len() {
        0 => {
            findings.push(finding(
                "specialty.manifest-block",
                "error",
                file,
                1,
                1,
                "Specialty file must contain exactly one ```json manifest block.".to_string(),
                "Place one JSON manifest block immediately after the # title heading.".to_string(),
            ));
            return;
        }
        1 => {}
        count => {
            findings.push(finding(
                "specialty.manifest-block",
                "error",
                file,
                blocks[1].start_line,
                1,
                format!("Specialty file contains {count} ```json manifest blocks."),
                "Keep exactly one manifest block.".to_string(),
            ));
        }
    }

    let first_block_line = blocks[0].start_line;
    let lines: Vec<&str> = content.lines().collect();
    let mut seen_title = false;
    for (idx, line) in lines.iter().enumerate() {
        let line_number = idx + 1;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if !seen_title {
            if trimmed.starts_with("# ") {
                seen_title = true;
                continue;
            }
            findings.push(finding(
                "specialty.manifest-block",
                "error",
                file,
                line_number,
                1,
                "First non-blank line must be the # title heading.".to_string(),
                "Start the specialty file with `# Specialty: <Name>`.".to_string(),
            ));
            return;
        }
        if line_number != first_block_line || trimmed != "```json" {
            findings.push(finding(
                "specialty.manifest-block",
                "error",
                file,
                line_number,
                1,
                "JSON manifest block must be the first non-blank content after the title."
                    .to_string(),
                "Move the ```json manifest block directly under the title heading.".to_string(),
            ));
        }
        return;
    }
}

fn lint_manifest_rules(
    file: &Path,
    content: &str,
    parsed: &ParsedManifest,
    repo_root: Option<&Path>,
    findings: &mut Vec<LintFinding>,
) {
    let manifest = &parsed.manifest;
    let line = parsed.json_start_line;

    let expected_slug = file
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("");
    if manifest.schema_version != 1 {
        findings.push(finding(
            "specialty.schema-version",
            "error",
            file,
            line,
            1,
            format!(
                "Manifest schema_version `{}` is not supported; expected 1.",
                manifest.schema_version
            ),
            "Use schema_version 1 until the specialty manifest schema is explicitly migrated."
                .to_string(),
        ));
    }

    if manifest.slug != expected_slug {
        findings.push(finding(
            "specialty.slug-filename-match",
            "error",
            file,
            line,
            1,
            format!(
                "Manifest slug `{}` does not match filename stem `{expected_slug}`.",
                manifest.slug
            ),
            "Rename the file or set manifest.slug to the filename stem.".to_string(),
        ));
    }

    match docs_specialty_path_role(file, repo_root) {
        Some(role) if manifest.canonical_role != role => {
            findings.push(finding(
                "specialty.canonical-role-match",
                "error",
                file,
                line,
                1,
                format!(
                    "Manifest canonical_role `{}` does not match parent role `{role}`.",
                    manifest.canonical_role
                ),
                "Move the file under the matching docs/roles/<canonical>/specialties directory or fix canonical_role.".to_string(),
            ));
        }
        Some(_) => {
            if !canonical_specialty_path_matches(file, repo_root, manifest) {
                findings.push(finding(
                    "specialty.canonical-path-violation",
                    "error",
                    file,
                    line,
                    1,
                    "Specialty file is outside docs/roles/<canonical>/specialties/<slug>.md."
                        .to_string(),
                    "Move the specialty under docs/roles/coder, reviewer, or orchestrator specialties."
                        .to_string(),
                ));
            }
        }
        None => findings.push(finding(
            "specialty.canonical-path-violation",
            "error",
            file,
            line,
            1,
            "Specialty file is outside docs/roles/<canonical>/specialties/<slug>.md.".to_string(),
            "Move the specialty under docs/roles/coder, reviewer, or orchestrator specialties."
                .to_string(),
        )),
    }

    lint_allowed_runtime_roles(file, manifest, line, findings);

    if manifest.required_output_sections.is_empty() {
        findings.push(finding(
            "specialty.required-output-sections",
            "error",
            file,
            line,
            1,
            "required_output_sections must be non-empty.".to_string(),
            "Declare the exact required ## output headings.".to_string(),
        ));
    }

    let allowed_fields: BTreeSet<&str> = manifest
        .matrix_fields_allowed
        .iter()
        .map(String::as_str)
        .collect();
    if manifest.matrix_fields_allowed.is_empty()
        || !specialty_required_matrix_fields()
            .iter()
            .all(|required| allowed_fields.contains(required))
    {
        findings.push(finding(
            "specialty.matrix-fields-allowed",
            "error",
            file,
            line,
            1,
            "matrix_fields_allowed must be non-empty and include the baseline matrix fields."
                .to_string(),
            format!(
                "Include at least: {}.",
                specialty_required_matrix_fields().join(", ")
            ),
        ));
    }
    let known_matrix_fields = allowed_specialty_fields_for(&manifest.canonical_role);
    let unknown_fields = manifest
        .matrix_fields_allowed
        .iter()
        .filter(|field| !known_matrix_fields.contains(*field))
        .cloned()
        .collect::<Vec<_>>();
    if !unknown_fields.is_empty() {
        findings.push(finding(
            "specialty.matrix-fields-not-in-vocabulary",
            "error",
            file,
            line,
            1,
            format!(
                "matrix_fields_allowed contains non-vocabulary fields: {}.",
                unknown_fields.join(", ")
            ),
            "Use fields from matrix-vocabulary.json or the documented specialty field allowlist."
                .to_string(),
        ));
    }

    let seed = manifest.thin_skill_projection.description_seed.trim();
    match (manifest.thin_skill_projection.enabled, seed.is_empty()) {
        (true, true) => findings.push(finding(
            "specialty.thin-skill-projection",
            "error",
            file,
            line,
            1,
            "thin_skill_projection.enabled=true requires non-empty description_seed.".to_string(),
            "Add a concise trigger-oriented description_seed.".to_string(),
        )),
        (false, false) => findings.push(finding(
            "specialty.thin-skill-projection",
            "error",
            file,
            line,
            1,
            "thin_skill_projection.enabled=false requires empty description_seed.".to_string(),
            "Set description_seed to an empty string or enable projection.".to_string(),
        )),
        (true, false) if seed.len() < 12 => findings.push(finding(
            "specialty.thin-skill-projection",
            "warning",
            file,
            line,
            1,
            "description_seed is very short for skill discovery.".to_string(),
            "Use a trigger-oriented one-line description.".to_string(),
        )),
        _ => {}
    }

    if !manifest.deprecated_aliases_forbidden {
        findings.push(finding(
            "specialty.deprecated-aliases-forbidden",
            "error",
            file,
            line,
            1,
            "deprecated_aliases_forbidden must be true.".to_string(),
            "Set deprecated_aliases_forbidden to true.".to_string(),
        ));
    }

    let headings = declared_output_sections(content);
    for section in &manifest.required_output_sections {
        if !headings.contains(section) {
            findings.push(finding(
                "specialty.required-section-heading",
                "error",
                file,
                line,
                1,
                format!("Required output section `{section}` is missing as a ## heading."),
                format!("Add `## {section}` to the specialty body."),
            ));
        }
    }

    lint_body_quality(file, content, manifest, line, findings);

    let deprecated_key =
        Regex::new(r"(?m)^\s*(checkpoint boundary|truth destination|artifact truth destination):")
            .expect("deprecated key regex compiles");
    for hit in deprecated_key.find_iter(content) {
        let line_number = content[..hit.start()].lines().count() + 1;
        findings.push(finding(
            "specialty.deprecated-structured-key",
            "error",
            file,
            line_number,
            1,
            "Deprecated structured key is not allowed in specialty body.".to_string(),
            "Use completion boundary / evidence destination vocabulary instead.".to_string(),
        ));
        findings.push(finding(
            "specialty.deprecated-alias-in-body",
            "error",
            file,
            line_number,
            1,
            "Deprecated alias key is not allowed in specialty body.".to_string(),
            "Use completion boundary / evidence destination vocabulary instead.".to_string(),
        ));
    }
}

fn lint_body_quality(
    file: &Path,
    content: &str,
    manifest: &Manifest,
    fallback_line: usize,
    findings: &mut Vec<LintFinding>,
) {
    let sections = body_sections(content);
    let mut required_section_text = Vec::new();
    for section in &manifest.required_output_sections {
        let Some((line, body)) = sections.get(section) else {
            continue;
        };
        required_section_text.push(body.as_str());
        if placeholder_only_section(section, body) {
            findings.push(finding(
                "specialty.placeholder-only-section",
                "warning",
                file,
                *line,
                1,
                format!("Required output section `{section}` contains only placeholder content."),
                "Replace placeholder text with concrete guidance for this specialty section."
                    .to_string(),
            ));
        }
    }

    if manifest.canonical_role == "orchestrator"
        && !required_section_text
            .iter()
            .any(|body| section_has_example(body))
    {
        findings.push(finding(
            "specialty.missing-example",
            "warning",
            file,
            fallback_line,
            1,
            "Orchestrator specialty required sections do not contain an example or code block."
                .to_string(),
            "Add a worked example, an `例`, or a fenced code block to a required output section."
                .to_string(),
        ));
    }
}

fn body_sections(content: &str) -> BTreeMap<String, (usize, String)> {
    let mut sections = BTreeMap::new();
    let mut in_fenced_code = false;
    let mut current: Option<(String, usize, Vec<String>)> = None;

    for (idx, line) in content.lines().enumerate() {
        let line_number = idx + 1;
        if line.trim_start().starts_with("```") {
            in_fenced_code = !in_fenced_code;
        }
        if !in_fenced_code {
            if let Some(heading) = line.strip_prefix("## ") {
                if let Some((name, start, lines)) = current.take() {
                    sections.insert(name, (start, lines.join("\n")));
                }
                current = Some((heading.trim().to_string(), line_number, Vec::new()));
                continue;
            }
        }
        if let Some((_, _, lines)) = current.as_mut() {
            lines.push(line.to_string());
        }
    }

    if let Some((name, start, lines)) = current {
        sections.insert(name, (start, lines.join("\n")));
    }
    sections
}

fn placeholder_only_section(section: &str, body: &str) -> bool {
    let trimmed = body.trim();
    if trimmed.is_empty() || trimmed == section {
        return true;
    }

    let placeholder_re = Regex::new(
        r"(?is)^_?\(?\s*(worker fills this section(?:\s+with\s+specialty-specific\s+content)?(?:;?\s*see manifest `required_output_sections`\.)?|todo:?|tbd:?|placeholder\.?)\s*\)?_?$",
    )
    .expect("placeholder regex compiles");

    let mut saw_content = false;
    for line in trimmed.lines() {
        let clean = line
            .trim()
            .trim_start_matches("- ")
            .trim_start_matches("* ")
            .trim();
        if clean.is_empty() {
            continue;
        }
        saw_content = true;
        if clean == section {
            continue;
        }
        if !placeholder_re.is_match(clean) {
            return false;
        }
    }
    saw_content
}

fn section_has_example(body: &str) -> bool {
    let lower = body.to_ascii_lowercase();
    lower.contains("example") || body.contains('例') || body.contains("```")
}

fn lint_allowed_runtime_roles(
    file: &Path,
    manifest: &Manifest,
    line: usize,
    findings: &mut Vec<LintFinding>,
) {
    let roles = &manifest.allowed_runtime_roles;
    let role_set: BTreeSet<&str> = roles.iter().map(String::as_str).collect();
    let all_allowed = role_set.iter().all(|role| RUNTIME_ROLES.contains(role));
    let has_standard_or_research = role_set.contains("standard") || role_set.contains("research");

    let invalid = if manifest.canonical_role == "orchestrator" {
        !roles.is_empty()
    } else if roles.is_empty() || !all_allowed || has_standard_or_research {
        true
    } else if manifest.canonical_role == "coder" {
        role_set.contains("reviewer")
            || !(role_set.contains("coder") || role_set.contains("high-coder"))
    } else if manifest.canonical_role == "reviewer" {
        roles != &["reviewer".to_string()]
    } else {
        true
    };

    if invalid {
        findings.push(finding(
            "specialty.allowed-runtime-roles",
            "error",
            file,
            line,
            1,
            format!(
                "allowed_runtime_roles {:?} is invalid for canonical_role `{}`.",
                manifest.allowed_runtime_roles, manifest.canonical_role
            ),
            "Use [] for orchestrator; coder/high-coder for coder; [\"reviewer\"] for reviewer. Never use standard/research.".to_string(),
        ));
    }
}

fn lint_projection_drift(
    file: &Path,
    repo_root: &Path,
    parsed: &ParsedManifest,
    findings: &mut Vec<LintFinding>,
) {
    let manifest = &parsed.manifest;
    if !manifest.thin_skill_projection.enabled {
        return;
    }
    let targets = [
        repo_root
            .join(".claude")
            .join("skills")
            .join(&manifest.slug)
            .join("SKILL.md"),
        repo_root
            .join(".agents")
            .join("skills")
            .join(&manifest.slug)
            .join("SKILL.md"),
    ];
    let absolute_file = fs::canonicalize(file).unwrap_or_else(|_| {
        if file.is_absolute() {
            file.to_path_buf()
        } else {
            std::env::current_dir()
                .map(|cwd| cwd.join(file))
                .unwrap_or_else(|_| file.to_path_buf())
        }
    });
    let repo_root = fs::canonicalize(repo_root).unwrap_or_else(|_| repo_root.to_path_buf());
    let relative_path = absolute_file
        .strip_prefix(repo_root)
        .unwrap_or(file)
        .to_path_buf();
    let expected = skill_body(&LoadedSpecialty {
        path: absolute_file,
        relative_path,
        manifest: manifest.clone(),
        manifest_hash: parsed.manifest_hash.clone(),
    });

    for target in targets {
        let content = match fs::read_to_string(&target) {
            Ok(content) => content,
            Err(_) => {
                findings.push(finding(
                    "specialty.projection-drift",
                    "error",
                    file,
                    parsed.json_start_line,
                    1,
                    format!("Projection target {} is missing.", target.display()),
                    "Run `agent-core specialty project --slug <slug> --provider all`.".to_string(),
                ));
                continue;
            }
        };
        let observed = frontmatter_value(&content, "source_manifest_hash");
        if observed.as_deref() != Some(parsed.manifest_hash.as_str()) {
            findings.push(finding(
                "specialty.projection-drift",
                "error",
                &target,
                1,
                1,
                format!(
                    "Projection source_manifest_hash `{}` does not match current manifest hash `{}`.",
                    observed.unwrap_or_else(|| "<missing>".to_string()),
                    parsed.manifest_hash
                ),
                "Regenerate the projection with `agent-core specialty project`.".to_string(),
            ));
        }
        if content != expected {
            findings.push(finding(
                "specialty.projection-body-drift",
                "error",
                &target,
                1,
                1,
                "Projection body does not match deterministic generator output.".to_string(),
                "Regenerate the projection with `agent-core specialty project`.".to_string(),
            ));
        }
    }
}

fn parse_manifest_from_content(
    file: &Path,
    content: &str,
) -> std::result::Result<ParsedManifest, String> {
    let blocks = json_blocks(content);
    if blocks.len() != 1 {
        return Err(format!(
            "{} must contain exactly one JSON manifest block; found {}",
            file.display(),
            blocks.len()
        ));
    }
    let block = &blocks[0];
    let manifest: Manifest = serde_json::from_str(&block.body)
        .map_err(|e| format!("manifest JSON does not match Manifest schema: {e}"))?;
    let hash = manifest_hash(&manifest).map_err(|e| e.to_string())?;
    Ok(ParsedManifest {
        manifest,
        manifest_hash: hash,
        json_start_line: block.start_line,
    })
}

fn json_blocks(content: &str) -> Vec<JsonBlock> {
    let lines: Vec<&str> = content.lines().collect();
    let mut blocks = Vec::new();
    let mut idx = 0;
    while idx < lines.len() {
        if lines[idx].trim() != "```json" {
            idx += 1;
            continue;
        }
        let start = idx;
        let mut end = None;
        idx += 1;
        while idx < lines.len() {
            if lines[idx].trim() == "```" {
                end = Some(idx);
                break;
            }
            idx += 1;
        }
        let end = end.unwrap_or(lines.len());
        let body = lines[start + 1..end].join("\n");
        blocks.push(JsonBlock {
            start_line: start + 1,
            body,
        });
        idx = end.saturating_add(1);
    }
    blocks
}

fn declared_output_sections(content: &str) -> BTreeSet<String> {
    let mut sections = BTreeSet::new();
    let mut in_fenced_code = false;
    for line in content.lines() {
        if line.trim_start().starts_with("```") {
            in_fenced_code = !in_fenced_code;
            continue;
        }
        if in_fenced_code {
            continue;
        }
        if let Some(heading) = line.strip_prefix("## ") {
            sections.insert(heading.trim().to_string());
        }
    }
    sections
}

fn docs_specialty_path_role(path: &Path, repo_root: Option<&Path>) -> Option<String> {
    let relative_path = repo_relative_path(path, repo_root)?;
    let components: Vec<String> = relative_path
        .components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect();
    if components.len() == 5
        && components[0] == "docs"
        && components[1] == "roles"
        && CANONICAL_ROLES.contains(&components[2].as_str())
        && components[3] == "specialties"
        && components[4].ends_with(".md")
    {
        return Some(components[2].clone());
    }
    None
}

fn canonical_specialty_path_matches(
    path: &Path,
    repo_root: Option<&Path>,
    manifest: &Manifest,
) -> bool {
    let Some(relative_path) = repo_relative_path(path, repo_root) else {
        return false;
    };
    let rel_path = relative_path.to_string_lossy().replace('\\', "/");
    let pattern = format!(
        r"^docs/roles/{}/specialties/{}\.md$",
        regex::escape(&manifest.canonical_role),
        regex::escape(&manifest.slug)
    );
    Regex::new(&pattern)
        .expect("canonical specialty path regex compiles")
        .is_match(&rel_path)
}

fn repo_relative_path(path: &Path, repo_root: Option<&Path>) -> Option<PathBuf> {
    let root = repo_root?;
    if let Ok(relative) = path.strip_prefix(root) {
        return Some(relative.to_path_buf());
    }
    if let (Ok(absolute_path), Ok(absolute_root)) = (fs::canonicalize(path), fs::canonicalize(root))
    {
        if let Ok(relative) = absolute_path.strip_prefix(&absolute_root) {
            return Some(relative.to_path_buf());
        }
    }
    if path.is_relative() {
        return Some(path.to_path_buf());
    }
    None
}

fn matrix_vocabulary_top_level_fields() -> BTreeSet<String> {
    let vocabulary: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../docs/manual/matrix-vocabulary.json"
    )))
    .expect("matrix-vocabulary.json must parse at compile-time tests/runtime");
    let mut fields = BTreeSet::new();
    if let Some(object) = vocabulary.as_object() {
        for key in object.keys() {
            if !key.starts_with('_') {
                fields.insert(key.to_string());
            }
        }
    }
    fields
}

fn frontmatter_value(content: &str, key: &str) -> Option<String> {
    let mut lines = content.lines();
    if lines.next()? != "---" {
        return None;
    }
    for line in lines {
        if line == "---" {
            break;
        }
        let Some((raw_key, raw_value)) = line.split_once(':') else {
            continue;
        };
        if raw_key.trim() == key {
            return Some(raw_value.trim().trim_matches('"').to_string());
        }
    }
    None
}

fn is_projection_skill_path(path: &Path) -> bool {
    path.file_name().and_then(|name| name.to_str()) == Some("SKILL.md")
        && path.components().any(|component| {
            let text = component.as_os_str().to_string_lossy();
            text == ".claude" || text == ".agents"
        })
}

fn valid_slug(slug: &str) -> bool {
    let mut chars = slug.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first.is_ascii_lowercase() || first.is_ascii_digit())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>> {
    let mut out = String::new();
    write_canonical_value(value, &mut out)?;
    Ok(out.into_bytes())
}

fn write_canonical_value(value: &Value, out: &mut String) -> Result<()> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => out.push_str(&value.to_string()),
        Value::String(value) => {
            out.push_str(&serde_json::to_string(value).map_err(AgentError::Json)?)
        }
        Value::Array(values) => {
            out.push('[');
            for (idx, value) in values.iter().enumerate() {
                if idx > 0 {
                    out.push(',');
                }
                write_canonical_value(value, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            let sorted: BTreeMap<&String, &Value> = map.iter().collect();
            out.push('{');
            for (idx, (key, value)) in sorted.iter().enumerate() {
                if idx > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).map_err(AgentError::Json)?);
                out.push(':');
                write_canonical_value(value, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn finding(
    rule_id: &str,
    severity: &str,
    file: &Path,
    line: usize,
    column: usize,
    message: String,
    suggestion: String,
) -> LintFinding {
    LintFinding {
        rule_id: rule_id.to_string(),
        severity: severity.to_string(),
        file: file.to_string_lossy().to_string(),
        line,
        column,
        message,
        suggestion,
    }
}

#[cfg(test)]
pub mod lint {
    use super::*;

    const FIXTURE_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/specialty_lint_fixtures");

    fn fixture(name: &str) -> PathBuf {
        Path::new(FIXTURE_DIR).join(name)
    }

    fn base_manifest(slug: &str, role: &str) -> Manifest {
        let allowed_runtime_roles = match role {
            "coder" => vec!["coder".to_string(), "high-coder".to_string()],
            "reviewer" => vec!["reviewer".to_string()],
            "orchestrator" => Vec::new(),
            _ => Vec::new(),
        };
        Manifest {
            schema_version: 1,
            slug: slug.to_string(),
            canonical_role: role.to_string(),
            allowed_runtime_roles,
            required_output_sections: vec!["Findings".to_string(), "Verdict".to_string()],
            matrix_fields_allowed: BASELINE_MATRIX_FIELDS
                .iter()
                .map(|field| field.to_string())
                .collect(),
            thin_skill_projection: ThinSkillProjection {
                enabled: false,
                description_seed: String::new(),
            },
            summary_oneline: "A deterministic specialty fixture.".to_string(),
            deprecated_aliases_forbidden: true,
        }
    }

    fn specialty_markdown(manifest: &Manifest, extra_body: &str) -> String {
        let mut body = format!(
            "# Specialty: {}\n\n```json\n{}\n```\n\n## Purpose\n\nFixture.\n\n",
            manifest.slug,
            serde_json::to_string_pretty(manifest).unwrap()
        );
        for section in &manifest.required_output_sections {
            body.push_str(&format!("## {section}\n\nPlaceholder.\n\n"));
        }
        body.push_str(extra_body);
        body
    }

    fn write_specialty(
        root: &Path,
        role: &str,
        slug: &str,
        manifest: &Manifest,
        extra_body: &str,
    ) -> PathBuf {
        let path = root
            .join("docs")
            .join("roles")
            .join(role)
            .join("specialties")
            .join(format!("{slug}.md"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, specialty_markdown(manifest, extra_body)).unwrap();
        path
    }

    fn lint_one(path: PathBuf, root: Option<&Path>) -> SpecialtyLintReport {
        lint_files(&[path], false, root).unwrap().0
    }

    fn assert_rule(report: &SpecialtyLintReport, rule_id: &str) {
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.rule_id == rule_id),
            "expected {rule_id}, got {:?}",
            report.findings
        );
    }

    fn assert_rule_severity(report: &SpecialtyLintReport, rule_id: &str, severity: &str) {
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.rule_id == rule_id && finding.severity == severity),
            "expected {rule_id} with severity {severity}, got {:?}",
            report.findings
        );
    }

    fn assert_no_rule(report: &SpecialtyLintReport, rule_id: &str) {
        assert!(
            !report
                .findings
                .iter()
                .any(|finding| finding.rule_id == rule_id),
            "did not expect {rule_id}, got {:?}",
            report.findings
        );
    }

    #[test]
    fn lint_passes_on_all_pr_a_specialties() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let paths = find_all_specialties(&root)
            .unwrap()
            .into_iter()
            .map(|specialty| specialty.path)
            .collect::<Vec<_>>();
        assert_eq!(paths.len(), 16);
        let (report, errors) = lint_files(&paths, false, Some(&root)).unwrap();
        assert_eq!(errors, 0, "{:?}", report.findings);
    }

    #[test]
    fn lint_rejects_missing_manifest() {
        let report = lint_one(fixture("missing-manifest.md"), None);
        assert_rule(&report, "specialty.manifest-block");
    }

    #[test]
    fn lint_rejects_multiple_manifest_blocks() {
        let report = lint_one(fixture("multiple-manifests.md"), None);
        assert_rule_severity(&report, "specialty.manifest-block", "error");
    }

    #[test]
    fn lint_rejects_wrong_position_manifest_block() {
        let report = lint_one(fixture("wrong-position-manifest.md"), None);
        assert_rule_severity(&report, "specialty.manifest-block", "error");
    }

    #[test]
    fn lint_rejects_invalid_json() {
        let report = lint_one(fixture("invalid-json.md"), None);
        assert_rule(&report, "specialty.manifest-valid");
    }

    #[test]
    fn lint_rejects_slug_mismatch() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("wrong-slug", "coder");
        let path = write_specialty(dir.path(), "coder", "actual-slug", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.slug-filename-match");
    }

    #[test]
    fn lint_rejects_canonical_role_mismatch() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("role-mismatch", "reviewer");
        manifest.allowed_runtime_roles = vec!["reviewer".to_string()];
        let path = write_specialty(dir.path(), "coder", "role-mismatch", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.canonical-role-match");
    }

    #[test]
    fn lint_rejects_standard_runtime_role() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("standard-role", "coder");
        manifest.allowed_runtime_roles = vec!["standard".to_string()];
        let path = write_specialty(dir.path(), "coder", "standard-role", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.allowed-runtime-roles");
    }

    #[test]
    fn lint_rejects_research_runtime_role() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("research-role", "coder");
        manifest.allowed_runtime_roles = vec!["research".to_string()];
        let path = write_specialty(dir.path(), "coder", "research-role", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.allowed-runtime-roles");
    }

    #[test]
    fn lint_rejects_orchestrator_with_runtime_role() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("orchestrator-runtime", "orchestrator");
        manifest.allowed_runtime_roles = vec!["coder".to_string()];
        let path = write_specialty(
            dir.path(),
            "orchestrator",
            "orchestrator-runtime",
            &manifest,
            "",
        );
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.allowed-runtime-roles");
    }

    #[test]
    fn lint_rejects_disabled_projection_with_seed() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("disabled-seed", "coder");
        manifest.thin_skill_projection.description_seed = "should be empty".to_string();
        let path = write_specialty(dir.path(), "coder", "disabled-seed", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.thin-skill-projection");
    }

    #[test]
    fn lint_rejects_enabled_projection_without_seed() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("enabled-no-seed", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        let path = write_specialty(dir.path(), "orchestrator", "enabled-no-seed", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.thin-skill-projection");
    }

    #[test]
    fn lint_rejects_missing_required_section_heading() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("missing-section", "coder");
        let path = dir
            .path()
            .join("docs/roles/coder/specialties/missing-section.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "# Specialty: Missing Section\n\n```json\n{}\n```\n\n## Findings\n\nOnly one.\n",
                serde_json::to_string_pretty(&manifest).unwrap()
            ),
        )
        .unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.required-section-heading");
    }

    #[test]
    fn fenced_code_pseudo_heading_does_not_satisfy_r10() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("fenced-code-section", "coder");
        let path = dir
            .path()
            .join("docs/roles/coder/specialties/fenced-code-section.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "# Specialty: Fenced Code Section\n\n```json\n{}\n```\n\n```rust\n## Findings\n## Verdict\n```\n",
                serde_json::to_string_pretty(&manifest).unwrap()
            ),
        )
        .unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule_severity(&report, "specialty.required-section-heading", "error");
    }

    #[test]
    fn lint_rejects_numbered_list_as_required_section_heading() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("numbered-section", "coder");
        let path = dir
            .path()
            .join("docs/roles/coder/specialties/numbered-section.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "# Specialty: Numbered Section\n\n```json\n{}\n```\n\n## Required Output Sections\n\n1. Findings\n2. Verdict\n",
                serde_json::to_string_pretty(&manifest).unwrap()
            ),
        )
        .unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.required-section-heading");
    }

    #[test]
    fn lint_accepts_exact_required_section_headings() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("exact-section", "coder");
        let path = write_specialty(dir.path(), "coder", "exact-section", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_no_rule(&report, "specialty.required-section-heading");
    }

    #[test]
    fn lint_rejects_unsupported_schema_version() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("schema-version", "coder");
        manifest.schema_version = 2;
        let path = write_specialty(dir.path(), "coder", "schema-version", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.schema-version");
    }

    #[test]
    fn lint_rejects_empty_required_output_sections() {
        let report = lint_one(fixture("empty-required-output-sections.md"), None);
        assert_rule_severity(&report, "specialty.required-output-sections", "error");
    }

    #[test]
    fn lint_rejects_unknown_manifest_field() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir
            .path()
            .join("docs/roles/coder/specialties/unknown-field.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut value = serde_json::to_value(base_manifest("unknown-field", "coder")).unwrap();
        value["unexpected_future_field"] = serde_json::json!(true);
        fs::write(
            &path,
            format!(
                "# Specialty: Unknown Field\n\n```json\n{}\n```\n\n## Findings\n\nPlaceholder.\n\n## Verdict\n\nPlaceholder.\n",
                serde_json::to_string_pretty(&value).unwrap()
            ),
        )
        .unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.manifest-valid");
    }

    #[test]
    fn lint_rejects_non_canonical_path() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("loose-specialty", "coder");
        let path = dir.path().join("loose-specialty.md");
        fs::write(&path, specialty_markdown(&manifest, "")).unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.canonical-path-violation");
    }

    #[test]
    fn canonical_path_spoof_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("refactor-safety-analyst", "coder");
        let path = dir
            .path()
            .join("harness-rust/some/non-docs/roles/coder/specialties/refactor-safety-analyst.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, specialty_markdown(&manifest, "")).unwrap();
        let report = lint_one(path, Some(dir.path()));
        assert_rule_severity(&report, "specialty.canonical-path-violation", "error");
    }

    #[test]
    fn lint_rejects_missing_baseline_matrix_field() {
        let report = lint_one(fixture("missing-baseline-matrix-field.md"), None);
        assert_rule_severity(&report, "specialty.matrix-fields-allowed", "error");
    }

    #[test]
    fn matrix_fields_not_in_vocabulary_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("unknown-matrix", "coder");
        manifest.matrix_fields_allowed.push("foobar".to_string());
        let path = write_specialty(dir.path(), "coder", "unknown-matrix", &manifest, "");
        let report = lint_one(path, Some(dir.path()));
        assert_rule_severity(
            &report,
            "specialty.matrix-fields-not-in-vocabulary",
            "error",
        );
    }

    #[test]
    fn lint_rejects_unknown_matrix_field_fixture() {
        let report = lint_one(fixture("unknown-matrix-field.md"), None);
        assert_rule_severity(
            &report,
            "specialty.matrix-fields-not-in-vocabulary",
            "error",
        );
    }

    #[test]
    fn lint_warns_on_short_enabled_projection_seed() {
        let report = lint_one(fixture("short-description-seed.md"), None);
        assert_rule_severity(&report, "specialty.thin-skill-projection", "warning");
    }

    #[test]
    fn lint_rejects_deprecated_aliases_not_forbidden() {
        let report = lint_one(fixture("deprecated-aliases-forbidden-false.md"), None);
        assert_rule_severity(&report, "specialty.deprecated-aliases-forbidden", "error");
    }

    #[test]
    fn lint_rejects_deprecated_key() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("deprecated-key", "coder");
        let path = write_specialty(
            dir.path(),
            "coder",
            "deprecated-key",
            &manifest,
            "checkpoint boundary: old\n",
        );
        let report = lint_one(path, Some(dir.path()));
        assert_rule(&report, "specialty.deprecated-structured-key");
    }

    #[test]
    fn lint_rule_13_placeholder_section_warning_fires() {
        let report = lint_one(fixture("body-placeholder-only-warning.md"), None);
        assert_rule_severity(&report, "specialty.placeholder-only-section", "warning");
    }

    #[test]
    fn lint_rule_14_missing_example_orchestrator() {
        let report = lint_one(fixture("body-missing-example-orchestrator.md"), None);
        assert_rule_severity(&report, "specialty.missing-example", "warning");
    }

    #[test]
    fn lint_rule_15_deprecated_alias_body_error() {
        let report = lint_one(fixture("body-deprecated-alias-error.md"), None);
        assert_rule_severity(&report, "specialty.deprecated-alias-in-body", "error");
    }

    #[test]
    fn manifest_hash_deterministic() {
        let manifest = base_manifest("hash-stable", "coder");
        let first = manifest_hash(&manifest).unwrap();
        let second = manifest_hash(&manifest).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn project_writes_both_providers_under_all() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let written = project_specialty(dir.path(), &loaded, "all").unwrap();
        assert_eq!(written.len(), 2);
        assert!(dir
            .path()
            .join(".claude/skills/scope-guard/SKILL.md")
            .exists());
        assert!(dir
            .path()
            .join(".agents/skills/scope-guard/SKILL.md")
            .exists());
    }

    #[test]
    fn project_skill_md_contains_lens_disclaimer() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains("lens"));
        assert!(body.contains("not a workflow owner"));
    }

    #[test]
    fn skill_body_role_aware_orchestrator() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains("Orchestrator-primary lens"));
        assert!(body.contains(
            "orchestrator reads `docs/roles/orchestrator/specialties/scope-guard.md` directly"
        ));
        assert!(body.contains("this skill auto-trigger is a discovery hint only"));
    }

    #[test]
    fn skill_body_role_aware_coder() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("production-function-implementer", "coder");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Implement production-grade functions with tests.".to_string();
        let path = write_specialty(
            dir.path(),
            "coder",
            "production-function-implementer",
            &manifest,
            "",
        );
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains("Coder lens"));
        assert!(body.contains(
            "scripts/codex-wrapper.sh --role coder --specialty production-function-implementer"
        ));
        assert!(body.contains(
            "scripts/codex-wrapper.sh --role high-coder --specialty production-function-implementer"
        ));
    }

    #[test]
    fn skill_body_role_aware_reviewer() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("staff-code-reviewer", "reviewer");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Review PRs for blocking correctness issues.".to_string();
        let path = write_specialty(dir.path(), "reviewer", "staff-code-reviewer", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains("Reviewer lens"));
        assert!(body
            .contains("scripts/codex-wrapper.sh --role reviewer --specialty staff-code-reviewer"));
        assert!(body.contains("primary invocation is the wrapper flag"));
    }

    #[test]
    fn project_skill_md_contains_manifest_hash() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains(&format!(
            "source_manifest_hash: \"{}\"",
            loaded.manifest_hash
        )));
    }

    #[test]
    fn project_skill_md_quotes_yaml_frontmatter_strings() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Trigger: clarify scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let body = skill_body(&loaded);
        assert!(body.contains("description: \"Trigger: clarify scope before implementation.\""));
    }

    #[test]
    fn project_rejects_disabled_specialty() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = base_manifest("disabled-project", "coder");
        let path = write_specialty(dir.path(), "coder", "disabled-project", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        let err = project_specialty(dir.path(), &loaded, "all").unwrap_err();
        assert!(err.to_string().contains("enabled=false"));
    }

    #[test]
    fn project_matches_golden_output() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let golden_root =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/specialty_project_golden");
        for slug in [
            "scope-guard",
            "slice-designer",
            "context-compactor",
            "structured-mentor",
            "production-function-implementer",
            "staff-code-reviewer",
        ] {
            let loaded = load_specialty_by_slug(&root, slug).unwrap();
            let body = skill_body(&loaded);
            for provider in ["claude", "codex"] {
                let golden =
                    fs::read_to_string(golden_root.join(slug).join(format!("{provider}.SKILL.md")))
                        .unwrap();
                assert_eq!(body, golden, "{slug} {provider}");
            }
        }
    }

    #[test]
    fn check_projections_detects_drift() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let skill_path = dir.path().join(".claude/skills/scope-guard/SKILL.md");
        fs::create_dir_all(skill_path.parent().unwrap()).unwrap();
        fs::write(
            &skill_path,
            "---\nsource_manifest_hash: deadbeef\n---\n# scope-guard\n",
        )
        .unwrap();
        let other = dir.path().join(".agents/skills/scope-guard/SKILL.md");
        fs::create_dir_all(other.parent().unwrap()).unwrap();
        fs::write(
            &other,
            "---\nsource_manifest_hash: deadbeef\n---\n# scope-guard\n",
        )
        .unwrap();
        let (report, errors) = lint_files(&[path], true, Some(dir.path())).unwrap();
        assert!(errors > 0);
        assert_rule(&report, "specialty.projection-drift");
    }

    #[test]
    fn check_projections_detects_body_drift_with_matching_hash() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = base_manifest("scope-guard", "orchestrator");
        manifest.thin_skill_projection.enabled = true;
        manifest.thin_skill_projection.description_seed =
            "Clarify ambiguous scope before implementation.".to_string();
        let path = write_specialty(dir.path(), "orchestrator", "scope-guard", &manifest, "");
        let loaded = load_specialty_file(dir.path(), &path).unwrap();
        project_specialty(dir.path(), &loaded, "all").unwrap();
        let skill_path = dir.path().join(".claude/skills/scope-guard/SKILL.md");
        let mut body = fs::read_to_string(&skill_path).unwrap();
        body.push_str("\nmanual drift\n");
        fs::write(&skill_path, body).unwrap();

        let (report, errors) = lint_files(&[path], true, Some(dir.path())).unwrap();
        assert!(errors > 0);
        assert_rule(&report, "specialty.projection-body-drift");
    }
}
