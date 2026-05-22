# Lane H Opus scoring round 1 (recorded)

| 軸 | スコア | 根拠 |
|---|---|---|
| A | 7.5 | 7 sub-phase 足回り揃う; acceptance は外部 gate (brew install/dpkg -i/docker pull/cargo install) を要求、tag push まで PASS 確認不能 (deferred-by-design); rev-stealth-cli-stub は `rev-stealth --help` 不成立 |
| B | 8.0 | cosign keyless OIDC + SLSA L3 + trivy HIGH/CRITICAL fail + dry-run の reproducible; cosign verify の self-check CI 未 |
| C | 7.5 | 設計上は Crawl4AI/Browserless/Playwright を supply-chain で勝つ; 実走 0 ゆえ "設計勝ち実装 0" |
| D | 6.5 | brew install 60 秒で動かない(placeholder version/sha256, tap repo 不在, stub binary exit 3, install path workspace publish=false) |
| E | 8.5 | 採用技術 1 年生存; rename TODO は文書化済 |
| F | 6.5 | install.sh unit test なし / Formula brew audit CI なし / cargo deb sanity gate なし / cosign verify self-test なし / trivy PR run なし |
| G | 7.5 | コメントは充実だが docs/distribution.md ADR 不在 / crates/rev-stealth-cli/README が stub 動作不能を伝えていない |

overall = 7.38
verdict: FAIL (< 9.0)

deltas to 9.0 (Opus):
1. crates/stealth-cli に lib.rs + pub fn run() -> ExitCode 追加、stub bin → 1 行 forwarder + [[bin]] name = "rev-stealth" rename (最大 delta、D 6.5 → 8.5+)
2. Homebrew tap bootstrap runbook + brew audit --strict --online CI
3. install.sh posix unit test + cosign verify self-test (sign 直後 verify)
4. cargo-deb / cargo-generate-rpm の dpkg/rpm sanity gate (PR で dpkg -I + rpm -qip)
5. distroless image PR-level trivy fs scan + self-pull smoke
6. docs/distribution.md ADR + crates.io README stub 注意書き
7. release.yml e2e dry-run integration job (workflow_dispatch で 1 ボタン実走)
