// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P5.1)

use serde::de::DeserializeOwned;

use super::lev;
use super::schema::{AuthorizedSchema, KnownConfig};

pub const ENV_CONFIG_LENIENT: &str = "REV_SCRAPING_CONFIG_LENIENT";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidateOptions {
    pub lenient_unknown_fields: bool,
}

impl ValidateOptions {
    pub fn strict() -> Self {
        Self {
            lenient_unknown_fields: false,
        }
    }

    fn is_lenient(&self) -> bool {
        self.lenient_unknown_fields
            || std::env::var(ENV_CONFIG_LENIENT)
                .map(|value| value == "1")
                .unwrap_or(false)
    }
}

impl Default for ValidateOptions {
    fn default() -> Self {
        Self::strict()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationReport {
    pub errors: Vec<ValidationIssue>,
    pub warnings: Vec<ValidationIssue>,
}

impl ValidationReport {
    pub fn new() -> Self {
        Self {
            errors: Vec::new(),
            warnings: Vec::new(),
        }
    }

    pub fn is_ok(&self) -> bool {
        self.errors.is_empty()
    }

    fn push(&mut self, issue: ValidationIssue, opts: &ValidateOptions) {
        if opts.is_lenient()
            && matches!(
                issue.code,
                ValidationCode::UnknownField | ValidationCode::SchemaVersionUnsupported
            )
        {
            tracing::warn!(
                target: "rev_scraping::config_io",
                path = %issue.path,
                code = ?issue.code,
                "{}",
                issue.message
            );
            self.warnings.push(issue);
        } else {
            self.errors.push(issue);
        }
    }
}

impl Default for ValidationReport {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationIssue {
    pub path: String,
    pub code: ValidationCode,
    pub message: String,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationCode {
    UnknownField,
    WrongType,
    MissingRequired,
    SchemaVersionUnsupported,
    Custom(String),
}

pub fn validate_toml_against<T>(text: &str, opts: &ValidateOptions) -> ValidationReport
where
    T: DeserializeOwned + KnownConfig,
{
    let mut report = ValidationReport::new();
    let toml_value = match toml::from_str::<toml::Value>(text) {
        Ok(value) => value,
        Err(err) => {
            report.errors.push(ValidationIssue {
                path: span_path(&err),
                code: ValidationCode::Custom("TomlParse".to_string()),
                message: err.to_string(),
                hint: None,
            });
            return report;
        }
    };

    if let Err(err) = serde_json::to_value(&toml_value) {
        report.errors.push(ValidationIssue {
            path: "$".to_string(),
            code: ValidationCode::Custom("TomlJsonBridge".to_string()),
            message: format!("TOML value could not be represented as JSON: {err}"),
            hint: None,
        });
        return report;
    }

    validate_schema_version::<T>(&toml_value, opts, &mut report);

    if let Err(err) = toml::from_str::<T>(text) {
        report.push(issue_from_toml_error::<T>(&err), opts);
    }

    report
}

/// Validate an `authorized.toml` document. Layers strict schema validation
/// (`deny_unknown_fields` + schema_version pin) on top of regex-compile checks
/// for each `url_pattern`.
pub fn validate_authorized_toml(text: &str, opts: &ValidateOptions) -> ValidationReport {
    let mut report = validate_toml_against::<AuthorizedSchema>(text, opts);
    // Pattern validation must run independently of structural outcome:
    // a downgraded `UnknownField` warning under lenient mode would otherwise
    // mask a broken `url_pattern` in the same document. We parse the targets
    // array directly out of the TOML value so unknown sibling fields cannot
    // suppress regex checks.
    extract_target_patterns(text)
        .into_iter()
        .for_each(|(index, pattern)| {
            if let Err(e) = regex::Regex::new(&pattern) {
                report.push(
                    ValidationIssue {
                        path: format!("targets[{index}].url_pattern"),
                        code: ValidationCode::Custom("InvalidRegex".to_string()),
                        message: format!("url_pattern {pattern:?} is not a valid regex: {e}"),
                        hint: Some(
                            "Escape regex metacharacters (e.g. `\\.`) or wrap a literal host \
                             in `^https?://example\\.com/`."
                                .to_string(),
                        ),
                    },
                    opts,
                );
            }
        });
    report
}

fn extract_target_patterns(text: &str) -> Vec<(usize, String)> {
    let Ok(value) = toml::from_str::<toml::Value>(text) else {
        return Vec::new();
    };
    let Some(targets) = value.get("targets").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    targets
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            item.as_table()
                .and_then(|t| t.get("url_pattern"))
                .and_then(|v| v.as_str())
                .map(|s| (idx, s.to_string()))
        })
        .collect()
}

fn validate_schema_version<T: KnownConfig>(
    value: &toml::Value,
    opts: &ValidateOptions,
    report: &mut ValidationReport,
) {
    let Some(table) = value.as_table() else {
        return;
    };
    let Some(raw_version) = table.get(T::SCHEMA_VERSION_FIELD) else {
        return;
    };
    let Some(version) = raw_version.as_integer() else {
        report.push(
            ValidationIssue {
                path: T::SCHEMA_VERSION_FIELD.to_string(),
                code: ValidationCode::WrongType,
                message: format!(
                    "{} must be an integer schema version",
                    T::SCHEMA_VERSION_FIELD
                ),
                hint: Some("Use schema_version = 1 for the reserved v1 config schema.".to_string()),
            },
            opts,
        );
        return;
    };

    let Ok(version) = u32::try_from(version) else {
        report.push(
            unsupported_schema_version_issue::<T>(version.to_string()),
            opts,
        );
        return;
    };

    if !T::supported_versions().contains(&version) {
        report.push(
            unsupported_schema_version_issue::<T>(version.to_string()),
            opts,
        );
    }
}

fn unsupported_schema_version_issue<T: KnownConfig>(found: String) -> ValidationIssue {
    ValidationIssue {
        path: T::SCHEMA_VERSION_FIELD.to_string(),
        code: ValidationCode::SchemaVersionUnsupported,
        message: format!("unsupported schema version {found}"),
        hint: Some(format!(
            "Supported versions for this config are: {}.",
            T::supported_versions()
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

fn issue_from_toml_error<T: KnownConfig>(err: &toml::de::Error) -> ValidationIssue {
    let message = err.to_string();
    let (code, hint) = if message.contains("unknown field") {
        (
            ValidationCode::UnknownField,
            extract_backtick_value(&message).and_then(|field| closest_field_hint::<T>(&field)),
        )
    } else if message.contains("missing field") {
        (ValidationCode::MissingRequired, None)
    } else if message.contains("invalid type") {
        (ValidationCode::WrongType, None)
    } else {
        (ValidationCode::Custom("Deserialize".to_string()), None)
    };

    ValidationIssue {
        path: error_path(err),
        code,
        message,
        hint,
    }
}

fn closest_field_hint<T: KnownConfig>(field: &str) -> Option<String> {
    T::known_fields()
        .iter()
        .map(|candidate| (*candidate, lev::distance(field, candidate)))
        .filter(|(_, distance)| *distance <= 2)
        .min_by_key(|(_, distance)| *distance)
        .map(|(candidate, _)| format!("Did you mean `{candidate}`?"))
}

fn extract_backtick_value(message: &str) -> Option<String> {
    let start = message.find('`')?;
    let rest = &message[start + 1..];
    let end = rest.find('`')?;
    Some(rest[..end].to_string())
}

fn error_path(err: &toml::de::Error) -> String {
    extract_backtick_value(&err.to_string()).unwrap_or_else(|| span_path(err))
}

fn span_path(err: &toml::de::Error) -> String {
    err.span()
        .map(|span| format!("byte {}..{}", span.start, span.end))
        .unwrap_or_else(|| "$".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_io::default_schema_version_v1;
    use crate::policy::Policy;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_lenient_env<R>(value: Option<&str>, f: impl FnOnce() -> R) -> R {
        let _guard = ENV_LOCK.lock().unwrap();
        let previous = std::env::var(ENV_CONFIG_LENIENT).ok();
        match value {
            Some(value) => std::env::set_var(ENV_CONFIG_LENIENT, value),
            None => std::env::remove_var(ENV_CONFIG_LENIENT),
        }
        let result = f();
        match previous {
            Some(previous) => std::env::set_var(ENV_CONFIG_LENIENT, previous),
            None => std::env::remove_var(ENV_CONFIG_LENIENT),
        }
        result
    }

    #[test]
    fn parses_v1_1_0_policy_default() {
        let text = toml::to_string(&Policy::default()).expect("serialize default policy");
        let parsed: Policy = toml::from_str(&text).expect("default policy parses");
        assert_eq!(parsed.schema_version, default_schema_version_v1());
    }

    #[test]
    fn unknown_field_rejected_strict() {
        with_lenient_env(None, || {
            let report = validate_toml_against::<Policy>(
                "require_vpn = true\nbogus_field = \"x\"\n",
                &ValidateOptions::strict(),
            );
            assert_eq!(report.errors.len(), 1);
            assert_eq!(report.errors[0].code, ValidationCode::UnknownField);
            assert!(report.warnings.is_empty());
        });
    }

    #[test]
    fn unknown_field_downgraded_lenient() {
        with_lenient_env(Some("1"), || {
            let report = validate_toml_against::<Policy>(
                "require_vpn = true\nbogus_field = \"x\"\n",
                &ValidateOptions::strict(),
            );
            assert!(report.errors.is_empty());
            assert_eq!(report.warnings.len(), 1);
            assert_eq!(report.warnings[0].code, ValidationCode::UnknownField);
        });
    }

    #[test]
    fn did_you_mean_suggests_close_field() {
        with_lenient_env(None, || {
            let report =
                validate_toml_against::<Policy>("requier_vpn = true\n", &ValidateOptions::strict());
            assert_eq!(report.errors.len(), 1);
            assert_eq!(report.errors[0].code, ValidationCode::UnknownField);
            assert_eq!(
                report.errors[0].hint.as_deref(),
                Some("Did you mean `require_vpn`?")
            );
        });
    }

    #[test]
    fn missing_schema_version_defaults_to_1() {
        let parsed: Policy = toml::from_str("").expect("empty policy parses");
        assert_eq!(parsed.schema_version, default_schema_version_v1());
    }

    // ---- P5.1 spec-required tests --------------------------------------

    #[test]
    fn validate_policy_accepts_existing_templates_policy_toml() {
        with_lenient_env(None, || {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../..")
                .join("templates/policy.toml");
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
            let report = validate_toml_against::<Policy>(&text, &ValidateOptions::strict());
            assert!(
                report.is_ok(),
                "templates/policy.toml must validate clean; errors={:?}",
                report.errors
            );
        });
    }

    #[test]
    fn validate_policy_rejects_unknown_field() {
        with_lenient_env(None, || {
            let report =
                validate_toml_against::<Policy>("requite_vpn = true\n", &ValidateOptions::strict());
            assert_eq!(report.errors.len(), 1);
            assert_eq!(report.errors[0].code, ValidationCode::UnknownField);
        });
    }

    #[test]
    fn validate_policy_levenshtein_suggests_correction() {
        with_lenient_env(None, || {
            let report =
                validate_toml_against::<Policy>("requite_vpn = true\n", &ValidateOptions::strict());
            assert_eq!(report.errors.len(), 1);
            assert_eq!(
                report.errors[0].hint.as_deref(),
                Some("Did you mean `require_vpn`?")
            );
        });
    }

    #[test]
    fn validate_authorized_accepts_existing_templates() {
        // No canonical templates/authorized.toml file exists in the
        // distribution (it is generated per-operator at install time), so we
        // pin the canonical example shape inline and assert it validates.
        let text = r#"
schema_version = 1

[[targets]]
url_pattern = "^https://example\\.com/"
auth_allowed = false

[[targets]]
url_pattern = "^https://test\\.local/"
"#;
        with_lenient_env(None, || {
            let report = validate_authorized_toml(text, &ValidateOptions::strict());
            assert!(
                report.is_ok(),
                "canonical authorized.toml shape must validate clean; errors={:?}",
                report.errors
            );
        });
    }

    #[test]
    fn validate_authorized_rejects_invalid_url_pattern() {
        let text = r#"
[[targets]]
url_pattern = "["
"#;
        with_lenient_env(None, || {
            let report = validate_authorized_toml(text, &ValidateOptions::strict());
            assert!(!report.is_ok(), "broken regex must produce an error");
            let invalid_regex = report
                .errors
                .iter()
                .find(|e| matches!(&e.code, ValidationCode::Custom(c) if c == "InvalidRegex"));
            assert!(
                invalid_regex.is_some(),
                "expected InvalidRegex error, got {:?}",
                report.errors
            );
            assert_eq!(invalid_regex.unwrap().path, "targets[0].url_pattern");
        });
    }

    #[test]
    fn validate_authorized_lenient_mode_still_flags_invalid_regex() {
        // Reviewer round-1 finding: lenient unknown-field downgrade must
        // not suppress regex-compile errors.
        let text = r#"
bogus_root = true

[[targets]]
url_pattern = "["
"#;
        with_lenient_env(Some("1"), || {
            let report = validate_authorized_toml(text, &ValidateOptions::strict());
            let has_invalid_regex = report
                .errors
                .iter()
                .any(|e| matches!(&e.code, ValidationCode::Custom(c) if c == "InvalidRegex"));
            assert!(
                has_invalid_regex,
                "InvalidRegex must surface even when other fields are downgraded; got errors={:?} warnings={:?}",
                report.errors, report.warnings,
            );
        });
    }

    #[test]
    fn policy_schema_version_default_is_1() {
        let parsed: Policy = toml::from_str("").expect("empty policy parses");
        assert_eq!(parsed.schema_version, 1);
        assert_eq!(parsed.schema_version, default_schema_version_v1());
    }

    #[test]
    fn unsupported_schema_version_errors() {
        with_lenient_env(None, || {
            let report = validate_toml_against::<Policy>(
                "schema_version = 999\n",
                &ValidateOptions::strict(),
            );
            assert_eq!(report.errors.len(), 1);
            assert_eq!(
                report.errors[0].code,
                ValidationCode::SchemaVersionUnsupported
            );
        });
    }
}
