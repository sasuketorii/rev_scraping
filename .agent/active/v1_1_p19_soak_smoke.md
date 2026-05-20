# P19 — soak smoke run (proof of concept)

Date: 2026-05-19
Operator: M6/P19 coder (Claude opus 4.7-medium)
Binary: `./target/release/rev-stealth` (v1.1.0 release build)
Host: darwin 25.5.0 (no gluetun container present)

## Invocation

```bash
LOGDIR=/tmp/soak_smoke bash scripts/run_soak.sh 240 60
```

- Duration: 240 s window
- Interval: 60 s
- Per-cycle steps: `doctor --format json`, `auth list --format json`,
  `measure --url https://example.com --format json` (local-only)

## Result summary

| metric | value |
| --- | --- |
| cycles completed | 4 |
| crashes (rc >= 128) | **0** |
| errors (rc != 0, rc < 128) | 4 (one per cycle, all `doctor` rc=7) |
| RSS at cycle 1 | 8608 KB |
| RSS at cycle 4 | 8672 KB |
| RSS delta over run | +64 KB (~0.7%) — within noise |

### Latency (per step, ms)

| step | min | max | avg |
| --- | --- | --- | --- |
| doctor    | 306 | 362 | 325 |
| auth.list |  23 |  28 |  26 |
| measure   |  19 |  21 |  20 |

## Error classification

All four `doctor` exit-7 events trace to a single environmental cause: the
host has no `gluetun` Docker container, so `kill-switch`, `dns-lock`, and
`ipv6` probes report `Docker responded with status code 404: No such
container: gluetun`. This is **not a binary crash** and is expected on
developer machines. The exit-7 result is deterministic — no signal,
no panic, JSON output still well-formed. On a GA-soak host with the
gluetun stack running, `doctor` will return rc=0.

`auth list` and `measure` returned rc=0 every cycle.

## Crash-0 judgement

**PASS for smoke gate.** Zero signal-killed exits across 12 step
invocations (4 cycles × 3 steps). RSS growth is bounded. Per-step latency
is stable.

This smoke run does not satisfy the GA-gate 7-day soak requirement; it
proves the runner script, the log discipline, and the absence of any
short-window regression. The real GA soak is operator-driven per
`docs/soak-protocol.md`.

## Secret-leak check

`grep -iE "cookie|password|secret|credential|token"` across every cycle
log returned no match. `auth list` emitted `{"profiles":[]}` (no profiles
configured on this host); `measure` ran in local mode (no
`--enable-external`). Safe to upload as a release artifact.

## Artifacts

- `/tmp/soak_smoke/cycle-1-20260519T094210Z.log`
- `/tmp/soak_smoke/cycle-2-20260519T094310Z.log`
- `/tmp/soak_smoke/cycle-3-20260519T094411Z.log`
- `/tmp/soak_smoke/cycle-4-20260519T094511Z.log`
- `/tmp/soak_smoke/soak-summary.log`
