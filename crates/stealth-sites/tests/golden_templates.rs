// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)
//
// Integration tests: every committed template under `templates/sites/` must
// deserialize cleanly into a `SiteRecipe`.

use std::path::PathBuf;

use stealth_sites::{Rendering, SiteRecipe};

fn templates_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("templates")
        .join("sites")
}

#[test]
fn test_load_example_com_template_via_filesystem() {
    let path = templates_dir().join("example.com.toml");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let r: SiteRecipe = toml::from_str(&text).expect("parse example.com template");
    assert_eq!(r.site.domain, "example.com");
    assert_eq!(r.site.rendering, Rendering::Spa);
    assert!(r.auth.is_some());
}

#[test]
fn test_load_example_site_template_has_3_endpoints() {
    let path = templates_dir().join("example.com.example.toml");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let r: SiteRecipe = toml::from_str(&text).expect("parse example template");
    assert_eq!(r.site.domain, "example.com");
    let api = r.api.expect("api section");
    assert_eq!(api.endpoints.len(), 3);
    let purposes: Vec<_> = api.endpoints.iter().map(|e| e.purpose.as_str()).collect();
    assert!(purposes.contains(&"user_profile"));
    assert!(purposes.contains(&"user_articles"));
    assert!(purposes.contains(&"article"));
}
