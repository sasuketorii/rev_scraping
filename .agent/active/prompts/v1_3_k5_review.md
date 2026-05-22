# Lane K.5 reviewer prompt (Codex)

You are the v1.3 Lane K.5 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.5):

> cargo-fuzz 3 targets: sanitize::layer4_unicode::normalize,
> sanitize::layer2_envelope::parse, MCP JSON-RPC frame parser.
> Acceptance: targets build; nightly GH cron 1h/day; crash artifacts
> pinned as seed.

Artifacts:
- .github/workflows/fuzz-nightly.yml
- (fuzz target source files if present under fuzz/ or crates/*/fuzz/)

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main
- v1.3 partial scope: targets may be YAML-declared without crash corpus yet.

Verify:
1. fuzz-nightly.yml exists and is on cron (1h/day or daily).
2. Workflow references 3 distinct fuzz targets (sanitize unicode normalize,
   sanitize envelope parse, MCP JSON-RPC parser).
3. Crash-artifact upload step is present (or documented as v1.3 partial).

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
