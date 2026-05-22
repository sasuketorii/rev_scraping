# Review P6.5 round-2 — BLOCK fix applied

file: crates/stealth-cli/src/commands/config_cli.rs

## Round-1 BLOCK
Reviewer flagged: `config_base_dir()` derived profiles_root from
$REV_SCRAPING_HOME. After `profile switch alpha` exports
REV_SCRAPING_HOME=<base>/profiles/alpha, the next call resolves
profiles_root to `<base>/profiles/alpha/profiles` (nested), and the
active-profile delete guard compares against a wrong nested path
(returns profile_not_found instead of profile_active).

## Fix
- Removed `config_base_dir()`.
- New `profiles_root()` is DECOUPLED from $REV_SCRAPING_HOME:
  1. `$REV_SCRAPING_PROFILES_ROOT` (registry override; test + opt-in)
  2. `~/.rev_scraping/profiles/` (default; ignores REV_SCRAPING_HOME)
  3. `./.rev_scraping/profiles/` (fallback when HOME unset)
- Doc-comment pins the invariant: REV_SCRAPING_HOME is the *activation*
  env; the *registry* is independent so list/create/delete still find
  siblings after switch.
- `profile_dir()` doc updated; switch hint still
  `export REV_SCRAPING_HOME=<profile_dir>`.
- Active-profile delete guard logic unchanged but now correct because
  profile_dir is stable across activations.

## Tests added (2 new, total P6.5 = 7)
1. profile_registry_decoupled_from_rev_scraping_home — create alpha,
   then set REV_SCRAPING_HOME=<alpha_dir>; assert profiles_root() does
   NOT resolve to `<alpha>/profiles` and that alpha is still found.
2. profile_delete_active_profile_refused — construct ConfigLocations
   whose policy.parent() == profile_dir("alpha"); delete returns
   exit 2; dir survives. This is the exact invariant the reviewer
   said the round-1 code could not prove.
- with_home_override now toggles REV_SCRAPING_PROFILES_ROOT, restored on drop.

## Gates PASS
- cargo check --workspace clean
- cargo test --workspace --no-fail-fast: 653 PASS / 0 FAIL (641 baseline
  → 646 after P6.4 → 651 after P6.5 round-1 → 653 with round-2 +2)
- cargo clippy -p stealth-cli --all-targets -- -D warnings clean
- CLI smoke: config profile --help lists list/create/switch/delete
- baseline diff untouched
- ConfigWriter still enforced for all seeding
- Secret redaction surfaces preserved L1

## REV_HARNESS_DELEGATION_METRIC
REV_HARNESS_DELEGATION_METRIC sub_phase=P6.5 round=2 tests_added=7 workspace_pass=653 clippy=clean registry_env=REV_SCRAPING_PROFILES_ROOT activation_env=REV_SCRAPING_HOME decoupled=true active_delete_guard=verified

verdict: LGTM or BLOCK: <reason>
