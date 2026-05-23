# Lane G Opus scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 9.3 | CliErrorKind 26 exhaustive + emit_err_envelope macro + augment_with_g7_fields 中央化、IdempotencyStore library 化 + 15 hook 再利用、clap_complete/mangen 統一 |
| B | 9.2 | help_dict/completion-drift/manpage-drift/json-schema 20/idempotency 6+14/G.7 12+7/completion 5/man 7 = 776→886 (+110)、TCP sentinel zero side-effect strong |
| C | 9.4 | --help 3 section CI lint、26 ErrorKind doc_url 全 resolve、man 44 mandoc 確認、4 層 (help/man/book/schema) drift gate sync |
| D | 9.5 | ripgrep 級: 4 shell completion + 44 man + json 全 11 + dry-run/explain/idempotency-key 15 + envelope で Claude Code jq pipe 即動。「最初の 5 分」golden path 成立 |
| E | 9.0 | IdempotencyStore atomic + TTL 24h + env override、TCP sentinel 副作用ゼロ確認可、CLI hot path 軽量、bench 数値明示なし |
| F | 8.8 | 5 CI gate 再生成漏れ fail-fast、retry_after_ms machine-readable、idempotency env override。G.8 Manpages variant 欠落 LGTM 後 build break が運用品質の傷 -0.4 (G.7 R6 honest recovery 加点) |
| G | 9.0 | idempotency-key 重複 mutate 防止、dry-run 副作用可視化、envelope raw secret 出さず、config.edit carve-out。TTL 24h 脅威モデル文書化未 |

overall = 9.23
verdict: PASS (>= 9.0)

deltas to 9.0: none (PASS 済)

next-lane 申し送り (informational):
- F+0.4: slice contract に "workspace build green" 明文化(G.8 build break が CI gate を通過した root cause)
- B+0.3: emitter ↔ schema property-based round-trip / schemars derive 化検討
- G+0.5: idempotency TTL 24h + key 衝突セマンティクス (replay vs reject) を docs/book 脅威モデルで明示
