# Skill Integration

This document is the stable index for Revharness skill packages. It does not
mirror skill internals. Operational checklists, risk matrices, source
registries, prompts, and scripts stay inside each skill package so agents load
them only when the skill is relevant.

## Installed Skill Packages

Source package root:

- `${REV_DEVSKILLS_ROOT:-../rev_devskills}`

Install targets:

- `.claude/skills/*`
- `${CODEX_HOME:-$HOME/.codex}/skills/*`

Installed packages:

| Package | Skill name | Use |
|---|---|---|
| `client-distribution-readiness` | `client-distribution-readiness` | Client handoff / clean distribution readiness audit for stale archive refs, local paths, semantic DB regeneration, skill sync, and doctor assumptions |
| `cloudflare-deploy-guard` | `cloudflare-deploy-guard` | Cloudflare deploy / settings / billing / security GO/NO-GO gate |
| `codex-app-server-guard` | `codex-app-server-guard` | Codex app-server transport / auth / approval / sandbox / tool-side-effect GO/NO-GO gate |
| `go-skills-knowledge-pack` | `go-skills-architecture` | REV-C Go architecture, review, implementation, and dependency governance |
| `naming-normalization-guard` | `naming-normalization-guard` | Skill / knowledge pack addition, import, rename, and stale-path hygiene |
| `payload-cms-deploy-guard` | `payload-cms-deploy-guard` | Payload CMS production deploy / schema / access / uploads / jobs / migration GO/NO-GO gate |
| `rust-skills-knowledge-pack` | `rust-skills-architecture` | REV-C Rust architecture, implementation, benchmarking, and dependency governance |
| `self-growth-proposal-triage` | `self-growth-proposal-triage` | HermesAgent-inspired self-growth, proposal triage, skill promotion, and cleanup evolution without autonomous mutation |
| `shadcn` | `shadcn` | Lightweight bootstrap for the official shadcn skill, shadcn CLI, shadcn MCP, registries, presets, and `components.json` |
| `supabase-deploy-guard` | `supabase-deploy-guard` | Supabase deploy / migration / Auth / Storage / Realtime / MCP/API GO/NO-GO gate |
| `typescript-skills-knowledge-pack` | `typescript-skills-architecture` | REV-C TypeScript / Node / frontend / edge / agent architecture and governance |
| `revc-shadcn-frontend-workflow` | `revc-shadcn-frontend-workflow` | REV-C shadcn-first frontend workflow, official shadcn skill/CLI/MCP usage, and React/Next security freshness checks |

## Authority Boundary

- `SKILL.md`: trigger metadata, mandatory workflow, output contract, and core rules.
- `references/`: skill-local supporting details. Load only when the triggered
  task needs that reference.
- `scripts/`: deterministic scans, estimators, probes, and local checks.
- `prompts/`: reusable worker or reviewer prompts.
- `README.md`: package-local usage notes. Do not treat it as a repo-wide stable
  operating rule unless this document or another manual explicitly promotes it.
- `provenance.json`: required for new or imported workflow skills after the
  routing-matrix policy. Records source, allowed tools, network policy, MCP
  exposure, and mutation policy.
- `docs/`: stable navigation, routing policy, and update protocol only.

## No Mirror Rule

Do not copy skill-local checklists, risk matrices, source manifests, prompts,
scripts, master packs, or audit reports into `docs/` as standalone content.

If a skill-local artifact is useful, link to it by path instead of duplicating
it. The skill package remains the authority for its bundled materials.

## Freshness Rule

Treat bundled references and source registries as snapshots. For
provider-specific deployment, billing, security, version, or usage-limit
decisions, re-check current official docs, MCP output, dashboards, package
registries, or local CLI output before returning `DEPLOY: GO`, `LGTM`, or
`pending acceptance`.

Official docs and current runtime facts outrank stale bundled references.

## Routing Summary

- Pre-deploy provider changes trigger the matching deploy guard.
- Codex app-server product exposure or proxying triggers `codex-app-server-guard`.
- Go architecture, dependency, performance, or release work triggers
  `go-skills-architecture`.
- Rust architecture, hot-path, dependency, benchmark, or release work triggers
  `rust-skills-architecture`.
- TypeScript, Node, frontend, edge, AI-agent, and package governance work
  triggers `typescript-skills-architecture`.
- REV-C frontend UI/UX work that uses shadcn/ui, React, or Next.js triggers
  `revc-shadcn-frontend-workflow`. This is the default REV-C shadcn workflow;
  it requires current official shadcn, Next.js, and React security/update docs
  before production-impacting UI work. `rev-ui-prebuild-mockup` is not loaded
  unless the user explicitly asks for pre-build mockup artifacts.
- Direct shadcn component, registry, preset, MCP, or `components.json` work may
  also trigger the lightweight `shadcn` bootstrap skill. REV-C production UI
  work still routes through `revc-shadcn-frontend-workflow`.
- Skill package addition, import, rename, or reorganization triggers
  `naming-normalization-guard`.
- Self-growth, skill promotion, proposal triage, and HermesAgent-inspired
  workflow evolution trigger `self-growth-proposal-triage`.
- Deploy guards are release gates, not general implementation guides. Use them
  together with the relevant official platform skill when available.

The orchestrator routing table lives in:

- `.claude/skills/auto-orchestrator/SKILL.md`

The machine-checkable task-class to skill routing matrix lives in:

- `.agent/registry/skill_routing_matrix.json`
- `docs/manual/skill-routing-matrix.md`

## Update Protocol

1. Update the package in `${REV_DEVSKILLS_ROOT:-../rev_devskills}`.
2. Validate each changed package with `quick_validate.py`.
3. Sync the whole skill directory to `.claude/skills/<package>` and
   `${CODEX_HOME:-$HOME/.codex}/skills/<package>`.
   For shadcn projects, the target product repo should also install or refresh
   the official shadcn skill with `pnpm dlx skills add shadcn/ui` when that
   repo uses agent-managed shadcn UI work.
4. For new or imported skills, add provenance and validate routing with
   `bash scripts/rev-harness-skill-routing-check.sh --json`.
5. Do not hand-edit installed mirrored copies except for emergency repair.
   Follow up by applying the same repair to `${REV_DEVSKILLS_ROOT:-../rev_devskills}`
   and re-syncing.
6. Keep `docs/` as an index and policy layer. Do not turn it into a second
   source of truth for skill internals.
7. Skill sharing/projection helpers may remain Python when they are
   low-frequency file projection or validation tasks. Rust-first still applies
   to runtime/control-plane hot paths where performance, safety, and process
   supervision matter.
8. Validate shared Claude/Codex skill parity with:

   ```bash
   bash scripts/rev-harness-skill-projection.sh --check --json
   ```

   The manifest at `.agent/registry/skill_projection_manifest.json` contains
   `shared_skill_sync` entries for shared `.claude/skills/*` packages and their
   installed `${CODEX_HOME:-$HOME/.codex}/skills/*` projections. Local
   `provenance.json` metadata is excluded from byte-for-byte payload comparison.

## Frontier-push 後の API 表面 (2026-05 以降)

semantic-mcp tool surface に以下が追加されています。正典は skill `revharness-semantic-mcp-usage`:

- `sem.context.top_k`: server-side Top-K + context_token 発行 (TTL 30 min)
- `sem.capsule`: 必須 `{project_id, task_id, phase, context_token}`、`top_k_symbols` 送信禁止、`INDEX_VERSION` / `FILE_SHA_ROLLUP` 行追加
- `sem.search`: 既定 `kind="fts5"` (BM25 + 48h recency)、prefix wildcard なし、`legacy-like` は opt-in
- `sem.admin.gc`: orphan DB cleanup (`dry_run=true && force=false` default、実削除は `--dry-run=false --force` 両方明示)
- placement v2: `<XDG/Library/LOCALAPPDATA>/Revharness/semantic-mcp/v1/{project_id}/semantic.db`
- test isolation: `REVHARNESS_TEST_HARNESS=1` + `SEMANTIC_MCP_HOME=...`
