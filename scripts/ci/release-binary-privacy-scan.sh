#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'usage: %s [--rebuild] [--binary <path>]\n' "${0##*/}" >&2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
harness_rust="$repo_root/harness-rust"
default_binary="$harness_rust/target/release/semantic-mcp"
metrics_path="$repo_root/.agent/metrics/release_binary_privacy_scan.jsonl"
rebuild=0; binary_path="$default_binary"; binary_override=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1; shift ;;
    --binary)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      binary_path="$2"; binary_override=1; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-binary-privacy.XXXXXX")"
strings_file="$tmp_dir/strings.txt"; build_log="$tmp_dir/cargo-build.log"
trap 'rm -rf "$tmp_dir" || true' EXIT

redact() {
  sed -E -e 's#/Users/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#/home/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#[[:alnum:]_.-]*/\.cargo/registry/src/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g' \
    -e 's#[[:alnum:]_.-]*/\.rustup/toolchains/[^[:space:]:"]+#<REDACTED_HOST_PATH>#g'
}

json_binary_path() {
  case "$binary_path" in
    "$repo_root"/*) printf '%s' "${binary_path#"$repo_root"/}" ;;
    *) printf '%s' '<REDACTED_HOST_PATH>' ;;
  esac
}

emit_jsonl() {
  result="$1"; hits="$2"
  mkdir -p "$(dirname "$metrics_path")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; rel_binary="$(json_binary_path)"
  printf '{"ts":"%s","event":"release_binary_privacy_scan","schema":"release-binary-privacy-scan/v1","binary_path":"%s","scan_patterns":["/Users/","/home/",".cargo/registry/src/",".rustup/toolchains/","contact_dev"],"hits":%s,"result":"%s"}\n' \
    "$ts" "$rel_binary" "$hits" "$result" >> "$metrics_path"
}

privacy_rustflags() {
  # Keep in sync with harness-rust/.cargo/config.toml's header: this runtime
  # path covers host-expanded remaps that Cargo config cannot express.
  cargo_home="${CARGO_HOME:-${HOME:-}/.cargo}"; rustup_home="${RUSTUP_HOME:-${HOME:-}/.rustup}"
  flags=""
  [ -z "${HOME:-}" ] || flags="$flags --remap-path-prefix=$HOME=~"
  flags="$flags --remap-path-prefix=$cargo_home/registry/src=cargo-registry-src"
  flags="$flags --remap-path-prefix=$rustup_home/toolchains=rustup-toolchains"
  flags="$flags --remap-path-prefix=$repo_root=rev-harness-src"
  printf '%s' "${flags# }"
}

run_privacy_build() {
  flags="$(privacy_rustflags)"
  if ! (cd "$harness_rust" && RUSTFLAGS="${RUSTFLAGS:-} $flags" cargo build --release -p semantic-mcp) >"$build_log" 2>&1; then
    printf 'release binary privacy scan: cargo build failed\n' >&2
    redact < "$build_log" >&2
    exit 1
  fi
}

scan_binary() {
  strings "$binary_path" > "$strings_file"
  total_hits=0
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
  return 0
}

if ! command -v strings >/dev/null 2>&1; then
  printf 'release binary privacy scan: strings command not found\n' >&2
  exit 1
fi

if [ "$binary_override" -eq 0 ] && { [ "$rebuild" -eq 1 ] || [ ! -x "$binary_path" ]; }; then
  run_privacy_build
fi

if [ ! -f "$binary_path" ]; then
  printf 'release binary privacy scan: binary missing: %s\n' "$(json_binary_path)" >&2
  exit 1
fi

leak_report="$tmp_dir/leak-report.txt"
scan_binary
if [ "$total_hits" -gt 0 ] && [ "$binary_override" -eq 0 ]; then
  run_privacy_build
  scan_binary
fi

if [ "$total_hits" -gt 0 ]; then
  emit_jsonl "leak" "$total_hits"
  printf 'release binary privacy scan: leak detected in %s (%s hits)\n' "$(json_binary_path)" "$total_hits" >&2
  redact < "$leak_report" >&2
  exit 1
fi

emit_jsonl "ok" 0
exit 0
