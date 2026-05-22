# Review v1.3 I.2 (Round 3)

R2 BLOCK addressed:

`cargo-public-api` consumes rustdoc JSON and is tied to a specific nightly date. Pinning `cargo-public-api 0.39.0` against floating `nightly` was a flake risk — the next nightly bump in rustdoc JSON schema could break the diff job before it ever ran. Per the cargo-public-api version_info table, 0.39.x is validated against `nightly-2024-10-13`.

Pinned the nightly toolchain to that date:

```
- uses: dtolnay/rust-toolchain@master
  with:
    toolchain: nightly-2024-10-13
- uses: Swatinem/rust-cache@v2
  with:
    shared-key: ubuntu-22.04-nightly-2024-10-13
```

Added an inline comment pointing to the upstream version_info table and noting "re-pin in lockstep when bumping cargo-public-api in v1.4."

## Files touched (delta)
- `.github/workflows/ci.yml` — `cargo-public-api-diff` toolchain pin + comment.

## Gates PASS
- yamllint: workflow valid
- nightly-2024-10-13 + cargo-public-api 0.39.0 is the validated pair per upstream

## Verify (3)
1. Floating `nightly` removed; explicit `nightly-2024-10-13` in place.
2. Cache key updated so the cache doesn't poison the toolchain on key reuse.
3. Comment documents the upstream source so the v1.4 contributor knows where to look when bumping cargo-public-api.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
