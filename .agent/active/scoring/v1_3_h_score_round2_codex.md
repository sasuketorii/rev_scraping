# Lane H R2 scoring prompt — Codex

You are **Codex scorer** for the v1.3 Lane H release plumbing fixup (R2).

R1 baseline (Codex, recorded at `.agent/active/scoring/v1_3_h_score_round1_codex.md`):

| Axis | R1 | R1 rationale |
|---|---|---|
| A   | 6.8 | H.1/H.5 stub bin name + sha placeholder; acceptance unmet |
| B   | 8.0 | dry-run CI present; cosign verify self-check missing |
| C   | 7.0 | design wins; implementation at 0 |
| D   | 5.8 | `brew install rev-stealth` blocked by missing tap / sha / bottle |
| E   | 7.5 | 1-year survival OK; rename TODO documented |
| F   | 6.0 | dry-run-centric; brew audit / dpkg-rpm install sanity / cosign verify self-check / Trivy PR scan all missing |
| G   | 6.0 | README claimed `cargo install rev-stealth` and bottles ahead of reality |

**overall R1 = 6.79 FAIL**

## What landed across Slices B-1 → B-3 (between R1 and R2)

Commits:

  - `edc66bca` — Slice B-1 (workflow-only): adds brew audit, cosign self-check, Trivy PR scan, and `--dry-run` mode wiring across the release lanes.
  - `25838866` — Slice B-2: real `install.sh` POSIX unit test (shellcheck + behavioral coverage in dash; ubuntu-22.04 PR job).
  - `f2cd477`  — Slice B-3 (this commit): mass rename of all 12 internal crates to the `rev-stealth-*` crates.io namespace, every internal crate flipped to `publish = true`, full crates.io metadata added (description / repository / homepage / readme / keywords / categories), `[lib] name` aliases preserve `use stealth_core::...` etc. unchanged, `obscura-bridge` direct `path = "../X"` deps converted to `workspace = true`, plus a new PR-only `package-metadata-sanity` CI job that runs `cargo deb --no-build -p rev-stealth` + `dpkg-deb -I` + `cargo generate-rpm -p rev-stealth` + `rpm -qip` and greps the required fields.

Deterministic evidence at R2:

  - `cargo test --workspace --no-fail-fast`: 865 passed / 0 failed / 38 ignored (R1 baseline was 858 / 0 / 38).
  - `cargo build -p rev-stealth --release`: PASS.
  - `cargo package -p rev-stealth-<leaf> --allow-dirty`: PASS for all 6 in-tree leaf crates (mobile-fp / cf / sanitize / sites / agent-contracts / parse). Full transitive `cargo publish --dry-run -p rev-stealth` still expects the renamed packages to be uploaded first — same as Slice A semantics; turns green during the real bottom-up release.
  - `./target/release/rev-stealth --version` → `rev-stealth 1.2.0`.
  - Codex reviewer LGTM round 1 on B-3 (9/9 checklist items: naming consistency, workspace dep aliasing, metadata, no stray path deps, [lib] name on every crate including stealth-mcp, CI gate, no rust source churn, stealth-sanitize policy comment refreshed, no secret leakage).

## What this round is being scored against

Same 7-axis rubric used at R1 (A = acceptance, B = pipeline coverage, C = implementation completeness, D = end-user install path, E = 1-year survival, F = production sanity gates, G = README/reality parity).

Produce R2 scores per axis, with one-line rationale per axis citing the concrete change between R1 and R2. Then compute:

  overall_R2 = round(mean(A..G), 2)

and report verdict: **PASS if overall_R2 ≥ 9.0, else FAIL** (target was ≥ 9.0).

## Output format

```
| Axis | R2 | Δ vs R1 | rationale |
|---|---|---|---|
| A | <s> | <±> | <one line citing concrete change> |
| B | <s> | <±> | <…> |
| C | <s> | <±> | <…> |
| D | <s> | <±> | <…> |
| E | <s> | <±> | <…> |
| F | <s> | <±> | <…> |
| G | <s> | <±> | <…> |

overall_R2 = <x.xx>     (R1 = 6.79, target ≥ 9.0)
verdict: <PASS | FAIL>
```

Be honest. Score reality, not the prompt. If an axis still has an open gap (e.g. real `brew install` still cannot succeed because the tap repo is empty), reflect that in D.
