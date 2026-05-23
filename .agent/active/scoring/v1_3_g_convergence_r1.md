# Lane G — Dual Scoring Convergence Record (round 1)

| Scorer | Round | Overall | Verdict |
|--------|-------|---------|---------|
| Opus 4.7-xhigh | R1 | 9.23 | PASS |
| Codex gpt-5.5-xhigh | R1 | 8.78 | FAIL (gap 0.45 < tolerance 1.5、split) |

**Lane G R1: SPLIT (Opus PASS / Codex FAIL)** — User mandate「両者 ≥ 9.0」未達。Codex 寄りの fix-up driver dispatch、R2 で両者 ≥ 9.0 目標。

## Integrated deltas (Codex primary)
1. --output-format text + yaml を全 11 sub-command で受理(or human/json 公式化と ExecPlan amendment)
2. G.6 proptest 50-iter (idempotent invariant): 同 key + 同 payload → 同 envelope / 異 payload → 新 envelope
3. G.6 auth login --idempotency-key X 二重実行で audit log entry 不増、duplicate side effect 抑制を直接検証
4. G.1 cli-surface inventory 再生成 drift gate を CI 化 (`scripts/cli_surface_inventory.py --check`)
5. (low) committed target/man/* + target/completions/* の "drift gate target" justification を .gitignore コメントで明文化(legacy "build artifact in git" 負債への honest disclosure)
