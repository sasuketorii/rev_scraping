# Shipped Artifacts

## Purpose

This manifest lists executable and archive artifacts whose shipped bytes must
scan clean before a release is tagged.

## Update obligation

Every release slice that adds, removes, renames, or changes a shipped
executable/archive must update this manifest in the same slice. Empty implicit
success is forbidden: if no core executable/archive ships, a row must explicitly
record `no shipped core artifact` with reviewer evidence.

## Reviewer evidence rule

Each `not-shipped` row must include an evidence pointer showing why the artifact
does not ship in the current release. A missing evidence pointer is a manifest
failure.

## Manifest

Allowed `kind` values: `executable`, `archive`.
Allowed `ships-in-release` values: `yes`, `not-shipped`.

| artifact path | kind | ships-in-release | privacy-scan command | status | evidence |
|---|---|---|---|---|---|
| `harness-rust/target/release/semantic-mcp` | executable | yes | `bash scripts/ci/release-binary-privacy-scan.sh` | addon-pending-still-blocking | `.agent/active/plan_20260611_2000_index_first_core_refactor.md:314` |
| `harness-rust/target/release/agent-core` | executable | not-shipped | `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md` | no shipped core artifact; conditional first core activation target | `.agent/active/idxfirst-20260611/p1/review_codex_r1.md`; `.agent/active/idxfirst-20260611/p1/review_fable_r1.md` |
