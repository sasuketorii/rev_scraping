#!/usr/bin/env bash
#
# rev-skill-curator-lite.sh — Curator-Lite Phase 1 (telemetry + dry-run only)
#
# Single shared runner over all 3 RevHarness skill trees:
#   - rev_harness            (.claude/skills, telemetry under .agent/registry/)
#   - rev_marketing_harness  (.claude/skills, telemetry under knowledge/_meta/)
#   - rev_textsocialharness  (.claude/skills, telemetry under knowledge/_meta/)
#
# What it DOES (Phase 1, per agreed_strategy_3harness.md §2 S-6 + §7 S-6):
#   - Walk each harness's skills and SEED telemetry into skill_usage.json
#     schema: { "<skill>": { use_count, last_used_at, first_seen_at } }
#     Initial seed: use_count=0, last_used_at=null, first_seen_at=<ISO8601 now>.
#   - Classify lifecycle (Hermes-compliant, JUDGEMENT ONLY — never moves files):
#       DEFAULT_STALE_AFTER_DAYS=30    -> "stale" candidate
#       DEFAULT_ARCHIVE_AFTER_DAYS=90  -> "archived-candidate"
#     last_used_at == null OR older than 30d  => stale candidate.
#     older than 90d                          => archived-candidate.
#   - provenance gate: any skill with NO entry in
#     cross_harness_projection_registry.json (matched by created_by / source
#     harness provenance) is reported as `ineligible_for_action: missing_registry`
#     and is NEVER promoted to archived-candidate.
#   - Emit a per-harness REPORT.md plus one global aggregate report.
#
# What it DOES NOT do (deferred to S-7 / Phase 2):
#   - NO file moves. NO mv. NO rm. NO `.archive/` directory creation.
#   - `--apply` is NOT implemented (see help; deferred to Phase 2 / S-7).
#
# Portable: macOS (BSD) and Linux. Heavy lifting is delegated to python3 for
# robust JSON + timezone-aware date arithmetic; bash only orchestrates.
#
set -euo pipefail

# ── Hermes-compliant lifecycle constants (inline, per Q1/Q3 arbitration) ──────
# Source: Z_hermesagent_deep_dive.md §3.4 / agent/curator.py:58-59
DEFAULT_STALE_AFTER_DAYS=30
DEFAULT_ARCHIVE_AFTER_DAYS=90

# ── Canonical paths ───────────────────────────────────────────────────────────
DEV_ROOT="${REV_DEV_ROOT:-$HOME/dev}"

REV_HARNESS_DIR="$DEV_ROOT/rev_harness"
MARKETING_DIR="$DEV_ROOT/rev_marketing_harness"
TEXTSOCIAL_DIR="$DEV_ROOT/rev_textsocialharness"

# Per-harness skills roots (.claude/skills) — READ ONLY in this script.
RH_SKILLS="$REV_HARNESS_DIR/.claude/skills"
MK_SKILLS="$MARKETING_DIR/.claude/skills"
TS_SKILLS="$TEXTSOCIAL_DIR/.claude/skills"

# Per-harness telemetry + report destinations (the only writable paths).
RH_META="$REV_HARNESS_DIR/.agent/registry"
MK_META="$MARKETING_DIR/knowledge/_meta"
TS_META="$TEXTSOCIAL_DIR/knowledge/_meta"

# provenance authority (Pass 1 registry).
REGISTRY="$RH_META/cross_harness_projection_registry.json"

# ── Arg parsing ───────────────────────────────────────────────────────────────
DRY_RUN=0

usage() {
  cat <<'EOF'
rev-skill-curator-lite.sh — Curator-Lite Phase 1 (telemetry + dry-run only)

USAGE:
  rev-skill-curator-lite.sh --dry-run
  rev-skill-curator-lite.sh -h | --help

FLAGS:
  --dry-run   Seed/update telemetry sidecars and emit lifecycle REPORTs.
              Performs ZERO file moves (no mv, no rm, no .archive/).
  -h, --help  Show this help.

NOTES:
  --apply is deferred to Phase 2 (S-7 Distribution-Time Archival) and is
  intentionally NOT implemented in this Phase 1 runner. This runner only
  records telemetry and reports lifecycle candidates; it never archives,
  moves, or deletes any skill.

  Lifecycle constants (Hermes-compliant, judgement only):
    DEFAULT_STALE_AFTER_DAYS=30
    DEFAULT_ARCHIVE_AFTER_DAYS=90

  provenance gate: skills without a registry (cross_harness_projection_registry
  .json) entry are reported as `ineligible_for_action: missing_registry` and are
  never promoted to archived-candidate.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --apply)
      echo "error: --apply is deferred to Phase 2 (S-7) and is not implemented." >&2
      echo "       This Phase 1 runner only records telemetry; run with --dry-run." >&2
      exit 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$DRY_RUN" -ne 1 ]; then
  echo "error: --dry-run is required (Phase 1 has no other mode)." >&2
  usage >&2
  exit 2
fi

# ── python3 discovery (portable) ──────────────────────────────────────────────
PYBIN="$(command -v python3 || true)"
if [ -z "$PYBIN" ]; then
  echo "error: python3 is required but was not found on PATH." >&2
  exit 1
fi

# ── Delegate to python3 for telemetry + lifecycle + reports ───────────────────
# We pass config via env so quoting stays sane.
export RH_SKILLS MK_SKILLS TS_SKILLS RH_META MK_META TS_META REGISTRY
export DEFAULT_STALE_AFTER_DAYS DEFAULT_ARCHIVE_AFTER_DAYS

"$PYBIN" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

STALE_AFTER_DAYS = int(os.environ["DEFAULT_STALE_AFTER_DAYS"])
ARCHIVE_AFTER_DAYS = int(os.environ["DEFAULT_ARCHIVE_AFTER_DAYS"])

NOW = datetime.now(timezone.utc)
NOW_ISO = NOW.isoformat()
STALE_CUTOFF = NOW - timedelta(days=STALE_AFTER_DAYS)
ARCHIVE_CUTOFF = NOW - timedelta(days=ARCHIVE_AFTER_DAYS)

# harness key -> (skills_dir, meta_dir)
HARNESSES = {
    "rev_harness": (os.environ["RH_SKILLS"], os.environ["RH_META"]),
    "rev_marketing_harness": (os.environ["MK_SKILLS"], os.environ["MK_META"]),
    "rev_textsocialharness": (os.environ["TS_SKILLS"], os.environ["TS_META"]),
}

REGISTRY_PATH = os.environ["REGISTRY"]


def load_registry_index(path):
    """Return dict: harness -> set(skill_name) for provenance gating.

    A skill walked in harness H is registry-eligible when the registry has an
    entry whose source_harness == H OR whose present_in array includes H. This
    is the `created_by`/provenance gate: the registry is the authority for which
    skills RevHarness governs.
    """
    index = {h: set() for h in HARNESSES}
    if not os.path.exists(path):
        return index, False
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:  # pragma: no cover - defensive
        # Emit only the basename to avoid leaking home-dir absolute paths into
        # logs/artifacts (path-leak guard hygiene).
        sys.stderr.write(
            f"warning: could not parse registry {os.path.basename(path)}: {exc}\n"
        )
        return index, False
    for entry in data.get("skills", []):
        name = entry.get("skill_name")
        if not name:
            continue
        src = entry.get("source_harness")
        if src in index:
            index[src].add(name)
        for h in entry.get("present_in", []) or []:
            if h in index:
                index[h].add(name)
    return index, True


def iter_skills(skills_dir):
    """Yield (skill_name, skill_md_path) for every SKILL.md under skills_dir.

    skill_name is the immediate parent directory name of SKILL.md (matches the
    registry's skill_name convention). Read-only; never mutates skills_dir.
    """
    root = Path(skills_dir)
    if not root.is_dir():
        return
    for skill_md in sorted(root.rglob("SKILL.md")):
        yield skill_md.parent.name, skill_md


def atomic_write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def parse_iso(value):
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def load_telemetry(meta_dir):
    path = Path(meta_dir) / "skill_usage.json"
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def classify(record, eligible):
    """Hermes-compliant lifecycle judgement (JUDGEMENT ONLY — no file move).

    Returns one of: "active", "stale", "archived-candidate".
    archived-candidate is gated by provenance: an ineligible (missing_registry)
    skill is never promoted past "stale".
    """
    last_used = parse_iso(record.get("last_used_at"))
    # anchor: last real activity, else first_seen_at, else now (new skills do
    # not immediately archive — mirrors Hermes apply_automatic_transitions).
    anchor = last_used or parse_iso(record.get("first_seen_at")) or NOW

    if anchor <= ARCHIVE_CUTOFF:
        return "archived-candidate" if eligible else "stale"
    if last_used is None or anchor <= STALE_CUTOFF:
        # Newly seeded skills have anchor == first_seen_at == now, which is NOT
        # <= STALE_CUTOFF, so they correctly classify as active on first run.
        if anchor <= STALE_CUTOFF:
            return "stale"
        return "active"
    return "active"


def render_report_md(harness, rows, totals):
    lines = []
    lines.append(f"# Curator-Lite Report — {harness}")
    lines.append("")
    lines.append(f"Generated: {NOW_ISO}")
    lines.append(
        f"Mode: dry-run (telemetry only; ZERO file moves) · "
        f"stale_after_days={STALE_AFTER_DAYS} · "
        f"archive_after_days={ARCHIVE_AFTER_DAYS}"
    )
    lines.append("")
    lines.append(
        f"Skills: {totals['total']} · active: {totals['active']} · "
        f"stale: {totals['stale']} · archived-candidate: "
        f"{totals['archived_candidate']} · "
        f"ineligible (missing_registry): {totals['ineligible']}"
    )
    lines.append("")
    lines.append("| skill | lifecycle | use_count | last_used_at | provenance |")
    lines.append("|---|---|---|---|---|")
    for r in rows:
        prov = "registry" if r["eligible"] else "ineligible_for_action: missing_registry"
        last_used = r["record"]["last_used_at"] or "(never)"
        lines.append(
            f"| {r['skill']} | {r['lifecycle']} | "
            f"{r['record']['use_count']} | {last_used} | {prov} |"
        )
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append(
        "- Phase 1 is telemetry + judgement only. No skill was moved, archived, "
        "or deleted. File archival (`--apply`) is deferred to Phase 2 / S-7."
    )
    lines.append(
        "- `archived-candidate` is a *report-only* label. Skills without a "
        "registry entry are capped at `stale` and flagged "
        "`ineligible_for_action: missing_registry`."
    )
    lines.append("")
    return "\n".join(lines)


def main():
    reg_index, reg_present = load_registry_index(REGISTRY_PATH)
    if not reg_present:
        sys.stderr.write(
            f"warning: registry not found at {os.path.basename(REGISTRY_PATH)}; "
            "all skills will be treated as ineligible (missing_registry).\n"
        )

    global_rows = []
    grand = {
        "total": 0, "active": 0, "stale": 0,
        "archived_candidate": 0, "ineligible": 0,
    }
    per_harness_summary = {}

    for harness, (skills_dir, meta_dir) in HARNESSES.items():
        existing = load_telemetry(meta_dir)
        telemetry = {}
        rows = []
        totals = {
            "total": 0, "active": 0, "stale": 0,
            "archived_candidate": 0, "ineligible": 0,
        }

        for skill_name, _skill_md in iter_skills(skills_dir):
            # Seed or carry forward telemetry record.
            rec = existing.get(skill_name)
            if not isinstance(rec, dict):
                rec = {
                    "use_count": 0,
                    "last_used_at": None,
                    "first_seen_at": NOW_ISO,
                }
            else:
                # Preserve existing counters; backfill missing fields.
                rec = {
                    "use_count": int(rec.get("use_count", 0) or 0),
                    "last_used_at": rec.get("last_used_at"),
                    "first_seen_at": rec.get("first_seen_at") or NOW_ISO,
                }
            telemetry[skill_name] = rec

            eligible = skill_name in reg_index.get(harness, set())
            lifecycle = classify(rec, eligible)

            totals["total"] += 1
            if not eligible:
                totals["ineligible"] += 1
            if lifecycle == "active":
                totals["active"] += 1
            elif lifecycle == "stale":
                totals["stale"] += 1
            elif lifecycle == "archived-candidate":
                totals["archived_candidate"] += 1

            row = {
                "harness": harness,
                "skill": skill_name,
                "lifecycle": lifecycle,
                "eligible": eligible,
                "record": rec,
            }
            rows.append(row)
            global_rows.append(row)

        # Write telemetry sidecar (seed file always created, even if empty).
        atomic_write_json(os.path.join(meta_dir, "skill_usage.json"), telemetry)

        # Write per-harness REPORT.md.
        reports_dir = os.path.join(meta_dir, "curator_reports")
        Path(reports_dir).mkdir(parents=True, exist_ok=True)
        report_path = os.path.join(reports_dir, "REPORT.md")
        with open(report_path, "w", encoding="utf-8") as fh:
            fh.write(render_report_md(harness, rows, totals))

        for k in grand:
            grand[k] += totals[k]
        per_harness_summary[harness] = dict(totals)

    # Global aggregate report under rev_harness governance home.
    agg_dir = os.path.join(os.environ["RH_META"], "curator_reports")
    Path(agg_dir).mkdir(parents=True, exist_ok=True)
    agg_path = os.path.join(agg_dir, "AGGREGATE.md")
    agg_lines = []
    agg_lines.append("# Curator-Lite Aggregate (all 3 harnesses)")
    agg_lines.append("")
    agg_lines.append(f"Generated: {NOW_ISO}")
    agg_lines.append(
        f"Mode: dry-run (telemetry only; ZERO file moves) · "
        f"stale_after_days={STALE_AFTER_DAYS} · "
        f"archive_after_days={ARCHIVE_AFTER_DAYS}"
    )
    agg_lines.append("")
    agg_lines.append(
        "| harness | total | active | stale | archived-candidate | "
        "ineligible (missing_registry) |"
    )
    agg_lines.append("|---|---|---|---|---|---|")
    for h, t in per_harness_summary.items():
        agg_lines.append(
            f"| {h} | {t['total']} | {t['active']} | {t['stale']} | "
            f"{t['archived_candidate']} | {t['ineligible']} |"
        )
    agg_lines.append(
        f"| **TOTAL** | {grand['total']} | {grand['active']} | "
        f"{grand['stale']} | {grand['archived_candidate']} | "
        f"{grand['ineligible']} |"
    )
    agg_lines.append("")
    agg_lines.append("## Provenance gate")
    agg_lines.append("")
    agg_lines.append(
        "Skills without a `cross_harness_projection_registry.json` entry "
        "(matched by source harness / `present_in` provenance, i.e. the "
        "`created_by` authority) are flagged `ineligible_for_action: "
        "missing_registry` and are never promoted to archived-candidate."
    )
    agg_lines.append("")
    agg_lines.append("## Phase boundary")
    agg_lines.append("")
    agg_lines.append(
        "- Phase 1 = telemetry + dry-run lifecycle judgement only. "
        "No file was moved, archived, or deleted."
    )
    agg_lines.append(
        "- `--apply` (auto-archive to `.archive/`) is deferred to Phase 2 / S-7."
    )
    agg_lines.append("")
    with open(agg_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(agg_lines))

    # Machine-readable summary to stdout.
    print(json.dumps({
        "mode": "dry-run",
        "files_moved": 0,
        "stale_after_days": STALE_AFTER_DAYS,
        "archive_after_days": ARCHIVE_AFTER_DAYS,
        "per_harness": per_harness_summary,
        "totals": grand,
        "registry_present": reg_present,
    }, indent=2, ensure_ascii=False))


main()
PYEOF
