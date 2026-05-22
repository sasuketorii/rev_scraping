#!/usr/bin/env bash
# Lane I.1 — capture the rev-stealth CLI public surface as deterministic JSON.
#
# Output: .agent/v1.3/cli-public-api.snapshot.json
#
# Modes:
#   ./scripts/cli-public-api-snapshot.sh           # regenerate snapshot
#   ./scripts/cli-public-api-snapshot.sh --check   # exit 1 if drift detected
#
# Public-surface coverage (per v1.3 ExecPlan Lane I.1 + R2 expansion):
#   - every subcommand + nested subcommand (depth 1 & 2)
#   - every flag (long + short), default value, value-set when enum,
#     env-var binding (captured across wrapped help lines)
#   - every documented env var (REV_STEALTH_OBSCURA, REV_SCRAPING_*, etc.)
#   - every documented exit code from --help bodies (0/1/3/7/10)
#   - MCP tool surface (16 tools: names + required input-schema fields +
#     R2: input-schema enum constraints + output-schema top-level property
#     names + output-schema enum constraints sourced from
#     docs/json-schemas/<tool>.output.json)
#   - R2: full 26-variant ErrorKind closed-set (wire_name strings) extracted
#     from crates/stealth-agent-contracts/src/error.rs
#   - R2: every `#[deprecated]` attribute's `replace_with=…` (or "Use …" /
#     "Prefer …" / "replaced by …") replacement hint, indexed by source
#     path:line so silent removal of the replacement string is caught.
#   - rev-stealth --version string
#
# Schema version: R2 bumps `$schema_version` from 2 → 3 (additive — fields
# only appended). Snapshot consumers must re-parse on bump.
#
# Schema-stable JSON: keys sorted alphabetically at every level. Drift = any
# byte-level diff against the committed snapshot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_PATH=".agent/v1.3/cli-public-api.snapshot.json"
BIN="${REV_STEALTH_BIN:-./target/debug/rev-stealth}"

if [[ ! -x "$BIN" ]]; then
  echo "[snapshot] building stealth-cli (debug)..." >&2
  cargo build -p rev-stealth >&2
fi

# All top-level subcommands declared in the workspace today. We use `__` as the
# helpfile separator (never appears in clap subcommand names) so multi-hyphen
# commands like `cf-evaluate` survive round-tripping.
TOP_CMDS=(captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes)

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

"$BIN" --help > "$tmpdir/help__ROOT.txt" 2>&1 || true

for cmd in "${TOP_CMDS[@]}"; do
  "$BIN" "$cmd" --help > "$tmpdir/help__${cmd}.txt" 2>&1 || true
  awk '/^Commands:/{f=1;next} /^Options:/{f=0} f' "$tmpdir/help__${cmd}.txt" \
    | awk '{print $1}' \
    | { grep -Ev '^(help)?$' || true; } \
    | while read -r sub; do
        [[ -n "$sub" ]] || continue
        "$BIN" "$cmd" "$sub" --help \
          > "$tmpdir/help__${cmd}__${sub}.txt" 2>&1 || true
      done
done

VERSION_LINE="$("$BIN" --version 2>&1 | tr -d '\n')"

python3 - "$tmpdir" "$SNAPSHOT_PATH" "$VERSION_LINE" <<'PY'
import json, os, re, sys, subprocess
from pathlib import Path

tmpdir, snapshot_path, version_line = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = Path(tmpdir)

ENV_VARS = sorted([
    "REV_STEALTH_OBSCURA",
    "REV_SCRAPING_HOME",
    "REV_SCRAPING_POLICY",
    "REV_SCRAPING_AUTHORIZED",
    "REV_SCRAPING_AUTH_DIR",
    "REV_SCRAPING_AUTH_PASSPHRASE",
    "REV_SCRAPING_PROFILES_ROOT",
    "REV_SCRAPING_AUP_ACK",
    "REV_SCRAPING_CONFIG_LENIENT",
    "REV_SCRAPING_VPN_INSTANCES",
    "REV_SCRAPING_REQUIRE_VPN",
])

EXIT_CODES = {
    "0":  "success",
    "1":  "generic CLI / validation error",
    "3":  "permanent runtime failure (browser launch, VPS deploy readiness)",
    "7":  "doctor fail-closed (leak detected)",
    "10": "relocate Ambiguous result under --strict",
}

FLAG_RE = re.compile(r"--[a-zA-Z0-9][a-zA-Z0-9_-]*")
SHORT_RE = re.compile(r"(?<![-\w])-[a-zA-Z](?![-\w])")
ENV_RE = re.compile(r"\[env:\s*([A-Z0-9_]+)=")
DEFAULT_RE = re.compile(r"\[default:\s*([^\]]*)\]")
POSSIBLE_RE = re.compile(r"\[possible values:\s*([^\]]+)\]")

def parse_help(text):
    """Extract usage, flags (with multi-line continuation), nested cmds."""
    usage = ""
    nested = []
    raw_lines = text.splitlines()

    # Locate Options: / Commands: sections.
    sections = {}
    for idx, line in enumerate(raw_lines):
        s = line.strip()
        if s.startswith("Usage:"):
            usage = s[len("Usage:"):].strip()
        if s == "Options:":
            sections["options"] = idx
        elif s == "Commands:":
            sections["commands"] = idx

    # Nested subcommands: scan the Commands: block.
    if "commands" in sections:
        start = sections["commands"] + 1
        for line in raw_lines[start:]:
            stripped = line.strip()
            if not stripped or stripped.startswith("-") or stripped.endswith(":"):
                if stripped == "Options:" or stripped.endswith(":"):
                    break
                continue
            tok = stripped.split(None, 1)[0]
            if tok and tok != "help" and not tok.startswith("-"):
                nested.append(tok)

    # Flags: iterate Options: block. A flag spans from the line starting with
    # "--" (or "-X, --") until the next flag-introducing line OR a blank line
    # followed by a non-indented section header. We collect every continuation
    # line into the flag's "block" so [env:...], [default:...], and
    # [possible values:...] tokens are captured even when wrapped.
    flags_by_name = {}
    if "options" in sections:
        start = sections["options"] + 1
        # Detect indentation of a flag line: clap uses "      --flag" (6 spaces)
        # or "  -X, --flag". We treat any line whose stripped form begins with
        # "-" as a flag-start line.
        i = start
        while i < len(raw_lines):
            line = raw_lines[i]
            stripped = line.strip()
            if stripped == "Options:" or stripped == "Commands:":
                i += 1
                continue
            if stripped and stripped.startswith("-"):
                # Accumulate block until next flag-start or end.
                block_lines = [line]
                j = i + 1
                while j < len(raw_lines):
                    nxt = raw_lines[j]
                    nxt_stripped = nxt.strip()
                    if nxt_stripped.startswith("-") and (
                        FLAG_RE.search(nxt) or SHORT_RE.search(nxt)
                    ):
                        # Heuristic: next line is a new flag if it has -short
                        # or --long AND starts with a dash after the leading
                        # whitespace (clap convention).
                        # Guard against description text that begins with "-":
                        # require ≤ 8 leading spaces (clap flag-line indent).
                        leading = len(nxt) - len(nxt.lstrip(" "))
                        if leading <= 8:
                            break
                    block_lines.append(nxt)
                    j += 1
                block = "\n".join(block_lines)
                long_flags = sorted(set(FLAG_RE.findall(block_lines[0])))
                # Short forms only from the first line (clap puts both forms
                # on the head line, never wrapped).
                short_forms = sorted(set(SHORT_RE.findall(block_lines[0])))
                env_match = ENV_RE.search(block)
                default_match = DEFAULT_RE.search(block)
                possible_match = POSSIBLE_RE.search(block)
                for f in long_flags:
                    entry = {"flag": f}
                    if short_forms:
                        entry["short"] = short_forms[0]
                    if env_match:
                        entry["env"] = env_match.group(1)
                    if default_match:
                        entry["default"] = default_match.group(1).strip()
                    if possible_match:
                        entry["values"] = sorted(
                            v.strip() for v in possible_match.group(1).split(",")
                        )
                    prev = flags_by_name.get(f)
                    if not prev or len(entry) > len(prev):
                        flags_by_name[f] = entry
                i = j
            else:
                i += 1

    return {
        "usage": usage,
        "flags": sorted(flags_by_name.values(), key=lambda x: x["flag"]),
        "subcommands": sorted(set(nested)),
    }

root_help = parse_help((tmp / "help__ROOT.txt").read_text())

commands = {}
for help_file in sorted(tmp.glob("help__*.txt")):
    stem = help_file.stem.removeprefix("help__")
    if stem == "ROOT":
        continue
    if "__" in stem:
        cmd, sub = stem.split("__", 1)
    else:
        cmd, sub = stem, None
    commands.setdefault(cmd, {"help": {}, "subcommands": {}})
    parsed = parse_help(help_file.read_text())
    if sub is None:
        commands[cmd]["help"] = parsed
    else:
        commands[cmd]["subcommands"][sub] = parsed

# MCP tool surface — parse tools.rs for `name: "<tool>"` AND each
# tool's required-arg names. We extract the schema's "required" array as a
# best-effort proxy for the public input contract.
tools_src = Path("crates/stealth-mcp/src/tools.rs").read_text()
tool_names = sorted(set(re.findall(r'name:\s*"([a-z_][a-z0-9_]*)"', tools_src)))

# Extract required arrays by scanning ToolDefinition blocks. We look for the
# nearest "required": [...] literal after each name and parse strings out.
def extract_required(src, name):
    """Extract the top-level `"required": [...]` array of the tool's
    input_schema, bounded to *this* tool's block.

    Strategy: locate `name: "<name>"`, then bound the window from the next
    `input_schema: json!({` to the matching `})`. Inside that window, only the
    *first* `"required": [...]` after `"properties":` decreases nesting depth
    counts as the top-level required (nested object schemas may also use
    `"required"`, e.g. `recipe_propose_endpoint.properties.endpoint.required`).
    We approximate top-level by counting braces from the input_schema head
    and returning the required array whose surrounding brace-depth is 1.
    """
    m = re.search(r'name:\s*"' + re.escape(name) + r'"', src)
    if not m:
        return []
    tail = src[m.end():]
    # Find this tool's input_schema literal.
    js = re.search(r'input_schema:\s*json!\(\{', tail)
    if not js:
        return []
    start = js.end() - 1  # at the leading `{`
    depth = 0
    end = None
    for i in range(start, min(len(tail), start + 20000)):
        c = tail[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return []
    schema = tail[start:end + 1]
    # Walk through schema char-by-char; record every `"required": [...]` whose
    # surrounding depth is exactly 1 (i.e. immediate child of the root object).
    depth = 0
    i = 0
    candidates = []
    while i < len(schema):
        c = schema[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif c == '"' and schema[i:i+11] == '"required":' and depth == 1:
            # Found top-level required. Capture its array literal.
            arr = re.match(r'"required"\s*:\s*\[([^\]]*)\]', schema[i:])
            if arr:
                candidates.append(arr.group(1))
                i += arr.end()
                continue
        i += 1
    if not candidates:
        return []
    return sorted(set(re.findall(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', candidates[0])))

# R2: extract per-tool input-schema enum constraints (property → values).
# A narrowing of an enum's value-set (e.g. removing a `Pending` variant)
# is a breaking change for callers, so we capture the full {property:
# sorted([values])} map per tool. We parse the tool's input_schema block
# the same way `extract_required` does.
def extract_input_enums(src, name):
    m = re.search(r'name:\s*"' + re.escape(name) + r'"', src)
    if not m:
        return {}
    tail = src[m.end():]
    js = re.search(r'input_schema:\s*json!\(\{', tail)
    if not js:
        return {}
    start = js.end() - 1
    depth = 0
    end = None
    for i in range(start, min(len(tail), start + 20000)):
        c = tail[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return {}
    schema = tail[start:end + 1]
    # Walk properties looking for `"<prop>": { ... "enum": [...] ... }` at any
    # depth. Record property name + sorted values. We deliberately flatten
    # nesting (recipe_propose_endpoint.endpoint.method becomes "endpoint.method"
    # so a tightening anywhere is caught).
    enums = {}
    # Heuristic: scan `"enum": [ ... ]` literals and walk backwards from each
    # match to find the enclosing "<prop>": { context. Property nesting depth
    # is approximated by the brace-stack closest to the enum.
    for m_enum in re.finditer(r'"enum"\s*:\s*\[([^\]]*)\]', schema):
        values = sorted(set(re.findall(r'"([^"\\]*)"', m_enum.group(1))))
        if not values:
            continue
        # Walk back from the enum match for the nearest preceding
        # `"<prop>": {` at brace-depth 0 from the enum's standpoint.
        prefix = schema[: m_enum.start()]
        prop_match = list(re.finditer(r'"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:\s*\{', prefix))
        if not prop_match:
            continue
        prop_name = prop_match[-1].group(1)
        enums[prop_name] = values
    return enums


# R2: extract per-tool output-schema field names + enum constraints from
# docs/json-schemas/<tool>.output.json. The MCP layer references these via
# include_str!, so the file IS the source of truth for the response shape.
def extract_output_schema_summary(tool_name):
    p = Path(f"docs/json-schemas/{tool_name}.output.json")
    if not p.exists():
        return {"properties": [], "enums": {}, "required": []}
    try:
        schema = json.loads(p.read_text())
    except json.JSONDecodeError:
        return {"properties": [], "enums": {}, "required": []}

    props = schema.get("properties", {}) or {}
    top_level_props = sorted(props.keys())
    top_required = sorted(schema.get("required", []) or [])

    # Walk the schema recursively, recording any `enum` arrays we find at any
    # depth. Property path is dotted (e.g. "result.outcome", "result.diff.kind").
    enums = {}
    def walk(node, path):
        if isinstance(node, dict):
            if "enum" in node and isinstance(node["enum"], list):
                values = sorted(str(v) for v in node["enum"])
                enums[path or "<root>"] = values
            for k, v in node.items():
                if k == "properties" and isinstance(v, dict):
                    for prop, sub in v.items():
                        walk(sub, f"{path}.{prop}" if path else prop)
                elif k in ("items", "additionalProperties") and isinstance(v, dict):
                    walk(v, f"{path}.{k}")
                elif k == "oneOf" or k == "anyOf" or k == "allOf":
                    if isinstance(v, list):
                        for i, sub in enumerate(v):
                            walk(sub, f"{path}.{k}[{i}]")
        # Skip non-dict nodes — only object schemas can carry enums/properties.
    walk(schema, "")
    return {
        "properties": top_level_props,
        "required": top_required,
        "enums": {k: enums[k] for k in sorted(enums)},
    }


mcp_tool_schemas = {
    name: {
        "required": extract_required(tools_src, name),
        "input_enums": extract_input_enums(tools_src, name),
        "output": extract_output_schema_summary(name),
    }
    for name in tool_names
}

# R2: 26 ErrorKind variants. Parse the closed enum directly from
# crates/stealth-agent-contracts/src/error.rs. The enum is serialized via
# `#[serde(rename_all = "snake_case")]`, so we emit both the Rust variant
# names AND their wire (snake_case) forms — a rename in either direction is
# a breaking change.
def to_snake_case(camel):
    out = []
    for i, c in enumerate(camel):
        if c.isupper() and i > 0 and not camel[i - 1].isupper():
            out.append("_")
        out.append(c.lower())
    return "".join(out)


error_src = Path("crates/stealth-agent-contracts/src/error.rs").read_text()
# Locate `pub enum ErrorKind {` … matching `}`.
ek_match = re.search(r"pub enum ErrorKind\s*\{", error_src)
error_kinds: list[dict] = []
if ek_match:
    depth = 0
    start = ek_match.end() - 1
    end = None
    for i in range(start, len(error_src)):
        c = error_src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is not None:
        body = error_src[start + 1:end]
        # Strip doc comments + attributes; only collect variant identifiers.
        for raw in body.splitlines():
            line = raw.strip()
            if not line or line.startswith("//") or line.startswith("#["):
                continue
            tok = re.match(r"([A-Z][A-Za-z0-9]*)", line)
            if tok:
                variant = tok.group(1)
                error_kinds.append({
                    "variant": variant,
                    "wire_name": to_snake_case(variant),
                })
# Sort by variant name so the snapshot remains deterministic across reorderings
# of the enum body (the enum order is significant for human review but not
# for the public-surface contract; we sort the snapshot copy for stability).
error_kinds.sort(key=lambda d: d["variant"])

# R2: collect every `#[deprecated(...)]` attribute's replacement hint.
# Walk crates/*/src/ for .rs files (skipping tests/), regex each attribute,
# and record path:line:since:note:replace_with so a silent regression
# (someone removes the replacement string from the note) shows up as drift.
def collect_deprecated_attrs():
    found = []
    skip_dirs = {"target", "vendor", "_refs", "node_modules", ".git", "tests"}
    crates_root = Path("crates")
    for crate_dir in sorted(crates_root.iterdir()):
        src_dir = crate_dir / "src"
        if not src_dir.is_dir():
            continue
        for path in sorted(src_dir.rglob("*.rs")):
            if any(p in skip_dirs for p in path.parts):
                continue
            text = path.read_text()
            for m in re.finditer(r"#\[deprecated\b", text):
                # Find balanced parens — re-use the same approach as the
                # Rust test in crates/stealth-cli/tests/deprecated_completeness.rs.
                start = m.start()
                line_no = text[:start].count("\n") + 1
                # Skip bare `#[deprecated]` form for now (the Rust test rejects it).
                paren = text.find("(", start)
                if paren < 0 or paren - start > 16:
                    continue
                depth = 1
                i = paren + 1
                in_string = False
                escape = False
                while i < len(text) and depth > 0:
                    c = text[i]
                    if escape:
                        escape = False
                    elif in_string:
                        if c == "\\":
                            escape = True
                        elif c == '"':
                            in_string = False
                    else:
                        if c == '"':
                            in_string = True
                        elif c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                    i += 1
                block = text[paren + 1:i - 1]
                since = re.search(r'since\s*=\s*"([^"]*)"', block)
                note = re.search(r'note\s*=\s*"((?:[^"\\]|\\.)*)"', block)
                replace_with = None
                if note:
                    note_value = note.group(1)
                    # Recognized replacement-hint syntaxes (kept aligned
                    # with deprecated_completeness.rs::HINTS).
                    rw = re.search(r'replace_with\s*=\s*([^\s,;]+)', note_value)
                    if rw:
                        replace_with = rw.group(1).strip("`\"',.")
                    else:
                        use = re.search(r'(?:Use|use|Prefer|prefer|replaced by)\s+`?([A-Za-z0-9_:\.]+)', note_value)
                        if use:
                            replace_with = use.group(1)
                rel = path.as_posix()
                found.append({
                    "path": rel,
                    "line": line_no,
                    "since": since.group(1) if since else None,
                    "replace_with": replace_with,
                })
    found.sort(key=lambda d: (d["path"], d["line"]))
    return found


deprecated_attrs = collect_deprecated_attrs()

snapshot = {
    "$schema_version": 3,
    "binary_name": "rev-stealth",
    "version_string": version_line,
    "env_vars": ENV_VARS,
    "exit_codes": EXIT_CODES,
    "global": root_help,
    "commands": commands,
    "mcp_tools": {
        "count": len(tool_names),
        "names": tool_names,
        "schemas": mcp_tool_schemas,
    },
    "error_kinds": {
        "count": len(error_kinds),
        "variants": error_kinds,
    },
    "deprecated_attrs": deprecated_attrs,
    "_notes": [
        "Generated by scripts/cli-public-api-snapshot.sh. Do not edit by hand.",
        "Drift means a public-surface change. Rebuild + commit alongside the change",
        "and apply PR label api-additive / api-breaking / mcp-schema-breaking",
        "per docs/compat.md.",
        "Schema version 3 (R2): adds mcp_tools.schemas.*.input_enums,",
        "mcp_tools.schemas.*.output, error_kinds, and deprecated_attrs.",
    ],
}

out = Path(snapshot_path)
out.parent.mkdir(parents=True, exist_ok=True)
serialized = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
out.write_text(serialized)
print(f"[snapshot] wrote {snapshot_path} ({len(serialized)} bytes)")
print(f"[snapshot] commands={len(commands)} mcp_tools={len(tool_names)}")
PY

if [[ "${1:-}" == "--check" ]]; then
  # Drift gate semantics:
  #
  #   - If the snapshot exists in HEAD, the regenerated file must match what
  #     is committed/staged.
  #   - If the snapshot is brand new on this branch (not in HEAD, but staged
  #     for the first commit that introduces it), we accept it: the
  #     contributor is the one introducing the snapshot.
  #   - If the snapshot file isn't on disk at all after running the
  #     regenerator, something is badly wrong — exit 1.
  if [[ ! -f "$SNAPSHOT_PATH" ]]; then
    echo "[snapshot] ERROR: $SNAPSHOT_PATH missing after regeneration." >&2
    exit 1
  fi
  if git cat-file -e "HEAD:$SNAPSHOT_PATH" 2>/dev/null; then
    # Snapshot is in HEAD — compare working-tree against HEAD for drift.
    if ! git diff HEAD --quiet -- "$SNAPSHOT_PATH" 2>/dev/null; then
      echo "[snapshot] DRIFT — public surface changed without snapshot update." >&2
      git --no-pager diff HEAD -- "$SNAPSHOT_PATH" 2>/dev/null | head -200 >&2
      echo "" >&2
      echo "Rebuild with: ./scripts/cli-public-api-snapshot.sh" >&2
      echo "Then commit + apply PR label api-additive | api-breaking | mcp-schema-breaking." >&2
      exit 1
    fi
  else
    echo "[snapshot] note: $SNAPSHOT_PATH absent in HEAD (first PR introducing it). Accepting."
  fi
  echo "[snapshot] CLI public surface unchanged."
fi
