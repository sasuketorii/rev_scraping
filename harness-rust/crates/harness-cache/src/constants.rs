//! Constants for the cache crate.
//!
//! Tool classifications and configuration file mappings used by the
//! verification and review caches.

/// Tools that operate on individual files.
pub const FILE_LEVEL_TOOLS: &[&str] = &[
    "clippy",
    "rustfmt",
    "eslint",
    "prettier",
    "ruff",
    "mypy",
    "shellcheck",
];

/// Tools that operate on the entire project.
pub const PROJECT_LEVEL_TOOLS: &[&str] = &["cargo-test", "cargo-check", "npm-test", "pytest"];

/// Mapping from tool name to its primary configuration file (relative to project root).
///
/// Used by [`crate::helpers::compute_config_hash`] to determine which file
/// to hash for cache invalidation.
pub const TOOL_CONFIG_MAP: &[(&str, &str)] = &[
    ("clippy", ".clippy.toml"),
    ("rustfmt", "rustfmt.toml"),
    ("eslint", ".eslintrc.json"),
    ("prettier", ".prettierrc"),
    ("ruff", "ruff.toml"),
    ("mypy", "mypy.ini"),
    ("shellcheck", ".shellcheckrc"),
    ("cargo-test", "Cargo.toml"),
    ("cargo-check", "Cargo.toml"),
    ("npm-test", "package.json"),
    ("pytest", "pyproject.toml"),
];
