<!--
  rev_scraping — README.ja.md (日本語版)
  v1.3.0 "Black-Belt CLI" (2026-05-23) — partial update; see README.md for full v1.3 coverage
  English version: README.md
-->

# rev_scraping

> **AI エージェント向けに最初から設計された、本番運用品質のステルススクレイピング・ツールキット。**
> Rust ワークスペース · 13 クレート · MCP ネイティブ(16 ツール) · VPN 必須デフォルト ·
> XChaCha20-Poly1305 で cookie 暗号化保管 · `<<<UNTRUSTED_CONTENT>>>` エンベロープによる prompt injection 防御 · systemd 級 VPS デプロイ。

[![tests](https://img.shields.io/badge/workspace_tests-911%20PASS%20%2F%200%20fail-success)](#テストスイート)
[![python](https://img.shields.io/badge/hermes_python-20%20PASS-success)](#hermes-プラグイン)
[![rust](https://img.shields.io/badge/rust-1.83%2B-orange)](https://www.rust-lang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![release](https://img.shields.io/badge/release-v1.3.0-blueviolet)](RELEASE_NOTES_v1.3.0.md)
[![mcp](https://img.shields.io/badge/MCP-stdio_JSON--RPC_2.0-purple)](docs/MCP_REFERENCE.md)
[![ci](https://img.shields.io/badge/CI-28_gates-green)](.github/workflows/ci.yml)

🇺🇸 English: [README.md](README.md) · 🇯🇵 日本語: README.ja.md (このページ)

---


> ⚠ **v1.3.0 注記**: この日本語版は v1.2.0 baseline を保持。v1.3 で追加された機能(`--output-format yaml` / `--dry-run --explain` / `--idempotency-key` / shell completion 4 系統 / 44 man pages / unified error envelope `{kind, message, hint, doc_url}` / mdBook docs / 12 crate rename `rev-stealth-*` prefix / 28 CI gates 等)は [README.md (英語版)](README.md) と [RELEASE_NOTES_v1.3.0.md](RELEASE_NOTES_v1.3.0.md) を参照。完全和訳は v1.3.1 で対応予定。


## 目次

- [30 秒で理解](#30-秒で理解)
- [なぜ rev_scraping か](#なぜ-rev_scraping-か)
- [クイックスタート](#クイックスタート)
- [MCP ツール 16 個 概要](#mcp-ツール-16-個-概要)
- [アーキテクチャ](#アーキテクチャ)
- [セキュリティモデル](#セキュリティモデル)
- [機能カタログ](#機能カタログ)
- [動作の流れ(シーケンス)](#動作の流れシーケンス)
- [ユースケース](#ユースケース)
- [競合比較](#競合比較)
- [設定](#設定)
- [FAQ・トラブルシューティング](#faqトラブルシューティング)
- [既知の制限と v1.2.1 バックログ](#既知の制限と-v121-バックログ)
- [開発プロセス](#開発プロセス)
- [ライセンス](#ライセンス)

---

## 30 秒で理解

```bash
git clone https://github.com/sasuketorii/scraping.git
cd rev_scraping && cargo build --release --bin stealth-mcp --bin rev-stealth
./target/release/rev-stealth doctor --output-format json
```

これだけで手に入るもの:

- **`stealth-mcp` バイナリ** — Model Context Protocol(`2024-11-05`)を stdio で話し、**スキーマ厳密な 16 ツール** (`spider`, `auth_login_*`, `vpn_rotate`, `recipe_*`, `session_show` …) を公開。
- **`rev-stealth` CLI** — オペレータ直叩き用 (doctor / config / profile / hermes / auth / spider)。
- **ステルス Chromium ドライバ** — chromiumoxide + obscura CDP shim。`canAccessOpener` 等 11+ field 補完、WebSocket 警告 0、ヘッドレス VPS でも `xvfb-run` 自動ラップで動作。
- **VPN 必須ゲート** — Surfshark + Gluetun × 3 インスタンス HRW スティッキープール + 5〜300 秒間隔のリーク監視。
- **5 層 prompt injection サニタイザ** (`stealth-sanitize`) — 全ツール応答を `<<<UNTRUSTED_CONTENT origin=… sanitize_id=NONCE>>>` で包み、**20 種類の canary を検出**(v1.2.0 ゴールデンコーパスで Critical / High ともに 100% 検出)。
- **26 種 closed `ErrorEnvelope`** — retriable ヒント付き。typed agent がスタックトレース grep する必要なし。
- **systemd 5 unit パック** (`dist/systemd/`) + `systemd-creds` 暗号化シークレット — 1 コマンド VPS デプロイ。
- **Python Hermes プラグイン** (`dist/hermes/rev-scraping-mcp/`) — MCP サーバを env ホワイトリスト付きで起動(`ANTHROPIC_API_KEY` 等は子プロセスに漏らさない)。

**想定ユーザ**: 防衛側 red/blue チーム、AI エージェント運用者 (Claude Code / Cursor / Hermes)、監査ログ付きで認証スクレイピングを回したいアナリスト。

**想定外**: 1,000 万 URL 級の分散クロール、RAG 用 HTML→Markdown 大量取り込み、GUI 管理のブラウザファーム。それは Crawl4AI / Browserless / Bright Data の領分。[正直な制限](#既知の制限と-v121-バックログ) 参照。

---

## なぜ rev_scraping か

他のスクレイピングツールがオペレータに丸投げしている 5 つのこと。rev_scraping はデフォルトで全部やる。

| 観点 | rev_scraping | 業界の現状 |
|------|-------------|-----------|
| **スクレイプ内容への prompt injection 防御** | `stealth-sanitize` 5 層パイプライン、canary 20 種、`<<<UNTRUSTED_CONTENT>>>` エンベロープ、全応答に `_meta.sanitize` レポート添付。v1.2.0 ゴールデンコーパスで **Critical / High 100% 検出**。 | Crawl4AI / Playwright MCP / Puppeteer MCP / Browserless / Bright Data — **全部 raw HTML/markdown をそのまま LLM に渡す**。Crawl4AI 公式 MCP ドキュメントでも「prompt injection はエージェント側でモデル aligment で対処してくれ」とサーバ側で扱わない方針を明示している。 |
| **VPN が前提、設定じゃなく必須条件** | `require_vpn=true` デフォルト · 5〜300 秒 leak monitor(デフォルト 30 秒、初回即発火、leak でラッチ停止) · IP/国/DNS/kill-switch/IPv6/WebRTC チェック · HRW 3 インスタンスステッキープール · Surfshark 認証情報を `systemd-creds` で暗号化 · leak 検出で exit 7。 | 他全ツール: VPN はオペレータがグルーコードで自作。Bright Data / Browserless は *プロキシ* primitive を持つが「leak-stop 付き VPN」ではない。 |
| **クレデンシャル暗号化保管** | XChaCha20-Poly1305 AEAD(24 バイト `OsRng` nonce、32 バイト鍵)· OS keyring(Keychain / `secret-service` / DPAPI)· Argon2id パスフレーズフォールバック(`m=64 MiB, t=3, p=1`)· 平文は `Zeroizing<Vec<u8>>` + `secrecy::SecretString` 寿命 · プロファイル単位 AAD バインディング。 | Playwright `storageState.json` は **平文**。Puppeteer `userDataDir` も **平文**。Scrapling / Crawl4AI / obscura / gocrawl はセッション暗号化レイヤなし。 |
| **型安全な error contract** | 26 種 closed `ErrorKind` · `retryable: bool` + `hint` + `retry_after_ms` を envelope に同梱 · `#[forbid(unreachable_patterns)]` + 網羅 match でコンパイル時 arity 保証。27 番目の variant 追加は**意図的に**破壊的変更。 | gocrawl: Go の `error` 文字列。Scrapling / Crawl4AI: Python 例外文字列。Browserless / Bright Data: HTTP ステータス + JSON `error: "..."`。Playwright / Puppeteer: 文字列例外。結果 agent 側で `if "rate limit" in str(err)` のグルーコードだらけになる。 |
| **MCP ネイティブ + 厳密スキーマ** | 16 ツール、**入力 *と* 出力 両方の JSON-Schema**。`docs/MCP_REFERENCE.md` に自動生成 + CI 鮮度ゲート。auth ツール応答全部に `cookie_values_returned: false` のマーカ field。 | Crawl4AI MCP: 4 ツール、エラーは文字列。Playwright MCP: 広いツール面、closed error enum なし。この空間の MCP サーバはほぼ raw markdown か HTTP-shape error を返してくる。 |

8 ツール × 11 軸の完全マトリクスと「rev_scraping が *間違った* 選択になるケース」の正直な列挙は [競合比較](#競合比較) 参照。

---

## クイックスタート

### ルート A — ローカル開発(macOS / Linux)

```bash
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping
cargo build --release --bin stealth-mcp --bin rev-stealth

# ~/.rev_scraping/{policy.toml, authorized.toml, sites/} を初期化
./target/release/rev-stealth config init

# リーク防止サニティチェック
./target/release/rev-stealth doctor --output-format json
# exit 0 = OK / exit 7 = leak / exit 3 = 前提条件 fail
```

要件: Rust 1.83+、Chrome/Chromium 120+ が `PATH` 上 (または `OBSCURA_BIN` 設定)、cookie 保管庫用に macOS Keychain か Linux `secret-service`。Windows は **v1.2.0 非対応**(ACL TODO)。

### ルート B — VPS 本番(Ubuntu 24.04 / Debian 12+、systemd 252+)

完全な手順書は [`docs/deploy/vps.md`](docs/deploy/vps.md)。要約:

```bash
# OS 側の前提
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 chromium-browser \
                        xvfb x11vnc ufw fail2ban unattended-upgrades

# ビルド
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping && cargo build --release

# systemd unit 配置(冪等 — `ln -sfn` なので `git pull` 後の再実行も安全)
sudo ./dist/systemd/install.sh

# Surfshark 認証情報を systemd-creds で暗号化(TPM2 利用可能時は自動シーリング)
sudo ./dist/systemd/setup-credentials.sh

# VPN インスタンス + MCP サーバ + doctor タイマ有効化
sudo systemctl enable --now rev-stealth-vpn@1 rev-stealth-vpn@2 rev-stealth-vpn@3
sudo systemctl enable --now rev-stealth-mcp rev-stealth-doctor.timer

# 初回起動サニティ (VPS 9 deep check)
sudo -u rev-stealth ./target/release/rev-stealth doctor --vps --output-format json \
  | tee /var/log/rev-stealth/doctor-firstboot.json
```

`install.sh` が `/etc` に置くもの(コピーではなくシンボリックリンク):

- `rev-stealth-mcp.service` — `User=rev-stealth`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `ProtectKernel{Tunables,Modules,ControlGroups}=yes`, `LockPersonality=yes`, `RestrictSUIDSGID=yes`, `LimitNOFILE=65536`, `Restart=on-failure RestartSec=5s`, `ReadWritePaths=/var/lib/rev-stealth /var/log/rev-stealth`。
- `rev-stealth-vpn@.service`(テンプレート、Gluetun コンテナ 1 インスタンスごと)。
- `rev-stealth-doctor.{service,timer}` — `OnBootSec=5min` + `OnUnitActiveSec=30min`(30 分ごと)で発火、`/var/log/rev-stealth/doctor.jsonl` に JSONL 追記。
- `rev-stealth-xvfb-vnc.service` — `install.sh --with-vnc-fallback` で **opt-in**。localhost バインドの x11vnc、緊急時に `ssh -L` で転送して使う。デフォルト無効。
- `tmpfiles.d` + `sysusers.d`(`rev-stealth` システムユーザ + `/usr/sbin/nologin` シェル)。

クレデンシャル drop-in(オペレータが用意 — `systemd-creds` ブロブを env ファイルパスに繋ぐ):

```ini
# /etc/systemd/system/rev-stealth-mcp.service.d/override.conf
[Service]
LoadCredentialEncrypted=surfshark_user:/etc/credstore.encrypted/surfshark_user.cred
LoadCredentialEncrypted=surfshark_password:/etc/credstore.encrypted/surfshark_password.cred
Environment=VPN_USER_FILE=%d/surfshark_user
Environment=VPN_PASSWORD_FILE=%d/surfshark_password
```

`<KEY>_FILE` 優先順位は `CredentialResolver` が honor し、**owner-other ビットが立った Unix mode のファイルを拒否** (`mode & 0o077 != 0` だと reject)。systemd の 0400 は OK、手作りの 0644 は NG。

### ルート C — Hermes プラグイン

```bash
./target/release/rev-stealth hermes install
./target/release/rev-stealth hermes verify
# Hermes 起動 → 16 MCP ツールが ctx callable として自動登録
```

内部動作:

1. スキャフォールドを `~/.hermes/plugins/rev-scraping-mcp/` にコピー(`--prefix` で上書き可)。
2. `register(ctx)` が `stealth-mcp` を **env ホワイトリスト** 付きで subprocess 起動 — `REV_SCRAPING_*` / `VPN_*_FILE` / `PATH` / `HOME` / `LANG` のみ通過、`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GITHUB_TOKEN` / AWS creds は **起動前に削除**。
3. MCP `2024-11-05` ハンドシェイク → `tools/list` → 各ツールを `ctx.register_tool(...)` 登録。
4. 子プロセス crash → exp バックオフ再起動 `1, 2, 4, 8, 16 秒` (16 秒で頭打ち)。
5. 応答ペイロードは `schema_bridge.redact_response` を通る(Rust 側 `stealth-sanitize` の上の defense in depth)。

バイナリパスは `REV_SCRAPING_MCP_BIN` で上書き可。

### AI クライアント側の設定(Claude Code / Cursor)

```json
{
  "mcpServers": {
    "rev-scraping": {
      "command": "/absolute/path/to/target/release/stealth-mcp",
      "env": {
        "REV_SCRAPING_HOME": "/home/user/.rev_scraping",
        "VPN_USER_FILE": "/run/credentials/rev-stealth-mcp/vpn_user",
        "VPN_PASSWORD_FILE": "/run/credentials/rev-stealth-mcp/vpn_password"
      }
    }
  }
}
```

スモークテスト(16 ツールが返るはず):

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | ./target/release/stealth-mcp | jq '.result.tools | length'
# 期待: 16
```

---

## MCP ツール 16 個 概要

全ツールは共通エンベロープ `{ok, operation, result, _meta: { sanitize: {...} }}` を返す(失敗時は `{ok: false, exit_code, error}`)。入出力スキーマの完全版は [`docs/MCP_REFERENCE.md`](docs/MCP_REFERENCE.md) (自動生成、CI gate で陳腐化防止)。

| # | ツール名 | 目的 |
|---|---|---|
| 1 | `spider` | obscura CDP shim + 任意の CF challenge eval + 適応 selector relocate で AUP 許可 URL をステルス取得。per-host rate-limit、`session_id` 冪等。 |
| 2 | `relocate` | `stealth-parse` fingerprint cache による selector 復元。記録済 element を新しい HTML / URL 上で特定。 |
| 3 | `cf_evaluate` | Cloudflare Turnstile 強度評価(defender 側、solver は同梱せず)。 |
| 4 | `doctor` | リーク / VPN / captcha sidecar 健康診断。フラット出力。 |
| 5 | `vpn_rotate` | VPN exit ローテーション(Surfshark via Gluetun)。strategy: `lazy-on-fail` / `every-n` / `interval`。region miss で `vpn_country_mismatch` (retriable)。 |
| 6 | `recipe_list` | `~/.rev_scraping/sites/` 配下の全 site recipe を列挙。 |
| 7 | `recipe_show` | 指定ドメインの完全な `SiteRecipe` JSON を返す。 |
| 8 | `recipe_remove` | recipe 削除。デフォルトは preview のみ、`confirm=true` で commit。 |
| 9 | `recipe_propose_endpoint` | 既存 recipe に endpoint 追加。secret 含む field は reject。 |
| 10 | `recipe_export` | 全 recipe を base64 JSON 配列でエクスポート。 |
| 11 | `recipe_import` | base64 JSON から import。secret reject、path-traversal guard。 |
| 12 | `auth_login_start` | 2-phase login の Phase 1。AUP enforce + `rev-auth` helper 起動。single-use `session_token` を返す。**`cookie_values_returned=false`**。 |
| 13 | `auth_login_complete` | Phase 2。helper の完了を polling、`ProfileMeta` を返す。cookie *値* は暗号化保管庫から絶対に出ない。 |
| 14 | `auth_list` | 保管済 auth profile 一覧(`ProfileMeta` のみ)。 |
| 15 | `auth_status` | 鮮度分類: `Valid` / `ExpiringSoon` / `ExpiringCritical` / `PartiallyExpired` / `AllExpired` / `Missing`。 |
| 16 | `session_show` | 永続化済 session メタデータ(VPN binding + recipe hits + auth profile)。cookie 値は返さない。 |

**全 16 ツール共通の不変条件**:

- **Rate limit**: per-host トークンバケット(`DashMap<String, TokenBucket>`)。429 backoff は `MAX_429_BACKOFF_SECS = 86400` 秒で clamp(u64::MAX DoS 経路を遮断)。枯渇時は `kind: "rate_limit"` + `retry_after_ms` 返却。
- **Idempotency**: Stripe スタイルキー(`spider` / `relocate` / `cf_evaluate`)。`DashMap::remove_if` atomic 退避で TOCTOU race を排除。
- **AUP / SSRF**: URL を取る全ツールが `aup::enforce` + `ObscuraBridge::validate_url` 通過(loopback / RFC1918 / link-local は reject)。
- **Secrets**: cookie 値は MCP 経由で **絶対に** 返らない。auth ツール全応答の `cookie_values_returned=false` がその契約マーカ。

---

## アーキテクチャ

### ワークスペース クレートグラフ

```mermaid
graph TD
  cli["stealth-cli<br/>(bin: rev-stealth)"]
  mcp["stealth-mcp<br/>(bin: stealth-mcp + gen_reference)"]
  auth_bin["stealth-auth<br/>(bin: rev-auth)"]

  core[stealth-core]
  contracts[stealth-agent-contracts]
  sanitize[stealth-sanitize]
  obscura[obscura-bridge]
  vpn[vpn-rotate]
  authlib[stealth-auth lib]
  mfp[mobile-fp]
  cf[stealth-cf]
  parse[stealth-parse]
  sites[stealth-sites]
  cap[captcha-bypass]

  cli --> core
  cli --> cap
  cli --> vpn
  cli --> mfp
  cli --> obscura
  cli --> cf
  cli --> parse
  cli --> sites
  cli --> authlib

  mcp --> contracts
  mcp --> sanitize
  mcp --> sites
  mcp --> authlib
  mcp -. "spawn rev-stealth bin" .-> cli

  auth_bin --> authlib
  auth_bin --> obscura
  auth_bin --> vpn

  obscura --> core
  obscura --> mfp
  vpn --> core
  core --> mfp
```

3 つの実行表面(`rev-stealth` CLI、`stealth-mcp` MCP サーバ、`rev-auth` login helper)を **10 ライブラリクレート** で綺麗に分離。`stealth-agent-contracts` が IPC 境界を跨ぐ型(エラー・トークン・rate limit)を、`stealth-sanitize` が content safety 境界を提供する。

### 3 つのランタイム構成

#### A. ローカルオペレータモード

```
オペレータシェル
   │
   ▼
rev-stealth (stealth-cli バイナリ)
   │
   ├──► vpn_guard::run_startup_probe  (require_vpn チェック、leak で exit 7)
   ├──► InstancePool::pick(session_id) (HRW スティッキー)
   ├──► ObscuraBridge (CDP shim、SSRF guard)
   │     └──► Chrome/Chromium (chromiumoxide WebSocket)
   ├──► stealth-cf (challenge 検出)
   └──► stealth-parse (適応 selector cache、SQLite WAL)
```

認証は `rev-stealth auth login` から別バイナリを spawn:

```
rev-stealth auth login ── spawn ──► rev-auth (stealth-auth クレート)
                                       │
                                       ├──► auth_aup::enforce
                                       ├──► prepare_vpn_context (probe + monitor)
                                       ├──► chromiumoxide::Browser::launch
                                       │     (headed / headless / xvfb shim)
                                       ├──► page.get_cookies() via CDP
                                       └──► XChaCha20-Poly1305 暗号化
                                            + OS keyring 保管
                                            + audit JSONL 追記
```

#### B. VPS 本番(systemd)

```
systemd (PID 1)
 │
 ├── rev-stealth-vpn@{1,2,3}.service   docker compose ──► Gluetun/WireGuard
 │     LoadCredentialEncrypted=surfshark_user/password.cred
 │
 ├── rev-stealth-mcp.service
 │     User=rev-stealth NoNewPrivileges=yes ProtectSystem=strict
 │     PrivateTmp=yes ReadWritePaths=/var/lib/rev-stealth /var/log/rev-stealth
 │
 ├── rev-stealth-doctor.timer ──► doctor.service
 │     OnBootSec=5min  OnUnitActiveSec=30min  Persistent=true
 │
 └── rev-stealth-xvfb-vnc.service   (opt-in localhost VNC フォールバック)
```

#### C. AI エージェント経由(MCP)

```
Claude / GPT / Hermes (MCP クライアント)
        │ stdio JSON-RPC 2.0
        ▼
stealth-mcp ──► dispatch_tool
        │
        ├── auth_*    → in-process (handle_auth_tool)
        ├── recipe_*  → in-process (SiteRecipeStore)
        ├── session_* → in-process (~/.rev_scraping/sessions/)
        └── spider / relocate / cf_evaluate / doctor / vpn_rotate
                                       → subprocess (rev-stealth)
                                       │
                                       ▼
                          stealth-sanitize: L4 → L5 → L3 → L2 → L7
                                       │
                                       ▼
                          JSON-RPC result + _meta.sanitize レポート
```

### ファイル / プロセス レイアウト

| パス / プロセス | mode | owner | 用途 |
|---|---|---|---|
| `/var/lib/rev-stealth/` | 0700 | `rev-stealth:rev-stealth` | サービス状態ルート |
| `/var/lib/rev-stealth/vpn/` | 0700 | `rev-stealth:rev-stealth` | インスタンス別 compose 作業 dir |
| `/var/log/rev-stealth/` | 0750 | `rev-stealth:rev-stealth` | doctor JSONL + audit |
| `/etc/credstore.encrypted/surfshark_{user,password}.cred` | 0400 | root | systemd-creds 暗号化 Surfshark |
| `~/.rev_scraping/policy.toml` | 0600 | user | VPN / require_vpn / instance |
| `~/.rev_scraping/sessions/<id>.json` | 0600 | user | HRW スティッキー binding メタ |
| `<user_data_dir>/rev-auth-xvfb-run.sh` | 0700 | user | 自動生成 `xvfb-run` shim |
| OS keyring エントリ | — | user | `service=rev_scraping.stealth_auth`, `account=cookie-jar:<profile>` |

### exit code(`stealth-core::ExitCode` 由来)

| code | バリアント | 意味 |
|---|---|---|
| 0 | `Ok` | 成功 |
| 1 | `UserError` | clap parse / ユーザ入力 |
| 2 | `TransientError` | retriable failure |
| 3 | `PermanentError` | 前提条件 fail(Chrome 未解決等) |
| 4 | `AuthExpired` | 取得時点で全 cookie 既に expired |
| 7 | `Leak` | VPN tunnel down / IP/国/DNS leak 検出 |

sanitize の Critical fail-closed は JSON-RPC envelope の `isError: true` として返り、**プロセス exit code は別途持たない**。

---

## セキュリティモデル

rev_scraping v1.2.0 は外部境界全てで **fail-closed デフォルト**。

### 1. 3 階層脅威モデル

- **T1 — パッシブ攻撃(データ at rest、フォレンジック)**: cookie jar は XChaCha20-Poly1305 AEAD + プロファイル別 AAD で暗号化。鍵は cookie ファイル内には絶対書かない(OS keyring または Argon2id)。平文寿命は `Zeroizing<Vec<u8>>` のみ。`tracing` redaction layer + panic hook が cookie 形状の正規表現をログから除去。audit JSONL はアクションは記録するが値は残さない(regression test 済)。
- **T2 — アクティブ攻撃(通信傍受、DNS poisoning、VPN タイミング)**: `require_vpn=true` がデフォルト。起動時 probe + 継続 leak monitor(5〜300 秒、デフォルト 30 秒、初回 tick 即発火、leak 検出で **ラッチ停止**)。国マッチ gate(`vpn_country_mismatch` → `vpn_rotate`)。HRW スティッキープールでセッション安定性。`<KEY>_FILE` クレデンシャル resolver は `mode & 0o077 != 0` のファイルを reject。
- **T3 — コンテンツ層攻撃(prompt injection、サプライチェーン、Unicode covert channel)**: `stealth-sanitize` 5 層パイプライン。canary 20 ルール = Aho-Corasick(リテラル chat-template token)+ `regex::RegexSet`(shape ルール)。`<<<UNTRUSTED_CONTENT origin=… sanitize_id=NONCE>>>` envelope(64 ビット forgery-resistant nonce)。

### 2. 暗号スタック

- **アルゴリズム**: XChaCha20-Poly1305 AEAD(24 バイト nonce、32 バイト鍵)。192 ビット nonce で randomly chosen nonce 衝突は事実上ゼロ。ChaCha20 はソフトウェアで定数時間動作(AES-NI 依存なし)。
- **AAD バインディング**: `rev_scraping:stealth-auth:v1:<profile>[:<aad_context>]`。AAD 不一致 → `AuthStoreError::BadKeyOrTamper`、profile クロス試行 → `AuthStoreError::ProfileHashMismatch`(cipher 実行前に拒否)。
- **エンベロープ**: `MAGIC "REVAUTH1" || version u16 || profile_hash[32] || nonce[24] || ciphertext`。
- **鍵ソース**: OS keyring(macOS Keychain / Linux `secret-service` / Windows DPAPI)。フォールバック `feature = "passphrase-only"` は Argon2id(`m=64 MiB, t=3, p=1`、32 バイト出力、16 バイト salt)。
- **systemd-creds**: TPM2 利用可能時は sealing、なければホスト master key。オペレータ設置の drop-in(`/etc/systemd/system/rev-stealth-mcp.service.d/override.conf`)が unit start 時に load。`${CREDENTIALS_DIRECTORY}/<name>` 配下 mode 0400 で露出。

### 3. `stealth-sanitize` パイプライン

5 層が以下の順で全 MCP ツール応答に適用される:

| 層 | 内容 | デフォルト(Balanced) |
|---|---|---|
| **L4 — Unicode strip** | NFKC 正規化 → zero-width(U+200B/C/D, U+2060, U+FEFF) strip → tag chars(U+E0000–E007F)strip → bidi override(U+202D/E, U+2066–9)strip。bidi 命中で Suspicious canary 発火。 | 常時 on |
| **L5 — length clamp** | field ごと 256 KiB(Strict: 64 KiB)/ 全体 512 KiB(Strict: 128 KiB)。超過時は 80% head + `[...TRUNCATED...]` + 20% tail。 | 常時 on |
| **L3 — canary 検出** | Aho-Corasick(リテラル chat-template token: `<\|im_start\|>`, `[INST]`, `<<SYS>>` …)+ `regex::RegexSet`(shape: `ignore previous instructions`, `### Instruction:`, `\bSYSTEM\s*[:>]`, `curl --data`, `data:text/html`, envelope forgery `<<<UNTRUSTED_CONTENT` …)。**20 ルール × 3 重大度**。 | Critical = `critical_fail_closed=true` のとき fail-closed · High = `[REDACTED:injection]` 置換 · Suspicious = report-only |
| **L2 — envelope wrap** | 各 string leaf を `<<<UNTRUSTED_CONTENT origin=… tool=… sanitize_id=NONCE>>> … <<<END_UNTRUSTED_CONTENT sanitize_id=NONCE>>>` で囲む。64 ビット hex nonce を call ごとに生成(forgery 防御)。 | 常時(aborted 時のみスキップ) |
| **L7 — `_meta.sanitize` レポート** | 全応答に `{schema_version, policy_name, mode, bytes_in, bytes_out, truncated, aborted, layers_applied, canary_hits, sanitize_id}` 添付。`canary_hits[]` には **id + severity + location のみ — マッチした生バイトは絶対に含めない**(descendant pointer leak 修正)。 | 常時 on |

**検出率**(v1.2.0 ゴールデンコーパス、悪意 20 + benign 20):Critical 100% (8/8)、High 100% (12/12)、誤検出は benign fixture あたり Suspicious ≤ 1。

**モード行列**:

| プリセット | モード | 使用先 |
|---|---|---|
| `Strict` | `Enforce`(Critical → payload null + `aborted=true`) | `auth_login_*` |
| `Balanced` | `Warn`(デフォルト、`critical_fail_closed=true`) | 大多数のツール |
| `PassThrough` | `Off` | 信頼内部 call のみ |

### 4. 厳密 UUID v4 検証

v1.2.0 以前、`SessionId` / `ProgressToken` は `#[serde(transparent)]` で `Uuid` を包んでいた。結果 `serde_json::from_str("\"00000000-0000-0000-0000-000000000000\"")` で version 0 / variant NCS のトークンが通っていた。v1.2.0 では **手書き `Serialize`/`Deserialize`** を経由:

```rust
fn is_strict_v4(u: &Uuid) -> bool {
    matches!(u.get_version(), Some(Version::Random))
        && u.get_variant() == Variant::RFC4122
}
```

**両条件必須** — `00000000-0000-4000-0000-000000000000`(v4 version、NCS variant)も明示的に reject。

### 5. Rate limit / idempotency / backoff

- **per-host トークンバケット** は `Instant`(モノトニック)ベース — 壁時計の調整では unblock されない。
- **`Retry-After` を `MAX_429_BACKOFF_SECS = 86400` で clamp** + `Instant::checked_add(...).unwrap_or(now)` のフォールバック。clamp なしだと `Retry-After: 18446744073709551615` で limiter が panic = プロセス DoS。
- **Idempotency `DashMap::remove_if` atomic 退避** で「naive expired-eviction が新しい record を消す」TOCTOU race を排除。

### 6. systemd hardening

`rev-stealth-mcp.service` には `NoNewPrivileges=yes` + `ProtectSystem=strict` + `ProtectHome=yes` + `PrivateTmp=yes` + `ProtectKernel{Tunables,Modules,ControlGroups}=yes` + `LockPersonality=yes` + `RestrictSUIDSGID=yes` が並ぶ。`ExecStart` は **`exec`** 必須(load-bearing — 旧版が抜けていて `/bin/sh` が cgroup PID 1 になりゾンビ回収が壊れていた)。

### 7. Acceptable Use Policy (AUP)

URL を取る全 sub-command の前で `aup::enforce` 実行。許可経路は 3 つ:

1. `--i-have-authorization` フラグ(stderr に warn 出力、オペレータ自己宣誓)。
2. `REV_SCRAPING_AUP_ACK` env が `SHA256("rev-scraping-aup:" + YYYYMMDD)[:8]` にマッチ — **当日限定有効**。
3. `~/.rev_scraping/authorized.toml` allow-list(`[[targets]]` ごとの `url_pattern` 正規表現)。

reject → exit 3 / `kind: "aup"`(非 retriable)。

---

## 機能カタログ

### 13 クレート

| クレート | 目的 | 主要型 |
|---|---|---|
| `stealth-core` | 共有 trait + Chromium ベースステルス launcher | `StealthError`, `ExitCode`, `StealthProfile`, `leak_guard` |
| `mobile-fp` | モバイル fingerprint プリセット | 6 プリセット: `iPhone15Pro/Max`, `iPadProM4`, `Pixel9Pro`, `Pixel8a`, `GalaxyS24Ultra`; `StealthLevel{Off,Low,Medium,High(default)}` |
| `obscura-bridge` | CDP shim + SSRF guard(obscura パッチ静的リンク) | `ObscuraBridge`, `BridgeError`, `BrowserOps`, `inject_cookies`, `validate_url` |
| `captcha-bypass` | reCAPTCHA v2/v3 / hCaptcha / Turnstile 研究(Node sidecar 経由) | `CaptchaKind`, `SolveRequest`、`sidecar` feature gate |
| `stealth-cf` | Cloudflare Turnstile 強度評価(defender 側) | `detect_from_html`, `CfEvaluator`, `ChallengeType` |
| `stealth-parse` | 適応 element relocate + SQLite WAL fingerprint cache | `fingerprint_from_html`, `ElementFingerprint`, `Relocator`, `ParseStore` |
| `stealth-sites` | ドメイン別 TOML Site Recipe ストア | `SiteRecipe`, `SiteMeta`, `SiteRecipeStore`, `Endpoint`, `AuthRecipe` |
| `vpn-rotate` | VPN IP ローテーション(Surfshark/Gluetun)+ leak monitor + HRW pool | `RotationStrategy`, `InstancePool`, `LeakMonitor`, `CredentialResolver` |
| `stealth-auth` | 認証 cookie 暗号化保管 + `rev-auth` バイナリ | `AuthStore`, `AuthCookieJar`, `Cookie` |
| `stealth-agent-contracts` | クレート横断契約型 | `ErrorEnvelope`, `ErrorKind`(26 variants), `SessionId`/`ProgressToken`(UUID v4 strict), `ToolRateLimiter`, `IdempotencyKey`, `ProgressTracker` |
| `stealth-sanitize` | prompt injection 防御(5 層パイプライン) | `sanitize_for_agent`, `SanitizePolicy`, `Mode`, `SanitizationReport`, `CanaryHit` |
| `stealth-cli` | `rev-stealth` CLI フロントエンド | clap sub-command + `config_io/`(schema/validate/writer/lev/migration) |
| `stealth-mcp` | MCP stdio JSON-RPC 2.0 サーバ + `gen_reference` バイナリ | 16 ツール、auth_*/recipe_*/session_* は in-process、それ以外は subprocess |

### `rev-stealth` CLI sub-command ツリー

```
rev-stealth
├── doctor         リーク防止プリフライト(kill-switch / DNS / IPv6 / WebRTC)
│                  flags: --vps(9 deep check), --deep, --output-format {json|text}
├── spider         AUP gate + 任意 CF eval + 適応 relocate
├── relocate       fingerprint 済 element を新 HTML/URL で再特定
├── cf-evaluate    Cloudflare Turnstile 強度評価
├── auth           {login,list,show,delete,status,refresh}
├── measure        ローカル fingerprint 診断
│                  flags: --enable-external, --enable-egress-probe(feature: vps-egress-probe)
├── browser        stealth browser launch / stealth-test sweep
├── vpn            rotate / status(Surfshark + Gluetun)
├── captcha        CAPTCHA bypass(研究、デフォルト dry-run)
├── config
│   ├── show       マージ済の effective config(4 層、secret は <redacted>)
│   ├── paths      設定ファイルパス + 存在 + mode リスト
│   ├── validate   strict validate、違反で exit 1 + issue リスト
│   ├── diff       templates/policy.toml との unified diff
│   ├── get <key>  ドット表記キーを解決(例: policy.require_vpn)
│   ├── init       ~/.rev_scraping/{policy,authorized}.toml + sites/ 初期化
│   ├── set <k> <v> --target {policy|authorized}  作成時 0600 で atomic 書込
│   ├── edit       $EDITOR で開く(fallback vi)、validate-then-commit
│   ├── migrate    schema_version マイグレート(LATEST=1)
│   ├── history    .bak.<epoch> backup を新しい順に列挙
│   ├── rollback <name>  backup を復元(現行は新 .bak.<epoch> として保存)
│   ├── gc --keep N      古い backup を削除(default 5)
│   └── profile
│       ├── list
│       ├── create <name>  名前パターン [A-Za-z0-9_-]{1,64}
│       ├── switch <name>  シェル `export REV_SCRAPING_HOME=…` 行を print
│       └── delete <name> --yes  active profile は refuse、best-effort zero-overwrite shred
└── hermes
    ├── install [--prefix <dir>] [--source <dir>] [--force]
    ├── uninstall [--prefix <dir>]
    └── verify [--prefix <dir>] [--no-python-check]
```

### 環境変数(主要)

#### 設定パス / profile
- `REV_SCRAPING_HOME` — 設定ベース上書き(default `~/.rev_scraping`)
- `REV_SCRAPING_PROFILES_ROOT` — profile レジストリルート(P6.5 で `HOME` から分離)
- `REV_SCRAPING_PROFILE` — active profile 名(Hermes ホワイトリスト経由)
- `REV_SCRAPING_POLICY`, `REV_SCRAPING_AUTHORIZED`, `REV_SCRAPING_AUTH_DIR` — パス上書き

#### policy / guard
- `REV_SCRAPING_REQUIRE_VPN=1` — `require_vpn` 強制(最優先)
- `REV_SCRAPING_AUP_ACK` — 日付ローテ AUP ack hash
- `REV_SCRAPING_ALLOW_LOOPBACK` — loopback ターゲット許可(dev/test 限定)
- `REV_SCRAPING_CONFIG_LENIENT` — strict validate 緩和
- `REV_SCRAPING_AUTH_PASSPHRASE` — passphrase-only モード鍵供給

#### VPN
- `VPN_USER_FILE`, `VPN_PASSWORD_FILE` — `<KEY>_FILE` 優先(systemd-creds)
- `VPN_USER`, `VPN_PASSWORD` — 平文(本番では避ける)
- `VPN_INSTANCES` — `name:proxy_port:control_port,...`(policy 上書き)

#### 認証ヘルパー
- `REV_AUTH_BIN`, `REV_AUTH_CHROME_BIN`, `REV_AUTH_AUTO_XVFB`, `REV_AUTH_DISPLAY`, `REV_AUTH_HEADLESS`
- `REV_OBSCURA_BIN` / `OBSCURA_BIN` — obscura subprocess パス
- `REV_STEALTH_CHROME` — Chrome 上書き(stealth-cli 側)
- `REV_STEALTH_SIDECAR` — captcha-bypass Node sidecar パス

#### その他
- `REV_SCRAPING_MCP_BIN` — Hermes adapter の `stealth-mcp` パス上書き
- `REV_STEALTH_BIN` — MCP 側 CLI バイナリ上書き
- `REV_STEALTH_EGRESS_PROBE_URL` — `measure --enable-egress-probe` の probe URL
- `EDITOR` — `config edit` の fallback(default `vi`)
- `RUST_LOG` — `tracing-subscriber` EnvFilter

---

## 動作の流れ(シーケンス)

### フロー A — `auth_login_start` → `auth_login_complete`

```
1. MCP 受信   tools/call {name: auth_login_start, args: {profile, url, ...}}
2. server.rs  is_auth_tool → handle_auth_tool
3. rev-auth   auth_aup::enforce(domain, url)            → AUP gate
4. rev-auth   ObscuraBridge::validate_url(login_url)    → SSRF guard
5. rev-auth   publicsuffix で eTLD+1 正規化
6. rev-auth   prepare_vpn_context().await
                ├─ policy.toml ロード
                ├─ InstancePool::pick(session_id) — HRW スティッキー
                ├─ leak_guard::probe_all(instances, expected_country)
                └─ LeakMonitor::spawn(5–300s, default 30s, 初回 tick 即発火)
7. rev-auth   resolve_login_display_mode
                ├─ --headless → Headless
                ├─ --xvfb → Xvfb(<user_data_dir>/rev-auth-xvfb-run.sh @0700 自動生成)
                ├─ Linux + DISPLAY 未設定 + REV_AUTH_AUTO_XVFB=1 → Xvfb
                └─ それ以外 → Headed(macOS Auto)
8. rev-auth   chromiumoxide::Browser::launch — オペレータが対話 login
9. MCP polling auth_login_complete が <TMPDIR>/rev-auth-<token>.complete を待機
                ├─ timeout → ErrorKind::AuthSessionExpired + retry_after_ms
                └─ helper 完了 → 続行
10. rev-auth  page.get_cookies() via CDP
                ├─ filter_cdp_cookies → eTLD+1 のみ
                ├─ all_cookies_expired → exit 4
                └─ それ以外:
                     ├─ crypto::encrypt(XChaCha20-Poly1305 + 24 バイト OsRng nonce
                     │   + AAD: rev_scraping:stealth-auth:v1:<profile>)
                     ├─ keystore.set(service=rev_scraping.stealth_auth, account=cookie-jar:<profile>)
                     └─ audit::append_jsonl(start + success イベント)
11. teardown  browser.close → sleep(CHROME_TEARDOWN_FLUSH_MS=1500ms) → browser.wait
                              → handler_task.abort → profile_dir.cleanup
12. MCP 包む  sanitize_structured("auth_login_complete", result) → _meta.sanitize → JSON-RPC 送信
```

### フロー B — `spider`

```
1. MCP 受信   tools/call {name: spider, args: {url, session_id?, ...}}
2. server.rs  in-process ではない → build_cli_argv("spider", args) → rev-stealth subprocess
3. rev-stealth policy ロード → InstancePool::pick(session_id) → leak_guard::probe_all
                leak で exit 7(StealthError::Leak)
4. rev-stealth ObscuraBridge 起動 → CDP shim → SSRF guard
5. rev-stealth 任意 stealth-cf 評価 → challenge 処理
6. rev-stealth HRW で選んだ VPN proxy 経由で fetch
7. rev-stealth recipe に stable_id があれば stealth-parse で relocate
8. server.rs  stdout キャプチャ(JSON parse、失敗時は {"raw": "..."})
9. server.rs  sanitize_structured("spider", body)
                L4 → L5 → L3 → L2 → L7
                policy_for_tool("spider") = Balanced(Warn モード、256/512 KiB)
10. server.rs JSON-RPC result emit
                content + structuredContent + _meta.sanitize
                + isError = !out.status.success() + exitCode
              stderr も別途 sanitize
```

### フロー C — VPN leak-monitor ループ

```
1. systemd が rev-stealth-vpn@N → docker compose up -d で Gluetun コンテナ起動
2. stealth-cli  vpn_guard::run_startup_probe
                  ├─ require_vpn=false → Ok(None)
                  ├─ require_vpn=true + instance なし → Err(Leak) → exit 7
                  └─ probe_all(instances, expected_country) → spider envelope に JSON 添付
3. LeakMonitor::spawn(instances, expected_country, interval)
   interval は [5s, 300s] にクランプ、default 30s
   初回 tick 即発火
4. tick ごと: probe_once → ProbeVerdict::{Healthy, Leak{instance, reason}}
5. Leak 検出:
     leak_detected=true(ラッチ、以降 polling 停止)
     notify_waiters() via tokio::sync::Notify
     state.reason / failed_instance 書込
6. fetcher(caller)が tokio::select! で work vs notify を競争:
     notify.notified() → bridge.force_kill() → return Err(StealthError::Leak(reason))
     work_future       → 続行
7. InstancePool::mark_failure(name) 連続 3 回 → 60 秒除外
   mark_success でリセット、all_failed() が fail-closed sentinel
8. systemd の Restart=on-failure RestartSec=5s が doctor/vpn/MCP unit を再起動
```

### フロー D — `stealth-sanitize` 5 層パイプライン

```
入力: serde_json::Value(ツールの生出力)
   │
   ▼
[L4 unicode] NFKC → zero-width strip → tag-char strip → bidi-override strip
              bidi 命中 → Suspicious canary 発火
   │
   ▼
[L5 clamp] field ごと 256 KiB / 全体 512 KiB(Balanced)
            超過 → 80% head + "[...TRUNCATED...]" + 20% tail
            report.truncated = true
   │
   ▼
[L3 canary] Aho-Corasick(リテラル)+ RegexSet(shape) → 20 ルール
              Critical(Enforce + critical_fail_closed)→ マッチ領域削除
                                                       + payload = Value::Null
                                                       + report.aborted = true
              High        → マッチを "[REDACTED:injection]" に置換
              Suspicious  → 記録のみ
              report.canary_hits[] = {id, severity, location}
                            マッチした生バイトは絶対に含めない
   │
   ▼  (aborted ならスキップ)
[L2 envelope] 各 string leaf を以下で包む:
              <<<UNTRUSTED_CONTENT origin=<ctx.origin> tool=<ctx.tool>
                 sanitize_id=<64ビットhex nonce>>>>
              ...sanitize 済 content...
              <<<END_UNTRUSTED_CONTENT sanitize_id=<同じ nonce>>>>
              forgery 防御: body は nonce を知らずに END マーカを偽造できない
   │
   ▼
[L7 meta] _meta.sanitize 添付 = {schema_version, policy_name, mode,
                                  bytes_in, bytes_out, truncated, aborted,
                                  layers_applied[], canary_hits[], sanitize_id}
   │
   ▼
出力: SanitizedEnvelope { payload, report }
```

---

## ユースケース

### 1 — 認証必要会員サイトを定期スクレイプ

```bash
rev-stealth config init
cp templates/sites/example.com.toml ~/.rev_scraping/sites/myfinance.toml
$EDITOR ~/.rev_scraping/sites/myfinance.toml   # site.domain, [auth], [api.endpoints]

# 2-phase login(オペレータが起動したブラウザで一度だけ対話 login)
rev-stealth auth login --profile myfinance_main --url https://myfinance.example/login

# 次の cron 実行前に鮮度確認
rev-stealth auth status --profile myfinance_main --format json
# → Valid | ExpiringSoon | ExpiringCritical | PartiallyExpired | AllExpired | Missing

# cron(平日 09:00 JST)
# 0 9 * * 1-5 /usr/local/bin/rev-stealth spider \
#   --url https://myfinance.example/portfolio --profile myfinance_main --format json \
#   >> /var/log/rev-stealth/myfinance-$(date +\%F).jsonl
```

spider 応答(抜粋):

```json
{
  "ok": true,
  "operation": "spider",
  "result": {
    "session_id": "7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01",
    "recipe": {"domain": "myfinance.example", "hits": ["/portfolio"]},
    "api_response": {"status": 200, "body_sha256": "..."}
  },
  "_meta": {"sanitize": {"schema_version": 1, "canary_hits": [], "aborted": false}}
}
```

### 2 — Turnstile 保護下の JSON API

```json
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{
  "name":"cf_evaluate","arguments":{"url":"https://protected.example/login"}}}

{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{
  "name":"spider","arguments":{
    "url":"https://protected.example/api/quotes",
    "cf_evaluate": true,
    "session_id": "7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01"}}}
```

`session_id` 共有で `spider` が challenge cookie を idempotency window 内で再利用。`kind:"captcha"` 失敗は **非 retriable** — 認証 profile に切替えるか、out-of-band で解く。

### 3 — VPS を AI エージェントの 24/7 の目として使う

```bash
sudo systemctl enable --now rev-stealth-mcp rev-stealth-doctor.timer
sudo systemctl enable --now rev-stealth-vpn@1 rev-stealth-vpn@2 rev-stealth-vpn@3
tailscale up --ssh   # オプション private mesh、rev_scraping には同梱せず
```

ワークステーション側 Claude Desktop 設定(SSH 越しに MCP サーバ起動):

```json
{"mcpServers": {"rev-scraping-vps": {
  "command": "ssh",
  "args": ["operator@vps.tailnet.ts.net", "sudo", "-u", "rev-stealth",
           "/usr/local/bin/stealth-mcp"]}}}
```

健康診断タイマが 30 分ごとに発火、`/var/log/rev-stealth/doctor.jsonl` に JSON 追記。leak 検出 → exit 7 → unit `failed` → オペレータアラート(配線は自分でやる)。

### 4 — 同一サイトを JP/US/EU の 3 国 exit IP で並行スクレイプ

```json
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{
  "name":"vpn_rotate","arguments":{
    "provider":"surfshark","region":"JP","strategy":"lazy-on-fail",
    "reason":"warmup JP exit for nikkei feed"}}}
```

成功:

```json
{"ok":true,"operation":"vpn.rotate",
 "result":{"instance":"vpn-1","exit_ip":{"country":"JP","asn":"AS9009"},"reason":"warmup ..."}}
```

VPN 関連エラー(closed set): `vpn_not_configured`(非 retriable)、`vpn_all_instances_failed`(retriable)、`vpn_country_mismatch`(retriable、別 region でリトライ)。

### 5 — prompt injection サニタイザの動作確認

```bash
./target/release/stealth-mcp <<'EOF' | jq '.result._meta.sanitize'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"canary","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"spider","arguments":{"url":"https://canary-fixtures.local/critical-01"}}}
EOF
```

期待出力(Critical canary 命中):

```json
{
  "schema_version": 1,
  "aborted": true,
  "canary_hits": [{"id": "C-IGNORE-PREV", "severity": "Critical", "location": "$.result.html"}]
}
```

envelope に `isError: true` 付与、`env.message` は保持(生バイトは含まない — canary ID のみ)。

### 6 — Profile 切替で dev/staging/prod 同居

```bash
rev-stealth config profile create dev
rev-stealth config profile create staging
rev-stealth config profile list

rev-stealth config profile switch dev          # export 行 print — 取り込む(下記参照)
export REV_SCRAPING_HOME="$HOME/.rev_scraping/profiles/dev"
rev-stealth config show --format json | jq '.profile, .config_root'
```

注意:
- **レジストリルート**(`REV_SCRAPING_PROFILES_ROOT`)と**アクティベーションルート**(`REV_SCRAPING_HOME`)は意図的に分離。
- `switch` はレジストリポインタの更新のみ — シェル側の `export REV_SCRAPING_HOME=…` が実際の activation。
- active profile の delete は refuse される。先に switch する。

### 7 — スキーマ migration

```bash
rev-stealth config validate --format json
rev-stealth config migrate --dry-run
rev-stealth config migrate           # atomic 0600 at creation、chmod-after race なし
rev-stealth config history
rev-stealth config rollback --to <history_id>
rev-stealth config gc                # default --keep 5
```

migration ループは bounded(無限連鎖防止)。

---

## 競合比較

凡例: ✅ first-class · 🟡 partial / plugin / オペレータ任せ · ❌ 非対応

| 観点 | rev_scraping v1.2.0 | gocrawl | Scrapling 0.4 | obscura | Playwright | Puppeteer | Crawl4AI 0.8 | Browserless | Bright Data Unlocker |
|---|---|---|---|---|---|---|---|---|---|
| 言語 / ランタイム | Rust workspace(13 crate) | Go | Python | Rust (V8) | TS/Py/Java/.NET | TS / Node | Python | マネージド (Node) | SaaS API |
| ステルス(CDP patch + FP) | ✅ obscura CDP shim、11+ field patch、WS 警告=0 | ❌(HTTP のみ) | ✅ Patchright + humanized input | ✅ session 別 GPU/screen/canvas/audio/battery ランダム化 | 🟡 `playwright-stealth` plugin、**2023-03 以降メンテ停止** | 🟡 community `puppeteer-extra` | 🟡 Playwright 継承 | ✅ BrowserQL / `/unblock` | ✅ AI unlocking(内部不透明) |
| VPN 必須ゲート | ✅ Surfshark + Gluetun + 3 instance HRW + leak monitor + exit 7 | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 residential-proxy add-on | 🟡 プロキシが本体 |
| 暗号化 credentials | ✅ XChaCha20-Poly1305 + OS keyring + Argon2id fallback | ❌ | 🟡 fetcher 経由 cookie、暗号化なし | 🟡 標準 CDP storage | ❌ `storageState.json` **平文** | ❌ `userDataDir` **平文** | ❌ | 🟡 サーバ側不透明 | N/A |
| MCP ネイティブ | ✅ stdio JSON-RPC 2.0、**16 ツール × 入出力スキーマ** | ❌ | ✅ MCP サーバ (v0.4) | 🟡 3rd-party wrapper | ✅ Microsoft 公式 | 🟡 コミュニティ | ✅ 4 ツール | ✅ `mcp.browserless.io` ホスト | ❌ |
| **prompt injection 防御** | ✅ `stealth-sanitize` 5 層・canary 20・Critical/High 100% 検出・`<<<UNTRUSTED_CONTENT>>>` envelope・`_meta.sanitize` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ raw markdown を LLM へ(これが売り) | ❌ | ❌ raw HTML/markdown |
| closed-enum error contract | ✅ 26 ErrorKind + retriable + hint + UUID v4 strict | ❌ Go 文字列 | ❌ Python 例外文字列 | 🟡 Rust `Result`、カタログなし | ❌ | ❌ | ❌ HTTP status + JSON | 🟡 | 🟡 |
| idempotency(Stripe 流) | ✅ キー + `Retry-After` clamp | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 host-side rate limit のみ | 🟡 concurrency unit のみ | 🟡 quota のみ |
| 本番デプロイ | ✅ systemd 5 unit + systemd-creds + Xvfb 自動 wrap | 🟡 binary | 🟡 pip | 🟡 binary | 🟡 | 🟡 | ✅ Docker + self-host guide | ✅ SaaS / self-host license | ✅ SaaS |
| ライセンス | MIT | BSD-3 | BSD-3 | Apache-2.0 | Apache-2.0 | Apache-2.0 | Apache-2.0 | proprietary | proprietary |
| 直近活動(2026-05) | v1.2.0 current | last tag **2021** | v0.4 (2026-02) | active | active | active | active | active SaaS | active SaaS |

### 軸別詳細(抜粋)

**ステルス** — `playwright-stealth` は 2023 年 3 月以降メンテ停止 (Chrome 109–112 時代)。2026 年の anti-bot stack は TLS / HTTP/2 SETTINGS フレーム指紋を **JavaScript 実行前** に取るため、JS 層の `navigator.webdriver = undefined` 修正は無効化されている。rev_scraping は obscura の CDP shim を Rust クレートとして静的リンク(プラグイン drift なし)。ただし Browserless / Bright Data の residential IP 多様性には勝てない(150M IP プールではなく VPN)。Akamai Bot Manager の厳格 ASN レピュテーションが相手なら SaaS unlocker のほうが現実的。

**AI エージェントネイティブ MCP** — rev_scraping が賭けているのは **厳密スキーマ + closed `ErrorEnvelope`**。この空間の MCP サーバはほぼ raw markdown か HTTP-shape error を返してきて、consumer 側で `if "rate limit" in str(err)` のグルーコードが量産される。rev_scraping は `ErrorKind::RateLimited{retry_after_ms}` を typed envelope で返す。typed agent consumer なら効く、ワンオフスクリプトには過剰。

**prompt injection 防御** — これが**最大の差別化**。**表中の他全ツールがやっていない**。Crawl4AI 公式 MCP ドキュメントですら「prompt injection は agent 側の問題で、モデル alignment で扱え」とサーバ側非関与の方針を明言。canary テスト済 sanitizer + マーカ envelope は銀の弾丸ではないが、「silent compromise」を「logged + rejected + reviewable」に変える。**書き込み権限**を持つエージェント(file write、tool call、MCP fan-out)では、ステルスよりこれが効く。

### rev_scraping が *間違った* 選択になるケース(正直版)

| ユースケース | 代わりに | 理由 |
|---|---|---|
| 1,000 万 URL 級分散クロール | Crawl4AI / Scrapy 系列 | single-machine、分散ワークキュー無し |
| RAG 用 HTML → Markdown 取込 | Crawl4AI / Bright Data | Crawl4AI の本業はそれ |
| GUI 管理ブラウザファーム / live debug | Browserless / Bright Data | rev_scraping は CLI + systemd、fleet dashboard 無し |
| 多言語クライアント SDK | Playwright (TS/Py/Java/.NET) | rev_scraping は Rust + Python (Hermes) のみ |
| コミュニティサイズ依存プロジェクト | Playwright / Puppeteer | rev_scraping は単一ベンダ、Microsoft / Google エコシステムには勝てない |

**ワンライン要約**: rev_scraping が正解になるのは、**typed AI エージェントが認証必要会員サイトを単一ハードン化 VPS から駆動し、prompt-injection safe な content 配信と egress-IP-leak 保証が非交渉条件である**ワークロード。

---

## 設定

### ファイルレイアウト(`~/.rev_scraping/`)

```
~/.rev_scraping/                          # デフォルトベース(上書き: REV_SCRAPING_HOME)
├── policy.toml                           # mode 0600 — VPN / require_vpn / instance
├── authorized.toml                       # mode 0600 — AUP allow-list
├── sites/                                # mode 0700 — ドメイン別 SiteRecipe TOML
├── sessions/                             # mode 0700 — HRW スティッキー session binding
└── profiles/                             # mode 0700 — マルチ環境レジストリ
    ├── dev/
    ├── staging/
    └── prod/
```

### `policy.toml` のキモ

```toml
schema_version = 1                        # bounded migration(LATEST=1)
require_vpn = true                        # fail-closed デフォルト
vpn_required_country = "JP"               # ISO-2 / alias table

[[vpn_instances]]
name = "vpn-1"
http_proxy_port = 18801
control_port = 18831

[proxies.gluetun]
strength = "high"
url = "http://${VPN_USER}:${VPN_PASSWORD}@vpn-1:18801"   # ${VAR} placeholder 必須
                                                          # 平文 user:pass はロード時 reject
auth_env = "VPN_USER"
no_proxy = "127.0.0.1,localhost"

[fallback_chain]
auto = ["gluetun", "direct"]              # tier 順、"auto" 自体は禁止
```

`require_vpn` 優先順位(高→低): env `REV_SCRAPING_REQUIRE_VPN=1` > `--require-vpn` フラグ > `--allow-no-vpn` フラグ > `policy.toml::require_vpn` > built-in デフォルト `true`。

`ConfigWriter` は `OpenOptions::new().write(true).create_new(true).mode(0o600).open()` で書き込む — 権限は**作成時にセット**、chmod-after の race window はゼロ。

---

## FAQ・トラブルシューティング

**Q: `rev-stealth doctor` が exit 7。**
A: VPN tunnel down / leak 検出。`systemctl status rev-stealth-vpn@1` と `docker compose logs vpn-1`。`doctor --output-format json` で `kill_switch` / `dns_lock` / `webrtc_guard_present` / `exit_ip_ok` のどれが false か特定。

**Q: cookie が消える / `auth_status` が `Missing` を返す。**
A: keyring permission。macOS: `security find-generic-password -s rev_scraping.stealth_auth`。Linux: `secret-tool search service rev_scraping.stealth_auth`。profile 切替後に `export REV_SCRAPING_HOME=…` 忘れてないか?

**Q: VPS で Chrome が起動しない(`Failed: no $DISPLAY`)。**
A: 自動 Xvfb が発火していない。`REV_AUTH_AUTO_XVFB=1` + `xvfb-run` が PATH 上、または `--with-vnc-fallback`(opt-in xvfb-vnc service)+ drop-in `Environment=DISPLAY=:99`。

**Q: MCP tool call が `_meta.sanitize.aborted: true` + `isError: true` を返す。**
A: Critical canary 検出。`canary_hits[].id` + `severity` でどのルールか確認。Critical は fail-closed(Enforce + `critical_fail_closed`)。誤検出疑い(security blog で `[INST]` を引用しているような場合)なら `Preset::Balanced` で fetch しなおす。

**Q: `config profile switch dev` しても何も変わらない。**
A: `switch` はレジストリ更新だけ、`REV_SCRAPING_HOME` はシェルごと。print された `export` 行をシェルで実行(または新シェル)。`config show --format json | jq '.profile, .config_root'` で確認。

**Q: `vpn_rotate` が `kind: "vpn_country_mismatch"` を返す。**
A: 指定 region が pool に無い。retriable — 別 region でリトライ。`docker compose logs vpn-N` で Gluetun handshake 詳細。

**Q: `recipe_import` が `kind: "recipe_invalid"` / secret-rejected。**
A: payload に secret 形状の field(token / password 系)。export → import 前に削除。v1.2.1 で strict mode 追加予定(field が canary を踏む recipe を refuse)。

**Q: `tools/call` が `kind: "aup"` を返す。**
A: URL が `authorized.toml` の allow-list に無い。または SSRF guard 失敗(`kind: "ssrf"` — loopback / RFC1918 / link-local)。両方 非 retriable。

**Q: Hermes プラグインで 16 ツール出ない。**
A: `stealth-mcp` バイナリが未ビルドか PATH に無い。`REV_SCRAPING_MCP_BIN` を絶対パスで指定。`cd dist/hermes/rev-scraping-mcp && python3 -m unittest discover tests -v` で adapter smoke。

**Q: `LoadCredentialEncrypted=` が unit start で失敗。**
A: systemd < 252、または `/etc/credstore.encrypted/` 不在。`systemctl --version` 確認、`setup-credentials.sh` 再実行。

**Q: `auth_login_complete` 2 回目が `kind: "auth_session_not_found"`。**
A: `session_token` は **single-use**。`auth_login_start` をやり直して新トークン取得。

**Q: `doctor --vps` JSON が予想外に array 形式。**
A: v1.2.0 で top-level array に変更(security fix)。旧 `{doctor, vps}` object 形式はもう無い。

---

## 既知の制限と v1.2.1 バックログ

[`RELEASE_NOTES_v1.3.0.md`](RELEASE_NOTES_v1.3.0.md) からそのまま転記、adopter が残留リスクを正確に把握できるように:

- **L1 — ammonia HTML scrub。** v1.2.0 は HTML サニタイズなし。隠しテキスト (`<span style="display:none">`)、可視フローに relocate された JSON-LD ブロック、SVG `<script>` ペイロードは LLM にそのまま届く。
- **L6 — URL scheme allowlist + length cap。** `javascript:`, `file:`, 巨大 `data:` URL は URL 層でフィルタされない。
- **多言語 canary。** canary 正規表現セットは英語のみ。JP / ZH / KR / RU パックは v1.2.1 バックログ。
- **Hermes Python ミラー sanitizer。** sanitize は Rust 側のみ。Python adapter で再シリアライズすると bypass される。
- **`recipe_import` strict mode。** import した recipe は canary engine を通っていない(T3 サプライチェーン経路)。
- **Enforce モードのデフォルト切替。** v1.2.0 は `Warn` デフォルト + `Critical-only` fail-closed。v1.2.1 で Enforce デフォルトに切替予定。
- **L2 envelope の re-scan idempotence。** sanitize 済み payload を再 sanitize すると、envelope marker 自身が canary パターンにマッチして再発火する。
- **サイト別 policy 上書き。** 現状 per-tool policy が唯一の粒度。v1.2.1 で domain キーの per-target 上書きを追加。
- **改ざん検出 audit log。** v1.2.0 の audit JSONL は HMAC chain / ローテーション / TPM sealing 無し。
- **OS サポート。** macOS / Linux のみ。Windows は ACL TODO、v1.2.0 本番非対応。
- **スコープ。** single-machine。分散クロールは対象外。
- **既知 flake。** `auth_login_with_allow_no_vpn_skips_probe` が `--test-threads=4` で process-wide `REV_SCRAPING_REQUIRE_VPN` env レース。CI は `--no-fail-fast` で吸収。

---

## 開発プロセス

v1.2.0 は **30 sub-phase** を 6 lane (A: VPS / B: Config UX / C: Agentability / D: Hermes / E: Docs+CI / F: Injection defense) に分割し、Opus 4.7-high コーダー × Codex gpt-5.5-high レビュアーのループで着地:

- canonical wrapper: `scripts/codex-wrapper.sh --role reviewer --stdin`(raw `codex exec` 禁止)。
- スライス ≤ 2 KB / レビュー max 3 round / slice。
- evidence: `.agent/active/prompts/*.md`(commit 済)+ `REV_HARNESS_DELEGATION_METRIC` 行 / round。

CI(8 job、[`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

- `rust-test` — `cargo test --workspace --locked --no-fail-fast`
- `rust-clippy` — `cargo clippy --workspace --all-targets -- -D warnings`
- `rust-fmt-check` — `cargo fmt --check`
- `mcp-schema-lint` — `cargo run -p stealth-mcp --bin gen_reference -- --check`(鮮度ゲート)
- `config-cli-smoke` — `rev-stealth config init --target=policy --non-interactive --force` を tmpdir で
- `hermes-contract` — `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`(20 PASS)
- `systemd-analyze` — `systemd-analyze verify dist/systemd/system/*.{service,timer}`(Ubuntu 24.04 / systemd 255)
- `headless-auth` — placeholder skip(Xvfb 依存、将来の Linux ジョブ用)

### テストスイート

- **ワークスペース**: 911 PASS / 0 fail / 38 ignored(`cargo test --workspace --no-fail-fast`)
- **Python (Hermes)**: 20 PASS / 0 fail
- **Sanitize ゴールデンコーパス**: 悪意 20 + benign 20 → Critical 100%、High 100%、FP ≤ 1 Suspicious / page

### v1.2.0 で潰した security fix 一覧

1. UUID v4 偽造(transparent deserialize)
2. `Retry-After: u64::MAX` での Instant overflow DoS
3. Idempotency 期限切れ退避の TOCTOU race
4. `ConfigWriter` chmod-after の権限暴露窓
5. systemd `ExecStart` の `exec` 欠落(zombie 化)
6. docker-compose `${VPN_USER}` 補完の干渉
7. `doctor --vps` JSON 形(`{doctor, vps}` → top-level array)
8. Hermes Python `readline()` deadline bypass
9. Hermes `start()` の fd leak(handshake-fail 時)
10. Hermes `env=` コンストラクタが `filter_env` を bypass(smuggling)
11. `auth.rs` CLI `--python-check=false` parse regression
12. `stealth-sanitize` の descendant pointer key-leak(canary レポート経由)

### ErrorEnvelope — 26 種 closed `ErrorKind` 完全表

| # | wire 名 | 発生条件 | retriable | hint |
|---|---|---|---|---|
| 1 | `aup` | AUP allow-list 違反 | no | AUP allow-list と robots.txt 確認 |
| 2 | `ssrf` | private/internal ターゲット | no | loopback/RFC1918/link-local には接続しない |
| 3 | `vpn_leak` | VPN egress で IP 漏れ可能性 | yes | VPN を上げ doctor 再実行、rotate |
| 4 | `rate_limit` | per-host / global rate 超過 | yes | `retry_after_ms` を honor |
| 5 | `timeout` | budget 超過 | yes | budget を増やして再試行 |
| 6 | `captcha` | bypass 不可な captcha | no | 認証フローに切替か out-of-band 解決 |
| 7 | `auth` | 認証/認可失敗 | no | `auth_login_start` やり直し |
| 8 | `not_found` | リソース不在 | no | URL / recipe / profile 確認 |
| 9 | `validation` | 入力検証失敗 | no | `message` を見て field 修正 |
| 10 | `network` | transport 失敗 | yes | backoff 付きリトライ |
| 11 | `internal` | 未分類内部エラー | no | ログ採取、bug 報告 |
| 12 | `recipe_not_found` | recipe 検索失敗 | no | `recipe_list` で確認 |
| 13 | `recipe_invalid` | recipe スキーマ/セマンティクス無効 | no | 修正して re-import |
| 14 | `auth_session_expired` | `auth_login_complete` の polling が timeout | yes | `auth_login_start` やり直し |
| 15 | `auth_session_not_found` | `session_token` 未知 | no | 新規 login flow 開始 |
| 16 | `auth_session_pending` | helper 未完了 | yes | 少し待って再 poll |
| 17 | `vpn_not_configured` | rotation 要求だが backend 未設定 | no | policy.toml で設定 |
| 18 | `vpn_all_instances_failed` | 全インスタンス失敗 | yes | 待機、provider 確認 |
| 19 | `vpn_country_mismatch` | 解決した国 ≠ policy | yes | 別 region でリトライ |
| 20 | `cdp_protocol` | CDP 想定外エラー | yes | リトライ、Chrome version 確認 |
| 21 | `cdp_disconnected` | CDP WebSocket 切断 | yes | リトライ、browser 再起動 |
| 22 | `cdp_injection_failed` | stealth JS inject 失敗 | yes | 再実行、obscura 確認 |
| 23 | `browser_crashed` | headless browser crash | yes | リトライ、再現すれば core dump 採取 |
| 24 | `browser_not_found` | バイナリが PATH に無い | no | Chrome インストールか `OBSCURA_BIN` 設定 |
| 25 | `cookie_decrypt_failed` | on-disk cookie 復号失敗 | no | auth profile 再作成 |
| 26 | `aborted` | caller によるキャンセル | yes | 必要なら resume |

---

## ライセンス

MIT。[LICENSE](LICENSE) 参照。

### 謝辞

- **obscura** ([h4ckf0r0day/obscura](https://github.com/h4ckf0r0day/obscura)) — CDP shim の基盤。
- **Scrapling** ([D4Vinci/Scrapling](https://github.com/D4Vinci/Scrapling)) — 適応 selector 復元の設計(BSD-3 参考)。
- **chromiumoxide** — CDP transport。
- **Gluetun** — Surfshark / WireGuard コンテナ。
- **systemd-creds + TPM2** — クレデンシャル sealing。

単独人間オペレータ + Opus 4.7-high コーダー + Codex gpt-5.5-high レビュアーの並列オーケストレーションで約 8 時間で着地。
