# typed: false
# frozen_string_literal: true
#
# Homebrew formula for rev-stealth (Lane H plumbing-only template).
#
# Distribution path:
#   1. User: `brew tap sasuketorii/rev-stealth`
#      (resolves to https://github.com/sasuketorii/homebrew-rev-stealth)
#   2. User: `brew install rev-stealth`
#
# This formula file lives in the main repo as the canonical source.
# A separate `homebrew-rev-stealth` tap repository (to be created by the
# release owner) will mirror this file at `Formula/rev-stealth.rb`.
# `release.yml` automation can rsync this file into the tap repo on each tag.
#
# Audit compliance notes (Homebrew core / tap audit):
#   - URL points at a GitHub-hosted release tarball (no curl-pipe-bash inside).
#   - SHA256 is bumped per release by `release-please` (placeholder OK here).
#   - `head` block supports `brew install --HEAD rev-stealth` for git tip.
#   - No `system "curl"` / `system "wget"`; all network goes through Homebrew.
#   - Single bin produced: `rev-stealth`.
#
# Cargo-driven build: Homebrew's `rust` formula provides the toolchain.

class RevStealth < Formula
  desc "Stealth web scraping & MCP CLI for AI agent developers"
  homepage "https://github.com/sasuketorii/rev_scraping"
  license "MIT"
  head "https://github.com/sasuketorii/rev_scraping.git", branch: "main"

  stable do
    # Placeholder values — `release-please` rewrites url + sha256 on tag.
    url "https://github.com/sasuketorii/rev_scraping/archive/refs/tags/v1.3.0.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    version "1.3.0"
  end

  depends_on "rust" => :build

  # Chromium is intentionally NOT declared as a runtime dependency.
  # `rev-stealth` works headless via system Chromium/Chrome when present,
  # and the recommended container-mode flow uses the distroless OCI image.
  # Surfacing this as a `caveats` block keeps Homebrew audit happy
  # (no implicit binary dep on a 200MB+ package).

  def install
    # Build only the `rev-stealth` binary from the workspace.
    system "cargo", "install", *std_cargo_args(path: "crates/stealth-cli")

    # NOTE: shell completions + man pages are wired by Lane G G.3 / G.8.
    # Once `rev-stealth completions <shell>` exists, swap this block in:
    #
    #   generate_completions_from_executable(bin/"rev-stealth", "completions",
    #                                         shells: [:bash, :zsh, :fish])
    #   man1.install Dir["target/release/man/*.1"] if Dir.exist?("target/release/man")
    #
    # Left out of v1.3 Lane H plumbing to keep `brew install rev-stealth`
    # from failing on a missing subcommand.
  end

  def caveats
    <<~EOS
      `rev-stealth` browser commands need a Chromium-family browser at
      runtime. Either install Google Chrome / Chromium yourself, or use
      the distroless OCI image:

        docker pull ghcr.io/sasuketorii/rev-stealth:#{version}

      For Claude Code / Cursor / Hermes integration see:
        https://sasuketorii.github.io/rev_scraping/
    EOS
  end

  test do
    # Sanity: the binary runs and reports a version.
    assert_match(/rev-stealth \d+\.\d+\.\d+/, shell_output("#{bin}/rev-stealth --version"))
    # Subcommand help works (covers clap wiring regression).
    assert_match("Usage:", shell_output("#{bin}/rev-stealth --help"))
  end
end
