# Lane K.1 reviewer prompt (Codex)

You are the v1.3 Lane K.1 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.1):

> cargo-llvm-cov CI job; soft gate at 80% line / 70% branch for v1.3,
> hardened to 85% / 75% in v1.4. Acceptance: CI artifact; PR comment
> with delta.

Artifacts:
- .github/workflows/coverage.yml

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- raw codex exec 禁止 (this is invoked via canonical wrapper)
- baseline: commit 7c700a0b on main

Verify:
1. Workflow installs cargo-llvm-cov.
2. Runs `cargo llvm-cov` on workspace.
3. Uploads/emits coverage artifact (lcov.info or cobertura.xml).
4. Has a soft gate (warning, not block) at 80% line for v1.3.
5. Triggers on PR + push to main.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
