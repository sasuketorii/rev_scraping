# Batch Code Review Request

<!--
Phase 2 compatibility contract:
- This file owns the reusable batch review prompt body.
- auto_orchestrate.sh owns queue/state authority, routing, and fail-closed checks.
- docs/roles/reviewer.md is the canonical reviewer schema.
-->

## Review Context
__BATCH_REVIEW_METADATA__

## Review Focus
Please review the following git diff for:
1. **[High] Security Issues**: Injection vulnerabilities, credential exposure, unsafe operations
2. **[High] Critical Bugs**: Logic errors, race conditions, data loss risks
3. **[Medium] Design Issues**: Architecture problems, poor abstractions, maintainability concerns
4. **[Medium] Error Handling**: Missing or inadequate error handling
5. **[Low] Code Quality**: Style, naming, documentation

## Output Format
Return exactly one markdown report that follows `docs/roles/reviewer.md`.

Required output hygiene:
- The first non-empty line must be `# Code Review Report`
- Do not emit transport envelopes such as `<subagent_notification>`, transport JSON, or `trigger_turn`
- Treat pretty-printed multi-line transport JSON exactly the same as single-line transport blobs: both are invalid, including inside fenced code blocks
- Do not emit wrapper audit logs such as `[codex-wrapper] INFO: ...`
- Select exactly one verdict from `LGTM | BLOCK | Request Changes | Needs verification | Needs Discussion`
- Return `LGTM` only for `review request target: FINAL` with `pending final review`, `artifact integrity: complete`, and passing required verification
- The machine-readable runtime subset for packet/reviewer validation lives in `.agent/registry/orchestration_policy_projection.json`
- In `## Worker Outcome Payload Reviewed`, use `contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract`
- If `## Required Verification` uses a file artifact pointer, point to an existing artifact path

Required section order:
1. `## Review Request`
2. `## Review Outcome`
3. `## Slice Contract`
4. `## Loop Budget Ledger`
5. `## Summary`
6. `## Findings`
7. `## Tests`
8. `## Review Scope`
9. `## Class Closure Sheet`
10. `## Adversarial Pre-Closure Pass`
11. `## Required Verification`
12. `## Worker Outcome Payload Reviewed`
13. `## Evidence Reviewed`
14. `## Unverified Areas`
15. `## Open Questions`
16. `## Verdict`

If no issues are found:
- In `## Findings`, write `- None.`
- Fill every required section explicitly
- Choose `LGTM` only when the reviewer contract and evidence are sufficient
- Do not reply with `No issues found.` only

## Git Diff
```diff
__BATCH_REVIEW_DIFF__
```
