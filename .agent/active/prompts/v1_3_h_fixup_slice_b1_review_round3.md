# Lane H v1.3 Slice B-1 — Reviewer Prompt (Round 3)

You are the Codex reviewer (role: `reviewer`, `xhigh` + `cached`).

## Round-2 verdict recap

Round 2 returned `BLOCK` with:

- **High**: `id-token: write` + `attestations: write` permissions were still granted at the `build-binaries` and `oci-image` job level, so PR / `workflow_dispatch{dry_run=true}` runs of those jobs retained OIDC authority even though individual signing steps were gated off.
- **Low**: comments pinned `actions/attest-build-provenance@v2`; v4 (currently v4.1.0) is the recommended major.

Round-1 high #2 (slsa-verifier vs `gh attestation verify`) and high #3 (offline `brew audit`) were marked resolved.

## Round-3 fixes applied

### Fix A — OIDC permissions removed from non-push jobs (round-2 high)

`build-binaries`:
- `permissions:` reduced to `contents: read` only. Round-2 had `contents: read` + `id-token: write` + `attestations: write`; the latter two are removed.
- All cosign / attest / `gh attestation verify` steps are MOVED OUT of this job. The job's last step is now `actions/upload-artifact@v4` (`name: bin-${{ matrix.target }}`).

New `sign-binaries` job:
- `if: github.event_name == 'push'` — only ever runs on real tag push.
- `runs-on: ubuntu-22.04`. Single runner is sufficient since cosign sign-blob is OS-agnostic; the per-target matrix is preserved for parallelism + per-target attestation bundles.
- `permissions: { contents: read, id-token: write, attestations: write }` — the sole holder of Sigstore + GitHub attestation authority on the binary side.
- `needs: build-binaries`, downloads `bin-${{ matrix.target }}` artifact, runs cosign sign-blob, cosign verify-blob (self-check, with OIDC SAN regexp pin), `actions/attest-build-provenance@v4` (id `attest`), `gh attestation verify --bundle ... --repo ... --signer-workflow ...` self-check.
- Uploads `bin-signed-${{ matrix.target }}` with the full dist tree (tarball + sha256 + .sig + .pem).

`oci-image`:
- `permissions:` reduced to `contents: read` + `packages: write` only. Round-2 had `id-token: write` + `attestations: write`; both removed.
- Cosign sign + attest-build-provenance steps REMOVED from this job. The job now ends at the trivy scan.
- Exposes `digest` as a job-level output for the new sign-image job.

New `sign-image` job:
- `if: github.event_name == 'push'`. `needs: oci-image`.
- `permissions: { contents: read, packages: write, id-token: write, attestations: write }`.
- Logs into GHCR, installs cosign, signs the image by digest (`cosign sign --yes ${REGISTRY}/${IMAGE_NAME}@${needs.oci-image.outputs.digest}`), runs `actions/attest-build-provenance@v4` with `subject-name` + `subject-digest` + `push-to-registry: true`.

### Fix B — attest-build-provenance pinned to @v4 (round-2 low)
- Binary attestation (sign-binaries job): `@v4`.
- Image attestation (sign-image job): `@v4`.
- Block comments updated to reflect that v4 is the current stable major.

### Fix C — gh-release `needs:` updated
- `needs:` now lists `build-binaries`, `sign-binaries`, `package-deb`, `package-rpm`, `oci-image`, `sign-image`, `cargo-publish`.
- Comment explains that the two `sign-*` jobs are skipped on dry-run (`if: push`) and GitHub Actions treats skipped `needs:` as satisfied, so the dry-run inventory path still runs.
- `download-artifact@v4` step has no `name:` filter, so it picks up both `bin-${target}` (always present) and `bin-signed-${target}` (present on push only). The inventory `find` and the real `softprops/action-gh-release` glob both naturally degrade.

## Files touched in round 3
- `.github/workflows/release.yml` only.
- `.github/workflows/ci.yml` unchanged from round 2.
- `docs/distribution.md` unchanged from round 2.

## Deterministic checks
- `actionlint .github/workflows/release.yml` → exit 0 (clean).
- `actionlint .github/workflows/ci.yml` → only the pre-existing SC2155 + `if: false` placeholder findings unrelated to B-1.
- `git diff --stat` → 3 files, +307 / -30.

## What round-3 reviewer should verify

1. **OIDC permission scope** — re-audit every job's `permissions:` block. Confirm `id-token: write` appears ONLY in `sign-binaries` and `sign-image`, both of which are `if: github.event_name == 'push'`. Flag any residual OIDC authority in jobs that can run on PR or dry-run.

2. **`gh-release` dry-run path** — confirm a workflow_dispatch run with `dry_run=true` still completes the gh-release job despite `sign-binaries` and `sign-image` being skipped. GitHub Actions: a skipped dependency is treated as success for `needs:` resolution by default (the downstream job's `if:` decides whether to actually run).

3. **digest output handoff** — confirm `oci-image.outputs.digest` is correctly produced by `docker/build-push-action@v6` (it is — `steps.build.outputs.digest`) and consumed by `sign-image` via `needs.oci-image.outputs.digest`. Flag if you think a missing `outputs:` plumbing breaks the handoff.

4. **`sign-binaries` matrix parallelism** — the matrix is target-only (no `os` axis), all runs on `ubuntu-22.04`. cosign sign-blob is content-agnostic, so this is intentional — confirm or flag if you think macOS targets need to be signed on macOS runners for some Sigstore policy reason.

5. **gh-release `softprops/action-gh-release` glob** — `dist/**/*.tar.gz.sig` + `dist/**/*-keyless.pem` will resolve under the artifact-download path. The download path is `dist/`, and artifact-download@v4 expands each artifact into a subdirectory named after the artifact (`dist/bin-signed-${target}/...`). Confirm the globs reach the .sig/.pem files at that depth (`**` is recursive).

6. **Workflow-only scope** — Cargo.toml / `crates/**` / `install.sh` untouched. Confirm with `git diff --name-only`.

## Required reviewer output
- LGTM / BLOCK verdict
- Severity-tagged findings list
- For each high/medium finding: file + line + suggested fix
- Confirmation that the round-2 high (OIDC scope) and low (v4 pin) findings are resolved
- Workflow-only scope confirmation
