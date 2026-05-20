//! TypeScript/JavaScript symbol and dependency extraction using tree-sitter.

use crate::extractors::{hash_bytes, is_error_descendant, RawDependency, SymbolExtractor};
use crate::types::{DependencyKind, RawSymbol, SymbolKind};

/// Extractor for TypeScript and JavaScript source files.
pub struct TypeScriptExtractor;

impl SymbolExtractor for TypeScriptExtractor {
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

    // Track whether we are entering a class body so child recursion skips methods.
    let mut entering_class = false;

    match node.kind() {
        "function_declaration" => {
            if let Some(sym) = extract_function(source, node) {
                symbols.push(sym);
            }
        }
        "class_declaration" => {
            if let Some(sym) = extract_class(source, node) {
                symbols.push(sym);
            }
            entering_class = true;
        }
        "method_definition" if !in_class => {
            // Skip if inside a class body — already captured as a child.
            if let Some(sym) = extract_method(source, node) {
                symbols.push(sym);
            }
        }
        "interface_declaration" => {
            if let Some(sym) = extract_named_symbol(source, node, SymbolKind::Interface) {
                symbols.push(sym);
            }
        }
        "type_alias_declaration" => {
            if let Some(sym) = extract_named_symbol(source, node, SymbolKind::Type) {
                symbols.push(sym);
            }
        }
        "import_statement" => {
            if let Some(sym) = extract_import(source, node) {
                symbols.push(sym);
            }
        }
        "export_statement" => {
            if let Some(sym) = extract_export(source, node) {
                symbols.push(sym);
            }
        }
        "lexical_declaration" | "variable_declaration" => {
            // Handle `const foo = () => {}` pattern.
            extract_variable_declarations(source, node, symbols);
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

/// Extract a function declaration.
fn extract_function(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = find_child_by_kind_text(source, node, "identifier")?;
    let visibility = check_export_ancestor(node);
    let signature = build_function_signature(source, node, &name);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Function,
        language: "typescript".to_string(),
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

/// Extract a class declaration with its methods as children.
fn extract_class(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = find_child_by_kind_text(source, node, "type_identifier")
        .or_else(|| find_child_by_kind_text(source, node, "identifier"))?;
    let visibility = check_export_ancestor(node);
    let body_hash = compute_body_hash(source, node);

    let mut children = Vec::new();
    if let Some(body) = node.child_by_field_name("body") {
        let child_count = body.child_count();
        for i in 0..child_count {
            if let Some(child) = body.child(i) {
                if child.kind() == "method_definition" && !child.is_error() {
                    if let Some(method) = extract_method(source, child) {
                        children.push(method);
                    }
                }
            }
        }
    }

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Class,
        language: "typescript".to_string(),
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

/// Extract a method definition.
fn extract_method(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let name = find_child_by_kind_text(source, node, "property_identifier")
        .or_else(|| find_child_by_kind_text(source, node, "identifier"))?;
    let signature = build_function_signature(source, node, &name);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Method,
        language: "typescript".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature,
        visibility: None,
        body_hash,
        children: Vec::new(),
    })
}

/// Extract a named symbol (interface, type alias).
fn extract_named_symbol(
    source: &[u8],
    node: tree_sitter::Node,
    kind: SymbolKind,
) -> Option<RawSymbol> {
    let name = find_child_by_kind_text(source, node, "type_identifier")
        .or_else(|| find_child_by_kind_text(source, node, "identifier"))?;
    let visibility = check_export_ancestor(node);
    let body_hash = compute_body_hash(source, node);

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind,
        language: "typescript".to_string(),
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

/// Extract an import statement as an Import symbol.
fn extract_import(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let source_node = node.child_by_field_name("source")?;
    let module_path = node_text(source, source_node)
        .trim_matches(|c| c == '\'' || c == '"')
        .to_string();

    Some(RawSymbol {
        name: module_path.clone(),
        qualified_name: Some(module_path),
        kind: SymbolKind::Import,
        language: "typescript".to_string(),
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

/// Extract an export statement. May contain a declaration as a child.
fn extract_export(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    // If the export wraps a declaration, we skip the export symbol itself
    // and let the child declaration be extracted with export visibility.
    // Only emit an Export symbol for bare/default exports.
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            let k = child.kind();
            if k == "function_declaration"
                || k == "class_declaration"
                || k == "lexical_declaration"
                || k == "interface_declaration"
                || k == "type_alias_declaration"
            {
                // The child will be extracted in its own match arm.
                return None;
            }
        }
    }

    let text = node_text(source, node);
    let name = text
        .split_whitespace()
        .nth(1)
        .unwrap_or("default")
        .to_string();

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Export,
        language: "typescript".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: Some("export".to_string()),
        body_hash: None,
        children: Vec::new(),
    })
}

/// Extract variable declarations that hold arrow functions or exported consts.
fn extract_variable_declarations(
    source: &[u8],
    node: tree_sitter::Node,
    symbols: &mut Vec<RawSymbol>,
) {
    let visibility = check_export_ancestor(node);
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == "variable_declarator" {
                let name = child
                    .child_by_field_name("name")
                    .map(|n| node_text(source, n));
                let value = child.child_by_field_name("value");

                if let (Some(name), Some(val)) = (name, value) {
                    if name.is_empty() {
                        continue;
                    }
                    let is_arrow = val.kind() == "arrow_function";
                    let kind = if is_arrow {
                        SymbolKind::Function
                    } else if visibility.is_some() {
                        SymbolKind::Const
                    } else {
                        continue;
                    };

                    let signature = if is_arrow {
                        build_arrow_signature(source, val, &name)
                    } else {
                        None
                    };

                    symbols.push(RawSymbol {
                        name,
                        qualified_name: None,
                        kind,
                        language: "typescript".to_string(),
                        start_line: child.start_position().row as u32 + 1,
                        end_line: child.end_position().row as u32 + 1,
                        start_col: child.start_position().column as u32,
                        end_col: child.end_position().column as u32,
                        signature,
                        visibility: visibility.clone(),
                        body_hash: compute_body_hash(source, child),
                        children: Vec::new(),
                    });
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
        "import_statement" => {
            if let Some(source_node) = node.child_by_field_name("source") {
                let module = node_text(source, source_node)
                    .trim_matches(|c: char| c == '\'' || c == '"')
                    .to_string();
                if !module.is_empty() {
                    deps.push(RawDependency {
                        to_name: module,
                        kind: DependencyKind::Imports,
                        source_line: node.start_position().row as u32 + 1,
                    });
                }
            }
        }
        "call_expression" => {
            if let Some(func) = node.child_by_field_name("function") {
                let name = node_text(source, func);
                if !name.is_empty() && name != "require" {
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

/// Find the first direct child matching the given node kind and return its text.
fn find_child_by_kind_text(source: &[u8], node: tree_sitter::Node, kind: &str) -> Option<String> {
    let child_count = node.child_count();
    for i in 0..child_count {
        if let Some(child) = node.child(i) {
            if child.kind() == kind {
                let text = node_text(source, child);
                if !text.is_empty() {
                    return Some(text);
                }
            }
        }
    }
    None
}

/// Check if the node has an `export_statement` ancestor, returning `Some("export")`.
fn check_export_ancestor(node: tree_sitter::Node) -> Option<String> {
    let mut current = node;
    while let Some(parent) = current.parent() {
        if parent.kind() == "export_statement" {
            return Some("export".to_string());
        }
        current = parent;
    }
    None
}

/// Build a function signature from parameters and optional return type.
fn build_function_signature(source: &[u8], node: tree_sitter::Node, name: &str) -> Option<String> {
    let params = node
        .child_by_field_name("parameters")
        .map(|p| node_text(source, p))
        .unwrap_or_else(|| "()".to_string());

    let return_type = node
        .child_by_field_name("return_type")
        .map(|r| format!(": {}", node_text(source, r)));

    Some(format!(
        "function {name}{params}{}",
        return_type.unwrap_or_default()
    ))
}

/// Build a signature for an arrow function.
fn build_arrow_signature(
    source: &[u8],
    arrow_node: tree_sitter::Node,
    name: &str,
) -> Option<String> {
    let params = arrow_node
        .child_by_field_name("parameters")
        .map(|p| node_text(source, p))
        .or_else(|| {
            // Single-parameter arrow without parens.
            arrow_node
                .child_by_field_name("parameter")
                .map(|p| format!("({})", node_text(source, p)))
        })
        .unwrap_or_else(|| "()".to_string());

    let return_type = arrow_node
        .child_by_field_name("return_type")
        .map(|r| format!(": {}", node_text(source, r)));

    Some(format!(
        "const {name} = {params} =>{}",
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

    fn extract_from_ts(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "typescript").unwrap();
        let ext = TypeScriptExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    fn extract_deps_from_ts(source: &str) -> Vec<RawDependency> {
        let tree = parse_source(source, "typescript").unwrap();
        let ext = TypeScriptExtractor;
        ext.extract_dependencies(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_function_declarations() {
        let symbols = extract_from_ts("function hello() {} function world() {}");
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
        let source = r#"
class Greeter {
    greet() { return "hi"; }
    farewell() { return "bye"; }
}
"#;
        let symbols = extract_from_ts(source);
        let class = symbols.iter().find(|s| s.kind == SymbolKind::Class);
        assert!(class.is_some());
        let class = class.unwrap();
        assert_eq!(class.name, "Greeter");
        assert_eq!(class.children.len(), 2);
        // Methods should NOT be duplicated at top level.
        let top_methods: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Method)
            .collect();
        assert_eq!(
            top_methods.len(),
            0,
            "class methods should not appear as standalone symbols"
        );
    }

    #[test]
    fn extracts_interface_declaration() {
        let source = "interface User { name: string; age: number; }";
        let symbols = extract_from_ts(source);
        let iface = symbols.iter().find(|s| s.kind == SymbolKind::Interface);
        assert!(iface.is_some());
        assert_eq!(iface.unwrap().name, "User");
    }

    #[test]
    fn extracts_type_alias() {
        let source = "type ID = string | number;";
        let symbols = extract_from_ts(source);
        let ty = symbols.iter().find(|s| s.kind == SymbolKind::Type);
        assert!(ty.is_some());
        assert_eq!(ty.unwrap().name, "ID");
    }

    #[test]
    fn extracts_imports() {
        let source = r#"import { useState } from "react";"#;
        let symbols = extract_from_ts(source);
        let imports: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Import)
            .collect();
        assert_eq!(imports.len(), 1);
        assert_eq!(imports[0].name, "react");
    }

    #[test]
    fn extracts_import_dependencies() {
        let source = r#"import { foo } from "./bar";"#;
        let deps = extract_deps_from_ts(source);
        let imports: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Imports)
            .collect();
        assert_eq!(imports.len(), 1);
        assert_eq!(imports[0].to_name, "./bar");
    }

    #[test]
    fn extracts_call_dependencies() {
        let source = "function main() { foo(); bar(1, 2); }";
        let deps = extract_deps_from_ts(source);
        let calls: Vec<_> = deps
            .iter()
            .filter(|d| d.kind == DependencyKind::Calls)
            .map(|d| d.to_name.as_str())
            .collect();
        assert!(calls.contains(&"foo"));
        assert!(calls.contains(&"bar"));
    }

    #[test]
    fn handles_syntax_errors_gracefully() {
        // Intentionally broken syntax.
        let source = "function good() {} function { broken } function bad() {}";
        let symbols = extract_from_ts(source);
        let good = symbols.iter().find(|s| s.name == "good");
        assert!(good.is_some());
    }

    #[test]
    fn extracts_arrow_function_with_const() {
        let source = "export const add = (a: number, b: number): number => a + b;";
        let symbols = extract_from_ts(source);
        let fns: Vec<_> = symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Function)
            .collect();
        assert!(!fns.is_empty());
        assert!(fns.iter().any(|f| f.name == "add"));
    }

    #[test]
    fn function_has_signature() {
        let source = "function greet(name: string): void {}";
        let symbols = extract_from_ts(source);
        let func = symbols.iter().find(|s| s.name == "greet");
        assert!(func.is_some());
        let sig = func.unwrap().signature.as_deref().unwrap_or("");
        assert!(sig.contains("greet"));
        assert!(sig.contains("name"));
    }
}
