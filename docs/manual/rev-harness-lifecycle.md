# rev-harness — Adopter Lifecycle CLI Reference
> Operator reference for the vendor-neutral `scripts/rev-harness` lifecycle
> facade. The facade calls existing lifecycle scripts; it does not absorb their
> state machines or make deferred mutation paths real.
## CLI surface table
The canonical entrypoint is:
```bash
bash scripts/rev-harness [global flags] <sub-command> [args]
```
Global flags are parsed by the facade before dispatch.
| Flag | 動作 |
|---|---|
| `--target <path>` | Select adopter root explicitly. Highest priority in target resolution. |
| `--dry-run` | Request non-mutating behavior where the child command supports it. |
| `--json` | Request machine-readable output or a facade envelope where implemented. |
| `--strict` | Pass strict mode to doctor-backed checks where implemented. |
| `--verbose` | Request verbose child output where implemented. |
| `--with-mcp-wire` | After successful setup, request semantic MCP merge into the target `.mcp.json`. |
| `--help`, `-h` | Print facade help or pass help through when already inside a command. |
Sub-command behavior:
| Sub-command | 動作 | exit codes |
|---|---|---|
| `install` | Runs the adopter setup flow through `rev-harness-install.sh`, which delegates to `rev-harness-adopter-setup.sh setup`. | `0` success; `2` CLI/prerequisite; `10..16`, `70..72` from setup; child exit otherwise |
| `setup` | Alias of `install --setup-only`; still delegates through the install composer. | Same as `install` |
| `verify` | Runs `harness-doctor.sh --quick` for the target. | Doctor exit code |
| `doctor` | Alias of `verify`. | Doctor exit code |
| `repair` | Runs `rev-harness-repair.sh`; emits one advisory suggestion after doctor. | `0` advisory emitted; `2` CLI misuse before doctor; facade validation errors may propagate |
| `status` | Reads `.rev-harness-state/state.json` when present and runs quick doctor state reporting. | `0`; `64` on project identity mismatch |
| `clean` | Runs `rev-harness-janitor.sh build-cleanup`; if unsupported, falls back to `inspect`. | Janitor exit code; `2` for invalid cleanup arguments |
| `upgrade` | Runs `rev-harness-upgrade.sh inspect` or `plan`; `apply` is deferred and rejected. | `0` for successful inspect/plan; `2` for unknown action or deferred apply |
| `uninstall` | Prints uninstall checklist through `rev-harness-uninstall.sh`; `--apply` is deferred and rejected. | `0` checklist printed; `2` for deferred apply or CLI misuse |
| `help` | Prints facade usage and deferred-operation note. | `0` |
The facade uses advisory locking for mutating-capable lifecycle surfaces:
`install`, `setup`, `repair`, `clean`, and `uninstall`.
When lock acquisition times out, setup reports lease timeout as exit `71`.
Facade JSON output, when present, uses `rev-harness-facade/v1`.
The facade records command history in `.rev-harness-state/state.json` only when
a state file already exists and the command is not dry-run.
`verify` and `doctor` execute doctor directly and do not use the facade envelope.
Unknown facade sub-commands exit `2`.
## install 5-phase FSM
`scripts/rev-harness-install.sh` is a thin composer.
It accepts facade-compatible flags and then executes:
```bash
bash scripts/rev-harness-adopter-setup.sh setup ...
```
The setup FSM has five phases, in this exact order:
1. `phase_init`
2. `phase_semantic_node` (legacy state key; runs Rust semantic bootstrap)
3. `phase_semantic_rust`
4. `phase_hooks`
5. `phase_doctor`
The on-disk state path is:
```bash
.rev-harness-state/state.json
```
The state schema identifier is:
```json
{
  "schema": "rev-harness-state/v1"
}
```
The state file also carries `run_id`, `phase`, `current_phase`, `phases`,
`history`, `last_install_at`, `started_at`, and `last_updated`.
Legacy state paths are maintained as relative symlinks when state is written:
| Legacy path | Target |
|---|---|
| `.shared/rev-harness-adopter-setup.state.json` | `../.rev-harness-state/state.json` |
| `.agent/registry/rev_harness_adoption_state.json` | `../../.rev-harness-state/state.json` |
Phase command mapping:
| FSM phase | Command body |
|---|---|
| `phase_init` | Runs `scripts/init-project.sh adopter` in the target. |
| `phase_semantic_node` | Runs Rust-only `scripts/semantic-bootstrap.sh` in the target unless heavy smoke skip is set. The phase key is retained for state/exit-code compatibility; it does not require the retired Node semantic tree. |
| `phase_semantic_rust` | Runs `cargo build --release -p semantic-mcp` in target `harness-rust` when that workspace exists. |
| `phase_hooks` | Runs `scripts/install-rev-harness-hooks.sh install` in the target. Installs the `pre-commit` guard hook only. The opt-in `post-commit` semantic index hook is NOT installed by setup; enable it explicitly (see below). |
| `phase_doctor` | Runs `scripts/harness-doctor.sh --quick --json`, plus `--strict` when requested. |
`REV_HARNESS_SMOKE_SKIP_HEAVY=1` skips Rust bootstrap under `phase_semantic_node` and
`phase_semantic_rust`.
If the target has no `harness-rust` directory, `phase_semantic_rust` is skipped.
Per-phase owner-token paths are limited to phases that declare owner files:
| Phase | owner_token paths |
|---|---|
| `phase_init` | `.gitignore`; `.shared/project_id` |
| `phase_hooks` | `.claude/settings.json`; `.git/hooks/pre-commit` |
| `phase_semantic_node` | No owner-token file path declared by setup. Legacy phase key; Rust-only bootstrap. |
| `phase_semantic_rust` | No owner-token file path declared by setup. |
| `phase_doctor` | No owner-token file path declared by setup. |
Phase input hashes are derived from owner-token paths when a phase has them.
Phases without owner-token paths use a phase-local placeholder input.
### post-commit semantic index hook (opt-in)
`phase_hooks` installs only the `pre-commit` guard hook. A separate, opt-in
`post-commit` hook keeps the semantic-mcp index fresh by incrementally
re-indexing each commit. It is NOT installed by default; enable it explicitly:
```bash
bash scripts/install-rev-harness-hooks.sh \
  --harness-root <harness> --adopter-root <adopter> --with-index-hook
# prerequisite: cargo build --release -p agent-core
```
The generated `.git/hooks/post-commit` captures immutable `POST_HEAD` and
`POST_BASE` values before detaching. The detached worker runs
`agent-core context index-commit --head "$POST_HEAD" --base "$POST_BASE" --apply`
in the adopter cwd for ordinary commits, omits `--base` for root commits, and
writes bounded redacted logs/evidence under `.git/rev-harness/`. This upserts
the just-committed source-filtered change into the live semantic-mcp db without
blocking the commit. Properties:
| Property | Behavior |
|---|---|
| fail-open | The hook always `exit 0`; it never blocks a commit. |
| async | The index run is detached (`setsid`/`nohup`), so commit latency stays ~zero. |
| binary discovery | Release preferred, debug fallback, `REV_HARNESS_AGENT_CORE_BIN` override; a missing binary is logged to `.git/rev-harness/post-commit-index.log` and skipped fail-open. |
| idempotent | Re-running the installer rewrites a byte-identical hook (single `# rev-harness-hooks installed` marker). |
| status / uninstall | `--status` reports and `--uninstall` removes both `pre-commit` and `post-commit`. |
Operational note: `index-commit` upserts only commit-changed files
(`gc_orphans=false`), so symbols for deleted or renamed files are NOT reaped.
Run `agent-core context index-all` (or `semantic-bootstrap.sh --index-all`)
periodically to sweep those orphans.
Per-phase failure exit codes:
| Phase | Failure code |
|---|---:|
| `phase_init` | `10` |
| `phase_semantic_node` | `11` |
| `phase_semantic_rust` | `12` |
| `phase_hooks` | `13` |
| `phase_doctor` | `14` |
Additional setup exit codes:
| Code | Meaning |
|---:|---|
| `15` | `state.json` corruption or rollback snapshot verification failure. |
| `16` | Resume requested but no state file exists. |
| `70` | Vendoring detected by canonical guard. |
| `71` | Lease timeout. |
| `72` | Self-install refused. |
Setup emits JSONL phase events with schema `adopter_setup/v1`.
With `--json`, setup emits a final report with schema version
`rev-harness-adopter-setup-report/v1`.
When setup reaches doctor successfully, state phase becomes `done`.
`last_install_at` is written after a successful non-verify setup run.
When `--with-mcp-wire` is set, setup runs MCP wiring only after all FSM phases
complete successfully.
MCP wiring is skipped during dry-run.
## resume + rollback
Resume is exposed by `rev-harness-adopter-setup.sh resume` and by `--resume`.
`--resume` re-runs from the first failed or pending phase.
Already successful phases are skipped only when their recorded input sha256
matches the current input sha256.
If resume is requested without `.rev-harness-state/state.json`, setup exits `16`.
State corruption during resume exits `15`.
Rollback is exposed by:
```bash
bash scripts/rev-harness-adopter-setup.sh setup --rollback <step>
bash scripts/rev-harness-adopter-setup.sh setup --rollback all
```
Rollback restores owner-token files from pre-step snapshots.
Snapshots live under:
```bash
.rev-harness-state/snapshots/<run_id>/
```
Snapshot manifests are named:
```bash
pre-<phase>.sha256
```
For owner-token files that existed before the phase, rollback copies the saved
file back and verifies its sha256.
For owner-token files that were missing before the phase, rollback removes the
post-phase file.
If a phase has no owner-token paths and no snapshot manifest, rollback resets
that phase to `pending` in state.
`--rollback all` processes phases in reverse order:
`doctor`, `hooks`, `semantic_rust`, `semantic_node`, `init`.
Rollback is non-mutating under `--dry-run`.
Rollback failures exit `15`.
## TARGET_ROOT resolver
Lifecycle target resolution is centralized through the canonical guard helper.
Priority order:
1. `--target <path>`
2. `REV_HARNESS_ADOPTER_ROOT`
3. Current working directory from `pwd`
The resolved target becomes both `TARGET_ROOT` and `PROJECT_ROOT`.
The facade stores:
| Variable | Value |
|---|---|
| `TARGET_ROOT` | Resolved adopter project root. |
| `PROJECT_ROOT` | Same value as `TARGET_ROOT` for lifecycle commands. |
| `STATE_FILE` | `$TARGET_ROOT/.rev-harness-state/state.json` |
| `LOCK_FILE` | `$TARGET_ROOT/.agent/registry/.rev-harness-facade.lock` |
`install` and `setup` use the self-install guard.
The guard compares the resolved target realpath with `HARNESS_ROOT`.
If the target matches the harness checkout itself, setup refuses self-install
and exits `72`.
Other facade commands resolve roots without that self-install guard.
If a target path cannot be accessed, the resolver exits `2`.
## uninstall checklist
Phase G uninstall is checklist-only.
The facade command is:
```bash
bash scripts/rev-harness uninstall
```
It delegates to:
```bash
bash scripts/rev-harness-uninstall.sh --print-checklist
```
The checklist has six steps:
| Step | Checklist item |
|---:|---|
| `1` | Remove canonical PATH export lines from shell rc files. |
| `2` | Delete adopter state at `.agent/registry/rev_harness_adoption_state.json`. |
| `3` | Inspect `.claude/` and `.agent/active/` before removing RevHarness-created links or dirs. |
| `4` | Restore `.git/hooks/pre-commit` from `.git/hooks/pre-commit.rev-harness.bak` if needed; if the opt-in index hook was enabled, also remove `.git/hooks/post-commit` (or run `install-rev-harness-hooks.sh --uninstall`). |
| `5` | Decide what to do with `.shared/project_id`; it is immutable project identity. |
| `6` | Treat canonical cargo target cleanup as canonical-side, not adopter-side uninstall state. |
The canonical cargo target note points to:
```bash
${HOME}/dev/rev_harness/harness-rust/target
```
`--json` prints the same checklist as structured JSON.
`--apply` is deferred to Phase G+1.
If `--apply` is passed, uninstall prints the deferred message and exits `2`
immediately.
No uninstall script path currently removes adopter files.
## upgrade inspect
Upgrade foundation supports read-only inspection and read-only planning.
Inspect command:
```bash
bash scripts/rev-harness upgrade inspect --target <dir>
```
Plan command:
```bash
bash scripts/rev-harness upgrade plan --target <dir> --source-ref <ref>
```
`inspect` compares adopter state against the distribution manifest:
```bash
.agent/registry/rev_harness_distribution_manifest.json
```
It reports git state, known lifecycle directories, `.shared/project_id`,
legacy naming hits, and distribution metadata.
`plan` is also read-only.
`plan` resolves preserve globs and managed candidate globs from the manifest.
`plan` detects dirty managed candidate paths as blockers.
`plan --output <file>` may write the generated plan under the target path.
That output is a plan artifact, not an apply operation.
`apply` is not implemented in the foundation.
`upgrade apply` fails closed with exit `2`.
The facade also rejects `upgrade apply` as deferred to Phase G+1.
## clean (build-cleanup)
The facade command is:
```bash
bash scripts/rev-harness clean
```
It delegates to:
```bash
bash scripts/rev-harness-janitor.sh build-cleanup
```
If `build-cleanup` is unavailable and the child output reports `unknown`, the
facade falls back to:
```bash
bash scripts/rev-harness-janitor.sh inspect
```
`build-cleanup` uses a C-hybrid cleanup policy.
A target is eligible only when all cleanup gates pass:
| Gate | Requirement |
|---|---|
| Age | Newest mtime must be at least `--max-age-days` old. Default is `14`. |
| Protection | Path must not be a protected path. |
| mtime shield | Newest mtime must be at least 24 hours old. |
Default mode is `--dry-run`.
`--apply` requires:
```bash
--apply --ack-rebuild-cost
```
If `--apply` is used without `--ack-rebuild-cost`, the command exits `2`.
Protected paths and classes include:
| Protected surface | Rule |
|---|---|
| `target/release/<latest>` | Release output is not a build-cleanup target. |
| `target/criterion/` | Criterion benchmark data is protected. |
| `.agent/active/**` | Active agent state is protected. |
| `.git/**` | Git internals are protected. |
| `mtime <24h` | Recent paths are shielded. |
| Symlinks | Symlink cleanup targets are protected. |
| Non-directories | Non-directory cleanup targets are protected. |
Current build-cleanup target set:
| Target |
|---|
| `harness-rust/target/debug` |
| `harness-rust/target/incremental` |
| `$HOME/.cargo/registry/cache` |
Semantic MCP database files under `$HOME/.semantic-mcp` are delegated to
semantic-mcp GC by advisory output, not deleted by build-cleanup.
Metrics are written to:
```bash
.agent/metrics/build_cleanup.jsonl
```
When `REVHARNESS_BUILD_CLEANUP_ON_STOP=1`, the command writes hints instead of
applying cleanup.
Hint metrics path:
```bash
.agent/metrics/build_cleanup_hints.jsonl
```
When `REVHARNESS_PARALLEL_QUIESCE=1`, `build-cleanup` skips and exits `0`.
## skill trigger table
The lifecycle skill maps operator phrases to facade sub-commands.
| Phrase | Language | Sub-command |
|---|---|---|
| `revharness 入れて` | Japanese | `rev-harness install` |
| `初回セットアップ` | Japanese | `rev-harness install` |
| `enable rev_harness` | English | `rev-harness install` |
| `doctor 回して` | Japanese | `rev-harness verify` |
| `動いてる?` | Japanese | `rev-harness verify` |
| `verify rev_harness` | English | `rev-harness verify` |
| `壊れた、直して` | Japanese | `rev-harness repair` |
| `repair rev_harness` | English | `rev-harness repair` |
| `状態` | Japanese | `rev-harness status` |
| `status` | English | `rev-harness status` |
| `アップグレード見て` | Japanese | `rev-harness upgrade inspect` |
| `upgrade inspect` | English | `rev-harness upgrade inspect` |
| `アンインストール手順` | Japanese | `rev-harness uninstall` |
| `uninstall checklist` | English | `rev-harness uninstall` |
Negative triggers:
| Phrase or surface | Route instead |
|---|---|
| `.claude/tmp` cleanup | `development-junk-cleanup` |
| Session start or orchestrator wake-up | `orchestrator-bootstrap` |
| Client packaging or distribution readiness | `client-distribution-readiness` |
The lifecycle skill does not authorize destructive apply paths.
Destructive paths still require the explicit command-level opt-in described by
the scripts and invariants.
## Invariants I-10 and I-11
I-10: Call out, never absorb.
The `scripts/rev-harness` facade must call out to existing lifecycle scripts.
It must not absorb their state machines, rewrite their ownership model, or
mutate adopter project state during inspect-only paths.
Relevant child scripts include:
| Child script |
|---|
| `scripts/rev-harness-install.sh` |
| `scripts/rev-harness-adopter-setup.sh` |
| `scripts/rev-harness-uninstall.sh` |
| `scripts/rev-harness-repair.sh` |
| `scripts/rev-harness-mcp-wire.sh` |
The failure mode for I-10 is facade absorption, such as overwriting
`.shared/project_id` or deleting adopter files without an apply-authorized path.
I-11: Destructive opt-in.
Destructive commands must default to dry-run, checklist, inspect, or fail-closed
behavior.
A destructive action requires an explicit opt-in pair.
For build cleanup, the opt-in pair is:
```bash
--apply --ack-rebuild-cost
```
For uninstall, `--apply` is deferred to Phase G+1 and exits `2`.
For upgrade, `apply` is not implemented in the foundation and exits `2`.
Silent destructive defaults violate I-11.
## Cross-references
Primary operator guide:
- `docs/adoption-guide.md`
Canonical invariant index:
- `docs/canonical-invariants.md`
Dispatch safety manual:
- `docs/manual/safe-dispatch.md`
Lifecycle skill source:
- `.claude/skills/rev-harness-lifecycle/SKILL.md`
Related scripts:
- `scripts/rev-harness`
- `scripts/rev-harness-install.sh`
- `scripts/rev-harness-adopter-setup.sh`
- `scripts/rev-harness-uninstall.sh`
- `scripts/rev-harness-repair.sh`
- `scripts/rev-harness-mcp-wire.sh`
- `scripts/rev-harness-janitor.sh`
- `scripts/rev-harness-upgrade.sh`
