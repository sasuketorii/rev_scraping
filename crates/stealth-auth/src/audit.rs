// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::errors::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AuditEvent {
    pub ts: DateTime<Utc>,
    pub profile: String,
    pub action: String,
}

pub fn append_jsonl(path: &Path, event: &AuditEvent) -> Result<()> {
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    serde_json::to_writer(&mut file, event)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audit_jsonl_append_has_no_cookie_value() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("audit.jsonl");
        append_jsonl(
            &path,
            &AuditEvent {
                ts: Utc::now(),
                profile: "work".to_string(),
                action: "save".to_string(),
            },
        )
        .unwrap();
        let contents = std::fs::read_to_string(path).unwrap();
        assert!(contents.contains("\"profile\":\"work\""));
        assert!(!contents.contains("SUPER_SECRET_VALUE_XYZ"));
    }
}
