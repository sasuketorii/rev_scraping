// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

//! SQLite-backed fingerprint store (WAL mode, 0700 dir on Unix).

use crate::fingerprint::ElementFingerprint;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS fingerprints (
    stable_id TEXT NOT NULL,
    url_fld TEXT NOT NULL,
    css_path TEXT NOT NULL,
    xpath TEXT NOT NULL,
    text_norm TEXT NOT NULL,
    tag_name TEXT NOT NULL,
    attrs_json TEXT NOT NULL,
    attrs_hash INTEGER NOT NULL,
    neighbor_hash INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    PRIMARY KEY (stable_id, url_fld)
);
CREATE INDEX IF NOT EXISTS idx_fp_fld ON fingerprints(url_fld);
"#;

pub struct ParseStore {
    pub(crate) db: Connection,
}

impl ParseStore {
    /// Open (or create) a SQLite DB file at `path` in WAL mode. Parent dir is created
    /// with 0700 perms on Unix.
    pub fn open(path: &Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ =
                        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
                }
            }
        }
        let db = Connection::open(path)?;
        // Pragmas must be applied before schema for WAL to stick.
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.pragma_update(None, "synchronous", "NORMAL")?;
        db.execute_batch(SCHEMA)?;
        Ok(Self { db })
    }

    /// Insert-or-replace a fingerprint.
    pub fn upsert(&mut self, fp: &ElementFingerprint) -> anyhow::Result<()> {
        let last_seen = fp
            .last_seen
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.db.execute(
            "INSERT INTO fingerprints
              (stable_id, url_fld, css_path, xpath, text_norm, tag_name,
               attrs_json, attrs_hash, neighbor_hash, last_seen)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
             ON CONFLICT(stable_id, url_fld) DO UPDATE SET
               css_path=excluded.css_path,
               xpath=excluded.xpath,
               text_norm=excluded.text_norm,
               tag_name=excluded.tag_name,
               attrs_json=excluded.attrs_json,
               attrs_hash=excluded.attrs_hash,
               neighbor_hash=excluded.neighbor_hash,
               last_seen=excluded.last_seen",
            params![
                fp.stable_id,
                fp.url_fld,
                fp.css_path,
                fp.xpath,
                fp.text_norm,
                fp.tag_name,
                fp.attrs_json,
                fp.attrs_hash as i64,
                fp.neighbor_hash as i64,
                last_seen,
            ],
        )?;
        Ok(())
    }

    /// Look up by (stable_id, url_fld).
    pub fn lookup(
        &self,
        stable_id: &str,
        url_fld: &str,
    ) -> anyhow::Result<Option<ElementFingerprint>> {
        let row = self.db.query_row(
            "SELECT stable_id, url_fld, css_path, xpath, text_norm, tag_name,
                    attrs_json, attrs_hash, neighbor_hash, last_seen
             FROM fingerprints WHERE stable_id = ?1 AND url_fld = ?2",
            params![stable_id, url_fld],
            |r| {
                let last_seen: i64 = r.get(9)?;
                let attrs_hash: i64 = r.get(7)?;
                let neighbor_hash: i64 = r.get(8)?;
                Ok(ElementFingerprint {
                    stable_id: r.get(0)?,
                    url_fld: r.get(1)?,
                    css_path: r.get(2)?,
                    xpath: r.get(3)?,
                    text_norm: r.get(4)?,
                    tag_name: r.get(5)?,
                    attrs_json: r.get(6)?,
                    attrs_hash: attrs_hash as u64,
                    neighbor_hash: neighbor_hash as u64,
                    last_seen: UNIX_EPOCH + std::time::Duration::from_secs(last_seen.max(0) as u64),
                })
            },
        );
        Ok(row.optional()?)
    }

    /// Delete fingerprints whose `last_seen` is older than `days` ago. Returns rows deleted.
    pub fn purge_older_than_days(&mut self, days: u64) -> anyhow::Result<usize> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let cutoff = now - (days as i64) * 86_400;
        let n = self.db.execute(
            "DELETE FROM fingerprints WHERE last_seen < ?1",
            params![cutoff],
        )?;
        Ok(n)
    }

    /// Test helper: returns the current journal_mode pragma.
    #[doc(hidden)]
    pub fn journal_mode(&self) -> anyhow::Result<String> {
        let v: String = self.db.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
        Ok(v)
    }
}
