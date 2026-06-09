#!/usr/bin/env bash
# sync-knowledge-pack.sh — report-only cross-scope skill drift detector.
#
# Compares 9 cross-scope skill packs across three scopes:
#   - project: $REPO_ROOT/.claude/skills/<pack>
#   - user:    $HOME/.claude/skills/<pack>
#   - agents:  $REPO_ROOT/.agent/skills/<pack>  (if present)
#
# Drift verdicts:
#   - "exact mirror"          : sha256 manifest identical across present scopes
#   - "drift: N files differ" : at least one file's sha256 differs
#   - "missing on <scope>"    : the pack does not exist in the named scope
#
# Project-only preserve windows
# ------------------------------
# This script is **report-only**; there is no --apply flag in this session.
# When a future --apply lands, it must preserve project-local override windows
# inside otherwise-mirrored files so adopting projects can keep workspace pins
# (e.g. a "Rev_<ProjectName> workspace baseline" table) without being reset by
# the global pack.
#
# Two preserve markers are recognised by the report. Drift inside a preserve
# window is COUNTED for visibility, but the report flags the window so a future
# --apply implementation can skip the preserved section line range:
#
#   1. Explicit fence:
#        <!-- preserve:project-only:start -->
#        ... project-local override content ...
#        <!-- preserve:project-only:end -->
#
#   2. Implicit section header:
#        ## Rev_<ProjectName> workspace baseline ...
#      (matched as the literal text "workspace baseline" on a heading line, so
#       any "Rev_Foo workspace baseline" header is recognised)
#
# Future --apply design (documented in docs/skill-sync.md):
#   - Default direction = project -> user (per audit §6.3).
#   - For each file with drift: if the file has no preserve windows, replace the
#     user-scope file with the project-scope file byte-for-byte.
#   - If the file HAS preserve windows on the user side, splice the user-side
#     preserve regions into the project-side content before writing. The set
#     of cross-scope skills covered here is intentionally narrow so this
#     splice rule remains tractable.
#   - Apply is gated behind an explicit `--apply` flag and a `--dry-run`
#     preview. Both modes must reuse this script's verdict format unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# ---------------------------------------------------------------------------
# Projection-boundary description cap (agreed_strategy_3harness.md §2 S-3).
#
# Hermes parity: a skill `description:` rendered into a Claude-Code-readable
# shelf is hard-capped at 60 codepoints. Hermes `extract_skill_description`
# truncates with `desc[:57] + "..."` (57 + 3 = 60). The cap is a SINGLE inline
# constant here — there is intentionally no external cap-config JSON sidecar
# (Q1 arbitration: callsite=1, constant=1).
#
# The cap applies ONLY at the projection boundary, i.e. when writing a user
# shelf file `~/.claude/skills/<x>/SKILL.md` AND only when the cross-harness
# registry declares that skill `projection_kind: "partial-capped"`. Canonical
# harness sources under `dev/rev_*/.claude/skills/` are READ-ONLY and never
# capped. `byte-for-byte` and `manual/unknown` skills are skipped silently.
# ---------------------------------------------------------------------------
CAP=60
PROJECTION_REGISTRY="${PROJECTION_REGISTRY:-${REPO_ROOT}/.agent/registry/cross_harness_projection_registry.json}"
OWNERSHIP_MAP="${OWNERSHIP_MAP:-${REPO_ROOT}/.agent/registry/cross_harness_skill_ownership.json}"

# apply_description_cap <description-string>
# Echoes the description capped to CAP codepoints (Unicode-safe). If the input
# is longer than CAP, it is truncated to (CAP-3) codepoints + "..." so the
# final string is exactly CAP codepoints. Shorter inputs pass through unchanged.
apply_description_cap() {
  local desc="$1"
  CAP="$CAP" python3 - "$desc" <<'PY'
import os, sys
cap = int(os.environ["CAP"])
desc = sys.argv[1] if len(sys.argv) > 1 else ""
if len(desc) > cap:
    desc = desc[:cap - 3] + "..."
sys.stdout.write(desc)
PY
}

# registry_projection_kind <skill-name>
# Echoes the registry-declared projection_kind for the skill, or "" if the
# registry is missing/unparseable or has no entry. Used to gate the cap.
registry_projection_kind() {
  local skill="$1"
  [[ -f "$PROJECTION_REGISTRY" ]] || { printf ''; return 0; }
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  jq -r --arg s "$skill" \
    '(.skills // [])[] | select(.skill_name == $s) | .projection_kind' \
    "$PROJECTION_REGISTRY" 2>/dev/null | head -n1
}

# registry_source_harness <skill-name>
# Echoes the registry-resolved source_harness (canonical_base) for the skill, or
# "" if the registry is missing/unparseable or has no entry. Used to derive the
# provenance source_harness dynamically (F-2: never hardcode rev_textsocialharness).
# Falls back to the ownership-map canonical_base for the bootstrap projection,
# when the body-SHA-based registry has not yet flipped to partial-capped.
registry_source_harness() {
  local skill="$1"
  local sh=""
  if [[ -f "$PROJECTION_REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
    sh="$(jq -r --arg s "$skill" \
      '(.skills // [])[] | select(.skill_name == $s) | .source_harness' \
      "$PROJECTION_REGISTRY" 2>/dev/null | head -n1)"
  fi
  if [[ -z "$sh" || "$sh" == "null" || "$sh" == "unknown" ]]; then
    sh="$(ownership_canonical_base "$skill")"
  fi
  printf '%s' "$sh"
}

# 9 cross-scope skill packs covered by this report (audit §6.1).
SKILLS=(
  rust-skills-knowledge-pack
  typescript-skills-knowledge-pack
  go-skills-knowledge-pack
  revc-shadcn-frontend-workflow
  self-growth-proposal-triage
  supabase-deploy-guard
  cloudflare-deploy-guard
  payload-cms-deploy-guard
  codex-app-server-guard
)

# Output destinations.
REPORT_DIR="$REPO_ROOT/.agent/active"
REPORT_PATH="$REPORT_DIR/skill-sync-report.md"
mkdir -p "$REPORT_DIR"

hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

# Print a stable "sha256<TAB>relpath" manifest for every regular file in a tree.
# Returns "" (empty stdout) if the tree is missing.
manifest_for() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  (
    cd "$root"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      printf '%s\t%s\n' "$(hash_file "$rel")" "$rel"
    done
  )
}

# Detect "project-only preserve" windows inside a file.
# Echoes one line per window: "<start_line>:<end_line>:<kind>"
detect_preserve_windows() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  # 1) Explicit fence pairs.
  awk '
    /<!-- preserve:project-only:start -->/  { open=NR }
    /<!-- preserve:project-only:end -->/    { if (open) { print open ":" NR ":fence"; open=0 } }
  ' "$file"

  # 2) Implicit "workspace baseline" section headers (markdown heading).
  grep -nE '^#{1,6} .*workspace baseline' "$file" 2>/dev/null \
    | awk -F: '{print $1 ":" $1 ":workspace-baseline-header"}' || true
}

# Diff two file manifests; count distinct relpaths whose hash differs or that
# are present only on one side. Returns the count on stdout.
count_drift() {
  local a="$1"
  local b="$2"
  local count
  count="$( { diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") || true; } \
    | grep -E '^[<>] ' \
    | awk '{print $NF}' \
    | sort -u \
    | wc -l \
    | tr -d '[:space:]' )"
  printf '%s\n' "$count"
}

# Emit a single skill block to the report.
report_skill() {
  local skill="$1"
  local project_dir="$REPO_ROOT/.claude/skills/$skill"
  local user_dir="$HOME/.claude/skills/$skill"
  local agents_dir="$REPO_ROOT/.agent/skills/$skill"

  printf '## %s\n\n' "$skill"

  local present_project=false present_user=false present_agents=false
  [[ -d "$project_dir" ]] && present_project=true
  [[ -d "$user_dir"    ]] && present_user=true
  [[ -d "$agents_dir"  ]] && present_agents=true

  printf -- '- project (`.claude/skills/%s`): %s\n' "$skill" \
    "$([[ $present_project == true ]] && echo present || echo missing)"
  printf -- '- user (`~/.claude/skills/%s`): %s\n' "$skill" \
    "$([[ $present_user == true ]] && echo present || echo missing)"
  printf -- '- agents (`.agent/skills/%s`): %s\n' "$skill" \
    "$([[ $present_agents == true ]] && echo present || echo missing)"
  printf '\n'

  local proj_manifest="" user_manifest="" agents_manifest=""
  if $present_project; then proj_manifest="$(manifest_for "$project_dir")"; fi
  if $present_user;    then user_manifest="$(manifest_for "$user_dir")";    fi
  if $present_agents;  then agents_manifest="$(manifest_for "$agents_dir")"; fi

  # Verdicts per cross-scope pair (project<->user, project<->agents).
  local pu_verdict="n/a"
  if $present_project && $present_user; then
    if [[ "$proj_manifest" == "$user_manifest" ]]; then
      pu_verdict="exact mirror"
    else
      local n
      n="$(count_drift "$proj_manifest" "$user_manifest")"
      pu_verdict="drift: $n files differ"
    fi
  elif $present_project && ! $present_user; then
    pu_verdict="missing on user"
  elif ! $present_project && $present_user; then
    pu_verdict="missing on project"
  fi

  local pa_verdict="n/a"
  if $present_project && $present_agents; then
    if [[ "$proj_manifest" == "$agents_manifest" ]]; then
      pa_verdict="exact mirror"
    else
      local n
      n="$(count_drift "$proj_manifest" "$agents_manifest")"
      pa_verdict="drift: $n files differ"
    fi
  elif $present_project && ! $present_agents; then
    pa_verdict="missing on agents"
  elif ! $present_project && $present_agents; then
    pa_verdict="missing on project"
  fi

  printf -- '- project <-> user verdict: **%s**\n' "$pu_verdict"
  printf -- '- project <-> agents verdict: **%s**\n' "$pa_verdict"
  printf '\n'

  # File-level summary (count + first 5 sha256 lines so the report stays small).
  if [[ -n "$proj_manifest" ]]; then
    local proj_count
    proj_count="$(printf '%s\n' "$proj_manifest" | grep -c . || true)"
    printf -- '- project file count: %s\n' "$proj_count"
  fi

  # Preserve-window detection across the project scope (so the future --apply
  # author knows which files contain protected ranges).
  local preserve_lines=""
  if $present_project; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      local windows
      windows="$(detect_preserve_windows "$REPO_ROOT/.claude/skills/$skill/$f" || true)"
      if [[ -n "$windows" ]]; then
        while IFS= read -r w; do
          [[ -n "$w" ]] || continue
          preserve_lines+="    - \`$f\` window $w"$'\n'
        done <<<"$windows"
      fi
    done < <(printf '%s\n' "$proj_manifest" | awk '{print $2}')
  fi

  if [[ -n "$preserve_lines" ]]; then
    printf -- '- project-only preserve windows detected:\n%s' "$preserve_lines"
  else
    printf -- '- project-only preserve windows detected: none\n'
  fi
  printf '\n'
}

# ownership_canonical_base <skill>
# Echoes the ownership-map canonical_base harness for the skill, or "" if none.
# Used as the bootstrap gate: a freshly-forked shelf entry still reads
# manual/unknown in the registry until the projection lands, so the ownership
# map's declared intent authorises the FIRST partial-capped projection.
ownership_canonical_base() {
  local skill="$1"
  [[ -f "$OWNERSHIP_MAP" ]] || { printf ''; return 0; }
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  jq -r --arg s "$skill" '.[$s].canonical_base // empty' "$OWNERSHIP_MAP" 2>/dev/null | head -n1
}

# project_partial_capped <skill> <canonical_source_skill.md> <user_shelf_target.md>
# Re-projects a registry-managed `partial-capped` skill onto the user shelf:
#   - body  = canonical body verbatim (everything AFTER the leading frontmatter)
#   - frontmatter = stripped style (name + capped description only), matching the
#                   established user-shelf convention.
# Gate: proceeds when the registry already declares `partial-capped`, OR (bootstrap)
# when the ownership map declares a canonical_base for this skill — the body-SHA
# based registry only flips to partial-capped AFTER this first projection lands.
# Never touches the canonical source (read-only). Writes provenance.json sidecar.
project_partial_capped() {
  local skill="$1" src="$2" dst="$3"
  local kind base
  kind="$(registry_projection_kind "$skill")"
  base="$(ownership_canonical_base "$skill")"
  if [[ "$kind" != "partial-capped" && -z "$base" ]]; then
    printf 'skip %s: projection_kind=%s and no ownership canonical_base (not eligible)\n' \
      "$skill" "${kind:-<none>}" >&2
    return 0
  fi
  [[ -f "$src" ]] || { printf 'skip %s: canonical source missing (%s)\n' "$skill" "$src" >&2; return 0; }

  local capped_desc src_sha
  # Extract canonical description, then cap it.
  local raw_desc
  raw_desc="$(python3 - "$src" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
if not m:
    sys.exit(0)
dm = re.search(r"^description:\s*(.*)$", m.group(1), re.MULTILINE)
if not dm:
    sys.exit(0)
val = dm.group(1).strip()
if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
    val = val[1:-1]
sys.stdout.write(val)
PY
)"
  capped_desc="$(apply_description_cap "$raw_desc")"
  src_sha="$(hash_file "$src")"

  mkdir -p "$(dirname "$dst")"
  # Compose: stripped frontmatter (name + capped description) + canonical body.
  CAPPED_DESC="$capped_desc" SKILL_NAME="$skill" python3 - "$src" "$dst" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()
# Strip the leading frontmatter block to get the canonical body verbatim.
body = re.sub(r"^---\s*\n.*?\n---\s*\n", "", text, count=1, flags=re.DOTALL) if text.startswith("---") else text
name = os.environ["SKILL_NAME"]
desc = os.environ["CAPPED_DESC"]
out = f"---\nname: {name}\ndescription: {desc}\n---\n\n{body.lstrip(chr(10))}"
with open(dst, "w", encoding="utf-8") as f:
    f.write(out)
PY

  # provenance sidecar (optional, registry remains authority)
  # F-2: source_harness is derived dynamically from the registry-resolved
  # canonical_base (closest-specialist-wins), never hardcoded. satori/launch
  # resolve to rev_marketing_harness; x/threads resolve to rev_textsocialharness.
  local prov_dir prov src_harness
  prov_dir="$(dirname "$dst")"
  prov="$prov_dir/provenance.json"
  src_harness="$(registry_source_harness "$skill")"
  PROV_SOURCE_HARNESS="$src_harness" python3 - "$prov" "$src_sha" <<'PY'
import json, os, sys, datetime
prov, src_sha = sys.argv[1], sys.argv[2]
doc = {
    "source_harness": os.environ.get("PROV_SOURCE_HARNESS", ""),
    "projection_kind": "partial-capped",
    "projected_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source_sha256": src_sha,
}
with open(prov, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  printf 'projected %s -> %s (capped description, %s)\n' "$skill" "$dst" "$capped_desc"
}

main() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # --project <skill> mode: re-project a single registry-managed
  # partial-capped skill from its canonical harness onto the user shelf.
  if [[ "${1:-}" == "--project" && -n "${2:-}" ]]; then
    local skill="$2"
    # Canonical source resolved from the registry's harness-relative
    # source_relpath, joined to the resolved source harness root. Harness
    # roots are siblings of this rev_harness checkout (no home-dir absolute
    # paths baked in; keeps the path-leak guard happy and stays portable).
    local relpath src_harness harness_root src
    relpath="$(jq -r --arg s "$skill" \
      '(.skills // [])[] | select(.skill_name == $s) | .source_relpath' \
      "$PROJECTION_REGISTRY" 2>/dev/null | head -n1)"
    src_harness="$(registry_source_harness "$skill")"
    if [[ "$src_harness" == "rev_harness" ]]; then
      harness_root="$REPO_ROOT"
    else
      harness_root="$(dirname "$REPO_ROOT")/$src_harness"
    fi
    src="$harness_root/$relpath"
    project_partial_capped "$skill" "$src" "$HOME/.claude/skills/$skill/SKILL.md"
    return 0
  fi

  {
    printf '# Skill Sync Report\n\n'
    printf -- '- Generated: %s\n' "$now"
    # Use placeholders, never home-dir absolute paths, so the committed report
    # stays path-leak-clean and portable across machines.
    printf -- '- Repo root: `<rev_harness>` (this checkout)\n'
    printf -- '- User scope: `~/.claude/skills`\n'
    printf -- '- Mode: **report-only** (no `--apply` in this session)\n'
    printf -- '- Preserve markers detected: `<!-- preserve:project-only:start/end -->` and `## ... workspace baseline ...` headings\n'
    printf -- '- Direction (future apply): project -> user\n\n'

    printf '## Coverage\n\n'
    for s in "${SKILLS[@]}"; do
      printf -- '- %s\n' "$s"
    done
    printf '\n'

    printf '## Per-skill verdicts\n\n'
    for s in "${SKILLS[@]}"; do
      report_skill "$s"
    done

    printf '## Notes\n\n'
    printf -- '- Drift counts include files within preserve windows for visibility; a future `--apply` step must skip preserved line ranges when writing user-scope content.\n'
    printf -- '- See `docs/skill-sync.md` for the preserve contract and the planned `--apply` semantics.\n'
  } >"$REPORT_PATH"

  printf 'wrote %s\n' "$REPORT_PATH"
}

main "$@"
