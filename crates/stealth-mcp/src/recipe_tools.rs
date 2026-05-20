// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7d)
//
//! In-process MCP tool handlers for SiteRecipe CRUD. Unlike spider/relocate/...
//! which shell out to the `rev-stealth` CLI, recipe tools operate directly on
//! the on-disk store under `~/.rev_scraping/sites/` via `stealth_sites`.

use std::path::PathBuf;

use base64::Engine;
use serde_json::{json, Value};
use stealth_sites::{Endpoint, SiteRecipe, SiteRecipeStore, SitesError};

/// Set of in-process tool names. Used by the server dispatcher to branch
/// before the subprocess-style `build_cli_argv` path.
pub const RECIPE_TOOLS: &[&str] = &[
    "recipe_list",
    "recipe_show",
    "recipe_remove",
    "recipe_propose_endpoint",
    "recipe_export",
    "recipe_import",
];

pub fn is_recipe_tool(name: &str) -> bool {
    RECIPE_TOOLS.contains(&name)
}

/// Default store dir: `~/.rev_scraping/sites/`. Falls back to `./.rev_scraping/sites/`
/// if no home directory is resolvable.
pub fn default_store_dir() -> PathBuf {
    dirs::home_dir()
        .map(|h| h.join(".rev_scraping").join("sites"))
        .unwrap_or_else(|| PathBuf::from(".rev_scraping/sites"))
}

#[derive(Debug)]
pub enum RecipeError {
    MissingField(&'static str),
    Sites(SitesError),
    Json(String),
    Base64(String),
    NotFound(String),
}

impl std::fmt::Display for RecipeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecipeError::MissingField(k) => write!(f, "missing required argument: {k}"),
            RecipeError::Sites(e) => write!(f, "site store error: {e}"),
            RecipeError::Json(e) => write!(f, "json error: {e}"),
            RecipeError::Base64(e) => write!(f, "base64 error: {e}"),
            RecipeError::NotFound(d) => write!(f, "recipe not found: {d}"),
        }
    }
}

impl From<SitesError> for RecipeError {
    fn from(e: SitesError) -> Self {
        RecipeError::Sites(e)
    }
}

fn get_str<'a>(args: &'a Value, key: &'static str) -> Result<&'a str, RecipeError> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or(RecipeError::MissingField(key))
}

/// Dispatch any of the `recipe_*` tools against the given store dir.
pub fn handle_recipe_tool(
    name: &str,
    args: &Value,
    store_dir: &std::path::Path,
) -> Result<Value, RecipeError> {
    let mut store = SiteRecipeStore::open(store_dir)?;
    match name {
        "recipe_list" => handle_list(&store),
        "recipe_show" => handle_show(&store, get_str(args, "domain")?),
        "recipe_remove" => {
            let domain = get_str(args, "domain")?.to_string();
            let confirm = args
                .get("confirm")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            handle_remove(&mut store, &domain, confirm)
        }
        "recipe_propose_endpoint" => {
            let domain = get_str(args, "domain")?.to_string();
            let endpoint = args
                .get("endpoint")
                .cloned()
                .ok_or(RecipeError::MissingField("endpoint"))?;
            handle_propose_endpoint(&mut store, &domain, endpoint)
        }
        "recipe_export" => handle_export(&store),
        "recipe_import" => {
            let payload = get_str(args, "payload")?.to_string();
            handle_import(&mut store, &payload)
        }
        _ => Err(RecipeError::MissingField("unknown recipe tool")),
    }
}

fn handle_list(store: &SiteRecipeStore) -> Result<Value, RecipeError> {
    let domains = store.list_domains()?;
    let items: Vec<Value> = domains
        .iter()
        .map(|d| {
            let recipe = store.load(d).ok().flatten();
            json!({
                "domain": d,
                "rendering": recipe.as_ref().map(|r| format!("{:?}", r.site.rendering).to_lowercase()),
                "last_verified": recipe.as_ref().and_then(|r| r.site.last_verified.clone()),
                "endpoint_count": recipe
                    .as_ref()
                    .and_then(|r| r.api.as_ref())
                    .map(|a| a.endpoints.len())
                    .unwrap_or(0),
            })
        })
        .collect();
    let total = items.len();
    Ok(json!({ "recipes": items, "total": total }))
}

fn handle_show(store: &SiteRecipeStore, domain: &str) -> Result<Value, RecipeError> {
    let recipe = store
        .load(domain)?
        .ok_or_else(|| RecipeError::NotFound(domain.to_string()))?;
    serde_json::to_value(&recipe).map_err(|e| RecipeError::Json(e.to_string()))
}

fn handle_remove(
    store: &mut SiteRecipeStore,
    domain: &str,
    confirm: bool,
) -> Result<Value, RecipeError> {
    // Verify path is well-formed and recipe exists before deciding.
    let existed = store.load(domain)?.is_some();
    if !confirm {
        return Ok(json!({
            "removed": false,
            "domain": domain,
            "preview": true,
            "would_remove": existed,
        }));
    }
    store.remove(domain)?;
    Ok(json!({
        "removed": true,
        "domain": domain,
        "existed": existed,
    }))
}

fn handle_propose_endpoint(
    store: &mut SiteRecipeStore,
    domain: &str,
    endpoint_val: Value,
) -> Result<Value, RecipeError> {
    let mut recipe = store
        .load(domain)?
        .ok_or_else(|| RecipeError::NotFound(domain.to_string()))?;

    let endpoint: Endpoint = serde_json::from_value(endpoint_val)
        .map_err(|e| RecipeError::Json(format!("invalid endpoint: {e}")))?;

    if let Some(api) = recipe.api.as_mut() {
        api.endpoints.push(endpoint);
    } else {
        return Err(RecipeError::Json(
            "recipe has no [api] section; cannot append endpoint".into(),
        ));
    }

    // save() applies secret-leak rejection + atomic write.
    store.save(&recipe)?;
    let count = recipe.api.as_ref().map(|a| a.endpoints.len()).unwrap_or(0);
    Ok(json!({
        "added": true,
        "domain": domain,
        "endpoint_count_after": count,
    }))
}

fn handle_export(store: &SiteRecipeStore) -> Result<Value, RecipeError> {
    let domains = store.list_domains()?;
    let mut recipes: Vec<SiteRecipe> = Vec::with_capacity(domains.len());
    for d in &domains {
        if let Some(r) = store.load(d)? {
            recipes.push(r);
        }
    }
    let json_bytes = serde_json::to_vec(&recipes).map_err(|e| RecipeError::Json(e.to_string()))?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(&json_bytes);
    Ok(json!({
        "payload": encoded,
        "count": recipes.len(),
        "encoding": "base64-json",
    }))
}

fn handle_import(store: &mut SiteRecipeStore, payload: &str) -> Result<Value, RecipeError> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(payload)
        .map_err(|e| RecipeError::Base64(e.to_string()))?;
    let recipes: Vec<SiteRecipe> =
        serde_json::from_slice(&bytes).map_err(|e| RecipeError::Json(e.to_string()))?;

    let mut imported = 0usize;
    let mut rejected: Vec<Value> = Vec::new();
    for r in &recipes {
        match store.save(r) {
            Ok(()) => imported += 1,
            Err(e) => rejected.push(json!({
                "domain": r.site.domain,
                "error": e.to_string(),
            })),
        }
    }
    Ok(json!({
        "imported": imported,
        "rejected": rejected,
        "total": recipes.len(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn sample_recipe(domain: &str) -> SiteRecipe {
        let v = json!({
            "schema_version": 1,
            "site": { "domain": domain, "rendering": "spa" },
            "api": {
                "base_url": format!("https://api.{domain}"),
                "endpoints": [{
                    "purpose": "product_list",
                    "path": "/v1/products",
                    "http_method": "GET"
                }]
            }
        });
        serde_json::from_value(v).expect("sample parses")
    }

    fn seed(dir: &std::path::Path, domains: &[&str]) {
        let mut store = SiteRecipeStore::open(dir).unwrap();
        for d in domains {
            store.save(&sample_recipe(d)).unwrap();
        }
    }

    #[test]
    fn test_recipe_list_returns_all_domains_in_dir() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["a.example.com", "b.example.com"]);
        let v = handle_recipe_tool("recipe_list", &json!({}), tmp.path()).unwrap();
        assert_eq!(v["total"], 2);
        let recipes = v["recipes"].as_array().unwrap();
        let domains: Vec<&str> = recipes
            .iter()
            .map(|r| r["domain"].as_str().unwrap())
            .collect();
        assert!(domains.contains(&"a.example.com"));
        assert!(domains.contains(&"b.example.com"));
        assert_eq!(recipes[0]["endpoint_count"], 1);
    }

    #[test]
    fn test_recipe_show_returns_full_recipe() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["one.example.com"]);
        let v = handle_recipe_tool(
            "recipe_show",
            &json!({ "domain": "one.example.com" }),
            tmp.path(),
        )
        .unwrap();
        assert_eq!(v["site"]["domain"], "one.example.com");
        assert_eq!(v["api"]["endpoints"][0]["purpose"], "product_list");
    }

    #[test]
    fn test_recipe_show_missing_returns_not_found() {
        let tmp = TempDir::new().unwrap();
        let err = handle_recipe_tool("recipe_show", &json!({ "domain": "nope.com" }), tmp.path())
            .unwrap_err();
        assert!(matches!(err, RecipeError::NotFound(_)));
    }

    #[test]
    fn test_recipe_remove_with_confirm_false_does_nothing() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["keep.example.com"]);
        let v = handle_recipe_tool(
            "recipe_remove",
            &json!({ "domain": "keep.example.com", "confirm": false }),
            tmp.path(),
        )
        .unwrap();
        assert_eq!(v["removed"], false);
        assert_eq!(v["would_remove"], true);
        assert!(tmp.path().join("keep.example.com.toml").exists());
    }

    #[test]
    fn test_recipe_remove_with_confirm_true_deletes_file() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["bye.example.com"]);
        let v = handle_recipe_tool(
            "recipe_remove",
            &json!({ "domain": "bye.example.com", "confirm": true }),
            tmp.path(),
        )
        .unwrap();
        assert_eq!(v["removed"], true);
        assert!(!tmp.path().join("bye.example.com.toml").exists());
    }

    #[test]
    fn test_recipe_propose_endpoint_appends_to_existing() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["ep.example.com"]);
        let v = handle_recipe_tool(
            "recipe_propose_endpoint",
            &json!({
                "domain": "ep.example.com",
                "endpoint": {
                    "purpose": "search",
                    "path": "/v1/search",
                    "http_method": "GET",
                    "url_pattern": "/v1/search?q={q}"
                }
            }),
            tmp.path(),
        )
        .unwrap();
        assert_eq!(v["added"], true);
        assert_eq!(v["endpoint_count_after"], 2);

        // verify persisted
        let store = SiteRecipeStore::open(tmp.path()).unwrap();
        let r = store.load("ep.example.com").unwrap().unwrap();
        assert_eq!(r.api.as_ref().unwrap().endpoints.len(), 2);
    }

    #[test]
    fn test_recipe_propose_endpoint_rejects_secret_leak() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["sec.example.com"]);
        // url_pattern containing "cookie" triggers secret rejection in save()
        let err = handle_recipe_tool(
            "recipe_propose_endpoint",
            &json!({
                "domain": "sec.example.com",
                "endpoint": {
                    "purpose": "auth cookie endpoint",
                    "path": "/v1/auth",
                    "http_method": "POST"
                }
            }),
            tmp.path(),
        )
        .unwrap_err();
        match err {
            RecipeError::Sites(SitesError::SecretRejected(_)) => {}
            other => panic!("expected SecretRejected, got {other:?}"),
        }
    }

    #[test]
    fn test_recipe_export_returns_base64_json_array() {
        let tmp = TempDir::new().unwrap();
        seed(tmp.path(), &["x.example.com", "y.example.com"]);
        let v = handle_recipe_tool("recipe_export", &json!({}), tmp.path()).unwrap();
        assert_eq!(v["count"], 2);
        let payload = v["payload"].as_str().unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(payload)
            .unwrap();
        let arr: Vec<SiteRecipe> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(arr.len(), 2);
    }

    #[test]
    fn test_recipe_import_writes_each_recipe() {
        let src = TempDir::new().unwrap();
        seed(src.path(), &["i1.example.com", "i2.example.com"]);
        let exported = handle_recipe_tool("recipe_export", &json!({}), src.path()).unwrap();
        let payload = exported["payload"].as_str().unwrap().to_string();

        let dst = TempDir::new().unwrap();
        let v = handle_recipe_tool("recipe_import", &json!({ "payload": payload }), dst.path())
            .unwrap();
        assert_eq!(v["imported"], 2);
        assert_eq!(v["total"], 2);
        assert!(dst.path().join("i1.example.com.toml").exists());
        assert!(dst.path().join("i2.example.com.toml").exists());
    }

    #[test]
    fn test_recipe_import_rejects_path_traversal_in_domain() {
        // Craft a recipe with a malicious domain and import it.
        let malicious = json!([{
            "schema_version": 1,
            "site": { "domain": "../escape", "rendering": "spa" },
        }]);
        let bytes = serde_json::to_vec(&malicious).unwrap();
        let payload = base64::engine::general_purpose::STANDARD.encode(&bytes);

        let dst = TempDir::new().unwrap();
        let v = handle_recipe_tool("recipe_import", &json!({ "payload": payload }), dst.path())
            .unwrap();
        // All entries should land in `rejected`, none imported.
        assert_eq!(v["imported"], 0);
        assert_eq!(v["rejected"].as_array().unwrap().len(), 1);
        // and crucially no file outside dir exists
        assert!(!dst.path().parent().unwrap().join("escape.toml").exists());
    }

    #[test]
    fn test_handle_show_missing_domain_field() {
        let tmp = TempDir::new().unwrap();
        let err = handle_recipe_tool("recipe_show", &json!({}), tmp.path()).unwrap_err();
        assert!(matches!(err, RecipeError::MissingField("domain")));
    }

    #[test]
    fn test_is_recipe_tool() {
        assert!(is_recipe_tool("recipe_list"));
        assert!(is_recipe_tool("recipe_import"));
        assert!(!is_recipe_tool("spider"));
    }
}
