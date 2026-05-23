// SPDX-License-Identifier: MIT
//! v1.3 Lane G fix-up R2 — Delta 2: idempotency invariant property tests.
//!
//! This file is the direct evidence target for the Codex R1 finding that
//! `idempotency_replay.rs` covers only a *representative* set of mutate
//! sub-commands (config init / config profile create / hermes uninstall)
//! and therefore proves the contract by enumeration, not by induction
//! over the input space.
//!
//! Properties asserted (with `PROPTEST_CASES = 50` by default):
//!
//!   1. **Replay invariance** — for any (op, key, payload), a write
//!      followed by a re-check returns the *same* envelope byte-for-byte.
//!      In wire terms: a second invocation with identical idempotency key
//!      + identical payload short-circuits to the cached envelope.
//!
//!   2. **Payload variance** — for any (op, key) and two *different*
//!      payloads `P1 != P2`, the second write does NOT collide with the
//!      first: `check(op, key, hash(P2))` returns `Record` (no replay)
//!      until `P2` is itself written. This is the failure mode Codex
//!      flagged: the cache must key on `(op, key_hash, payload_hash)`
//!      rather than just `(op, key)`.
//!
//!   3. **Key variance** — different idempotency keys with the same
//!      payload do not collide. Belt-and-suspenders against accidental
//!      `(op, payload_hash)`-only keying.
//!
//! Hermeticity: each proptest case uses its own `tempfile::TempDir`-backed
//! store, so the property loop cannot disturb the operator's real
//! `~/.rev_scraping/idempotency/` directory and parallel test execution is
//! safe.
//!
//! Runtime: the in-process store API is driven directly via the
//! `__idempotency_for_test` re-export, so each case is microseconds, not
//! the seconds a `cargo run` shell-out would take. PR loop stays cheap.

use std::time::Duration;

use proptest::prelude::*;
use serde_json::{json, Value};

use stealth_cli::__idempotency_for_test::{
    maybe_replay, payload_value, CheckResult, IdempotencyStore,
};

/// Build a fresh, isolated `IdempotencyStore` rooted at a `TempDir`. The
/// `TempDir` is leaked into the returned tuple so its `Drop` happens at
/// the end of the property case, not when this helper returns.
fn fresh_store() -> (IdempotencyStore, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    // 1h TTL is well above any plausible single-iteration wall time so
    // expiry never accidentally fires during a property case.
    let store = IdempotencyStore::new(dir.path().to_path_buf(), Duration::from_secs(3600));
    (store, dir)
}

/// Build a representative payload from a u64 seed. Using a richer JSON
/// shape (object with sub-command + args) mirrors the real mutate-command
/// shape produced by `payload_value` in `idempotency.rs`.
fn payload_from_seed(seed: u64) -> Value {
    payload_value(
        "test.op",
        vec![
            ("seed".to_string(), json!(seed)),
            ("nested".to_string(), json!({"a": seed % 7, "b": seed % 13})),
        ],
    )
}

proptest! {
    #![proptest_config(ProptestConfig {
        // 50 iterations matches the Lane G fix-up R2 ExecPlan budget.
        cases: 50,
        // Deterministic-by-default; CI can override via PROPTEST_CASES.
        ..ProptestConfig::default()
    })]

    /// Property 1: replay invariance.
    ///
    /// For arbitrary (op, key, payload-seed):
    ///   1. Build a representative envelope.
    ///   2. Write it under (op, key, payload).
    ///   3. `maybe_replay(op, key, payload)` MUST now return
    ///      `Some((payload_hash, envelope_clone))` where the envelope is
    ///      byte-for-byte equal to the one we wrote.
    #[test]
    fn same_key_same_payload_yields_same_envelope(
        op in "[a-z][a-z._]{2,19}",
        key in "[A-Za-z0-9_-]{1,32}",
        payload_seed in any::<u64>(),
    ) {
        let (store, _dir) = fresh_store();
        let payload = payload_from_seed(payload_seed);
        let payload_hash = IdempotencyStore::payload_hash(&payload);
        let envelope = json!({
            "ok": true,
            "operation": &op,
            "result": payload.clone(),
        });
        // First write — no prior entry, so the store must accept it.
        prop_assert!(matches!(
            store.check(&op, &key, &payload_hash),
            CheckResult::Record,
        ));
        store
            .write_envelope(&op, &key, &payload_hash, &envelope)
            .expect("write_envelope ok");

        // Re-check: must replay the *identical* envelope.
        let replay = maybe_replay(&store, &op, Some(&key), &payload);
        prop_assert!(replay.is_some(), "expected Replay, got Record");
        let (replay_hash, replay_env) = replay.unwrap();
        prop_assert_eq!(replay_hash, payload_hash);
        prop_assert_eq!(replay_env, envelope);
    }

    /// Property 2: payload variance does NOT collide.
    ///
    /// Same (op, key), but two distinct payloads P1 != P2:
    ///   * write P1 → cache contains entry for (op, key, hash(P1))
    ///   * check (op, key, hash(P2)) → MUST return `Record`, not `Replay`
    ///
    /// This protects against the gameable failure mode where the cache
    /// key is `(op, key)` only and a stale envelope would mask a
    /// legitimate second mutate with new arguments.
    #[test]
    fn different_payload_same_key_does_not_replay(
        op in "[a-z][a-z._]{2,19}",
        key in "[A-Za-z0-9_-]{1,32}",
        seed_a in any::<u64>(),
        seed_b in any::<u64>(),
    ) {
        prop_assume!(seed_a != seed_b);
        let (store, _dir) = fresh_store();
        let p1 = payload_from_seed(seed_a);
        let p2 = payload_from_seed(seed_b);
        prop_assume!(p1 != p2); // skip the (vanishingly rare) hash-collision draw
        let env1 = json!({
            "ok": true,
            "operation": &op,
            "result": p1.clone(),
        });
        let h1 = IdempotencyStore::payload_hash(&p1);
        store
            .write_envelope(&op, &key, &h1, &env1)
            .expect("write_envelope ok");

        // Second-payload check must MISS the cache.
        let replay = maybe_replay(&store, &op, Some(&key), &p2);
        prop_assert!(
            replay.is_none(),
            "different payload unexpectedly replayed: hash(p1)={h1} hash(p2)={h2}",
            h1 = h1,
            h2 = IdempotencyStore::payload_hash(&p2),
        );
    }

    /// Property 3: key variance does NOT collide.
    ///
    /// Same (op, payload), but two distinct keys K1 != K2:
    ///   * write under K1 → cache contains entry for (op, hash(K1), hash(payload))
    ///   * check under K2 → MUST return `Record`, not `Replay`.
    #[test]
    fn different_key_same_payload_does_not_replay(
        op in "[a-z][a-z._]{2,19}",
        key_a in "[A-Za-z0-9_-]{1,32}",
        key_b in "[A-Za-z0-9_-]{1,32}",
        payload_seed in any::<u64>(),
    ) {
        prop_assume!(key_a != key_b);
        let (store, _dir) = fresh_store();
        let payload = payload_from_seed(payload_seed);
        let payload_hash = IdempotencyStore::payload_hash(&payload);
        let envelope = json!({
            "ok": true,
            "operation": &op,
            "result": payload.clone(),
        });
        store
            .write_envelope(&op, &key_a, &payload_hash, &envelope)
            .expect("write_envelope ok");

        let replay = maybe_replay(&store, &op, Some(&key_b), &payload);
        prop_assert!(
            replay.is_none(),
            "different key unexpectedly replayed for same payload",
        );
    }
}
