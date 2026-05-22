# Review v1.3 I.5 (Round 2)

R1 BLOCK addressed:

1. **Live-vs-committed-snapshot was tautological.** Once a contributor regenerates `.agent/v1.3/cli-public-api.snapshot.json` in the PR, live always equals committed — a removal was invisible. Rewrote the script to compare against the BASE branch's snapshot via `git show "$BASE_REF:$SNAPSHOT_PATH"`. `BASE_REF` defaults to `origin/main`; CI sets it from `github.event.pull_request.base.ref`.

2. **CI not base-aware.** Updated job: `fetch-depth: 0` on checkout, `git fetch --no-tags --depth=200 origin "$BASE_REF"` before the diff, BASE_REF env passed to script.

3. **Fallbacks.** Base snapshot unreachable ⇒ fall back to `HEAD~1` (stderr note). Neither reachable (first PR introducing snapshot, or shallow checkout) ⇒ exit 0 with explicit note. No spurious blocking on first-introduction.

## Files touched (delta)
- `scripts/mcp-schema-breaking.sh` — full rewrite around base-branch diff.
- `.github/workflows/ci.yml` — mcp-schema-breaking-detector updated.

## Gates PASS
- `./scripts/mcp-schema-breaking.sh --check` → exit 0 with documented "no base reachable" note on this branch (snapshot is new; no base yet).
- Tool surface unchanged (16 tools).

## Verify (3)
1. Comparison is BASE branch snapshot, not the PR's own. Removing a tool + regenerating snapshot in same PR ⇒ exit 1 ⇒ `mcp-schema-breaking` label required.
2. Adding a tool + regenerating ⇒ exit 0 + informational additive note ⇒ `api-additive` label suffices.
3. First-introduction case handled with note + exit 0.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
