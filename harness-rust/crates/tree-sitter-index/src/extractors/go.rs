//! Go symbol and dependency extraction using tree-sitter.

use crate::extractors::{hash_bytes, is_error_descendant, RawDependency, SymbolExtractor};
use crate::types::{DependencyKind, RawSymbol, SymbolKind};

/// Extractor for Go source files.
pub struct GoExtractor;

impl SymbolExtractor for GoExtractor {
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
    if node.is_error() || is_error_descendant(node) {
        return;
    }

    match node.kind() {
        "function_declaration" => {
            if let Some(sym) = extract_function(source, node) {
                symbols.push(sym);
            }
        }
        "method_declaration" => {
            if let Some(sym) = extract_method(source, node) {
                symbols.push(sym);
            }
        }
        "type_declaration" => {
            extract_type_declaration(source, node, symbols);
        }
        "import_declaration" => {
            extract_import_declaration(source, node, symbols);
        }
        "const_declaration" => {
            extract_const_declaration(source, node, symbols);
        }
        _ => {}
    }

    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            extract_symbols_recursive(source, child, symbols);
        }
    }
}

/// Extract a function declaration.
fn extract_function(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let visibility = go_visibility(&name);
    let signature = Some(
        node_text(source, node)
            .lines()
            .next()
            .unwrap_or("")
            .to_string(),
    );
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Function,
        language: "go".to_string(),
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

/// Extract a method declaration (function with receiver).
fn extract_method(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let visibility = go_visibility(&name);
    let signature = Some(
        node_text(source, node)
            .lines()
            .next()
            .unwrap_or("")
            .to_string(),
    );
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Method,
        language: "go".to_string(),
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

/// Extract type declarations (struct, interface, type alias).
fn extract_type_declaration(source: &[u8], node: tree_sitter::Node, symbols: &mut Vec<RawSymbol>) {
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "type_spec" {
                if let Some(sym) = extract_type_spec(source, child) {
                    symbols.push(sym);
                }
            }
        }
    }
}

/// Extract a single type_spec node.
fn extract_type_spec(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(source, n))?;
    if name.is_empty() {
        return None;
    }

    let type_node = node.child_by_field_name("type");
    let kind = match type_node.map(|t| t.kind()) {
        Some("struct_type") => SymbolKind::Struct,
        Some("interface_type") => SymbolKind::Interface,
        _ => SymbolKind::Type,
    };

    let visibility = go_visibility(&name);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind,
        language: "go".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility,
        body_hash,
        children: Vec::new(),
    })
}

/// Extract import declarations.
fn extract_import_declaration(
    source: &[u8],
    node: tree_sitter::Node,
    symbols: &mut Vec<RawSymbol>,
) {
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "import_spec" || child.kind() == "import_spec_list" {
                extract_import_specs(source, child, symbols);
            }
            // Single import without parens: `import "fmt"`
            if child.kind() == "interpreted_string_literal" {
                let path = node_text(source, child).trim_matches('"').to_string();
                if !path.is_empty() {
                    symbols.push(make_import_symbol(node, &path));
                }
            }
        }
    }
}

/// Extract import specs from an import_spec or import_spec_list.
fn extract_import_specs(source: &[u8], node: tree_sitter::Node, symbols: &mut Vec<RawSymbol>) {
    if node.kind() == "import_spec" {
        if let Some(path_node) = node.child_by_field_name("path") {
            let path = node_text(source, path_node).trim_matches('"').to_string();
            if !path.is_empty() {
                symbols.push(make_import_symbol(node, &path));
            }
        }
    }

    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "import_spec" {
                extract_import_specs(source, child, symbols);
            }
        }
    }
}

/// Create an Import RawSymbol for a Go import path.
fn make_import_symbol(node: tree_sitter::Node, path: &str) -> RawSymbol {
    let name = path.rsplit('/').next().unwrap_or(path).to_string();

    RawSymbol {
        name,
        qualified_name: Some(path.to_string()),
        kind: SymbolKind::Import,
        language: "go".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: None,
        body_hash: None,
        children: Vec::new(),
    }
}

/// Extract const declarations.
fn extract_const_declaration(source: &[u8], node: tree_sitter::Node, symbols: &mut Vec<RawSymbol>) {
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "const_spec" {
                if let Some(name_node) = child.child_by_field_name("name") {
                    let name = node_text(source, name_node);
                    if !name.is_empty() {
                        symbols.push(RawSymbol {
                            name: name.clone(),
                            qualified_name: None,
                            kind: SymbolKind::Const,
                            language: "go".to_string(),
                            start_line: child.start_position().row as u32 + 1,
                            end_line: child.end_position().row as u32 + 1,
                            start_col: child.start_position().column as u32,
                            end_col: child.end_position().column as u32,
                            signature: None,
                            visibility: go_visibility(&name),
                            body_hash: compute_body_hash(source, child),
                            children: Vec::new(),
                        });
                    }
                }
            }
        }
    }
}

/// Recursively extract dependency references.
fn extract_deps_recursive(source: &[u8], node: tree_sitter::Node, deps: &mut Vec<RawDependency>) {
    if node.is_error() {
        return;
    }

    match node.kind() {
        "import_spec" => {
            if let Some(path_node) = node.child_by_field_name("path") {
                let path = node_text(source, path_node).trim_matches('"').to_string();
                if !path.is_empty() {
                    deps.push(RawDependency {
                        to_name: path,
                        kind: DependencyKind::Imports,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        "call_expression" => {
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

/// Determine Go visibility: uppercase first letter is public, otherwise private.
fn go_visibility(name: &str) -> Option<String> {
    name.chars().next().map(|c| {
        if c.is_uppercase() {
            "public".to_string()
        } else {
            "private".to_string()
        }
    })
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

    fn extract_from_go(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "go").unwrap();
        let ext = GoExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    fn extract_deps_from_go(source: &str) -> Vec<RawDependency> {
        let tree = parse_source(source, "go").unwrap();
        let ext = GoExtractor;
        ext.extract_dependencies(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_function_declarations() {
        let source = r#"package main
func Hello() {}
func world() {}
"#;
        let symbols = extract_from_go(source);
        let fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert_eq!(fns.len(), 2);
        assert_eq!(fns[0].name, "Hello");
        assert_eq!(fns[1].name, "world");
    }

    #[test]
    fn extracts_struct_and_interface() {
        let source = r#"package main
type User struct {
    Name string
    Age  int
}
type Reader interface {
    Read(p []byte) (n int, err error)
}
"#;
        let symbols = extract_from_go(source);
        let structs: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Struct)
            .collect();
        let ifaces: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Interface)
            .collect();
        assert_eq!(structs.len(), 1);
        assert_eq!(structs[0].name, "User");
        assert_eq!(ifaces.len(), 1);
        assert_eq!(ifaces[0].name, "Reader");
    }

    #[test]
    fn extracts_imports() {
        let source = r#"package main
import (
    "fmt"
    "os"
)
"#;
        let symbols = extract_from_go(source);
        let imports: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Import)
            .collect();
        assert!(imports.len() >= 2);
        assert!(imports.iter().any(|i| i.name == "fmt"));
        assert!(imports.iter().any(|i| i.name == "os"));
    }

    #[test]
    fn go_visibility_convention() {
        let source = r#"package main
func Exported() {}
func unexported() {}
"#;
        let symbols = extract_from_go(source);
        let exported = symbols.iter().find(|s| s.name == "Exported");
        let unexported = symbols.iter().find(|s| s.name == "unexported");
        assert_eq!(exported.unwrap().visibility.as_deref(), Some("public"));
        assert_eq!(unexported.unwrap().visibility.as_deref(), Some("private"));
    }

    #[test]
    fn extracts_const_declarations() {
        let source = r#"package main
const MaxSize = 100
"#;
        let symbols = extract_from_go(source);
        let consts: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Const)
            .collect();
        assert_eq!(consts.len(), 1);
        assert_eq!(consts[0].name, "MaxSize");
    }

    #[test]
    fn extracts_method_declarations() {
        let source = r#"package main
type Foo struct{}
func (f *Foo) Bar() {}
"#;
        let symbols = extract_from_go(source);
        let methods: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Method)
            .collect();
        assert_eq!(methods.len(), 1);
        assert_eq!(methods[0].name, "Bar");
    }

    #[test]
    fn extracts_call_dependencies() {
        let source = r#"package main
import "fmt"
func main() {
    fmt.Println("hello")
}
"#;
        let deps = extract_deps_from_go(source);
        let calls: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Calls)
            .collect();
        assert!(!calls.is_empty());
    }

    #[test]
    fn handles_syntax_errors_gracefully() {
        let source = r#"package main
func Good() {}
func { broken }
func Bad() {}
"#;
        let symbols = extract_from_go(source);
        let good = symbols.iter().find(|s| s.name == "Good");
        assert!(good.is_some());
    }

    #[test]
    fn function_has_signature() {
        let source = r#"package main
func Add(a int, b int) int {
    return a + b
}
"#;
        let symbols = extract_from_go(source);
        let func = symbols.iter().find(|s| s.name == "Add");
        assert!(func.is_some());
        let sig = func.unwrap().signature.as_deref().unwrap_or("");
        assert!(sig.contains("func Add"));
    }
}
