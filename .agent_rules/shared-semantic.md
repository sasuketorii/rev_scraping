# Shared Semantic Rules

Charter: transitional semantic-coordination rules and addon extraction seed.
Current truth after P8 is config-level opt-in: core sessions do not auto-start
semantic MCP, and addon wiring is valid only when the absent-or-compliant check
passes.

- [RS-SEM-01] Semantic coordination uses a four-layer model: Layer 0 ground
  truth, Layer 1 pre-flight analysis, Layer 2 prompt capsule, and Layer 3
  execution feedback.
- [RS-SEM-02] `.agent/context/**` and JSONL exports are derived analysis,
  cache, or debug artifacts, not authoritative policy.
- [RS-SEM-03] Prompt capsules are capped at 220 tokens total: 200 token body
  plus 20 token metadata/JSON budget.
- [RS-SEM-04] A capsule over 220 tokens returns `BLOCK` fail-closed and must
  not be accepted for continued processing.
- [RS-SEM-05] `sem.capsule` must use the `context_token` issued by
  `sem.context.top_k`; caller-supplied `top_k_symbols` is rejected
  fail-closed.
- [RS-SEM-06] `context_token` has a 30-minute TTL. Expired tokens, cache
  misses, or file rollup drift require a fresh `sem.context.top_k` call.
- [RS-SEM-07] Capsule bodies include `INDEX_VERSION=<u64>` and
  `FILE_SHA_ROLLUP=<sha256>`; the file rollup participates in freshness
  binding while index version is informational for hash-slot handling.
- [RS-SEM-08] `CAPSULE_SHA256` references are preserved and external references
  follow the same fail-closed freshness policy.
- [RS-SEM-09] Shadow Verify order is Coder -> Shadow Verify -> Reviewer when
  that gate is enabled; do not proceed to Reviewer while Shadow Verify is
  failing or missing.
- [RS-SEM-10] QG-1: `quality_gate.status in {failed, skipped}` is a
  fail-closed Shadow Verify failure.
- [RS-SEM-11] QG-2: missing required language commands such as package-manager,
  Rust, or Python test commands are fail-closed Shadow Verify failures.
- [RS-SEM-12] Shadow Verify retries and extra checks are recorded against the
  same task lineage, evidence destination, and task-level budget. Do not create
  a separate retry ceiling outside the matrix budget semantics.
- [RS-SEM-13] If Shadow Verify progress, evidence, or budget recheck cannot be
  traced, route to `BLOCK` instead of leaving the slice ambiguously in
  `pending verification`.
- [RS-SEM-14] Semantic MCP wiring is an explicit addon opt-in. Core sessions
  must pass with no semantic MCP config, while enabled addon wiring must pass
  `scripts/ci/addon-absent-or-compliant-check.sh --semantic`.
- [RS-SEM-15] Semantic dependency verdict handling is an interface boundary;
  dependency policy logic and registry ownership remain in their dedicated
  plan/surface.
- [RS-SEM-16] When semantic MCP is enabled, its database placement uses the
  platform data directory under
  `Revharness/semantic-mcp/v1/{project_id}/semantic.db`; family-specific
  runtime config ownership stays in the relevant vendor-local configuration
  until addon demotion replaces that contract.
