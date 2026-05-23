# Lane G Codex scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 8.6 | G.4 --output-format human/json のみ多数で text/yaml 拒否 + G.6 proptest 50-iter 不在 + G.1 drift gate 弱 |
| B | 9.0 | help/schema/completion/manpage/dry-run/error の CI gate 揃う、text/yaml drift + G.6 proptest 不在で減点 |
| C | 8.5 | dry-run/idempotency/error doc_url で ripgrep より agent-friendly、enum/envelope 揃わず明確勝ち未 |
| D | 9.0 | Claude/Cursor/Hermes pipe-able、text/yaml 不一致 + flat/独自 envelope の存在で reject 要因 |
| E | 8.6 | clap 安定、mixed envelope + committed target/ + legacy message heuristic + idempotency dead-code warning が負債 |
| F | 8.8 | G 系 integration 74 + idempotency unit 14 PASS、proptest/auth-login idempotency audit/text-yaml emission validation 欠 |
| G | 8.9 | help/man/schema/error docs 強い、G.4 docs が ExecPlan の {json,yaml,text} ではなく human/json を正として固定 |

overall = 8.78 FAIL (Opus 9.23 PASS、gap 0.45)

deltas to 9.0 (Codex primary):
1. 全 11 surface で --output-format text + yaml 実装 OR ExecPlan を human/json に公式変更
2. G.6 proptest 50-iter + auth login --idempotency-key X 二重実行 duplicate write/audit 不増 直接検証 test
3. G.1 inventory 再生成 drift gate CI 化
