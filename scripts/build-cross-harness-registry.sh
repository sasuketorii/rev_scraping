#!/usr/bin/env bash
# build-cross-harness-registry.sh
#
# Task: skill-audit/phase12 S-1 (agreed_strategy_3harness.md §2 S-1)
#
# Walks the four skill locations (3 canonical harnesses + user shelf) and emits
# cross_harness_projection_registry.json describing, per SKILL.md:
#   - full SHA256
#   - frontmatter-stripped SHA256 (body after the leading `---...---` block)
#   - description char length
#   - resolved source_harness (via ownership map, "closest specialist wins")
#   - projected_sha256 (user-shelf SHA if present, else null)
#   - projection_kind: byte-for-byte | partial-capped | manual/unknown
#   - domain + managed flag
#
# READ-ONLY against all SKILL.md files. Never edits / archives / moves a skill.
# Writes ONLY the registry JSON under rev_harness/.agent/registry/.
#
# macOS/Linux compatible (shasum -a 256 / sha256sum auto-detect).
set -euo pipefail

# --- paths -------------------------------------------------------------------
# Resolve rev_harness root from this script's location (no home-dir absolute
# paths baked in; keeps the path-leak guard happy and the script portable).
REV_HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Sibling harnesses live next to rev_harness under the same parent dir.
DEV_ROOT="$(dirname "$REV_HARNESS_ROOT")"
OWNERSHIP_MAP="${REV_HARNESS_ROOT}/.agent/registry/cross_harness_skill_ownership.json"
OUT="${REV_HARNESS_ROOT}/.agent/registry/cross_harness_projection_registry.json"

declare -a HARNESS_NAMES=("rev_harness" "rev_marketing_harness" "rev_textsocialharness")
declare -a HARNESS_PATHS=(
  "${REV_HARNESS_ROOT}/.claude/skills"
  "${DEV_ROOT}/rev_marketing_harness/.claude/skills"
  "${DEV_ROOT}/rev_textsocialharness/.claude/skills"
)
USER_SHELF="${HOME}/.claude/skills"

# --- sha helper (cross-platform) --------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
  sha256_stdin() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
  sha256_stdin() { shasum -a 256 | awk '{print $1}'; }
else
  echo "ERROR: neither sha256sum nor shasum found" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 2; }

# --- delegate the heavy lifting to python3 for safe JSON + frontmatter strip --
export OWNERSHIP_MAP OUT USER_SHELF
export HARNESS_NAMES_CSV="$(IFS=,; echo "${HARNESS_NAMES[*]}")"
export HARNESS_PATHS_CSV="$(IFS=,; echo "${HARNESS_PATHS[*]}")"

python3 - <<'PY'
import os, sys, json, hashlib, re, datetime

ownership_path = os.environ["OWNERSHIP_MAP"]
out_path = os.environ["OUT"]
user_shelf = os.environ["USER_SHELF"]
hnames = os.environ["HARNESS_NAMES_CSV"].split(",")
hpaths = os.environ["HARNESS_PATHS_CSV"].split(",")

ownership = {}
if os.path.isfile(ownership_path):
    with open(ownership_path, "r", encoding="utf-8") as f:
        ownership = json.load(f)

def full_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()

FM = re.compile(r"^---\s*\n.*?\n---\s*\n", re.DOTALL)

def stripped_sha_and_desc(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    body = FM.sub("", text, count=1) if text.startswith("---") else text
    sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
    # parse description length from frontmatter
    desc_len = 0
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    if m:
        fm = m.group(1)
        dm = re.search(r"^description:\s*(.*)$", fm, re.MULTILINE)
        if dm:
            val = dm.group(1).strip()
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            desc_len = len(val)
    return sha, desc_len

# collect canonical harness presence: skill -> {harness: {path, full, stripped}}
canon = {}   # skill -> harness -> dict
for hn, hp in zip(hnames, hpaths):
    if not os.path.isdir(hp):
        continue
    for d in sorted(os.listdir(hp)):
        sk = os.path.join(hp, d, "SKILL.md")
        if not os.path.isfile(sk):
            continue
        fs = full_sha(sk)
        ss, dl = stripped_sha_and_desc(sk)
        # Harness-root-relative path (no home-dir absolute leak). Source
        # harness is named separately, so source_harness + relpath fully
        # resolves the canonical SKILL.md location.
        relpath = os.path.join(".claude", "skills", d, "SKILL.md")
        canon.setdefault(d, {})[hn] = {
            "relpath": relpath, "full": fs, "stripped": ss, "desc_len": dl,
        }

# collect user shelf
shelf = {}   # skill -> dict
if os.path.isdir(user_shelf):
    for d in sorted(os.listdir(user_shelf)):
        sk = os.path.join(user_shelf, d, "SKILL.md")
        if not os.path.isfile(sk):
            continue
        fs = full_sha(sk)
        ss, dl = stripped_sha_and_desc(sk)
        shelf[d] = {"path": sk, "full": fs, "stripped": ss, "desc_len": dl}

def resolve_source_harness(skill, harnesses_present):
    """closest-specialist-wins via ownership map; fallback to sole presence."""
    ent = ownership.get(skill)
    if ent and ent.get("canonical_base") in hnames:
        return ent["canonical_base"], True
    if len(harnesses_present) == 1:
        return harnesses_present[0], True
    # multiple harnesses but no ownership entry -> unknown, unmanaged
    return "unknown", False

def domain_for(skill, source_harness):
    ent = ownership.get(skill)
    if ent and ent.get("domain"):
        return ent["domain"]
    # heuristic fallback by prefix
    if skill.endswith("-knowledge-pack") or skill in ("rust-skills-knowledge-pack","go-skills-knowledge-pack","typescript-skills-knowledge-pack"):
        return "dev"
    if skill.startswith(("system-planner","review-workflow","staff-code-reviewer","auto-orchestrator","research-handoff")) or skill.endswith("-deploy-guard"):
        return "dev"
    if skill.startswith(("launch-","copy-","psychology-","ops-")):
        return "marketing"
    if skill.startswith("channel-") or skill in ("x-kobun","threads-kobun"):
        return "social"
    if skill == "satori-kobun":
        return "marketing"
    return "other"

# union of all skill names seen anywhere (canonical or shelf)
all_skills = sorted(set(canon.keys()) | set(shelf.keys()))

records = []
for skill in all_skills:
    present = sorted(canon.get(skill, {}).keys())
    src_harness, managed_by_resolution = resolve_source_harness(skill, present) if present else ("unknown", False)

    source_relpath = None
    source_full = None
    source_stripped = None
    desc_len = 0
    if src_harness in canon.get(skill, {}):
        c = canon[skill][src_harness]
        source_relpath = c["relpath"]; source_full = c["full"]; source_stripped = c["stripped"]; desc_len = c["desc_len"]
    elif present:
        # fall back to first present harness for relpath/sha if resolution gave unknown
        c = canon[skill][present[0]]
        source_relpath = c["relpath"]; source_full = c["full"]; source_stripped = c["stripped"]; desc_len = c["desc_len"]

    sh = shelf.get(skill)
    projected_sha = sh["full"] if sh else None

    # projection_kind + managed
    #
    # Determination is frontmatter-stripped-SHA based (S-3/S-4 strengthening):
    #   - shelf stripped SHA == resolved-source stripped SHA:
    #       * full SHA also equal              -> "byte-for-byte"
    #       * full SHA differs (desc-only diff,
    #         e.g. capped/stripped frontmatter) -> "partial-capped"
    #   - shelf stripped SHA != any canonical   -> "manual/unknown"
    #
    # "resolved source" is the ownership-map canonical_base when it pins one;
    # otherwise we fall back to matching the shelf body against ANY canonical
    # harness body so a sole-present skill still resolves.
    if sh is None:
        # not on user shelf -> registry tracks canonical only; managed iff resolved
        projection_kind = "manual/unknown" if src_harness == "unknown" else "byte-for-byte"
        managed = managed_by_resolution and src_harness != "unknown"
    else:
        # Prefer the resolved source harness for the stripped-SHA comparison.
        resolved = canon.get(skill, {}).get(src_harness)
        body_match_harness = None
        full_match_harness = None
        if resolved is not None and resolved["stripped"] == sh["stripped"]:
            body_match_harness = src_harness
            if resolved["full"] == sh["full"]:
                full_match_harness = src_harness
        else:
            # Fall back: scan all canonical harnesses for a body (stripped) match.
            for hn, c in canon.get(skill, {}).items():
                if c["full"] == sh["full"]:
                    body_match_harness = hn
                    full_match_harness = hn
                    break
                if body_match_harness is None and c["stripped"] == sh["stripped"]:
                    body_match_harness = hn

        if body_match_harness is not None and full_match_harness is not None:
            projection_kind = "byte-for-byte"
            managed = True
        elif body_match_harness is not None:
            # body identical, frontmatter differs -> capped/stripped projection.
            projection_kind = "partial-capped"
            managed = True
        else:
            # shelf body differs from every canonical (fork / hand-edit)
            # A-arbitration: mixed until proven -> manual/unknown, unmanaged
            projection_kind = "manual/unknown"
            managed = False

    rec = {
        "skill_name": skill,
        "source_harness": src_harness,
        "source_relpath": source_relpath,
        "source_sha256": source_full,
        "frontmatter_stripped_sha256": source_stripped,
        "projected_sha256": projected_sha,
        "projection_kind": projection_kind,
        "domain": domain_for(skill, src_harness),
        "managed": managed,
        "description_chars": desc_len,
        "present_in": present,
        "on_user_shelf": sh is not None,
    }
    records.append(rec)

doc = {
    "schema_version": 1,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "generator": "scripts/build-cross-harness-registry.sh",
    "skills": records,
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"wrote {out_path}: {len(records)} skills")
PY
