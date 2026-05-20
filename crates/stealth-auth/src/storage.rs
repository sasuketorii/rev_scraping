// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::errors::Result;
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub fn ensure_auth_dir(dir: &Path) -> Result<()> {
    fs::create_dir_all(dir)?;
    set_dir_permissions_0700(dir)?;
    let trash = trash_dir(dir);
    fs::create_dir_all(&trash)?;
    set_dir_permissions_0700(&trash)?;
    Ok(())
}

pub fn enc_path(dir: &Path, profile: &str) -> PathBuf {
    dir.join(format!("{profile}.enc"))
}

pub fn meta_path(dir: &Path, profile: &str) -> PathBuf {
    dir.join(format!("{profile}.meta.json"))
}

pub fn trash_dir(dir: &Path) -> PathBuf {
    dir.join(".trash")
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension(format!(
        "{}.tmp",
        path.extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("tmp")
    ));
    {
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp)?;
        set_file_permissions_0600(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    fsync_parent(path)?;
    Ok(())
}

pub fn rotate_existing_to_trash(dir: &Path, profile: &str) -> Result<()> {
    let source = enc_path(dir, profile);
    if !source.exists() {
        return Ok(());
    }
    let trash = trash_dir(dir);
    fs::create_dir_all(&trash)?;
    set_dir_permissions_0700(&trash)?;
    remove_existing_trash_generation(&trash, profile)?;
    let ts = chrono::Utc::now().timestamp();
    let target = trash.join(format!("{profile}.{ts}.enc"));
    if target.exists() {
        fs::remove_file(&target)?;
    }
    fs::rename(source, &target)?;
    fsync_parent(&target)?;
    Ok(())
}

pub fn shred_delete(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    let len = file.metadata()?.len();
    file.seek(SeekFrom::Start(0))?;
    let chunk = [0xff_u8; 8192];
    let mut remaining = len;
    while remaining > 0 {
        let write_len = remaining.min(chunk.len() as u64) as usize;
        file.write_all(&chunk[..write_len])?;
        remaining -= write_len as u64;
    }
    file.sync_all()?;
    drop(file);
    fs::remove_file(path)?;
    fsync_parent(path)?;
    Ok(())
}

pub fn fsync_parent(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        let dir = File::open(parent)?;
        dir.sync_all()?;
    }
    Ok(())
}

fn remove_existing_trash_generation(trash: &Path, profile: &str) -> Result<()> {
    let prefix = format!("{profile}.");
    for entry in fs::read_dir(trash)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(&prefix) && name.ends_with(".enc") {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

#[cfg(unix)]
pub fn set_file_permissions_0600(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
pub fn set_file_permissions_0600(_path: &Path) -> Result<()> {
    // PHASE9B-TODO: apply a restrictive Windows ACL equivalent to Unix 0600.
    // Windows ACL hardening is Phase 9b/9d. The Phase 9a behavior is best
    // effort and documented at the storage boundary.
    Ok(())
}

#[cfg(unix)]
pub fn set_dir_permissions_0700(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
pub fn set_dir_permissions_0700(_path: &Path) -> Result<()> {
    // PHASE9B-TODO: apply a restrictive Windows ACL equivalent to Unix 0700.
    // Windows ACL hardening is Phase 9b/9d. The Phase 9a behavior is best
    // effort and documented at the storage boundary.
    Ok(())
}
