//! Deterministic task stamp generation.

use std::collections::BTreeMap;

use chrono::{DateTime, SecondsFormat, Utc};
use clap::Args;
use sha2::{Digest, Sha256};

use shared::error::{AgentError, Result};

#[derive(Args, Debug)]
pub struct TaskStampArgs {
    /// Task identifier.
    #[arg(long)]
    task_id: String,
    /// Human-readable task description.
    #[arg(long)]
    description: String,
    /// RFC3339 UTC timestamp. Defaults to the current UTC time.
    #[arg(long)]
    timestamp: Option<String>,
}

pub fn run(args: TaskStampArgs) -> Result<()> {
    let stamp = build_task_stamp(&args.task_id, &args.description, args.timestamp.as_deref())?;
    println!("{}", serde_json::to_string(&stamp)?);
    Ok(())
}

fn build_task_stamp(
    task_id: &str,
    description: &str,
    timestamp: Option<&str>,
) -> Result<BTreeMap<&'static str, String>> {
    validate_task_id(task_id)?;
    validate_description(description)?;

    let timestamp = match timestamp {
        Some(value) => parse_utc_timestamp(value)?,
        None => Utc::now(),
    };
    let timestamp = format_timestamp(timestamp);
    let stamp_id = stamp_id(task_id, description, &timestamp);

    let mut stamp = BTreeMap::new();
    stamp.insert("description", description.to_string());
    stamp.insert("stamp_id", stamp_id);
    stamp.insert("task_id", task_id.to_string());
    stamp.insert("timestamp", timestamp);
    Ok(stamp)
}

fn validate_task_id(task_id: &str) -> Result<()> {
    let bytes = task_id.as_bytes();
    if !(3..=64).contains(&bytes.len()) {
        return Err(AgentError::Validation(
            "task-id must be 3-64 ASCII characters".to_string(),
        ));
    }

    let Some(first) = bytes.first() else {
        return Err(AgentError::Validation(
            "task-id must not be empty".to_string(),
        ));
    };
    if !first.is_ascii_alphanumeric() {
        return Err(AgentError::Validation(
            "task-id must start with an ASCII letter or digit".to_string(),
        ));
    }

    if !bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(AgentError::Validation(
            "task-id may contain only ASCII letters, digits, '.', '_', or '-'".to_string(),
        ));
    }

    Ok(())
}

fn validate_description(description: &str) -> Result<()> {
    let len = description.len();
    if !(1..=200).contains(&len) {
        return Err(AgentError::Validation(
            "description must be 1-200 bytes".to_string(),
        ));
    }

    if description.chars().any(char::is_control) {
        return Err(AgentError::Validation(
            "description must not contain disallowed control characters".to_string(),
        ));
    }

    Ok(())
}

fn parse_utc_timestamp(value: &str) -> Result<DateTime<Utc>> {
    if !value.ends_with('Z') {
        return Err(AgentError::Validation(
            "invalid timestamp: not RFC3339 UTC".to_string(),
        ));
    }

    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|_| AgentError::Validation("invalid timestamp: not RFC3339 UTC".to_string()))
}

fn format_timestamp(timestamp: DateTime<Utc>) -> String {
    timestamp.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn stamp_id(task_id: &str, description: &str, timestamp: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(task_id.as_bytes());
    hasher.update(b"\n");
    hasher.update(description.as_bytes());
    hasher.update(b"\n");
    hasher.update(timestamp.as_bytes());
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_stamp_valid_with_explicit_timestamp() {
        let stamp = build_task_stamp("DRILL-001", "ok", Some("2026-05-20T00:00:00Z")).unwrap();

        assert_eq!(stamp.get("description").unwrap(), "ok");
        assert_eq!(stamp.get("task_id").unwrap(), "DRILL-001");
        assert_eq!(stamp.get("timestamp").unwrap(), "2026-05-20T00:00:00Z");

        let stamp_id = stamp.get("stamp_id").unwrap();
        assert_eq!(stamp_id.len(), 64);
        assert!(stamp_id
            .chars()
            .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
    }

    #[test]
    fn task_stamp_rejects_invalid_task_id() {
        assert!(build_task_stamp("_DRILL", "ok", Some("2026-05-20T00:00:00Z")).is_err());
    }

    #[test]
    fn task_stamp_rejects_description_too_long() {
        let description = "a".repeat(201);
        assert!(build_task_stamp("DRILL-001", &description, Some("2026-05-20T00:00:00Z")).is_err());
    }

    #[test]
    fn task_stamp_rejects_invalid_timestamp() {
        assert!(build_task_stamp("DRILL-001", "ok", Some("not-a-date")).is_err());
    }

    #[test]
    fn task_stamp_rejects_ansi_escape_in_timestamp() {
        let value = "2026-05-20T00:00:00\x1b[31mZ";
        let error = build_task_stamp("DRILL-001", "ok", Some(value))
            .unwrap_err()
            .to_string();

        assert!(error.contains("invalid timestamp: not RFC3339 UTC"));
        assert!(!error.contains(value));
        assert!(!error.contains("\x1b[31m"));
    }

    #[test]
    fn task_stamp_rejects_newline_in_timestamp() {
        let value = "2026-05-20T00:00:00\nZ";
        let error = build_task_stamp("DRILL-001", "ok", Some(value))
            .unwrap_err()
            .to_string();

        assert!(error.contains("invalid timestamp: not RFC3339 UTC"));
        assert!(!error.contains(value));
        assert!(!error.contains('\n'));
    }

    #[test]
    fn task_stamp_deterministic() {
        let first = build_task_stamp("DRILL-001", "ok", Some("2026-05-20T00:00:00Z")).unwrap();
        let second = build_task_stamp("DRILL-001", "ok", Some("2026-05-20T00:00:00Z")).unwrap();

        assert_eq!(first.get("stamp_id"), second.get("stamp_id"));
    }

    #[test]
    fn task_stamp_rejects_control_characters() {
        assert!(build_task_stamp("DRILL-001", "bad\nvalue", Some("2026-05-20T00:00:00Z")).is_err());
    }

    #[test]
    fn task_stamp_rejects_htab_in_description() {
        assert!(build_task_stamp("DRILL-001", "ok\tvalue", Some("2026-05-20T00:00:00Z")).is_err());
    }

    #[test]
    fn task_stamp_rejects_all_control_chars_in_description() {
        for codepoint in (0x00..=0x1f).chain(std::iter::once(0x7f)) {
            let control = char::from_u32(codepoint).unwrap();
            let description = format!("bad{control}value");
            let error = build_task_stamp(
                "DRILL-001",
                &description,
                Some("2026-05-20T00:00:00Z"),
            )
            .unwrap_err()
            .to_string();

            assert!(
                error.contains("description must not contain disallowed control characters"),
                "codepoint {codepoint:#04x} returned unexpected error: {error}"
            );
            assert!(!error.contains(&description));
        }
    }
}
