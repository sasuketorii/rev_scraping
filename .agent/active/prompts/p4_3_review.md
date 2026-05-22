# Review P4.3 ErrorEnvelope wiring 26 variants

files:
- crates/stealth-agent-contracts/src/error.rs (+15 variants → 26 closed; +3 tests)
- crates/stealth-mcp/Cargo.toml (+stealth-agent-contracts dep)
- crates/stealth-mcp/src/auth_tools.rs (+AuthToolError::to_envelope)
- crates/stealth-mcp/src/recipe_tools.rs (+RecipeError::to_envelope)
- crates/stealth-mcp/src/server.rs (+envelope_response; dispatch error paths now emit ErrorEnvelope under structuredContent.error + isError=true; +4 tests)

gates PASS:
- cargo test -p stealth-agent-contracts: 27 PASS
- cargo test -p stealth-mcp: 61 PASS (+6 vs baseline)
- cargo test --workspace: 640 PASS / 0 FAIL (baseline 630)
- cargo clippy --workspace --all-targets -- -D warnings: clean
- SPDX preserved; diff scoped to contracts + mcp only

verify:
1. ErrorKind = exactly 26 closed variants, no #[non_exhaustive]. Test error_kind_has_exactly_26_variants enforces arity + dedup.
2. All 26 round-trip serde. Wire = snake_case (P1 contract preserved; task spec said kebab-case but P1 shipped snake_case — kept to avoid breaking the 11 P1 wire names).
3. tool dispatch in-process errors return ErrorEnvelope JSON under result.structuredContent.error with isError=true. Raw format!("error: {e}") paths replaced.
4. AUP reject (auth_login_start unauthorized) → ErrorKind::Aup; recipe_show missing → ErrorKind::RecipeNotFound.
5. auth_login_complete timeout → ErrorKind::AuthSessionExpired with retryable=true, retry_after_ms=Some(1000).
6. P1 11-variant tests preserved; P4.1 inputSchema + P4.2 outputSchema tests unaffected.
7. MissingField still maps to JSON-RPC INVALID_PARAMS (transport-level), not envelope — preserves existing caller contract.
8. No secret leakage: message carries only pre-formatted Display from existing error types.

return: verdict: LGTM or BLOCK: <reason>
