#!/usr/bin/env bash
# Local helper to run the `#[ignore]`-gated obscura E2E tests
# (S1, S2, S9 / Phase 5a / Phase 5b) the same way CI does.
#
# Usage:
#   ./scripts/run_obscura_e2e.sh                # build (if needed) + run all
#   OBSCURA_BIN=/abs/path ./scripts/run_obscura_e2e.sh --nocapture
set -euo pipefail
cd "$(dirname "$0")/.."

OBSCURA_BIN="${OBSCURA_BIN:-vendor/obscura/target/release/obscura}"
if [[ ! -x "$OBSCURA_BIN" ]]; then
  echo "Building obscura binary (this may take 5+ min)..."
  (cd vendor/obscura && cargo build --release --bin obscura)
fi

export REV_SCRAPING_RUN_OBSCURA=1
# Both env-var names are honoured by different call-sites:
#   - obscura_lifecycle.rs                 -> OBSCURA_BIN
#   - stealth-cli `spider` / `cf-evaluate` -> REV_STEALTH_OBSCURA
export OBSCURA_BIN
ABS_BIN="$(cd "$(dirname "$OBSCURA_BIN")" && pwd)/$(basename "$OBSCURA_BIN")"
export OBSCURA_BIN="$ABS_BIN"
export REV_STEALTH_OBSCURA="$ABS_BIN"

echo "Running ignored E2E tests with obscura binary at: $ABS_BIN"
cargo test --workspace -- --ignored obscura_lifecycle cdp_shim_e2e e2e_spider_fallback "$@"
