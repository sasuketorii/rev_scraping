# Review v1.3 Lane H (plumbing-only) — round 3

Round-2 BLOCK addressed:

**Preflight `cargo package --workspace` failure** → narrowed to
`cargo package -p rev-stealth-cli --allow-dirty --no-verify` in
`.github/workflows/release.yml`. Verified locally:

```
$ cargo package -p rev-stealth-cli --allow-dirty --no-verify
   Packaging rev-stealth-cli v1.2.0
    Packaged 6 files, 10.5KiB (3.8KiB compressed)
```

Inline comment in the workflow explains why workspace-wide packaging
isn't viable: internal path deps (`mobile-fp`, etc.) are `publish = false`
and intentionally lack version requirements; the wrapper crate is the
only crates.io publish target so it's the only thing that needs to be
packaged.

Round-1 + round-2 reviewer accepted answers retained: duplicate-bin
collision cleared; installer find-based extract acceptable; Homebrew
completion path removed; release-please moved to its own workflow.

## Re-verified gates

- `cargo check --workspace`: OK
- `cargo package -p rev-stealth-cli --allow-dirty --no-verify`: OK
- `cargo publish --dry-run -p rev-stealth-cli --allow-dirty`: OK
- `cargo build --release --bin rev-stealth`: 1 artifact, no warning
- `shellcheck -s sh install.sh`: clean
- `actionlint release.yml release-please.yml`: clean
- `docker buildx build --check -f Dockerfile.distroless .`: no warnings

## Verify (1)

Are all round-1/2 BLOCKs cleared with no new plumbing concerns introduced
by the narrowed `cargo package` step?

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
