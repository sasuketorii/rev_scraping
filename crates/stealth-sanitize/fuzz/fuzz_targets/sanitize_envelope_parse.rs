// SPDX-License-Identifier: MIT
// Lane K K.5 — layer-2 envelope parse fuzz target.
//
// Covers the path the spec calls `sanitize::layer2_envelope::parse`: feed
// arbitrary bytes through `serde_json::from_slice` (the entry to the L2
// envelope handling) and then `sanitize_for_agent` so the L2 forgery
// neutralization (`apply_l2` / `neutralize_forgery`) is exercised. The
// property under test: parse + L2 normalize must never panic, must
// never produce a non-UTF-8 string, and must terminate on adversarial
// envelope-marker inputs.

#![no_main]

use libfuzzer_sys::fuzz_target;
use stealth_sanitize::{sanitize_for_agent, Preset, SanitizePolicy};

fuzz_target!(|data: &[u8]| {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    // Use Balanced (not Strict) so an L3 critical hit cannot short-circuit
    // before L2 runs. Balanced still executes the L2 envelope normalize
    // / forgery neutralization on every iteration.
    let policy = SanitizePolicy::preset(Preset::Balanced);
    let env = sanitize_for_agent(value.clone(), &policy);
    // Returned report MUST serialize back to JSON; treat failure as a
    // fuzz finding (panic surfaces it to libfuzzer).
    serde_json::to_vec(&env.report).expect("report must serialize");
});
