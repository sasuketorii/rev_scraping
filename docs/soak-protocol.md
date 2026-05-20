# 7-Day Soak Protocol (v1.1.0 GA gate)

The v1.1.0 GA tag cannot be pushed until a 7-day continuous soak of the
`rev-stealth` release binary completes with **crash count = 0** on the
candidate SHA. This document is the operator playbook.

This is one of the 24 GA-gate items in `docs/release-checklist.md`
("7-day soak crash-0"). It is calendar-bound: a release manager owns the
calendar window and observes the run; engineering only owns the runner
script and the analysis criteria.

## Definitions

| term | meaning |
| --- | --- |
| **cycle** | one pass through the soak step list (currently 3 steps: `doctor`, `auth list`, `measure --url …`) |
| **crash** | a subprocess exits with code `>= 128` (signal-killed), or `cargo`/`rev-stealth` panics — these are GA blockers |
| **error** | a subprocess exits non-zero but `< 128` — tracked for trending; not a blocker by itself |
| **drift** | RSS growth, descriptor growth, or latency growth that exceeds the thresholds below |

## Pre-flight (T-1 day)

1. Pick a host that will stay online for 7 + 1 days. Prefer a dedicated
   Linux box that mirrors CI; macOS is acceptable for a parallel run but
   not the canonical environment.
2. Build the release binary on the candidate SHA:
   `cargo build --release --bin rev-stealth`.
3. Bring up the `gluetun` Docker container so `doctor` rc=0 (otherwise
   every cycle logs an environmental rc=7).
4. Ensure at least 20 GiB free under `~/.rev_scraping/soak/`. With the
   default 5-minute interval, expect ~2016 cycle logs over 7 days,
   typically < 200 MiB total.
5. Disable host auto-sleep and OS update reboots for the soak window.
6. Run a 4-minute smoke first (see "Smoke" below) to confirm the script
   and binary work on the chosen host.

## Start

```bash
cd <repo-root>
nohup bash scripts/run_soak.sh > ~/.rev_scraping/soak/nohup.out 2>&1 &
echo $! > ~/.rev_scraping/soak/soak.pid
```

Defaults: `DURATION=604800` (7 d), `INTERVAL=300` (5 min),
`LOGDIR=~/.rev_scraping/soak`, `BIN=./target/release/rev-stealth`.

The script aborts immediately on any crash (subprocess rc >= 128) so the
release manager learns of a blocker within one cycle.

## Monitoring (each day)

Tail the summary:

```bash
tail -f ~/.rev_scraping/soak/soak-summary.log
```

Per-day, record in the release issue:

- `cycles=N crash=0 error=E` from the latest summary line
- `ps -o pid,rss,etime -p $(cat ~/.rev_scraping/soak/soak.pid)`
- `df -h ~/.rev_scraping/soak`
- spot-check one random cycle log for unexpected stderr

Thresholds (any breach is a release-manager decision, not an auto-block):

| metric | threshold |
| --- | --- |
| RSS growth | < 10 % over 7 d, absolute < 200 MiB |
| step latency p95 | < 2x cycle-1 p95 |
| error rate | < 1 % per step (excluding environmental `doctor` rc=7) |
| disk usage | log directory < 1 GiB |

## Pause / resume

The runner is stateless within a cycle. To pause:

```bash
kill $(cat ~/.rev_scraping/soak/soak.pid)
```

Logs are preserved. To resume with a fresh window, re-launch as above —
record the pause in the release issue so the 7-day window is extended
accordingly. **Do not edit existing log files** to make a run "look"
continuous; the GA gate is honest crash-0, not paperwork.

## Triage on failure

When the runner aborts with a crash:

1. Capture the offending `cycle-N-*.log` and any core dump.
2. `dmesg | tail -200`, `ulimit -a`, and `uname -a` to the issue.
3. Re-run just the failing step under `RUST_BACKTRACE=1` to get a panic
   site.
4. File a GA-blocker bug. The release manager decides whether the fix
   ships in v1.1.0 (restart the 7-day clock after the patch lands and
   another smoke passes) or v1.1.1 (downgrade GA gate decision).
5. Errors (rc 1–127) trending up over time are also reportable — open a
   non-blocking issue and continue the soak.

## Log rotation and artifact upload

Logs are written one file per cycle to keep `grep` cheap and to make
upload selective. After the soak completes:

```bash
tar -C ~/.rev_scraping/soak -czf soak-v1.1.0-<sha>.tar.gz .
sha256sum soak-v1.1.0-<sha>.tar.gz
```

Upload the tarball + checksum to the release artifact store referenced
in the release issue. Retain for at least one minor version (until
v1.2.0 GA).

## Smoke (pre-soak sanity, ~4 minutes)

```bash
LOGDIR=/tmp/soak_smoke bash scripts/run_soak.sh 240 60
```

Pass criteria: `crashes=0`, RSS delta < 5 %, all `auth list` and
`measure` rc=0. A representative smoke result lives at
`.agent/active/v1_1_p19_soak_smoke.md`.

## Sign-off

The GA gate item "7-day soak crash-0" in `docs/release-checklist.md` is
ticked when **all** of the following hold:

- soak ran for the full configured duration (no shortened window without
  a documented release-manager exception),
- final summary line reads `crash=0`,
- monitoring thresholds above were either respected or escalated,
- the tarball + checksum is uploaded and linked from the release issue,
- the release manager, security lead, and QA lead acknowledge the run.

Anything less is a release-block.
