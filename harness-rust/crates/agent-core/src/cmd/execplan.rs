//! ExecPlan-specific linting.

use clap::Subcommand;
use regex::Regex;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use shared::error::{AgentError, Result};

use crate::cmd::envelope::{LintFinding, LintReport};
use crate::cmd::specialty;

const DEFAULT_MATRIX_VOCABULARY_JSON: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../docs/manual/matrix-vocabulary.json"
));
const DEFAULT_INVOCATION_PATHS: [&str; 3] = ["wrapper-flag", "direct-read", "generated-skill-hint"];
const DEFAULT_CANONICAL_ROLES: [&str; 3] = ["coder", "reviewer", "orchestrator"];

#[derive(Subcommand, Debug)]
pub enum ExecPlanAction {
    /// Lint an ExecPlan markdown file for specialty-using-slice canonical fields.
    Lint(LintArgs),
}

#[derive(clap::Args, Debug)]
pub struct LintArgs {
    /// ExecPlan markdown file path(s) to lint.
    #[arg(required = true, num_args = 1..)]
    pub files: Vec<PathBuf>,
    /// Override matrix-vocabulary JSON path for testing.
    #[arg(long)]
    pub matrix_vocabulary: Option<PathBuf>,
    /// Override specialty files root for testing.
    #[arg(long)]
    pub specialty_root: Option<PathBuf>,
    /// Write lint report JSON to this path (default stdout).
    #[arg(long)]
    pub output_json: Option<PathBuf>,
}

#[derive(Debug)]
struct ExecPlanVocabulary {
    invocation_paths: BTreeSet<String>,
    canonical_roles: BTreeSet<String>,
}

#[derive(Debug)]
struct SliceSection {
    heading: String,
    start_line: usize,
    lines: Vec<(usize, String)>,
}

#[derive(Debug, Clone)]
struct DeclaredField {
    value: String,
    line: usize,
    column: usize,
}

#[derive(Debug, Default)]
struct SliceDeclarations {
    specialty_id: Option<DeclaredField>,
    canonical_role: Option<DeclaredField>,
    invocation_path: Option<DeclaredField>,
    manifest_hash: Option<DeclaredField>,
    selection_reason: Option<DeclaredField>,
    specialty_path: Option<DeclaredField>,
    wrapper_specialty: Option<DeclaredField>,
}

#[derive(Debug)]
struct SpecialtyRef {
    path: PathBuf,
    canonical_role: String,
    loaded: specialty::LoadedSpecialty,
}

pub fn run(action: ExecPlanAction) -> Result<()> {
    match action {
        ExecPlanAction::Lint(args) => run_lint_cli(args),
    }
}

fn run_lint_cli(args: LintArgs) -> Result<()> {
    let (report, error_count) = lint_files(
        &args.files,
        args.matrix_vocabulary.as_deref(),
        args.specialty_root.as_deref(),
    )?;
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

fn lint_files(
    files: &[PathBuf],
    matrix_vocabulary: Option<&Path>,
    specialty_root: Option<&Path>,
) -> Result<(LintReport, usize)> {
    let vocabulary = load_execplan_vocabulary(matrix_vocabulary)?;
    let mut findings = Vec::new();

    for file in files {
        let content = fs::read_to_string(file).map_err(AgentError::Io)?;
        lint_content(file, &content, &vocabulary, specialty_root, &mut findings);
    }

    let error_count = findings
        .iter()
        .filter(|finding| finding.severity == "error")
        .count();
    Ok((
        LintReport {
            schema_version: 1,
            findings,
        },
        error_count,
    ))
}

fn lint_content(
    file: &Path,
    content: &str,
    vocabulary: &ExecPlanVocabulary,
    specialty_root: Option<&Path>,
    findings: &mut Vec<LintFinding>,
) {
    for section in slice_sections(content) {
        let declarations = extract_declarations(&section);
        if !is_specialty_using_slice(&declarations) {
            continue;
        }
        lint_specialty_slice(
            file,
            &section,
            &declarations,
            vocabulary,
            specialty_root,
            findings,
        );
    }
}

fn lint_specialty_slice(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    vocabulary: &ExecPlanVocabulary,
    specialty_root: Option<&Path>,
    findings: &mut Vec<LintFinding>,
) {
    let Some(specialty_id) = lint_specialty_id_presence(file, section, declarations, findings)
    else {
        return;
    };

    let resolved = resolve_specialty_ref(&specialty_id, declarations, specialty_root);
    if let Err(message) = &resolved {
        findings.push(finding(
            "execplan.specialty-reference-missing",
            "error",
            file,
            declarations
                .specialty_path
                .as_ref()
                .or(declarations.specialty_id.as_ref())
                .map(|field| field.line)
                .unwrap_or(section.start_line),
            1,
            message.clone(),
            "Cite the live specialty file path or declare a specialty_id that resolves under docs/roles/*/specialties."
                .to_string(),
        ));
    }
    let resolved = resolved.ok();

    lint_canonical_role(
        file,
        section,
        declarations,
        vocabulary,
        resolved.as_ref(),
        findings,
    );
    lint_invocation_path(file, section, declarations, vocabulary, findings);
    lint_manifest_hash(file, section, declarations, resolved.as_ref(), findings);
    lint_selection_reason(file, section, declarations, findings);
}

fn lint_specialty_id_presence(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    findings: &mut Vec<LintFinding>,
) -> Option<String> {
    let Some(field) = &declarations.specialty_id else {
        findings.push(finding(
            "execplan.specialty-id-missing",
            "error",
            file,
            section.start_line,
            1,
            format!(
                "Specialty-using slice `{}` does not declare specialty_id.",
                section.heading
            ),
            "Add `specialty_id: <slug>` to the slice contract.".to_string(),
        ));
        return None;
    };

    if !is_valid_slug(&field.value) {
        findings.push(finding(
            "execplan.specialty-id-invalid",
            "error",
            file,
            field.line,
            field.column,
            format!(
                "specialty_id `{}` must match ^[a-z0-9][a-z0-9-]*$.",
                field.value
            ),
            "Use the specialty file slug without `.md`.".to_string(),
        ));
        return None;
    }

    Some(field.value.clone())
}

fn lint_canonical_role(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    vocabulary: &ExecPlanVocabulary,
    resolved: Option<&SpecialtyRef>,
    findings: &mut Vec<LintFinding>,
) {
    let Some(field) = &declarations.canonical_role else {
        findings.push(finding(
            "execplan.canonical-role-missing",
            "error",
            file,
            section.start_line,
            1,
            format!(
                "Specialty-using slice `{}` does not declare canonical_role.",
                section.heading
            ),
            "Add `canonical_role: <coder|reviewer|orchestrator>`.".to_string(),
        ));
        return;
    };

    if !vocabulary.canonical_roles.contains(&field.value) {
        findings.push(finding(
            "execplan.canonical-role-invalid",
            "error",
            file,
            field.line,
            field.column,
            format!(
                "canonical_role `{}` is not declared in matrix vocabulary.",
                field.value
            ),
            format!(
                "Use one of: {}.",
                vocabulary
                    .canonical_roles
                    .iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" | ")
            ),
        ));
    }

    if let Some(resolved) = resolved {
        if field.value != resolved.canonical_role
            || field.value != resolved.loaded.manifest.canonical_role
        {
            findings.push(finding(
                "execplan.canonical-role-mismatch",
                "error",
                file,
                field.line,
                field.column,
                format!(
                    "canonical_role `{}` does not match cited specialty role `{}` and manifest canonical_role `{}`.",
                    field.value, resolved.canonical_role, resolved.loaded.manifest.canonical_role
                ),
                format!(
                    "Use `canonical_role: {}` for `{}`.",
                    resolved.canonical_role,
                    resolved.path.display()
                ),
            ));
        }
    }
}

fn lint_invocation_path(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    vocabulary: &ExecPlanVocabulary,
    findings: &mut Vec<LintFinding>,
) {
    let Some(field) = &declarations.invocation_path else {
        findings.push(finding(
            "execplan.invocation-path-missing",
            "error",
            file,
            section.start_line,
            1,
            format!(
                "Specialty-using slice `{}` does not declare invocation_path.",
                section.heading
            ),
            "Add `invocation_path: wrapper-flag | direct-read | generated-skill-hint`.".to_string(),
        ));
        return;
    };

    if !vocabulary.invocation_paths.contains(&field.value) {
        findings.push(finding(
            "execplan.invocation-path-invalid",
            "error",
            file,
            field.line,
            field.column,
            format!("invocation_path `{}` is not allowed.", field.value),
            format!(
                "Use one of: {}.",
                vocabulary
                    .invocation_paths
                    .iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" | ")
            ),
        ));
    }
}

fn lint_manifest_hash(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    resolved: Option<&SpecialtyRef>,
    findings: &mut Vec<LintFinding>,
) {
    let Some(field) = &declarations.manifest_hash else {
        findings.push(finding(
            "execplan.manifest-hash-missing",
            "error",
            file,
            section.start_line,
            1,
            format!(
                "Specialty-using slice `{}` does not declare manifest_hash.",
                section.heading
            ),
            "Add the current specialty manifest hash from `agent-core specialty lint`.".to_string(),
        ));
        return;
    };

    if !is_hex(&field.value) {
        findings.push(finding(
            "execplan.manifest-hash-invalid",
            "error",
            file,
            field.line,
            field.column,
            "manifest_hash must be a hex string.".to_string(),
            "Use the current sha256 hex manifest hash from `agent-core specialty lint`."
                .to_string(),
        ));
        return;
    }

    if let Some(resolved) = resolved {
        if field.value != resolved.loaded.manifest_hash {
            findings.push(finding(
                "execplan.manifest-hash-stale",
                "error",
                file,
                field.line,
                field.column,
                format!(
                    "manifest_hash `{}` does not match current live hash `{}` for `{}`.",
                    field.value,
                    resolved.loaded.manifest_hash,
                    resolved.path.display()
                ),
                "Refresh the slice's manifest_hash from `agent-core specialty lint`.".to_string(),
            ));
        }
    }
}

fn lint_selection_reason(
    file: &Path,
    section: &SliceSection,
    declarations: &SliceDeclarations,
    findings: &mut Vec<LintFinding>,
) {
    let Some(field) = &declarations.selection_reason else {
        findings.push(finding(
            "execplan.selection-reason-thin",
            "warning",
            file,
            section.start_line,
            1,
            format!(
                "Specialty-using slice `{}` does not explain selection_reason.",
                section.heading
            ),
            "Add a concrete one-sentence reason for choosing this specialty.".to_string(),
        ));
        return;
    };

    let normalized = field.value.trim().trim_matches('"').trim_matches('\'');
    let placeholder = matches!(
        normalized.to_ascii_lowercase().as_str(),
        "" | "todo" | "tbd" | "n/a" | "na" | "none" | "<todo>" | "..."
    );
    if placeholder || normalized.chars().count() < 10 {
        findings.push(finding(
            "execplan.selection-reason-thin",
            "warning",
            file,
            field.line,
            field.column,
            "selection_reason is empty, placeholder, or too thin.".to_string(),
            "Add at least 10 characters of concrete rationale.".to_string(),
        ));
    }
}

fn slice_sections(content: &str) -> Vec<SliceSection> {
    let mut sections = Vec::new();
    let mut current: Option<SliceSection> = None;

    for (idx, line) in content.lines().enumerate() {
        let line_number = idx + 1;
        if line.starts_with("## ") || line.starts_with("### ") {
            if let Some(section) = current.take() {
                sections.push(section);
            }
            if line.starts_with("### ") {
                current = Some(SliceSection {
                    heading: line.trim_start_matches('#').trim().to_string(),
                    start_line: line_number,
                    lines: Vec::new(),
                });
            }
            continue;
        }

        if let Some(section) = current.as_mut() {
            section.lines.push((line_number, line.to_string()));
        }
    }

    if let Some(section) = current {
        sections.push(section);
    }

    sections
}

fn is_specialty_using_slice(declarations: &SliceDeclarations) -> bool {
    declarations.specialty_id.is_some()
        || declarations.specialty_path.is_some()
        || declarations.wrapper_specialty.is_some()
}

fn extract_declarations(section: &SliceSection) -> SliceDeclarations {
    let mut declarations = SliceDeclarations::default();
    let mut in_yaml_fence = false;

    for (line_number, line) in &section.lines {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            let fence = trimmed.trim_start_matches("```").trim();
            in_yaml_fence = !in_yaml_fence && (fence == "yaml" || fence == "yml");
            if !in_yaml_fence && trimmed == "```" {
                in_yaml_fence = false;
            }
            continue;
        }

        if in_yaml_fence || trimmed.starts_with('-') || trimmed.starts_with('*') {
            capture_field(line, *line_number, &mut declarations);
        }

        capture_specialty_path(line, *line_number, &mut declarations);
        capture_wrapper_specialty(line, *line_number, &mut declarations);
    }

    declarations
}

fn capture_field(line: &str, line_number: usize, declarations: &mut SliceDeclarations) {
    let re = Regex::new(
        r#"^\s*(?:[-*]\s*)?(specialty[_-]id|canonical_role|invocation_path|manifest_hash|selection_reason)\s*[:=]\s*(.*?)\s*$"#,
    )
    .expect("field regex must compile");
    let Some(captures) = re.captures(line) else {
        return;
    };
    let Some(key_match) = captures.get(1) else {
        return;
    };
    let Some(value_match) = captures.get(2) else {
        return;
    };
    let value = clean_value(value_match.as_str());
    let field = DeclaredField {
        value,
        line: line_number,
        column: key_match.start() + 1,
    };
    match key_match.as_str().replace('-', "_").as_str() {
        "specialty_id" => {
            declarations.specialty_id.get_or_insert(field);
        }
        "canonical_role" => {
            declarations.canonical_role.get_or_insert(field);
        }
        "invocation_path" => {
            declarations.invocation_path.get_or_insert(field);
        }
        "manifest_hash" => {
            declarations.manifest_hash.get_or_insert(field);
        }
        "selection_reason" => {
            declarations.selection_reason.get_or_insert(field);
        }
        _ => {}
    }
}

fn capture_specialty_path(line: &str, line_number: usize, declarations: &mut SliceDeclarations) {
    if declarations.specialty_path.is_some() {
        return;
    }
    let normalized = line.to_ascii_lowercase().replace('-', "_");
    if !(normalized.contains("change_surface") || normalized.contains("in_scope")) {
        return;
    }
    let re = Regex::new(r#"(docs/roles/([a-z0-9-]+)/specialties/([a-z0-9][a-z0-9-]*)\.md)"#)
        .expect("specialty path regex must compile");
    let Some(captures) = re.captures(line) else {
        return;
    };
    let Some(path_match) = captures.get(1) else {
        return;
    };
    declarations.specialty_path = Some(DeclaredField {
        value: path_match.as_str().to_string(),
        line: line_number,
        column: path_match.start() + 1,
    });
}

fn capture_wrapper_specialty(line: &str, line_number: usize, declarations: &mut SliceDeclarations) {
    if declarations.wrapper_specialty.is_some() {
        return;
    }
    if line.trim_start().starts_with('|') {
        return;
    }
    let re = Regex::new(r#"codex-wrapper\.sh\b[^\n`]*--specialty\s+([a-z0-9][a-z0-9-]*)"#)
        .expect("wrapper specialty regex must compile");
    let Some(captures) = re.captures(line) else {
        return;
    };
    let Some(slug) = captures.get(1) else {
        return;
    };
    declarations.wrapper_specialty = Some(DeclaredField {
        value: slug.as_str().to_string(),
        line: line_number,
        column: slug.start() + 1,
    });
}

fn resolve_specialty_ref(
    specialty_id: &str,
    declarations: &SliceDeclarations,
    specialty_root: Option<&Path>,
) -> std::result::Result<SpecialtyRef, String> {
    let root = resolve_specialty_root(specialty_root).map_err(|error| error.to_string())?;
    if let Some(path_field) = &declarations.specialty_path {
        let path = resolve_cited_specialty_path(&root, &path_field.value);
        let loaded = specialty::load_specialty_file(&root, &path).map_err(|error| {
            format!(
                "failed to load cited specialty `{}`: {error}",
                path.display()
            )
        })?;
        let (canonical_role, slug) = role_and_slug_from_specialty_path(&path_field.value)
            .ok_or_else(|| format!("invalid specialty path `{}`", path_field.value))?;
        if slug != specialty_id {
            return Err(format!(
                "specialty_id `{specialty_id}` does not match cited specialty slug `{slug}`."
            ));
        }
        return Ok(SpecialtyRef {
            path: PathBuf::from(&path_field.value),
            canonical_role,
            loaded,
        });
    }

    let loaded = load_specialty_by_slug_from_root(&root, specialty_id)
        .map_err(|error| format!("failed to resolve specialty_id `{specialty_id}`: {error}"))?;
    Ok(SpecialtyRef {
        path: loaded.relative_path.clone(),
        canonical_role: loaded.manifest.canonical_role.clone(),
        loaded,
    })
}

fn resolve_specialty_root(specialty_root: Option<&Path>) -> Result<PathBuf> {
    if let Some(root) = specialty_root {
        return Ok(root.to_path_buf());
    }
    specialty::detect_repo_root(None)
}

fn resolve_cited_specialty_path(root: &Path, cited: &str) -> PathBuf {
    let cited_path = Path::new(cited);
    let direct = root.join(cited_path);
    if direct.exists() {
        return direct;
    }
    if let Ok(stripped) = cited_path.strip_prefix("docs/roles") {
        let roles_root = root.join(stripped);
        if roles_root.exists() {
            return roles_root;
        }
    }
    direct
}

fn load_specialty_by_slug_from_root(root: &Path, slug: &str) -> Result<specialty::LoadedSpecialty> {
    if let Ok(loaded) = specialty::load_specialty_by_slug(root, slug) {
        return Ok(loaded);
    }

    for roles_root in [root.join("docs").join("roles"), root.to_path_buf()] {
        for role in DEFAULT_CANONICAL_ROLES {
            let path = roles_root
                .join(role)
                .join("specialties")
                .join(format!("{slug}.md"));
            if path.exists() {
                return specialty::load_specialty_file(root, &path);
            }
        }
    }

    Err(AgentError::NotFound(format!(
        "specialty file for slug `{slug}` under docs/roles/*/specialties"
    )))
}

fn role_and_slug_from_specialty_path(path: &str) -> Option<(String, String)> {
    let re = Regex::new(r#"docs/roles/([a-z0-9-]+)/specialties/([a-z0-9][a-z0-9-]*)\.md$"#).ok()?;
    let captures = re.captures(path)?;
    Some((
        captures.get(1)?.as_str().to_string(),
        captures.get(2)?.as_str().to_string(),
    ))
}

fn load_execplan_vocabulary(path: Option<&Path>) -> Result<ExecPlanVocabulary> {
    let raw = if let Some(path) = path {
        fs::read_to_string(path).map_err(AgentError::Io)?
    } else {
        DEFAULT_MATRIX_VOCABULARY_JSON.to_string()
    };
    let value: Value = serde_json::from_str(&raw).map_err(AgentError::Json)?;
    Ok(ExecPlanVocabulary {
        invocation_paths: enum_values(&value, &["invocation_path", "specialty_invocation_path"])
            .unwrap_or_else(|| {
                DEFAULT_INVOCATION_PATHS
                    .iter()
                    .map(|value| value.to_string())
                    .collect()
            }),
        canonical_roles: enum_values(&value, &["canonical_role", "specialty_canonical_role"])
            .unwrap_or_else(|| {
                DEFAULT_CANONICAL_ROLES
                    .iter()
                    .map(|value| value.to_string())
                    .collect()
            }),
    })
}

fn enum_values(value: &Value, keys: &[&str]) -> Option<BTreeSet<String>> {
    let object = value.as_object()?;
    for key in keys {
        if let Some(values) = object
            .get(*key)
            .and_then(|block| block.get("enum"))
            .and_then(|values| values.as_array())
        {
            return Some(
                values
                    .iter()
                    .filter_map(|value| value.as_str().map(str::to_string))
                    .collect(),
            );
        }
        if let Some(values) = object
            .get("_policy")
            .and_then(|policy| policy.get("domain_local"))
            .and_then(|domain_local| domain_local.get(*key))
            .and_then(|block| block.get("values"))
            .and_then(|values| values.as_array())
        {
            return Some(
                values
                    .iter()
                    .filter_map(|value| value.as_str().map(str::to_string))
                    .collect(),
            );
        }
    }
    None
}

fn clean_value(value: &str) -> String {
    value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim_matches('`')
        .to_string()
}

fn is_valid_slug(value: &str) -> bool {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first.is_ascii_lowercase() || first.is_ascii_digit())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn is_hex(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|ch| ch.is_ascii_hexdigit())
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
mod tests {
    use super::*;
    use tempfile::tempdir;

    const FIXTURE_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/execplan_lint_fixtures");
    const HASH: &str = "f9e16b3e7f96a410ac74480cad663671f14c73ead7d01dc373c1352199051113";

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    fn fixture(name: &str) -> PathBuf {
        Path::new(FIXTURE_DIR).join(name)
    }

    fn lint_fixture(name: &str) -> LintReport {
        lint_files(&[fixture(name)], None, Some(&repo_root()))
            .unwrap()
            .0
    }

    fn assert_rule(report: &LintReport, rule_id: &str) {
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.rule_id == rule_id),
            "expected {rule_id}, got {:?}",
            report.findings
        );
    }

    fn assert_no_findings(report: &LintReport) {
        assert!(
            report.findings.is_empty(),
            "unexpected findings: {:?}",
            report.findings
        );
    }

    #[test]
    fn valid_specialty_slice_passes() {
        assert_no_findings(&lint_fixture("slice-with-valid-specialty.md"));
    }

    #[test]
    fn missing_specialty_id_fails() {
        assert_rule(
            &lint_fixture("slice-missing-specialty-id.md"),
            "execplan.specialty-id-missing",
        );
    }

    #[test]
    fn wrapper_invocation_marker_still_requires_declared_specialty_id() {
        let dir = tempdir().unwrap();
        let plan = dir.path().join("wrapper-only.md");
        fs::write(
            &plan,
            r#"# Wrapper Only

## Slice Board

### Slice A

- invocation_path: wrapper-flag
- canonical_role: coder
- manifest_hash: f9e16b3e7f96a410ac74480cad663671f14c73ead7d01dc373c1352199051113
- selection_reason: Refactor risk review is required for this implementation slice.
- example: codex-wrapper.sh --role coder --specialty refactor-safety-analyst --stdin
"#,
        )
        .unwrap();
        let report = lint_files(&[plan], None, Some(&repo_root())).unwrap().0;
        assert_rule(&report, "execplan.specialty-id-missing");
    }

    #[test]
    fn canonical_role_mismatch_fails() {
        assert_rule(
            &lint_fixture("slice-canonical-mismatch.md"),
            "execplan.canonical-role-mismatch",
        );
    }

    #[test]
    fn invalid_invocation_path_fails() {
        assert_rule(
            &lint_fixture("slice-invalid-invocation-path.md"),
            "execplan.invocation-path-invalid",
        );
    }

    #[test]
    fn stale_manifest_hash_fails() {
        assert_rule(
            &lint_fixture("slice-stale-manifest-hash.md"),
            "execplan.manifest-hash-stale",
        );
    }

    #[test]
    fn thin_selection_reason_warns() {
        let report = lint_fixture("slice-empty-selection-reason.md");
        assert!(
            report.findings.iter().any(|finding| {
                finding.rule_id == "execplan.selection-reason-thin" && finding.severity == "warning"
            }),
            "expected selection-reason warning, got {:?}",
            report.findings
        );
    }

    #[test]
    fn non_specialty_slice_ignored() {
        assert_no_findings(&lint_fixture("non-specialty-slice.md"));
    }

    #[test]
    fn multiple_slices_in_one_file_lints_only_specialty_slices() {
        let dir = tempdir().unwrap();
        let plan = dir.path().join("multi.md");
        fs::write(
            &plan,
            format!(
                r#"# Multi

## Slice Board

### Slice A

- change_surface: harness-rust/crates/agent-core/src/main.rs

### Slice B

```yaml
specialty_id: refactor-safety-analyst
canonical_role: coder
invocation_path: wrapper-flag
selection_reason: Refactor risk review is required for this implementation slice.
manifest_hash: {HASH}
change_surface: docs/roles/coder/specialties/refactor-safety-analyst.md
```
"#
            ),
        )
        .unwrap();
        let report = lint_files(&[plan], None, Some(&repo_root())).unwrap().0;
        assert_no_findings(&report);
    }

    #[test]
    fn matrix_vocabulary_override_is_used() {
        let dir = tempdir().unwrap();
        let vocab = dir.path().join("matrix-vocabulary.json");
        fs::write(
            &vocab,
            r#"{
  "canonical_role": { "enum": ["coder", "reviewer", "orchestrator"] },
  "invocation_path": { "enum": ["direct-read"] }
}"#,
        )
        .unwrap();
        let report = lint_files(
            &[fixture("slice-with-valid-specialty.md")],
            Some(&vocab),
            Some(&repo_root()),
        )
        .unwrap()
        .0;
        assert_rule(&report, "execplan.invocation-path-invalid");
    }
}
