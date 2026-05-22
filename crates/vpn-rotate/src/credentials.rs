// SPDX-License-Identifier: MIT
//! Credential resolver for systemd `LoadCredentialEncrypted=` integration.
//!
//! Lane A P10.2: Reads secrets from a `<KEY>_FILE` environment variable
//! pointing at a file in `${CREDENTIALS_DIRECTORY}/...` (populated by systemd's
//! Credentials subsystem), falling back to the raw `<KEY>` env var for dev /
//! non-systemd runtimes. Returned values are wrapped in [`SecretString`] so the
//! plaintext is zeroized on drop and never accidentally `Debug`-printed.

use secrecy::SecretString;
use std::path::{Path, PathBuf};

/// Resolver for secrets supplied via `LoadCredentialEncrypted=` (file) or env.
pub struct CredentialResolver;

/// Errors returned by [`CredentialResolver::resolve`].
#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    /// `<KEY>_FILE` was set but the file could not be read.
    #[error("failed to read credential file {path}: {source}")]
    FileReadFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    /// Neither `<KEY>_FILE` nor `<KEY>` was present in the environment.
    #[error("credential env var missing: {key} (and {key}_FILE unset)")]
    EnvMissing { key: String },
    /// File mode is not restricted to owner-only (0600 expected).
    #[error("credential file {path} has insecure mode {mode:o}; expected 0600")]
    FilePermNotRestricted { path: PathBuf, mode: u32 },
}

impl CredentialResolver {
    /// Resolve `<KEY>` by first checking `<KEY>_FILE` (file contents, trimmed),
    /// then falling back to the `<KEY>` env var. Returns an error if neither is
    /// set, or if the file exists but cannot be read.
    pub fn resolve(key: &str) -> Result<SecretString, CredentialError> {
        Self::resolve_with_env(key, |k| std::env::var(k).ok())
    }

    /// Like [`Self::resolve`] but returns `None` when nothing is set.
    pub fn resolve_optional(key: &str) -> Option<SecretString> {
        Self::resolve(key).ok()
    }

    /// Same as `resolve` but reads via an injected env lookup (test seam).
    pub fn resolve_with_env<F>(key: &str, env: F) -> Result<SecretString, CredentialError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let file_key = format!("{key}_FILE");
        if let Some(path) = env(&file_key) {
            let path = PathBuf::from(path);
            check_file_perm(&path)?;
            let raw = std::fs::read_to_string(&path)
                .map_err(|source| CredentialError::FileReadFailed { path: path.clone(), source })?;
            return Ok(SecretString::new(raw.trim_end_matches(['\n', '\r']).to_owned().into()));
        }
        match env(key) {
            Some(v) => Ok(SecretString::new(v.into())),
            None => Err(CredentialError::EnvMissing { key: key.to_owned() }),
        }
    }
}

#[cfg(unix)]
fn check_file_perm(path: &Path) -> Result<(), CredentialError> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path).map_err(|source| CredentialError::FileReadFailed {
        path: path.to_path_buf(),
        source,
    })?;
    let mode = meta.permissions().mode() & 0o777;
    // systemd CREDENTIALS_DIRECTORY exposes files as 0400; refuse anything
    // group/world-readable (mode & 0o077 != 0).
    if mode & 0o077 != 0 {
        return Err(CredentialError::FilePermNotRestricted {
            path: path.to_path_buf(),
            mode,
        });
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_file_perm(_path: &Path) -> Result<(), CredentialError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrecy::ExposeSecret;
    use std::collections::HashMap;
    use std::io::Write;

    fn env_from<'a>(
        map: &'a HashMap<&'a str, String>,
    ) -> impl Fn(&str) -> Option<String> + 'a {
        move |k: &str| map.get(k).cloned()
    }

    #[cfg(unix)]
    fn write_secret(contents: &str, mode: u32) -> (tempfile::TempDir, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cred");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(mode);
        std::fs::set_permissions(&path, perms).unwrap();
        (dir, path)
    }

    #[test]
    #[cfg(unix)]
    fn file_path_resolve_trims_trailing_newline() {
        let (_dir, path) = write_secret("hunter2\n", 0o600);
        let mut map = HashMap::new();
        map.insert("VPN_USER_FILE", path.to_string_lossy().into_owned());
        let env = env_from(&map);
        let s = CredentialResolver::resolve_with_env("VPN_USER", env).unwrap();
        assert_eq!(s.expose_secret(), "hunter2");
    }

    #[test]
    fn file_missing_falls_back_env() {
        let mut map = HashMap::new();
        map.insert("VPN_USER", "fallback".to_owned());
        let env = env_from(&map);
        let s = CredentialResolver::resolve_with_env("VPN_USER", env).unwrap();
        assert_eq!(s.expose_secret(), "fallback");
    }

    #[test]
    fn env_missing_errors() {
        let map: HashMap<&str, String> = HashMap::new();
        let env = env_from(&map);
        let err = CredentialResolver::resolve_with_env("VPN_USER", env).unwrap_err();
        assert!(matches!(err, CredentialError::EnvMissing { .. }));
    }

    #[test]
    #[cfg(unix)]
    fn file_perm_rejected_when_world_readable() {
        let (_dir, path) = write_secret("topsecret", 0o644);
        let mut map = HashMap::new();
        map.insert("VPN_PASSWORD_FILE", path.to_string_lossy().into_owned());
        let env = env_from(&map);
        let err = CredentialResolver::resolve_with_env("VPN_PASSWORD", env).unwrap_err();
        assert!(matches!(err, CredentialError::FilePermNotRestricted { .. }));
    }

    #[test]
    fn secret_string_does_not_leak_in_debug() {
        // SecretString's Debug impl must not expose the plaintext.
        let s = SecretString::new("super-sensitive".to_owned().into());
        let dbg = format!("{s:?}");
        assert!(!dbg.contains("super-sensitive"), "Debug leaked secret: {dbg}");
        // Sanity: ExposeSecret still works (and zeroizes on drop via Drop impl).
        assert_eq!(s.expose_secret(), "super-sensitive");
    }

    #[test]
    fn file_read_failed_on_missing_path() {
        let mut map = HashMap::new();
        map.insert(
            "VPN_USER_FILE",
            "/nonexistent/rev-stealth/p10_2/missing.cred".to_owned(),
        );
        let env = env_from(&map);
        let err = CredentialResolver::resolve_with_env("VPN_USER", env).unwrap_err();
        assert!(matches!(err, CredentialError::FileReadFailed { .. }));
    }
}
