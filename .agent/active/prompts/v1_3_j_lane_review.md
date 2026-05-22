# Lane J combined reviewer (Codex)

v1.3 ExecPlan: .agent/active/v1_3_uplift_execplan_rev1.md (Lane J).
Quality bar: .agent/active/v1_3_quality_bar.md.

Acceptance (condensed):
- J.1: docs/book/ mdbook builds; SUMMARY.md links EN+JA trees; .github/workflows/docs.yml deploys to GH Pages on tag.
- J.2: 7 tutorial pages docs/book/src/en/tutorial/{01..07}-*.md, each runnable + smoke test.
- J.3: 16 cookbook pages docs/book/src/en/tools/*.md (matches 16 tools in crates/stealth-mcp/src/tools.rs); each: happy-path JSON-RPC + 1 ErrorEnvelope + outputSchema link.
- J.4: docs/book/src/en/migration/{from-crawl4ai,from-playwright}.md side-by-side.
- J.5: docs.yml runs `cargo doc`; #![warn(missing_docs)] applied to crates/stealth-agent-contracts/src/lib.rs only with staged-rollout note.
- J.6: 26 pages docs/book/src/en/errors/<Variant>.md (matches 26 variants in crates/stealth-agent-contracts/src/error.rs); each has shape+repro+fix+root-causes.
- J.7: docs/landscape.md Q3-2026 timestamp + quarterly checklist + ≥1 losing cell per row.

Local verification:
- mdbook build  → PASS
- mdbook test   → PASS

Scope adjustments (operator-approved):
- J.3 gen_reference extension descoped (curated content for 16 small pages preferred over library API churn).
- J.5 warn(missing_docs) on stealth-sanitize deferred (unstaged Lane K changes in tree).
- J.1 mdbook-i18n-helpers PO i18n deferred to v1.4 Lane O.

Return per sub-phase verdict (LGTM/CHANGES) with ≤3 bullet deltas if CHANGES. Text-only.
