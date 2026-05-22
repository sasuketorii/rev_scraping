# Lane K.2 reviewer prompt (Codex)

You are the v1.3 Lane K.2 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.2):

> cargo-deny + cargo-audit + cargo-msrv verify three-point CI gate.
> Acceptance: deny.toml extended (license allowlist, banned-crates,
> advisory deny); failures block merge.

Artifacts:
- .github/workflows/security.yml (cargo-msrv + forbid-unsafe-lint job)
- deny.toml (if present at repo root)

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main

Verify:
1. security.yml runs cargo-deny check.
2. security.yml runs cargo-audit.
3. security.yml runs cargo-msrv verify.
4. forbid-unsafe-lint job present (grep for `#![forbid(unsafe_code)]`).
5. Failures actually fail the workflow (no `|| true` swallow).

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
