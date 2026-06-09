# Decision Memo: toRust-Idea adoption

Date: 2026-04-17

## 1. Decision summary

Verdict: `toRust-Idea` は現状のまま適用しない。先に修正し、その後に段階導入のみ許可する。

Decision:
- Do not apply as-is.
- Modify first.
- Staged adoption only.
- Treat `toRust-Idea/RESULT.md` and `toRust-Idea/REVIEW_FINAL_LGTM.md` as historical progress/review artifacts after truth correction, not current acceptance proof.

Rationale:
- Rust workspace 自体は部分的に成立しているが、proposal/result 側の完了表現と実装・統合の実態が一致していない。
- 現時点では全面置換の acceptance / LGTM / completion を主張できる状態ではない。

## 2. Evidence snapshot

Local recheck on 2026-04-17:

| Command | Result | Note |
|---|---|---|
| `cargo test --manifest-path toRust-Idea/rust/Cargo.toml --workspace --quiet` | PASS | current verified local recheck passed |
| `cargo build --manifest-path toRust-Idea/rust/Cargo.toml -p agent-core` | PASS | `agent-core` build passed |
| `cargo test --manifest-path toRust-Idea/rust/Cargo.toml -p tree-sitter-index --features all-languages` | FAIL | `extractors::shell::tests::handles_syntax_errors_gracefully` |

Implication:
- `agent-core` build failure is not the blocker.
- The blocker is decision quality: overstated readiness, direct failing test evidence, and incomplete cutover readiness.

## 3. Why not apply as-is

### Primary blockers

#### A. Completion / LGTM is overstated

- `toRust-Idea/RESULT.md` states broad completion and LGTM acquisition.
- `toRust-Idea/REVIEW_FINAL_LGTM.md` states crate-wide and overall LGTM.
- Those claims are too strong for adoption judgment because required integration, acceptance evidence, and staged rollout boundaries are not complete.

#### B. Test evidence is not sufficient for as-is adoption

- `agent-core` build passes, but that does not establish cutover readiness.
- `tree-sitter-index` still has a direct failing test under `--features all-languages`.

#### C. Fail-open behavior remains on acceptance-critical paths

Reviewer themes remain material in:

- `toRust-Idea/rust/crates/agent-core/src/cmd/orchestrate.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/verify.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/review.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/gate.rs`

Current patterns still degrade or continue on cache/init/check failures, skipped tools, or partial review/verify outcomes. That is not sufficient for replacing current fail-closed acceptance surfaces.

#### D. Cutover readiness is still incomplete in the proposal set

- `toRust-Idea/RESULT.md` still lists remaining work for integration tests, Shell to Rust bridge/cutover, MCP server switch, benchmarks, and release pipeline work.
- Phase 4-related implementation hooks exist for verify cache, review cache, context index-symbols/file-index update, and orchestrate cache/symbol/capsule flow.
- However, reviewers found fail-open behavior, stale review reuse risk, and acceptance evidence/docs mismatch.

Therefore the correct status is: `wired in code but not acceptance-ready`.

### Additional adoption concerns

#### E. Native-layout / `src/` assumptions remain

The repo operating model explicitly allows project-native layouts and does not require rehousing into `src/`.

- `toRust-Idea/rust/crates/agent-core/src/cmd/context.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/verify.rs`
- `.agent/PROJECT_CONTEXT.md`

`src/`-centric assumptions still remain in indexing, heuristics, and examples. Applying as-is risks mismatch with the actual harness distribution model.

#### F. Wrapper/runtime truth boundary must be preserved

`AGENTS.md` and `docs/manual/verification-truth-matrix.md` separate runtime truth from acceptance truth.

- Wrapper contracts are caller-facing runtime policy.
- Acceptance / completion / LGTM require deterministic checks and traceable evidence.

Any migration that blurs that boundary is not ready for blanket adoption.

#### G. Semantic path/trust handling still needs adoption scrutiny

- Reviewer evidence also pointed to path normalization / trust concerns in semantic surfaces.
- These are additional repo-adoption concerns, not the core blocker set for this memo.

#### H. Follow-up check on possible workspace-test flake

- A reviewer previously reported a rerun failure around `session::tests::test_resolve_effort_level_default`.
- That report is not currently backed by a traceable artifact in this memo's evidence set.
- Treat it as a potential flake / follow-up rerun target, not a primary blocker.

#### I. Performance / ROI claims are not benchmark-backed

- Size reduction and dependency reduction are observable.
- Performance and ROI claims for adoption order are still not backed by current benchmark artifacts.
- Proposal docs themselves still list benchmark work as remaining.

Therefore performance upside is directional, not yet decision-grade proof for full replacement.

## 4. Required modifications before any adoption

1. Narrow the status language in `RESULT.md` and `REVIEW_FINAL_LGTM.md` so they read as historical progress/review records and do not imply repo-wide completion, valid final LGTM, or full replacement readiness.
2. Stabilize workspace test evidence and close the known failing `tree-sitter-index` test for `extractors::shell::tests::handles_syntax_errors_gracefully`.
3. Convert fail-open behavior in orchestrate / verify / review / gate to the intended fail-closed boundary for acceptance-critical paths, or explicitly scope those paths as non-authoritative.
4. Resolve stale review reuse risk and align cache/review behavior with acceptance expectations.
5. Reframe Phase 4/cutover status as wired-but-not-acceptance-ready until deterministic rerun evidence is captured.
6. Remove or generalize `src/`-only assumptions so project-native layouts remain first-class.
7. Preserve the wrapper/runtime-truth vs acceptance-truth split exactly as defined in `AGENTS.md` and `docs/manual/verification-truth-matrix.md`.
8. Add benchmark artifacts for the specific claims used to justify migration order or replacement ROI.
9. Reframe adoption scope as bridge-first, with explicit rollback and coexistence boundaries.

## 5. Recommended next slices

Order:

1. Fix the failing `tree-sitter-index` shell extractor test and re-run the targeted crate tests.
2. Re-run workspace tests until deterministic evidence is captured for the previously conflicting result.
3. Harden orchestrate / verify / review / gate so acceptance-critical paths do not continue fail-open.
4. Fix review-cache reuse semantics and validate invalidation on prompt / head changes.
5. Rewrite proposal/result closeout language so readiness claims match actual deterministic evidence and remain explicit about `partial parity`.
6. Remove `src/`-biased assumptions from context / verify paths and validate against project-native layouts.
7. Only then run a bridge-based pilot slice, not a full Shell/TS replacement.

## 6. Appendix: key evidence sources

- `toRust-Idea/RESULT.md`
- `toRust-Idea/REVIEW_FINAL_LGTM.md`
- `toRust-Idea/rust/crates/agent-core/src/cmd/orchestrate.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/verify.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/review.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/gate.rs`
- `toRust-Idea/rust/crates/agent-core/src/cmd/context.rs`
- `toRust-Idea/rust/crates/semantic-mcp/src/util.rs`
- `AGENTS.md`
- `.agent/PROJECT_CONTEXT.md`
- `docs/manual/verification-truth-matrix.md`
