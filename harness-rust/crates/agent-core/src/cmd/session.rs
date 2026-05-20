//! Session management subcommands (replaces session.sh).
//!
//! Wired to the library code in `crate::session`.

use std::path::{Path, PathBuf};

use clap::Subcommand;
use shared::error::Result;

use crate::session;

#[derive(Subcommand)]
pub enum SessionAction {
    /// Start a new Claude session.
    Start {
        /// Prompt text to send.
        #[arg(long)]
        prompt: String,
        /// Output file path.
        #[arg(long)]
        output: Option<String>,
        /// Session timeout in seconds.
        #[arg(long, default_value = "1800")]
        timeout: u64,
        /// Repository root path.
        #[arg(long)]
        repo_root: Option<String>,
    },
    /// Start a new Codex session.
    CodexStart {
        /// Path to the prompt file.
        #[arg(long)]
        prompt_file: String,
        /// Path to the output file.
        #[arg(long)]
        output_file: String,
        /// Session timeout in seconds.
        #[arg(long, default_value = "7200")]
        timeout: u64,
        /// Repository root path.
        #[arg(long)]
        repo_root: Option<String>,
    },
    /// Show session info.
    Info,
}

pub fn run(action: SessionAction) -> Result<()> {
    match action {
        SessionAction::Start {
            prompt,
            output,
            timeout,
            repo_root,
        } => {
            let root = resolve_repo_root(repo_root.as_deref())?;
            let output_path = output.as_deref().map(Path::new);
            let session_id = session::session_start(&prompt, output_path, timeout, &root)?;
            println!("{session_id}");
            Ok(())
        }
        SessionAction::CodexStart {
            prompt_file,
            output_file,
            timeout,
            repo_root,
        } => {
            let root = resolve_repo_root(repo_root.as_deref())?;
            let sid = session::codex_session_start(
                Path::new(&prompt_file),
                Path::new(&output_file),
                timeout,
                &root,
            )?;
            match sid {
                Some(id) => println!("{id}"),
                None => eprintln!("Warning: could not retrieve Codex session ID"),
            }
            Ok(())
        }
        SessionAction::Info => {
            let effort = session::resolve_effort_level();
            println!("Effort level: {effort}");
            println!("Session timeout: {}s", session::DEFAULT_SESSION_TIMEOUT);
            Ok(())
        }
    }
}

/// Resolve the repository root from an optional override or git detection.
fn resolve_repo_root(override_path: Option<&str>) -> Result<PathBuf> {
    match override_path {
        Some(p) => Ok(PathBuf::from(p)),
        None => shared::git::git_repo_root(),
    }
}
