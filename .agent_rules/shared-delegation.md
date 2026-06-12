# Shared Delegation Rules

Charter: cross-agent invocation truth. Vendor files keep family-specific
mechanics; this module owns the shared wrapper role map and crossing rules.

- [RS-DELEG-01] Caller-facing/manual/external Codex invocation uses
  `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`.
- [RS-DELEG-02] Do not call `codex exec` directly as a caller-facing path.
  Direct binary calls are not completion evidence and may bypass guardrails.
- [RS-DELEG-03] Do not override wrapper model or reasoning settings with
  ad hoc `-c model=...` or `-c model_reasoning_effort=...` flags.
- [RS-DELEG-04] The canonical caller-facing roles are:
  `standard` (`medium` + `cached`), `research` (`high` + `live`), `coder`
  (`medium` + `cached`), `high-coder` (`high` + `cached`), and `reviewer`
  (`xhigh` + `cached`).
- [RS-DELEG-05] Compatibility shims map only to canonical roles:
  `medium.sh -> standard`, `high.sh -> high-coder`, and
  `xhigh.sh -> reviewer`; shims are not role-escape hatches.
- [RS-DELEG-06] Reviewer execution is fixed to `--role reviewer`; do not route
  reviewer work through coder, standard, research, or high-coder roles.
- [RS-DELEG-07] Same-family native orchestration stays inside the current
  agent family and must not recursively invoke cross-family wrapper scripts.
- [RS-DELEG-08] Cross-family Claude/Codex coordination uses canonical wrapper
  entrypoints plus durable artifact packets, lease closeout, and evidence
  pointers; live chat is not completion evidence.
- [RS-DELEG-09] `codex resume`, `--continue-session`, `--fork-session`, and
  equivalent continuation flags are for manual/interactive recovery only and
  must not be used in automated orchestrator flows.
- [RS-DELEG-10] If the canonical wrapper is missing, role resolution fails, or
  a shim role escape is detected, fail closed instead of falling back to direct
  binary execution.
- [RS-DELEG-11] `--cd` and `--add-dir` are not caller-facing escape hatches;
  wrapper handling must preserve the fixed sandbox contract.
- [RS-DELEG-12] Orchestrator role selection is dual-native: top-level Claude
  sessions use Claude-native subagents, top-level Codex sessions use Codex
  native subagents, and cross-family work crosses through wrappers and
  artifacts.
- [RS-DELEG-13] Coder work may be performed by Claude or Codex; security-
  sensitive or complex implementation uses the high-coder lane when using
  caller-facing Codex.
- [RS-DELEG-14] Wrapper compliance is runtime evidence only; it does not
  replace acceptance evidence under the matrix.
- [RS-DELEG-15] Caller-facing Codex invocations must not override
  `.codex/config.toml`, wrapper-selected model, or wrapper-selected reasoning
  effort through direct binary calls, command-line flags, or config mutation.
- [RS-DELEG-16] Reviewer output format is owned by `docs/roles/reviewer.md`;
  abbreviated severity labels are valid only inside that template's Findings
  section.
- [RS-DELEG-17] Wrapper input guards fail closed on missing canonical wrapper,
  role-resolution failure, or shim role escape; `--cd` and `--add-dir` are not
  accepted as caller-facing escape hatches and direct Codex fallback is banned.
