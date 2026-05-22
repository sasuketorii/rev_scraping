// SPDX-License-Identifier: MIT
//
// Lane K K.4 — property-based invariants for stealth-auth envelope crypto.
//
// Covers the three invariants every caller is allowed to rely on:
//   1. encrypt → decrypt roundtrip restores plaintext exactly, for ANY
//      profile string, AAD-context string, key, and plaintext bytes.
//   2. AAD mismatch (different aad_context) MUST fail decrypt — never
//      panic, never return arbitrary plaintext.
//   3. Profile-hash mismatch (different profile binding) MUST fail
//      decrypt at the envelope-decode stage, before AEAD even runs.
//
// PR runs default to 256 cases per property.

use proptest::prelude::*;
use stealth_auth::crypto::{decrypt, encrypt};

fn arb_key() -> impl Strategy<Value = [u8; 32]> {
    any::<[u8; 32]>()
}

fn arb_profile() -> impl Strategy<Value = String> {
    // Profiles are user-controlled identifiers; cover ASCII + a few Unicode.
    prop_oneof![
        Just("default".to_string()),
        "[a-z0-9_-]{1,16}".prop_map(|s| s),
        ".{1,16}".prop_map(|s| s),
    ]
}

fn arb_aad_ctx() -> impl Strategy<Value = String> {
    // Empty is the documented "no extra context" path; otherwise free-form.
    prop_oneof![Just(String::new()), ".{1,32}".prop_map(|s| s)]
}

fn arb_plaintext() -> impl Strategy<Value = Vec<u8>> {
    // 0..=2 KiB covers the empty-jar edge plus realistic cookie blob sizes.
    prop::collection::vec(any::<u8>(), 0..2048)
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 256,
        failure_persistence: None,
        .. ProptestConfig::default()
    })]

    /// encrypt → decrypt roundtrip MUST restore plaintext byte-for-byte
    /// for every combination of (profile, aad_context, key, plaintext).
    #[test]
    fn envelope_roundtrip(
        profile in arb_profile(),
        ctx in arb_aad_ctx(),
        key in arb_key(),
        pt in arb_plaintext(),
    ) {
        let encoded = encrypt(&profile, &ctx, &key, &pt)
            .expect("encrypt must succeed for arbitrary inputs");
        let recovered = decrypt(&profile, &ctx, &key, &encoded)
            .expect("decrypt with matching params must recover plaintext");
        prop_assert_eq!(recovered.as_slice(), pt.as_slice());
    }

    /// AAD mismatch MUST cause decrypt to fail (cleanly, never panic).
    /// We only run this branch when the two aad_context strings differ;
    /// when they happen to coincide the property is vacuous.
    #[test]
    fn aad_mismatch_rejected(
        profile in arb_profile(),
        ctx_a in arb_aad_ctx(),
        ctx_b in arb_aad_ctx(),
        key in arb_key(),
        pt in arb_plaintext(),
    ) {
        prop_assume!(ctx_a != ctx_b);
        let encoded = encrypt(&profile, &ctx_a, &key, &pt).expect("encrypt ok");
        let result = decrypt(&profile, &ctx_b, &key, &encoded);
        prop_assert!(
            result.is_err(),
            "decrypt with mismatched AAD context must fail"
        );
    }

    /// profile-hash mismatch MUST cause decrypt to fail at the envelope
    /// decode stage. (When the two profile strings happen to be equal,
    /// the property is vacuous and skipped.)
    #[test]
    fn profile_hash_mismatch_rejected(
        profile_a in arb_profile(),
        profile_b in arb_profile(),
        ctx in arb_aad_ctx(),
        key in arb_key(),
        pt in arb_plaintext(),
    ) {
        prop_assume!(profile_a != profile_b);
        let encoded = encrypt(&profile_a, &ctx, &key, &pt).expect("encrypt ok");
        let result = decrypt(&profile_b, &ctx, &key, &encoded);
        prop_assert!(
            result.is_err(),
            "decrypt under different profile must fail (profile_hash bind)"
        );
    }
}
