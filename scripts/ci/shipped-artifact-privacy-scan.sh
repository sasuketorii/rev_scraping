#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s --manifest <path>\n' "${0##*/}" >&2
}

manifest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      manifest="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$manifest" ] || { usage; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
case "$manifest" in
  /*) manifest_path="$manifest" ;;
  *) manifest_path="$repo_root/$manifest" ;;
esac

policy_fail() {
  printf 'shipped artifact privacy scan: %s\n' "$*" >&2
  exit 1
}

env_fail() {
  printf 'shipped artifact privacy scan: %s\n' "$*" >&2
  exit 3
}

trim_cell() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\`}"
  value="${value%\`}"
  printf '%s' "$value"
}

redact() {
  sed -E -e 's#/Users/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#/home/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#[[:alnum:]_.-]*/\.cargo/registry/src/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#[[:alnum:]_.-]*/\.rustup/toolchains/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g'
}

privacy_rustflags() {
  local cargo_home rustup_home flags
  cargo_home="${CARGO_HOME:-${HOME:-}/.cargo}"
  rustup_home="${RUSTUP_HOME:-${HOME:-}/.rustup}"
  flags=""
  [ -z "${HOME:-}" ] || flags="$flags --remap-path-prefix=$HOME=~"
  flags="$flags --remap-path-prefix=$cargo_home/registry/src=cargo-registry-src"
  flags="$flags --remap-path-prefix=$rustup_home/toolchains=rustup-toolchains"
  flags="$flags --remap-path-prefix=$repo_root=rev-harness-src"
  printf '%s' "${flags# }"
}

build_known_artifact() {
  local rel_path="$1"
  local package=""
  case "$rel_path" in
    harness-rust/target/release/semantic-mcp) package="semantic-mcp" ;;
    harness-rust/target/release/agent-core) package="agent-core" ;;
    *) return 1 ;;
  esac

  local build_log="$tmp_dir/build-${package}.log"
  local flags
  flags="$(privacy_rustflags)"
  if ! (cd "$repo_root/harness-rust" && RUSTFLAGS="${RUSTFLAGS:-} $flags" cargo build --release -p "$package") >"$build_log" 2>&1; then
    printf 'shipped artifact privacy scan: cargo build failed for %s\n' "$rel_path" >&2
    redact < "$build_log" >&2
    exit 3
  fi
  return 0
}

scan_artifact() {
  local rel_path="$1"
  local abs_path="$repo_root/$rel_path"
  local strings_file="$tmp_dir/strings-${row_index}.txt"
  local leak_report="$tmp_dir/leaks-${row_index}.txt"
  local total_hits=0
  local pattern count

  if [ ! -f "$abs_path" ]; then
    build_known_artifact "$rel_path" || env_fail "listed shipped artifact is missing and has no known build rule: $rel_path"
  fi
  [ -f "$abs_path" ] || env_fail "listed shipped artifact still missing after build attempt: $rel_path"

  strings "$abs_path" > "$strings_file"
  : > "$leak_report"
  while IFS= read -r pattern; do
    count="$(grep -F -c "$pattern" "$strings_file" || true)"
    total_hits=$((total_hits + count))
    if [ "$count" -gt 0 ]; then
      printf 'pattern=%s hits=%s\n' "$pattern" "$count" >> "$leak_report"
      grep -F "$pattern" "$strings_file" | sed -n '1,3p' | redact >> "$leak_report"
    fi
  done <<'EOF_PATTERNS'
/Users/
/home/
.cargo/registry/src/
.rustup/toolchains/
contact_dev
EOF_PATTERNS

  if [ "$total_hits" -gt 0 ]; then
    printf 'shipped artifact privacy scan: leak detected in %s (%s hits)\n' "$rel_path" "$total_hits" >&2
    redact < "$leak_report" >&2
    exit 1
  fi
  printf 'PASS shipped artifact privacy scan: %s\n' "$rel_path"
}

command -v strings >/dev/null 2>&1 || env_fail "strings command not found"
[ -r "$manifest_path" ] || env_fail "manifest not readable: $manifest"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/shipped-artifact-privacy.XXXXXX")"
trap 'rm -rf "$tmp_dir" || true' EXIT

row_count=0
shipped_count=0
core_shipped_count=0
no_core_evidence_count=0
row_index=0
seen_paths="$tmp_dir/seen-paths.txt"
: > "$seen_paths"

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '| artifact path |'*|'|---|'*) continue ;;
    '|'*)
      IFS='|' read -r _ artifact kind ships command status evidence _rest <<< "$line"
      artifact="$(trim_cell "${artifact:-}")"
      kind="$(trim_cell "${kind:-}")"
      ships="$(trim_cell "${ships:-}")"
      command="$(trim_cell "${command:-}")"
      status="$(trim_cell "${status:-}")"
      evidence="$(trim_cell "${evidence:-}")"

      [ -n "$artifact" ] || continue
      row_count=$((row_count + 1))
      row_index=$((row_index + 1))

      case "$artifact" in
        /*|*'..'*) policy_fail "artifact path must be repo-relative and non-parent-traversing: $artifact" ;;
      esac
      case "$kind" in
        executable|archive) ;;
        *) policy_fail "invalid kind for $artifact: $kind" ;;
      esac
      case "$ships" in
        yes|not-shipped) ;;
        *) policy_fail "invalid ships-in-release for $artifact: $ships" ;;
      esac
      if grep -Fx "$artifact" "$seen_paths" >/dev/null 2>&1; then
        policy_fail "duplicate artifact path in manifest: $artifact"
      fi
      printf '%s\n' "$artifact" >> "$seen_paths"

      if [ "$ships" = "not-shipped" ]; then
        [ -n "$evidence" ] || policy_fail "not-shipped row lacks reviewer evidence: $artifact"
        [ "$evidence" != "TBD" ] || policy_fail "not-shipped row has placeholder evidence: $artifact"
        case "$status" in
          *'no shipped core artifact'*) no_core_evidence_count=$((no_core_evidence_count + 1)) ;;
        esac
        continue
      fi

      shipped_count=$((shipped_count + 1))
      case "$status:$artifact" in
        *addon*|*semantic-mcp*) ;;
        *) core_shipped_count=$((core_shipped_count + 1)) ;;
      esac
      [ -n "$command" ] || policy_fail "shipped row lacks privacy-scan command: $artifact"
      scan_artifact "$artifact"
      ;;
  esac
done < "$manifest_path"

[ "$row_count" -gt 0 ] || policy_fail "manifest has no artifact rows"
[ "$shipped_count" -gt 0 ] || policy_fail "manifest has no shipped artifact rows"
if [ "$core_shipped_count" -eq 0 ] && [ "$no_core_evidence_count" -eq 0 ]; then
  policy_fail "manifest records no shipped core artifact without reviewer evidence"
fi

printf 'PASS shipped artifact manifest rows=%s shipped=%s core_shipped=%s\n' \
  "$row_count" "$shipped_count" "$core_shipped_count"
