//! Symbol and dependency extraction from tree-sitter parse trees.
//!
//! Each supported language has its own extractor module implementing
//! the [`SymbolExtractor`] trait.

#[cfg(feature = "lang-go")]
pub mod go;
#[cfg(feature = "lang-python")]
pub mod python;
#[cfg(feature = "lang-rust")]
pub mod rust;
#[cfg(feature = "lang-shell")]
pub mod shell;
#[cfg(feature = "lang-typescript")]
pub mod typescript;

use crate::types::{DependencyKind, RawSymbol};

// ---------------------------------------------------------------------------
// RawDependency
// ---------------------------------------------------------------------------

/// A dependency extracted from a parse tree, before database insertion.
#[derive(Debug, Clone)]
pub struct RawDependency {
    /// Name of the depended-upon symbol.
    pub to_name: String,
    /// What kind of dependency this is.
    pub kind: DependencyKind,
    /// 1-based line number where the dependency reference occurs (for attribution).
    pub source_line: u32,
}

// ---------------------------------------------------------------------------
// SymbolExtractor trait
// ---------------------------------------------------------------------------

/// Trait for language-specific symbol and dependency extraction.
pub trait SymbolExtractor {
    /// Extract all symbols from a parsed source file.
    fn extract_symbols(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawSymbol>;

    /// Extract all dependency references from a parsed source file.
    fn extract_dependencies(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawDependency>;
}

// ---------------------------------------------------------------------------
// Extractor factory
// ---------------------------------------------------------------------------

/// Return a [`SymbolExtractor`] for the given language, or `None` if
/// the language has no extractor implementation.
pub fn get_extractor(language: &str) -> Option<Box<dyn SymbolExtractor>> {
    match language {
        #[cfg(feature = "lang-rust")]
        "rust" => Some(Box::new(rust::RustExtractor)),
        #[cfg(feature = "lang-typescript")]
        "typescript" | "tsx" => Some(Box::new(typescript::TypeScriptExtractor)),
        #[cfg(feature = "lang-typescript")]
        "javascript" | "jsx" => Some(Box::new(typescript::TypeScriptExtractor)),
        #[cfg(feature = "lang-python")]
        "python" => Some(Box::new(python::PythonExtractor)),
        #[cfg(feature = "lang-go")]
        "go" => Some(Box::new(go::GoExtractor)),
        #[cfg(feature = "lang-shell")]
        "shell" | "bash" => Some(Box::new(shell::ShellExtractor)),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Check whether a tree-sitter node is a descendant of an ERROR node.
///
/// Symbols inside ERROR subtrees are unreliable and should be skipped.
pub fn is_error_descendant(node: tree_sitter::Node) -> bool {
    let mut current = node;
    while let Some(parent) = current.parent() {
        if parent.is_error() {
            return true;
        }
        current = parent;
    }
    false
}

/// Compute a SHA-256 hash of the given byte slice and return it as a hex string.
pub(crate) fn hash_bytes(data: &[u8]) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(data);
    hex::encode(digest)
}
