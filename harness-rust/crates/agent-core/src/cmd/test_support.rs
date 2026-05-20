use std::env;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

static PROCESS_STATE_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn lock_process_state() -> MutexGuard<'static, ()> {
    PROCESS_STATE_LOCK
        .lock()
        .expect("process state lock should not be poisoned")
}

pub(crate) struct EnvGuard {
    key: &'static str,
    original: Option<OsString>,
}

impl EnvGuard {
    pub(crate) fn set(key: &'static str, value: impl AsRef<OsStr>) -> Self {
        let original = env::var_os(key);
        env::set_var(key, value);
        Self { key, original }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        if let Some(value) = self.original.take() {
            env::set_var(self.key, value);
        } else {
            env::remove_var(self.key);
        }
    }
}

pub(crate) struct PathGuard(Option<OsString>);

impl PathGuard {
    pub(crate) fn prepend(path: &Path) -> Self {
        let original = env::var_os("PATH");
        let mut entries = vec![path.to_path_buf()];
        if let Some(current) = &original {
            entries.extend(env::split_paths(current));
        }
        let joined = env::join_paths(entries.iter()).expect("test PATH should be valid");
        env::set_var("PATH", joined);
        Self(original)
    }
}

impl Drop for PathGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            env::set_var("PATH", path);
        } else {
            env::remove_var("PATH");
        }
    }
}

pub(crate) struct CurrentDirGuard(PathBuf);

impl CurrentDirGuard {
    pub(crate) fn set(path: &Path) -> Self {
        let original = env::current_dir().expect("current directory should be readable");
        env::set_current_dir(path).expect("current directory should be settable");
        Self(original)
    }
}

impl Drop for CurrentDirGuard {
    fn drop(&mut self) {
        env::set_current_dir(&self.0).expect("current directory should be restorable");
    }
}
