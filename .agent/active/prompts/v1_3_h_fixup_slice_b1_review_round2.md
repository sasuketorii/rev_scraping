# Lane H v1.3 Slice B-1 — Reviewer Prompt (Round 2)

You are the Codex reviewer (role: `reviewer`, `xhigh` + `cached`).

## Round-1 verdict recap

Round 1 (`v1_3_h_fixup_slice_b1_review.md`) returned `BLOCK` with three high findings:

1. **Dry-run not side-effect isolated.** `cosign sign-blob` + `actions/attest-build-provenance` create permanent Sigstore/Rekor + GitHub attestation records, so gating them on `push || dry_run` was incorrect.
2. **`slsa-verifier verify-artifact` is wrong for `attest-build-provenance@v2` bundle.** v2 emits a DSSE/Sigstore bundle that `gh attestation verify --bundle` is designed for; `slsa-verifier`'s artifact path expects a different provenance shape.
3. **`brew audit --strict --online` on PR/dry-run is a deterministic-fail.** The formula still carries the placeholder `v1.3.0.tar.gz` URL with all-zero sha256; `--online` will 404 against the unpublished archive.

## Round-2 fixes applied

### Fix 1 — Signing is now real-tag-push-only (high #1)
- `Install cosign`, `Cosign sign-blob (keyless OIDC)`, `Cosign verify-blob (self-check)`, `Attest build provenance (SLSA L3)`, and the new `gh attestation verify (self-check)` step are all gated on `github.event_name == 'push'` (no `|| dry_run`).
- `workflow_dispatch{dry_run=true}` now exercises ONLY: build, stage tarball, upload artifact. No Sigstore/Rekor entry, no GitHub attestation, no cosign cert.
- The dry-run intent is preserved as "rehearse the build + artifact-collection path without producing permanent supply-chain side effects." The `gh-release` job's `List release artifacts (dry-run inventory)` step explicitly documents that absent `.sig` / `-keyless.pem` files in the inventory IS the proof that no signing side effect occurred.
- Block comment at `release.yml` build-binaries job documents the rationale (lines 195–209).

### Fix 2 — Replace slsa-verifier with `gh attestation verify` (high #2)
- Removed `slsa-framework/slsa-verifier/actions/installer@v2.7.1` step and `slsa-verifier verify-artifact` step.
- Added a single `gh attestation verify (self-check)` step using the runner's preinstalled `gh` CLI:
  ```
  gh attestation verify "${ARCHIVE}" \
    --bundle "${ATTESTATION}" \
    --repo "${REPO}" \
    --signer-workflow "${SIGNER_WORKFLOW}"
  ```
  where `ATTESTATION = steps.attest.outputs.bundle-path`, `REPO = github.repository`, `SIGNER_WORKFLOW = github.repository/.github/workflows/release.yml`. `GH_TOKEN = secrets.GITHUB_TOKEN`.
- Gated on `github.event_name == 'push'` only (matches the attestation step it verifies).

### Fix 3 — `brew audit` runs offline on PR/dry-run (high #3)
- `brew-audit` job step changed from `brew audit --strict --online --formula ./Formula/rev-stealth.rb` → `brew audit --strict --formula ./Formula/rev-stealth.rb` (no `--online`).
- Block comment at `release.yml` lines 168–184 documents that `--online` cannot run while the formula carries the placeholder url+sha256, and that the matching `--online` audit responsibility moves to:
  - `docs/distribution.md` tap-bootstrap step 4 (run by the operator at first tap publish, when the url+sha256 are already real), and
  - the tap repo's own CI (post-release).
- `docs/distribution.md` step 4 and the closing paragraph were updated to make this offline-PR / online-tap split explicit.

## Files touched in round 2
- `.github/workflows/release.yml`
- `.github/workflows/ci.yml` — unchanged from round 1 (Delta 5 distroless PR scan stays as approved-directionally last round).
- `docs/distribution.md`

## Deterministic checks
- `actionlint .github/workflows/release.yml` → exit 0 (clean).
- `actionlint .github/workflows/ci.yml` → only pre-existing SC2155 + `if: false` placeholder findings unrelated to B-1.

## What round-2 reviewer should verify

1. **`gh attestation verify` invocation form** — confirm flag set + identity pinning is correct against the `attest-build-provenance@v2` bundle. Note `--signer-workflow` is documented at https://cli.github.com/manual/gh_attestation_verify and pins the workflow path to defeat workflow-source spoofing.
2. **brew audit (offline) still catches the regression class the slice cares about** — formula syntax, deprecated DSL, missing test block, etc. If you think offline is too weak and a different reachable canary URL should be substituted instead, call it out.
3. **dry-run side-effect surface is now zero** — re-audit every `if:` in `release.yml` jobs and confirm none of: cosign installer, cosign sign-blob, cosign verify-blob, attest-build-provenance, gh attestation verify, GHCR login, docker buildx push, cargo publish (real), softprops/action-gh-release fire under `workflow_dispatch{dry_run=true}`.
4. **No regression in real-tag-push behaviour** — the push path still: signs blob, verifies blob, attests, gh-verifies attestation, signs image, attests image, drafts release. Confirm the round-2 edits did not silently demote any of these steps.

## Required reviewer output
- LGTM / BLOCK verdict
- Severity-tagged finding list (high / medium / low)
- For each high/medium finding: file + line + suggested fix
- Confirmation the three round-1 high findings are now resolved (or explicit unresolved with reason)
- Workflow-only scope confirmation (no Cargo.toml / `crates/**` / `install.sh` leaked into B-1)
