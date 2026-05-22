# Lane H Codex scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 6.8 | H.1/H.5 stub bin 名 + sha placeholder で acceptance 未達 |
| B | 8.0 | dry-run CI ある、cosign verify self-check 不在 |
| C | 7.0 | 設計勝ち / 実装 0 |
| D | 5.8 | brew install rev-stealth が tap/sha/bottle 不在で不成立 |
| E | 7.5 | 1 年生存 OK、rename TODO 文書化 |
| F | 6.0 | dry-run 中心、brew audit / dpkg-rpm install sanity / cosign verify self-check / Trivy PR scan 欠落 |
| G | 6.0 | README が `cargo install rev-stealth` や bottles を先取りし現物と不一致 |

overall = 6.79 FAIL
