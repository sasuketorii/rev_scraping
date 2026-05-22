# Lane K.6 reviewer prompt (Codex)

You are the v1.3 Lane K.6 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.6):

> Cross-platform CI matrix: Linux x86_64 + Linux aarch64 (QEMU) +
> macOS x86_64 + macOS arm64. Acceptance: cargo test --release PASS
> on all 4.

Artifacts:
- .github/workflows/cross-platform-nightly.yml

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main

Verify:
1. Workflow declares a 4-way matrix (linux-x86_64, linux-aarch64,
   macos-x86_64, macos-arm64).
2. Linux aarch64 uses QEMU (cross or docker/qemu action).
3. Runs `cargo test --release` (not just build).
4. Triggers on nightly cron + manual dispatch.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
