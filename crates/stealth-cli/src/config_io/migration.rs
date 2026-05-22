// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P9.1 — config-schema migration framework)
//
//! Pluggable schema-migration framework for the `policy.toml` /
//! `authorized.toml` config layers.
//!
//! Each registered [`Migration`] knows how to convert a single TOML
//! document from `from_version` to `to_version`. The framework chains
//! migrations sequentially so a v1 document can hop through v2, v3, ...
//! to reach the latest known schema.
//!
//! P9.1 ships with exactly one registered migration: the v1 → v1 no-op
//! that pins the contract surface. A v2-shaped migration is provided as
//! an example via the public [`Migration`] struct constructor; once a
//! genuine v2 schema lands we register it via `default_migrations()` and
//! delete the no-op stub.

use toml::Value as TomlValue;

/// Latest known schema version. Bumped in lock-step with the
/// `validate.rs` LATEST_SCHEMA_VERSION constant — see the assertion in
/// the test module for the cross-pin.
pub const LATEST_SCHEMA_VERSION: u32 = 1;

/// A single schema migration step. `apply` MUST be pure: deterministic,
/// no env reads, no IO. Errors are surfaced as a `String` so the caller
/// can route them onto an operator-facing JSON envelope.
#[derive(Clone)]
pub struct Migration {
    pub from_version: u32,
    pub to_version: u32,
    pub apply: fn(TomlValue) -> Result<TomlValue, String>,
}

impl std::fmt::Debug for Migration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Migration")
            .field("from_version", &self.from_version)
            .field("to_version", &self.to_version)
            .finish()
    }
}

/// Outcome of running the migration chain over a document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationOutcome {
    /// Document already at the latest version; no rewrite needed.
    NoOp { version: u32 },
    /// Document was rewritten across at least one Migration.
    Migrated { from: u32, to: u32, steps: u32 },
}

/// Default migrations registered for the current build. P9.1 ships a
/// single v1→v1 no-op step so the harness exercises the chain loop even
/// before a real v2 migration lands.
pub fn default_migrations() -> Vec<Migration> {
    vec![Migration {
        from_version: 1,
        to_version: 1,
        // Identity transform: returns the document unchanged.
        apply: |doc| Ok(doc),
    }]
}

/// Apply registered migrations until `doc`'s `schema_version` reaches
/// `target` or we run out of registered steps. Returns an Err with a
/// human-readable message if:
///   * `schema_version` is missing / non-integer / out of u32 range
///   * a migration step is registered with overlapping/missing
///     `from_version` such that the chain stalls
///   * an `apply` callback fails
pub fn migrate_to(
    mut doc: TomlValue,
    target: u32,
    migrations: &[Migration],
) -> Result<(TomlValue, MigrationOutcome), String> {
    let current = read_schema_version(&doc)?;
    if current == target {
        return Ok((doc, MigrationOutcome::NoOp { version: current }));
    }
    let from = current;
    let mut steps = 0u32;
    let mut version = current;
    // Bound the loop to the number of registered migrations + 1 so a
    // misconfigured registry can never cause infinite progress.
    let max_steps = migrations.len() as u32 + 1;
    while version != target {
        let step = migrations
            .iter()
            .find(|m| m.from_version == version)
            .ok_or_else(|| format!("no migration registered for v{version} → v{target}"))?;
        doc = (step.apply)(doc)?;
        version = step.to_version;
        steps += 1;
        if steps > max_steps {
            return Err(format!(
                "migration chain exceeded {max_steps} steps (loop suspected)"
            ));
        }
    }
    Ok((
        doc,
        MigrationOutcome::Migrated {
            from,
            to: version,
            steps,
        },
    ))
}

fn read_schema_version(doc: &TomlValue) -> Result<u32, String> {
    let raw = doc
        .get("schema_version")
        .ok_or_else(|| "schema_version field missing".to_string())?;
    let n = raw
        .as_integer()
        .ok_or_else(|| "schema_version is not an integer".to_string())?;
    u32::try_from(n).map_err(|_| format!("schema_version {n} out of u32 range"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc_v(v: i64) -> TomlValue {
        let s = format!("schema_version = {v}\n");
        toml::from_str::<TomlValue>(&s).unwrap()
    }

    #[test]
    fn migration_v1_v1_noop() {
        // The shipped no-op step. Pin: latest version reached, zero
        // structural changes, MigrationOutcome::NoOp returned.
        let migs = default_migrations();
        let (out, outcome) =
            migrate_to(doc_v(1), LATEST_SCHEMA_VERSION, &migs).expect("noop must succeed");
        assert_eq!(outcome, MigrationOutcome::NoOp { version: 1 });
        // Document unchanged — schema_version still 1.
        assert_eq!(
            out.get("schema_version").and_then(|v| v.as_integer()),
            Some(1)
        );
    }

    #[test]
    fn migration_harness_supports_future_v2() {
        // The contract surface for a future v2: register a Migration with
        // from=1, to=2, that bumps schema_version. The harness chains it
        // and reports Migrated{from:1, to:2, steps:1}.
        let migs = vec![Migration {
            from_version: 1,
            to_version: 2,
            apply: |mut doc| {
                if let Some(table) = doc.as_table_mut() {
                    table.insert("schema_version".into(), TomlValue::Integer(2));
                }
                Ok(doc)
            },
        }];
        let (out, outcome) = migrate_to(doc_v(1), 2, &migs).expect("v1→v2 must succeed");
        assert_eq!(
            outcome,
            MigrationOutcome::Migrated {
                from: 1,
                to: 2,
                steps: 1
            }
        );
        assert_eq!(
            out.get("schema_version").and_then(|v| v.as_integer()),
            Some(2)
        );
    }

    #[test]
    fn migrate_missing_step_errors() {
        // No registered migration for v1 → v2 must produce a stable
        // operator-facing error string, not panic or loop.
        let migs: Vec<Migration> = vec![];
        let err = migrate_to(doc_v(1), 2, &migs).unwrap_err();
        assert!(err.contains("no migration registered"), "got: {err}");
    }

    #[test]
    fn migrate_rejects_missing_schema_version() {
        let doc: TomlValue = toml::from_str("[other]\nx = 1\n").unwrap();
        let err = migrate_to(doc, 1, &default_migrations()).unwrap_err();
        assert!(err.contains("schema_version field missing"), "got: {err}");
    }

    #[test]
    fn latest_version_matches_schema_default() {
        // Cross-pin: this module's LATEST_SCHEMA_VERSION MUST track the
        // schema layer's default v1 constant. Today both are 1; when a
        // v2 schema lands we bump both in lock-step.
        assert_eq!(
            crate::config_io::schema::default_schema_version_v1(),
            LATEST_SCHEMA_VERSION,
            "migration::LATEST_SCHEMA_VERSION must equal schema::default_schema_version_v1()"
        );
    }
}
