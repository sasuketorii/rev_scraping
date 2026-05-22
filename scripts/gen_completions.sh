#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Source: RevHarness — Lane G.3 (v1.3 Black-Belt CLI).
#
# Regenerate the committed shell-completion scripts under
# `target/completions/{bash,zsh,fish,nushell}/`. The drift between regen and
# committed is gated by the `completion-drift` job in `.github/workflows/ci.yml`.
#
# The generator goes through the canonical clap CommandFactory by invoking the
# (hidden) `rev-stealth completions <shell>` subcommand. We deliberately avoid
# spawning the stub `target/debug/rev-stealth` rename target produced by other
# build-fixup paths — `cargo run --bin rev-stealth` always picks the real
# stealth-cli binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="target/completions"

# Map of shell -> output file extension. Keep declaration order stable so the
# generated tree is deterministic across machines.
SHELLS=(bash zsh fish nushell)
declare -A EXT=(
  [bash]="bash"
  [zsh]="zsh"
  [fish]="fish"
  [nushell]="nu"
)

mkdir -p "$OUT_DIR"

for sh in "${SHELLS[@]}"; do
  mkdir -p "$OUT_DIR/$sh"
  ext="${EXT[$sh]}"
  out="$OUT_DIR/$sh/rev-stealth.$ext"
  # `cargo run -q` keeps cargo status chatter out of the generated file.
  # Redirect cargo's own stderr too — any compile noise would otherwise leak
  # into the diff and the CI gate would chase a phantom drift.
  cargo run -q --bin rev-stealth -- completions "$sh" >"$out" 2>/dev/null
done

echo "regenerated $OUT_DIR/{bash,zsh,fish,nushell}/rev-stealth.*"
