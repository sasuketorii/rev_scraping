// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! Extended CLI exit codes (plan §3.5 / §5).
//!
//! Codes 0–3 reuse `stealth_core::ExitCode`. Codes 7–10 are CLI-local and
//! returned as raw `i32` via the wrapper [`Phase2Exit::as_i32`].

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // Transient/Permanent/Leak reserved for future call sites.
pub enum Phase2Exit {
    Ok = 0,
    UserError = 1,
    Transient = 2,
    Permanent = 3,
    Leak = 7,
    CfUnsolved = 8,
    RelocateMiss = 9,
    RelocateAmbiguous = 10,
    // Phase 8d diverges from the design draft, which suggested reusing 8
    // for "all proxy tiers failed"; 8 already means CfUnsolved here.
    ProxyExhausted = 11,
}

impl Phase2Exit {
    pub fn as_i32(self) -> i32 {
        self as i32
    }
}

/// Map a spider/relocate outcome to the canonical exit code.
pub fn map_spider_exit(
    cf_blocked: bool,
    relocate_miss: bool,
    relocate_ambiguous: bool,
    strict: bool,
) -> Phase2Exit {
    if cf_blocked {
        return Phase2Exit::CfUnsolved;
    }
    if relocate_ambiguous {
        // Strict mode promotes Ambiguous to a distinct hard failure (10);
        // otherwise Ambiguous is still treated as a data-quality miss (9).
        return if strict {
            Phase2Exit::RelocateAmbiguous
        } else {
            Phase2Exit::RelocateMiss
        };
    }
    if relocate_miss {
        return Phase2Exit::RelocateMiss;
    }
    Phase2Exit::Ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spider_exit_code_mapping() {
        assert_eq!(map_spider_exit(false, false, false, false), Phase2Exit::Ok);
        assert_eq!(
            map_spider_exit(true, false, false, false),
            Phase2Exit::CfUnsolved
        );
        // NotFound always exits 9, regardless of strict.
        assert_eq!(
            map_spider_exit(false, true, false, false),
            Phase2Exit::RelocateMiss
        );
        assert_eq!(
            map_spider_exit(false, true, false, true),
            Phase2Exit::RelocateMiss
        );
        // Ambiguous WITHOUT --strict => exit 9 (relocate_miss, data-quality risk).
        assert_eq!(
            map_spider_exit(false, false, true, false),
            Phase2Exit::RelocateMiss
        );
        // Ambiguous WITH --strict => exit 10 (relocate_ambiguous).
        assert_eq!(
            map_spider_exit(false, false, true, true),
            Phase2Exit::RelocateAmbiguous
        );
        // CF blocked takes precedence over relocate signals.
        assert_eq!(
            map_spider_exit(true, true, true, true),
            Phase2Exit::CfUnsolved
        );
    }

    #[test]
    fn test_ambiguous_non_strict_maps_to_miss() {
        // Explicit: Ambiguous in default (non-strict) mode must suppress as code 9.
        let exit = map_spider_exit(false, false, true, false);
        assert_eq!(exit, Phase2Exit::RelocateMiss);
        assert_eq!(exit.as_i32(), 9);
    }

    #[test]
    fn test_ambiguous_strict_maps_to_ambiguous() {
        let exit = map_spider_exit(false, false, true, true);
        assert_eq!(exit, Phase2Exit::RelocateAmbiguous);
        assert_eq!(exit.as_i32(), 10);
    }

    #[test]
    fn test_notfound_independent_of_strict() {
        assert_eq!(map_spider_exit(false, true, false, false).as_i32(), 9);
        assert_eq!(map_spider_exit(false, true, false, true).as_i32(), 9);
    }

    #[test]
    fn test_ambiguous_and_miss_combined() {
        // Both signals set: non-strict still 9, strict promotes to 10.
        assert_eq!(
            map_spider_exit(false, true, true, false),
            Phase2Exit::RelocateMiss
        );
        assert_eq!(
            map_spider_exit(false, true, true, true),
            Phase2Exit::RelocateAmbiguous
        );
    }

    #[test]
    fn test_exit_code_values() {
        assert_eq!(Phase2Exit::Ok.as_i32(), 0);
        assert_eq!(Phase2Exit::UserError.as_i32(), 1);
        assert_eq!(Phase2Exit::Leak.as_i32(), 7);
        assert_eq!(Phase2Exit::CfUnsolved.as_i32(), 8);
        assert_eq!(Phase2Exit::RelocateMiss.as_i32(), 9);
        assert_eq!(Phase2Exit::RelocateAmbiguous.as_i32(), 10);
        assert_eq!(Phase2Exit::ProxyExhausted.as_i32(), 11);
    }
}
