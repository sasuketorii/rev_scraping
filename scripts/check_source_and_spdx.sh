#!/usr/bin/env bash
# Verify that every .rs file in crates/ has either a `// Source:` provenance
# header (for vendored code) or a `// SPDX-License-Identifier:` header in the
# first 5 lines. SPDX values are restricted to a project-approved whitelist.
#
# v1.1.0 (P10): tightened to reject unknown SPDX identifiers so a contributor
# cannot silently introduce GPL / AGPL / proprietary code via header text.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Permitted SPDX expressions. Mirrors deny.toml `licenses.allow`.
allowed_spdx_regex='^(MIT|Apache-2\.0|MIT OR Apache-2\.0|Apache-2\.0 OR MIT|BSD-3-Clause|BSD-2-Clause|ISC|Zlib|0BSD)$'

fail=0
while IFS= read -r f; do
    head_chunk="$(head -n 5 "$f" || true)"
    if grep -qE '^//\s*Source:' <<< "$head_chunk"; then
        # Vendored / provenance-tracked file — Source: header is sufficient.
        continue
    fi
    spdx_line="$(grep -E '^//\s*SPDX-License-Identifier:' <<< "$head_chunk" | head -n 1 || true)"
    if [ -z "$spdx_line" ]; then
        echo "MISSING header: $f"
        fail=1
        continue
    fi
    # Extract the expression after the colon, trim whitespace.
    spdx_value="$(sed -E 's|^//\s*SPDX-License-Identifier:\s*||; s|\s*$||' <<< "$spdx_line")"
    if ! grep -qE "$allowed_spdx_regex" <<< "$spdx_value"; then
        echo "DISALLOWED SPDX '$spdx_value' in: $f"
        fail=1
    fi
done < <(find crates -type f -name '*.rs')

if [ "$fail" -ne 0 ]; then
    echo "check_source_and_spdx: FAIL"
    exit 1
fi
echo "check_source_and_spdx: PASS"
