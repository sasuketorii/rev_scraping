#!/usr/bin/env bash
# v1.1.0 GA soak runner.
#
# Purpose: exercise the three primary subcommands of `rev-stealth`
# (doctor, auth list, measure) repeatedly so we can observe long-running
# stability — RSS growth, crash count, and per-cycle latency — without
# touching any external SaaS endpoint.
#
# Usage:
#   bash scripts/run_soak.sh [DURATION_SECS] [INTERVAL_SECS]
#
# Defaults: 7 days * 5 min interval = 2016 cycles (the GA-gate run).
#
# Environment overrides:
#   LOGDIR   directory for cycle logs and summary    (default: ~/.rev_scraping/soak)
#   BIN      path to rev-stealth release binary       (default: ./target/release/rev-stealth)
#   URL      measurement URL (local-only by default)  (default: https://example.com)
#
# Crash policy:
#   - exit code >= 128  => signal-killed = CRASH (BLOCKER for GA gate)
#   - exit code != 0    => error (tracked, not a crash; e.g. doctor returns 7
#                          on hosts where the gluetun container is absent)
#   - exit code == 0    => ok
#
# Secrets: nothing in this script logs profile contents. `auth list` only
# enumerates profile *names*, and `measure` runs in local mode (no external
# fetch). Do NOT pass `--enable-external` here.

set -euo pipefail

DURATION=${1:-604800}   # seconds; 7 days
INTERVAL=${2:-300}      # seconds; 5 min
LOGDIR=${LOGDIR:-$HOME/.rev_scraping/soak}
BIN=${BIN:-./target/release/rev-stealth}
URL=${URL:-https://example.com}

mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/soak-summary.log"

if [ ! -x "$BIN" ]; then
  echo "soak: binary not found or not executable: $BIN" >&2
  exit 2
fi

START=$(date +%s)
END=$((START + DURATION))
CYCLE=0
CRASH=0
ERROR=0

ts_utc() { date -u +%Y%m%dT%H%M%SZ; }
now()    { date +%s; }

# Portable RSS read (KB on Linux/macOS). Best-effort; absent on some platforms.
rss_kb() {
  ps -o rss= -p "$$" 2>/dev/null | tr -d ' ' || echo "0"
}

run_step() {
  # $1 = label, $2..$N = argv
  local label="$1"; shift
  local log_path="$1"; shift
  local t0 t1 dt_ms rc
  t0=$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || now)
  set +e
  "$BIN" "$@" >>"$log_path" 2>&1
  rc=$?
  set -e
  t1=$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || now)
  dt_ms=$((t1 - t0))
  if [ "$rc" -ge 128 ]; then
    CRASH=$((CRASH + 1))
    echo "  step=$label rc=$rc latency_ms=$dt_ms CRASH" | tee -a "$SUMMARY"
  elif [ "$rc" -ne 0 ]; then
    ERROR=$((ERROR + 1))
    echo "  step=$label rc=$rc latency_ms=$dt_ms error" | tee -a "$SUMMARY"
  else
    echo "  step=$label rc=$rc latency_ms=$dt_ms ok" | tee -a "$SUMMARY"
  fi
}

echo "soak: start duration=${DURATION}s interval=${INTERVAL}s bin=$BIN logdir=$LOGDIR" | tee -a "$SUMMARY"

while [ "$(now)" -lt "$END" ]; do
  CYCLE=$((CYCLE + 1))
  TS=$(ts_utc)
  LOG="$LOGDIR/cycle-${CYCLE}-${TS}.log"
  RSS=$(rss_kb)
  echo "[$TS] cycle=$CYCLE rss_kb=$RSS" | tee -a "$SUMMARY"

  run_step "doctor"    "$LOG" doctor --format json
  run_step "auth.list" "$LOG" auth list --format json
  run_step "measure"   "$LOG" measure --url "$URL" --format json

  echo "[$TS] cycle=$CYCLE crash=$CRASH error=$ERROR" | tee -a "$SUMMARY"

  # If a real crash occurred, fail fast — GA gate requires crash-0.
  if [ "$CRASH" -gt 0 ]; then
    echo "soak: aborting due to crash" | tee -a "$SUMMARY"
    exit 1
  fi

  # Don't sleep past the end window.
  REMAIN=$((END - $(now)))
  if [ "$REMAIN" -le 0 ]; then break; fi
  if [ "$INTERVAL" -lt "$REMAIN" ]; then
    sleep "$INTERVAL"
  else
    sleep "$REMAIN"
  fi
done

echo "soak: complete cycles=$CYCLE crashes=$CRASH errors=$ERROR" | tee -a "$SUMMARY"
[ "$CRASH" -eq 0 ] || exit 1
