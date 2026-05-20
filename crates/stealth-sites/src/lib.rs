// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)
//
// Site Recipe L2 cache — per-domain TOML store remembering how to scrape a
// site once it has been figured out (API endpoints, rendering, anti-bot
// posture). See `.agent/active/sites_recipe_design.md` (Phase 7 design) and
// the companion templates in `templates/sites/`.

#![forbid(unsafe_code)]

pub mod discovery;
pub mod error;
pub mod recipe;
pub mod render;
pub mod store;

pub use error::{Result, SitesError};
pub use recipe::{
    AntiBotConfig, ApiConfig, AuthMethod, AuthRecipe, Endpoint, FingerprintHint, RateLimits,
    RefusalAction, RefusalError, RefusalPolicy, Rendering, ScrapingMethod, ScrapingStrategy,
    Selectors, SiteMeta, SiteRecipe,
};
pub use render::render_url;
pub use store::SiteRecipeStore;

#[cfg(test)]
mod tests;
