//! # agent-core
//!
//! Agent Base core CLI — Rust replacement for the shell script orchestration
//! layer (`state.sh`, `session.sh`, `coder.sh`, `reviewer.sh`, etc.).
//!
//! Entry point: parses CLI args via `clap` and dispatches to the appropriate
//! command module.

use clap::{Parser, Subcommand};

mod cmd;
mod session;

// ---------------------------------------------------------------------------
// CLI definition
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(
    name = "agent-core",
    version,
    about = "Agent Base core CLI — Rust replacement for shell scripts"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// State management (replaces state.sh)
    State {
        #[command(subcommand)]
        action: cmd::state::StateAction,
    },
    /// Session management (replaces session.sh)
    Session {
        #[command(subcommand)]
        action: cmd::session::SessionAction,
    },
    /// Context analysis (replaces context_analysis.sh)
    Context {
        #[command(subcommand)]
        action: cmd::context::ContextAction,
    },
    /// Capsule generation (replaces context_capsule.sh)
    Capsule {
        #[command(subcommand)]
        action: cmd::capsule::CapsuleAction,
    },
    /// Cache management for verify/review/capsule artifacts
    Cache {
        #[command(subcommand)]
        action: cmd::cache_cmd::CacheAction,
    },
    /// Shadow verification (replaces shadow_verify.sh)
    Verify {
        #[command(subcommand)]
        action: cmd::verify::VerifyAction,
    },
    /// Review execution (replaces reviewer.sh)
    Review {
        #[command(subcommand)]
        action: cmd::review::ReviewAction,
    },
    /// Coder execution (replaces coder.sh)
    Coder {
        #[command(subcommand)]
        action: cmd::coder::CoderAction,
    },
    /// Orchestration (replaces auto_orchestrate.sh)
    Orchestrate {
        #[command(subcommand)]
        action: cmd::orchestrate::OrchestrateAction,
    },
    /// Task contract (replaces task_contract.sh)
    Contract {
        #[command(subcommand)]
        action: cmd::contract::ContractAction,
    },
    /// Handoff envelope rendering and linting
    Envelope {
        #[command(subcommand)]
        action: cmd::envelope::EnvelopeAction,
    },
    /// ExecPlan linting
    Execplan {
        #[command(subcommand)]
        action: cmd::execplan::ExecPlanAction,
    },
    /// Specialty manifest linting and thin skill projection
    Specialty {
        #[command(subcommand)]
        action: cmd::specialty::SpecialtyAction,
    },
    /// Git worktree management (replaces hydra)
    Worktree {
        #[command(subcommand)]
        action: cmd::worktree::WorktreeAction,
    },
    /// Quality gate (replaces quality_gate.sh)
    Gate {
        #[command(subcommand)]
        action: cmd::gate::GateAction,
    },
    /// Project ID management (replaces project-id.sh)
    ProjectId {
        #[command(subcommand)]
        action: cmd::project_id::ProjectIdAction,
    },
    /// Project initialization (replaces init-project.sh)
    Init {
        #[command(subcommand)]
        action: cmd::init::InitAction,
    },
    /// Hook management (replaces codex-review-hook.sh)
    Hook {
        #[command(subcommand)]
        action: cmd::hook::HookAction,
    },
    /// Lease registry validation.
    Lease {
        #[command(subcommand)]
        action: cmd::lease::LeaseAction,
    },
    /// Secret scanning utilities.
    Secret {
        #[command(subcommand)]
        action: cmd::secret::SecretAction,
    },
    /// Semantic MCP administration.
    Semantic {
        #[command(subcommand)]
        action: cmd::semantic::SemanticAction,
    },
    /// Deterministic task stamp generation.
    TaskStamp(cmd::task_stamp::TaskStampArgs),
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn main() {
    shared::logging::init();

    let cli = Cli::parse();

    let result = match cli.command {
        Commands::State { action } => cmd::state::run(action),
        Commands::Session { action } => cmd::session::run(action),
        Commands::Context { action } => cmd::context::run(action),
        Commands::Capsule { action } => cmd::capsule::run(action),
        Commands::Cache { action } => cmd::cache_cmd::run(action),
        Commands::Verify { action } => cmd::verify::run(action),
        Commands::Review { action } => cmd::review::run(action),
        Commands::Coder { action } => cmd::coder::run(action),
        Commands::Orchestrate { action } => cmd::orchestrate::run(action),
        Commands::Contract { action } => cmd::contract::run(action),
        Commands::Envelope { action } => cmd::envelope::run(action),
        Commands::Execplan { action } => cmd::execplan::run(action),
        Commands::Specialty { action } => cmd::specialty::run(action),
        Commands::Worktree { action } => cmd::worktree::run(action),
        Commands::Gate { action } => cmd::gate::run(action),
        Commands::ProjectId { action } => cmd::project_id::run(action),
        Commands::Init { action } => cmd::init::run(action),
        Commands::Hook { action } => cmd::hook::run(action),
        Commands::Lease { action } => cmd::lease::run(action),
        Commands::Secret { action } => match cmd::secret::run(action) {
            Ok(code) => std::process::exit(code),
            Err(error) => {
                eprintln!("[ERROR] {error}");
                std::process::exit(2);
            }
        },
        Commands::Semantic { action } => match cmd::semantic::run(action) {
            Ok(code) => std::process::exit(code),
            Err(error) => Err(error),
        },
        Commands::TaskStamp(args) => cmd::task_stamp::run(args),
    };

    if let Err(e) = result {
        eprintln!("[ERROR] {e}");
        std::process::exit(1);
    }
}
