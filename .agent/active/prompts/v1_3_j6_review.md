# Lane J.6 reviewer prompt (Codex)

You are the v1.3 Lane J.6 reviewer. Verify the acceptance criteria from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane J.6) against the
artifacts listed below. Return LGTM | CHANGES (with bullet diffs).

Acceptance summary by sub-phase:
- J.1: docs/book/ scaffold builds; EN+JA toggle reachable; .github/workflows/docs.yml deploys on tag.
- J.2: 7 tutorial pages under docs/book/src/en/tutorial/; each has runnable code + smoke test.
- J.3: 16 tool cookbook pages under docs/book/src/en/tools/; each shows happy path + 1 error variant + outputSchema link.
- J.4: 2 migration pages (Crawl4AI, Playwright MCP) with side-by-side examples.
- J.5: rustdoc workflow + #![warn(missing_docs)] staged on stealth-agent-contracts only (warning, not deny); rollout note present.
- J.6: 26 ErrorKind pages under docs/book/src/en/errors/; each has ErrorEnvelope shape + reproduction + fix path + root causes.
- J.7: docs/landscape.md present with Q3-2026 timestamp + quarterly refresh checklist + ≥1 losing cell per row.

Artifacts:
- docs/book/book.toml
- docs/book/src/SUMMARY.md, intro.md
- docs/book/src/en/ (README, install, landscape, compat, tutorial/, tools/, migration/, errors/)
- docs/book/src/ja/ (README, install, tutorial, tools, migration, errors)
- .github/workflows/docs.yml
- crates/stealth-agent-contracts/src/lib.rs (warn missing_docs added)
- docs/landscape.md

Local verification commands used:
- cd docs/book && mdbook build      → PASS
- cd docs/book && mdbook test       → PASS (all chapters)

Constraints:
- prompt ≤ 2 KB / max 3 round
- raw codex exec 禁止 (this prompt is invoked via canonical wrapper)
- No Write/Edit; report findings as text only.

Focus J.6 only. Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
