//! Handoff envelope rendering and linting.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use chrono::DateTime;
use clap::{Args, Subcommand};
use serde::{Deserialize, Serialize};

use shared::error::{AgentError, Result};

use crate::cmd::specialty;

const VOCABULARY_JSON: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../docs/manual/matrix-vocabulary.json"
));

#[derive(Subcommand, Debug)]
pub enum EnvelopeAction {
    /// Render a canonical ExecPlan + handoff envelope from a structured plan source.
    Render(RenderArgs),
    /// Lint an existing ExecPlan / handoff envelope against matrix-vocabulary.json.
    Lint(LintArgs),
}

#[derive(Args, Debug)]
pub struct RenderArgs {
    /// Structured plan source JSON.
    #[arg(long)]
    pub source: Option<PathBuf>,
    /// Render a specialty-specific handoff envelope template.
    #[arg(long)]
    pub specialty: Option<String>,
}

#[derive(Args, Debug, Clone)]
pub struct LintArgs {
    /// Continue with exit code 0 even if error findings are present.
    #[arg(long)]
    pub advisory: bool,
    /// Override the matrix vocabulary JSON path.
    #[arg(long = "matrix-vocabulary")]
    pub matrix_vocabulary: Option<PathBuf>,
    /// Write lint report JSON to this path instead of stdout.
    #[arg(long = "output-json")]
    pub output_json: Option<PathBuf>,
    /// Also validate specialty-required ## headings.
    #[arg(long)]
    pub specialty: Option<String>,
    /// Markdown files to lint.
    #[arg(required = true)]
    pub files: Vec<PathBuf>,
}

#[allow(dead_code)]
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct PlanSource {
    pub task_id: Option<String>,
    pub slice_id: Option<String>,
    pub task_class: Option<String>,
    pub schema_profile: Option<String>,
    pub objective: Option<String>,
    pub envelope_fields: Option<EnvelopeFields>,
}

#[allow(dead_code)]
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct EnvelopeFields {
    pub status: Option<String>,
    pub worker_outcome: Option<String>,
    pub evidence_destination: Option<String>,
    pub completion_boundary: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct Vocabulary {
    #[serde(rename = "_policy")]
    pub policy: PolicyBlock,
    pub task_class: EnumBlock,
    pub schema_profile: SchemaProfileBlock,
    pub status: EnumBlock,
    pub reviewer_verdict: EnumBlock,
    pub worker_outcome: EnumBlock,
    pub re_slice_delta_type: EnumBlock,
    pub budget: BudgetBlock,
    pub budget_status: EnumBlock,
    pub loop_caps: LoopCapsBlock,
    pub deprecated_aliases: DeprecatedAliasesBlock,
    pub counter: CounterBlock,
    pub discovery_owner: EnumBlock,
    pub review_request_target: EnumBlock,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct PolicyBlock {
    pub vocabulary_consumer_contract: String,
    pub domain_local: HashMap<String, DomainLocalBlock>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct DomainLocalBlock {
    pub rationale: Option<String>,
    pub values: Option<Vec<String>>,
    pub consumers: Option<Vec<String>>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct EnumBlock {
    pub r#enum: Vec<String>,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct SchemaProfileBlock {
    pub r#enum: Vec<String>,
    #[serde(flatten)]
    pub profiles: HashMap<String, SchemaProfileRequiredFields>,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct SchemaProfileRequiredFields {
    pub required_fields: Option<Vec<String>>,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct BudgetBlock {
    pub format: String,
    pub basis_enum: Vec<String>,
    pub default: String,
    pub auto_loop_ceiling: String,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct LoopCapsBlock {
    pub same_slice: HashMap<String, serde_json::Value>,
    pub task_level: HashMap<String, serde_json::Value>,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct DeprecatedAliasesBlock {
    pub forbidden_live_keys: Vec<String>,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct CounterBlock {
    pub format: String,
    pub overflow_behavior: String,
    #[serde(rename = "_source_lines")]
    pub source_lines: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct LintReport {
    pub schema_version: u8,
    pub findings: Vec<LintFinding>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct LintFinding {
    pub rule_id: String,
    pub severity: String,
    pub file: String,
    pub line: usize,
    pub column: usize,
    pub message: String,
    pub suggestion: String,
}

#[derive(Debug, Clone)]
struct ParsedField {
    key: String,
    value: String,
    line: usize,
    column: usize,
    section: String,
}

pub fn run(action: EnvelopeAction) -> Result<()> {
    match action {
        EnvelopeAction::Render(args) if args.specialty.is_some() => run_render_specialty(args),
        EnvelopeAction::Render(_args) => {
            eprintln!("agent-core envelope render is reserved for Slice 4.");
            Ok(())
        }
        EnvelopeAction::Lint(args) => run_lint_cli(args),
    }
}

fn run_lint_cli(args: LintArgs) -> Result<()> {
    let (mut report, mut error_count) = lint_files(&args.files, args.matrix_vocabulary.as_deref())?;
    if let Some(slug) = &args.specialty {
        let repo_root = specialty::detect_repo_root(None)?;
        let loaded = specialty::load_specialty_by_slug(&repo_root, slug)?;
        lint_files_against_specialty(&args.files, &loaded, &mut report.findings)?;
        error_count = report
            .findings
            .iter()
            .filter(|finding| finding.severity == "error")
            .count();
    }
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

    if !args.advisory && error_count > 0 {
        std::process::exit(error_count.min(255) as i32);
    }

    Ok(())
}

fn run_render_specialty(args: RenderArgs) -> Result<()> {
    let slug = args
        .specialty
        .as_deref()
        .ok_or_else(|| AgentError::Validation("--specialty is required".to_string()))?;
    let repo_root = specialty::detect_repo_root(None)?;
    let loaded = specialty::load_specialty_by_slug(&repo_root, slug)?;
    let source = if let Some(path) = &args.source {
        let raw = fs::read_to_string(path).map_err(AgentError::Io)?;
        let source: PlanSource = serde_json::from_str(&raw).map_err(AgentError::Json)?;
        validate_plan_source_against_specialty(&source, &loaded.manifest)?;
        Some(source)
    } else {
        None
    };
    println!("{}", render_specialty_template(&loaded, source.as_ref()));
    Ok(())
}

fn lint_files(files: &[PathBuf], vocabulary_path: Option<&Path>) -> Result<(LintReport, usize)> {
    let vocabulary = load_vocabulary(vocabulary_path)?;
    let mut findings = Vec::new();

    for file in files {
        let content = fs::read_to_string(file).map_err(AgentError::Io)?;
        lint_content(file, &content, &vocabulary, &mut findings);
    }

    let error_count = findings.iter().filter(|f| f.severity == "error").count();
    Ok((
        LintReport {
            schema_version: 1,
            findings,
        },
        error_count,
    ))
}

fn validate_plan_source_against_specialty(
    source: &PlanSource,
    manifest: &specialty::Manifest,
) -> Result<()> {
    let allowed: HashSet<&str> = manifest
        .matrix_fields_allowed
        .iter()
        .map(String::as_str)
        .collect();
    let fields = plan_source_fields(source);
    let disallowed = fields
        .into_iter()
        .filter(|field| !allowed.contains(field.as_str()))
        .collect::<Vec<_>>();
    if !disallowed.is_empty() {
        return Err(AgentError::Validation(format!(
            "plan source fields are not allowed by specialty `{}`: {}",
            manifest.slug,
            disallowed.join(", ")
        )));
    }
    Ok(())
}

fn plan_source_fields(source: &PlanSource) -> Vec<String> {
    let mut fields = Vec::new();
    if source.task_id.is_some() {
        fields.push("task_id".to_string());
    }
    if source.slice_id.is_some() {
        fields.push("slice_id".to_string());
    }
    if source.task_class.is_some() {
        fields.push("task_class".to_string());
    }
    if source.schema_profile.is_some() {
        fields.push("schema_profile".to_string());
    }
    if let Some(envelope_fields) = &source.envelope_fields {
        if envelope_fields.status.is_some() {
            fields.push("status".to_string());
        }
        if envelope_fields.worker_outcome.is_some() {
            fields.push("worker_outcome".to_string());
        }
        if envelope_fields.evidence_destination.is_some() {
            fields.push("evidence_destination".to_string());
        }
        if envelope_fields.completion_boundary.is_some() {
            fields.push("completion_boundary".to_string());
        }
    }
    fields
}

fn render_specialty_template(
    specialty: &specialty::LoadedSpecialty,
    source: Option<&PlanSource>,
) -> String {
    let manifest = &specialty.manifest;
    let task_class = source
        .and_then(|source| source.task_class.as_deref())
        .unwrap_or("...");
    let schema_profile = source
        .and_then(|source| source.schema_profile.as_deref())
        .unwrap_or("...");
    let evidence_destination = source
        .and_then(|source| source.envelope_fields.as_ref())
        .and_then(|fields| fields.evidence_destination.as_deref())
        .unwrap_or("...");
    let completion_boundary = source
        .and_then(|source| source.envelope_fields.as_ref())
        .and_then(|fields| fields.completion_boundary.as_deref())
        .unwrap_or("...");

    let mut output = format!(
        "---\n\
handoff:\n  role: \"{}\"\n  task_class: \"{}\"\n  schema_profile: \"{}\"\n  handoff_state: \"ready_for_next | needs_fix | needs_more_context | blocked\"\n  evidence_destination: \"{}\"\n  completion_boundary: \"{}\"\n  specialty_id: \"{}\"\n  canonical_role: \"{}\"\n  manifest_hash: \"{}\"\n---\n",
        manifest.canonical_role,
        task_class,
        schema_profile,
        evidence_destination,
        completion_boundary,
        manifest.slug,
        manifest.canonical_role,
        specialty.manifest_hash
    );

    for section in &manifest.required_output_sections {
        output.push_str(&format!("\n## {section}\n\n<fill {section}>\n"));
    }
    output
}

fn lint_files_against_specialty(
    files: &[PathBuf],
    specialty: &specialty::LoadedSpecialty,
    findings: &mut Vec<LintFinding>,
) -> Result<()> {
    for file in files {
        let content = fs::read_to_string(file).map_err(AgentError::Io)?;
        let headings: HashSet<String> = content
            .lines()
            .filter_map(|line| line.strip_prefix("## "))
            .map(|heading| heading.trim().to_string())
            .collect();
        for section in &specialty.manifest.required_output_sections {
            if !headings.contains(section) {
                findings.push(finding(
                    "envelope.specialty-required-section",
                    "error",
                    file,
                    1,
                    1,
                    format!(
                        "Specialty `{}` requires missing ## section `{section}`.",
                        specialty.manifest.slug
                    ),
                    format!(
                        "Add `## {section}` or render with `envelope render --specialty {}`.",
                        specialty.manifest.slug
                    ),
                ));
            }
        }

        let allowed: HashSet<&str> = specialty
            .manifest
            .matrix_fields_allowed
            .iter()
            .map(String::as_str)
            .collect();
        let matrix_fields =
            specialty::allowed_specialty_fields_for(&specialty.manifest.canonical_role);
        for field in parse_fields(&content) {
            let key = field.key.replace(' ', "_");
            if matrix_fields.contains(&key) && !allowed.contains(key.as_str()) {
                findings.push(finding(
                    "envelope.specialty-field-allowed",
                    "error",
                    file,
                    field.line,
                    field.column,
                    format!(
                        "Field `{key}` is not allowed by specialty `{}`.",
                        specialty.manifest.slug
                    ),
                    "Remove the field or choose a specialty that allows it.".to_string(),
                ));
            }
        }
    }
    Ok(())
}

fn load_vocabulary(path: Option<&Path>) -> Result<Vocabulary> {
    let raw = if let Some(path) = path {
        fs::read_to_string(path).map_err(AgentError::Io)?
    } else {
        VOCABULARY_JSON.to_string()
    };
    serde_json::from_str(&raw).map_err(AgentError::Json)
}

fn lint_content(
    file: &Path,
    content: &str,
    vocabulary: &Vocabulary,
    findings: &mut Vec<LintFinding>,
) {
    let fields = parse_fields(content);
    let field_keys: HashSet<&str> = fields.iter().map(|field| field.key.as_str()).collect();

    lint_field_presence(file, &fields, &field_keys, vocabulary, findings);
    lint_enum_membership(file, &fields, vocabulary, findings);
    lint_deprecated_keys(file, &fields, vocabulary, findings);
    lint_budget_shape(file, &fields, vocabulary, findings);
    lint_field_placement(file, &fields, findings);
    lint_loop_vocabulary(file, content, findings);
    lint_root_cause_vs_na(file, content, findings);
    lint_class_closure_sentinel(file, &fields, findings);
}

fn parse_fields(content: &str) -> Vec<ParsedField> {
    let mut fields = Vec::new();
    let mut section = String::new();
    let mut in_fence = false;
    let mut in_example = false;

    for (idx, line) in content.lines().enumerate() {
        let line_number = idx + 1;
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        if lower.starts_with("<example") {
            in_example = true;
            continue;
        }
        if lower.starts_with("</example") {
            in_example = false;
            continue;
        }
        if in_fence
            || in_example
            || trimmed.starts_with('>')
            || trimmed.starts_with('|')
            || trimmed.is_empty()
        {
            continue;
        }
        if trimmed.starts_with('#') {
            section = trimmed.trim_start_matches('#').trim().to_ascii_lowercase();
        }

        let without_list = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
            .or_else(|| trimmed.strip_prefix("+ "))
            .unwrap_or(trimmed)
            .trim();
        if without_list.starts_with('`') {
            continue;
        }
        let without_ticks = without_list.replace('`', "");
        let Some((raw_key, raw_value)) = split_field(&without_ticks) else {
            continue;
        };
        if is_value_space_display(raw_value) {
            continue;
        }
        let key = normalize_key(raw_key);
        if key.is_empty() || raw_value.trim().is_empty() {
            continue;
        }
        let column = line.find(raw_key).map(|pos| pos + 1).unwrap_or(1);
        fields.push(ParsedField {
            key,
            value: raw_value.trim().trim_matches('"').to_string(),
            line: line_number,
            column,
            section: section.clone(),
        });
    }

    fields
}

fn is_value_space_display(value: &str) -> bool {
    let value = value.trim().trim_matches('"').trim_matches('`');
    value.contains(" | ")
        && value
            .split('|')
            .all(|part| !part.trim().is_empty() && part.trim() != "...")
}

fn split_field(line: &str) -> Option<(&str, &str)> {
    if let Some(pos) = line.find(':') {
        return Some((&line[..pos], &line[pos + 1..]));
    }
    if let Some(pos) = line.find('=') {
        return Some((&line[..pos], &line[pos + 1..]));
    }
    None
}

fn normalize_key(key: &str) -> String {
    key.trim()
        .trim_start_matches('#')
        .trim()
        .replace('_', " ")
        .replace('-', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn normalize_value(value: &str) -> String {
    value.trim().trim_matches('"').trim_matches('`').to_string()
}

fn lint_field_presence(
    file: &Path,
    fields: &[ParsedField],
    field_keys: &HashSet<&str>,
    vocabulary: &Vocabulary,
    findings: &mut Vec<LintFinding>,
) {
    let Some(schema_profile) = field_value(fields, "schema profile") else {
        return;
    };
    let profile = normalize_value(schema_profile);
    let Some(profile_block) = vocabulary.schema_profile.profiles.get(&profile) else {
        return;
    };
    let Some(required_fields) = &profile_block.required_fields else {
        return;
    };

    for required in required_fields {
        let normalized = normalize_key(required);
        if !field_keys.contains(normalized.as_str()) {
            findings.push(finding(
                "envelope.field-presence",
                "error",
                file,
                1,
                1,
                format!("Required field `{required}` missing for schema_profile `{profile}`."),
                format!("Add `{required}: <value>` near completion_boundary."),
            ));
        }
    }
}

fn lint_enum_membership(
    file: &Path,
    fields: &[ParsedField],
    vocabulary: &Vocabulary,
    findings: &mut Vec<LintFinding>,
) {
    let domain_local_names = declared_domain_local_names(fields);
    for namespace in &domain_local_names {
        if !domain_local_declared(vocabulary, namespace) {
            if let Some(field) = fields.iter().find(|field| {
                field.key == "domain local" && normalize_value(&field.value) == *namespace
            }) {
                findings.push(finding(
                    "envelope.enum-membership",
                    "error",
                    file,
                    field.line,
                    field.column,
                    format!("domain_local namespace `{namespace}` is not declared in matrix-vocabulary.json."),
                    format!("Add `_policy.domain_local.{namespace}.rationale` or remove the domain_local declaration."),
                ));
            }
        }
    }

    for field in fields {
        if let Some(domain_local) = vocabulary
            .policy
            .domain_local
            .get(&field.key.replace(' ', "_"))
        {
            if let Some(values) = &domain_local.values {
                let value = normalize_value(&field.value);
                if !values.contains(&value) && !is_value_space_display(&field.value) {
                    findings.push(finding(
                        "envelope.domain-local-value-not-declared",
                        "error",
                        file,
                        field.line,
                        field.column,
                        format!(
                            "Value `{value}` is not declared for domain_local field `{}`.",
                            field.key
                        ),
                        format!("Use one of: {}.", values.join(" | ")),
                    ));
                }
            }
            continue;
        }

        let expected = match field.key.as_str() {
            "task class" => Some(&vocabulary.task_class.r#enum),
            "schema profile" => Some(&vocabulary.schema_profile.r#enum),
            "status" => Some(&vocabulary.status.r#enum),
            "reviewer verdict" => Some(&vocabulary.reviewer_verdict.r#enum),
            "worker outcome" => Some(&vocabulary.worker_outcome.r#enum),
            "re slice delta type" => Some(&vocabulary.re_slice_delta_type.r#enum),
            "task level stall or wall time budget status" | "budget status" => {
                Some(&vocabulary.budget_status.r#enum)
            }
            "discovery owner" => Some(&vocabulary.discovery_owner.r#enum),
            "review request target" => Some(&vocabulary.review_request_target.r#enum),
            _ => None,
        };
        let Some(expected) = expected else {
            continue;
        };
        let value = normalize_value(&field.value);
        if expected.contains(&value) {
            continue;
        }
        if domain_local_namespace(&value).is_some() {
            findings.push(finding(
                "envelope.enum-membership",
                "error",
                file,
                field.line,
                field.column,
                format!(
                    "`domain_local:` values are not valid for canonical enum `{}`.",
                    field.key
                ),
                format!("Use one of: {}.", expected.join(" | ")),
            ));
            continue;
        }
        findings.push(finding(
            "envelope.enum-membership",
            "error",
            file,
            field.line,
            field.column,
            format!("Value `{value}` is not valid for `{}`.", field.key),
            format!("Use one of: {}.", expected.join(" | ")),
        ));
    }
}

fn lint_deprecated_keys(
    file: &Path,
    fields: &[ParsedField],
    vocabulary: &Vocabulary,
    findings: &mut Vec<LintFinding>,
) {
    let forbidden: HashSet<String> = vocabulary
        .deprecated_aliases
        .forbidden_live_keys
        .iter()
        .map(|key| normalize_key(key))
        .collect();
    for field in fields {
        if forbidden.contains(&field.key) {
            findings.push(finding(
                "envelope.deprecated-key",
                "error",
                file,
                field.line,
                field.column,
                format!("Deprecated live key `{}` is not allowed.", field.key),
                "Use `completion boundary` or `evidence destination` as appropriate.".to_string(),
            ));
        }
    }
}

fn lint_budget_shape(
    file: &Path,
    fields: &[ParsedField],
    vocabulary: &Vocabulary,
    findings: &mut Vec<LintFinding>,
) {
    for field in fields {
        if field.key == "task level stall or wall time budget" {
            if !budget_matches(&field.value, &vocabulary.budget.basis_enum) {
                findings.push(finding(
                    "envelope.budget-shape",
                    "error",
                    file,
                    field.line,
                    field.column,
                    "Budget field does not match the canonical budget format.".to_string(),
                    format!("Use `{}`.", vocabulary.budget.format),
                ));
            }
        }
    }
}

fn lint_field_placement(file: &Path, fields: &[ParsedField], findings: &mut Vec<LintFinding>) {
    for field in fields {
        if field.key == "worker outcome"
            && (field.section.contains("slice contract")
                || field.section.contains("pre-flight")
                || field.section.contains("preflight"))
        {
            findings.push(finding(
                "envelope.field-placement",
                "error",
                file,
                field.line,
                field.column,
                "`worker outcome` is post-execution only and must not appear in a pre-flight slice contract.".to_string(),
                "Move `worker outcome` to the worker report / review request envelope.".to_string(),
            ));
        }
    }
}

fn lint_loop_vocabulary(file: &Path, content: &str, findings: &mut Vec<LintFinding>) {
    for paragraph in paragraphs(content) {
        let lower = paragraph.text.to_ascii_lowercase();
        let deny = lower.contains("allowable upper bound");
        let allow = lower.contains("stop condition") || lower.contains("block condition");
        if deny && !allow {
            findings.push(finding(
                "envelope.loop-vocabulary",
                "warning",
                file,
                paragraph.line,
                1,
                "Loop ceiling wording frames the number as an allowable upper bound.".to_string(),
                "Frame ceiling overflow as a stop condition or BLOCK condition.".to_string(),
            ));
        }
    }
}

fn lint_root_cause_vs_na(file: &Path, content: &str, findings: &mut Vec<LintFinding>) {
    for paragraph in paragraphs(content) {
        let lower = paragraph.text.to_ascii_lowercase();
        if lower.contains("bug class candidate: n/a") && lower.contains("root cause") {
            findings.push(finding(
                "envelope.root-cause-vs-na",
                "warning",
                file,
                paragraph.line,
                1,
                "`bug class candidate: n/a` appears with root-cause language.".to_string(),
                "Use a concrete bug class candidate or remove root-cause framing.".to_string(),
            ));
        }
    }
}

fn lint_class_closure_sentinel(
    file: &Path,
    fields: &[ParsedField],
    findings: &mut Vec<LintFinding>,
) {
    let sentinel_fields = [
        "class closure sheet",
        "sheet status",
        "owned sink universe",
        "closed universe status",
        "closed universe basis",
    ];
    let invalid_non_applicable = [
        "not required",
        "not applicable",
        "none",
        "n/a.",
        "na",
        "N/A",
    ];

    for field in fields {
        if !sentinel_fields.contains(&field.key.as_str()) {
            continue;
        }
        let value = normalize_value(&field.value);
        let lower = value.to_ascii_lowercase();
        if value != "n/a"
            && invalid_non_applicable
                .iter()
                .any(|sentinel| lower == sentinel.to_ascii_lowercase())
        {
            findings.push(finding(
                "envelope.class-closure-sentinel",
                "warning",
                file,
                field.line,
                field.column,
                format!(
                    "Non-applicable sentinel `{value}` is not canonical for `{}`.",
                    field.key
                ),
                "Use `n/a` for non-applicable class-closure fields.".to_string(),
            ));
        }
    }
}

fn field_value<'a>(fields: &'a [ParsedField], key: &str) -> Option<&'a str> {
    fields
        .iter()
        .find(|field| field.key == key)
        .map(|field| field.value.as_str())
}

fn declared_domain_local_names(fields: &[ParsedField]) -> Vec<String> {
    fields
        .iter()
        .filter(|field| field.key == "domain local")
        .map(|field| normalize_value(&field.value))
        .collect()
}

fn domain_local_declared(vocabulary: &Vocabulary, namespace: &str) -> bool {
    vocabulary
        .policy
        .domain_local
        .get(namespace)
        .and_then(|entry| entry.rationale.as_deref())
        .is_some_and(|rationale| !rationale.trim().is_empty())
}

fn domain_local_namespace(value: &str) -> Option<&str> {
    value
        .strip_prefix("domain_local:")
        .or_else(|| value.strip_prefix("domain-local:"))
        .map(str::trim)
}

fn budget_matches(value: &str, basis_enum: &[String]) -> bool {
    let parts: Vec<&str> = value.split(';').map(str::trim).collect();
    if parts.len() != 5 {
        return false;
    }
    let Some(stall) = parts[0].strip_prefix("stall<=") else {
        return false;
    };
    let Some(wall) = parts[1].strip_prefix("wall<=") else {
        return false;
    };
    let Some(basis) = parts[2].strip_prefix("basis=") else {
        return false;
    };
    let Some(start) = parts[3].strip_prefix("start=") else {
        return false;
    };
    let Some(last_progress) = parts[4].strip_prefix("last-progress=") else {
        return false;
    };

    minute_value(stall)
        && minute_value(wall)
        && basis_enum.iter().any(|allowed| allowed == basis)
        && timestampish(start)
        && timestampish(last_progress)
}

fn minute_value(value: &str) -> bool {
    value
        .strip_suffix('m')
        .is_some_and(|minutes| !minutes.is_empty() && minutes.chars().all(|c| c.is_ascii_digit()))
}

fn timestampish(value: &str) -> bool {
    value.ends_with('Z') && DateTime::parse_from_rfc3339(value).is_ok()
}

struct Paragraph {
    line: usize,
    text: String,
}

fn paragraphs(content: &str) -> Vec<Paragraph> {
    let mut paragraphs = Vec::new();
    let mut current = Vec::new();
    let mut start_line = 1;

    for (idx, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            if !current.is_empty() {
                paragraphs.push(Paragraph {
                    line: start_line,
                    text: current.join("\n"),
                });
                current.clear();
            }
            start_line = idx + 2;
            continue;
        }
        if current.is_empty() {
            start_line = idx + 1;
        }
        current.push(line.to_string());
    }

    if !current.is_empty() {
        paragraphs.push(Paragraph {
            line: start_line,
            text: current.join("\n"),
        });
    }

    paragraphs
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
mod lint {
    use super::*;

    const FIXTURE_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/envelope_lint_fixtures");

    fn fixture(name: &str) -> PathBuf {
        Path::new(FIXTURE_DIR).join(name)
    }

    fn lint_fixture(name: &str) -> LintReport {
        lint_files(&[fixture(name)], None).unwrap().0
    }

    fn assert_rule(pass_fixture: &str, fail_fixture: &str, rule_id: &str) {
        let pass = lint_fixture(pass_fixture);
        assert!(
            !pass
                .findings
                .iter()
                .any(|finding| finding.rule_id == rule_id),
            "expected {pass_fixture} not to trigger {rule_id}: {:?}",
            pass.findings
        );
        let fail = lint_fixture(fail_fixture);
        assert!(
            fail.findings
                .iter()
                .any(|finding| finding.rule_id == rule_id),
            "expected {fail_fixture} to trigger {rule_id}: {:?}",
            fail.findings
        );
    }

    #[test]
    fn lint_rule_01_field_presence() {
        assert_rule(
            "rule-01-field-presence-pass.md",
            "rule-01-field-presence-fail.md",
            "envelope.field-presence",
        );
    }

    #[test]
    fn lint_rule_02_enum_membership() {
        assert_rule(
            "rule-02-enum-membership-pass.md",
            "rule-02-enum-membership-fail.md",
            "envelope.enum-membership",
        );
    }

    #[test]
    fn lint_rule_02_rejects_domain_local_on_canonical_enum() {
        let fixture_path = fixture("rule-02-enum-membership-domain-local-on-canonical-fail.md");
        let report = lint_files(&[fixture_path.clone()], None).unwrap().0;
        let finding = report
            .findings
            .iter()
            .find(|finding| finding.rule_id == "envelope.enum-membership")
            .expect("expected domain_local on canonical status to trigger enum-membership");

        assert_eq!(finding.file, fixture_path.to_string_lossy());
        assert!(
            finding.message.contains("status"),
            "message should identify the status field: {}",
            finding.message
        );
        assert!(
            finding.message.contains("domain_local"),
            "message should identify domain_local invalidity: {}",
            finding.message
        );
    }

    #[test]
    fn lint_rule_02_rejects_undeclared_domain_local_value() {
        let vocabulary = fixture("rule-02-domain-local-value-vocabulary.json");
        let report = lint_files(
            &[fixture("rule-02-domain-local-value-fail.md")],
            Some(&vocabulary),
        )
        .unwrap()
        .0;
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.rule_id == "envelope.domain-local-value-not-declared"),
            "expected undeclared domain_local value finding: {:?}",
            report.findings
        );
    }

    #[test]
    fn lint_rule_02_ignores_prose_code_examples_and_value_displays() {
        let report = lint_fixture("rule-02-prose-code-example-pass.md");
        assert!(
            !report
                .findings
                .iter()
                .any(|finding| finding.rule_id == "envelope.enum-membership"),
            "example/prose enum displays should not be linted: {:?}",
            report.findings
        );
    }

    #[test]
    fn lint_rule_03_deprecated_key() {
        assert_rule(
            "rule-03-deprecated-key-pass.md",
            "rule-03-deprecated-key-fail.md",
            "envelope.deprecated-key",
        );
    }

    #[test]
    fn lint_rule_04_budget_shape() {
        assert_rule(
            "rule-04-budget-shape-pass.md",
            "rule-04-budget-shape-fail.md",
            "envelope.budget-shape",
        );
    }

    #[test]
    fn lint_rule_04_rejects_invalid_rfc3339_budget_timestamps() {
        let report = lint_fixture("rule-04-budget-rfc3339-fail.md");
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.rule_id == "envelope.budget-shape"),
            "expected invalid RFC3339 budget finding: {:?}",
            report.findings
        );
    }

    #[test]
    fn lint_rule_05_field_placement() {
        assert_rule(
            "rule-05-field-placement-pass.md",
            "rule-05-field-placement-fail.md",
            "envelope.field-placement",
        );
    }

    #[test]
    fn lint_rule_06_loop_vocabulary() {
        assert_rule(
            "rule-06-loop-vocabulary-pass.md",
            "rule-06-loop-vocabulary-fail.md",
            "envelope.loop-vocabulary",
        );
    }

    #[test]
    fn lint_rule_07_root_cause_vs_na() {
        assert_rule(
            "rule-07-root-cause-vs-na-pass.md",
            "rule-07-root-cause-vs-na-fail.md",
            "envelope.root-cause-vs-na",
        );
    }

    #[test]
    fn lint_rule_08_class_closure_sentinel() {
        assert_rule(
            "rule-08-class-closure-sentinel-pass.md",
            "rule-08-class-closure-sentinel-fail.md",
            "envelope.class-closure-sentinel",
        );
    }

    #[test]
    fn lint_rule_08_rejects_uppercase_na_on_expected_line() {
        let report = lint_fixture("rule-08-class-closure-sentinel-fail.md");
        assert!(
            report.findings.iter().any(|finding| {
                finding.rule_id == "envelope.class-closure-sentinel" && finding.line == 6
            }),
            "expected line 6 N/A sentinel finding: {:?}",
            report.findings
        );
    }

    #[test]
    fn lint_advisory_forces_exit_zero_policy() {
        let (_report, errors) =
            lint_files(&[fixture("rule-02-enum-membership-fail.md")], None).unwrap();
        assert!(errors > 0);
        let dir = tempfile::tempdir().unwrap();
        let output_json = dir.path().join("lint.json");
        let args = LintArgs {
            advisory: true,
            matrix_vocabulary: None,
            output_json: Some(output_json.clone()),
            specialty: None,
            files: vec![fixture("rule-02-enum-membership-fail.md")],
        };
        assert!(run_lint_cli(args).is_ok());
        let report: LintReport =
            serde_json::from_str(&fs::read_to_string(output_json).unwrap()).unwrap();
        assert!(report
            .findings
            .iter()
            .any(|finding| finding.severity == "error"));
    }

    #[test]
    fn lint_json_schema_has_required_finding_fields() {
        let report = lint_fixture("rule-02-enum-membership-fail.md");
        let finding = report.findings.first().unwrap();
        let json = serde_json::to_value(finding).unwrap();
        for key in [
            "rule_id",
            "severity",
            "file",
            "line",
            "column",
            "message",
            "suggestion",
        ] {
            assert!(json.get(key).is_some(), "missing {key}");
        }
    }

    #[test]
    fn lint_new_enum_value_from_temp_vocabulary_passes_without_rust_enum() {
        let dir = tempfile::tempdir().unwrap();
        let vocabulary_path = dir.path().join("matrix-vocabulary.json");
        let mut vocabulary: serde_json::Value = serde_json::from_str(VOCABULARY_JSON).unwrap();
        vocabulary["status"]["enum"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::Value::String("ready_for_next".to_string()));
        fs::write(
            &vocabulary_path,
            serde_json::to_string_pretty(&vocabulary).unwrap(),
        )
        .unwrap();

        let (_default_report, default_errors) =
            lint_files(&[fixture("rule-02-enum-membership-fail.md")], None).unwrap();
        assert!(default_errors > 0);

        let (report, errors) = lint_files(
            &[fixture("rule-02-enum-membership-fail.md")],
            Some(&vocabulary_path),
        )
        .unwrap();
        assert_eq!(errors, 0, "{:?}", report.findings);
    }

    #[test]
    fn lint_domain_local_fixture_vocabulary_accepts_namespace() {
        let vocabulary = fixture("domain-local-fixture-vocabulary.json");
        let (report, errors) =
            lint_files(&[fixture("domain-local-accepted.md")], Some(&vocabulary)).unwrap();
        assert_eq!(errors, 0, "{:?}", report.findings);
    }

    #[test]
    fn specialty_lint_rejects_known_field_not_allowed_by_manifest() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let loaded = crate::cmd::specialty::load_specialty_by_slug(&root, "staff-code-reviewer")
            .expect("staff-code-reviewer specialty should load");
        let path = fixture("specialty-release-verdict-disallowed.md");
        let mut findings = Vec::new();

        lint_files_against_specialty(&[path], &loaded, &mut findings).unwrap();

        assert!(
            findings.iter().any(|finding| {
                finding.rule_id == "envelope.specialty-field-allowed"
                    && finding.severity == "error"
                    && finding.message.contains("release_verdict")
            }),
            "expected release_verdict specialty-field-allowed error: {:?}",
            findings
        );
    }
}

#[cfg(test)]
pub mod render {
    pub mod specialty {
        use super::super::*;

        #[test]
        fn envelope_render_specialty_includes_metadata() {
            let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
            let loaded = crate::cmd::specialty::load_specialty_by_slug(&root, "scope-guard")
                .expect("scope-guard specialty should load");
            let output = render_specialty_template(&loaded, None);

            assert!(output.contains("specialty_id: \"scope-guard\""));
            assert!(output.contains("canonical_role: \"orchestrator\""));
            assert!(output.contains("manifest_hash: \""));
            assert!(output.contains(&loaded.manifest_hash));
        }
    }
}
