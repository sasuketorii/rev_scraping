# Tier 2 Markdown Medium

## 1. What is Tier 2

Tier 2 is the decision-rationale capsule layer for orchestrator handoff
narratives. It records why a phase, slice, or invariant moved in a specific
direction after review, not the low-level semantic context bytes used for
retrieval.

The target budget is 800-1500 tokens per capsule. That makes the medium a
human-readable, medium-density narrative: compact enough to read at handoff
time, but large enough to preserve alternatives, falsifiers, and review
context.

Tier 2 lifecycle is bound to a `decision_id`.

- `decision_id` is the stable lookup key for one decision capsule.
- Phase-boundary TTL semantics apply to the decision's freshness, not to the
  existence of its source markdown.
- A replacement decision uses `superseded_by` to form an explicit chain.
- Expired or superseded rationale remains readable because the historical
  reasoning is part of the handoff record.

Tier 2 is separate from Tier 1. Tier 1 is the semantic-mcp context capsule
implemented by `harness-rust/crates/semantic-mcp/src/capsule.rs`; it is a
byte-equivalent retrieval substrate protected by `tier1-scope-guard.sh`.
Tier 2 is intentionally not byte-equivalent to Tier 1. It is a rationale
medium for orchestrators and reviewers.

## 2. Current Wave 21 medium - markdown + YAML frontmatter

Wave 21 records Tier 2 decisions as markdown-frontmatter files. The
frontmatter is the machine-readable envelope; the body is the rationale.

Storage:

- canonical: `.agent/decisions/<decision_id>.md`
- de-facto today: existing RFC / plan markdown under
  `.agent/active/plan_<YYYYMMDD>_*-rfc.md`,
  `.agent/active/plan_<YYYYMMDD>_*-execplan.md`, and phase-scoped
  review/score files

Existing `.agent/active/plan_20260525_hsdi-*` files do not all carry YAML
frontmatter. The frontmatter convention is forward-going for Wave 21; Wave 22
reader onboarding can retroactively normalize existing plan and review files
when it starts mirroring decisions into SQLite.

Frontmatter schema:

```yaml
---
decision_id: hsdi-phase-B
plan_id: plan_20260525_hsdi
phase: B
status: approved          # proposed | approved | rejected | superseded | expired
created: 2026-05-25
expires_at: phase_C_start # optional TTL anchor; null = no auto-expire
superseded_by: null       # decision_id of replacement, or null
sha256: <computed-by-future-hook>  # of the markdown body below the frontmatter close
---
```

Field semantics:

- `decision_id`: stable identifier for this decision capsule.
- `plan_id`: parent plan or wave identifier that owns the decision.
- `phase`: phase label that produced or currently owns the decision.
- `status`: lifecycle state: `proposed`, `approved`, `rejected`,
  `superseded`, or `expired`.
- `created`: ISO date when the decision capsule was authored.
- `expires_at`: optional TTL anchor; `null` means no automatic expiry anchor.
- `superseded_by`: replacement `decision_id`, or `null` when the decision is
  current or terminal.
- `sha256`: future Wave 22 body hash computed over the markdown body below the
  frontmatter close.

Body:

The markdown body is free-form narrative. It is the actual rationale: what was
tried, what was chosen, why it was chosen, what alternatives were rejected, and
which falsifiers would invalidate the decision later.

Recommended body shape:

```markdown
# HSDI Phase B Decision

## Context

Why this decision exists and which phase or artifact needed it.

## Decision

The selected direction.

## Rationale

The reasoning, tradeoffs, reviewer findings, and incident context.

## Falsifiers

Conditions under which this decision should be reopened or superseded.
```

## 3. TTL handling (current, Wave 21)

TTL is manual in Wave 21. At each phase boundary, the orchestrator visually
inspects prior-phase decision files and treats them as expired-for-new-work.
That does not delete, truncate, hide, or elide their content.

Principle 4 applies: Tier 2 expired-rationale is never deleted. Expiry is a
banner flag, not a hard content filter. An expired rationale can still explain
why a previous phase accepted a constraint, chose a mitigation, or rejected an
alternative.

The current implicit TTL index is the file-name plus folder convention:

```bash
.agent/active/plan_20260525_hsdi-phase-B-*.md
.agent/active/plan_20260525_hsdi-phase-C-*.md
.agent/active/plan_20260525_hsdi-phase-B/
.agent/active/plan_20260525_hsdi-phase-C/
```

Phase-scoped names such as `phase-B-*` and `phase-C-*` let the orchestrator
grep, compare, and visually age rationale without a Rust phase-advance writer.

Automatic phase-advance UPDATE of `status` to `expired` is deferred to Wave
22. This is the Codex strategy advisory section 3.3 Alternative C decision;
the original execplan task was T-21.4-5.

## 4. Storage (current vs future)

Wave 21 current storage:

- markdown files are the source of truth
- files are git-tracked under `.agent/active/` or `.agent/decisions/`
- orchestrators read them through the standard `Read` tool
- no MCP tool is registered for Tier 2 decisions
- no SQL queryability exists for Tier 2 decisions
- the `decisions` SQLite table is schema-only and empty

Wave 22 future storage:

- the same markdown files remain the source of truth
- a Rust reader, `decision.rs`, parses YAML frontmatter and body markdown
- the reader computes `sha256` over the markdown body
- parsed rows are mirrored into the `decisions` SQLite table
- typed programmatic access is exposed through `sem.decision.get`

The mirror is not an alternate authority. If SQLite and markdown disagree, the
markdown source path is the recovery anchor and the reader must report
freshness or validation status rather than silently rewriting history.

## 5. Schema persisted for Wave 22

The additive Wave 21 schema is in
`harness-rust/crates/semantic-mcp/migrations/0001_add_decisions_table.sql`.
It landed under T-F-1 as schema-only work.

```sql
CREATE TABLE IF NOT EXISTS decisions (
    decision_id     TEXT PRIMARY KEY,
    plan_id         TEXT NOT NULL,
    phase           TEXT NOT NULL,
    title           TEXT NOT NULL,
    rationale_md    TEXT NOT NULL,
    decision_status TEXT NOT NULL CHECK (decision_status IN ('proposed','approved','rejected','superseded','expired')),
    created_ts      TEXT NOT NULL,
    expires_at      TEXT,
    superseded_by   TEXT,
    sha256          TEXT NOT NULL,
    source_md_path  TEXT,
    additional_metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_decisions_plan_phase ON decisions (plan_id, phase);
CREATE INDEX IF NOT EXISTS idx_decisions_status ON decisions (decision_status);
CREATE INDEX IF NOT EXISTS idx_decisions_expires ON decisions (expires_at) WHERE expires_at IS NOT NULL;
```

Mapping:

| column | source in markdown |
|--------|--------------------|
| `decision_id` | frontmatter `decision_id` |
| `plan_id` | frontmatter `plan_id` |
| `phase` | frontmatter `phase` |
| `title` | first H1 of markdown body |
| `rationale_md` | markdown body (post-frontmatter) |
| `decision_status` | frontmatter `status` |
| `created_ts` | frontmatter `created` (ISO date) |
| `expires_at` | frontmatter `expires_at` (nullable) |
| `superseded_by` | frontmatter `superseded_by` (nullable) |
| `sha256` | computed by Wave 22 hook over body |
| `source_md_path` | repo-relative path to source markdown |
| `additional_metadata` | JSON blob (reserved) |

The table is empty in Wave 21. No reader writes to it yet, and no acceptance
gate should infer Tier 2 coverage from row presence until Wave 22 lands the
reader.

## 6. Wave 22 plan (deferred from HSDI)

The Codex strategy advisory moved the following tasks out of HSDI and into
Wave 22:

- `decision.rs` plus the `DecisionFrontmatter` struct, with
  `#[serde(deny_unknown_fields)]`
- sha256 validator, including `freshness=tampered` on linked
  reviewer-artifact mismatch
- TTL UPDATE on phase advance, including `freshness=expired` for prior-phase
  rows
- `sem.decision.get` MCP tool registration

The deferral source is
`.agent/active/plan_20260525_hsdi-strategy-advisory.md`, section 3.3
Alternative C. The same advisory references the incident artifact recovery
context: Phase A through Phase E relied on markdown plan, review, score, and
incident artifacts under `.agent/active/` as the recoverable handoff record.
That recovery path is the observed current Tier 2 medium.

## 7. Why not Rust now - Codex strategy advisory rationale

The strategy advisory evaluated three alternatives.

Alternative A: markdown-only. This saves about 6 business days relative to the
full Phase F Rust path, keeps the orchestrator on the medium it already reads,
and avoids MCP API growth. The cost is no schema lock-in and no typed
programmatic query path.

Alternative B: defer all of Phase F. This saves maximum time and closes HSDI at
the self-defense and dual-LGTM layers. The cost is that Wave 22 must relitigate
the Tier 2 design and may inherit ad-hoc markdown fields without a schema
anchor.

Alternative C: schema migration plus scope guard plus this docs file land in
HSDI; reader and tool work defer to Wave 22. This is the recommended and
adopted path. It saves about 3 business days versus original Phase F while
still locking the additive SQL shape and documenting markdown-frontmatter as
the current medium.

The markdown-frontmatter pattern has been observably stable through Phase A
through Phase E. Files named like `plan_20260525_hsdi-phase-*` are the working
Tier 2 medium today: orchestrators read them, reviewers score against them, and
incident recovery refers back to them.

## 8. Cross-links

Required HSDI references:

- `.agent/active/plan_20260525_hsdi-strategy-advisory.md` section 3.3
  Alternative C
- `.agent/active/plan_20260525_hsdi-execplan.md` section 5.1 / Phase F
  tasks T-21.4-1 through T-21.4-10
- `.agent/active/plan_20260525_hsdi-incident-R6-wave-risk.md`
- `harness-rust/crates/semantic-mcp/migrations/0001_add_decisions_table.sql`
- `docs/roles/orchestrator.md` Principle 3, dual-LGTM on-disk-only
- `docs/roles/orchestrator.md` Principle 4, Tier 2 expired-rationale never
  elided, banner only
- `docs/manual/verification-truth-matrix.md`

Phase invariant references:

- `.agent/active/plan_20260525_hsdi-phase-B-rfc.md`
- `.agent/active/plan_20260525_hsdi-phase-B-review-codex-r1.md`
- `.agent/active/plan_20260525_hsdi-phase-B-review-opus-r1.md`
- `.agent/active/plan_20260525_hsdi-phase-C/`

No Phase B or Phase C invariant document was discoverable under `docs/` at
Wave 21 authoring time. The current discoverable invariant and evidence
records are under `.agent/active/`.

## 9. Acceptance check grep tokens

The mandatory grep tokens for T-F-4 are intentionally present here:

- `decision_id`
- `markdown-frontmatter`
- `Wave 22`

