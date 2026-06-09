//! Markdown symbol extraction using tree-sitter.

use crate::extractors::{hash_bytes, RawDependency, SymbolExtractor};
use crate::types::{RawSymbol, SymbolKind};

/// Extractor for Markdown source files.
pub struct MarkdownExtractor;

impl SymbolExtractor for MarkdownExtractor {
    fn extract_symbols(&self, source: &[u8], tree: &tree_sitter::Tree) -> Vec<RawSymbol> {
        let mut symbols = Vec::new();
        let root = tree.root_node();
        extract_symbols_recursive(source, root, &mut symbols);
        symbols
    }

    fn extract_dependencies(
        &self,
        _source: &[u8],
        _tree: &tree_sitter::Tree,
    ) -> Vec<RawDependency> {
        Vec::new()
    }
}

fn extract_symbols_recursive(source: &[u8], node: tree_sitter::Node, symbols: &mut Vec<RawSymbol>) {
    if node.kind() == "atx_heading" && !node.has_error() {
        if let Some(sym) = extract_heading(source, node) {
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

fn extract_heading(source: &[u8], node: tree_sitter::Node) -> Option<RawSymbol> {
    let content = node
        .child_by_field_name("heading_content")
        .map(|n| node_text(source, n))
        .unwrap_or_else(|| heading_text_from_line(source, node));
    let name = content.trim().trim_matches('#').trim().to_string();
    if name.is_empty() {
        return None;
    }

    Some(RawSymbol {
        name,
        qualified_name: None,
        kind: SymbolKind::Mod,
        language: "markdown".to_string(),
        start_line: node.start_position().row as u32 + 1,
        end_line: node.end_position().row as u32 + 1,
        start_col: node.start_position().column as u32,
        end_col: node.end_position().column as u32,
        signature: None,
        visibility: Some("public".to_string()),
        body_hash: compute_section_hash(source, node),
        children: Vec::new(),
    })
}

fn heading_text_from_line(source: &[u8], node: tree_sitter::Node) -> String {
    node_text(source, node)
        .trim()
        .trim_start_matches('#')
        .trim()
        .trim_end_matches('#')
        .trim()
        .to_string()
}

fn node_text(source: &[u8], node: tree_sitter::Node) -> String {
    node.utf8_text(source).unwrap_or("").to_string()
}

fn compute_section_hash(source: &[u8], node: tree_sitter::Node) -> Option<String> {
    let section = nearest_section(node).unwrap_or(node);
    let start = section.start_byte();
    let end = section.end_byte();
    if start < end && end <= source.len() {
        Some(hash_bytes(&source[start..end]))
    } else {
        None
    }
}

fn nearest_section(mut node: tree_sitter::Node) -> Option<tree_sitter::Node> {
    while let Some(parent) = node.parent() {
        if parent.kind() == "section" {
            return Some(parent);
        }
        node = parent;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse_source;

    fn extract_from_md(source: &str) -> Vec<RawSymbol> {
        let tree = parse_source(source, "markdown").unwrap();
        let ext = MarkdownExtractor;
        ext.extract_symbols(source.as_bytes(), &tree)
    }

    #[test]
    fn extracts_atx_headings() {
        let source = "# Hello\n\n## Sub\n\ncontent\n";
        let symbols = extract_from_md(source);
        assert_eq!(symbols.len(), 2);
        assert_eq!(symbols[0].name, "Hello");
        assert_eq!(symbols[1].name, "Sub");
    }

    #[test]
    fn headings_are_mod_symbols() {
        let source = "# Guide\n";
        let symbols = extract_from_md(source);
        assert_eq!(symbols[0].kind, SymbolKind::Mod);
        assert_eq!(symbols[0].language, "markdown");
    }

    #[test]
    fn body_hash_is_populated() {
        let source = "# Hello\n\ncontent\n";
        let symbols = extract_from_md(source);
        assert!(symbols[0].body_hash.is_some());
    }

    #[test]
    fn dependencies_are_empty() {
        let source = "# Hello\n\n[link](https://example.invalid)\n";
        let tree = parse_source(source, "markdown").unwrap();
        let ext = MarkdownExtractor;
        assert!(ext
            .extract_dependencies(source.as_bytes(), &tree)
            .is_empty());
    }
}
