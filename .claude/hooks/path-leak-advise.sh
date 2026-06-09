#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P 2>/dev/null || pwd -P)"
METRICS_PATH="${REPO_ROOT}/.agent/metrics/path_leak_events.jsonl"
HOOK_NAME="path-leak-advise"
DEFAULT_PATTERNS='/Users/[A-Za-z0-9_.-]+/dev/:/home/[A-Za-z0-9_.-]+/dev/'

rotate_jsonl() {
  f="${1:-}"
  [ -n "$f" ] || return 0
  [ -f "$f" ] || return 0
  size="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')" || {
    printf '%s\n' "path-leak-advise: warning: unable to inspect metrics size" >&2
    return 0
  }
  case "$size" in
    ''|*[!0-9]*)
      printf '%s\n' "path-leak-advise: warning: invalid metrics size" >&2
      return 0
      ;;
  esac
  if [ "$size" -gt 1048576 ] && ! mv -f "$f" "${f}.1" 2>/dev/null; then
    printf '%s\n' "path-leak-advise: warning: unable to rotate metrics file" >&2
  fi
  return 0
}

repo_rel() {
  path="${1:-}"
  [ -n "$path" ] || return 0
  case "$path" in
    "$REPO_ROOT"/*) printf '%s\n' "${path#"$REPO_ROOT"/}" ;;
    /*) basename "$path" 2>/dev/null || printf '%s\n' "outside-repo" ;;
    *) printf '%s\n' "$path" ;;
  esac
}
scan_and_record() {
  rotate_jsonl "$METRICS_PATH"
  FILE_ABS="${1:-}" SOURCE_PATH="${2:-}" METRICS_PATH="$METRICS_PATH" \
  HOOK_NAME="$HOOK_NAME" DEFAULT_PATTERNS="$DEFAULT_PATTERNS" \
  TASK_ID="${HARNESS_TASK_ID:-}" AGENT_FAMILY="${HARNESS_AGENT_FAMILY:-unknown}" \
  python3 - <<'PY' || true
import datetime, json, os, re, sys

try:
    file_abs = os.environ.get("FILE_ABS") or ""
    source = os.environ.get("SOURCE_PATH") or ""
    metrics_path = os.environ.get("METRICS_PATH") or ""
    patterns_raw = os.environ.get("HSDI_PATH_LEAK_PATTERNS") or os.environ.get("DEFAULT_PATTERNS") or ""
    regexes = [re.compile(p) for p in patterns_raw.split(":") if p]
    if not file_abs or not source or not os.path.isfile(file_abs) or not regexes:
        sys.exit(0)
    with open(file_abs, "r", encoding="utf-8", errors="ignore") as fh:
        text = fh.read()
    matches = []
    for rx in regexes:
        matches.extend(list(rx.finditer(text)))
    if not matches:
        sys.exit(0)

    def redact(value):
        value = re.sub(r"/Users/[A-Za-z0-9_.-]+/", "~/", value)
        value = re.sub(r"/home/[A-Za-z0-9_.-]+/", "~/", value)
        value = re.sub(r"(?i)\b(authorization)\s*:\s*(bearer|basic)\s+[A-Za-z0-9._~+/=-]+",
                       lambda m: f"{m.group(1)}: <REDACTED>", value)
        value = re.sub(r"(?i)\b(api[_-]?key|secret|token|password|passwd|credential)\b\s*[:=]\s*[\"']?[^\"'\s,;]+",
                       lambda m: f"{m.group(1)}=<REDACTED>", value)
        for rx in regexes:
            value = rx.sub("<HOME>/dev/", value)
        return value

    snippets = []
    for match in matches[:3]:
        start = max(0, match.start() - 48)
        end = min(len(text), match.end() + 96)
        snippet = " ".join(text[start:end].split())
        snippets.append(redact(snippet))
    preview = " | ".join(snippets)[:300] or "<redacted>"

    row = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "event": "path_leak",
        "source": source,
        "match_count": int(len(matches)),
        "redacted_preview": preview,
        "action": "warn",
        "agent_family": os.environ.get("AGENT_FAMILY") or "unknown",
        "hook": os.environ.get("HOOK_NAME") or "path-leak-advise",
    }
    task_id = os.environ.get("TASK_ID") or ""
    if task_id:
        row["task_id"] = task_id
    os.makedirs(os.path.dirname(metrics_path), exist_ok=True)
    with open(metrics_path, "a", encoding="utf-8") as out:
        out.write(json.dumps(row, separators=(",", ":")) + "\n")
    print(f"path-leak-advise: warned for {source} ({len(matches)} absolute home path match(es)); metrics appended", file=sys.stderr)
except Exception:
    pass
PY
}

main() {
  payload="$(cat 2>/dev/null || true)"
  parsed="$(
    printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
tool = data.get("tool_name") or data.get("tool") or ""
tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
path = (
    tool_input.get("file_path")
    or tool_input.get("notebook_path")
    or data.get("file_path")
    or data.get("path")
    or ""
)
print(tool)
print(path)
' 2>/dev/null || true
  )"
  tool="$(printf '%s\n' "$parsed" | sed -n '1p')"
  file_path="$(printf '%s\n' "$parsed" | sed -n '2p')"

  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
  esac
  [ -n "$file_path" ] || exit 0

  case "$file_path" in
    /*) file_abs="$file_path" ;;
    *) file_abs="${REPO_ROOT}/${file_path}" ;;
  esac
  [ -f "$file_abs" ] || exit 0

  source_path="$(repo_rel "$file_abs" 2>/dev/null || true)"
  [ -n "$source_path" ] || source_path="unknown"
  scan_and_record "$file_abs" "$source_path"
  exit 0
}
self_test() {
  before="$(wc -l < "$METRICS_PATH" 2>/dev/null || printf '0')"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/path-leak-advise.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp_dir" ] || { printf '%s\n' "SELF-TEST FAIL: tmpdir"; return 0; }
  tmp_file="${tmp_dir}/sample.txt"
  sample_home="${HOME:-/home/example}"
  printf 'sample leak: %s/dev/project/file.txt token=secret-value\n' "$sample_home" > "$tmp_file" 2>/dev/null || true
  payload="$(TARGET_FILE="$tmp_file" python3 -c 'import json, os; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":os.environ.get("TARGET_FILE","")}}))' 2>/dev/null || true)"
  printf '%s' "$payload" | bash "$0" >/dev/null 2>&1 || true
  after="$(wc -l < "$METRICS_PATH" 2>/dev/null || printf '0')"
  sample="$(tail -n 1 "$METRICS_PATH" 2>/dev/null || true)"
  rm -rf "$tmp_dir" 2>/dev/null || true
  if [ "${after:-0}" -gt "${before:-0}" ] && printf '%s' "$sample" | grep -q '"event":"path_leak"'; then
    printf '%s\n' "SELF-TEST OK"
    printf '%s\n' "$sample"
  else
    printf '%s\n' "SELF-TEST FAIL"
  fi
  return 0
}
case "${1:-}" in
  --self-test) self_test; exit 0 ;;
  *) main ;;
esac

exit 0
