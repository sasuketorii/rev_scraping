# Phase 9 hotfix-1 follow-ups

Created: 2026-05-14.

## Context

Hotfix-1 rewired `rev-auth` interactive cookie capture from `obscura-bridge`
(headless-only) to a direct `chromiumoxide` launch of system Chrome. Obscura
remains the backend for scrape paths (spider / cf-evaluate).

## TODOs (target: v1.2)

1. Remove the dead `ObscuraConfig::headless` field
   (`crates/obscura-bridge/src/config.rs`). It is currently a no-op because
   the launcher never forwards it to the obscura subprocess. Audit
   spider/cf-evaluate call sites first; replace `headless: false` literals
   with a no-op constructor or simply drop the assignment.

2. Drop the deprecated `--obscura-bin` / `REV_OBSCURA_BIN` flag from
   `rev-auth` once external wrappers are updated. The flag currently only
   emits a warning; flag removal needs an MCP / `rev-stealth` wrapper bump.

3. Consider migrating spider/cf-evaluate to a parametrised browser-backend
   trait if/when obscura grows a true headed mode, instead of carrying the
   dead `headless` field.

4. Add an integration test that runs `rev-auth login` end-to-end against a
   local stub HTTP server and validates that a real Chrome window is
   spawned (gated by `REV_AUTH_RUN_HEADED_E2E=1`). The `#[ignore]`d unit
   test added in hotfix-1 covers the launch path but not the full subprocess.
