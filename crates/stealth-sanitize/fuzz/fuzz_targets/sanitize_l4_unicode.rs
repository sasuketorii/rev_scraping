// SPDX-License-Identifier: MIT
// Lane K K.5 — L4 unicode-strip fuzz target.
//
// Feeds arbitrary UTF-8 bytes as a single JSON string leaf and runs the
// full sanitize pipeline. Because L4 is `pub(crate)`, we exercise it
// via the public `sanitize_for_agent` entry point with a payload whose
// string content is the fuzz input. The property under test: L4
// (NFKC + zero-width strip + tag-char strip + bidi-override strip)
// never panics and always produces valid UTF-8 in the output JSON.

#![no_main]

use libfuzzer_sys::fuzz_target;
use serde_json::json;
use stealth_sanitize::{sanitize_for_agent, Preset, SanitizePolicy};

fuzz_target!(|data: &[u8]| {
    // Treat input as a UTF-8 string with replacement on invalid sequences.
    let s = String::from_utf8_lossy(data).into_owned();
    let payload = json!({ "content": s });
    let policy = SanitizePolicy::preset(Preset::Strict);
    let env = sanitize_for_agent(payload, &policy);
    // Output must serialize back to valid JSON (proves UTF-8 well-formed).
    let _ = serde_json::to_vec(&env.payload).expect("envelope payload must serialize");
});
