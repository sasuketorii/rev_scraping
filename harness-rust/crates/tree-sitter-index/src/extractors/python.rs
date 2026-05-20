//! Python symbol and dependency extraction using tree-sitter.

use crate::extractors::{hash_bytes, is_error_descendant, RawDependency, SymbolExtractor};
use crate::types::{DependencyKind, RawSymbol, SymbolKind};

/// Extractor for Python source files.
pub struct PythonExtractor;

impl SymbolExtractor for PythonExtractor {
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
    extract_symbols_inner(source, node, symbols, false);
}

/// Inner recursive extraction with `in_class` flag to prevent double extraction
/// of class methods (they are already captured as children of the class symbol).
fn extract_symbols_inner(
    source: &[u8],
    node: tree_sitter::Node,
    symbols: &mut Vec<RawSymbol>,
    in_class: bool,
) {
    if node.is_error() || is_error_descendant(node) {
        return;
    }

    // Track whether we are entering a class body so child recursion skips functions.
    let mut entering_class = false;

    match node.kind() {
        "function_definition" if !in_class => {
            // Skip if inside a class body — already captured as a child method.
            if let Some(sym) = extract_function(source, node) {
                symbols.push(sym);
            }
        }
        "class_definition" => {
            if let Some(sym) = extract_class(source, node) {
                symbols.push(sym);
            }
            entering_class = true;
        }
        "import_statement" => {
            if let Some(sym) = extract_import(source, node) {
                symbols.push(sym);
            }
        }
        "import_from_statement" => {
            if let Some(sym) = extract_import_from(source, node) {
                symbols.push(sym);
            }
        }
        "decorated_definition" => {
            // Look at the actual definition child (function or class).
            let child_count = node.child_count();
            for i in 0..child_count {
                if let Some(child) = node.child(i) {
                    match child.kind() {
                        "function_definition" if !in_class => {
                            // Skip if inside a class — already captured as child method.
                            if let Some(sym) = extract_function(source, child) {
                                symbols.push(sym);
                            }
                        }
                        "class_definition" => {
                            if let Some(sym) = extract_class(source, child) {
                                symbols.push(sym);
                            }
                        }
                        _ => {}
                    }
                }
            }
            // Skip recursion into children since we handled them above.
            return;
        }
        _ => {}
    }

    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            extract_symbols_inner(source, child, symbols, in_class || entering_class);
        }
    }
}

/// Extract a function definition.
fn extract_function(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let visibility = if name.starts_with('_') {
        Some("private".to_string())
    } else {
        Some("public".to_string())
    };

    let signature = build_function_signature(source, node, &name);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Function,
        language: "python".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature,
        visibility,
        body_hash,
        children: Vec::new(),
    })
}

/// Extract a class definition with its methods as children.
fn extract_class(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let visibility = if name.starts_with('_') {
        Some("private".to_string())
    } else {
        Some("public".to_string())
    };

    let body_hash = compute_body_hash(source, node);

    let mut children = Vec::new();
    if let Some(body) = node.child_by_field_name("body") {
        let child_count = body.child_count();
        for i in 0..child_count {
            if let Some(child) = body.child(i) {
                if child.kind() == "function_definition" && !child.is_error() {
                    if let Some(mut method) = extract_function(source, child) {
                        method.kind = SymbolKind::Method;
                        children.push(method);
                    }
                }
                // Handle decorated methods.
                if child.kind() == "decorated_definition" && !child.is_error() {
                    let inner_count = child.child_count();
                    for j in 0..inner_count {
                        if let Some(inner) = child.child(j) {
                            if inner.kind() == "function_definition" {
                                if let Some(mut method) = extract_function(source, inner) {
                                    method.kind = SymbolKind::Method;
                                    children.push(method);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Class,
        language: "python".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility,
        body_hash,
        children,
    })
}

/// Extract an `import` statement.
fn extract_import(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    // `import foo` or `import foo, bar`
    let text = node_text(source, node);
    let module = text
        .strip_prefix("import")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if module.is_empty() {
        return None;
    }

    Some(RawSymbol {
        name: module.clone(),
        qualified_name: Some(module),
        kind: SymbolKind::Import,
        language: "python".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: None,
        body_hash: None,
        children: Vec::new(),
    })
}

/// Extract a `from ... import ...` statement.
fn extract_import_from(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let module_node = node.child_by_field_name("module_name")?;
    let module = node_text(source, module_node);
    if module.is_empty() {
        return None;
    }

    Some(RawSymbol {
        name: module.clone(),
        qualified_name: Some(module),
        kind: SymbolKind::Import,
        language: "python".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: None,
        body_hash: None,
        children: Vec::new(),
    })
}

/// Recursively extract dependency references.
fn extract_deps_recursive(source: &[u8], node: tree_sitter::Node, deps: &mut Vec<RawDependency>) {
    if node.is_error() {
        return;
    }

    match node.kind() {
        "import_statement" => {
            let text = node_text(source, node);
            if let Some(module) = text.strip_prefix("import") {
                let module = module.trim();
                if !module.is_empty() {
                    deps.push(RawDependency {
                        to_name: module.to_string(),
                        kind: DependencyKind::Imports,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        "import_from_statement" => {
            if let Some(module_node) = node.child_by_field_name("module_name") {
                let module = node_text(source, module_node);
                if !module.is_empty() {
                    deps.push(RawDependency {
                        to_name: module,
                        kind: DependencyKind::Imports,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        "call" => {
            if let Some(func) = node.child_by_field_name("function") {
                let name = node_text(source, func);
                if !name.is_empty() {
                    deps.push(RawDependency {
                        to_name: name,
                        kind: DependencyKind::Calls,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        _ => {}
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

/// Build a function signature from parameters.
fn build_function_signature(source: &[u8], node: tree_sitter::Node, name: &str) -> Option<String> {
    let params = node
        .child_by_field_name("parameters")
        .map(|p| node_text(source, p))
        .unwrap_or_else(|| "()".to_string());

    let return_type = node
        .child_by_field_name("return_type")
        .map(|r| format!(" -> {}", node_text(source, r)));

    Some(format!(
        "def {name}{params}{}",
        return_type.unwrap_or_default()
    ))
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

    fn extract_from_py(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "python").unwrap();
        let ext = PythonExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    fn extract_deps_from_py(source: &str) -> Vec<RawDependency> {
        let tree = parse_source(source, "python").unwrap();
        let ext = PythonExtractor;
        ext.extract_dependencies(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_function_definitions() {
        let source = "def hello():\n    pass\n\ndef world():\n    pass\n";
        let symbols = extract_from_py(source);
        let fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert_eq!(fns.len(), 2);
        assert_eq!(fns[0].name, "hello");
        assert_eq!(fns[1].name, "world");
    }

    #[test]
    fn extracts_class_with_methods() {
        let source = "class Greeter:\n    def greet(self):\n        pass\n    def farewell(self):\n        pass\n";
        let symbols = extract_from_py(source);
        let class = symbols.iter().find(|s| s.kind == SymbolKind::Class);
        assert!(class.is_some());
        let class = class.unwrap();
        assert_eq!(class.name, "Greeter");
        assert_eq!(class.children.len(), 2);
        assert_eq!(class.children[0].kind, SymbolKind::Method);
        // Methods should NOT be duplicated as standalone functions.
        let top_fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert_eq!(
            top_fns.len(),
            0,
            "class methods should not appear as standalone functions"
        );
    }

    #[test]
    fn extracts_imports() {
        let source = "import os\nfrom pathlib import Path\n";
        let symbols = extract_from_py(source);
        let imports: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Import)
            .collect();
        assert!(!imports.is_empty());
        assert!(imports.iter().any(|i| i.name.contains("os")));
    }

    #[test]
    fn extracts_import_from_dependencies() {
        let source = "from typing import List, Dict\n";
        let deps = extract_deps_from_py(source);
        let imports: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Imports)
            .collect();
        assert!(!imports.is_empty());
        assert!(imports.iter().any(|d| d.to_name.contains("typing")));
    }

    #[test]
    fn extracts_call_dependencies() {
        let source = "def main():\n    foo()\n    bar(1, 2)\n";
        let deps = extract_deps_from_py(source);
        let calls: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Calls)
            .map(|d| d.to_name.as_str())
            .collect();
        assert!(calls.contains(&"foo"));
        assert!(calls.contains(&"bar"));
    }

    #[test]
    fn private_visibility_for_underscore_names() {
        let source = "def _private():\n    pass\n\ndef public():\n    pass\n";
        let symbols = extract_from_py(source);
        let private = symbols.iter().find(|s| s.name == "_private");
        let public = symbols.iter().find(|s| s.name == "public");
        assert_eq!(private.unwrap().visibility.as_deref(), Some("private"));
        assert_eq!(public.unwrap().visibility.as_deref(), Some("public"));
    }

    #[test]
    fn handles_syntax_errors_gracefully() {
        let source = "def good():\n    pass\ndef (broken:\n    pass\ndef bad():\n    pass\n";
        let symbols = extract_from_py(source);
        let good = symbols.iter().find(|s| s.name == "good");
        assert!(good.is_some());
    }

    #[test]
    fn function_has_signature() {
        let source = "def greet(name: str) -> str:\n    return name\n";
        let symbols = extract_from_py(source);
        let func = symbols.iter().find(|s| s.name == "greet");
        assert!(func.is_some());
        let sig = func.unwrap().signature.as_deref().unwrap_or("");
        assert!(sig.contains("def greet"));
        assert!(sig.contains("name"));
    }
}
