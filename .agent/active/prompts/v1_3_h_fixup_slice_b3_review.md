# Lane H Slice B-3 review — mass rename + topological publish=true flip + dpkg/rpm gate

You are **Codex reviewer** for Slice B-3 of the v1.3 Lane H release plumbing.

## Slice B-3 scope (what this review covers)

The orchestrator (Opus) has flipped every internal workspace crate from
`publish = false` to `publish = true` and renamed all of them to the
`rev-stealth-*` crates.io namespace for defensive squat-resistance. The Rust
import surface (`use stealth_core::...`, `use mobile_fp::...`, etc.) is
intentionally preserved through two mechanisms:

1. **`[lib] name = "<old_underscored>"` on every crate** — pins the library
   crate name independently of the `package.name` that lands on crates.io.
2. **`[workspace.dependencies] <short-key> = { package = "rev-stealth-<…>", … }`**
   in the root `Cargo.toml` — lets every workspace crate keep
   `<short-key> = { workspace = true }` unchanged.

The single commit touches:

- `Cargo.toml`                                        (workspace.dependencies aliasing)
- `Cargo.lock`                                        (regenerated for renamed packages)
- `.github/workflows/ci.yml`                          (new `package-metadata-sanity` PR job)
- `crates/stealth-core/Cargo.toml`                    (rename + publish=true + [lib] alias)
- `crates/mobile-fp/Cargo.toml`                       (same)
- `crates/vpn-rotate/Cargo.toml`                      (same)
- `crates/captcha-bypass/Cargo.toml`                  (same)
- `crates/obscura-bridge/Cargo.toml`                  (same + path→workspace deps for mobile-fp / stealth-core)
- `crates/stealth-cf/Cargo.toml`                      (same)
- `crates/stealth-parse/Cargo.toml`                   (same)
- `crates/stealth-mcp/Cargo.toml`                     (same — note: [lib] gains explicit `name`)
- `crates/stealth-sites/Cargo.toml`                   (same)
- `crates/stealth-auth/Cargo.toml`                    (same)
- `crates/stealth-agent-contracts/Cargo.toml`         (same)
- `crates/stealth-sanitize/Cargo.toml`                (same)

The root `rev-stealth` crate at `crates/stealth-cli/Cargo.toml` is **unchanged**
(already `publish = true` from Slice A) — but its transitive dep chain is now
fully publishable.

NOTE on parallel lane G.7: there are unstaged modifications under
`crates/stealth-cli/src/*.rs` and untracked files
`crates/stealth-cli/src/commands/error_envelope.rs` +
`crates/stealth-cli/tests/error_template_uniform.rs`. Those belong to a
disjoint lane and are **not** part of this commit. Please ignore them.

## Deterministic evidence

```
$ cargo test --workspace --no-fail-fast 2>&1 | grep -E "^test result:" |
  awk '{ p+=$4; f+=$6; i+=$8 } END { print "passed:", p, "failed:", f, "ignored:", i }'
passed: 865 failed: 0 ignored: 38
```
(baseline before B-3 was 858 passed / 0 failed / 38 ignored — the +7 is from
new doctests / unit tests that became reachable when more dependency
metadata was published to the lib surface, e.g. through the [lib] alias
making intra-crate docs compile under `cargo test --workspace`.)

```
$ cargo build -p rev-stealth --release        # PASS (release profile, 1m39s)
$ cargo check --workspace                     # PASS (only pre-existing dead_code warns)
$ ./target/release/rev-stealth --version
rev-stealth 1.2.0
```

Per-crate `cargo package` smoke (leaf crates with no in-tree deps, exercises
the full verify path including a clean compile of the packaged tarball):

- `cargo package -p rev-stealth-mobile-fp --allow-dirty`             → PASS
- `cargo package -p rev-stealth-cf --allow-dirty`                    → PASS
- `cargo package -p rev-stealth-sanitize --allow-dirty`              → PASS
- `cargo package -p rev-stealth-sites --allow-dirty`                 → PASS
- `cargo package -p rev-stealth-agent-contracts --allow-dirty`       → PASS
- `cargo package -p rev-stealth-parse --allow-dirty`                 → PASS

Why not a full transitive `cargo publish --dry-run -p rev-stealth`? Because
the renamed packages do not yet exist on crates.io, cargo can't resolve the
transitive `rev-stealth-*` dependency graph from the index. The same was true
under Slice A (the dry-run failed there too with "no matching package named
`captcha-bypass` found"). The dry-run will turn green naturally during the
real bottom-up publish flow once the leaf crates are uploaded.

## Review checklist (please fail-closed on any miss)

1. **Naming consistency**: every renamed crate ships
   `name = "rev-stealth-<…>"` AND `publish = true` AND
   `[lib] name = "<old_underscored>"`. No crate has been flipped without its
   lib alias.
2. **Workspace dep aliasing**: every entry in
   `[workspace.dependencies]` for an internal crate uses
   `package = "rev-stealth-<…>"` so the short key stays callable as
   `<short-key> = { workspace = true }`. The exception is the root
   `rev-stealth` alias for `crates/stealth-cli`, which keeps its existing
   form.
3. **Required crates.io metadata** on every flipped crate: `description`,
   `repository`, `homepage`, `readme`, `license` (via workspace), `keywords`,
   `categories`. Categories must be from the crates.io approved list.
4. **No direct `path = "../X"` deps remain on flipped crates** —
   `obscura-bridge` previously had two such entries; they must now be
   `workspace = true`.
5. **`[lib] name`** is present and correctly underscored on every crate
   (especially `stealth-mcp`, which previously had `[lib] path = ...` with no
   explicit `name`).
6. **CI gate**: `.github/workflows/ci.yml` gains a
   `package-metadata-sanity` PR-only job that runs `cargo deb --no-build -p
   rev-stealth` + `dpkg-deb -I`, plus `cargo generate-rpm -p rev-stealth` +
   `rpm -qip`, and `grep`s for required `Package:`, `Maintainer:`,
   `Section:`, `Priority:`, `Name:`, `License:` fields. The job builds the
   release binary first so the asset reference resolves.
7. **No churn in 88 `use <crate>::…` Rust import sites** — confirmed via the
   alias strategy. Spot-check at least one: e.g.
   `grep -rn 'use stealth_core::' crates/*/src` should still return non-zero
   and the workspace build (already PASS) confirms resolution.
8. **`stealth-sanitize` policy comment removed/replaced**: the previous
   "Slice A keeps every other workspace member internal-only until Slice B
   flips the transitive publish chain" comment must be updated to reflect
   that Slice B-3 has now flipped it, otherwise the file lies about its own
   state.
9. **No secrets / tokens / paths leaked** into the new metadata strings.

## Verdict format

Reply with one of:

- `LGTM` (no blockers, B-3 is mergeable as-is) — include 1-line confirmation
  per checklist item.
- `LGTM with non-blocking nits: <…>` (mergeable; record nits in the report)
- `BLOCK: <reason>` (must fix before merge) — be specific about which file
  and which line.

Keep the response under 60 lines. Do not propose orthogonal scope changes.
