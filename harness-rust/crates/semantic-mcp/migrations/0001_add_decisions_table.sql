-- HSDI Phase F (Alternative C) — additive decisions table
-- Tier 2 (decision rationale) markdown-frontmatter medium の永続化 layer
-- Wave 21 では reader 実装なし (Wave 22 へ deferral, Codex 戦略諮問より)

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
