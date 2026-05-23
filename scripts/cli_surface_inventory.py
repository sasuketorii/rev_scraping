#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
cli_surface_inventory.py — Lane G.1

Walk the `rev-stealth` CLI help tree and emit a machine-readable JSON
inventory of every sub-command, flag, positional, and exit code.

Designed to be deterministic so CI can diff it as a drift gate.

Usage:
    scripts/cli_surface_inventory.py \\
        --bin ./target/debug/rev-stealth \\
        --out .agent/v1.3/cli-surface.json

The schema is intentionally simple (see `SCHEMA_VERSION`) so downstream
G.2 (--help dictionary lint) and G.3 (completion drift gate) can reuse it.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from typing import Optional

SCHEMA_VERSION = "1.1"

# Workspace-canonical exit-code contract (stealth_core::ExitCode).
# This is the SOURCE OF TRUTH the inventory pins; CI drift gate fails if any
# value here drifts from the Rust enum.  G.7 (unified error template) and the
# G.2 per-command --help dictionary will both reference these.
EXIT_CODES: list[dict] = [
    {"code": 0, "name": "Ok",              "rust_variant": "ExitCode::Ok",
     "description": "Success."},
    {"code": 1, "name": "UserError",       "rust_variant": "ExitCode::UserError",
     "description": "User input error (bad args / bad config)."},
    {"code": 2, "name": "TransientError",  "rust_variant": "ExitCode::TransientError",
     "description": "Transient failure (retryable: network / VPN flap)."},
    {"code": 3, "name": "PermanentError",  "rust_variant": "ExitCode::PermanentError",
     "description": "Permanent failure (unsupported / not implemented / fatal)."},
    {"code": 4, "name": "AuthExpired",     "rust_variant": "ExitCode::AuthExpired",
     "description": "Stored authentication is missing, expired, or unusable (Phase 9a)."},
    {"code": 7, "name": "Leak",            "rust_variant": "ExitCode::Leak",
     "description": "Fail-closed: VPN / DNS / IPv6 / WebRTC leak detected (Phase 6c)."},
]

# Per-command exit-code surface.  A command lists the SUBSET of EXIT_CODES it
# can emit, sourced from `crates/stealth-cli/src/main.rs` module header +
# the per-command run() return paths.  This is the machine-readable mapping
# G.2 / G.7 / man-page generation will consume.
COMMAND_EXIT_CODES: dict[str, list[int]] = {
    # path key uses space-joined node path; "" = root (not applicable)
    "captcha":              [0, 1, 2, 3],
    "captcha solve":        [0, 1, 2, 3],
    "captcha verify":       [0, 1, 2, 3],
    "browser":              [0, 1, 2, 3],
    "browser launch":       [0, 1, 2, 3],
    "browser stealth-test": [0, 1, 2, 3],
    "vpn":                  [0, 1, 2, 3, 7],
    "vpn rotate":           [0, 1, 2, 3, 7],
    "vpn status":           [0, 1, 2, 3, 7],
    "doctor":               [0, 1, 7],
    "spider":               [0, 1, 2, 3, 4, 7],
    "relocate":             [0, 1, 3],
    "cf-evaluate":          [0, 1, 2, 3],
    "auth":                 [0, 1, 3, 4],
    "auth login":           [0, 1, 3, 4],
    "auth list":            [0, 1, 3],
    "auth show":            [0, 1, 3],
    "auth delete":          [0, 1, 3],
    "auth status":          [0, 1, 3, 4],
    "auth refresh":         [0, 1, 3, 4],
    "measure":              [0, 1, 2, 3],
    "config":               [0, 1, 3],
    "config show":          [0, 1, 3],
    "config paths":         [0, 1, 3],
    "config validate":      [0, 1, 3],
    "config diff":          [0, 1, 3],
    "config get":           [0, 1, 3],
    "config set":           [0, 1, 3],
    "config edit":          [0, 1, 3],
    "config migrate":       [0, 1, 3],
    "config init":          [0, 1, 3],
    "config history":       [0, 1, 3],
    "config rollback":      [0, 1, 3],
    "config gc":            [0, 1, 3],
    "config profile":               [0, 1, 3],
    "config profile list":          [0, 1, 3],
    "config profile create":        [0, 1, 3],
    "config profile switch":        [0, 1, 3],
    "config profile delete":        [0, 1, 3],
    "hermes":               [0, 1, 3],
    "hermes install":       [0, 1, 3],
    "hermes uninstall":     [0, 1, 3],
    "hermes verify":        [0, 1, 3],
}

# Top-of-help lines clap emits we want to skip when scraping description.
_USAGE_RE = re.compile(r"^Usage:\s+")
_COMMANDS_HDR = re.compile(r"^Commands:\s*$")
_OPTIONS_HDR = re.compile(r"^Options:\s*$")
_ARGS_HDR = re.compile(r"^Arguments:\s*$")

# clap flag lines look like:
#   "  -f, --format <FORMAT>     Output format [default: human] [possible values: ...]"
#   "      --skip-exit-ip        Skip exit IP check"
_FLAG_RE = re.compile(
    r"""^\s+
        (?:(-[A-Za-z]),\s+)?       # optional short flag (group 1)
        (--[A-Za-z0-9][A-Za-z0-9\-]*)   # long flag (group 2)
        (\s+<[^>]+>)?              # optional value placeholder (group 3)
        (\.\.\.)?                  # optional repeating indicator
        (?:\s{2,}(.*))?$           # description tail (group 5)
    """,
    re.VERBOSE,
)

# Subcommand row in clap "Commands:" block:
#   "  vpn          VPN IP rotation operations ..."
_SUBCMD_RE = re.compile(r"^\s{2,}([a-z][a-z0-9\-]*)\s{2,}(.*)$")

# Positional argument line:
#   "  <URL>   Target URL"
_POSARG_RE = re.compile(r"^\s+<([A-Z_][A-Z0-9_]*)>\s{2,}(.*)$")


@dataclass
class Flag:
    long: str
    short: Optional[str] = None
    takes_value: bool = False
    value_name: Optional[str] = None
    description: str = ""


@dataclass
class Positional:
    name: str
    description: str = ""


@dataclass
class CommandNode:
    path: list[str]                       # e.g. ["captcha", "solve"]
    description: str = ""
    flags: list[Flag] = field(default_factory=list)
    positionals: list[Positional] = field(default_factory=list)
    subcommands: list["CommandNode"] = field(default_factory=list)
    exit_codes: list[int] = field(default_factory=list)  # subset of EXIT_CODES


def _run_help(bin_path: str, path: list[str]) -> str:
    cmd = [bin_path, *path, "--help"]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    # clap prints --help to stdout (exit 0). If non-zero, surface it.
    if res.returncode != 0 and not res.stdout:
        sys.stderr.write(
            f"error: `{' '.join(cmd)}` exited {res.returncode}: {res.stderr.strip()}\n"
        )
        sys.exit(2)
    return res.stdout


def _parse_help(text: str) -> tuple[str, list[Flag], list[Positional], list[tuple[str, str]]]:
    """Return (description, flags, positionals, subcommand_rows)."""
    lines = text.splitlines()
    description_lines: list[str] = []
    flags: list[Flag] = []
    positionals: list[Positional] = []
    subs: list[tuple[str, str]] = []

    section: Optional[str] = "description"

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            # blank line — only meaningful as a section break
            continue
        if _USAGE_RE.match(line):
            section = None
            continue
        if _COMMANDS_HDR.match(line):
            section = "commands"
            continue
        if _OPTIONS_HDR.match(line):
            section = "options"
            continue
        if _ARGS_HDR.match(line):
            section = "args"
            continue

        if section == "description":
            description_lines.append(line.strip())
        elif section == "commands":
            m = _SUBCMD_RE.match(line)
            if m:
                name, desc = m.group(1), m.group(2).strip()
                if name == "help":
                    # clap-auto-generated; skip
                    continue
                subs.append((name, desc))
        elif section == "options":
            m = _FLAG_RE.match(line)
            if m:
                short = m.group(1)
                long_ = m.group(2)
                value_blob = m.group(3)
                desc = (m.group(5) or "").strip()
                value_name = None
                takes_value = False
                if value_blob:
                    takes_value = True
                    vn = value_blob.strip().lstrip("<").rstrip(">")
                    value_name = vn
                flags.append(
                    Flag(
                        long=long_,
                        short=short,
                        takes_value=takes_value,
                        value_name=value_name,
                        description=desc,
                    )
                )
            else:
                # Continuation line of previous flag description.
                if flags and line.strip():
                    flags[-1].description = (flags[-1].description + " " + line.strip()).strip()
        elif section == "args":
            m = _POSARG_RE.match(line)
            if m:
                positionals.append(Positional(name=m.group(1), description=m.group(2).strip()))

    desc = " ".join(description_lines).strip()
    return desc, flags, positionals, subs


def walk(bin_path: str, path: list[str]) -> CommandNode:
    text = _run_help(bin_path, path)
    desc, flags, positionals, subs = _parse_help(text)
    key = " ".join(path)
    node = CommandNode(
        path=path,
        description=desc,
        flags=flags,
        positionals=positionals,
        exit_codes=list(COMMAND_EXIT_CODES.get(key, [])),
    )
    for name, _row_desc in subs:
        node.subcommands.append(walk(bin_path, [*path, name]))
    return node


def _node_to_dict(node: CommandNode) -> dict:
    return {
        "path": node.path,
        "description": node.description,
        "flags": [asdict(f) for f in node.flags],
        "positionals": [asdict(p) for p in node.positionals],
        "exit_codes": node.exit_codes,
        "subcommands": [_node_to_dict(c) for c in node.subcommands],
    }


def _flatten(node: CommandNode, acc: list[CommandNode]) -> None:
    acc.append(node)
    for c in node.subcommands:
        _flatten(c, acc)


# --------- Naming-consistency lints (G.1 deliverable side-channel) ---------

# RevHarness CLI convention: `rev-stealth <noun> <verb>` (kebab-case).
_KEBAB = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")


def lint_naming(root: CommandNode) -> list[dict]:
    issues: list[dict] = []
    flat: list[CommandNode] = []
    _flatten(root, flat)
    for n in flat:
        if not n.path:
            continue  # root
        leaf = n.path[-1]
        if not _KEBAB.match(leaf):
            issues.append({
                "kind": "non-kebab-name",
                "path": n.path,
                "leaf": leaf,
                "note": "command name should be kebab-case",
            })
        # Depth check: encourage <noun> <verb> shape (2 levels under root)
        # Top-level commands w/ no subcommands are allowed (e.g. doctor),
        # but flag them informationally so reviewer can confirm.
        if len(n.path) == 1 and not n.subcommands:
            issues.append({
                "kind": "info-flat-top-level",
                "path": n.path,
                "note": "top-level leaf command (no <verb> level); confirm intentional",
            })

    # Flag-shape lint: all long flags kebab-case
    for n in flat:
        for f in n.flags:
            long = f.long.lstrip("-")
            if not _KEBAB.match(long):
                issues.append({
                    "kind": "non-kebab-flag",
                    "path": n.path,
                    "flag": f.long,
                    "note": "long flag should be kebab-case",
                })
    return issues


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="./target/debug/rev-stealth")
    ap.add_argument("--out", default=".agent/v1.3/cli-surface.json")
    ap.add_argument("--lint-out", default=".agent/v1.3/cli-naming-lint.json")
    # v1.3 Lane G fix-up R2 — Delta 4: drift-gate mode.
    #
    # When `--check` is passed, the script re-runs the same walk + payload
    # computation but does NOT overwrite the on-disk inventory. Instead it
    # compares the freshly-computed payload against the committed
    # `--out` / `--lint-out` files and exits non-zero (with a unified diff
    # on stderr) if either has drifted. This is the gate the `cli-surface-drift`
    # GitHub Actions job consumes.
    #
    # Operator workflow:
    #   * local: `cargo build --release --bin rev-stealth` then
    #     `scripts/cli_surface_inventory.py` (no flag) to regenerate.
    #   * CI:    same build, then `scripts/cli_surface_inventory.py --check`.
    ap.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the live CLI tree diverges from the committed "
             "inventory file (drift-gate mode; does NOT write outputs).",
    )
    args = ap.parse_args()

    root = walk(args.bin, [])
    # Detect any path missing from the exit-code mapping (drift gate).
    flat_pre: list[CommandNode] = []
    _flatten(root, flat_pre)
    missing_exit_codes = sorted(
        " ".join(n.path) for n in flat_pre
        if n.path and not n.exit_codes
    )

    payload = {
        "schema_version": SCHEMA_VERSION,
        "binary": "rev-stealth",
        "exit_code_dictionary": EXIT_CODES,
        "exit_code_coverage": {
            "total_commands": sum(1 for n in flat_pre if n.path),
            "mapped_commands": sum(1 for n in flat_pre if n.path and n.exit_codes),
            "missing": missing_exit_codes,
        },
        "root": _node_to_dict(root),
    }
    if missing_exit_codes:
        sys.stderr.write(
            "warning: commands missing from COMMAND_EXIT_CODES mapping "
            f"({len(missing_exit_codes)}): {missing_exit_codes}\n"
        )

    lints = lint_naming(root)
    lint_payload = {
        "schema_version": SCHEMA_VERSION,
        "issues": lints,
        "issue_count": len(lints),
    }

    # Canonical serialised form. Reused by both the write and the
    # `--check` drift-gate path so the on-disk format is byte-identical.
    payload_text = json.dumps(payload, indent=2, sort_keys=False) + "\n"
    lint_text = json.dumps(lint_payload, indent=2) + "\n"

    if args.check:
        # v1.3 Lane G fix-up R2 — Delta 4: drift gate.
        #
        # Diff each freshly-computed artifact against the committed copy
        # under .agent/v1.3/. Print a unified diff on drift and exit 1.
        import difflib
        rc = 0
        for label, path, fresh in (
            ("cli-surface", args.out, payload_text),
            ("cli-naming-lint", args.lint_out, lint_text),
        ):
            try:
                with open(path, "r") as fh:
                    committed = fh.read()
            except FileNotFoundError:
                sys.stderr.write(
                    f"[drift] {label}: committed artifact missing at {path}\n"
                )
                rc = 1
                continue
            if committed != fresh:
                rc = 1
                diff = difflib.unified_diff(
                    committed.splitlines(keepends=True),
                    fresh.splitlines(keepends=True),
                    fromfile=f"committed: {path}",
                    tofile=f"fresh:     {path}",
                    n=3,
                )
                sys.stderr.write(f"[drift] {label}: regenerated payload differs from {path}\n")
                sys.stderr.writelines(diff)
                sys.stderr.write("\n")
        if rc == 0:
            sys.stdout.write("cli-surface-drift: OK (no drift)\n")
        else:
            sys.stderr.write(
                "cli-surface-drift: FAIL — run "
                "`cargo build --release --bin rev-stealth && "
                "scripts/cli_surface_inventory.py` to regenerate, then commit.\n"
            )
        return rc

    with open(args.out, "w") as fh:
        fh.write(payload_text)
    with open(args.lint_out, "w") as fh:
        fh.write(lint_text)

    # Summarize to stdout for CI logs.
    flat: list[CommandNode] = []
    _flatten(root, flat)
    sys.stdout.write(
        f"cli-surface: {len(flat) - 1} command nodes inventoried "
        f"(excluding root) → {args.out}\n"
    )
    sys.stdout.write(f"cli-naming-lint: {len(lints)} issues → {args.lint_out}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
