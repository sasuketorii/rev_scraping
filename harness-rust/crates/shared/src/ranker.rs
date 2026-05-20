//! Shared ranking primitives for semantic search and top-k context selection.

pub struct RankingWeights {
    pub impact_depth_weight: f64,
    pub fan_in_weight: f64,
    pub recency_weight: f64,
    pub bm25_weight: f64,
}

impl RankingWeights {
    /// Top-K (`sem.context.top_k`) default: no BM25 signal.
    pub const TOP_K: Self = Self {
        impact_depth_weight: 0.5,
        fan_in_weight: 0.3,
        recency_weight: 0.2,
        bm25_weight: 0.0,
    };

    /// Search (`sem.search`) default: BM25-centered ranking.
    pub const SEARCH: Self = Self {
        impact_depth_weight: 0.0,
        fan_in_weight: 0.0,
        recency_weight: 0.3,
        bm25_weight: 0.7,
    };
}

/// Score with a 48-hour half-life.
pub fn recency_score(updated_at_unix_ms: u64, now_unix_ms: u64) -> f64 {
    let age_hours = (now_unix_ms.saturating_sub(updated_at_unix_ms) as f64) / 3_600_000.0;
    0.5_f64.powf(age_hours / 48.0)
}

pub fn compute_rank_score(
    impact_depth: u32,
    fan_in: u32,
    recency: f64,
    bm25_normalized: f64,
    w: &RankingWeights,
) -> f64 {
    let impact_depth_norm = 1.0 / (1.0 + impact_depth as f64);
    let fan_in_norm = (fan_in as f64).ln_1p() / 10.0_f64.ln_1p();
    impact_depth_norm * w.impact_depth_weight
        + fan_in_norm * w.fan_in_weight
        + recency * w.recency_weight
        + bm25_normalized * w.bm25_weight
}
