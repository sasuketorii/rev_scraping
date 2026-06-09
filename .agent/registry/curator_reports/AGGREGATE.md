# Curator-Lite Aggregate (all 3 harnesses)

Generated: 2026-06-01T16:46:22.842391+00:00
Mode: dry-run (telemetry only; ZERO file moves) · stale_after_days=30 · archive_after_days=90

| harness | total | active | stale | archived-candidate | ineligible (missing_registry) |
|---|---|---|---|---|---|
| rev_harness | 34 | 34 | 0 | 0 | 0 |
| rev_marketing_harness | 52 | 52 | 0 | 0 | 0 |
| rev_textsocialharness | 37 | 37 | 0 | 0 | 0 |
| **TOTAL** | 123 | 123 | 0 | 0 | 0 |

## Provenance gate

Skills without a `cross_harness_projection_registry.json` entry (matched by source harness / `present_in` provenance, i.e. the `created_by` authority) are flagged `ineligible_for_action: missing_registry` and are never promoted to archived-candidate.

## Phase boundary

- Phase 1 = telemetry + dry-run lifecycle judgement only. No file was moved, archived, or deleted.
- `--apply` (auto-archive to `.archive/`) is deferred to Phase 2 / S-7.
