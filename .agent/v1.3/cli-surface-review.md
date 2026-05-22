# Lane G.1 — CLI Surface Inventory + Naming Consistency Review

**Generated:** see `.agent/v1.3/cli-surface.json` (schema v1.1)
**Generator:** `scripts/cli_surface_inventory.py`
**Binary inspected:** `target/debug/rev-stealth` (workspace `stealth-cli` crate)
**Snapshot:** post-baseline commit `6dea6f63` (workspace 776 PASS / 0 fail)

## Summary

- 43 command nodes inventoried (excluding root).
- 11 top-level subcommands.
- 36 leaf commands (nodes with no subcommands; counted across all depths).
- 5 top-level "flat" commands without a `<verb>` layer (see Decisions below).
- 6 canonical exit codes mapped to every node (43/43 coverage, 0 missing).
- 0 kebab-case violations (long flags or command names).
- 0 short-flag collisions.

## Top-level shape

The canonical RevHarness CLI convention is `rev-stealth <noun> <verb>` (kebab
case). Auditing the current 11 top-level subcommands against that contract:

| Top-level    | Verb layer? | Shape                                       | Verdict |
|--------------|-------------|---------------------------------------------|---------|
| captcha      | yes         | `captcha {solve,verify}`                    | OK      |
| browser      | yes         | `browser {launch,stealth-test}`             | OK      |
| vpn          | yes         | `vpn {rotate,status}`                       | OK      |
| auth         | yes         | `auth {login,list,show,delete,status,refresh}` | OK   |
| config       | yes         | `config {show,paths,validate,diff,get,set,edit,migrate,init,history,rollback,gc,profile}` | OK |
| hermes       | yes         | `hermes {install,uninstall,verify}`         | OK      |
| doctor       | no          | `doctor` (flat)                             | KEEP    |
| spider       | no          | `spider` (flat)                             | KEEP    |
| relocate     | no          | `relocate` (flat)                           | KEEP    |
| cf-evaluate  | no          | `cf-evaluate` (flat)                        | KEEP    |
| measure      | no          | `measure` (flat)                            | KEEP    |

## Decisions (G.1 review notes)

1. **Flat top-level commands kept as-is.** `doctor`, `spider`, `relocate`,
   `cf-evaluate`, and `measure` are single-purpose diagnostic / orchestration
   verbs, not nouns with multiple actions. Forcing a `<verb>` layer (e.g.
   `spider run`) would add cognitive overhead with no operational benefit and
   would break every published example in `docs/` and prior README runbooks.
   Documented as `info-flat-top-level` in `cli-naming-lint.json` so future
   reviewers can confirm intentional.

2. **`config profile` is the only 3-level path.** `rev-stealth config profile
   {list,create,switch,delete}`. This is a legitimate nested-noun pattern
   (config has a profile subgroup with its own verbs) and matches the
   convention.

3. **`spider` flag count (36) is an outlier.** Not a naming issue, but a flag
   to G.5 (dry-run / explain) and G.7 (unified error template): `spider`
   accumulates options across `--use-auth`, `--use-cf`, `--use-recipe`,
   `--auto-learn`, etc. The G.4 JSON-output schema for `spider` will be the
   largest. Tracked as scope for G.4–G.7.

## Drift gate (for G.2 / G.3 / CI)

`scripts/cli_surface_inventory.py` is deterministic. CI can run:

```
cargo build -p stealth-cli --bin rev-stealth
python3 scripts/cli_surface_inventory.py \
    --bin ./target/debug/rev-stealth \
    --out /tmp/cli-surface-fresh.json \
    --lint-out /tmp/cli-naming-lint-fresh.json
diff -u .agent/v1.3/cli-surface.json /tmp/cli-surface-fresh.json
diff -u .agent/v1.3/cli-naming-lint.json /tmp/cli-naming-lint-fresh.json
```

A non-empty diff means a CLI change was made without regenerating the
inventory — gate fails. G.3 wires this into the actual workflow file.

The script also prints `cli-surface: N command nodes inventoried`, and the
top-level JSON now carries an `exit_code_coverage` block (currently
`{total_commands: 43, mapped_commands: 43, missing: []}`). If a new sub-command
is added without registering it in `COMMAND_EXIT_CODES` inside
`scripts/cli_surface_inventory.py`, the script writes a warning to stderr and
the `missing` array becomes non-empty — CI should fail on that.

## Files (G.1 deliverable)

- `$REPO_ROOT/scripts/cli_surface_inventory.py` (new, executable)
- `$REPO_ROOT/.agent/v1.3/cli-surface.json` (new, generated)
- `$REPO_ROOT/.agent/v1.3/cli-naming-lint.json` (new, generated)
- `$REPO_ROOT/.agent/v1.3/cli-surface-review.md` (this file)
