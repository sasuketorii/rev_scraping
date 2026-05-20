// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)

use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use regex::Regex;

use crate::error::{Result, SitesError};
use crate::recipe::SiteRecipe;

/// Filesystem-backed per-domain recipe store. One TOML file per eTLD+1,
/// atomic write semantics on POSIX.
pub struct SiteRecipeStore {
    dir: PathBuf,
}

/// Regex matching keys/values that look like secrets. Applied to the
/// serialized TOML payload at save time. Conservative — false positives are
/// preferable to leaking a cookie.
fn secret_regex() -> Regex {
    Regex::new(r"(?i)\b(cookie|token|session|bearer|password|api[_-]?key)\b")
        .expect("static regex compiles")
}

impl SiteRecipeStore {
    /// Open (or create) the store rooted at `dir`. Sets directory mode to
    /// `0700` on Unix; non-Unix platforms get default permissions.
    pub fn open(dir: &Path) -> Result<Self> {
        fs::create_dir_all(dir).map_err(|e| SitesError::Io {
            path: dir.to_path_buf(),
            source: e,
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perm = fs::Permissions::from_mode(0o700);
            // Best-effort; ignore if the FS doesn't support chmod.
            let _ = fs::set_permissions(dir, perm);
        }
        Ok(Self {
            dir: dir.to_path_buf(),
        })
    }

    /// Map a domain to the on-disk file path. Rejects path-separator chars
    /// to ensure recipes can't escape `dir`.
    fn path_for(&self, domain: &str) -> Result<PathBuf> {
        if domain.is_empty()
            || domain.contains('/')
            || domain.contains('\\')
            || domain.contains("..")
        {
            return Err(SitesError::InvalidDomain(domain.to_string()));
        }
        Ok(self.dir.join(format!("{domain}.toml")))
    }

    pub fn load(&self, domain: &str) -> Result<Option<SiteRecipe>> {
        let path = self.path_for(domain)?;
        match fs::read_to_string(&path) {
            Ok(text) => {
                let recipe: SiteRecipe = toml::from_str(&text)?;
                Ok(Some(recipe))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(SitesError::Io { path, source: e }),
        }
    }

    pub fn save(&mut self, recipe: &SiteRecipe) -> Result<()> {
        let path = self.path_for(&recipe.site.domain)?;
        let body = toml::to_string_pretty(recipe)?;

        if let Some(m) = secret_regex().find(&body) {
            return Err(SitesError::SecretRejected(m.as_str().to_string()));
        }

        // Atomic write: temp file in the same dir, fsync, rename.
        let tmp_path = path.with_extension("toml.tmp");
        {
            let mut f = fs::File::create(&tmp_path).map_err(|e| SitesError::Io {
                path: tmp_path.clone(),
                source: e,
            })?;
            f.write_all(body.as_bytes()).map_err(|e| SitesError::Io {
                path: tmp_path.clone(),
                source: e,
            })?;
            f.sync_all().map_err(|e| SitesError::Io {
                path: tmp_path.clone(),
                source: e,
            })?;

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = f.set_permissions(fs::Permissions::from_mode(0o600));
            }
        }

        fs::rename(&tmp_path, &path).map_err(|e| SitesError::Io {
            path: path.clone(),
            source: e,
        })?;

        Ok(())
    }

    pub fn list_domains(&self) -> Result<Vec<String>> {
        let mut out = Vec::new();
        let entries = fs::read_dir(&self.dir).map_err(|e| SitesError::Io {
            path: self.dir.clone(),
            source: e,
        })?;
        for entry in entries {
            let entry = entry.map_err(|e| SitesError::Io {
                path: self.dir.clone(),
                source: e,
            })?;
            let p = entry.path();
            if p.extension() == Some(OsStr::new("toml")) {
                if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                    out.push(stem.to_string());
                }
            }
        }
        out.sort();
        Ok(out)
    }

    pub fn remove(&mut self, domain: &str) -> Result<()> {
        let path = self.path_for(domain)?;
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(SitesError::Io { path, source: e }),
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}
