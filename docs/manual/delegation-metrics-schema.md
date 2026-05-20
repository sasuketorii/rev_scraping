# Delegation Metrics Schema (v1)

## Overview

Every invocation of `scripts/codex-wrapper.sh` that reaches production execution or `--dry-run` validation emits exactly one JSONL line on stderr of the form:

```text
REV_HARNESS_DELEGATION_METRIC {"schema_version":1,...}
```

This enables session-level Layer A measurement: token spend, duration, and drift count per the completion-criteria framework (`.claude/tmp/completion-criteria/round1.md`). The framework source may live in volatile orchestration storage, but this schema is tracked here as the durable contract.

## Fields

| Field | Type | Description |
|---|---|---|
| schema_version | int | Currently 1. Bump on incompatible changes |
| delegation_id | string (UUID) | Per-invocation unique id |
| timestamp | string (RFC3339Z) | Invocation start time |
| wrapper_role | string | One of standard, research, coder, high-coder, reviewer |
| specialty | string|null | Slug if `--specialty` was provided and valid |
| canonical_role | string|null | Resolved canonical role for the specialty |
| manifest_hash | string|null | SHA256 of canonical specialty manifest |
| exit_code | int | Codex or validation exit code; 0 means success |
| duration_ms | int | Wall-clock duration |
| tokens_in | int|null | Input tokens parsed from Codex stderr; null if Codex did not report |
| tokens_out | int|null | Output tokens parsed from Codex stderr; null if Codex did not report |
| total_tokens | int|null | Total tokens parsed from Codex stderr; null if Codex did not report |
| dry_run | bool | True iff `--dry-run` was used |
| specialty_status | string | One of validated, fail-closed, none |

## Disabling

Set `REV_HARNESS_METRICS_DISABLE=1` to suppress the line.

## Tooling

- `scripts/collect-delegation-metrics.sh`: aggregate per-session JSONL into JSON
- `scripts/compute-completion-delta.sh`: compute baseline-vs-post delta

Both tools use `jq`.

## Release-Gate Integration

`test/integration/harness_release_gate.sh` includes a smoke step that runs the wrapper against `test/fixtures/fake-codex/codex` and asserts the collector pipeline succeeds.

## Caveats

- Tokens are null when Codex does not emit `tokens used`, for example after a model error or rate limit.
- Timings are approximate; millisecond granularity is intended.
- This is a minimum-viable metrics layer. For per-task pre-vs-post comparisons at scale, persist sessions in a permanent location, not `.claude/tmp/`.
