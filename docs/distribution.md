# rev-stealth Distribution Architecture (v1.3, Lane H Slice A)

## Status

Accepted — supersedes the v1.2 plumbing-only "publish-wrapper crate" approach
documented in `.agent/active/v1_3_uplift_execplan_rev1.md` Lane H.

## Context

v1.2 shipped a placeholder `rev-stealth-cli` crate whose only job was to
satisfy `cargo publish --dry-run` against crates.io. The actual `rev-stealth`
binary lived in the workspace-internal `stealth-cli` crate, which was
`publish = false` because its description, name, license metadata, and ~13
inbound `{ workspace = true }` dependency references made flipping it to
`publish = true` a high-churn migration. Concretely:

- `crates/rev-stealth-cli/` — `publish = true`, no internal deps, a stub
  binary `rev-stealth-cli-stub` that printed help text and exited.
- `crates/stealth-cli/` — `publish = false`, the real binary `rev-stealth`,
  workspace-internal name `stealth-cli`, depended on `stealth-core`,
  `captcha-bypass`, `vpn-rotate`, `mobile-fp`, `obscura-bridge`, `stealth-cf`,
  `stealth-parse`, `stealth-sites`, `stealth-auth`.

The wrapper trick let `cargo publish --dry-run -p rev-stealth-cli` succeed
because the wrapper had no internal dependencies. But it meant
`cargo install rev-stealth-cli` produced a binary called
`rev-stealth-cli-stub` that did not actually run the CLI — a user-facing
trap. The wrapper was always intended to be retired at the v1.3 release-cut
once the real CLI was wired to crates.io.

## Decision

At v1.3 Lane H Slice A:

1. **Retire the `rev-stealth-cli` wrapper crate.** Removed from the workspace,
   `crates/rev-stealth-cli/` deleted, all release / Formula / workflow
   references repointed.
2. **Rename the workspace-internal `stealth-cli` package to `rev-stealth`**
   while keeping the directory `crates/stealth-cli/` (avoids touching ~13
   inbound `{ workspace = true }` references in other crates' manifests; the
   `[workspace.dependencies]` alias is updated to `rev-stealth = { path = ... }`).
3. **Lift the CLI entrypoint into a library.** `crates/stealth-cli/src/lib.rs`
   now exports `pub fn run() -> i32` and `pub async fn run_async() -> i32`;
   `src/main.rs` is a 1-line forwarder
   (`std::process::ExitCode::from(stealth_cli::run() as u8)`).
   This lets the same binary be built from `cargo install rev-stealth` and
   from the workspace `cargo build --bin rev-stealth` with no codegen step
   or build-time rename.
4. **Add publishable manifest metadata** to `crates/stealth-cli/Cargo.toml`:
   `name = "rev-stealth"`, `publish = true`, `description`, `repository`,
   `homepage`, `documentation`, `readme = "README.md"`, `keywords`,
   `categories`. Migrate the `cargo-deb` / `cargo-generate-rpm` metadata
   blocks from the deleted wrapper.
5. **Add version requirements** to every internal `[workspace.dependencies]`
   entry (`version = "1.2.0"` alongside `path = ...`) so that the published
   `Cargo.toml` for `rev-stealth` satisfies cargo's
   "all dependencies must have a version requirement specified when
   publishing" manifest verification.

The transitive consequence — internal crates being flipped to `publish = true`
so they actually resolve from crates.io during dry-run / publish — is
**deferred to Slice B (Deltas 2/3/4/5/7)**. Slice B handles the publish
chain, supply-chain attestation (cosign keyless OIDC,
`actions/attest-build-provenance`), tap-repo bootstrap, and the external
gate evidence pipeline.

## Consequences

### Positive

- `cargo install --locked rev-stealth` is a one-liner that installs the
  real binary, no `-stub` suffix, no confusion.
- The Homebrew formula (`Formula/rev-stealth.rb`) already references
  `crates/stealth-cli` so the install path is unchanged.
- The `.deb` and `.rpm` artifacts continue to ship a binary named
  `rev-stealth` at `/usr/bin/rev-stealth` (metadata migrated 1:1 from the
  retired wrapper).
- The library surface (`stealth_cli::run`, `stealth_cli::run_async`) is
  reusable by embedders (Hermes plugin, integration tests, future GUI
  wrappers) without forking the CLI.
- The CI gates (`cargo publish --dry-run`, `cargo deb`, `cargo generate-rpm`)
  now reference the same publish target — no wrapper/internal split.

### Negative / Deferred

- **`cargo publish --dry-run -p rev-stealth --allow-dirty` will not pass
  in CI until Slice B publishes the transitive internal crates**
  (`stealth-core`, `captcha-bypass`, `vpn-rotate`, `mobile-fp`,
  `obscura-bridge`, `stealth-cf`, `stealth-parse`, `stealth-sites`,
  `stealth-auth`, and their internal transitive deps). The verification
  step needs to resolve each from crates.io, and they are still
  `publish = false`. Slice B will flip the publish chain in topological
  order and add the required publishable metadata to each manifest.
- Until Slice B lands, the `preflight` job in `.github/workflows/release.yml`
  will fail at the `cargo publish dry-run (rev-stealth)` step on any PR
  that touches release machinery. Reviewers should treat that failure as
  expected during Slice A and gate the actual v1.3.0 tag-push on Slice B
  completion.

## Release-cut runbook

At v1.3.0 tag-push (after Slice B lands):

1. **External gate evidence** lands at
   `.github/release-evidence/v1.3.0/` — the SBOM (CycloneDX), cosign
   keyless-OIDC attestation, `cargo-audit` clean report, and a manual
   `brew install --build-from-source ./Formula/rev-stealth.rb` smoke test
   output. Reviewer signs off here before tag push.
2. **Tag push (`vX.Y.Z`) triggers `.github/workflows/release.yml`**, which:
   - Re-runs `cargo publish --dry-run -p rev-stealth`.
   - Builds the cross-target matrix (Linux musl x86_64/aarch64, macOS
     x86_64/aarch64) and uploads `bin-${target}` artifacts.
   - Packages `.deb` (`cargo deb --no-build -p rev-stealth`) and `.rpm`
     (`cargo generate-rpm -p rev-stealth`).
   - Builds and pushes the distroless OCI image to
     `ghcr.io/sasuketorii/rev-stealth:<tag>` with cosign signing
     (`id-token: write` + `actions/attest-build-provenance`).
   - Publishes to crates.io
     (`cargo publish --locked -p rev-stealth`).
   - Drafts the GitHub release with checksums + signatures attached.
3. **Homebrew tap bootstrap** (one-time, before first v1.3.x release):
   ```sh
   # In a separate repo, sasuketorii/homebrew-rev-stealth:
   mkdir Formula
   cp /path/to/rev_scraping/Formula/rev-stealth.rb Formula/
   git add Formula/rev-stealth.rb
   git commit -m "feat: bootstrap rev-stealth formula at v1.3.0"
   git push origin main
   ```
   After bootstrap, every release pushes an updated formula via
   release-please's `extra-files` entry on `Formula/rev-stealth.rb`.

## Affected files (Slice A)

- `crates/stealth-cli/Cargo.toml` — name → `rev-stealth`, `publish = true`,
  publishable metadata, deb/rpm metadata migrated.
- `crates/stealth-cli/src/lib.rs` — full CLI lifted here, exports
  `run` / `run_async`.
- `crates/stealth-cli/src/main.rs` — 1-line forwarder.
- `crates/stealth-cli/README.md` — crates.io landing page.
- `Cargo.toml` — `crates/rev-stealth-cli` removed from members,
  `[workspace.dependencies]` entry renamed to `rev-stealth` with
  `version = "1.2.0"`, all internal workspace deps gain matching
  `version = "1.2.0"`.
- `crates/rev-stealth-cli/` — deleted.
- `.github/workflows/release.yml` — every `-p rev-stealth-cli` becomes
  `-p rev-stealth`; the path filter `crates/rev-stealth-cli/**` becomes
  `crates/stealth-cli/**`.
- `docs/distribution.md` — this document.

## Cross-references

- v1.3 execplan: `.agent/active/v1_3_uplift_execplan_rev1.md` Lane H.
- Original wrapper review (pre-retirement):
  `.agent/active/prompts/v1_3_h_plumbing_review.md`.
- Operator GO/NO-GO for Slice A:
  `.agent/active/prompts/v1_3_h_fixup_slice_a_review.md` (this fix-up).
