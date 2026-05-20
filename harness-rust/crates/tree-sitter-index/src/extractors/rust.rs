//! Rust-specific symbol and dependency extraction using tree-sitter.

use crate::extractors::{hash_bytes, is_error_descendant, RawDependency, SymbolExtractor};
use crate::types::{DependencyKind, RawSymbol, SymbolKind};

/// Extractor for Rust source files.
pub struct RustExtractor;

impl SymbolExtractor for RustExtractor {
    fn extract_symbols(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawSymbol> {
        let mut symbols = Vec::new();
        let root = tree.root_node();
        extract_symbols_recursive(source, root, &mut symbols, None);
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
///
/// When `skip_functions` is true, standalone `function_item` nodes are not
/// extracted (used when recursing inside an `impl_item` whose methods have
/// already been captured as children of the impl symbol).
fn extract_symbols_recursive(
    source: &[u8],
    node: tree_sitter::Node,
    symbols: &mut Vec<RawSymbol>,
    _parent_name: Option<&str>,
) {
    extract_symbols_inner(source, node, symbols, _parent_name, false);
}

fn extract_symbols_inner(
    source: &[u8],
    node: tree_sitter::Node,
    symbols: &mut Vec<RawSymbol>,
    _parent_name: Option<&str>,
    skip_functions: bool,
) {
    if node.is_error() || is_error_descendant(node) {
        return;
    }

    // Track whether this node is an impl_item so we skip its body's
    // function_item children during recursion.
    let mut is_impl = false;

    match node.kind() {
        "function_item" => {
            if !skip_functions {
                if let Some(sym) = extract_function(source, node) {
                    symbols.push(sym);
                }
            }
            // Don't recurse into function bodies — no nested top-level symbols.
            return;
        }
        "struct_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Struct) {
                symbols.push(sym);
            }
        }
        "enum_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Enum) {
                symbols.push(sym);
            }
        }
        "trait_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Trait) {
                symbols.push(sym);
            }
        }
        "impl_item" => {
            if let Some(sym) = extract_impl(source, node) {
                symbols.push(sym);
            }
            is_impl = true;
        }
        "mod_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Mod) {
                symbols.push(sym);
            }
        }
        "const_item" | "static_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Const) {
                symbols.push(sym);
            }
        }
        "use_declaration" => {
            if let Some(sym) = extract_use(source, node) {
                symbols.push(sym);
            }
        }
        "type_item" => {
            if let Some(sym) = extract_named_item(source, node, SymbolKind::Type) {
                symbols.push(sym);
            }
        }
        _ => {}
    }

    // Recurse into children.  When inside an impl_item, skip function_item
    // children because they were already extracted as the impl's children.
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            extract_symbols_inner(source, child, symbols, _parent_name, is_impl);
        }
    }
}

/// Extract a function item with its signature.
fn extract_function(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = find_child_text(source, node, "name")?;
    let visibility = extract_visibility(source, node);
    let signature = build_function_signature(source, node);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Function,
        language: "rust".to_string(),
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

/// Extract a named item (struct, enum, trait, mod, const, type).
fn extract_named_item(
    source: &[u8],
    node: tree_sitter::Node,
    kind: SymbolKind,
) -> Option<RawSymbol> {
    let name = find_child_text(source, node, "name")?;
    let visibility = extract_visibility(source, node);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind,
        language: "rust".to_string(),
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

/// Extract an impl block, using the type name as the symbol name.
fn extract_impl(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    // impl blocks have a "type" child for the implementing type.
    let type_node = node.child_by_field_name("type")?;
    let type_text = node_text(source, type_node);
    let body_hash = compute_body_hash(source, node);

    // Check for trait impl: `impl Trait for Type`
    let trait_node = node.child_by_field_name("trait");
    let name = if let Some(tn) = trait_node {
        let trait_text = node_text(source, tn);
        format!("{trait_text} for {type_text}")
    } else {
        type_text
    };

    // Extract methods inside the impl block.
    let mut children = Vec::new();
    if let Some(body) = node.child_by_field_name("body") {
        let child_count = body.child_count();
        for i in 0..child_count {
            if let Some(child) = body.child(i) {
                if child.kind() == "function_item" && !child.is_error() {
                    if let Some(mut method) = extract_function(source, child) {
                        method.kind = SymbolKind::Method;
                        children.push(method);
                    }
                }
            }
        }
    }

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Impl,
        language: "rust".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: None,
        body_hash,
        children,
    })
}

/// Extract a use declaration as an Import symbol.
fn extract_use(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    // The argument child contains the use path.
    let arg_node = node.child_by_field_name("argument")?;
    let path_text = node_text(source, arg_node);
    let visibility = extract_visibility(source, node);

    // Use the last segment as the simple name.
    let name = path_text
        .rsplit("::")
        .next()
        .unwrap_or(&path_text)
        .trim_matches('{')
        .trim_matches('}')
        .trim()
        .to_string();

    Some(RawSymbol {
        name,
        qualified_name: Some(path_text),
        kind: SymbolKind::Import,
        language: "rust".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility,
        body_hash: None,
        children: Vec::new(),
    })
}

/// Recursively extract dependency references (function calls, type refs).
fn extract_deps_recursive(source: &[u8], node: tree_sitter::Node, deps: &mut Vec<RawDependency>) {
    if node.is_error() {
        return;
    }

    match node.kind() {
        "call_expression" => {
            // The function child of a call_expression.
            if let Some(func) = node.child_by_field_name("function") {
                let name = node_text(source, func);
                // Skip common macros and closures.
                if !name.is_empty() && !name.contains('|') {
                    deps.push(RawDependency {
                        to_name: name,
                        kind: DependencyKind::Calls,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        "use_declaration" => {
            if let Some(arg) = node.child_by_field_name("argument") {
                let path = node_text(source, arg);
                if !path.is_empty() {
                    deps.push(RawDependency {
                        to_name: path,
                        kind: DependencyKind::Imports,
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

/// Get the text of a child node with the given field name.
fn find_child_text(source: &[u8], node: tree_sitter::Node, field: &str) -> Option<String> {
    let child = node.child_by_field_name(field)?;
    let text = node_text(source, child);
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Get the UTF-8 text content of a node.
fn node_text(source: &[u8], node: tree_sitter::Node) -> String {
    node.utf8_text(source).unwrap_or("").to_string()
}

/// Extract the visibility modifier from a node, if present.
fn extract_visibility(source: &[u8], node: tree_sitter::Node) -> Option<String> {
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "visibility_modifier" {
                return Some(node_text(source, child));
            }
        }
    }
    None
}

/// Build a function signature string from parameter list and return type.
fn build_function_signature(source: &[u8], node: tree_sitter::Node) -> Option<String> {
    let name = find_child_text(source, node, "name")?;
    let params = node
        .child_by_field_name("parameters")
        .map(|p| node_text(source, p))
        .unwrap_or_else(|| "()".to_string());
    let return_type = node
        .child_by_field_name("return_type")
        .map(|r| format!(" {}", node_text(source, r)));

    Some(format!(
        "fn {name}{params}{}",
        return_type.unwrap_or_default()
    ))
}

/// Compute a SHA-256 hash of a node's body content.
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

    fn extract_from_rust(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "rust").unwrap();
        let ext = RustExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    fn extract_deps_from_rust(source: &str) -> Vec<RawDependency> {
        let tree = parse_source(source, "rust").unwrap();
        let ext = RustExtractor;
        ext.extract_dependencies(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_functions_with_correct_name_and_kind() {
        let symbols = extract_from_rust("fn hello() {} fn world() {}");
        let fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert_eq!(fns.len(), 2);
        assert_eq!(fns[0].name, "hello");
        assert_eq!(fns[1].name, "world");
        assert_eq!(fns[0].start_line, 1);
    }

    #[test]
    fn extracts_structs_enums_traits() {
        let source = "struct Foo {} enum Bar {} trait Baz {}";
        let symbols = extract_from_rust(source);
        let kinds: Vec<_> = symbols.iter().map(|s| (s.name.as_str(), s.kind)).collect();
        assert!(kinds.contains(&("Foo", SymbolKind::Struct)));
        assert!(kinds.contains(&("Bar", SymbolKind::Enum)));
        assert!(kinds.contains(&("Baz", SymbolKind::Trait)));
    }

    #[test]
    fn detects_pub_visibility() {
        let source = "pub fn visible() {} fn hidden() {}";
        let symbols = extract_from_rust(source);
        let visible = symbols.iter().find(|s| s.name == "visible");
        let hidden = symbols.iter().find(|s| s.name == "hidden");
        assert!(visible.is_some());
        assert_eq!(visible.unwrap().visibility.as_deref(), Some("pub"));
        assert!(hidden.is_some());
        assert!(hidden.unwrap().visibility.is_none());
    }

    #[test]
    fn generates_signature() {
        let source = "fn add(a: i32, b: i32) -> i32 { a + b }";
        let symbols = extract_from_rust(source);
        let func = symbols.iter().find(|s| s.name == "add");
        assert!(func.is_some());
        let sig = func.unwrap().signature.as_deref().unwrap_or("");
        assert!(sig.contains("fn add"));
        assert!(sig.contains("a: i32"));
    }

    #[test]
    fn extracts_use_declarations_as_import() {
        let source = "use std::collections::HashMap;";
        let symbols = extract_from_rust(source);
        let imports: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Import)
            .collect();
        assert_eq!(imports.len(), 1);
        assert_eq!(imports[0].name, "HashMap");
        assert!(imports[0]
            .qualified_name
            .as_deref()
            .unwrap_or("")
            .contains("std::collections::HashMap"));
    }

    #[test]
    fn extracts_impl_with_methods() {
        let source = r#"
struct Foo;
impl Foo {
    fn bar(&self) {}
    fn baz(&self) {}
}
"#;
        let symbols = extract_from_rust(source);
        let impl_sym = symbols.iter().find(|s| s.kind == SymbolKind::Impl);
        assert!(impl_sym.is_some());
        assert_eq!(impl_sym.unwrap().name, "Foo");
        assert_eq!(impl_sym.unwrap().children.len(), 2);
        assert_eq!(impl_sym.unwrap().children[0].kind, SymbolKind::Method);
        assert_eq!(impl_sym.unwrap().children[0].name, "bar");
    }

    #[test]
    fn extracts_const_items() {
        let source = "const MAX: u32 = 100;";
        let symbols = extract_from_rust(source);
        let consts: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Const)
            .collect();
        assert_eq!(consts.len(), 1);
        assert_eq!(consts[0].name, "MAX");
    }

    #[test]
    fn skips_error_node_descendants() {
        // Intentionally broken syntax — the parser will create ERROR nodes.
        // Symbols inside ERROR subtrees should be skipped.
        let source = "fn good() {} fn {broken fn bad() {}";
        let symbols = extract_from_rust(source);
        // "good" should be found; anything inside the ERROR region should be skipped.
        let good = symbols.iter().find(|s| s.name == "good");
        assert!(good.is_some());
    }

    #[test]
    fn extracts_call_dependencies() {
        let source = "fn main() { foo(); bar::baz(); }";
        let deps = extract_deps_from_rust(source);
        let call_names: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Calls)
            .map(|d| d.to_name.as_str())
            .collect();
        assert!(call_names.contains(&"foo"));
        assert!(call_names.iter().any(|n| n.contains("baz")));
    }

    #[test]
    fn extracts_import_dependencies() {
        let source = "use std::io::Read;";
        let deps = extract_deps_from_rust(source);
        let imports: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Imports)
            .collect();
        assert_eq!(imports.len(), 1);
        assert!(imports[0].to_name.contains("std::io::Read"));
    }

    #[test]
    fn body_hash_is_populated() {
        let source = "fn hello() { let x = 1; }";
        let symbols = extract_from_rust(source);
        let func = symbols.iter().find(|s| s.name == "hello");
        assert!(func.is_some());
        assert!(func.unwrap().body_hash.is_some());
    }
}
