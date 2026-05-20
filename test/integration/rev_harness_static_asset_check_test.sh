#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-static-asset-check.sh"
FIXTURE_DIR="$PROJECT_ROOT/workspace/static-asset-check-fixture-$$"

cleanup() {
  /bin/rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

mkdir -p "$FIXTURE_DIR"

cat > "$FIXTURE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <link rel="stylesheet" href="./styles.css">
    <title>Static Check Fixture</title>
  </head>
  <body>
    <main id="app"></main>
    <script src="./app.js"></script>
  </body>
</html>
HTML

cat > "$FIXTURE_DIR/styles.css" <<'CSS'
body {
  margin: 0;
}

#app {
  min-height: 100vh;
}
CSS

cat > "$FIXTURE_DIR/app.js" <<'JS'
const target = document.getElementById("app");
if (target) {
  target.textContent = "ready";
}
JS

cat > "$FIXTURE_DIR/data.json" <<'JSON'
{"ok": true}
JSON

json="$("$CHECKER" --json \
  "workspace/static-asset-check-fixture-$$/index.html" \
  "workspace/static-asset-check-fixture-$$/styles.css" \
  "workspace/static-asset-check-fixture-$$/app.js" \
  "workspace/static-asset-check-fixture-$$/data.json")"

jq -e '
  .schema_version == "rev-harness-static-asset-check/v1"
  and .status == "PASS"
  and (.checked_files | length) == 4
  and (.errors | length) == 0
' <<<"$json" >/dev/null

cat > "$FIXTURE_DIR/broken.js" <<'JS'
const broken = ;
JS

if "$CHECKER" "workspace/static-asset-check-fixture-$$/broken.js" >/tmp/rev_harness_static_asset_unexpected_js.txt 2>/dev/null; then
  printf 'expected broken JavaScript rejection\n' >&2
  exit 1
fi

cat > "$FIXTURE_DIR/broken.css" <<'CSS'
.missing-close {
  color: red;
CSS

if "$CHECKER" "workspace/static-asset-check-fixture-$$/broken.css" >/tmp/rev_harness_static_asset_unexpected_css.txt 2>/dev/null; then
  printf 'expected broken CSS rejection\n' >&2
  exit 1
fi

if "$CHECKER" "../outside.js" >/tmp/rev_harness_static_asset_unexpected_outside.txt 2>/dev/null; then
  printf 'expected unsafe outside path rejection\n' >&2
  exit 1
fi

printf 'PASS: rev_harness_static_asset_check\n'
