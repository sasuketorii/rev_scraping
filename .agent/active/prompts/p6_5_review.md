# Review P6.5 — config profile {list, create, switch, delete}

file: crates/stealth-cli/src/commands/config_cli.rs (additive)

## Slice
- ConfigAction::Profile(ProfileAction) with List/Create/Switch/Delete subcommands
- Profile root = `<base>/profiles/<name>/`; base = $REV_SCRAPING_HOME or
  ~/.rev_scraping (mirrors ConfigLocations::resolve)
- validate_profile_name: `[A-Za-z0-9_-]{1..=64}` — rejects `/`, `\`, `..`,
  `.hidden`, whitespace, control chars
- create: ensure_dir_0700 + init_file via ConfigWriter for policy/authorized,
  init_sites_dir for sites/. Refuses pre-existing profile (exit 2)
- switch: requires existing dir (exit 2 if missing); stdout = literal
  `export REV_SCRAPING_HOME=<dir>` for eval; banner to stderr; JSON path
  returns ProfileSwitchHint
- delete: --yes required (exit 2 without); refuses to delete the currently
  active profile (locs.policy.parent() == profile_dir); shred_walk overwrites
  regular files with zeros (skips symlinks, best-effort), then remove_dir_all
- PROFILE_ACTIVATE_ENV const = "REV_SCRAPING_HOME" pinned in tests
- SPDX L1 preserved; no new deps; ConfigWriter trait reused for seeding

## Tests added (5)
1. profile_list_empty — fresh home exit 0, profiles_root not auto-created
2. profile_create_seeds — alpha dir + policy + authorized + sites seeded;
   re-create → exit 2 (no mutation)
3. profile_create_rejects_traversal_name — `../etc`, `a/b`, `a\b`, `..`,
   `.hidden`, `with space` all → exit 2, no dir created
4. profile_switch_prints_env_hint — export line starts with
   `export REV_SCRAPING_HOME=`; unknown profile → exit 2
5. profile_delete_shreds — without --yes exit 2 (dir survives); with --yes
   → exit 0 and dir removed
- HomeGuard restores $REV_SCRAPING_HOME on drop; serialized via ENV_LOCK

## Gates PASS
- cargo check --workspace clean
- cargo test --workspace --no-fail-fast: 651 PASS / 0 FAIL (646 → 651)
- cargo clippy -p stealth-cli --all-targets -- -D warnings clean
- CLI smoke: `config profile --help` lists 4 subcommands
- baseline diff untouched

## REV_HARNESS_DELEGATION_METRIC
REV_HARNESS_DELEGATION_METRIC sub_phase=P6.5 tests_added=5 workspace_pass=651 clippy=clean profile_env=REV_SCRAPING_HOME shred=best_effort active_delete_guard=true

verdict: LGTM or BLOCK: <reason>
