# Lane I R2 fix-up — post-R2-scoring hardening (ROUND 2)

Role: reviewer (Codex gpt-5.5 xhigh). Round 1 found 1 issue: `mapfile -t WORKSPACE_LIBS < <(...)` swallows process-substitution exit status under `set -euo pipefail` — a metadata or helper failure would silently yield an empty crate list and "no diff" pass. Fixed.

## Round 1 → Round 2 delta

`.github/workflows/ci.yml::cargo-public-api-diff`:

```diff
-          mapfile -t WORKSPACE_LIBS < <(
-            cargo metadata --no-deps --format-version=1 \
-              | python3 scripts/workspace-lib-crates.py
-          )
+          metadata_json="$tmpdir/cargo-metadata.json"
+          if ! cargo metadata --no-deps --format-version=1 > "$metadata_json"; then
+            echo "::error::cargo metadata --no-deps failed; cannot enumerate workspace lib crates."
+            exit 1
+          fi
+          crate_list="$tmpdir/workspace-libs.txt"
+          if ! python3 scripts/workspace-lib-crates.py < "$metadata_json" > "$crate_list"; then
+            echo "::error::scripts/workspace-lib-crates.py failed; cannot enumerate workspace lib crates."
+            exit 1
+          fi
+          mapfile -t WORKSPACE_LIBS < "$crate_list"
+          if [[ "${#WORKSPACE_LIBS[@]}" -eq 0 ]]; then
+            echo "::error::workspace lib crate list is empty — refusing to fall through with zero coverage."
+            exit 1
+          fi
```

Three explicit gates:
1. `cargo metadata` exit code checked.
2. `workspace-lib-crates.py` exit code checked.
3. Empty crate-list explicitly rejected.

The temp-file materialization removes the process-substitution race entirely.

## Local validation

```
$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML OK
YAML OK
$ bash scripts/cli-public-api-snapshot.test.sh | tail -1
[fixture-test] results: 8 passed, 0 failed
```

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
