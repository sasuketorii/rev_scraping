// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! Phase 2 subcommands: spider / relocate / cf-evaluate.

pub mod auth;
pub mod auth_replay;
pub mod cf_evaluate;
// P6.1: `rev-stealth config {show,paths,validate,diff,get}` inspection surface.
pub mod config_cli;
// P10.5: VPS egress probe (feature-gated, default OFF).
pub mod egress;
pub mod exit;
pub mod fallback_http;
// P7.3: `rev-stealth hermes {install, uninstall, verify}`.
pub mod hermes;
// v1.1.0 (P15): local-only fingerprint measurement subcommand.
pub mod measure;
pub mod recipe_runtime;
pub mod relocate;
pub mod spider;
pub mod vpn_envelope;
