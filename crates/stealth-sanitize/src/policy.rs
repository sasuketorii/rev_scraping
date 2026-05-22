//! Policy types: `Mode`, `Preset`, `SanitizePolicy` and sub-policies.

use serde::{Deserialize, Serialize};

/// Sanitizer execution mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Layers do not run; payload is returned unchanged with an empty
    /// `_meta.sanitize` report. Used in dev or when an explicit upstream
    /// guarantee says the content is trusted.
    Off,
    /// Layers run and emit canary hits to the report, but only Critical
    /// hits trigger fail-closed behavior. High/Suspicious are replaced or
    /// reported without aborting the response.
    Warn,
    /// Strictest mode. Critical canaries empty the payload and set
    /// `aborted = true`; High canaries are always replaced with safe
    /// placeholders.
    Enforce,
}

/// Built-in policy presets used by the per-tool wiring table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preset {
    /// Strict: `Mode::Enforce`, smallest budgets, every canary tier active.
    /// Default for `auth_login_*` and other high-risk tools.
    Strict,
    /// Balanced: `Mode::Warn`, standard budgets. Default for most tools in
    /// v1.2.0 (Warn-default is the synthesis decision).
    Balanced,
    /// Pass-through: `Mode::Off`. Reserved for trusted internal calls.
    PassThrough,
}

/// Byte budgets enforced by L5 (length clamp). Defaults are 256 KiB
/// per-field and 512 KiB total per the synthesis design.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LimitPolicy {
    pub per_field_max_bytes: usize,
    pub total_max_bytes: usize,
}

impl Default for LimitPolicy {
    fn default() -> Self {
        Self {
            per_field_max_bytes: 256 * 1024,
            total_max_bytes: 512 * 1024,
        }
    }
}

/// L3 canary configuration. P13.1 ships the toggles; the actual canary set
/// is wired in P13.3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CanaryPolicy {
    pub enable_critical: bool,
    pub enable_high: bool,
    pub enable_suspicious: bool,
    /// When true, Critical canary hits cause the response to be replaced
    /// with an empty payload and `aborted = true`. Forced on in
    /// `Mode::Enforce`; honored in `Mode::Warn`.
    pub critical_fail_closed: bool,
}

impl Default for CanaryPolicy {
    fn default() -> Self {
        Self {
            enable_critical: true,
            enable_high: true,
            enable_suspicious: true,
            critical_fail_closed: true,
        }
    }
}

/// L4 unicode strip configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnicodePolicy {
    /// Apply NFKC normalization before stripping.
    pub nfkc: bool,
    /// Strip zero-width characters: U+200B–U+200D, U+2060, U+FEFF.
    pub strip_zero_width: bool,
    /// Strip Unicode tag characters U+E0000–U+E007F.
    pub strip_tag_chars: bool,
    /// Strip bidi overrides U+202D/U+202E and isolates U+2066–U+2069
    /// (each occurrence increments a single canary hit).
    pub strip_bidi_overrides: bool,
}

impl Default for UnicodePolicy {
    fn default() -> Self {
        Self {
            nfkc: true,
            strip_zero_width: true,
            strip_tag_chars: true,
            strip_bidi_overrides: true,
        }
    }
}

/// Fully resolved policy passed into [`super::sanitize_for_agent`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SanitizePolicy {
    pub mode: Mode,
    pub limits: LimitPolicy,
    pub canary: CanaryPolicy,
    pub unicode: UnicodePolicy,
    /// Stable preset identifier used as `policy_name` in the report.
    /// `None` means a custom/ad-hoc policy.
    preset: Option<Preset>,
}

impl SanitizePolicy {
    /// Build a policy from a named preset. This is the canonical entry
    /// point — call sites should not construct a policy field-by-field
    /// unless they have a specific reason.
    pub fn preset(p: Preset) -> Self {
        match p {
            Preset::Strict => Self {
                mode: Mode::Enforce,
                limits: LimitPolicy {
                    per_field_max_bytes: 64 * 1024,
                    total_max_bytes: 128 * 1024,
                },
                canary: CanaryPolicy::default(),
                unicode: UnicodePolicy::default(),
                preset: Some(Preset::Strict),
            },
            Preset::Balanced => Self {
                mode: Mode::Warn,
                limits: LimitPolicy::default(),
                canary: CanaryPolicy::default(),
                unicode: UnicodePolicy::default(),
                preset: Some(Preset::Balanced),
            },
            Preset::PassThrough => Self {
                mode: Mode::Off,
                limits: LimitPolicy::default(),
                canary: CanaryPolicy {
                    enable_critical: false,
                    enable_high: false,
                    enable_suspicious: false,
                    critical_fail_closed: false,
                },
                unicode: UnicodePolicy {
                    nfkc: false,
                    strip_zero_width: false,
                    strip_tag_chars: false,
                    strip_bidi_overrides: false,
                },
                preset: Some(Preset::PassThrough),
            },
        }
    }

    /// Stable string identifier for the resolved preset, used as
    /// `policy_name` in the sanitize report.
    pub fn preset_name(&self) -> &'static str {
        match self.preset {
            Some(Preset::Strict) => "strict",
            Some(Preset::Balanced) => "balanced",
            Some(Preset::PassThrough) => "passthrough",
            None => "custom",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_preset_resolves_to_enforce_with_tight_budgets() {
        let p = SanitizePolicy::preset(Preset::Strict);
        assert_eq!(p.mode, Mode::Enforce);
        assert_eq!(p.limits.per_field_max_bytes, 64 * 1024);
        assert_eq!(p.limits.total_max_bytes, 128 * 1024);
        assert!(p.canary.critical_fail_closed);
        assert_eq!(p.preset_name(), "strict");
    }

    #[test]
    fn balanced_preset_resolves_to_warn_with_default_budgets() {
        let p = SanitizePolicy::preset(Preset::Balanced);
        assert_eq!(p.mode, Mode::Warn);
        assert_eq!(p.limits.per_field_max_bytes, 256 * 1024);
        assert_eq!(p.limits.total_max_bytes, 512 * 1024);
        assert_eq!(p.preset_name(), "balanced");
    }

    #[test]
    fn passthrough_disables_everything_including_canary() {
        let p = SanitizePolicy::preset(Preset::PassThrough);
        assert_eq!(p.mode, Mode::Off);
        assert!(!p.canary.enable_critical);
        assert!(!p.unicode.nfkc);
        assert_eq!(p.preset_name(), "passthrough");
    }
}
