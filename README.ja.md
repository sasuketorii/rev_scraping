<!--
  rev_scraping — README.ja.md (日本語版)
  English version: README.md
  正直さ重視: すべての機能を「動く / feature-gated / roadmap」で明示する。
-->

# rev_scraping

> **AI エージェントネイティブで、ステルス志向の Web スクレイピング・ツールキット。すべて Rust 製。**
> 単一の `rev-stealth` CLI と MCP サーバが同じ操作を公開するので、Claude / Codex などのエージェントが
> **ネイティブなツールとして** スクレイピング・認証セッション管理・anti-bot 面の評価を実行できます。
> さらに、暗号化 Cookie 保管庫と prompt-injection サニタイザが、開いた Web を「敵性」として扱います。

[![workspace tests](https://img.shields.io/badge/workspace_tests-911%20PASS-success)](#エンジニアリング)
[![rust](https://img.shields.io/badge/rust-1.83%2B-orange)](https://www.rust-lang.org/)
[![unsafe](https://img.shields.io/badge/unsafe__code-forbid-success)](#エンジニアリング)
[![license](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![MCP](https://img.shields.io/badge/MCP-stdio_JSON--RPC_2.0-purple)](#mcp-サーバ--claude-code-連携)

---

## 目次

- [rev_scraping とは](#rev_scraping-とは)
- [なぜ作ったのか（開発目的）](#なぜ作ったのか開発目的)
- [何が違うのか（AI エージェント開発者向け）](#何が違うのかai-エージェント開発者向け)
- [機能一覧](#機能一覧)
- [正直な機能ステータス](#正直な機能ステータス) ← **最初に読んでください**
- [クイックスタート（ソースからビルド）](#クイックスタートソースからビルド)
- [マニュアル：コマンドリファレンス](#マニュアルコマンドリファレンス)
- [MCP サーバ / Claude Code 連携](#mcp-サーバ--claude-code-連携)
- [セキュリティと責任ある利用](#セキュリティと責任ある利用)
- [競合比較](#競合比較)
- [ロードマップ](#ロードマップ)
- [エンジニアリング](#エンジニアリング)
- [著者・連絡先](#著者連絡先)
- [ライセンス](#ライセンス)

---

## rev_scraping とは

rev_scraping は、**Rust ワークスペース（13 クレート、全クレート `#![forbid(unsafe_code)]`）** で、Web
スクレイピングを「AI エージェントが安全に駆動できるもの」に変えるツールキットです。中核は本物の
**fetch → render → parse → dump** パイプラインで、*Rust 製のヘッドレスブラウザ（`obscura`）を内蔵* し、
ブラウザが失敗したときは透過的に `reqwest`（HTTP）へフォールバックします。その周囲に、エージェント
ワークフローが実際に必要とするものを足しています — JSON/YAML 出力と明文化された終了コード体系を持つ
**安定した CLI**、同じ操作をツールとして公開する **MCP サーバ**、**暗号化された資格情報保管庫**、そして
スクレイプした内容がモデルに届く前に隔離する **prompt-injection サニタイザ** です。

最も強いのは **「エージェントから呼べる、セキュリティに配慮したスクレイピング・エンジンをソースから
ビルドして使う」** 用途です。**ターンキーな anti-bot / captcha 突破製品ではありません**
（[機能ステータス](#正直な機能ステータス)を参照）。

## なぜ作ったのか（開発目的）

AI が速く進化するほど、私たち一人ひとりが、新世代の自動化された攻撃の射程に近づいていきます。多くの人、
そして多くの組織は、**防御の基礎・基本にだけ**投資します。それは必要ですが、十分ではありません — 
**攻撃者が実際にどう動くのかを一度も見たことがなければ、自分の壁のどこに穴が空いているのかは見えない**
からです。

rev_scraping は、その死角を埋めるために作りました。これは **意図的に「読める」ように作られた** ステルス
対応スクレイピング・ツールキットです。防御側・研究者・開発者が、許可された対象に対して、攻撃的な
Web 自動化技術を **自分の手で、オープンに** 学べるようにするためのものです。一度も調べたことのない技術
には、防御のしようがありません。

現実の攻撃者は、ここで配布しているものより **何倍も洗練されたステルス性** で動いており、すでに私たちへ
照準を合わせています。このプロジェクトの目的は彼らより上手く隠れることではありません — **次世代の防御を
作る人々の手に、信頼でき、検証可能な攻撃側ツールを届ける** こと、そして AI 時代がいま必要としている
セキュリティ技術の発展に、ささやかでも貢献することです。

> **これは防御的なセキュリティ研究のためのものです。** すべてのネットワーク操作は明示的な
> `--i-have-authorization` フラグと VPN 必須ポリシーの背後にゲートされています。自分が所有する、または
> 契約上テストを許可されたシステムにのみ使用してください。[セキュリティと責任ある利用](#セキュリティと責任ある利用)参照。

## 何が違うのか（AI エージェント開発者向け）

- **最初から MCP ネイティブ。** Claude Code（または任意の MCP クライアント）を `stealth-mcp` の stdio
  サーバに向けるだけで、エージェントは 16 個のツール（スクレイプ、ドリフトした要素の再特定、ログイン管理、
  チャレンジ面の評価）を **接着コードなしで** 手に入れます。
- **スクレイプしたデータを敵性として扱う。** 信頼できない HTML は `<<<UNTRUSTED_CONTENT>>>` エンベロープで
  包み、prompt-injection のカナリアを走査し、Unicode 正規化し、長さをクランプしてからモデルに渡します。
  多くのスクレイパは生のページ本文をそのまま LLM に渡しますが、これは渡しません。
- **構造化された信頼できる出力。** すべてのコマンドが統一 JSON エンベロープと安定した終了コード
  （`0` ok / `1` user / `2` transient / `3` permanent / `4` auth-expired / `7` leak）を返すので、
  エージェントのリトライ／エスカレーション・ループが決定的に分岐できます。エラーには per-error ページへの
  `doc_url` が付きます。
- **メモリ安全な単一バイナリ。** 全 Rust・`forbid(unsafe)`・SQLite と暗号を同梱・ブラウザ内蔵 — CI
  サンドボックスにそのまま入れられます。

## 機能一覧

**コアスクレイピング**
- **`spider`** — obscura ブラウザ（実ナビゲーション＋JS）または純 HTTP で URL を取得し、レンダリング後の
  HTML をダンプ。ブラウザ経路が失敗すると `reqwest` に自動フォールバック。
- **サイトレシピ**（`stealth-sites`）— サイトごとの「どう取得するか」（エンドポイント・レンダリングモード・
  anti-bot 姿勢）をキャッシュし、実行間で再利用。
- **適応的パース**（`stealth-parse`）— DOM ノードをフィンガープリント化し、ページの markup がドリフトしても
  類似度で再特定。SQLite（WAL）キャッシュ。

**ブラウザ / ステルス**
- **`obscura-bridge`** — 内蔵の `obscura` ヘッドレスブラウザを CDP 経由で監督。独自の SSRF ガード付き。
- **`mobile-fp`** — 6 種のモバイル fingerprint プリセット（iPhone 15 Pro / Pro Max、iPad Pro M4、
  Pixel 9 Pro / 8a、Galaxy S24 Ultra）を UA / viewport / touch / WebGL / Sec-CH-UA のパッチに展開。

**セキュリティ**
- **`stealth-auth`** — 暗号化 Cookie/セッション保管庫：XChaCha20-Poly1305（AAD をプロファイル名に束縛）、
  OS キーリング＋Argon2 による鍵管理、クラッシュ安全な write-then-rename。Cookie は保管庫から外に出ません。
- **`stealth-sanitize`** — prompt-injection 防御：エンベロープ包み＋カナリア検出＋Unicode 除去＋長さクランプ。
  何を除去したかを `_meta.sanitize` でモデルに報告。
- **`vpn-rotate`** — Surfshark ＋ Gluetun（Docker）による IP ローテーション＋リーク監視 *(feature-gated;
  下表参照)*。

**エージェント連携**
- **`stealth-mcp`** — JSON-RPC 2.0 の MCP サーバ（2024-11-05 スキーマ）を stdio で提供、16 ツールを公開。
- **CLI UX** — シェル補完（bash/zsh/fish/nushell）、生成 man ページ、`human|json|yaml` 出力、
  `--dry-run` / `--explain`、`--idempotency-key` リプレイ、統一エラーエンベロープ。

**品質インフラ**
- ワークスペーステスト 911 件、全 13 クレートで `#![forbid(unsafe_code)]`、proptest、criterion ベンチ、
  補完／man ページのドリフトゲート（CI）。

## 正直な機能ステータス

> rev_scraping は **高品質で十分テストされたプロトタイプ** です。スクレイピング中核・エージェント連携・
> セキュリティ層は今日すでに本物で動きます。「攻撃的」な anti-bot 機能とワンコマンド配布は **未完成** です。
> この表が正典です。

| 機能 | ステータス | 備考 |
|---|---|---|
| Fetch → render → HTML dump (`spider`) | ✅ **動く** | obscura ブラウザ＋`reqwest` フォールバック。実ナビゲーション |
| 適応的パース／要素再特定 | ✅ **動く** | `stealth-parse`、SQLite ベース |
| MCP サーバ（16 エージェントツール） | ✅ **動く** | 自前 JSON-RPC 2.0 over stdio |
| prompt-injection サニタイザ | ✅ **動く** | エンベロープ＋カナリア＋Unicode＋クランプ |
| 暗号化 Cookie 保管庫 | ✅ **動く** | XChaCha20-Poly1305＋OS キーリング＋Argon2 |
| CLI UX（json/yaml・dry-run・idempotency・補完・man） | ✅ **動く** | — |
| Cloudflare 対応 (`cf-evaluate`) | 🟡 **設計上、検出のみ** | チャレンジ面を計測。**突破ソルバは無し** |
| VPN IP ローテーション (`vpn`) | 🟡 **feature-gated（オフ）** | `--features docker` でビルド＋Docker/Gluetun 起動が必要 |
| VPS egress プローブ (`measure --enable-egress-probe`) | 🟡 **feature-gated（オフ）** | 明示有効化時のみネットワーク I/O |
| captcha 突破 (`captcha solve` のライブ) | ⛔ **本リポでは stub** | `--dry-run` は合成トークン。ライブ経路は `sidecar` feature＋**本リポ未同梱の Node sidecar** が必要 |
| JA4 / TLS fingerprint (`measure`) | ⛔ **合成プレースホルダ** | 決定的スタブ文字列で、実 JA4 ではない |
| `cargo install` / Homebrew / OCI image / cosign | 🗺️ **ロードマップ・未公開** | release パイプラインは存在するが **一度も実 publish が成功していない**。配布物は無し — **ソースからビルド** |

## クイックスタート（ソースからビルド）

> 今日確実に動くのはこの経路です。`cargo install rev-stealth` / Homebrew / Docker イメージは
> [ロードマップ](#ロードマップ)ですが **未公開** — 使わないでください。

**要件:** Rust **1.83+** と C ツールチェーン（SQLite・暗号を同梱ビルド）。`obscura` ブラウザは
`vendor/obscura/` に内蔵され、ワークスペースと一緒にビルドされます（`spider` には別途の Chromium
ダウンロードは不要）。（任意の `browser` サブコマンドのみ、ホストの Chrome/Chromium を追加で使います。）

```bash
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping
cargo build --release            # rev-stealth ＋ 内蔵 obscura をビルド

./target/release/rev-stealth --version
./target/release/rev-stealth --help
```

最初のスクレイプ（純 HTTP 経路、VPN 不要）：

```bash
./target/release/rev-stealth --format json \
  spider --url https://example.com --http-only --i-have-authorization --allow-no-vpn
```

```jsonc
{"ok":true,"operation":"spider","result":{
  "session_id":"…","fetcher":"http-only","http_status":200,"html_size":1256, "…":"…"}}
```

> `./target/release` を `PATH` に追加（または `cargo install --path crates/stealth-cli`）すれば、以降の
> コマンドの `./target/release/` 接頭辞を省けます。

---

## マニュアル：コマンドリファレンス

`rev-stealth` は操作をサブコマンドにまとめています。全体ツリー：

| コマンド | 目的 | 状態 |
|---|---|---|
| `spider` | AUP ゲート付きブラウズ＋スクレイプ＋任意 CF 評価＋適応的再特定 | ✅ |
| `relocate` | 保存済み HTML / 新規 URL で fingerprint 済み要素を再特定 | ✅ |
| `doctor` | プリフライトのリークチェック（kill-switch / DNS / IPv6 / WebRTC） | ✅ |
| `auth` | 認証セッションのライフサイクル | ✅ |
| `config` | 階層化された設定の参照／変更（`profile` 含む） | ✅ |
| `measure` | ローカル fingerprint 診断（外部プローブはオプトイン） | 🟡 合成 |
| `cf-evaluate` | Cloudflare Turnstile 耐性評価（ソルバ無し） | 🟡 検出のみ |
| `captcha` | reCAPTCHA / hCaptcha / Turnstile の `solve` / `verify` | ⛔ ライブ=stub |
| `vpn` | Exit-IP の `rotate` / `status` | 🟡 Docker 必要 |
| `browser` | ステルスプロファイル起動 / stealth-test スイープ | 🟡 Chrome 必要 |
| `hermes` | Hermes MCP プラグイン雛形（`install` / `verify`） | ✅ |
| `completions` | シェル補完スクリプト出力 | ✅ |
| `manpages` | roff man ページ出力 | ✅ |

> `rev-stealth mcp` サブコマンドは **ありません** — MCP サーバは別バイナリ `stealth-mcp` です
> （[後述](#mcp-サーバ--claude-code-連携)）。「スクレイプ」は `spider`、「レシピ」は `spider` のフラグと
> MCP の `recipe_*` ツールで扱います。

### グローバルオプション

| フラグ | 値 | 既定 | 備考 |
|---|---|---|---|
| `--format` | `human`（別名 `text`）· `json` · `yaml` | `human` | グローバル。JSON は **stdout** にクリーン（ログは stderr） |
| `-v, --verbose` | 繰り返し可（`-v`/`-vv`/`-vvv`） | — | ログ → stderr |
| `-h, --help` / `-V, --version` | — | — | 全サブコマンドに有り |

変更系サブコマンド（`vpn rotate`、`auth login`、`config set/init/…`、`hermes install`）はさらに
**`--dry-run`**（副作用ゼロ）、**`--explain`**（`result.plan` を出力）、
**`--idempotency-key <KEY>`**（同 key＋operation＋payload で前回結果をリプレイ）を受け付けます。

### 出力形式・終了コード・エラーエンベロープ

**成功**（stdout にクリーン JSON）：
```json
{"ok":true,"operation":"vpn.rotate","result":{ "...": "..." }}
```
**失敗**：
```json
{"ok":false,"operation":"captcha.solve","kind":"captcha","exit_code":1,
 "error":"unknown captcha type \"bogus\"","message":"...","hint":null,
 "retry_after_ms":null,
 "doc_url":"https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/Captcha.md"}
```

| 終了 | 名前 | 意味 |
|---|---|---|
| 0 | Ok | 成功 |
| 1 | UserError | 引数不正 / AUP 拒否 / バリデーション |
| 2 | TransientError | ネットワーク／プロバイダの一時障害 — **再試行可** |
| 3 | PermanentError | 非対応 / 依存欠落 |
| 4 | AuthExpired | 保存済み認証プロファイルが無い／期限切れ |
| 7 | Leak | リーク検出 — **フェイルクローズ** |
| 9 / 10 | （コマンド固有） | cache-only ミス / relocate の曖昧一致 |

### `spider` — ページをスクレイプ

AUP ゲート付き：`--i-have-authorization` が必須。既定では VPN ガードも有効（VPN コンテナが無い、または
`--allow-no-vpn` を付けない限り終了 `7`）。

```bash
# 純 HTTP（ブラウザ無し）、VPN 無し：
rev-stealth --format json spider \
  --url https://example.com --http-only --i-have-authorization --allow-no-vpn

# ブラウザレンダリング（obscura）、セッション＋モバイル fingerprint 束縛：
rev-stealth --format json spider \
  --url https://example.com --i-have-authorization --allow-no-vpn \
  --session-id my-run --mobile-preset iphone15pro
```

主なフラグ：`--url <URL>`（必須）· `--http-only`（ブラウザ省略）· `--i-have-authorization`（AUP）·
`--allow-no-vpn` · `--session-id <ID>` · `--mobile-preset <preset>` · `--cf-evaluate` · `--cache-only`。

### `doctor` — プリフライトのリークチェック

kill-switch / DNS / IPv6 / WebRTC の姿勢を検証。リーク検出時は終了 `7`（フェイルクローズ）。

```bash
rev-stealth doctor --output-format json --skip-exit-ip
```

### `relocate` — ドリフト耐性のある要素特定

以前 fingerprint 化した要素を `stable_id` で再特定。ページの markup が変わっても追従します。

```bash
rev-stealth --format json relocate \
  --session-id my-run --stable-id checkout-button --html-file saved.html
```

### `auth` — 認証セッション

Cookie は保管庫で暗号化され、CLI/MCP はメタデータのみを返します（生 Cookie は決して出しません）。

```bash
rev-stealth --format json auth list
rev-stealth --format json auth status --profile my-site
rev-stealth auth login --profile my-site --url https://my-site.example/login   # rev-auth ヘルパが必要
```

### `config` — 階層化設定

```bash
REV_SCRAPING_HOME=/tmp/rs rev-stealth config init --target all
rev-stealth config --output-format json get policy.require_vpn   # → {"key":"…","value":true}
rev-stealth config set policy.require_vpn false --dry-run --explain
```

### `captcha` — captcha 操作

> **ライブ solve は本リポでは stub です。** `--dry-run` は（CI 配線用の）合成トークンを返します。ライブ経路は
> `sidecar` Cargo feature でのビルドと、**本リポに同梱されていない** Node sidecar が必要です。`verify` は
> プロバイダの `siteverify` エンドポイントへ実際に問い合わせます。

```bash
# 配線スモーク（ネットワーク・secret 不要）：
rev-stealth --format json captcha solve --type recaptcha-v3 \
  --site-url https://example.com --dry-run

# トークンをプロバイダで検証（--secret / env 必要）：
rev-stealth --format json captcha verify --type recaptcha-v3 --token "<TOKEN>" --secret "<SECRET>"
```

### `vpn` — IP ローテーション

> `--features docker` でのビルド **と** Docker＋Gluetun（Surfshark）コンテナの起動が必要。無ければリーク
> ガードがフェイルクローズ（終了 `7`）。`--dry-run` はオフラインで計画を表示。

```bash
rev-stealth --format json vpn status
rev-stealth --format json vpn rotate --dry-run --explain   # オフライン・副作用ゼロの計画
```

### `browser` / `cf-evaluate` / `measure`

```bash
rev-stealth browser stealth-test                                   # ステルススイープ（ホスト Chrome/Chromium 必要）
rev-stealth --format json cf-evaluate --url https://example.com    # 検出のみ・ソルバ無し
rev-stealth --format json measure --url https://example.com        # ローカルのみ・JA4 は合成スタブ
```

### `completions` & `manpages`

```bash
rev-stealth completions zsh > ~/.zfunc/_rev-stealth     # bash | zsh | fish | nushell
rev-stealth manpages ./man && man -M ./man rev-stealth
```

---

## MCP サーバ / Claude Code 連携

MCP サーバは **別バイナリ** `stealth-mcp` です。行区切り JSON-RPC 2.0 を stdio で話し、ツール呼び出しごとに
`rev-stealth` CLI を呼び出します。

```bash
cargo build --release --bin stealth-mcp --bin rev-stealth
./target/release/stealth-mcp        # stdin で JSON-RPC を待機
```

**Claude Code への組み込み：**
```bash
claude mcp add stealth-mcp -- /abs/path/to/target/release/stealth-mcp
```
または `.mcp.json`（Cursor でも同様）：
```json
{
  "mcpServers": {
    "stealth-mcp": {
      "command": "/abs/path/to/target/release/stealth-mcp",
      "args": [],
      "env": { "REV_SCRAPING_CLI_PATH": "/abs/path/to/target/release/rev-stealth" }
    }
  }
}
```
`REV_SCRAPING_CLI_PATH` を設定すると、サーバが CWD/PATH に依存しなくなります。

**16 個のツール**（各々が draft-07 の入力 *および* 出力スキーマを持ち、応答はサニタイザを通ります）：

| ツール | 目的 |
|---|---|
| `spider` | ステルススクレイプ＋任意 CF 評価＋適応的再特定（AUP ゲート） |
| `relocate` | `stable_id` で記録済み要素を再特定 |
| `cf_evaluate` | Cloudflare Turnstile 耐性評価（検出のみ） |
| `doctor` | リークガード / VPN / captcha-sidecar の健全性 |
| `recipe_list` / `recipe_show` / `recipe_remove` | サイトレシピの参照／管理 |
| `recipe_propose_endpoint` | レシピへエンドポイント追記（secret 漏れは拒否） |
| `recipe_export` / `recipe_import` | レシピを base64 JSON で移送（パストラバーサル防御） |
| `auth_login_start` / `auth_login_complete` | 2 段階ログイン（返すのはセッショントークン、Cookie ではない） |
| `auth_list` / `auth_status` | プロファイル一覧 / 鮮度 |
| `session_show` | 永続セッションのメタデータ（VPN 束縛・レシピヒット） |
| `vpn_rotate` | VPN exit のローテーション（Docker/Gluetun 必要） |

ハンドシェイク例：
```jsonc
// → {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0.1"}}}
// ← {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"stealth-mcp","version":"1.3.0"},"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}}}}
// → {"jsonrpc":"2.0","id":2,"method":"tools/list"}     // ← 16 ツール
```

共有のワイヤ型は `stealth-agent-contracts`（`rev-stealth-agent-contracts` として公開）に：
26 種の `ErrorKind`、`ErrorEnvelope`、`IdempotencyKey`、`PerHostRateLimiter`、`SessionId`。

---

## セキュリティと責任ある利用

- **許可された対象のみ。** `spider` は `--i-have-authorization` の背後にゲートされています。本ツールキットは、
  あなたが許可されたスクレイピング（自分のサイト、契約済みのエンゲージメント、ToS 内の公開データ）を対象とします。
- **既定で VPN 必須。** ネットワーク系コマンドは、VPN egress が検証されるか `--allow-no-vpn` で明示的に
  オプトアウトしない限り、フェイルクローズ（終了 `7`）します。
- **secret は暗号化のまま。** Cookie/セッションは XChaCha20-Poly1305 保管庫に保管され、CLI と MCP は
  メタデータのみを返します。レシピの import/export とエンドポイント提案は埋め込み secret を拒否します。
- **信頼できない内容は隔離。** モデルへ渡すスクレイプ済み HTML は、まずサニタイズ（`<<<UNTRUSTED_CONTENT>>>`
  エンベロープ＋injection カナリア検出）されます。

## 競合比較

| | rev_scraping | Playwright / Browserless | Crawl4AI | Scrapy |
|---|---|---|---|---|
| エージェント / MCP ネイティブ | ✅ stdio MCP 内蔵 | ✖（接着が必要） | ◯ LLM 志向 | ✖ |
| prompt-injection サニタイザ | ✅ | ✖ | ✖ | ✖ |
| 暗号化資格情報保管庫 | ✅ | ✖ | ✖ | ✖ |
| ランタイム | 単一 Rust バイナリ＋内蔵ブラウザ | Node＋Chromium | Python | Python |
| anti-bot / captcha **突破** | ✖（検出のみ / stub） | プラグインで一部 | 外部サービス | ✖ |
| 成熟度 / エコシステム | 若い | 非常に成熟 | 成長中 | 非常に成熟 |
| ワンコマンドインストール | ✖（ソースビルド） | ✅ | ✅ | ✅ |

**正直な評価:** rev_scraping はエージェントネイティブ連携とセキュリティエンベロープで勝ち、クリーンな
単一 Rust バイナリです。anti-bot 突破・エコシステム成熟度・公開配布では後れを取っています。

## ロードマップ

- 配布物を公開し、`cargo install` / Homebrew / OCI イメージ / cosign 署名を実際に動かす
- 動作する captcha sidecar の実装（ブリッジと interface は既に存在）
- 実 TLS / JA4 fingerprint（合成スタブを置換）
- 手動 Docker 手順なしで既定オンの VPN ローテーション

## エンジニアリング

13 クレートの Rust ワークスペース · 全クレート `#![forbid(unsafe_code)]` · ワークスペーステスト 911 件 ·
proptest · criterion ベンチ · 補完／man ページのドリフトゲート。全体は `cargo build --release` でビルド、
テストは `cargo test --workspace`。

## 著者・連絡先

**鳥居 佐助 (Sasuke Torii)** — **株式会社 REV-C（REV-C Inc., Tokyo）** 制作。
セキュリティ報告・責任ある開示：**`security-alert.reproduce897@passmail.com`**。

## ライセンス

**AGPL-3.0-only** — [LICENSE](LICENSE) 参照。唯一の例外は `vendor/obscura/` 配下の内蔵ブラウザ
エンジンで、これは元の **Apache-2.0** ライセンスのままです。
リポジトリ：<https://github.com/sasuketorii/rev_scraping>。

> 🇬🇧 English version: [README.md](README.md).
