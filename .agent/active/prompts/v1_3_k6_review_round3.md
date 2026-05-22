# Lane K.6 reviewer prompt (Codex) — round 3

You are the v1.3 Lane K.6 reviewer, round 3. Round 2 flagged:
- `runs-on: macos-13` is deprecated; use `macos-15-intel`.

Round 3 fix:
Updated `.github/workflows/cross-platform-nightly.yml` macos-x86_64 job:
- `runs-on: macos-13` → `runs-on: macos-15-intel`
- name updated to "macos-15-intel (x86_64 Intel, nightly)"
- cache shared-key updated to `macos-15-intel-x86_64`

All 4 jobs now use currently-supported GitHub-hosted runner labels:
- ubuntu-22.04 (linux-x86_64)
- ubuntu-22.04 + cross/QEMU (linux-aarch64)
- macos-15-intel (macos-x86_64)
- macos-14 (macos-arm64)

Each runs `cargo test --workspace --release --no-fail-fast`.

Constraints: prompt ≤ 2 KB / no Write/Edit / baseline 7c700a0b.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 3 items>
