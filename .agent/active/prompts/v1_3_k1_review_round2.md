# Lane K.1 reviewer prompt (Codex) — round 2

You are the v1.3 Lane K.1 reviewer, round 2. Previous round flagged:
1. PR comment did not compute delta vs main — only showed current values.
2. cargo-llvm-cov invocation omitted `--branch`, so branch gate was unreliable.

Round 2 fixes applied to .github/workflows/coverage.yml:
1. `cargo llvm-cov --workspace --branch ...` — branch coverage now measured.
2. New step `Fetch baseline coverage from main` downloads the last successful
   main-branch coverage-lcov artifact via `gh run download`, extracts
   `lines.percent`, exposes as `steps.baseline.outputs.baseline_line`.
3. PR comment now has a 4th column "delta" showing `+/-X.XX% vs main (Y%)`.
   Falls back to "n/a (no baseline)" on the very first run or if retention
   evicted the artifact (continue-on-error: true on baseline step).

Acceptance (recap):
> cargo-llvm-cov CI job; soft gate 80%/70% v1.3, hardened to 85%/75% v1.4.
> CI artifact + PR comment with delta.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
