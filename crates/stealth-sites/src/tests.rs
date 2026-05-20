// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)

use std::collections::HashMap;

use pretty_assertions::assert_eq;
use tempfile::tempdir;

use crate::error::SitesError;
use crate::recipe::{
    AuthRecipe, RefusalAction, RefusalError, RefusalPolicy, Rendering, SiteMeta, SiteRecipe,
};
use crate::render::render_url;
use crate::store::SiteRecipeStore;

const MINIMAL_TOML: &str = r#"
schema_version = 1
[site]
domain = "minimal.test"
rendering = "spa"
"#;

const FULL_TEMPLATE_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../templates/sites/example.com.toml"
);

#[test]
fn test_recipe_minimum_required_fields_deserialize() {
    let r: SiteRecipe = toml::from_str(MINIMAL_TOML).expect("parse minimal");
    assert_eq!(r.site.domain, "minimal.test");
    assert_eq!(r.site.rendering, Rendering::Spa);
    assert!(r.api.is_none());
}

#[test]
fn test_recipe_full_template_deserialize() {
    let text =
        std::fs::read_to_string(FULL_TEMPLATE_PATH).expect("read templates/sites/example.com.toml");
    let r: SiteRecipe = toml::from_str(&text).expect("parse example.com template");
    assert_eq!(r.site.domain, "example.com");
    assert_eq!(r.site.rendering, Rendering::Spa);
    let api = r.api.expect("api section present");
    assert_eq!(api.endpoints.len(), 3);
    assert_eq!(api.endpoints[0].purpose, "article");
}

#[test]
fn auth_recipe_deserializes_from_toml() {
    let toml_text = r#"
required = true
login_url = "https://example.com/login"
completion_pattern = "^https://example\\.com/dashboard"
recommended_profile = "example-default"
refusal_policy = "warn-continue"
session_ttl_days = 14
note = "Magic link login."
"#;
    let auth: AuthRecipe = toml::from_str(toml_text).expect("parse auth recipe");
    assert!(auth.required);
    assert_eq!(auth.login_url, "https://example.com/login");
    assert_eq!(
        auth.completion_pattern.as_deref(),
        Some("^https://example\\.com/dashboard")
    );
    assert_eq!(auth.recommended_profile.as_deref(), Some("example-default"));
    assert_eq!(auth.refusal_policy, RefusalPolicy::WarnContinue);
    assert_eq!(auth.session_ttl_days, Some(14));
    assert_eq!(auth.note.as_deref(), Some("Magic link login."));
}

#[test]
fn auth_recipe_serializes_round_trip() {
    let auth = AuthRecipe {
        required: true,
        login_url: "https://example.com/login".to_string(),
        completion_pattern: Some("^https://example\\.com/home".to_string()),
        recommended_profile: Some("example-default".to_string()),
        refusal_policy: RefusalPolicy::Allow,
        session_ttl_days: Some(30),
        note: Some("Operator note.".to_string()),
    };
    let text = toml::to_string(&auth).expect("serialize auth recipe");
    let parsed: AuthRecipe = toml::from_str(&text).expect("parse serialized auth recipe");

    assert_eq!(parsed.required, auth.required);
    assert_eq!(parsed.login_url, auth.login_url);
    assert_eq!(parsed.completion_pattern, auth.completion_pattern);
    assert_eq!(parsed.recommended_profile, auth.recommended_profile);
    assert_eq!(parsed.refusal_policy, auth.refusal_policy);
    assert_eq!(parsed.session_ttl_days, auth.session_ttl_days);
    assert_eq!(parsed.note, auth.note);
}

#[test]
fn site_recipe_without_auth_section_loads_existing_templates() {
    let r: SiteRecipe = toml::from_str(MINIMAL_TOML).expect("parse minimal without auth");
    assert!(r.auth.is_none());
    assert!(!r.auth_required());
}

#[test]
fn enforce_auth_returns_refuse_when_required_and_missing() {
    let recipe = auth_recipe_with_policy(true, RefusalPolicy::Refuse);
    let err = recipe.enforce_auth_or_refusal(false).unwrap_err();
    assert!(matches!(err, RefusalError::AuthRequiredButMissing));
}

#[test]
fn enforce_auth_returns_warn_continue_when_policy_warn() {
    let recipe = auth_recipe_with_policy(true, RefusalPolicy::WarnContinue);
    let action = recipe.enforce_auth_or_refusal(false).unwrap();
    assert_eq!(
        action,
        RefusalAction::ContinueWithWarning(
            "recipe declares auth.required=true but --use-auth was not supplied; continuing per refusal_policy=warn-continue",
        )
    );
}

#[test]
fn enforce_auth_returns_continue_when_policy_allow() {
    let recipe = auth_recipe_with_policy(true, RefusalPolicy::Allow);
    assert_eq!(
        recipe.enforce_auth_or_refusal(false).unwrap(),
        RefusalAction::Continue
    );
}

#[test]
fn auth_required_returns_false_for_optional_recipes() {
    let recipe = auth_recipe_with_policy(false, RefusalPolicy::Refuse);
    assert!(!recipe.auth_required());
    assert_eq!(
        recipe.enforce_auth_or_refusal(false).unwrap(),
        RefusalAction::Continue
    );
}

#[test]
fn example_template_with_auth_section_parses() {
    let text =
        std::fs::read_to_string(FULL_TEMPLATE_PATH).expect("read templates/sites/example.com.toml");
    let r: SiteRecipe = toml::from_str(&text).expect("parse example.com template");
    let auth = r.auth.expect("auth section present");
    assert_eq!(auth.login_url, "https://example.com/login");
    assert_eq!(auth.refusal_policy, RefusalPolicy::Allow);
}

#[test]
fn test_endpoint_default_http_method_is_get() {
    let toml_text = r#"
schema_version = 1
[site]
domain = "x.test"
rendering = "ssr"

[api]
base_url = "https://api.x.test"

[[api.endpoints]]
purpose = "p"
path = "/v1/p"
"#;
    let r: SiteRecipe = toml::from_str(toml_text).expect("parse");
    assert_eq!(r.api.unwrap().endpoints[0].http_method, "GET");
}

#[test]
fn test_store_save_and_load_roundtrip() {
    let dir = tempdir().unwrap();
    let mut store = SiteRecipeStore::open(dir.path()).unwrap();
    let recipe = SiteRecipe {
        schema_version: 1,
        site: SiteMeta {
            domain: "roundtrip.test".into(),
            last_verified: None,
            rendering: Rendering::ApiOnly,
            framework: None,
            backend_hint: None,
            tags: vec![],
        },
        api: None,
        scraping_strategy: None,
        rate_limits: None,
        selectors: None,
        fingerprint: None,
        anti_bot: None,
        notes: None,
        auth: None,
    };
    store.save(&recipe).unwrap();
    let loaded = store.load("roundtrip.test").unwrap().expect("present");
    assert_eq!(loaded.site.domain, "roundtrip.test");
    assert_eq!(loaded.site.rendering, Rendering::ApiOnly);

    let domains = store.list_domains().unwrap();
    assert_eq!(domains, vec!["roundtrip.test".to_string()]);
}

#[test]
fn test_store_save_rejects_cookie_token() {
    let dir = tempdir().unwrap();
    let mut store = SiteRecipeStore::open(dir.path()).unwrap();
    let recipe = SiteRecipe {
        schema_version: 1,
        site: SiteMeta {
            domain: "leaky.test".into(),
            last_verified: None,
            rendering: Rendering::Spa,
            framework: None,
            backend_hint: None,
            tags: vec![],
        },
        api: None,
        scraping_strategy: None,
        rate_limits: None,
        selectors: None,
        fingerprint: None,
        anti_bot: None,
        notes: Some(crate::recipe::Notes {
            text: Some("found my-session-cookie=ABC during recon".into()),
        }),
        auth: None,
    };
    let err = store.save(&recipe).unwrap_err();
    match err {
        SitesError::SecretRejected(_) => {}
        other => panic!("expected SecretRejected, got {other:?}"),
    }
}

#[test]
fn test_store_atomic_write_no_partial_on_crash() {
    // Verify the save path produces a final file and no leftover .tmp on success.
    let dir = tempdir().unwrap();
    let mut store = SiteRecipeStore::open(dir.path()).unwrap();
    let recipe = SiteRecipe {
        schema_version: 1,
        site: SiteMeta {
            domain: "atomic.test".into(),
            last_verified: None,
            rendering: Rendering::Spa,
            framework: None,
            backend_hint: None,
            tags: vec![],
        },
        api: None,
        scraping_strategy: None,
        rate_limits: None,
        selectors: None,
        fingerprint: None,
        anti_bot: None,
        notes: None,
        auth: None,
    };
    store.save(&recipe).unwrap();

    let final_path = dir.path().join("atomic.test.toml");
    let tmp_path = dir.path().join("atomic.test.toml.tmp");
    assert!(final_path.exists(), "final file written");
    assert!(!tmp_path.exists(), "tmp file cleaned up by rename");

    // Simulate a stale .tmp from a crashed prior run; a new save should still succeed.
    std::fs::write(&tmp_path, "garbage").unwrap();
    store.save(&recipe).unwrap();
    assert!(final_path.exists());

    // Original (final) file must still be parseable, never partial.
    let text = std::fs::read_to_string(&final_path).unwrap();
    let _parsed: SiteRecipe = toml::from_str(&text).expect("final file is whole");
}

#[test]
fn test_render_url_substitutes_params() {
    let mut p = HashMap::new();
    p.insert("username".to_string(), "fujin_metaverse".to_string());
    let url = render_url("https://api.example.com/v2/users/{username}/articles", &p).unwrap();
    assert_eq!(
        url.as_str(),
        "https://api.example.com/v2/users/fujin_metaverse/articles"
    );
}

#[test]
fn test_render_url_url_encodes_value() {
    let mut p = HashMap::new();
    p.insert("q".to_string(), "hello world".to_string());
    let url = render_url("https://example.com/search/{q}", &p).unwrap();
    assert_eq!(url.as_str(), "https://example.com/search/hello%20world");
}

#[test]
fn test_render_url_missing_param_errors() {
    let p = HashMap::new();
    let err = render_url("https://example.com/{missing}", &p).unwrap_err();
    match err {
        SitesError::MissingParam(k) => assert_eq!(k, "missing"),
        other => panic!("expected MissingParam, got {other:?}"),
    }
}

#[test]
fn test_store_rejects_path_traversal_domain() {
    let dir = tempdir().unwrap();
    let store = SiteRecipeStore::open(dir.path()).unwrap();
    let err = store.load("../etc/passwd").unwrap_err();
    matches!(err, SitesError::InvalidDomain(_));
}

fn auth_recipe_with_policy(required: bool, refusal_policy: RefusalPolicy) -> SiteRecipe {
    SiteRecipe {
        schema_version: 1,
        site: SiteMeta {
            domain: "auth.test".into(),
            last_verified: None,
            rendering: Rendering::Spa,
            framework: None,
            backend_hint: None,
            tags: vec![],
        },
        api: None,
        scraping_strategy: None,
        rate_limits: None,
        selectors: None,
        fingerprint: None,
        anti_bot: None,
        notes: None,
        auth: Some(AuthRecipe {
            required,
            login_url: "https://auth.test/login".into(),
            completion_pattern: None,
            recommended_profile: None,
            refusal_policy,
            session_ttl_days: None,
            note: None,
        }),
    }
}
