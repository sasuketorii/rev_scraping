# Plan A — Opus 4.7-xhigh v1.3 Uplift draft (raw)

> Saved evidence for the v1.3 ExecPlan synthesis.
> Original prompt: `/tmp/v13_uplift_prompt_base.md`
> Counterpart: `v1_3_plan_b_codex_raw.md`

(Full text returned by Opus agent a439a48582e6f1239. Synthesized version used in
`v1_3_uplift_execplan_rev1.md`. The complete Opus message is preserved here for
audit and future reference.)

## Executive summary

- Recommends 2-stage release: v1.3 (Lane H+I+J — deploy / stealth / quality)
  + v1.4 (Lane G + Lane K — crypto / docs).
- Sub-phase count: 72 across 5 axes / lanes.
- dev-day estimate: optimistic 36 / realistic **54.5** / pessimistic 75.
- For solo developer at ~25 h/week → 11 work-weeks total (split as 2-3 mo + 1.5-2 mo).

## Key axis-by-axis numbers (per Opus realistic estimate)

| Axis | Lane | dev-day (realistic) | Sub-phases |
|------|------|---------------------|------------|
| 1 Crypto | G | 10 | 12 |
| 2 Deploy | H | 12.5 | 16 |
| 3 Stealth | I | 13 | 15 |
| 4 Quality | J | 10.5 | 18 |
| 5 Docs | K | 8.5 | 11 |

## 9/10 criteria framework (Plan A)

Each criterion must satisfy ≥ 2 of:
1. External verifiable (third-party tool / fixture / public benchmark)
2. CI gating (regression caught at PR level)
3. Adversarial test (assumes attacker / detector)

## Recommendation (Plan A)

> Adopt case B: v1.3 = Lane H+I+J (deploy + stealth + quality), v1.4 = Lane G+K (crypto + docs).

Rationale: Lane I (TLS/H2/H3 stealth via boring-sys) is the largest novelty.
Lane G (TPM2/FIDO2) needs external cryptographer review (2-4 week lead time),
better separated. Lane K docs should follow feature delta, not precede it.

## Stealth (axis 3) detail (Plan A primary novelty)

- Primary: `boring-sys` (Cloudflare-maintained BoringSSL Rust bindings)
- Fallback / bench: `curl-impersonate` Rust wrapper
- Targets:
  - CreepJS Trust Score ≥ 70
  - bot.sannysoft.com all 24 PASS
  - tls.peet.ws JA4 = Chrome stable
  - Cloudflare managed challenge passage ≥ 80% (free / BFM tier)
  - DataDome the-bot-tester passage ≥ 50%
- SLO: "lasts at least 90 days between Chrome stable releases"

## Arms-race defense (Plan A objection rebuttal §8.3)

1. "Win = forcing detector cost up, not 100% bypass."
2. Track Chrome stable, target 90-day durability.
3. boring-sys is Cloudflare-published — evidence that Cloudflare itself
   accepts JA4 alone is insufficient for bot detection.
4. Honesty boundary: Cloudflare Enterprise Bot Mgmt = out of ROI; Free + BFM =
   in scope.

## Synthesis note

The pivoted user direction "CLI authority for AI agent devs / CLI UX black-belt
in v1.3" reorders this plan: Lane I (stealth) and Lane G (crypto) are deferred
to v1.4. Lane H (deploy / packaging) and Lane J (quality) remain. A NEW Lane G
"CLI UX black-belt" is inserted that neither Plan A nor Plan B contained.

See `v1_3_uplift_execplan_rev1.md` for the user-pivot synthesized plan that
governs v1.3 implementation.
