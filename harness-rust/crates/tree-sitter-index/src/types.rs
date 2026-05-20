//! Core domain types for tree-sitter based symbol indexing.
//!
//! These types represent symbols extracted from source code, their
//! dependencies, and the results of indexing and impact analysis.

use std::fmt;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Symbol
// ---------------------------------------------------------------------------

/// A symbol extracted from source code and stored in the database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Symbol {
    /// Database row ID (populated after insertion).
    pub id: Option<i64>,
    /// Path to the source file containing this symbol.
    pub file_path: String,
    /// SHA-256 hash of the source file content.
    pub file_hash: String,
    /// Simple name of the symbol (e.g. `"my_function"`).
    pub name: String,
    /// Fully qualified name including module path (e.g. `"crate::mod::my_function"`).
    pub qualified_name: Option<String>,
    /// What kind of symbol this is.
    pub kind: SymbolKind,
    /// Source language identifier (e.g. `"rust"`, `"typescript"`).
    pub language: String,
    /// 1-based starting line number.
    pub start_line: u32,
    /// 1-based ending line number.
    pub end_line: u32,
    /// 0-based starting column.
    pub start_col: u32,
    /// 0-based ending column.
    pub end_col: u32,
    /// Function/method signature text.
    pub signature: Option<String>,
    /// Visibility modifier (e.g. `"pub"`, `"pub(crate)"`).
    pub visibility: Option<String>,
    /// Database ID of the parent symbol (e.g. impl block for a method).
    pub parent_symbol_id: Option<i64>,
    /// SHA-256 hash of the symbol body for change detection.
    pub body_hash: Option<String>,
}

// ---------------------------------------------------------------------------
// SymbolKind
// ---------------------------------------------------------------------------

/// Classification of a source code symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    /// A standalone function.
    Function,
    /// A class definition.
    Class,
    /// A struct definition.
    Struct,
    /// An enum definition.
    Enum,
    /// A method within an impl/class.
    Method,
    /// An import/use declaration.
    Import,
    /// An export declaration.
    Export,
    /// A type alias.
    Type,
    /// An interface definition.
    Interface,
    /// A constant binding.
    Const,
    /// A module declaration.
    Mod,
    /// A trait definition.
    Trait,
    /// An impl block.
    Impl,
}

impl fmt::Display for SymbolKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Function => write!(f, "function"),
            Self::Class => write!(f, "class"),
            Self::Struct => write!(f, "struct"),
            Self::Enum => write!(f, "enum"),
            Self::Method => write!(f, "method"),
            Self::Import => write!(f, "import"),
            Self::Export => write!(f, "export"),
            Self::Type => write!(f, "type"),
            Self::Interface => write!(f, "interface"),
            Self::Const => write!(f, "const"),
            Self::Mod => write!(f, "mod"),
            Self::Trait => write!(f, "trait"),
            Self::Impl => write!(f, "impl"),
        }
    }
}

impl std::str::FromStr for SymbolKind {
    type Err = String;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "function" => Ok(Self::Function),
            "class" => Ok(Self::Class),
            "struct" => Ok(Self::Struct),
            "enum" => Ok(Self::Enum),
            "method" => Ok(Self::Method),
            "import" => Ok(Self::Import),
            "export" => Ok(Self::Export),
            "type" => Ok(Self::Type),
            "interface" => Ok(Self::Interface),
            "const" => Ok(Self::Const),
            "mod" => Ok(Self::Mod),
            "trait" => Ok(Self::Trait),
            "impl" => Ok(Self::Impl),
            other => Err(format!("unknown symbol kind: {other}")),
        }
    }
}

// ---------------------------------------------------------------------------
// RawSymbol
// ---------------------------------------------------------------------------

/// A symbol extracted from a parse tree, before database insertion.
///
/// Unlike [`Symbol`], this does not have a database ID or file-level metadata.
/// It may contain nested children (e.g. methods inside an impl block).
#[derive(Debug, Clone)]
pub struct RawSymbol {
    /// Simple name of the symbol.
    pub name: String,
    /// Fully qualified name including module path.
    pub qualified_name: Option<String>,
    /// What kind of symbol this is.
    pub kind: SymbolKind,
    /// Source language identifier.
    pub language: String,
    /// 1-based starting line number.
    pub start_line: u32,
    /// 1-based ending line number.
    pub end_line: u32,
    /// 0-based starting column.
    pub start_col: u32,
    /// 0-based ending column.
    pub end_col: u32,
    /// Function/method signature text.
    pub signature: Option<String>,
    /// Visibility modifier.
    pub visibility: Option<String>,
    /// SHA-256 hash of the symbol body.
    pub body_hash: Option<String>,
    /// Nested child symbols (e.g. methods in an impl block).
    pub children: Vec<RawSymbol>,
}

// ---------------------------------------------------------------------------
// SymbolDependency
// ---------------------------------------------------------------------------

/// A dependency relationship between two symbols.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolDependency {
    /// Database ID of the symbol that depends on another.
    pub from_symbol_id: i64,
    /// Database ID of the depended-upon symbol (may be `None` if unresolved).
    pub to_symbol_id: Option<i64>,
    /// Name of the depended-upon symbol.
    pub to_name: String,
    /// What kind of dependency this is.
    pub kind: DependencyKind,
}

// ---------------------------------------------------------------------------
// DependencyKind
// ---------------------------------------------------------------------------

/// Classification of a dependency between symbols.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyKind {
    /// Function/method call.
    Calls,
    /// Import/use statement.
    Imports,
    /// Class/struct inheritance.
    Extends,
    /// Trait/interface implementation.
    Implements,
    /// Type reference in signature or body.
    UsesType,
}

impl fmt::Display for DependencyKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Calls => write!(f, "calls"),
            Self::Imports => write!(f, "imports"),
            Self::Extends => write!(f, "extends"),
            Self::Implements => write!(f, "implements"),
            Self::UsesType => write!(f, "uses_type"),
        }
    }
}

impl std::str::FromStr for DependencyKind {
    type Err = String;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "calls" => Ok(Self::Calls),
            "imports" => Ok(Self::Imports),
            "extends" => Ok(Self::Extends),
            "implements" => Ok(Self::Implements),
            "uses_type" => Ok(Self::UsesType),
            other => Err(format!("unknown dependency kind: {other}")),
        }
    }
}

// ---------------------------------------------------------------------------
// ImpactReport
// ---------------------------------------------------------------------------

/// Result of an impact analysis showing which symbols and files are affected
/// by changes to a set of source files.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImpactReport {
    /// Symbols that were directly changed (in the changed files).
    pub changed_symbols: Vec<Symbol>,
    /// Symbols affected transitively via dependency edges.
    pub affected_symbols: Vec<Symbol>,
    /// Unique file paths containing affected symbols.
    pub affected_files: Vec<String>,
    /// Maximum BFS depth reached during traversal.
    pub depth: u32,
    /// Whether the symbols table had any data to analyze.
    pub populated: bool,
    /// Files that failed to parse during indexing.
    pub parse_failed_files: Vec<String>,
    /// Count of symbol name matches that were ambiguous (same name, multiple files).
    pub ambiguous_matches: u32,
    /// Whether the analysis was truncated due to `max_nodes` cutoff.
    pub truncated: bool,
}

// ---------------------------------------------------------------------------
// IndexResult
// ---------------------------------------------------------------------------

/// Summary statistics from an indexing run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexResult {
    /// Number of files successfully parsed and indexed.
    pub files_parsed: usize,
    /// Number of files skipped (cached, too large, binary).
    pub files_skipped: usize,
    /// Number of files that failed to parse.
    pub parse_failures: usize,
    /// Total number of symbols extracted.
    pub symbols_extracted: usize,
    /// Total number of dependencies extracted.
    pub dependencies_extracted: usize,
    /// Wall-clock duration in milliseconds.
    pub total_duration_ms: u64,
}

// ---------------------------------------------------------------------------
// IndexConfig
// ---------------------------------------------------------------------------

/// Configuration for the indexing process.
#[derive(Debug, Clone)]
pub struct IndexConfig {
    /// Maximum file size in bytes; larger files are skipped.
    pub max_file_size: u64,
    /// Fraction of files that may fail parsing before aborting (0.0 to 1.0).
    pub parse_failure_threshold: f64,
    /// Glob patterns for files to exclude from indexing.
    pub exclude_patterns: Vec<String>,
}

impl Default for IndexConfig {
    fn default() -> Self {
        Self {
            max_file_size: 102_400,
            parse_failure_threshold: 0.05,
            exclude_patterns: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symbol_kind_display_roundtrip() {
        assert_eq!(SymbolKind::Function.to_string(), "function");
        assert_eq!(SymbolKind::Struct.to_string(), "struct");
        assert_eq!(SymbolKind::Impl.to_string(), "impl");
        assert_eq!("function".parse::<SymbolKind>(), Ok(SymbolKind::Function));
        assert!("unknown".parse::<SymbolKind>().is_err());
    }

    #[test]
    fn dependency_kind_display_roundtrip() {
        assert_eq!(DependencyKind::Calls.to_string(), "calls");
        assert_eq!(DependencyKind::UsesType.to_string(), "uses_type");
        assert_eq!(
            "imports".parse::<DependencyKind>(),
            Ok(DependencyKind::Imports)
        );
        assert!("unknown".parse::<DependencyKind>().is_err());
    }

    #[test]
    fn index_config_defaults() {
        let cfg = IndexConfig::default();
        assert_eq!(cfg.max_file_size, 102_400);
        assert!((cfg.parse_failure_threshold - 0.05).abs() < f64::EPSILON);
        assert!(cfg.exclude_patterns.is_empty());
    }
}
