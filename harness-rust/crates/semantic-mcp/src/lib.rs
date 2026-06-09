//! semantic-mcp library entrypoint. The binary is a thin wrapper.

pub mod admin_gc;
pub mod capsule;
pub mod clock;
pub mod context;
pub mod context_top_k;
pub mod db;
pub mod health;
pub mod main_loop;
pub mod preflight;
pub mod protocol;
pub mod registry;
pub mod review_queue;
pub mod search;
pub mod symbols_search;
pub mod tools;
pub mod util;

#[cfg(test)]
pub(crate) mod test_env;

pub use clock::{Clock, SystemClock};
pub use context::ServerContext;
