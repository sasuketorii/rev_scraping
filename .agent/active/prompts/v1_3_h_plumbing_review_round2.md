# Review v1.3 Lane H (plumbing-only) — round 2

Round-1 findings addressed:

1. **Duplicate `rev-stealth` bin collision** → wrapper bin renamed to
   `rev-stealth-cli-stub`; `stealth-cli` keeps `rev-stealth`. Verified:
   `cargo build --release --bin rev-stealth` builds one artifact with
   no collision warning.

2. **Installer tar layout** → `install.sh` resolves the binary via
   `find ${TMPDIR_REAL} -type f -name rev-stealth -perm -u+x -print -quit`,
   matching the real tarball layout
   `rev-stealth-${VERSION}-${TARGET}/rev-stealth`.

3. **Homebrew `completions` subcommand missing** → removed
   `generate_completions_from_executable` from `def install`; commented
   placeholder kept for Lane G G.3 wiring.

4. **`release-please` unreachable** → moved into dedicated workflow
   `.github/workflows/release-please.yml` on `push: branches: [main]`.
   `release.yml` no longer contains the dead-coded job.

## Re-verified gates

- `cargo check --workspace`: OK
- `cargo publish --dry-run -p rev-stealth-cli --allow-dirty`: OK
- `cargo build --release --bin rev-stealth`: 1 artifact, no warning
- `shellcheck -s sh install.sh`: clean
- `actionlint release.yml release-please.yml`: clean
- `docker buildx build --check -f Dockerfile.distroless .`: no warnings

## Out of scope (release-cut, not plumbing)

- Wrapper rename `rev-stealth-cli-stub` → `rev-stealth` + wiring to
  `stealth_cli::run()` lib re-export
- Real `cargo publish`, cosign signing, GHCR push, brew tap repo

## Verify (3)

1. Does duplicate-bin BLOCK clear with the unique stub name?
2. Is `find ... -perm -u+x` acceptable, or should the installer also
   chmod +x in case a tar lost exec bits?
3. Any remaining plumbing concern (excluding the deferred items above)?

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
