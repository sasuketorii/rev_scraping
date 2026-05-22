# Review v1.3 Lane H Slice B-1 round 4 (narrow fix verify)

You are the **Codex reviewer** for round 4 of v1.3 Lane H Slice B-1
(release workflow hardening: brew audit + cosign verify-blob +
trivy PR-time + workflow_dispatch dry-run). Round 4 is **verification
only** — no new implementation. Return a single-line
`verdict: LGTM` or `verdict: BLOCK: <reason>` at end.

## Round 3 BLOCK (2 high findings)

1. **gh-release skip propagation**: round-2 added push-only
   `sign-binaries` / `sign-image` jobs gated on
   `if: github.event_name == 'push'`. `gh-release` listed those in
   `needs:` without overriding default status gating, so on
   `workflow_dispatch dry_run=true` the skipped sign-* jobs caused
   `gh-release` to be skipped too — breaking the dry-run inventory
   surface that Delta 7 promised.
2. **Top-level permissions comment stale**: comment referenced the
   old `build-binaries` / `oci-image` as OIDC holders even though
   round 2 moved OIDC authority to the dedicated `sign-binaries` /
   `sign-image` jobs.

## Round 4 narrow fix (working tree, uncommitted)

Files touched (3): `.github/workflows/release.yml`,
`.github/workflows/ci.yml`, `docs/distribution.md`.

1. `gh-release.if` rewritten to:
   ```yaml
   if: |
     !cancelled() &&
     needs.build-binaries.result == 'success' &&
     needs.package-deb.result == 'success' &&
     needs.package-rpm.result == 'success' &&
     needs.oci-image.result == 'success' &&
     needs.cargo-publish.result == 'success' &&
     (needs.sign-binaries.result == 'success' || needs.sign-binaries.result == 'skipped') &&
     (needs.sign-image.result   == 'success' || needs.sign-image.result   == 'skipped') &&
     (github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.dry_run))
   ```
   so dry-run reaches `gh-release` with `sign-*` skipped. The
   `softprops/action-gh-release@v2` step inside still carries
   `if: github.event_name == 'push'` so dry-run never drafts a
   release — it only runs the artifact inventory step.

2. Top-level `permissions:` block comment updated to spell out
   that OIDC authority (`id-token: write` + `attestations: write`)
   is held **only** by `sign-binaries` and `sign-image`, and that
   `build-binaries` / `oci-image` are deliberately OIDC-less for
   PR / dry-run paths.

## Gates (run by driver)

- `actionlint .github/workflows/release.yml` → clean (0 findings).
- `actionlint .github/workflows/ci.yml` → 4 pre-existing findings
  (SC2155 x3 on lines 217/261/438, `if: false` constant on line
  404). All are outside the Slice B-1 `distroless-pr-scan` block
  appended at line 832+. B-1 touched none of them.
- `cargo test --workspace --no-fail-fast` → 838 PASS / 0 fail
  (workflow-only change; Rust surface unchanged from G.5
  baseline).

## Verification asks (3)

1. **gh-release dry-run reachability**: With the new `if:`, does
   `workflow_dispatch dry_run=true` reach `gh-release` while
   `sign-binaries` / `sign-image` are skipped, AND does it stop
   short of `softprops/action-gh-release@v2` (no draft creation)?
   Confirm the `!cancelled()` + `success || skipped` logic is
   correct GitHub Actions expression semantics.

2. **OIDC permissions localization**: Confirm that on PR /
   `workflow_dispatch dry_run` paths, no job that runs has
   `id-token: write` or `attestations: write`. Walk the job
   list: `preflight`, `brew-audit`, `build-binaries`,
   `package-deb`, `package-rpm`, `oci-image`, `cargo-publish`,
   `gh-release`. `sign-binaries` and `sign-image` are the only
   OIDC holders and both carry `if: github.event_name == 'push'`.

3. **Slice B-1 four-delta coverage intact**:
   - Delta 2 (brew audit): `brew-audit` job runs on PR +
     `workflow_dispatch dry_run`, `--strict` offline only.
   - Delta 5 (trivy PR-time): `distroless-pr-scan` in ci.yml
     runs on PR, `trivy image --severity HIGH,CRITICAL
     --exit-code 1`.
   - Delta 6 (cosign verify-blob self-check): inside
     `sign-binaries` after `sign-blob`, with
     `--certificate-identity-regexp` pinned to this repo's
     workflow path and `--certificate-oidc-issuer` pinned to
     `token.actions.githubusercontent.com`.
   - Delta 7 (workflow_dispatch dry_run): `oci-image` builds
     without push on dry-run; `gh-release` runs inventory step
     only, draft step gated on push.

## Verdict

Return exactly one final line:
`verdict: LGTM` if all three verification asks pass.
`verdict: BLOCK: <reason>` if any fail, with concrete file:line.
