# ExecPlan — rev_scraping v1.0.0 "Ultimate Stealth Scraping Toolkit for AI Agents"

**Date:** 2026-05-12
**Author:** Claude Opus 4.7 (planning role) on behalf of Sasuke Torii / REV-C Inc.
**Status:** rev3 — Phase 0 complete; all DECISION items resolved.
**Development location:** `/Users/sasuketorii/dev/rev_scraping/` (new repo).
  Vendored origin: rev_stealth crates @ 6fc38fd (read-only reference at `/Users/sasuketorii/dev/rev_stealth/`).
**Scope discipline:** Orchestration artifact. Implementation is delegated via the
`auto_orchestrate.sh` / Task tool per CLAUDE.md §委譲の原則.
**Positioning (重要):** **Defender-Facing Evaluation Toolkit**.
  authorized red-team / defender-testbed limited use. Attack-purpose framing rejected.

---

## 1. 目的・成功基準

### 1.1 目的
agent (codex / Claude Code) が CLI もしくは MCP (stdio) 経由で本ツールを駆動し、
**authorized target** (operator が `~/.rev_scraping/authorized.toml` で明示同意した host) に対し
Cloudflare Turnstile 等の bot-mitigation の resilience を評価でき、
DOM 変化時には adaptive relocate が自動で要素を再特定する。
Chrome145 相当の TLS/HTTP2 指紋を per-session 決定的にキャッシュし、
ad/tracker をデフォルトでブロックする。

**使途制限 (技術的に enforce):**
- `~/.rev_scraping/authorized.toml` (allowlist `[[targets]] url_pattern = "^https://..."`) に対象 URL が match
  しない場合、`spider` / `cf-evaluate` は exit code 1 で実行拒否する (S12)。
- 初回実行時は CLI で `--i-have-authorization` フラグ または環境変数
  `REV_SCRAPING_AUP_ACK=<today-date-hash>` の明示同意を要求する (TTL: 当日のみ)。
- CLI 起動時 disclaimer banner は **表示しない** (ユーザー指示)。
  不正アクセス禁止法 / CFAA / Cloudflare ToS §2.8 disclaimer は **README.md のみ** で提供する。

### 1.2 成功基準 (deterministic / falsifiable)
| ID | criterion | check |
|----|-----------|-------|
| S1 | `rev-scraping spider --url <authorized_cf_target>` が Turnstile resilience を evaluate し HTTP 200 と DOM を返す | E2E fixture test (CI mocked + ローカル authorized live) |
| S2 | obscura subprocess が起動・停止し、kill-switch が SIGTERM 後 5s 以内に確実に死ぬ | integration test `obscura_lifecycle_test` |
| S3 | 同一 session_id を 2 回叩いた時の TLS ClientHello バイト列が完全一致 (per-session 決定性)。観測手段は Phase 0 SOW で確定 | unit test on FP cache + byte-diff test |
| S4 | DOM 構造が selector hash 一致時は cache hit、不一致時 strsim ≥ 0.85 で relocate 成功。`attrs_hash` / `neighbor_hash` 不一致時は exit code 10 + structured warn event 必須発火 | `stealth-parse` integration test + exit code assertion |
| S5 | MCP server (stdio) が `rmcp` 経由で `tools/list` を返し、CLI と同等の subcommand を expose | MCP conformance test |
| S6 | `cargo clippy --workspace -- -D warnings` PASS, `cargo test --workspace` 新規 unit ≥ 40 PASS | CI |
| S7 | obscura/Scrapling 出典コメントが対象ファイル全先頭に存在 + SPDX-License-Identifier ヘッダ妥当性 | `scripts/check_source_and_spdx.sh` |
| S8 | goscrapy (BSL) からの逐語ポートが 0 行 | `scripts/check_bsl_contamination.sh` |
| S9 | defender 観点の detection signal 抽出 deliverable: `rev-scraping measure` の副成果 | Phase 4 deliverable review |
| S10 | bridge レイヤで独立 SSRF guard。private IP / loopback / link-local / IMDS / non-http(s) を deny。テスト ≥ 3 | bridge unit test |
| S11 | VPN-down → obscura kill ≤ 5s deterministic。`vpn-rotate::leak_guard::on_vpn_loss` が `ObscuraBridge::shutdown` を fail-closed で呼ぶ | integration test |
| S12 | AUP technical enforcement: `~/.rev_scraping/authorized.toml` 不在 or URL 不一致時、`spider` / `cf-evaluate` が exit 1 | CLI unit test |

---

## 2. アーキテクチャ図 (テキスト)

```
                       ┌──────────────────────────────┐
   agent (codex /      │                              │
   Claude Code) ──────►│  stealth-cli (Rust bin)      │◄── operator shell
                       │  spider / relocate / cf-evaluate│
                       │  doctor / browser / vpn       │
                       │  measure (Phase 4 deliverable)│
                       └──────────────┬───────────────┘
                                      │ in-process call
       ┌──────────────────────────────┼──────────────────────────────┐
       │                              │                              │
       ▼                              ▼                              ▼
┌────────────────┐         ┌────────────────────┐         ┌──────────────────┐
│ obscura-bridge │         │   stealth-cf       │         │  stealth-parse   │
│ (subprocess +  │         │ (CF Turnstile      │         │ (adaptive        │
│  CDP via       │         │  resilience eval:  │         │  relocate +      │
│  chromiumoxide │         │  iframe detect,    │         │  SQLite WAL,     │
│  0.9)          │         │  jitter, title)    │         │  strsim 0.85)    │
│ + indep SSRF   │         │                    │         │  + exit10 amb    │
│ guard (S10)    │         │                    │         │                  │
└───────┬────────┘         └────────┬───────────┘         └────────┬─────────┘
        │                           │                              │
        │ CDP (chromiumoxide WS)    │ CDP eval                     │ rusqlite WAL
        ▼                           ▼                              ▼
┌──────────────────────────────────────────┐         ┌──────────────────────┐
│ obscura (vendored at vendor/obscura/)    │         │  ~/.rev_scraping/    │
│ - Chrome145 TLS+HTTP2 FP cache           │         │   parse.db (WAL,     │
│ - Blocklist (3520 ad/tracker entries)    │         │     30d retention,   │
│ - obscura-side SSRF guard                │         │     dir perm 0700)   │
│ - CDP server-compatible WebSocket        │         │   authorized.toml    │
└──────────────────────────────────────────┘         │   (AUP allowlist S12)│
        ▲                                            └──────────────────────┘
        │ mobile-fp injection                  ┌──────────────────┐
        │                                      │ leak_guard.rs    │── fail-closed
┌───────┴────────┐  ┌────────────────┐         │ on_vpn_loss →    │   callback
│ mobile-fp      │  │ captcha-bypass │         │ ObscuraBridge::  │── kill ≤5s
└────────────────┘  └────────────────┘         │ shutdown (S11)   │
                                               └──────────────────┘
                                                       ▲
                                              ┌────────┴────────┐
                                              │ vpn-rotate      │
                                              └─────────────────┘

                       ┌──────────────────────────────┐
   agent (MCP stdio) ─►│  stealth-mcp (rmcp server)   │── in-proc / shells out
                       │  thin wrapper over CLI ops    │   stealth-cli logic
                       └──────────────────────────────┘
```

### 2.1 Workspace layout (Phase 0 ground truth)

```
/Users/sasuketorii/dev/rev_scraping/
├── Cargo.toml                    (workspace root, members = 9)
├── crates/
│   ├── stealth-core/             (vendored, MIT, @ 6fc38fd)
│   ├── mobile-fp/                (vendored)
│   ├── vpn-rotate/               (vendored)
│   ├── captcha-bypass/           (vendored)
│   ├── stealth-cli/              (vendored, extended in Phase 2)
│   ├── obscura-bridge/           (NEW stub, Phase 1a)
│   ├── stealth-cf/               (NEW stub, Phase 1b)
│   ├── stealth-parse/            (NEW stub, Phase 1c)
│   └── stealth-mcp/              (NEW stub, Phase 3)
├── vendor/obscura/               (vendored obscura source, Apache-2.0)
├── _refs/                        (read-only: obscura, Scrapling, rev_harness clones)
├── scripts/                      (SPDX lint, BSL contamination check)
├── docs/, tests/
└── .agent/active/plan_v1.0.0.md  (this file)
```

---

## 3. クレート別の責務と API 設計

(unchanged from rev2 — see Revision History §12.)
Key API renames retained: `solve_turnstile` → `evaluate_turnstile_resilience`,
`cf-solve` → `cf-evaluate`. All `async fn` carry `Send + 'static` bounds where applicable.
`Browser` trait dyn-safety: inherent `async fn` on `ObscuraBridge` + object-safe
`BrowserOps` subset for mocks.

CDP client implementation: **reuse `chromiumoxide 0.9`** for standard CDP commands.
obscura-specific CDP extensions use `tokio-tungstenite 0.26` direct WebSocket.

`stealth-parse` DB: `~/.rev_scraping/parse.db`, **30-day retention** (background sweep),
parent dir created with **permission `0700`** (Decision #13).

---

## 4. 依存関係グラフ

```
stealth-cli ─┬─► obscura-bridge ─► (vendor/obscura binary, chromiumoxide 0.9)
             │                   └─► bridge SSRF guard (S10, independent)
             ├─► stealth-cf ──────► obscura-bridge
             ├─► stealth-parse ───► (rusqlite 0.32 bundled, strsim 0.11)
             ├─► mobile-fp ───────► obscura-bridge (glue)
             ├─► captcha-bypass (既存)
             ├─► vpn-rotate (既存) ── leak_guard::on_vpn_loss
             │                       └─► ObscuraBridge::shutdown (S11, §8 #15)
             └─► stealth-core (既存)

stealth-mcp ─► stealth-cli (lib API) ─► (上記)
```
- `obscura-bridge` は他の新規クレートが参照する基盤層。
- `stealth-cf` / `stealth-parse` / `mobile-fp` glue は obscura-bridge のみに依存し互いに独立 → 並列実装可能。
- `stealth-mcp` は最後 (CLI lib 安定後)。

---

## 5. 実装フェーズ分割 (並列単位)

### Phase 0 — Preflight & SOW (✅ COMPLETE @ rev3)
- ✅ Workspace skeleton at `/Users/sasuketorii/dev/rev_scraping/`.
- ✅ Vendored 5 crates from rev_stealth, vendored obscura source.
- ✅ 4 NEW stub crates created (obscura-bridge, stealth-cf, stealth-parse, stealth-mcp).
- ✅ `scripts/check_source_and_spdx.sh`, `scripts/check_bsl_contamination.sh` 雛形.
- ✅ README.md with disclaimers (Cloudflare ToS §2.8 / 不正アクセス禁止法 / CFAA).
- ✅ All DECISION items #1–#16 resolved (see §8).
- Remaining Phase 0 work: TLS ClientHello dump 手段 (S3) 確定, `dependency_policy.json` RC exception PR,
  `rmcp 0.1` publish confirmation.

### Phase 1a — `obscura-bridge` 単独 (Coder #1, 並列 OK, 2-3 日)
- obscura subprocess lifecycle, chromiumoxide reuse CDP client, inherent fn 設計
- bridge レイヤ独立 SSRF guard 実装 (S10)
- session_id ベースの per-session FP cache key 連携
- `leak_guard::on_vpn_loss` 連動 shutdown 契約
- **LGTM:** unit test ≥ 8 PASS、clippy PASS、integration `--ignored` 1 本、S11 deterministic test PASS。

### Phase 1b — `stealth-cf` 単独 (Coder #2, **1a と並列**, 2 日)
- 1a の `PageHandle` を mock で先行実装 → 1a merge 後 wire-up smoke test。
- detect / `evaluate_turnstile_resilience` / wait_cleared
- **LGTM:** unit test ≥ 6 PASS、Scrapling 由来 verbatim 0、wire-up integration smoke 1 本 PASS。

### Phase 1c — `stealth-parse` 単独 (Coder #3, **1a/b と並列**, 3 日)
- SQLite WAL schema、ElementFingerprint upsert/lookup、Relocator strsim、attrs_hash/neighbor_hash double-check
- exit 10 ambiguous path (S4 / §8 #16)、30-day retention sweep、dir perm 0700
- **LGTM:** unit test ≥ 10 PASS、golden HTML snapshot 3 種で 100/95/85% 成功。

### Phase 1d — `mobile-fp` obscura glue (Coder #4, **並列 OK**, 0.5 日)
- `inject_into_obscura` impl (chromiumoxide reuse) + unit test ≥ 3
- **LGTM:** clippy PASS, 既存 21 test 維持。

### Phase 2 — `stealth-cli` 拡張 (Coder #5, 1a/b/c merge 後 / 1.5 日)
- spider / relocate / cf-evaluate / measure サブコマンド + JSON output schema
- exit code 8/9/10 追記
- **AUP enforcement (S12)**: authorized.toml 読込 + `REV_SCRAPING_AUP_ACK` (date-hash TTL) + `--i-have-authorization`
- **`--strict` flag for exit 10**: default OFF (Decision #16); opt-in to convert ambiguous warn into exit 10
- **No runtime disclaimer banner** (Decision #9, #10); README is the canonical disclaimer surface
- **LGTM:** unit test ≥ 6 PASS、E2E スモーク (mocked obscura)、S12 (allowlist 不在で exit 1) PASS。

### Phase 3 — `stealth-mcp` (Coder #6, Phase 2 後 / 2 日)
- **transport: stdio** (Decision #4)
- rmcp server, tools/list, tools/call (6 tools incl. measure)
- **LGTM:** MCP conformance test 6/6 PASS、CLI と golden diff 0。

### Phase 4 — E2E + README + measure deliverable (Coder #7 + reviewer, 2 日)
- E2E `tests/e2e_spider_cf_relocate.rs` (`#[ignore]`)
- `rev-scraping measure` Bot Score 収集 + defender signal レポート (S9)
  - `--enable-external-measure` flag is **opt-in** (Decision #14); off by default
- README §12 "Agentic Scraping Stack" — defender-testbed positioning maintained
- **LGTM:** E2E `--ignored` PASS、reviewer LGTM、verification-truth-matrix S1–S12 全行 deterministic PASS。

---

## 6. テスト戦略
(Unchanged from rev2.) 合計新規テスト **40 本以上**。

---

## 7. HANDOFF Tier との整合

- 位置付け: Tier 2 / **Wave 5b**。Wave 5.1 と **並列実行** (Decision #5)。
- HANDOFF L394 defender-first 原則整合: README + AUP allowlist (S12) の二段で明文化 (CLI banner なし)。

---

## 8. DECISION (resolved @ rev3)

| # | 項目 | ✅ 確定 |
|---|------|--------|
| 1 | obscura License/NOTICE | ✅ 確定: ノータッチ (将来対応) |
| 2 | wreq 6.0.0-rc.28 (RC) 採用 | ✅ 確定: 採用 OK、`Cargo.lock` pin |
| 3 | vendored obscura binary 配布形態 | ✅ 確定: workspace source 取込 (`vendor/obscura/`) |
| 4 | MCP transport | ✅ 確定: stdio |
| 5 | Wave 5.1 (既存 HANDOFF) との実行順序 | ✅ 確定: 並列 |
| 6 | positioning | ✅ 確定: **Defender-Facing Evaluation Toolkit** |
| 7 | BSL goscrapy 取扱 | ✅ 確定: 設計参照のみ (verbatim 0) |
| 8 | obscura 3520 blocklist 再配布 | ✅ 確定: obscura 同梱として継承 |
| 9 | Cloudflare ToS §2.8 disclaimer | ✅ 確定: **README.md のみ** で disclaimer (CLI 起動時 disclaimer は不要) |
| 10 | 不正アクセス禁止法 / CFAA disclaimer | ✅ 確定: **README.md のみ** (CLI 起動時 disclaimer は不要) |
| 11 | AUP allowlist 細則 | ✅ 確定: `~/.rev_scraping/authorized.toml`, `[[targets]] url_pattern="^https://..."` |
| 12 | AUP env var TTL | ✅ 確定: `REV_SCRAPING_AUP_ACK` は当日のみ (date hash) |
| 13 | PII 保持期間 / 暗号化 | ✅ 確定: `parse.db` 30 日 retention, dir perm `0700`, 暗号化なし |
| 14 | measure 外部 SaaS 利用 | ✅ 確定: opt-in `--enable-external-measure` |
| 15 | leak_guard 監督責任 (S11) | ✅ 確定: `LeakGuard::on_vpn_loss` → `ObscuraBridge::shutdown` |
| 16 | relocate exit 10 強制 | ✅ 確定: `--strict` opt-in (既定 OFF); structured warn は常時発火 |

(Decision #2 は Phase 0 で `Cargo.lock` pin により消化; #7 は scripts/check_bsl_contamination.sh で enforce。)

---

## 9. リスクと Mitigation
(Unchanged from rev2.)

## 10. ロールバック計画
- per-phase: 新規 4 crate は workspace `[workspace] members` 追加のみで既存 5 crate へ非侵襲。
- 全 path / config を `~/.rev_scraping/` 配下に集約。削除で rollback 可。

## 11. タイムライン見積
(Unchanged from rev2; ~14 eng-day / ~9.5 wall-day, up to 4 並列.)

---

## 12. Revision History

| date | version | author | 内容 |
|------|---------|--------|------|
| 2026-05-12 | rev1 | Claude Opus 4.7 / Sasuke Torii | initial; obscura + Scrapling 統合 / 4 crate 新規 |
| 2026-05-12 | rev2 | Claude Opus 4.7 / Sasuke Torii | 技術 + 安全/法務レビュー 16 項目反映 (chromiumoxide reuse / dyn-safety / TLS dump Phase 0 / Send bounds / version pin / wire-up smoke / measure deliverable / RC exception PR / bridge SSRF S10 / API 改名 / leak_guard 連動 S11 / exit 10 S4 / AUP S12 / DECISION #9–#16 追加 / panic shutdown hook / S7 SPDX lint) |
| 2026-05-12 | **rev3** | Claude Opus 4.7 / Sasuke Torii | **dev location 変更 + 全 DECISION 確定。** (a) 開発先パスを `/Users/sasuketorii/dev/rev_scraping/` に全面更新 (rev_stealth は vendored origin としてのみ言及)。(b) DECISION #1–#16 を全て確定値で書き換え (✅ 確定 表記)。(c) workspace 構成 (vendored 5 + NEW 4 = 9 members) を §2.1 / §4 に反映。(d) CLI 起動時 disclaimer banner を撤廃し README.md を canonical disclaimer 面とする (#9 #10)。(e) AUP allowlist file 名を `authorized.toml`, env var を `REV_SCRAPING_AUP_ACK` に統一。(f) parse.db 30 日 retention + dir perm 0700 (#13)、measure 外部 SaaS opt-in (#14)、`--strict` opt-in for exit 10 (#16) を Phase 2/4 LGTM 条件に反映。 |

**END OF EXECPLAN (rev3)**
