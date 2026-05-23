# Round 2 — Slice B-2 review

## Round 1 findings (addressed)

1. **Trailing blank line at EOF of `.github/workflows/ci.yml`** — removed.
   `git diff --check -- .github/workflows/ci.yml tests/install_sh_unit.sh` now exits 0.

2. **Ambient `rm` under `set -e`** — hardened in two places:
   - **Outer shell PATH** is now pinned at top of script to standard system locations,
     so trap/cleanup never resolves through workspace-injected wrappers:
     ```sh
     PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
     export PATH
     ```
     (Comment notes the fake PATH used in e2e cases is scoped to the inner `sh -c` invocation only.)
   - Cleanup `rm -rf` calls now non-fatal: `rm -rf "${path}" 2>/dev/null || :`
     in both the trap on `WORK_ROOT` and the per-case sandbox cleanup inside `check_target`.

## Diff (round 2 delta)

```
$ git diff tests/install_sh_unit.sh
@@ -22,7 +22,15 @@
 set -eu

 unset CDPATH
+# Pin PATH to standard locations so that `rm`, `mkdir`, `awk`, `grep`, `tar`,
+# `mktemp`, and `sed` resolve to system tools even when this script is run
+# from a workspace that injects its own wrappers earlier on PATH. The fake
+# PATH used by the e2e cases is scoped to the inner `sh -c` invocation only;
+# the outer shell (including trap/cleanup) always uses the path below.
+PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
+export PATH
+
 REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
 INSTALL_SH="${REPO_ROOT}/install.sh"
@@ -33,7 +41,7 @@
 TESTS_RUN=0
 TESTS_FAIL=0
 WORK_ROOT="$(mktemp -d)"
-trap 'rm -rf "${WORK_ROOT}"' EXIT INT TERM
+trap 'rm -rf "${WORK_ROOT}" 2>/dev/null || :' EXIT INT TERM
@@ check_target()
-    rm -rf "${sandbox}"
+    rm -rf "${sandbox}" 2>/dev/null || :
```

`.github/workflows/ci.yml` lost only the trailing blank line.

## Re-verification

```
$ git diff --check -- .github/workflows/ci.yml tests/install_sh_unit.sh
(rc=0, no whitespace errors)

$ shellcheck -s sh install.sh tests/install_sh_unit.sh
(rc=0)

$ sh tests/install_sh_unit.sh
Ran 13 tests, 0 failed.

$ dash tests/install_sh_unit.sh
Ran 13 tests, 0 failed.
```

## Out-of-scope reminder

B-3 (Cargo workspace mass rename + topological `publish = true` flips) is the next driver's slice and is deliberately not touched here.

## Sign-off

`LGTM` + 1-line rationale if both round-1 items are satisfied. Otherwise list remaining diffs with file:line.
