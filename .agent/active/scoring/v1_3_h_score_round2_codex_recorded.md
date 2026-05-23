# Lane H R2 Codex scoring (recorded)

Post Slice B-1 (edc66bca), B-2 (25838866), B-3 (f2cd477).

| Axis | R2  | Δ vs R1 | rationale |
|---|---:|---:|---|
| A | 8.0 | +1.2 | Stub/wrapper path fixed and internal crates are publishable, but `cargo publish --dry-run -p rev-stealth` still fails until bottom-up crates exist and H.1 tap acceptance unmet. |
| B | 9.2 | +1.2 | Added brew audit, cosign verify self-check, Trivy PR scan, install dry-run wiring, release inventory checks; publish dry-run still red pre-upload. |
| C | 8.6 | +1.6 | B-3 made the real crate namespace/metadata/lib-alias implementation concrete; external publish/tap bootstrap still outside landed automation. |
| D | 6.0 | +0.2 | End-user install still blocked: tap repo not found, formula SHA all-zero, v1.3.0 tarball is 404, crates.io `rev-stealth` is 404. |
| E | 8.6 | +1.1 | Rename + metadata cleanup remove major wrapper debt; manual tap/bootstrap + formula SHA remain survival risks. |
| F | 8.5 | +2.5 | Added shellcheck+dash installer test, brew audit, cosign self-check, Trivy PR scan, deb/rpm metadata sanity; still missing real dpkg/rpm/brew install smoke. |
| G | 7.1 | +1.1 | Main README closer to source-build reality; mdBook install docs still promise bottles/cargo/GH release artifacts before those surfaces exist. |

**overall_R2 = 8.00**  (R1 = 6.79, target ≥ 9.0)
**verdict: FAIL** (vs ≥ 9.0 target; but +1.21 improvement)

## Remaining gap (Slice C territory, not B-3 scope)

The blockers are all external bootstrap, not in-tree plumbing:

  1. The `homebrew-rev-stealth` tap repo on GitHub does not exist yet.
  2. The `rev-stealth-*` packages are not uploaded to crates.io yet (B-3 enables the upload; B-3 does not perform it).
  3. The `Formula/rev-stealth.rb` SHA256 + URL placeholders need a real v1.3.0 tag to point at.
  4. The mdBook handbook copy still references bottles / `cargo install rev-stealth` / GH release tarballs in present tense rather than future tense.

R1 → R2 deltas (axis-by-axis):

  - A +1.2, B +1.2, C +1.6, D +0.2, E +1.1, F +2.5, G +1.1
  - average improvement: +1.21
  - F was the largest jump (PR-time pipeline coverage exploded across B-1+B-3)
  - D was the smallest jump (tap/upload sequence not yet executed)
