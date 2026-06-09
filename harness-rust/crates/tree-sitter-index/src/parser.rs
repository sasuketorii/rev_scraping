//! Tree-sitter parser configuration and source parsing.
//!
//! Provides language resolution and source code parsing with feature-gated
//! language support.

use shared::error::AgentError;

/// Return the tree-sitter [`Language`] for a given language identifier.
///
/// Returns `None` if the language is not supported or the corresponding
/// feature is not enabled.
///
/// # Supported identifiers
///
/// | Identifier | Feature |
/// |---|---|
/// | `"rust"` | `lang-rust` |
/// | `"typescript"`, `"tsx"` | `lang-typescript` |
/// | `"javascript"`, `"jsx"` | `lang-typescript` |
/// | `"python"` | `lang-python` |
/// | `"go"` | `lang-go` |
/// | `"shell"`, `"bash"` | `lang-shell` |
/// | `"markdown"` | `lang-markdown` |
pub fn get_language(lang: &str) -> Option<tree_sitter::Language> {
    match lang {
        #[cfg(feature = "lang-rust")]
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),

        #[cfg(feature = "lang-typescript")]
        "typescript" | "tsx" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),

        #[cfg(feature = "lang-typescript")]
        "javascript" | "jsx" => Some(tree_sitter_javascript::LANGUAGE.into()),

        #[cfg(feature = "lang-python")]
        "python" => Some(tree_sitter_python::LANGUAGE.into()),

        #[cfg(feature = "lang-go")]
        "go" => Some(tree_sitter_go::LANGUAGE.into()),

        #[cfg(feature = "lang-shell")]
        "shell" | "bash" => Some(tree_sitter_bash::LANGUAGE.into()),

        #[cfg(feature = "lang-markdown")]
        "markdown" => Some(tree_sitter_md::LANGUAGE.into()),

        _ => None,
    }
}

/// Parse source code with tree-sitter for the given language.
///
/// Returns the parse tree on success, or an [`AgentError`] if the language
/// is unsupported or parsing fails.
pub fn parse_source(source: &str, language: &str) -> shared::error::Result<tree_sitter::Tree> {
    let ts_lang = get_language(language).ok_or_else(|| {
        AgentError::Validation(format!(
            "unsupported language for tree-sitter parsing: {language}"
        ))
    })?;

    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&ts_lang).map_err(|e| {
        AgentError::State(format!(
            "failed to set tree-sitter language for {language}: {e}"
        ))
    })?;

    parser.parse(source, None).ok_or_else(|| {
        AgentError::State(format!("tree-sitter failed to parse source as {language}"))
    })
}

/// Detect the language identifier from a file extension.
///
/// Returns `None` if the extension is not recognized.
pub fn detect_language(file_path: &str) -> Option<&'static str> {
    let ext = file_path.rsplit('.').next()?;
    match ext {
        "rs" => Some("rust"),
        "ts" => Some("typescript"),
        "tsx" => Some("tsx"),
        "js" => Some("javascript"),
        "jsx" => Some("jsx"),
        "py" => Some("python"),
        "go" => Some("go"),
        "sh" | "bash" => Some("shell"),
        "md" | "markdown" => Some("markdown"),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_language_returns_some_for_rust() {
        assert!(get_language("rust").is_some());
    }

    #[test]
    fn get_language_returns_none_for_unsupported() {
        assert!(get_language("cobol").is_none());
        assert!(get_language("").is_none());
    }

    #[test]
    fn parse_source_succeeds_for_valid_rust() {
        let source = "fn main() { println!(\"hello\"); }";
        let tree = parse_source(source, "rust");
        assert!(tree.is_ok());
    }

    #[test]
    fn parse_source_returns_error_for_unsupported_language() {
        let result = parse_source("some code", "cobol");
        assert!(result.is_err());
        let err_msg = format!("{}", result.unwrap_err());
        assert!(err_msg.contains("unsupported language"));
    }

    #[test]
    fn detect_language_known_extensions() {
        assert_eq!(detect_language("src/main.rs"), Some("rust"));
        assert_eq!(detect_language("index.ts"), Some("typescript"));
        assert_eq!(detect_language("app.tsx"), Some("tsx"));
        assert_eq!(detect_language("lib.py"), Some("python"));
        assert_eq!(detect_language("main.go"), Some("go"));
        assert_eq!(detect_language("run.sh"), Some("shell"));
        assert_eq!(detect_language("README.md"), Some("markdown"));
        assert_eq!(detect_language("README.markdown"), Some("markdown"));
    }

    #[test]
    fn detect_language_unknown_extension() {
        assert_eq!(detect_language("data.csv"), None);
        assert_eq!(detect_language("Makefile"), None);
    }
}
