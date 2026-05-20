//! Secret scanning commands.

use clap::Subcommand;

use shared::Result;

use super::secret_scan::{run_scan_cli, ScanArgs};

#[derive(Subcommand, Debug)]
pub enum SecretAction {
    /// Scan staged content, a ref range, or specific files for secrets.
    Scan(ScanArgs),
}

pub fn run(action: SecretAction) -> Result<i32> {
    match action {
        SecretAction::Scan(args) => run_scan_cli(args),
    }
}
