#!/usr/bin/env python3
"""Lane I R2 — keep-a-changelog 1.1 structural lint for CHANGELOG.rev_scraping.md.

Enforces the minimum structural contract release-please needs to find the
`Unreleased` cursor and parse released sections deterministically:

  * Exactly one `# Changelog…` H1 at the top of the file.
  * Exactly one `## [Unreleased]` section (case-sensitive).
  * Every released section header matches `## [<semver>] - <YYYY-MM-DD>`.
  * Sub-section headings (`### …`) inside every section are drawn from the
    keep-a-changelog vocabulary
    (Added / Changed / Deprecated / Removed / Fixed / Security / Breaking
    Changes) — Breaking Changes is project-allowed per docs/compat.md.

This is intentionally textual rather than AST-based: the file is the source
of truth for human reviewers, so a stable text-level lint matches how the
file is actually authored. The release-please tool itself does deeper
parsing at release time; this lint runs on every PR to fail closed *before*
release-please attempts to read a malformed file.

Exit codes:
  0 ok
  1 structural violation
  2 IO / argument error
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ALLOWED_SUBSECTIONS = {
    # keep-a-changelog 1.1 canonical vocabulary.
    "Added",
    "Changed",
    "Deprecated",
    "Removed",
    "Fixed",
    "Security",
    # docs/compat.md project extension.
    "Breaking Changes",
    # Project-allowed prose-style headings that release-please ignores but
    # human reviewers use. Listed explicitly so a typo is still caught.
    "Notes",
    # release-please-generated section names (from
    # release-please-config.json::changelog-sections). Kept in sync with
    # that config so a release-please-authored CHANGELOG section does not
    # fail this lint. Update both files together.
    "Features",
    "Bug Fixes",
    "Performance",
    "Dependencies",
    "Documentation",
    "Refactoring",
    "Tests",
    "Continuous Integration",
    "Build System",
    "Chores",
}

SEMVER_DATE = re.compile(
    r"^## \[(?P<ver>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\] - "
    r"(?P<date>\d{4}-\d{2}-\d{2})\s*$"
)
UNRELEASED = re.compile(r"^## \[Unreleased\]\s*$")
H1 = re.compile(r"^# Changelog( —.+)?\s*$")
SUBSECTION = re.compile(r"^### (?P<title>[^\n]+?)\s*$")


def lint(path: Path) -> list[str]:
    errs: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [f"{path}: cannot read ({exc})"]

    if not lines:
        return [f"{path}: empty file"]

    if not H1.match(lines[0]):
        errs.append(
            f"{path}:1: first line must be `# Changelog` "
            f"(optionally `# Changelog — <subtitle>`); got: {lines[0]!r}"
        )

    h1_count = sum(1 for ln in lines if ln.startswith("# ") and not ln.startswith("## "))
    if h1_count != 1:
        errs.append(f"{path}: expected exactly 1 H1, found {h1_count}")

    unreleased_count = sum(1 for ln in lines if UNRELEASED.match(ln))
    if unreleased_count != 1:
        errs.append(
            f"{path}: expected exactly 1 `## [Unreleased]` cursor, found "
            f"{unreleased_count}. release-please needs this to compute the "
            f"next bump; keep-a-changelog 1.1 also mandates it."
        )

    # Per-section title vocabulary + version-line shape.
    in_section = False
    section_line = 0
    for idx, ln in enumerate(lines, start=1):
        if ln.startswith("## ") and not ln.startswith("### "):
            if UNRELEASED.match(ln):
                in_section = True
                section_line = idx
                continue
            if SEMVER_DATE.match(ln):
                in_section = True
                section_line = idx
                continue
            # Any other `## ...` heading is a structural error.
            errs.append(
                f"{path}:{idx}: H2 section header must be `## [Unreleased]` or "
                f"`## [<semver>] - <YYYY-MM-DD>`; got {ln!r}"
            )
            in_section = False
        elif ln.startswith("### "):
            if not in_section:
                errs.append(
                    f"{path}:{idx}: `### …` sub-section appears before any "
                    f"`## …` section header"
                )
            m = SUBSECTION.match(ln)
            if not m:
                continue
            title = m.group("title").strip()
            # Allow `### <Allowed> — <suffix>` form (em-dash subtitle).
            primary = re.split(r"\s+[—-]\s+", title, maxsplit=1)[0].strip()
            if primary not in ALLOWED_SUBSECTIONS:
                errs.append(
                    f"{path}:{idx}: sub-section `{primary}` is not in the "
                    f"keep-a-changelog vocabulary "
                    f"({sorted(ALLOWED_SUBSECTIONS)}); section starts at "
                    f"line {section_line}"
                )

    return errs


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: changelog-keepachangelog-lint.py <path> [<path>...]", file=sys.stderr)
        return 2
    all_errs: list[str] = []
    for raw in argv[1:]:
        all_errs.extend(lint(Path(raw)))
    if all_errs:
        for e in all_errs:
            print(f"::error::{e}", file=sys.stderr)
        print(
            f"\nchangelog lint failed ({len(all_errs)} issue(s)). See "
            f"docs/compat.md and CHANGELOG.rev_scraping.md preamble.",
            file=sys.stderr,
        )
        return 1
    print("changelog lint OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
