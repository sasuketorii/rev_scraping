# Review v1.3 Lane H (plumbing-only)

Option A: plumbing only. External gates (brew/docker/cosign verify/crates.io
publish real) deferred to tag push.

## Files touched

- `Cargo.toml` (+1 member)
- `crates/rev-stealth-cli/{Cargo.toml,src/main.rs,README.md}` (new publish crate
  + cargo-deb + cargo-generate-rpm metadata, placeholder main)
- `Formula/rev-stealth.rb` (Homebrew tap template)
- `Dockerfile.distroless` + `.dockerignore` + `.trivyignore` + `trivy.yaml`
- `install.sh` (POSIX, cosign fail-closed default)
- `.github/workflows/release.yml` (preflight, 4-target build, deb/rpm, OCI
  multi-arch, cosign sign-blob, SLSA L3, release-please)
- `release-please-config.json`, `.release-please-manifest.json`

## Gates PASS (local)

- `cargo check --workspace`: OK
- `cargo test --workspace --no-run`: OK
- `cargo publish --dry-run -p rev-stealth-cli`: OK
- `shellcheck -s sh install.sh`: clean
- `actionlint .github/workflows/release.yml`: clean
- `docker buildx build --check -f Dockerfile.distroless .`: no warnings

## Verify (3)

1. **Wrapper strategy**: `rev-stealth-cli` is new `publish=true` crate w/
   placeholder `main.rs` (exit 3). `stealth-cli` stays `publish=false` to
   avoid renaming 13 workspace dep refs. Real wiring (lib target +
   `stealth_cli::run()` forward) deferred to release cut. Acceptable as
   plumbing-only?

2. **deb/rpm asset path**: both point at `../../target/release/rev-stealth`
   and rely on workflow to pre-stage cross-built binaries. Are the
   `package-deb`/`package-rpm` staging steps extracting the right-arch
   binary from `bin-<target>` artifact?

3. **Workflow injection safety**: every `run:` uses env-bound scalars
   (`GITHUB_REF_NAME`, step outputs, secrets); no raw `${{ github.event.* }}`
   into shell. Confirm no remaining sinks.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
