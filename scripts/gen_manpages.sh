#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Source: RevHarness — Lane G.8 (v1.3 Black-Belt CLI).
#
# Regenerate the committed roff(7) man(1) pages under `target/man/man1/`.
# The drift between regen and committed is gated by the `manpage-drift`
# job in `.github/workflows/ci.yml`.
#
# The generator goes through the canonical clap CommandFactory by invoking
# the (hidden) `rev-stealth manpages <output-dir>` subcommand. We
# deliberately avoid spawning the stub `target/debug/rev-stealth` rename
# target produced by other build-fixup paths — `cargo run --bin rev-stealth`
# always picks the real stealth-cli binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="target/man/man1"

# Wipe the directory first so a renamed-or-removed subcommand does not
# leave a stale .1 file behind. The CI drift gate's
# `git status --porcelain` step would catch the orphan, but failing fast
# locally with a clean tree is friendlier than a CI red diff.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# `cargo run -q` keeps cargo status chatter out of the generator output.
# The hidden `manpages` subcommand writes files directly; the CLI's own
# stderr summary line is suppressed to keep this script's stdout/stderr
# clean for CI log parsing.
cargo run -q --bin rev-stealth -- manpages "$OUT_DIR" 2>/dev/null

count="$(find "$OUT_DIR" -name '*.1' -type f | wc -l | tr -d ' ')"
echo "regenerated $count man page(s) under $OUT_DIR/"
