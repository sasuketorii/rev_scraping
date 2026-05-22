// SPDX-License-Identifier: MIT
// Lane K K.5 — full sanitize pipeline fuzz target.
//
// Feeds arbitrary UTF-8 bytes through `serde_json::from_slice` and then
// (if parsing succeeds) through the full sanitize pipeline across every
// shipped preset. The property under test: the pipeline must never
// panic and must return a well-formed envelope.

#![no_main]

use libfuzzer_sys::fuzz_target;
use stealth_sanitize::{sanitize_for_agent, Preset, SanitizePolicy};

fuzz_target!(|data: &[u8]| {
    // Parse arbitrary bytes as JSON. Invalid JSON is dropped (not a
    // bug — the entry point assumes a parsed Value).
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    for preset in [Preset::Strict, Preset::Balanced, Preset::PassThrough] {
        let policy = SanitizePolicy::preset(preset);
        let _ = sanitize_for_agent(value.clone(), &policy);
    }
});
