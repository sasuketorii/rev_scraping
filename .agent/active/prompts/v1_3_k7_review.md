# Lane K.7 reviewer prompt (Codex)

You are the v1.3 Lane K.7 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.7):

> criterion benchmarks on 5 hot paths (sanitize walk / canary scan /
> AAD encrypt-decrypt / MCP dispatch / recipe load) + per-PR diff via
> bencher.dev. Acceptance: regression > 10% triggers PR comment + label.

Artifacts (this fix-up driver delivered):
- crates/stealth-sanitize/benches/sanitize_hotpath.rs  (sanitize_walk + canary_scan; already in)
- crates/stealth-auth/benches/aead_hotpath.rs         (encrypt + decrypt; NEW)
- crates/stealth-mcp/benches/dispatch_hotpath.rs      (ping/initialize/tools_list; NEW)
- crates/stealth-sites/benches/recipe_load_hotpath.rs (10/100/1000 scaling; NEW)
- .github/workflows/bench.yml (PR diff workflow if present)

Local verification:
- cargo bench -p stealth-auth   --bench aead_hotpath        --no-run → BUILD OK
- cargo bench -p stealth-mcp    --bench dispatch_hotpath    --no-run → BUILD OK
- cargo bench -p stealth-sites  --bench recipe_load_hotpath --no-run → BUILD OK

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main
- Note scope adjustment: recipe_load bench lives in stealth-sites (where
  SiteRecipeStore lives), not stealth-mcp. dispatch_hotpath measures the
  in-process methods (ping/initialize/tools_list); tools/call requires
  subprocess fan-out and is excluded from microbench.

Verify:
1. 5 hot paths benched: sanitize_walk, canary_scan, aead encrypt+decrypt
   counts as 2, mcp dispatch (3 methods), recipe_load (scaling).
2. Each bench compiles (--no-run).
3. bencher.dev integration: present, or documented as v1.3 partial.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
