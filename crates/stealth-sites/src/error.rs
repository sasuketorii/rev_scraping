// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)

use std::path::PathBuf;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, SitesError>;

#[derive(Debug, Error)]
pub enum SitesError {
    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("toml deserialize error: {0}")]
    TomlDe(#[from] toml::de::Error),

    #[error("toml serialize error: {0}")]
    TomlSer(#[from] toml::ser::Error),

    #[error("invalid domain: {0}")]
    InvalidDomain(String),

    #[error("forbidden secret-like value rejected (field hint: {0})")]
    SecretRejected(String),

    #[error("missing url template parameter: {0}")]
    MissingParam(String),

    #[error("invalid url after substitution: {0}")]
    InvalidUrl(String),
}
