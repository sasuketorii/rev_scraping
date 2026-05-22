# Lane H v1.3 Slice B-1 — Reviewer Prompt (Round 1)

You are the Codex reviewer (role: `reviewer`, `xhigh` + `cached`).

## Slice scope

Lane H v1.3 Slice B-1 is a **workflow-only** slice. Cargo.toml / source code are intentionally untouched (those land in Slice B-3). Touched files:

- `.github/workflows/release.yml`
- `.github/workflows/ci.yml`
- `docs/distribution.md`

## Deltas implemented in B-1

### Delta 2: Homebrew tap workflow + brew audit
- New job `brew-audit` in `release.yml` (`runs-on: macos-14`, needs preflight) running `brew audit --strict --online --formula ./Formula/rev-stealth.rb`.
- Gated to `pull_request` + `workflow_dispatch{dry_run=true}`. Skipped on real tag push because the formula's `url` points at the not-yet-published tag tarball (placeholder sha256) and `--online` would 404.
- Optional `brew test-bot --only-tap-syntax` step, advisory (`continue-on-error: true`).
- `docs/distribution.md` tap-repo bootstrap section refactored into a numbered, executable step table with per-step verification commands (including `brew audit` step 4 matching the release.yml gate).

### Delta 3: cosign verify-blob + SLSA verifier self-check + attest@v2
- `release.yml` binary build job (`build-binaries`) already had `id-token: write` + `attestations: write` permissions; left as-is.
- After `cosign sign-blob`, added a `cosign verify-blob` self-check pinning `--certificate-identity-regexp` to this repo's release workflow OIDC identity and `--certificate-oidc-issuer` to `token.actions.githubusercontent.com`.
- Upgraded `actions/attest-build-provenance@v1` → `@v2` for both the binary build job and the OCI image job. v2's `bundle-path` output is consumed by the next step.
- Added `slsa-framework/slsa-verifier/actions/installer@v2.7.1` step followed by `slsa-verifier verify-artifact --provenance-path "${{ steps.attest.outputs.bundle-path }}" --source-uri github.com/${{ github.repository }}` as the matching self-check.
- All four new steps (cosign install, cosign verify-blob, slsa-verifier install, slsa-verifier verify-artifact) are gated on `github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.dry_run)` so dry-run exercises them locally on the runner without registry side effects.

### Delta 5: distroless trivy PR scan + self-pull smoke
- New `distroless-pr-scan` job in `ci.yml`, gated `if: github.event_name == 'pull_request'`.
- Builds `local/rev-stealth-test:pr` via `docker/build-push-action@v6` with `platforms: linux/amd64`, `load: true`, `push: false`.
- Self-pull smoke: `docker image inspect` + `docker image ls` confirms the image is locally addressable.
- `trivy image --severity HIGH,CRITICAL --exit-code 1 --no-progress local/rev-stealth-test:pr`. `--ignore-unfixed` intentionally OFF.

### Delta 7: release.yml `workflow_dispatch.inputs.dry_run` integration
- Added `workflow_dispatch.inputs.dry_run` (bool, default false).
- Binary build job's cosign sign/verify + attest + slsa-verifier steps run on `push || dry_run`.
- OCI image job: `push:` to GHCR remains gated on real tag push only (no GHCR push during dry-run); image still builds via buildx so the Dockerfile path is exercised.
- `cargo-publish` job: existing condition `if: github.event_name != 'push'` naturally handles dry-run (no real publish).
- `gh-release` job: relaxed `if:` to `push || (workflow_dispatch && dry_run)`. Added a "List release artifacts (dry-run inventory)" step that runs unconditionally inside the job; the real `softprops/action-gh-release` step is still gated on `github.event_name == 'push'` so dry-run does not create a draft release.

## Files touched
- `.github/workflows/release.yml`
- `.github/workflows/ci.yml`
- `docs/distribution.md`

`Cargo.toml`, `crates/**`, `install.sh` intentionally NOT touched (Slice B-2 / B-3 scope).

## Deterministic checks performed locally

- `actionlint .github/workflows/release.yml` → exit 0 (clean).
- `actionlint .github/workflows/ci.yml` → only pre-existing SC2155 + `if: false` placeholder findings on lines 217/261/404/438 (unrelated to B-1 edits; all four are in regions Slice B-1 did not touch).
- `git diff --stat` → 3 files, +196 / -15.
- `cargo test --workspace --no-fail-fast` NOT re-run because B-1 is workflow-only; previous baseline 820 PASS remains valid (no Rust source changed).

## Out-of-scope items punted

- **install.sh POSIX unit test** — punt to Slice **B-2** (per orchestrator split decision).
- **Cargo.toml mass rename / publish chain flips** — punt to Slice **B-3**.
- Real verification of `actions/attest-build-provenance@v2` `bundle-path` output and `slsa-verifier@v2.7.1` action tag was done via public action.yml fetch; both are confirmed valid at review time.

## What reviewer should verify

1. **brew-audit job correctness**
   - macos-14 is the right runner (preinstalled brew).
   - `brew audit --strict --online --formula ./Formula/rev-stealth.rb` is the canonical strict audit; flag if you think `--git` or a different flag set is required for tap audit.
   - `brew test-bot --only-tap-syntax` is appropriately advisory (or should it be hard?).
   - Skip on real tag push: confirm the rationale (placeholder sha256 + `--online` 404) holds, or flag if you think the formula's url+sha256 are guaranteed bumped before the `release.yml` tag-push job evaluates the audit dependency.

2. **cosign verify-blob identity pin**
   - `--certificate-identity-regexp: "^https://github\\.com/${{ github.repository }}/\\.github/workflows/release\\.yml@"` — confirm this regex correctly matches the OIDC SAN that `cosign sign-blob` produces for a workflow at `.github/workflows/release.yml`, both on tag push (`@refs/tags/vX.Y.Z`) and on `workflow_dispatch` (`@refs/heads/main` or similar). Flag if the regex needs `\\.git$` anchoring or path-traversal hardening.
   - `--certificate-oidc-issuer: https://token.actions.githubusercontent.com` — correct issuer for GitHub Actions OIDC.

3. **attest-build-provenance v1 → v2 migration**
   - Output `bundle-path` is consumed by slsa-verifier. Confirm v2 emits this output (verified via the action's `action.yml`).
   - `push-to-registry: true` on the OCI attestation step is preserved across the v1→v2 bump.

4. **slsa-verifier self-check**
   - `verify-artifact` with `--provenance-path` + `--source-uri github.com/${{ github.repository }}` — correct invocation form for verifying a local tarball against its just-emitted attestation bundle.
   - Confirm slsa-verifier v2.7.1 is a current valid release tag.

5. **distroless-pr-scan job**
   - `linux/amd64`-only build is sufficient for CVE coverage (distroless base layer identical across arches from trivy DB lookup standpoint) — flag if you disagree.
   - `--ignore-unfixed` intentionally OFF — flag if you think this should be ON to avoid PR-blocking noise from unfixed CVEs in base images.
   - Trivy `--exit-code 1` correctly fails the PR job.

6. **dry-run mode side-effect isolation**
   - On `workflow_dispatch{dry_run=true}` confirm NO real side effects: no GHCR push (gated by `push: ${{ github.event_name == 'push' }}` on build-push-action), no crates.io publish (gated by `github.event_name == 'push'` step `if:`), no GitHub release creation (`softprops/action-gh-release` step `if: github.event_name == 'push'`). The inventory `find` step is read-only.
   - cosign signatures + attestation bundles ARE produced during dry-run but only stay on the runner / in `actions/upload-artifact` outputs — confirm this is the desired dry-run semantics and not a covert keyless-sign that should be gated tighter.

7. **Conflict with concurrent Lane G.5** (a99a9cab8c429df8c) — G.5 touches `crates/stealth-cli/src/commands/{auth,mod,dry_run}.rs`. B-1 touches no Rust code or shared workflow regions G.5 would touch. The ci.yml additions are at end-of-file, well outside any cargo-public-api / mcp-schema-breaking sections G.5 might modify. No expected merge conflict.

## Required reviewer output

Per `.agent_rules/RULES.md#13` reviewer role:
- LGTM / BLOCK verdict
- Issue list with severity (high / medium / low)
- For each high/medium finding: specific file + line + suggested fix
- Confirmation that workflow-only scope is respected (no Cargo/source changes leaked)
