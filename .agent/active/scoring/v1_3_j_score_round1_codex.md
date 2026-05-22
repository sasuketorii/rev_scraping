# v1.3 Lane J scoring (Codex)

ExecPlan: .agent/active/v1_3_uplift_execplan_rev1.md (Lane J).
Rubric: .agent/active/v1_3_quality_bar.md, axes A-G with weights {A:2.0, B:1.5, C:1.5, D:2.0, E:1.0, F:1.0, G:1.0}; Lane J D-axis特化 = "tutorial/05-claude-code.md 5分で動く" + "26 ErrorKind 全て個別解説".
Lane review rounds: .agent/active/reviews/v1_3_j_lane_review_round{1,2,3}.out.

Final state:
- mdbook build + mdbook test PASS.
- 7 tutorial pages with runnable code + smoke tests.
- 16 tool cookbook pages; all 16 success Response examples validate against docs/json-schemas/*.output.json (Draft-07, verified with jsonschema).
- 26 ErrorKind pages (1:1 with enum); snake_case wire `kind` + retryable field per all_error_kind_docs().
- 2 migration pages (Crawl4AI, Playwright MCP) side-by-side; schema-accurate args.
- docs/landscape.md authoritative + docs/book/src/en/landscape.md byte-identical; 8 competitors incl. Puppeteer + Scrapling; ≥1 losing-cell-per-row invariant; Q3-2026 timestamp + quarterly checklist.
- .github/workflows/docs.yml mdBook + rustdoc(--document-private-items, best-effort) → GH Pages; one-time Settings→Pages enable documented inline.

Operator-approved descopes: mdbook-i18n-helpers PO i18n → v1.4 Lane O (EN+JA parallel trees + visible toggle in v1.3); gen_reference fragment-gen descoped; warn(missing_docs) on stealth-sanitize deferred (Lane K).

Score each axis 0-10 with 1-3 line rationale. Return:
| 軸 | スコア | 根拠 |
overall = X.XX (weighted)
verdict: PASS (≥9.0) | FAIL (<9.0)
deltas to reach 9.0 if FAIL: bullets.
Text only.
