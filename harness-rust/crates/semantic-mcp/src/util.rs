//! Shared utility functions used across tool handlers.

use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};

/// Compute the SHA-256 hex digest of the input string.
pub fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// Truncate a string to `max_len` characters, appending "..." if truncated.
pub fn truncate(input: &str, max_len: usize) -> String {
    if input.len() <= max_len {
        return input.to_string();
    }
    if max_len <= 3 {
        return input[..max_len].to_string();
    }
    format!("{}...", &input[..max_len - 3])
}

/// Clamp an integer to the range `[min, max]`.
pub fn clamp_i64(value: i64, min: i64, max: i64) -> i64 {
    value.max(min).min(max)
}

/// Sanitize a value for capsule key=value format.
///
/// Replaces whitespace with `_` and strips `\r`, `\n`, `=`.
pub fn sanitize_value(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_whitespace() || ch == '=' {
            result.push('_');
        } else {
            result.push(ch);
        }
    }
    result
}

/// Estimate the number of tokens from a character count.
///
/// Uses a conservative ratio of 3 chars per token.
pub fn estimate_tokens(input: &str) -> i64 {
    ((input.len() as f64) / 3.0).ceil() as i64
}

/// Produce a stable JSON string with sorted keys.
pub fn stable_stringify(value: &serde_json::Value) -> String {
    serde_json::to_string(&normalize_json_value(value)).unwrap_or_else(|_| "null".to_string())
}

/// Recursively normalize a JSON value by sorting object keys.
fn normalize_json_value(value: &serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => {
            let mut sorted: Vec<(&String, &serde_json::Value)> = map.iter().collect();
            sorted.sort_by_key(|(k, _)| *k);
            let mut new_map = serde_json::Map::new();
            for (k, v) in sorted {
                new_map.insert(k.clone(), normalize_json_value(v));
            }
            serde_json::Value::Object(new_map)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(normalize_json_value).collect())
        }
        other => other.clone(),
    }
}

fn normalize_path_like_inner(input: &str, lowercase: bool) -> String {
    let trimmed = input.trim();
    let replaced = trimmed.replace('\\', "/");
    let mut collapsed = String::with_capacity(replaced.len());
    let mut prev_slash = false;
    for ch in replaced.chars() {
        if ch == '/' {
            if !prev_slash {
                collapsed.push(ch);
            }
            prev_slash = true;
        } else {
            collapsed.push(ch);
            prev_slash = false;
        }
    }

    let mut result = collapsed.as_str();
    while result.starts_with("./") {
        result = &result[2..];
    }
    let result = result.trim_end_matches('/');

    if lowercase {
        result.to_lowercase()
    } else {
        result.to_string()
    }
}

/// Canonicalize a file path for storage/dedupe while preserving case.
pub fn canonicalize_path_like(input: &str) -> String {
    normalize_path_like_inner(input, false)
}

/// Normalize a file path for comparison: trim, replace backslashes,
/// collapse slashes, remove leading `./`, remove trailing `/`, lowercase.
pub fn normalize_path_like(input: &str) -> String {
    normalize_path_like_inner(input, true)
}

/// Check whether `path` is exactly within `scope` or nested under it.
pub fn path_matches_scope(path: &str, scope: &str) -> bool {
    let path = normalize_path_like(path);
    let scope = normalize_path_like(scope);

    path == scope
        || path
            .strip_prefix(&scope)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// Check whether two scopes overlap by equality or directory containment.
pub fn paths_overlap(lhs: &str, rhs: &str) -> bool {
    path_matches_scope(lhs, rhs) || path_matches_scope(rhs, lhs)
}

/// Check if a value looks like a file path target (contains `/` or starts with `../`).
pub fn looks_like_path_target(input: &str) -> bool {
    let normalized = canonicalize_path_like(input);
    normalized.contains('/') || normalized.starts_with("../")
}

/// Normalize a caller-provided path and prove it remains inside `repo_root`.
pub fn normalize_repo_relative_path(
    repo_root: &Path,
    value: &str,
    field: &str,
) -> Result<String, String> {
    let raw = value.trim().replace('\\', "/");
    if raw.is_empty() {
        return Err(format!("{field} must not be blank"));
    }
    if raw.starts_with('/') || raw.starts_with("//") || has_windows_drive_prefix(&raw) {
        return Err(format!("{field} must be repo-relative"));
    }

    let relative = normalize_relative_path(&raw, field)?;
    let joined = repo_root.join(&relative);
    if !is_path_inside(repo_root, &joined) {
        return Err(format!("{field} must stay inside repo root"));
    }

    assert_no_symlink_component(repo_root, &relative, field)?;
    Ok(path_to_forward_slashes(&relative))
}

/// Return the exclusive upper bound for a prefix range scan.
pub fn build_prefix_upper_bound(prefix: &str) -> Option<String> {
    if prefix.is_empty() {
        return None;
    }
    let mut chars: Vec<char> = prefix.chars().collect();
    let last = chars.pop()?;
    let next = char::from_u32(last as u32 + 1)?;
    chars.push(next);
    Some(chars.into_iter().collect())
}

fn has_windows_drive_prefix(value: &str) -> bool {
    value.len() >= 3
        && value.as_bytes()[0].is_ascii_alphabetic()
        && value.as_bytes()[1] == b':'
        && value.as_bytes()[2] == b'/'
}

fn normalize_relative_path(raw: &str, field: &str) -> Result<PathBuf, String> {
    let collapsed = canonicalize_path_like(raw);
    if collapsed.is_empty() || collapsed == "." {
        return Err(format!("{field} must not be blank"));
    }

    let mut result = PathBuf::new();
    for component in Path::new(&collapsed).components() {
        match component {
            Component::Normal(part) => result.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(format!("{field} must not traverse outside repo root"));
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(format!("{field} must be repo-relative"));
            }
        }
    }

    if result.as_os_str().is_empty() {
        return Err(format!("{field} must not be blank"));
    }
    Ok(result)
}

fn assert_no_symlink_component(
    repo_root: &Path,
    relative_path: &Path,
    field: &str,
) -> Result<(), String> {
    let mut current = repo_root.to_path_buf();
    for component in relative_path.components() {
        let Component::Normal(part) = component else {
            continue;
        };
        current.push(part);
        let metadata = match std::fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("{field} symlink check failed: {error}")),
        };
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "{field} must not escape repo root through symlinks"
            ));
        }
        let canonical = current
            .canonicalize()
            .map_err(|e| format!("{field} canonicalization failed: {e}"))?;
        if !is_path_inside(repo_root, &canonical) {
            return Err(format!("{field} must stay inside repo root"));
        }
    }
    Ok(())
}

fn is_path_inside(root: &Path, candidate: &Path) -> bool {
    candidate == root || candidate.starts_with(root)
}

fn path_to_forward_slashes(path: &Path) -> String {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().to_string()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_hex_basic() {
        let hash = sha256_hex("hello");
        assert_eq!(hash.len(), 64);
    }

    #[test]
    fn truncate_short() {
        assert_eq!(truncate("abc", 5), "abc");
    }

    #[test]
    fn truncate_exact() {
        assert_eq!(truncate("abcde", 5), "abcde");
    }

    #[test]
    fn truncate_long() {
        assert_eq!(truncate("abcdefgh", 5), "ab...");
    }

    #[test]
    fn normalize_path() {
        assert_eq!(normalize_path_like("./src/foo.rs"), "src/foo.rs");
        assert_eq!(normalize_path_like("src//foo.rs"), "src/foo.rs");
        assert_eq!(normalize_path_like("SRC\\Foo.RS"), "src/foo.rs");
    }

    #[test]
    fn canonicalize_path_preserves_case() {
        assert_eq!(
            canonicalize_path_like("./Apps\\Web//Page.tsx"),
            "Apps/Web/Page.tsx"
        );
    }

    #[test]
    fn path_scope_matching_supports_directories() {
        assert!(path_matches_scope("apps/web/src/page.tsx", "apps/web"));
        assert!(path_matches_scope("apps/web", "apps/web"));
        assert!(!path_matches_scope("apps2/web/src/page.tsx", "apps/web"));
    }

    #[test]
    fn path_overlap_supports_root_and_nested_paths() {
        assert!(paths_overlap("apps/web", "apps/web/src/page.tsx"));
        assert!(!paths_overlap("apps/web", "packages/ui"));
    }

    #[test]
    fn prefix_upper_bound_increments_last_character() {
        assert_eq!(
            build_prefix_upper_bound("src/core/").as_deref(),
            Some("src/core0")
        );
    }

    #[cfg(unix)]
    #[test]
    fn repo_relative_path_rejects_broken_symlink_component() {
        use std::os::unix::fs::symlink;

        let repo_root = std::env::temp_dir().join(format!(
            "semantic-mcp-broken-symlink-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(repo_root.join("links")).unwrap();
        symlink(
            repo_root.join("missing-target"),
            repo_root.join("links/broken"),
        )
        .unwrap();
        let repo_root = repo_root.canonicalize().unwrap();

        let result = normalize_repo_relative_path(&repo_root, "links/broken/file.rs", "file_path");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("symlinks"));
    }

    #[test]
    fn sanitize() {
        assert_eq!(sanitize_value("a b\nc=d"), "a_b_c_d");
    }

    #[test]
    fn stable_json() {
        let val: serde_json::Value = serde_json::from_str(r#"{"b":2,"a":1}"#).unwrap();
        assert_eq!(stable_stringify(&val), r#"{"a":1,"b":2}"#);
    }
}
