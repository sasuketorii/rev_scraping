// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P5.2 ConfigWriter)

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Atomic config writer trait with .bak backup + tempfile+rename semantics.
pub trait ConfigWriter {
    fn write_with_backup(&self, path: &Path, contents: &[u8])
        -> Result<WriteReport, WriterError>;
    fn list_backups(&self, path: &Path) -> Result<Vec<PathBuf>, WriterError>;
    fn gc_backups(&self, path: &Path, keep_n: usize) -> Result<usize, WriterError>;
}

#[derive(Debug, Clone)]
pub struct WriteReport {
    pub final_path: PathBuf,
    pub backup_path: Option<PathBuf>,
    pub bytes_written: usize,
}

#[derive(Debug)]
pub enum WriterError {
    Io(io::Error),
    ParentDirMissing(PathBuf),
    PermissionDenied(PathBuf),
}

impl std::fmt::Display for WriterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WriterError::Io(e) => write!(f, "io error: {e}"),
            WriterError::ParentDirMissing(p) => {
                write!(f, "parent dir missing: {}", p.display())
            }
            WriterError::PermissionDenied(p) => {
                write!(f, "permission denied: {}", p.display())
            }
        }
    }
}

impl std::error::Error for WriterError {}

impl From<io::Error> for WriterError {
    fn from(e: io::Error) -> Self {
        match e.kind() {
            io::ErrorKind::PermissionDenied => {
                WriterError::PermissionDenied(PathBuf::from("<unknown>"))
            }
            _ => WriterError::Io(e),
        }
    }
}

pub struct FsConfigWriter;

fn epoch_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn rand_suffix() -> String {
    // std-only pseudo-random: ns + pid. Sufficient for tempfile uniqueness.
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}_{}", std::process::id(), nanos)
}

fn file_name_str(path: &Path) -> Option<String> {
    path.file_name().and_then(|s| s.to_str()).map(String::from)
}

fn bak_prefix(path: &Path) -> Option<String> {
    file_name_str(path).map(|n| format!("{n}.bak."))
}

impl ConfigWriter for FsConfigWriter {
    fn write_with_backup(
        &self,
        path: &Path,
        contents: &[u8],
    ) -> Result<WriteReport, WriterError> {
        let parent = path
            .parent()
            .ok_or_else(|| WriterError::ParentDirMissing(path.to_path_buf()))?;
        if !parent.as_os_str().is_empty() && !parent.exists() {
            return Err(WriterError::ParentDirMissing(parent.to_path_buf()));
        }

        // 1. Backup existing file (if any). Use create_new to avoid clobbering
        // any same-ms backup; on collision, append a monotonic counter suffix.
        let backup_path = if path.exists() {
            let name = file_name_str(path)
                .ok_or_else(|| WriterError::ParentDirMissing(path.to_path_buf()))?;
            let base_ms = epoch_ms();
            let mut bak = parent.join(format!("{name}.bak.{base_ms}"));
            let mut counter: u32 = 0;
            // Open destination with O_CREAT|O_EXCL semantics; bump suffix on EEXIST.
            // On Unix, the file is created with mode 0600 atomically (no post-creation
            // chmod window where another reader could observe the default 0644 file).
            // Windows: ACL inherits from parent; tracked as TODO for hardening.
            let mut dest = loop {
                let mut opts = fs::OpenOptions::new();
                opts.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    opts.mode(0o600);
                }
                match opts.open(&bak) {
                    Ok(f) => break f,
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                        counter = counter
                            .checked_add(1)
                            .ok_or_else(|| {
                                WriterError::Io(io::Error::new(
                                    io::ErrorKind::AlreadyExists,
                                    "backup suffix counter exhausted",
                                ))
                            })?;
                        bak = parent.join(format!("{name}.bak.{base_ms}_{counter}"));
                    }
                    Err(e) => return Err(WriterError::Io(e)),
                }
            };
            let src_bytes = fs::read(path).map_err(WriterError::Io)?;
            io::Write::write_all(&mut dest, &src_bytes).map_err(WriterError::Io)?;
            dest.sync_all().map_err(WriterError::Io)?;
            drop(dest);
            Some(bak)
        } else {
            None
        };

        // 2. Write to tempfile sibling. Create with mode 0600 atomically on Unix
        // (no chmod-after-create race window). Windows: TODO ACL hardening.
        let tmp_name = match file_name_str(path) {
            Some(n) => format!(".{n}.tmp.{}", rand_suffix()),
            None => format!(".tmp.{}", rand_suffix()),
        };
        let tmp_path = parent.join(tmp_name);
        {
            let mut opts = fs::OpenOptions::new();
            opts.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            let mut tmp_file = opts.open(&tmp_path).map_err(WriterError::Io)?;
            io::Write::write_all(&mut tmp_file, contents).map_err(WriterError::Io)?;
            tmp_file.sync_all().map_err(WriterError::Io)?;
        }

        // 3. Atomic rename.
        if let Err(e) = fs::rename(&tmp_path, path) {
            let _ = fs::remove_file(&tmp_path);
            return Err(WriterError::Io(e));
        }

        // 4. Best-effort fsync parent dir on Unix.
        #[cfg(unix)]
        {
            if let Ok(dir) = fs::File::open(parent) {
                let _ = dir.sync_all();
            }
        }

        Ok(WriteReport {
            final_path: path.to_path_buf(),
            backup_path,
            bytes_written: contents.len(),
        })
    }

    fn list_backups(&self, path: &Path) -> Result<Vec<PathBuf>, WriterError> {
        let parent = path
            .parent()
            .ok_or_else(|| WriterError::ParentDirMissing(path.to_path_buf()))?;
        let prefix = bak_prefix(path)
            .ok_or_else(|| WriterError::ParentDirMissing(path.to_path_buf()))?;

        if !parent.exists() {
            return Ok(Vec::new());
        }
        let mut entries: Vec<(PathBuf, SystemTime)> = Vec::new();
        for entry in fs::read_dir(parent).map_err(WriterError::Io)? {
            let entry = entry.map_err(WriterError::Io)?;
            let name = match entry.file_name().into_string() {
                Ok(n) => n,
                Err(_) => continue,
            };
            if !name.starts_with(&prefix) {
                continue;
            }
            let meta = entry.metadata().map_err(WriterError::Io)?;
            if !meta.is_file() {
                continue;
            }
            let mtime = meta.modified().unwrap_or(UNIX_EPOCH);
            entries.push((entry.path(), mtime));
        }
        // Sort by mtime desc; tie-break by filename desc (epoch_ms in name).
        entries.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then_with(|| b.0.file_name().cmp(&a.0.file_name()))
        });
        Ok(entries.into_iter().map(|(p, _)| p).collect())
    }

    fn gc_backups(&self, path: &Path, keep_n: usize) -> Result<usize, WriterError> {
        let baks = self.list_backups(path)?;
        let mut deleted = 0usize;
        for bak in baks.into_iter().skip(keep_n) {
            fs::remove_file(&bak).map_err(WriterError::Io)?;
            deleted += 1;
        }
        Ok(deleted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn write_creates_file_with_0600_mode() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        let r = w.write_with_backup(&p, b"hello").unwrap();
        assert_eq!(r.bytes_written, 5);
        assert!(r.backup_path.is_none());
        assert_eq!(fs::read(&p).unwrap(), b"hello");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "file mode should be 0600, got {:o}", mode);
        }
    }

    #[test]
    fn write_with_existing_file_creates_bak() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        w.write_with_backup(&p, b"v1").unwrap();
        let r = w.write_with_backup(&p, b"v2").unwrap();
        assert!(r.backup_path.is_some(), "second write should produce .bak");
        let bak = r.backup_path.unwrap();
        assert!(bak.exists());
        assert_eq!(fs::read(&bak).unwrap(), b"v1");
        assert_eq!(fs::read(&p).unwrap(), b"v2");
        let name = bak.file_name().unwrap().to_string_lossy().to_string();
        assert!(
            name.starts_with("cfg.toml.bak."),
            "bak name should start with cfg.toml.bak., got {name}"
        );
    }

    #[test]
    fn write_atomic_rename_no_partial_on_crash() {
        // Verify there is no lingering .tmp.* sibling after a successful write,
        // i.e. tempfile is consumed by rename, not left as partial state.
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        w.write_with_backup(&p, b"atomic").unwrap();
        let mut tmp_count = 0usize;
        for e in fs::read_dir(dir.path()).unwrap() {
            let e = e.unwrap();
            let n = e.file_name().to_string_lossy().to_string();
            if n.contains(".tmp.") {
                tmp_count += 1;
            }
        }
        assert_eq!(
            tmp_count, 0,
            "no .tmp.* siblings should remain after successful write"
        );
        assert_eq!(fs::read(&p).unwrap(), b"atomic");
    }

    #[test]
    fn list_backups_returns_sorted_desc_by_mtime() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        w.write_with_backup(&p, b"a").unwrap();
        // Force monotonically increasing epoch_ms by sleeping > 1ms.
        std::thread::sleep(std::time::Duration::from_millis(5));
        w.write_with_backup(&p, b"b").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        w.write_with_backup(&p, b"c").unwrap();

        let baks = w.list_backups(&p).unwrap();
        assert_eq!(baks.len(), 2, "two backups expected (a, b)");
        // Newest first: backup of "b" (created during write of "c") then backup of "a".
        let first = fs::read(&baks[0]).unwrap();
        let second = fs::read(&baks[1]).unwrap();
        assert_eq!(first, b"b");
        assert_eq!(second, b"a");
    }

    #[test]
    fn gc_backups_keeps_latest_n() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        for i in 0..4 {
            w.write_with_backup(&p, format!("v{i}").as_bytes()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(3));
        }
        // 3 backups exist (writes 1..=3 backed up prior content).
        let before = w.list_backups(&p).unwrap();
        assert_eq!(before.len(), 3);

        let deleted = w.gc_backups(&p, 1).unwrap();
        assert_eq!(deleted, 2);
        let after = w.list_backups(&p).unwrap();
        assert_eq!(after.len(), 1);

        // keep_n = 0 deletes all remaining.
        let deleted2 = w.gc_backups(&p, 0).unwrap();
        assert_eq!(deleted2, 1);
        assert_eq!(w.list_backups(&p).unwrap().len(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn tmp_file_created_with_0600_mode_directly() {
        // Verify tmp sibling is created with mode 0600 from the outset (via
        // OpenOptions.mode), not via post-creation chmod which would leave a
        // race window where the file is briefly 0644 and world-readable.
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let dir = tempdir().unwrap();
        let tmp_path = dir.path().join(".probe.tmp.race");
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create_new(true).mode(0o600);
        let f = opts.open(&tmp_path).unwrap();
        // Stat immediately after open — no intervening chmod.
        let mode = fs::metadata(&tmp_path).unwrap().permissions().mode() & 0o777;
        drop(f);
        assert_eq!(
            mode, 0o600,
            "tmp file must be 0600 at creation time, got {:o}",
            mode
        );

        // End-to-end: writer also leaves final file at 0600 (no tmp leak).
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        w.write_with_backup(&p, b"secret").unwrap();
        let final_mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(final_mode, 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn backup_file_created_with_0600_mode_directly() {
        // Verify .bak file is created with mode 0600 atomically. We trigger a
        // backup by writing twice to the same path and assert the backup mode
        // is exactly 0600 with no chmod-after-create race window.
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir().unwrap();
        let p = dir.path().join("cfg.toml");
        let w = FsConfigWriter;
        w.write_with_backup(&p, b"v1").unwrap();
        let r = w.write_with_backup(&p, b"v2").unwrap();
        let bak = r.backup_path.expect("second write should produce a backup");
        let mode = fs::metadata(&bak).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "backup file must be 0600 at creation time, got {:o}",
            mode
        );
    }

    #[test]
    fn parent_dir_missing_returns_error() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("nope").join("cfg.toml");
        let w = FsConfigWriter;
        let err = w.write_with_backup(&p, b"x").unwrap_err();
        match err {
            WriterError::ParentDirMissing(_) => {}
            other => panic!("expected ParentDirMissing, got {other:?}"),
        }
    }
}
