#!/usr/bin/env bash
# PoC: ensure no goscrapy (BSL-licensed) source has been vendored,
# and grep for suspiciously long literal blocks that might be verbatim ports.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -d "_refs/goscrapy" ]; then
    echo "BSL contamination risk: _refs/goscrapy exists. goscrapy is design-reference only."
    exit 1
fi

# Heuristic: warn on >200-char single-line string literals in any .rs under crates/
hits=$(grep -RhnoE '"[^"]{200,}"' crates/ 2>/dev/null | wc -l | tr -d ' ' || true)
hits="${hits:-0}"
if [ "$hits" != "0" ]; then
    echo "BSL contamination heuristic flagged $hits long literal(s) >200 chars; review manually."
    grep -RnE '"[^"]{200,}"' crates/ || true
    # PoC stage: warn only, do not fail.
fi

echo "check_bsl_contamination: PASS (PoC)"
