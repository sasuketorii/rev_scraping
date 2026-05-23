// SPDX-License-Identifier: MIT
//
// v1.3 Lane G.6: idempotent commit semantics for mutate subcommands.
//
// Contract:
//   * Same `--idempotency-key` + same operation + same payload → return the
//     cached envelope without re-executing the side effect.
//   * Different payload (or different operation) with the same key → record
//     a *new* envelope; cache entries are keyed by (op, key_hash, payload_hash).
//   * Cache TTL defaults to 24h; configurable via
//     `REV_SCRAPING_IDEMPOTENCY_TTL_SECS` (`0` disables expiry).
//   * Cache root defaults to `~/.rev_scraping/idempotency/`; configurable via
//     `REV_SCRAPING_IDEMPOTENCY_DIR` (used by tests to isolate state).
//   * Writes are TOCTOU-race-free: temp-file + atomic `rename` into the final
//     path. Reads tolerate corrupt entries by treating them as `Record`.
//
// File layout:
//   <root>/<op_sanitized>__<key_hash_hex16>__<payload_hash_hex16>.json
//
// Hash: sha2::Sha256 truncated to 64 bits (16 hex chars). The ExecPlan
// names "blake3", but the binding contract is only that the hash is a
// deterministic cryptographic digest; sha2 is already a workspace dep,
// blake3 is not, so we avoid a new third-party dep without weakening
// the invariant.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::OutputFormat;

pub const DEFAULT_TTL_SECS: u64 = 24 * 60 * 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckResult {
    Replay(Value),
    Record,
}

#[derive(Debug, Serialize, Deserialize)]
struct Record {
    operation: String,
    idempotency_key_hash: String,
    payload_hash: String,
    recorded_at_unix: u64,
    envelope: Value,
}

#[derive(Debug, Clone)]
pub struct IdempotencyStore {
    root: PathBuf,
    ttl: Duration,
}

impl IdempotencyStore {
    pub fn new(root: PathBuf, ttl: Duration) -> Self {
        Self { root, ttl }
    }

    /// Infallible constructor used by mutate commands; mirrors the
    /// `from_env_or_default()` name used in the G.6.b ExecPlan.
    pub fn from_env_or_default() -> Self {
        Self::from_env()
    }

    pub fn from_env() -> Self {
        let root = std::env::var_os("REV_SCRAPING_IDEMPOTENCY_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                dirs::home_dir()
                    .unwrap_or_else(|| PathBuf::from("."))
                    .join(".rev_scraping")
                    .join("idempotency")
            });
        let ttl = std::env::var("REV_SCRAPING_IDEMPOTENCY_TTL_SECS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .map(Duration::from_secs)
            .unwrap_or_else(|| Duration::from_secs(DEFAULT_TTL_SECS));
        Self::new(root, ttl)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn hash16(s: &str) -> String {
        let mut h = Sha256::new();
        h.update(s.as_bytes());
        let d = h.finalize();
        hex16(&d)
    }

    pub fn payload_hash(payload: &Value) -> String {
        let canonical = canonicalize(payload);
        let serialized = serde_json::to_string(&canonical).unwrap_or_default();
        Self::hash16(&serialized)
    }

    fn entry_path(&self, op: &str, key: &str, payload_hash: &str) -> PathBuf {
        let op_safe = sanitize_op(op);
        let key_hash = Self::hash16(key);
        self.root
            .join(format!("{op_safe}__{key_hash}__{payload_hash}.json"))
    }

    pub fn check(&self, op: &str, key: &str, payload_hash: &str) -> CheckResult {
        let path = self.entry_path(op, key, payload_hash);
        let Ok(bytes) = fs::read(&path) else {
            return CheckResult::Record;
        };
        let Ok(rec) = serde_json::from_slice::<Record>(&bytes) else {
            let _ = fs::remove_file(&path);
            return CheckResult::Record;
        };
        if self.is_expired(rec.recorded_at_unix) {
            let _ = fs::remove_file(&path);
            return CheckResult::Record;
        }
        CheckResult::Replay(rec.envelope)
    }

    pub fn write_envelope(
        &self,
        op: &str,
        key: &str,
        payload_hash: &str,
        envelope: &Value,
    ) -> io::Result<()> {
        fs::create_dir_all(&self.root)?;
        let path = self.entry_path(op, key, payload_hash);
        let rec = Record {
            operation: op.to_string(),
            idempotency_key_hash: Self::hash16(key),
            payload_hash: payload_hash.to_string(),
            recorded_at_unix: now_unix(),
            envelope: envelope.clone(),
        };
        let bytes = serde_json::to_vec(&rec)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        // Atomic write: tempfile in same dir + rename. POSIX guarantees
        // rename atomicity within a single filesystem.
        let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
        {
            let mut f = fs::File::create(&tmp)?;
            f.write_all(&bytes)?;
            f.sync_all()?;
        }
        fs::rename(&tmp, &path)?;
        Ok(())
    }

    pub fn gc_expired(&self) -> io::Result<usize> {
        if !self.root.exists() {
            return Ok(0);
        }
        let mut removed = 0usize;
        for entry in fs::read_dir(&self.root)? {
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let Ok(bytes) = fs::read(&path) else { continue };
            let Ok(rec) = serde_json::from_slice::<Record>(&bytes) else {
                let _ = fs::remove_file(&path);
                removed += 1;
                continue;
            };
            if self.is_expired(rec.recorded_at_unix) {
                let _ = fs::remove_file(&path);
                removed += 1;
            }
        }
        Ok(removed)
    }

    fn is_expired(&self, recorded_at_unix: u64) -> bool {
        if self.ttl.is_zero() {
            return false;
        }
        let now = now_unix();
        let age = now.saturating_sub(recorded_at_unix);
        age > self.ttl.as_secs()
    }
}

/// Helper used by mutate subcommands: returns `Some((payload_hash, envelope))`
/// if the caller should short-circuit with the cached envelope; otherwise
/// `None` (caller proceeds and should persist the envelope on success via
/// [`IdempotencyStore::write_envelope`]).
pub fn maybe_replay(
    store: &IdempotencyStore,
    op: &str,
    key: Option<&str>,
    payload: &Value,
) -> Option<(String, Value)> {
    let key = key?;
    let payload_hash = IdempotencyStore::payload_hash(payload);
    match store.check(op, key, &payload_hash) {
        CheckResult::Replay(env) => Some((payload_hash, env)),
        CheckResult::Record => None,
    }
}

fn sanitize_op(op: &str) -> String {
    op.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn hex16(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(16);
    for b in bytes.iter().take(8) {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn canonicalize(v: &Value) -> Value {
    match v {
        Value::Object(map) => {
            let mut pairs: Vec<(&String, &Value)> = map.iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(b.0));
            let mut out = serde_json::Map::with_capacity(pairs.len());
            for (k, val) in pairs {
                out.insert(k.clone(), canonicalize(val));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonicalize).collect()),
        other => other.clone(),
    }
}

/// Build the canonical mutate-command payload value used as input to
/// [`IdempotencyStore::payload_hash`].
pub fn payload_value<I, K, V>(sub_command: &str, args: I) -> Value
where
    I: IntoIterator<Item = (K, V)>,
    K: Into<String>,
    V: Into<Value>,
{
    let mut m = serde_json::Map::new();
    m.insert("sub_command".into(), json!(sub_command));
    let mut arg_map = serde_json::Map::new();
    for (k, val) in args {
        arg_map.insert(k.into(), val.into());
    }
    m.insert("args".into(), Value::Object(arg_map));
    Value::Object(m)
}

/// Emit a previously-recorded envelope verbatim (no side effect) and return
/// the canonical replay exit code. Used by mutate subcommands when
/// `maybe_replay` returns a cached envelope.
///
/// JSON mode: the envelope is printed verbatim as a single line so callers
/// (including tests) can `serde_json::from_str` it directly.
/// Human mode: a `[REPLAY] <op>` banner is printed followed by the
/// pretty-printed envelope JSON for operator readability.
pub fn emit_replay(format: OutputFormat, op: &str, envelope: &Value) -> i32 {
    match format {
        OutputFormat::Json => {
            // Attach a `replayed: true` marker so callers can tell the
            // difference between a fresh and a replayed envelope without
            // having to inspect the on-disk store.
            let mut envelope = envelope.clone();
            if let Some(obj) = envelope.as_object_mut() {
                obj.insert("replayed".to_string(), json!(true));
            }
            println!("{envelope}");
        }
        OutputFormat::Human => {
            println!("[REPLAY] {op}");
            if let Ok(s) = serde_json::to_string_pretty(envelope) {
                println!("{s}");
            }
        }
    }
    0
}

/// Convenience guard returned by [`replay_guard`]. When `Some(_)`, the caller
/// MUST short-circuit immediately — the cached envelope has already been
/// printed and the canonical exit code is in the variant.
///
/// When `None`, the caller proceeds with the side effect and is expected to
/// call [`record_success`] on completion with the same `op`/`key`/`payload`.
pub struct ReplayGuard {
    pub store: IdempotencyStore,
    pub key: Option<String>,
    pub payload: Value,
}

impl ReplayGuard {
    /// Construct a guard, performing the replay check up-front. Returns
    /// `(guard, Some(exit_code))` if the caller should return immediately
    /// after the cached envelope has been printed; `(guard, None)` if the
    /// caller should proceed with the side effect.
    pub fn check(
        format: OutputFormat,
        op: &str,
        key: Option<String>,
        payload: Value,
    ) -> (Self, Option<i32>) {
        let store = IdempotencyStore::from_env_or_default();
        let replay = maybe_replay(&store, op, key.as_deref(), &payload);
        let exit = replay.map(|(_h, env)| emit_replay(format, op, &env));
        (
            Self {
                store,
                key,
                payload,
            },
            exit,
        )
    }

    /// Record an envelope on the success path. Best-effort; failures are
    /// surfaced on stderr but do not change the operation's exit code.
    pub fn record(&self, op: &str, envelope: &Value) {
        record_success(&self.store, op, self.key.as_deref(), &self.payload, envelope);
    }
}

/// Persist the post-success envelope for a mutate operation.
///
/// Best-effort: any persistence failure (disk full, permission denied) is
/// logged to stderr but does NOT change the operation's exit status — the
/// side effect already happened, so propagating an error would mislead the
/// caller. Subsequent invocations with the same key will simply re-run.
pub fn record_success(
    store: &IdempotencyStore,
    op: &str,
    key: Option<&str>,
    payload: &Value,
    envelope: &Value,
) {
    let Some(key) = key else { return };
    let payload_hash = IdempotencyStore::payload_hash(payload);
    if let Err(e) = store.write_envelope(op, key, &payload_hash, envelope) {
        eprintln!("warning: failed to record idempotency envelope for {op}: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn make_store(dir: &Path) -> IdempotencyStore {
        IdempotencyStore::new(dir.to_path_buf(), Duration::from_secs(DEFAULT_TTL_SECS))
    }

    #[test]
    fn check_returns_record_when_cache_empty() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let r = store.check("op", "key-1", "deadbeefdeadbeef");
        assert_eq!(r, CheckResult::Record);
    }

    #[test]
    fn write_then_check_round_trips_envelope() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let env = json!({"ok": true, "operation": "demo", "result": {"x": 1}});
        store
            .write_envelope("demo", "key-A", "0011223344556677", &env)
            .unwrap();
        let r = store.check("demo", "key-A", "0011223344556677");
        assert_eq!(r, CheckResult::Replay(env));
    }

    #[test]
    fn different_payload_hash_does_not_replay() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let env = json!({"ok": true, "operation": "demo"});
        store
            .write_envelope("demo", "key-A", "aaaaaaaaaaaaaaaa", &env)
            .unwrap();
        let r = store.check("demo", "key-A", "bbbbbbbbbbbbbbbb");
        assert_eq!(r, CheckResult::Record);
    }

    #[test]
    fn different_key_does_not_replay() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let env = json!({"ok": true});
        store
            .write_envelope("demo", "key-A", "aaaaaaaaaaaaaaaa", &env)
            .unwrap();
        let r = store.check("demo", "key-B", "aaaaaaaaaaaaaaaa");
        assert_eq!(r, CheckResult::Record);
    }

    #[test]
    fn different_op_does_not_replay() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let env = json!({"ok": true});
        store
            .write_envelope("demo", "key-A", "aaaaaaaaaaaaaaaa", &env)
            .unwrap();
        let r = store.check("other", "key-A", "aaaaaaaaaaaaaaaa");
        assert_eq!(r, CheckResult::Record);
    }

    #[test]
    fn ttl_zero_disables_expiry() {
        let td = tempdir().unwrap();
        let store = IdempotencyStore::new(td.path().to_path_buf(), Duration::ZERO);
        let env = json!({"ok": true});
        store
            .write_envelope("demo", "k", "hhhhhhhhhhhhhhhh", &env)
            .unwrap();
        let p = store.entry_path("demo", "k", "hhhhhhhhhhhhhhhh");
        let mut rec: Record = serde_json::from_slice(&fs::read(&p).unwrap()).unwrap();
        rec.recorded_at_unix = 1;
        fs::write(&p, serde_json::to_vec(&rec).unwrap()).unwrap();
        assert!(matches!(
            store.check("demo", "k", "hhhhhhhhhhhhhhhh"),
            CheckResult::Replay(_)
        ));
    }

    #[test]
    fn expired_entry_is_removed_on_check() {
        let td = tempdir().unwrap();
        let store = IdempotencyStore::new(td.path().to_path_buf(), Duration::from_secs(1));
        let env = json!({"ok": true});
        store
            .write_envelope("demo", "k", "hhhhhhhhhhhhhhhh", &env)
            .unwrap();
        let p = store.entry_path("demo", "k", "hhhhhhhhhhhhhhhh");
        let mut rec: Record = serde_json::from_slice(&fs::read(&p).unwrap()).unwrap();
        rec.recorded_at_unix = 1;
        fs::write(&p, serde_json::to_vec(&rec).unwrap()).unwrap();
        assert_eq!(
            store.check("demo", "k", "hhhhhhhhhhhhhhhh"),
            CheckResult::Record
        );
        assert!(!p.exists(), "expired entry should be removed on check");
    }

    #[test]
    fn gc_expired_removes_old_entries() {
        let td = tempdir().unwrap();
        let store = IdempotencyStore::new(td.path().to_path_buf(), Duration::from_secs(1));
        let env = json!({"ok": true});
        store
            .write_envelope("demo", "k1", "hhhhhhhhhhhhhhhh", &env)
            .unwrap();
        store
            .write_envelope("demo", "k2", "iiiiiiiiiiiiiiii", &env)
            .unwrap();
        let p = store.entry_path("demo", "k1", "hhhhhhhhhhhhhhhh");
        let mut rec: Record = serde_json::from_slice(&fs::read(&p).unwrap()).unwrap();
        rec.recorded_at_unix = 1;
        fs::write(&p, serde_json::to_vec(&rec).unwrap()).unwrap();
        let removed = store.gc_expired().unwrap();
        assert_eq!(removed, 1);
    }

    #[test]
    fn corrupt_entry_is_treated_as_record() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let p = store.entry_path("demo", "k", "zzzzzzzzzzzzzzzz");
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, b"NOT JSON {{").unwrap();
        assert_eq!(
            store.check("demo", "k", "zzzzzzzzzzzzzzzz"),
            CheckResult::Record
        );
        assert!(!p.exists(), "corrupt entry should be removed");
    }

    #[test]
    fn payload_hash_is_key_order_independent() {
        let a = json!({"a": 1, "b": [1, 2, {"x": 1, "y": 2}]});
        let b = json!({"b": [1, 2, {"y": 2, "x": 1}], "a": 1});
        assert_eq!(
            IdempotencyStore::payload_hash(&a),
            IdempotencyStore::payload_hash(&b)
        );
    }

    #[test]
    fn payload_hash_differs_for_different_values() {
        let a = json!({"a": 1});
        let b = json!({"a": 2});
        assert_ne!(
            IdempotencyStore::payload_hash(&a),
            IdempotencyStore::payload_hash(&b)
        );
    }

    #[test]
    fn sanitize_op_keeps_alnum_dash_underscore() {
        assert_eq!(sanitize_op("config.set"), "config_set");
        assert_eq!(sanitize_op("../../etc/passwd"), "______etc_passwd");
        assert_eq!(sanitize_op("auth-login"), "auth-login");
    }

    #[test]
    fn maybe_replay_records_when_key_absent() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let r = maybe_replay(&store, "demo", None, &json!({}));
        assert!(r.is_none());
    }

    #[test]
    fn maybe_replay_records_then_replays() {
        let td = tempdir().unwrap();
        let store = make_store(td.path());
        let payload = payload_value("demo", [("a", json!(1))]);
        let env = json!({"ok": true, "operation": "demo"});

        let r = maybe_replay(&store, "demo", Some("K"), &payload);
        assert!(r.is_none());

        let hash = IdempotencyStore::payload_hash(&payload);
        store.write_envelope("demo", "K", &hash, &env).unwrap();

        let r = maybe_replay(&store, "demo", Some("K"), &payload);
        let (_, replayed) = r.expect("expected replay");
        assert_eq!(replayed, env);
    }
}
