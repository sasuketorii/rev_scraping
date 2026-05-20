//! Shell/Bash symbol and dependency extraction using tree-sitter.

use crate::extractors::{hash_bytes, RawDependency, SymbolExtractor};
use crate::types::{DependencyKind, RawSymbol, SymbolKind};

/// Extractor for Shell (Bash) source files.
pub struct ShellExtractor;

impl SymbolExtractor for ShellExtractor {
    fn extract_symbols(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawSymbol> {
        let mut symbols = Vec::new();
        let root = tree.root_node();
        extract_symbols_recursive(source, root, &mut symbols);
        symbols
    }

    fn extract_dependencies(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawDependency> {
        let mut deps = Vec::new();
        let root = tree.root_node();
        extract_deps_recursive(source, root, &mut deps);
        deps
    }
}

/// Recursively walk the parse tree and extract symbols.
fn extract_symbols_recursive(source: &[u8], node: tree_sitter::Node, symbols: &mut Vec<RawSymbol>) {
    // tree-sitter-bash can wrap otherwise valid siblings in a top-level ERROR
    // node during recovery, so we only reject function nodes that themselves
    // still carry parse errors.
    if node.kind() == "function_definition" && !node.has_error() {
        if let Some(sym) = extract_function(source, node) {
            symbols.push(sym);
        }
    }

    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            extract_symbols_recursive(source, child, symbols);
        }
    }
}

/// Extract a shell function definition.
fn extract_function(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name: name.clone(),
        qualified_name: None,
        kind: SymbolKind::Function,
        language: "shell".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: Some(format!("{name}()")),
        visibility: Some("public".to_string()),
        body_hash,
        children: Vec::new(),
    })
}

/// Recursively extract dependency references (command invocations).
fn extract_deps_recursive(source: &[u8], node: tree_sitter::Node, deps: &mut Vec<RawDependency>) {
    if node.kind() == "command_name" && !node.has_error() {
        let name = node_text(source, node);
        if !name.is_empty() {
            deps.push(RawDependency {
                to_name: name,
                kind: DependencyKind::Calls,
                source_line: node.start_position().row as u32 + 1,
            });
        }
    }

    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            extract_deps_recursive(source, child, deps);
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Get the UTF-8 text content of a node.
fn node_text(source: &[u8], node: tree_sitter::Node) -> String {
    node.utf8_text(source).unwrap_or("").to_string()
}

/// Compute a SHA-256 hash of a node's content.
fn compute_body_hash(source: &[u8], node: tree_sitter::Node) -> Option<String> {
    let start = node.start_byte();
    let end = node.end_byte();
    if start < end && end <= source.len() {
        Some(hash_bytes(&source[start..end]))
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse_source;

    fn extract_from_sh(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "shell").unwrap();
        let ext = ShellExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    fn extract_deps_from_sh(source: &str) -> Vec<RawDependency> {
        let tree = parse_source(source, "shell").unwrap();
        let ext = ShellExtractor;
        ext.extract_dependencies(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_function_definitions() {
        let source = "hello() {\n  echo hi\n}\nworld() {\n  echo bye\n}\n";
        let symbols = extract_from_sh(source);
        let fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert_eq!(fns.len(), 2);
        assert_eq!(fns[0].name, "hello");
        assert_eq!(fns[1].name, "world");
    }

    #[test]
    fn all_functions_are_public() {
        let source = "my_func() {\n  true\n}\n";
        let symbols = extract_from_sh(source);
        let func = symbols.iter().find(|s| s.name == "my_func");
        assert!(func.is_some());
        assert_eq!(func.unwrap().visibility.as_deref(), Some("public"));
    }

    #[test]
    fn function_has_signature() {
        let source = "greet() {\n  echo hello\n}\n";
        let symbols = extract_from_sh(source);
        let func = symbols.iter().find(|s| s.name == "greet");
        assert!(func.is_some());
        assert_eq!(func.unwrap().signature.as_deref(), Some("greet()"));
    }

    #[test]
    fn extracts_command_dependencies() {
        let source = "my_func() {\n  curl http://example.com\n  jq '.data'\n}\n";
        let deps = extract_deps_from_sh(source);
        let calls: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Calls)
            .map(|d| d.to_name.as_str())
            .collect();
        assert!(calls.contains(&"curl"));
        assert!(calls.contains(&"jq"));
    }

    #[test]
    fn handles_syntax_errors_gracefully() {
        let source = "good() {\n  echo ok\n}\n((( broken\nbad() {\n  echo no\n}\n";
        let symbols = extract_from_sh(source);
        let good = symbols.iter().find(|s| s.name == "good");
        assert!(good.is_some());
    }

    #[test]
    fn body_hash_is_populated() {
        let source = "hello() {\n  echo hi\n}\n";
        let symbols = extract_from_sh(source);
        let func = symbols.iter().find(|s| s.name == "hello");
        assert!(func.is_some());
        assert!(func.unwrap().body_hash.is_some());
    }
}
