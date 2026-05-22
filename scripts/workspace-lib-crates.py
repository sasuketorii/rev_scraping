#!/usr/bin/env python3
"""Lane I R2 — emit the sorted unique list of workspace lib crates.

Reads `cargo metadata --no-deps --format-version=1` from stdin and prints
one crate name per line, sorted. A crate is included when at least one of
its targets has kind `lib`, `rlib`, or `proc-macro`. Pure binary crates
(only `bin` targets) are excluded because cargo-public-api silently
ignores them.

This is a thin helper for the `cargo-public-api-diff` CI job so it does
not have to embed multi-line Python inside a YAML `run: |` block (an
inline heredoc would terminate the block under literal-block indent
rules — see Codex Sub-phase A round 1 / round 2 findings).
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        meta = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"::error::workspace-lib-crates: invalid cargo metadata JSON: {exc}", file=sys.stderr)
        return 1

    out: set[str] = set()
    for pkg in meta.get("packages", []):
        for tgt in pkg.get("targets", []):
            kinds = tgt.get("kind", [])
            if any(k in ("lib", "rlib", "proc-macro") for k in kinds):
                out.add(pkg["name"])
                break

    for name in sorted(out):
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
