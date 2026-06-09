//! Command modules for each `agent-core` subcommand.
//!
//! Only `state` and `session` are fully implemented in Wave 1.
//! All others are stubs that print a TODO message.

pub mod session;
pub mod state;
pub mod task_stamp;

// Stub modules — will be fleshed out in later waves.
pub mod cache_cmd;
pub mod capsule;
pub mod coder;
pub mod context;
pub mod contract;
pub mod envelope;
pub mod execplan;
pub mod gate;
pub mod hook;
pub mod index_all;
pub mod index_commit;
pub mod init;
pub mod lease;
pub mod migrate_paths;
pub mod orchestrate;
pub mod project_id;
pub mod review;
pub mod secret;
pub mod secret_scan;
pub mod semantic;
pub mod specialty;
#[cfg(test)]
pub(crate) mod test_support;
pub mod verify;
pub mod worktree;
