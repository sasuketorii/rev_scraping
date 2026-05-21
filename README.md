# RevHarness

> **Claude Code と Codex を repo-local policy・durable state・deterministic verification の上で協調させる、source-centric な AI 開発ハーネス。**

`Revharness` (canonical display name) / `rev_harness` (canonical machine name) は、AI エージェント運用の速度を落とさずに **再現性・精度・安全性** を機械的に担保するための薄い基盤です。`agent_base` / `agent-base` は legacy alias として残しています。

---

## 目次

1. [何のための基盤か](#1-何のための基盤か)
2. [一目で見る](#2-一目で見る-at-a-glance)
3. [アーキテクチャ — 3 層モデル](#3-アーキテクチャ--3-層モデル)
4. [Runtime Data Plane — 2 系統 db / project_id 分離 / call flow](#4-runtime-data-plane--2-系統-db--project_id-分離--call-flow)
5. [技術スタック / 言語マップ](#5-技術スタック--言語マップ)
6. [Quick Start](#6-quick-start)
7. [機能カタログ — Rust Core (harness-rust/)](#7-機能カタログ--rust-core-harness-rust)
8. [機能カタログ — Shell Scripts (scripts/)](#8-機能カタログ--shell-scripts-scripts-50)
9. [機能カタログ — Skills & Specialties](#9-機能カタログ--skills--specialties)
10. [Hooks — エディタ→キュー→Rust の 3 段アダプタ](#10-hooks--エディタキューrust-の-3-段アダプタ)
11. [Auto-orchestration — `auto_orchestrate.sh` + lib](#11-auto-orchestration--auto_orchestratesh--lib)
12. [Tests — 1,600+ deterministic checks](#12-tests--1600-deterministic-checks)
13. [Truth Surfaces — verification-truth-matrix を中心とする正本](#13-truth-surfaces--verification-truth-matrix-を中心とする正本)
14. [Roles — Orchestrator / Coder / Reviewer](#14-roles--orchestrator--coder--reviewer)
15. [Governance — Truth Read Order と Fail-Closed Boundaries](#15-governance--truth-read-order-と-fail-closed-boundaries)
16. [Operator Troubleshooting — 症状別レシピ](#16-operator-troubleshooting--症状別レシピ)
17. [Project Structure](#17-project-structure)
18. [Maturity & Status](#18-maturity--status)
19. [Customization & Contributing](#19-customization--contributing)

---

## 1. 何のための基盤か

AI agent (Claude Code / Codex) を本番品質のコード生成に使うと、3 つの壁にあたります。

| 壁 | 起きること | RevHarness のアプローチ |
|---|---|---|
| **再現性** | 同じ依頼に違う結果。LGTM が口約束化 | `docs/manual/verification-truth-matrix.md` を acceptance の正本にし、deterministic check artifact のみを LGTM/completion 根拠にする |
| **境界の崩壊** | エージェントが scope を超える / 別 role の権限を侵食する | `scripts/codex-wrapper.sh --role <coder\|high-coder\|reviewer\|research\|standard>` で sandbox / approval / effort / model 上書きを fail-closed に固定 |
| **コンテキスト爆発** | 大規模 repo で context が肥大化、無関係な部分を読み続ける | `semantic-mcp` の 2-step (`sem.context.top_k` → `sem.capsule`) で 220tok 上限の prompt capsule、`file_sha_rollup` + `INDEX_VERSION` で freshness 担保 |

軽量 shell helper + 小さな JSON registry + Rust core で、変更 path から必要な check だけを選び、レビューに渡せる envelope を機械的に作ります。常駐型オーケストレーターではなく **repo に置ける薄いハーネス** として、新規プロジェクトは `src/` を product workspace に、既存プロジェクトには compatibility / overlay path として重ねられます。

---

## 2. 一目で見る (at a glance)

```
Rust workspace     6 crates / ~44,200 LOC / 697 lib tests (1,116 with integration+bin+doc)
Shell scripts      50+ scripts across 11 categories / 35+ fail-closed
Skills             32 skills (100% provider parity .claude/skills ↔ .agents/skills; Cursor-visible via official Skills standard)
Canonical roles    3 (Orchestrator / Coder / Reviewer)
Specialty files    16 (orchestrator 6 / coder 6 / reviewer 4) — 6 projected to SKILL.md
Truth docs         18 manual docs + 3 role docs + matrix-vocabulary.json + cursor-rules-residual-risks.md
MCP tools          8 (sem.* server-side, stdio MCP)
Languages indexed  6 (Rust / TypeScript+JS / Python / Go / Shell / Markdown via tree-sitter)
Tests (total)      1,633+ (Rust 1,116 + shell unit 517 + integration smoke)
Deterministic gate verification-truth-matrix.md + 5 lint subcommands (envelope/specialty/execplan/...) + 9 shell test suites
```

---

## 3. アーキテクチャ — 3 層モデル

```
┌────────────────────────────────────────────────────────────────┐
│ Layer 3: Product Code (src/)                                   │
│   実際の application / service / library — Revharness が守る対象 │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ Layer 2: Project State (.agent/, .claude/tmp/, etc.)           │
│   ExecPlan, SOW, prompts, evidence, lineage ledger, run state  │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ Layer 1: Framework / Core Harness                              │
│   harness-rust/ (Rust)  +  scripts/ (shell wrappers/gates)     │
│   .claude/ + .agents/  +  docs/  +  .codex/                    │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ Layer 0: Ground Truth                                          │
│   .agent_rules/RULES.md  +  CLAUDE.md  +  .shared/project_id   │
│   docs/manual/verification-truth-matrix.md (acceptance 正本)   │
└────────────────────────────────────────────────────────────────┘
```

Truth は下層ほど安定 (Layer 0) で、上層ほど揮発的 (Layer 3 はプロダクトの動きそのもの)。**acceptance / LGTM / completion は Layer 0 の deterministic check に必ず根拠を持つ**設計です。

---

## 4. Runtime Data Plane — 2 系統 db / project_id 分離 / call flow

Section 3 の static な層モデルとは別に、**実行時にどんなデータが・どこに・どう動くか**を理解しておくと、トラブルシュートと multi-repo 運用が一気に楽になります。本セクションは 4 つのトピックを順に扱います。

### 4.1 2 系統 SQLite db が並列で動く

RevHarness の semantic infrastructure は **2 つの SQLite db** が project_id 別に並列存在します。役割と所在を取り違えると「sem.* が空応答」「table missing」の原因になるので、明示しておきます。

| 系統 | 物理パス (macOS) | バイナリ | 役割 | テーブル数 | maturity |
|---|---|---|---|---|---|
| **Rust MCP db (canonical)** | `~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/semantic.db` | `harness-rust/crates/semantic-mcp` の Rust binary (`launch-semantic-mcp.sh` 経由) | full schema (registry + symbol + FTS5 BM25) | **16** | **High** — production の正規経路 |
| Node MCP db (legacy compat) | `~/.semantic-mcp/<project_id>/semantic.db` | `scripts/semantic-mcp-server/dist/cli.js` (Node 20+) | registry-only (queue / capsule / review / projects / components / outbox / registry_deltas) | **7** | Medium — Rust 不在環境向け fallback |

Linux では Library path 部分が `~/.local/share/Revharness/semantic-mcp/v1/<project_id>/` になります。Windows 上では `%LOCALAPPDATA%\Revharness\semantic-mcp\v1\<project_id>\` です (`scripts/rev-harness-distribution-adoption.sh` の `client_distribution.exclude_globs` に 3 OS 全部記載)。

#### Rust db (canonical) の 16 テーブル

| カテゴリ | テーブル | 役割 |
|---|---|---|
| Identity | `projects` | この db を所有する `project_id` (immutable identity authority) を 1 行で保持 |
| Registry | `components` | 論理コンポーネント (`semantic_id`) のカタログ。`sem.registry.upsert/query/set_status/delete` の主表 |
| Registry FTS | `components_fts`, `components_fts_data`, `components_fts_idx`, `components_fts_docsize`, `components_fts_config` | SQLite FTS5 (BM25) で `sem.search` を支える virtual table 一式 |
| Audit | `registry_deltas` | components への変更履歴 (誰がいつ何を) |
| Workflow | `capsules` | `sem.capsule` の出力 (`CAPSULE_SHA256` / `INDEX_VERSION` / `FILE_SHA_ROLLUP` bound) |
| Outbox | `outbox_queue` | semantic-review-queue へ push する pending message |
| Review | `review_queue_items` | enqueue → lease → complete の review item |
| Review | `review_runs` | reviewer 実行履歴 (`run_id` / `verdict`) |
| Symbol | `symbols` | tree-sitter 抽出の関数・構造体・class 等 (1 行 = 1 シンボル) |
| Symbol | `symbol_dependencies` | symbol 間の依存グラフ (impact analysis の辺) |
| Symbol cache | `file_parse_cache` | per-file content hash + grammar version cache (incremental indexing 用) |
| Meta | `_ts_meta` | schema 版・最終 index 時刻・`INDEX_VERSION` 等のメタ |

#### Node db (legacy) との関係

Node db は **registry 7 テーブルだけ**を持ち、symbol layer は持ちません。Node binary (`scripts/semantic-mcp-server/`) は Rust 不在環境 (古い CI、debian slim container、開発初期) の fallback として残してありますが、新規環境では Rust binary が canonical です。

`scripts/semantic-bootstrap.sh` (0.0.13) は Node 側の bootstrap を担当し、Rust 側は `launch-semantic-mcp.sh` を 1 回起動するだけで自動 migration が走って full 16-table schema に到達します。詳しくは [Quick Start 5.2](#62-30-秒で動かす) を参照。

### 4.2 project_id namespace isolation — multi-repo 同居の物理保証

複数プロジェクトを 1 ユーザーが運用しても db が衝突しないのは、**`.shared/project_id` を path namespace に直接焼き込んでいる**からです。

```
~/Library/Application Support/Revharness/semantic-mcp/v1/
├── revharness-691f52d5cca3/   ← rev_harness 専用
│   ├── semantic.db
│   ├── semantic.db-wal
│   └── semantic.db.harness-lock
├── rev_scraping-09399a56d97f/        ← rev_scraping 専用
│   └── semantic.db
├── rev_salescopilot-a2e475d74ca4/    ← rev_salescopilot 専用
│   └── semantic.db
└── contact_dev-618a3613ee7a/         ← contact_dev 専用
    └── semantic.db
```

3 層の物理保証:

1. **ディレクトリ分離**: `<project_id>` が path component なので、別 repo の db が同じファイルを書くことは構造的に不可能。inode も別。
2. **DB-record スコープ**: `projects` テーブルにも自分の `project_id` が刻まれ、全クエリが `WHERE project_id = ?` で絞られる (= 万一誤って別 db を開いても他人の行を返さない、二重ガード)。
3. **同時書き込みロック**: `semantic.db.harness-lock` (shared crate の `SemanticDbLock`) が advisory file lock を取って、同 db への同時 server 起動を 1 つに制限。

`.shared/project_id` は immutable 設計で、`scripts/project-id.sh bootstrap <name>` で初回生成後は手で書き換え禁止 (`canonical-guard.sh` が `invalid` 判定で fail-close するため、識別子破壊事故を防ぐ)。

### 4.3 application_id RSEM marker — db 所有権の安全弁

各 db は SQLite の `PRAGMA application_id` に **`0x5253454D`** を書き込んであります。ASCII で読むと:

```
0x52 = 'R'
0x53 = 'S'
0x45 = 'E'
0x4D = 'M'
→ "RSEM" = Revharness SEMantic
```

意義は 3 つ:

1. **誤識別防止**: ユーザー個人の SQLite db (家計簿、写真メタ、etc.) を Revharness のツールが間違って開いて壊さない。`sem.admin.gc` も RSEM marker が無い db は対象外。
2. **ツール側の安全弁**: `harness-doctor.sh --check-vendoring` や distribution adoption check が「これは Revharness 由来の db です」を判定するキーとして使う。
3. **既存 db への自動採用**: 起動時に `application_id == 0` (未署名) なら自動で `0x5253454D` を書き込む。server log に `adopted application_id = 0x5253454D for /path/...` が出るのがこれ。**最初の 1 回だけ書き込まれ、以降は再起動しても変わらない** (immutable header)。

### 4.4 End-to-end call flow — wrapper invocation の解剖

`bash scripts/codex-wrapper.sh --role coder --stdin < prompt.md` 1 行で何が起きているか、runtime path を追います。

```
                             ┌─────────────────────────────────────────┐
                             │ Layer 0: identity authority             │
                             │  .shared/project_id  (immutable)        │
                             └────────────────┬────────────────────────┘
                                              │ read
                                              ▼
┌────────────────────────┐    ┌──────────────────────────────────────┐
│ user / CLI / hook      │───▶│ scripts/codex-wrapper.sh             │
│ (echo prompt | …)      │    │  ↓ source                            │
└────────────────────────┘    │ scripts/_canonical-guard.sh (0.0.12) │
                              │  ↓ classify identity:                │
                              │    canonical-dev / managed-adopter   │
                              │    /ambiguous-copy/invalid           │
                              │  ↓ if invalid → exit 70 (fail-close) │
                              │  ↓ if ambiguous → warn (advisory)    │
                              │  ↓ else        → silent pass         │
                              └────────────┬─────────────────────────┘
                                           │
              ┌────────────────────────────┼────────────────────────────┐
              │                            │                            │
              ▼                            ▼                            ▼
┌──────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────┐
│ optional: pre-call   │    │ codex CLI invocation     │    │ optional: semantic-  │
│ semantic-mcp pull    │    │  ↓ role-scoped sandbox   │    │ review-queue enqueue │
│ (sem.context.top_k → │    │  ↓ approval / model      │    │ (outbox_queue table) │
│  sem.capsule)        │    │  ↓ effort cap            │    └──────────────────────┘
│  ↓ Rust MCP server   │    │  ↓ run                   │
│  ↓ context_token     │    │  ↓ emit metrics line     │
│  ↓ 220-tok capsule   │    │  → user-visible output   │
└──────────────────────┘    └──────────────────────────┘

scripts/launch-semantic-mcp.sh が背後で起動 (stdio MCP server)
  ↓ Rust binary harness-rust/target/release/semantic-mcp
  ↓ opens Library-path db (auto-migrates schema if needed)
  ↓ acquires SemanticDbLock
  ↓ handles JSON-RPC: initialize / tools/list / tools/call
  ↓ tools/call sem.context.top_k:
       1. impact_analysis(changed_files) using symbol_dependencies graph
       2. rank_top_k(report, fan_in, k)
       3. issue context_token = SHA256(file_sha_rollup + INDEX_VERSION + summary)
       4. return top_k_symbols (observability) + context_token (auth)
  ↓ tools/call sem.capsule:
       5. validate context_token (TTL 30min, single use)
       6. emit 220-tok capsule with CAPSULE_SHA256 binding
       7. INSERT INTO capsules (...)
       8. return capsule body (caller uses as compact context for coder/reviewer)
```

ポイント:

- **guard は wrapper invocation 全部の手前にあり**、identity が壊れた状態ではこの flow は始まらない (0.0.12 default-warn 後も `invalid` は strict 維持)
- **sem.context.top_k と sem.capsule は別の MCP call** で、間を `context_token` で繋ぐ。caller が `top_k_symbols` を直接 sem.capsule に渡そうとすると fail-closed (token 必須)
- **MCP server は per-project_id で 1 プロセス**。同じ project_id に並列で複数起動しようとすると `SemanticDbLock` が advisory warning を出し、後発側は同 db に書かない設計
- **metrics 1 行 = wrapper invocation 1 回**。`REV_HARNESS_DELEGATION_METRIC` JSON line が `wrapper_role` / `specialty` / `manifest_hash` / `exit_code` / `total_tokens` を持って stdout に出る (CI / billing tracking 用)

### 4.5 Bootstrap order (新規 adopter 向け)

これら全部を**ゼロから準備する**には:

```bash
# 1. project_id を確立 (immutable identity)
./scripts/project-id.sh bootstrap "$(basename "$PWD")"

# 2. Rust core build (workspace 全 6 crate)
( cd harness-rust && cargo build --release -p agent-core -p semantic-mcp )

# 3. (optional) Node-side registry db を bootstrap (Rust 不在環境 fallback 用)
bash scripts/semantic-bootstrap.sh
#   → ~/.semantic-mcp/<pid>/semantic.db に 7 registry tables を migrate

# 4. Rust-side full db を migrate + RSEM marker 採用
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bootstrap","version":"0"}}}' \
  | bash scripts/launch-semantic-mcp.sh
#   → Library-path db に 16 tables 全部 migrate + application_id=RSEM 採用

# 5. シンボル index に実データを投入 (本格運用前に 1 度)
PLAN=$(find .agent/active -name "plan_*.md" 2>/dev/null | head -1)
./harness-rust/target/release/agent-core context update --plan "$PLAN" --output /tmp/snap.json
jq '{files: [.files[] | select(.language as $l | ["rust","typescript","tsx","javascript","jsx","python","go","shell"] | index($l))], timestamp: .timestamp}' /tmp/snap.json > /tmp/snap.filt.json
./harness-rust/target/release/agent-core context index-symbols \
  --snapshot /tmp/snap.filt.json \
  --db-path "$HOME/Library/Application Support/Revharness/semantic-mcp/v1/$(cat .shared/project_id)/semantic.db" \
  --project-id "$(cat .shared/project_id)"
#   → symbols テーブルに 100s-10,000s 行 INSERT (codebase 規模次第)
```

step 5 を省くと sem.context.top_k が impact 分析の対象 symbol を見つけられず top_k=0 を返します (動作はするが空)。トラブル時の典型症状なので [section 16 Operator Troubleshooting](#16-operator-troubleshooting--症状別レシピ) も参照してください。

---

## 5. 技術スタック / 言語マップ

| 言語 / 技術 | 役割 | 主な配置 | 成熟度 |
|---|---|---|---|
| **Rust 2021** | 中核 CLI、MCP server、symbol indexer、cache、hook ingress | `harness-rust/crates/` 全 6 crate | 高 (production-grade) |
| **Bash** | wrapper / gate / lint / cleanup / metrics / build | `scripts/` (50+)、`.claude/commands/` | 高 (35+ fail-closed) |
| **TypeScript / Node.js** | semantic-mcp の compatibility surface (Rust 不在環境向け) | `scripts/semantic-mcp-server/` | 中 (legacy fallback) |
| **SQLite + FTS5** | semantic registry / review queue / file index / capsule cache | `~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/semantic.db` (macOS) | 高 (FTS5 BM25 + migration) |
| **tree-sitter** | symbol extraction (6 言語、grammar version tracking) | `harness-rust/crates/tree-sitter-index/` | 高 (incremental + dedup) |
| **JSON / JSONL** | matrix-vocabulary, delegation metrics, task-contract, state.json | `docs/manual/matrix-vocabulary.json`、stderr metric line | 高 (schema versioned) |
| **Markdown** | ExecPlan、role docs、specialty manifests (embedded JSON)、truth matrix | `.agent/`、`docs/roles/`、`docs/manual/` | 高 (canonical 正本) |
| **TOML** | Codex native agent presets、`.codex/config.toml` | `.codex/` | 中 |

開発スタイルは **Rust-first backend / shell-first orchestration glue**。新規 control-plane は Rust、エージェント呼び出し境界は shell wrapper、永続データは SQLite。

---

## 6. Quick Start

### 6.1 前提

- Claude Code CLI (`claude`) または Codex CLI (`codex`) のいずれか以上
- `jq`, `git`, `bash 4+`, `sqlite3`
- Rust toolchain (`cargo`) — Rust core 機能を使う場合 (`semantic-mcp` / `agent-core`)
- Node 20+ — `scripts/semantic-mcp-server/` の Node legacy compat surface を使う場合
- macOS / Linux (Windows は WSL2 推奨)

### 6.2 30 秒で動かす (最短ルート)

```bash
# 1. clone
git clone https://github.com/sasuketorii/rev_harness.git
cd rev_harness

# 2. project_id artifact (初回のみ、immutable identity を確立)
./scripts/project-id.sh bootstrap "$(basename "$PWD")"

# 3. Rust core build
(cd harness-rust && cargo build --release -p agent-core -p semantic-mcp)

# 4. semantic-mcp 起動 (自動 migration + RSEM marker 採用)
./scripts/launch-semantic-mcp.sh   # Ctrl-C で抜ける、schema は永続化される

# 5. wrapper 経由で Codex を呼ぶ
echo "Hello, RevHarness." | ./scripts/codex-wrapper.sh --role coder --stdin
```

step 4 で Rust db に 16 tables (registry + symbol) が migrate され、`application_id=0x5253454D` (RSEM) marker が打たれます。詳細な data plane の動きは [section 4](#4-runtime-data-plane--2-系統-db--project_id-分離--call-flow) を参照。

### 6.3 本格運用前のフル準備 (推奨)

step 4 までで wrapper invocation は通りますが、**`sem.context.top_k` の impact 分析を機能させるには symbol index に実データを投入する必要**があります。step 4 の後に追加:

```bash
# 6. (optional) Node-side registry db も bootstrap (legacy compat / Rust 不在環境向け)
bash scripts/semantic-bootstrap.sh

# 7. symbol index に repo content を投入 (1 度実行で symbols テーブルに数千行)
PLAN=$(find .agent/active -name "plan_*.md" 2>/dev/null | head -1)
[[ -z "$PLAN" ]] && PLAN=README.md   # plan が無ければ任意の md ファイルでも可
./harness-rust/target/release/agent-core context update --plan "$PLAN" --output /tmp/snap.json
jq '{files: [.files[] | select(.language as $l | ["rust","typescript","tsx","javascript","jsx","python","go","shell"]|index($l))], timestamp: .timestamp}' \
  /tmp/snap.json > /tmp/snap.filt.json
./harness-rust/target/release/agent-core context index-symbols \
  --snapshot /tmp/snap.filt.json \
  --db-path "$HOME/Library/Application Support/Revharness/semantic-mcp/v1/$(cat .shared/project_id)/semantic.db" \
  --project-id "$(cat .shared/project_id)"

# 8. (sanity) symbol が入ったか確認
sqlite3 "$HOME/Library/Application Support/Revharness/semantic-mcp/v1/$(cat .shared/project_id)/semantic.db" \
  "SELECT language, COUNT(*) FROM symbols GROUP BY language"
```

step 7 を省くと sem.* call は schema 通りに動きますが、`top_k=0 件` (= 何も返らない) のままです。診断は [section 16.1](#161-sem-が空応答--pending_count-0--何も返らない) 参照。

### 6.4 主な使い方ルート

| やりたいこと | 入り口 |
|---|---|
| Claude Code で auto orchestration を走らせる | `./.claude/commands/auto_orchestrate.sh --plan .agent/active/plan_*.md --phase impl --run-coder` |
| Codex を role 固定で 1 回呼ぶ | `./scripts/codex-wrapper.sh --role <coder\|high-coder\|reviewer\|research\|standard> --stdin < prompt.md` |
| ExecPlan を lint する | `cd harness-rust && cargo run -p agent-core -- execplan lint <plan.md>` |
| handoff envelope を lint する | `cargo run -p agent-core -- envelope lint --specialty <slug> <envelope.md>` |
| specialty manifest を check / project する | `cargo run -p agent-core -- specialty lint --check-projections docs/roles/**/specialties/*.md` |
| task-stamp (SHA-256 deterministic ID) を作る | `cargo run -p agent-core -- task-stamp --task-id ID-001 --description "..." --timestamp 2026-05-20T00:00:00Z` |
| secret scan を走らせる | `scripts/rev-harness-secret-guard.sh check --staged-only` |
| semantic capsule を取る | semantic-mcp 経由で `sem.context.top_k` → `sem.capsule` を JSON-RPC で呼ぶ (詳細は `revharness-semantic-mcp-usage` skill) |

---

## 7. 機能カタログ — Rust Core (harness-rust/)

`harness-rust/Cargo.toml` workspace。Rust 2021 edition、6 crate、合計 ~44,200 LOC。全 crate に `cargo test` が通る単体テストが揃っており、production crate として扱える成熟度。

### 6.1 `agent-core` — オーケストレーション CLI (22 subcommands)

shell スクリプト群を逐次 Rust に置き換えた中核 CLI。`cargo run -p agent-core -- <subcommand>` で起動。

| Subcommand | 機能 | 旧 shell 置き換え | 出力例 / lint rule |
|---|---|---|---|
| `state` | session/task state の get/set/clear/gc | state.sh | `.claude/tmp/<task>/state.json` |
| `session` | session lifecycle (init/start/stop/status/refresh) | session.sh | non-interactive invariant 遵守 |
| `context` | code change context analysis、impact-top-k、symbol indexing | context_analysis.sh | `update`, `index-symbols`, `delta`, `preflight`, `detect-deletions`, `sync-freshness` |
| `capsule` | semantic capsule 生成 (≤220tok)、`CAPSULE_SHA256` / `FILE_SHA_ROLLUP` binding | context_capsule.sh | `INDEX_VERSION` slot exclusion 固定 |
| `cache` | verify/review/capsule artifact cache (LRU、220tok 上限) | — | SQLite `_cache_meta` |
| `verify` | shadow verification (ephemeral worktree lint/test) | shadow_verify.sh | QG-1/QG-2 fail-closed |
| `review` | Codex reviewer 実行 + 履歴 audit | reviewer.sh | review trace persistence |
| `coder` | Claude/Codex coder 実行 (start/watch/health/interrupt) | coder.sh | role-aware dispatch |
| `orchestrate` | cross-agent orchestration (plan/execute/checkpoint/rollback) | auto_orchestrate.sh 補助 | state machine driven |
| `contract` | task contract bind/validate/status | task_contract.sh | `.claude/tmp/<task>/task-contract.json` |
| **`envelope`** | handoff envelope render + **lint** (5 hard + 3 warning rules) | — | rule_id: `envelope.field-presence` / `envelope.enum-membership` / `envelope.prose-code-example` etc. |
| **`execplan`** | ExecPlan markdown lint (5 hard + 1 warning) | — | `execplan.specialty-id-missing` / `canonical-role-mismatch` / `invocation-path-invalid` / `manifest-hash-stale` / `selection-reason-thin` |
| **`specialty`** | specialty manifest lint (R1-R15) + SKILL.md projection (role-aware) | — | `specialty.placeholder-only-section` (R13) / `missing-example` (R14) / `deprecated-alias-in-body` (R15) etc. |
| `worktree` | git worktree (create/list/cleanup/status) | hydra 置換 | concurrent task 分離 |
| `gate` | quality gate (lint / check-coverage / audit) | quality_gate.sh | Level A/B/C |
| `project-id` | project_id artifact 解決/検証 | project-id.sh 一部 | `.shared/project_id` immutable |
| `init` | プロジェクト初期化 (directory + DB seed) | init-project.sh | one-time bootstrap |
| `hook` | hook validate / register / test | — | hook-review-queue と接続 |
| `lease` | lease registry validation (concurrent provider 制御) | — | codex/claude 排他 |
| **`secret`** (parent) | secret scan 系の親 subcommand。`secret scan` を内包 | — | future-proof な namespace |
| **`secret scan`** | staged/ref/files/pre-push stdin の secret scan、allowlist fingerprint、JSON schema v1 | — | accidental secret prevention guard |
| **`semantic`** (parent) | semantic.db 管理系の親 subcommand。`semantic gc` を内包 | — | 将来 `semantic status` / `reindex` 拡張余地 |
| **`semantic gc`** | `~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/semantic.db` の cleanup CLI。`--older-than-days` / `--all-projects` / `--ignore-active-lock` / `--json`、`--dry-run` と `--force` は mutual exclusive (exit 2) | (MCP `sem.admin.gc` の CLI 兄弟) | JSON schema v1、active DB は file lock 経由で default skip |
| **`task-stamp`** | 入力検証付き SHA-256 deterministic task ID 生成 | — | regex bounded task_id + control-char rejected description + RFC3339 UTC timestamp、JSONL 1 行出力 |

**主要 lint subcommands の rule 一覧:**

- `envelope lint`: matrix-vocabulary に対する field-presence / enum-membership / domain-local boundary / prose-code-example / `--specialty` で specialty required heading 検証
- `execplan lint`: specialty-using slice 5 hard rule + selection-reason thinness warning。`manifest_hash` は live re-hash で freshness check (presence-only ではない)
- `specialty lint` (R1-R15): manifest schema、required sections、role-aware body、placeholder-only / missing-example / deprecated-alias-in-body 構造的 lint。`--check-projections` で `.claude/skills/`+`.agents/skills/` への projection drift も検知
- `cache`, `verify`, `review`, `gate`: deterministic verification artifact の生成・検証

**maturity**: 高 — fail-closed の test、role-aware skill_body generator、live hash recomputation、provider parity 自動生成、6 specialty が projection enabled。

### 6.2 `semantic-mcp` — Stdio MCP server (8 tools)

Claude Code / Codex の MCP client から `./scripts/launch-semantic-mcp.sh` 経由で起動。`~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/semantic.db` (macOS) を durable authority に。

| Tool | 機能 | 重要な制約 |
|---|---|---|
| `sem.context.top_k` | changed_files から BFS impact analysis + top-k symbol ranking | `context_token` (SHA256(file_sha_rollup + INDEX_VERSION + summary)) 発行、TTL 30 分、`file_parse_cache` 要事前 populate |
| `sem.capsule` | server-issued `context_token` を入力に 220tok 上限の compact capsule 生成 | body は `CAPSULE_SHA256=` / `INDEX_VERSION=` / `FILE_SHA_ROLLUP=` を必ず含む。caller 提供の `top_k_symbols` は受理しない (token 必須) |
| `sem.preflight` | scope / proposed_components / deleted_paths / move_candidates → pass/warn/block | semantic registry に対する事前検証 |
| `sem.registry.upsert` | symbol registry delta update (semantic_id, logical_id, kind, imports, exports, deps) | idempotency tracking |
| `sem.registry.query` | path_prefix / name / symbol / status で検索 (FTS5 BM25) | compact result field |
| `sem.registry.set_status` | symbol lifecycle (active/inactive/incomplete/buggy/deprecated) | inactive_reason 必須 |
| `sem.registry.delete` | logical delete (idempotent) | by semantic_id / logical_id / symbol |
| `sem.search` | bounded advisory FTS5 search (capsule_budget aware) | scopePaths 必須、top-level conditional keyword 禁止 (OpenAI Responses API 互換) |
| `sem.health` | server / DB / table readiness probe | — |
| `sem.admin.gc` | stale managed DB の dry-run/force delete | older_than_days 指定 |

**LOC**: ~13,400。Tests: 43 lib tests + 2 criterion benchmark (`search_fts5`, `context_top_k`)。SQLite migration は schema 冪等。

**maturity**: 高 — FTS5 BM25 indexing、LRU 220tok cap、freshness invariant (context_token replay resistance)、Cargo feature による 6 言語 grammar の切替。

### 6.3 `tree-sitter-index` — Symbol indexer (6 languages)

`semantic-mcp` と `agent-core context` の symbol extraction エンジン。

| Feature flag | 対応言語 | LOC (extractor) |
|---|---|---|
| `lang-rust` (default) | Rust | 511 |
| `lang-typescript` (default、JS 含む) | TypeScript / JavaScript | 611 |
| `lang-python` (default) | Python | 464 |
| `lang-go` (optional) | Go | 512 |
| `lang-shell` (optional) | Bash / Shell | 193 |
| `all-languages` | 上記すべて | — |

API: `index_files_at_path()`, `impact_analysis_at_path()`, `should_force_full_review()`。incremental indexing 対応 (per-file hash + grammar version cache)。

**LOC**: ~4,600 (extractors 2,300 + db/incremental/parser/types)。Tests: 181 lib tests + 1 benchmark。

### 6.4 `hook-review-queue` — Hook ingress (Rust binary)

`.claude/hooks/codex-review-hook.sh` から委譲される Rust 側エンジン。

- `hook review-queue` subcommand: stdin の JSON (tool_name, file_path) を受け、real-path canonicalization → repo-relative check → write-tool allowlist (Edit/Write) → queue helper 起動
- `NormalizedPath` enum で `RepoRelative` / `OutsideRepo` を厳密分離
- **fail-closed**: 未知 tool / 範囲外 path / queue_helper 不在 / shim/proxy のみ解決可能 → 即 exit non-zero
- trusted runtime dir allowlist (real-user canonical home root) + canonical path matching

**LOC**: ~630。Tests: 29 lib + 統合。

### 6.5 `harness-cache` — Artifact cache

SQLite-backed cache (verify result / review / capsule / file index) with LRU eviction + 220 token budget enforcement。

- `CacheManager::{check,store}_verify_result()`
- `CacheManager::{check,store}_review()`
- `CacheManager::{check,store}_capsule()` (token budget enforced)
- `CacheManager::{file_index_entry, update_file_index}()`
- `gc()`, `maintenance()` — `_cache_meta` table で schema version 管理 (semantic-mcp の `PRAGMA user_version` と非干渉)

**LOC**: ~1,900。Tests: 54 lib tests + fixtures。

### 6.6 `shared` — Foundation layer

全 crate の基礎。

| Module | 役割 |
|---|---|
| `error` | `AgentError` enum + `Result<T>` |
| `freshness` | `snapshot()` → `FreshnessSnapshot` (file_sha_rollup, index_version, ttl_secs) |
| `git` | repo root detection、tree-sitter state |
| `lock` | `FileLock` (fs2-based、ScopeGuard cleanup) |
| `logging` | tracing-subscriber 初期化 (JSON output、env-filter) |
| `paths`, `ranker`, `types`, `validation` | path canonicalize、top-k score、common structs、jq path validator |

**LOC**: ~2,000 (最小 crate だが再利用密度最高)。Tests: 29 lib tests。

---

## 8. 機能カタログ — Shell Scripts (`scripts/`, 50+)

50+ shell script を 11 カテゴリに整理。`bash` (49) + Node.js TypeScript (`semantic-mcp-server/`)。35+ scripts が **fail-closed** (validation gate + non-zero exit + 明確 error)。

### 7.1 Wrappers / Entry points

| Script | 役割 | 主要呼び出し |
|---|---|---|
| **`codex-wrapper.sh`** | Codex CLI canonical entrypoint。`--role <standard\|research\|coder\|high-coder\|reviewer>` で sandbox/approval/effort/model を固定、`--specialty <slug>` で specialty 経路、`--dry-run` で 0-cost 検証、`REV_HARNESS_DELEGATION_METRIC` JSONL 出力 | orchestrator / cross-family / CI |
| `codex-wrapper-high.sh` / `-medium.sh` / `-xhigh.sh` | 互換 shim → canonical wrapper (high-coder / standard / reviewer) | 旧 caller |
| `claude-wrapper.sh` | Claude CLI 互換 shim (deprecated 2026-07-14)。`--bare` は API-key auth 必須で fail-closed | legacy 経路のみ |
| `cursor-wrapper.sh` | Cursor CLI entrypoint。`--role ask\|agent\|yolo`、rules presence metric、enum self-check metric slot、`ask` pre/post git diff gate、0-cost `--dry-run` | read-only Q&A / 軽量 edit / automation lane |

Cursor 経由で Codex / Claude wrapper lane に横抜けしないよう、Codex/Claude wrapper 側は `_outbound-deny.sh` を通じて parent process を確認します。Cursor 自身の実行は許可しつつ、Cursor-origin process から他 vendor wrapper を呼ぶ経路を machine-level に拒否する hardening です。

### 7.2 Semantic-MCP

| Script | 役割 |
|---|---|
| `launch-semantic-mcp.sh` | semantic MCP server エントリ。`harness-rust/crates/semantic-mcp` (Rust 優先) → Node.js fallback (`scripts/semantic-mcp-server/dist/cli.js`)。trusted runtime dir allowlist で fail-closed |
| `project-id.sh` | `.shared/project_id` 解決 + immutable artifact getter/setter |
| `resolve-semantic-project-id.sh` | drift classification を含む project-id resolver |
| `run-semantic-node-tool.sh` | Node.js 系 semantic tool 呼び出し (symlink-safe) |
| `semantic-review-queue.sh` | review queue operator (enqueue/lease/drain/complete/requeue/export) |

### 7.3 Classifier / Routing

| Script | 役割 |
|---|---|
| `rev-harness-task-classifier.sh` | intent + files → `light` / `standard` / `heavy` task class、`schema_profile`、`gate_tier`、`final_reviewer_gate_required` を JSON 出力 |
| `harness-block-router.sh` | BLOCK type → `code-block` / `process-block` / `governance-block` / `terminal-block` |
| `harness-governance-classifier.sh` | path set → governance class (advisory) |

### 7.4 Verification / Gates

| Script | 役割 |
|---|---|
| `quality_gate.sh` | Rust quality check (Level A: fmt / B: +clippy+test+audit / C: +bench) |
| `harness-doctor.sh` | harness health summary、vendoring check (exit 70/71 で vendoring detection) |
| `harness-check-planner.sh` | mode (dev/review/release) → deterministic check command set |
| `harness-projection-preflight.sh` | reviewer-next-status schema validation |
| `harness-runtime-baseline.sh` | wall/rss/cpu 等の orchestration runtime sampling |
| `cross-family-live-smoke-preflight.sh` | Codex↔Claude live smoke 前の advisory check |
| `cross-family-live-artifact-smoke.sh` | opt-in 短時間 live handoff (900s timeout) |

### 7.5 Metrics

| Script | 役割 |
|---|---|
| `collect-delegation-metrics.sh` | `REV_HARNESS_DELEGATION_METRIC` JSONL を集約 → session JSON (median/p75/total) |
| `compute-completion-delta.sh` | baseline vs post の ratio + pct_change + threshold_met (-20%) |
| `harness-benchmark.sh` | model-policy aware の canonical runtime benchmark + evidence manifest |
| `bench_runner.sh` | Criterion 集計 + p95 ratio assertion (cold/warm threshold) |

### 7.6 Build / Project setup

| Script | 役割 |
|---|---|
| `build-dev.sh` | macOS/iOS dev build (no sign/notarize) |
| `init-project.sh` | repo bootstrap (project_id artifact、template、.gitignore) |
| `model-policy.sh` | `model_policy.json` source → runtime compiled policy、hash 検証 |
| `sign-and-build.sh` | release 用 codesign + notarize + staple + verify (macOS) |

### 7.7 Cleanup / Maintenance

| Script | 役割 |
|---|---|
| `harness-active-artifact-pruner.sh` | `.claude/tmp` 等の run artifact を dry-run 既定で archive (no delete by default) |
| `rev-harness-janitor.sh` | inspect / plan / archive-report (read-only) |
| `cleanup-codex-mcp-zombies.sh` | MCP zombie プロセス report / kill |
| `shim-hits-rotate.sh` | `~/.rev_harness/shim-hits.log` の size-based rotation |

### 7.8 Governance / Evidence

| Script | 役割 |
|---|---|
| `rev-harness-admission.sh` | reviewer admission preflight (counter request / schema-micro-fix) |
| `rev-harness-dirty-surface.sh` | dirty/HOLD ownership preflight (read-only git status) |
| `rev-harness-evidence-manifest.sh` | evidence manifest (artifact 存在 + sha256 + 状態) 検証 |
| `rev-harness-worker-lifecycle.sh` | worker lifecycle manifest validation |
| `rev-harness-lease-guard.sh` | lease registry operator (validate/open/heartbeat/close/block/reap) |

### 7.9 Distribution / Adoption

| Script | 役割 |
|---|---|
| `rev-harness-skill-projection.sh` | shared skill canonical sources + provider projection 検証 (manifest 駆動) |
| `rev-harness-skill-routing-check.sh` | skill routing matrix invariants |
| `rev-harness-distribution-adoption.sh` | distribution preflight (composite of projection + dirty + evidence + lifecycle) |
| `rev-harness-src-promote.sh` | product payload copy plan (apply は意図的に無効化) |
| `rev-harness-upgrade.sh` | upgrade inspector / planner |

### 7.10 Utility / Guards

| Script | 役割 |
|---|---|
| `_canonical-guard.sh` | vendoring 防止 (sourced by wrappers、`REV_HARNESS_CANONICAL_ROOT` 強制、exit 70 EX_SOFTWARE on vendored) |
| `_outbound-deny.sh` | Cursor-origin process から Codex/Claude wrapper への outbound delegation を parent-process check で拒否 |
| `_shim-log.sh` | PII-safe shim log (JSONL append、fail-open) |
| `codex-job.sh` | 非同期 job (start/status/wait/result/gc) — fire-and-forget |
| `rev-harness-secret-guard.sh` | `agent-core secret scan` passthrough + managed pre-commit/pre-push hook installer |
| `subscription-auth-guard.sh` | subscription-only auth enforcement (API-key auth を block) |
| `validate-orchestration-packet.sh` | orchestration packet compile/validate |
| `check-matrix-vocabulary-sync.sh` | `matrix-vocabulary.json` hash と `verification-truth-matrix.md` marker の一致確認 |
| `rev-harness-dual-native-check.sh` | dual-native orchestration 文言 audit |
| `rev-harness-static-asset-check.sh` | .html href + .css braces + .js node --check + .json jq |

### 7.11 Semantic-mcp-server (Node.js compat surface)

`scripts/semantic-mcp-server/`: Node.js + TypeScript で書かれた MCP server の compatibility surface。Rust 不在 / 古い CI 環境向けの fallback。Rust に置き換え済みのため新規利用は非推奨。

---

## 9. 機能カタログ — Skills & Specialties

`.claude/skills/<slug>/SKILL.md` (Claude Code 用) と `.agents/skills/<slug>/SKILL.md` (Codex / cross-platform 用) で **100% provider parity**。32 skill。

Cursor Agent Skills については `.agents/skills/` が project-level discovery path、`.claude/skills/` が legacy compatibility path として扱われます。さらに `.cursor/skills/` を canonical Cursor path として確保しています。既存 32 skill (`cursor-caller`、`production-function-implementer`、`staff-code-reviewer` など) は `name:` / `description:` frontmatter compliance を `test/unit/test-cursor-skills-compliance.sh` で deterministic に検証します。

加えて `docs/roles/<role>/specialties/<slug>.md` に **16 canonical specialty file** (embedded JSON manifest)。そのうち 6 specialty が `thin_skill_projection.enabled: true` で SKILL.md に自動 projection されています。

### 8.1 Orchestration Core (7 skills)

| Skill | Trigger |
|---|---|
| `auto-orchestrator` | orchestrator turn 開始時の pre-flight classification、適切な workflow skill へ routing |
| `system-planner` | 計画 / 分析段階 |
| `orchestrator-bootstrap` | session 開始ルーチン (semantic capsule + memory + truth consult) |
| `scope-guard` (specialty) | 曖昧な scope / "ざっくり" 依頼の境界確定 |
| `slice-designer` (specialty) | 大きすぎる依頼の task class / slice boundary / evidence destination 決定 |
| `context-compactor` (specialty) | 長時間 session / handoff 前のコンテキスト圧縮 (compact_handoff ≤ 220 tokens) |
| `structured-mentor` (specialty) | コードを書かずに前提・制約・リスク・代替案の明確化 |

### 8.2 Worker Lenses (6 skills)

| Skill | Trigger |
|---|---|
| `production-function-implementer` (specialty) | 本番品質関数実装、機密データ、エラー処理網羅 |
| `staff-code-reviewer` (specialty) | コードレビュー、PR レビュー、リリース前最終チェック、bug/security 検出 |
| `codex-caller` | Claude → Codex cross-family delegation (wrapper 契約) |
| `review-workflow` | reusable review and fix loop |
| `research-handoff` | external research と handoff workflow |
| `baseline-protection` | coder→reviewer cycle のベースライン安定保護 (pre-write prompt pair、no-write-during-agent) |

### 8.3 Knowledge Packs (4 skills)

`rust-skills-knowledge-pack`、`rustskills-architecture`、`go-skills-knowledge-pack`、`typescript-skills-knowledge-pack`。各言語の最新 stable、依存 governance、benchmark / 公式 doc consultation を駆動。

### 8.4 Deploy Guards (4 skills)

`cloudflare-deploy-guard`、`payload-cms-deploy-guard`、`supabase-deploy-guard`、`codex-app-server-guard`。各 platform へのデプロイ前に **GO/NO-GO gate** を強制 (課金 / セキュリティ / 権限漏洩 / abuse risk / rollback readiness)。

### 8.5 Product Integration & Frontend (5 skills)

`revc-shadcn-frontend-workflow`、`codex-app-server-product-integration`、`shadcn`、`design-principles`、`naming-normalization-guard`。

### 8.6 Repo Lifecycle (5 skills)

`development-junk-cleanup`、`client-distribution-readiness`、`self-growth-proposal-triage`、`harness-official-docs-update`、`revharness-semantic-mcp-usage`。

### 8.7 Canonical Specialties (16 files, `docs/roles/`)

| Role | Specialty | Projection | Required output sections (抜粋) |
|---|---|---|---|
| **Orchestrator** | scope-guard | ✅ | Requested Outcome / Explicit Requirements / Non-Goals / Acceptance Criteria / Minimum Shippable Scope / Pre-Implementation Blockers |
| Orchestrator | slice-designer | ✅ | Classification / Slice Contract / Routing |
| Orchestrator | context-compactor | ✅ | Original Goal / Confirmed Facts / Files Changed / Compact Handoff |
| Orchestrator | structured-mentor | ✅ | My Understanding / Weak Reasoning Points / Alternatives / Smallest Useful Validation |
| Orchestrator | adr-author | — | Status / Decision / Rationale / Rollback / Likely Regrets |
| Orchestrator | migration-planner | — | Migration Goal / Verification Plan / Rollback Plan / Catastrophic Failure |
| **Coder** | production-function-implementer | ✅ | Spec Understanding / Implementation Notes / Tests / Error Handling / Logging-Security / Performance / Worker Outcome |
| Coder | codebase-archaeologist | — | Codebase Summary / Entry Points / Patterns / Safe First Changes / Risky Areas |
| Coder | hypothesis-driven-debugger | — | Symptom Restatement / Root Cause Candidates / First Experiment / Do Not Touch Yet |
| Coder | performance-detective | — | Bottleneck Hypotheses / Complexity Analysis / Improvement Candidates |
| Coder | refactor-safety-analyst | — | Caller Map / Invariants / Breakage Scenarios / Migration Path |
| Coder | risk-based-test-strategist | — | Risks / Test Case Matrix / Tests Not Worth Writing |
| **Reviewer** | staff-code-reviewer | ✅ | Findings / Block Reason / Residual Risk / Missing Context / Verdict |
| Reviewer | independent-verifier | — | Requirement Match / Implemented Behavior / Verification Verdict |
| Reviewer | release-readiness-reviewer | — | Release Verdict / Blockers / Test Status / Rollback Procedure |
| Reviewer | security-and-privacy-reviewer | — | Critical Security Findings / Privacy Risks / Abuse Scenarios / Required Fixes |

✅ = `thin_skill_projection.enabled: true`。`.claude/skills/<slug>/SKILL.md` と `.agents/skills/<slug>/SKILL.md` が `agent-core specialty project --all --provider all` で deterministic に生成される。**body は role-aware** (orchestrator → direct-Read、coder → `--role coder --specialty <slug>`、reviewer → `--role reviewer --specialty <slug>`)。

### 8.8 .claude/commands/ (実行層)

- `auto_orchestrate.sh`: メインのオーケストレータ engine (test/impl phase、state tracking、gate 実行、iteration 制御)
- `lib/`: 14 shared library
  - `state.sh` (state.json operations)
  - `coder.sh` (Claude/Codex coder wrapper)
  - `reviewer.sh` (Codex reviewer wrapper)
  - `session.sh` (CLI session)
  - `utils.sh` / `timeout.sh`
  - `context_capsule.sh` / `context_analysis.sh` (semantic glue)
  - `shadow_verify.sh` (mechanical gate)
  - `orchestration_packet.sh` / `orchestration_policy.sh`
  - `baseline_freeze.sh` (write amplification 防止)
  - `task_contract.sh` (contract bind)
  - `mcp_fallback.sh` (MCP 不通時 CLI fallback)

---

## 10. Hooks — エディタ→キュー→Rust の 3 段アダプタ

`.claude/settings.json` の `PostToolUse` hook が Edit/Write 後に起動する 3 段構造:

```
Claude Code Edit/Write
  │
  ▼
1. .claude/hooks/codex-review-hook.sh        ← shell adapter ingress (matcher: Edit|Write)
  │   • repo-relative 正規化
  │   • repo 外 skip
  │   • 拡張子 allowlist 判定
  ▼
2. scripts/semantic-review-queue.sh enqueue  ← caller-facing queue ingress
  │   • absolute shebang 起動
  │   • trusted runtime dir allowlist 上の真の cargo を解決
  │   • repo-local real-path validation
  ▼
3. harness-rust/crates/hook-review-queue     ← Rust durable engine
      • trusted dir allowlist (real-user canonical home root)
      • write-tool allowlist (Edit / Write)
      • path canonicalize + symlink reject
      • fail-closed: 未知 tool / 範囲外 / shim-only runtime / control-byte project_id
```

**fail-closed の条件 (全て exit non-zero):**

- canonical wrapper / `harness-rust/Cargo.toml` / `crates/semantic-mcp/src/main.rs` のいずれかが不在 or repo 外解決
- cargo lookup が shim/proxy しか返さない / allowlist 外 binary を返す
- malformed / CR byte / multiline の `.shared/project_id`
- entrypoint の実行ビット欠落

`.claude/tmp/review_queue.json` への compatibility export はあるが、**authority は SQLite (`semantic.db`) 側**。

---

## 11. Auto-orchestration — `auto_orchestrate.sh` + lib

### 基本オプション

| オプション | 意味 |
|---|---|
| `--plan PATH` | ExecPlan 指定 (新規実行) |
| `--phase PHASE` | test / impl / review / fix のいずれか |
| `--resume STATE_FILE` | `.claude/tmp/<task>/state.json` から再開 |
| `--run-coder` | Claude Code Coder を自動起動 |
| `--fix-until LEVEL` | 修正対象レベル (high/medium/low/all) |
| `--max-iterations N` | レビュー反復上限 (default: 5) |
| `--reviewers LIST` | reviewer 一覧 (default: safety,perf,consistency) |
| `--reviewer-strategy MODE` | fixed / auto |
| `--agent-strategy MODE` | fixed / dynamic |
| `--gate levelA\|B\|C` | quality gate level |
| `--recover` | stale state recovery |
| `--status` | state.json サマリー |

**重要**: `--continue-session` / `--fork-session` は予約済みで **自動経路では fail-closed**。non-interactive invariant により対話 TTY 以外では実行されない。

### state.json スキーマ

```jsonc
{
  "version": "2.0.0",
  "task": { "id": "<uuid>", "name": "task_name", "plan_path": "..." },
  "status": "running|completed|error|blocked",
  "phases": [
    {
      "name": "impl",
      "status": "pending|running|review|fixing|completed|escalated",
      "iteration": 1,
      "max_iterations": 5,
      "coder": { "session_id": "...", "output_file": "..." },
      "reviews": [],
      "fixes":   []
    }
  ],
  "sessions":     { "coder_sessions": [], "reviewer_sessions": [] },
  "quality_gate": { "level": "levelB", "status": "passed|failed|skipped" },
  "heartbeat":    { "last_updated": "...", "pid": 12345 },
  "error":        null
}
```

### Native multi-agent (.codex/)

- `.codex/config.toml`: `gpt-5.5` + workspace-write sandbox、MCP server `semantic` 自動起動
- `.codex/agents/*.toml`: 9 native subagent preset (coder / system_planner / security_reviewer / performance_reviewer / consistency_reviewer / plan_reviewer / alternative_reviewer / stack_upgrade_researcher / stack_upgrade_reviewer)。same-family delegation は wrapper を再帰起動せず内部で完結。

---

## 12. Tests — 1,600+ deterministic checks

### Rust (697 lib tests / 1,116 workspace cargo test total)

| Crate | Lib tests | Integration tests | Notable suites |
|---|---|---|---|
| `agent-core` | 363 | 25 (secret_scan_cli) + 7 (semantic_gc_cli) + 10 (task_stamp) + 17 fixture-dir files | `specialty::` (R1-R15)、`envelope::`、`execplan::`、`contract::tests::serde_roundtrip_snapshot`、新規 `secret_scan::`、`semantic::` |
| `semantic-mcp` | 183 | 17 files | top_k freshness、capsule SHA256 binding、FTS5 BM25 |
| `tree-sitter-index` | 54 (default features) / 69 (`--features all-languages`) | 4 | extractor coverage per language |
| `harness-cache` | 43 | — | LRU + token budget |
| `hook-review-queue` | 13 | + integration | NormalizedPath validation |
| `shared` | 41 | — | freshness snapshot、ranker、`semantic_gc::`、`semantic_lock::` |
| **合計 (lib)** | **697** | **70+** | — |

`cargo test --workspace` 実測: **1,116 passed** (lib + bin + integration + doc tests 合計)。

Benchmark: `cargo bench -p semantic-mcp` (search_fts5、context_top_k)、`cargo bench -p tree-sitter-index` (index_files)。

### Shell unit tests (517 across 9 files)

| File | Tests | 対象 |
|---|---|---|
| `test/unit/test-wrapper-specialty.sh` | 15 | codex-wrapper `--specialty`、`--specialty + --resume` reject |
| `test/unit/test-delegation-metrics.sh` | 24 | JSONL schema、UUID、null token、duration_ms、collector aggregate、delta ratio |
| `test/unit/test-classifier-specialty-surface.sh` | 7 | classifier specialty 経路 |
| `test/unit/test-secret-guard.sh` | 16 | rev-harness-secret-guard.sh wrapper + hook install / uninstall / dry-run / restore |
| `test/unit/test-cursor-wrapper.sh` | 30 | cursor-wrapper.sh `ask`/`agent`/`yolo` role、preflight + dual telemetry、ask diff gate、signal trap、vendoring guard |
| `test/unit/test-outbound-deny.sh` | 13 | codex/claude wrapper の cursor-parent 拒否、二重 gate `REVHARNESS_TEST_HARNESS=1 + REV_HARNESS_PARENT_PROCESS_TEST`、`REV_HARNESS_CURSOR_OUTBOUND_ALLOW=1` opt-in |
| `test/unit/test-cursor-rules-frontmatter.sh` | 18 | `.cursor/rules/revharness-{critical,detailed}.mdc` の MDC frontmatter spec、critical→detailed 重複検出 |
| `test/unit/test-cursor-skills-compliance.sh` | 394 | `.claude/skills/*/SKILL.md` + `.agents/skills/*/SKILL.md` の Cursor 公式 Agent Skills spec compliance (name presence + description + lowercase + folder parity + YAML fence) |
| `test/unit/test-matrix-vocabulary-sync.sh` | — | vocabulary hash 一致 (binary check) |
| **合計** | **517** | — |

### Integration

- `test/integration/harness_release_gate.sh --tier <quick\|local\|full>`: full tier に **42+ step** (本 round で `cursor_wrapper` / `cursor_rules_root` / `cursor_rules_frontmatter` / `cursor_outbound_deny` / `cursor_skills_compliance` / `secret_guard` を LOCAL + FULL に wire-in)
- `test/integration/root_instructions_test.sh`: `AGENTS.md` / `CLAUDE.md` / `.claude/CLAUDE-LOCAL.md` migration smoke (Cursor auto-read leakage 防止)
- `test/fixtures/fake-codex/codex`: shell fixture で CI を API budget zero に
- `test/fixtures/fake-cursor/agent`: Cursor CLI semantic を mimic、`FAKE_CURSOR_ARGV_LOG` で argv 記録 + `FAKE_CURSOR_TOUCH_FILE` で write 試行 trigger
- `test/fixtures/`: specialty_lint_fixtures、specialty_project_golden、execplan_lint_fixtures、envelope_lint_fixtures、secret_scan_fixtures

### Deterministic verification model

```
Coder → Shadow Verify → Reviewer
```

- **Shadow Verify** (`scripts/shadow_verify.sh` / `agent-core verify`): mechanical lint/test in ephemeral worktree
- **QG-1**: `quality_gate.status in {failed, skipped}` → fail-closed
- **QG-2**: 言語別必須コマンド (`pnpm|npm` / `cargo` / `pytest`) 不在 → fail-closed
- **3 回失敗で escalation report 生成** (`.claude/tmp/task/escalation_report_*.md`)

---

## 13. Truth Surfaces — `verification-truth-matrix` を中心とする正本

### `docs/manual/` (18 doc)

| File | 正本 | 読み手 |
|---|---|---|
| **`verification-truth-matrix.md`** | task class profile、canonical schema、status/verdict state machine、final-reviewer gate、loop budget ledger、fail-closed conditions、completion language、reviewer LGTM validity | **全 role 必読 (最高位正本)** |
| `orchestration-closure-playbook.md` | class closure sheet、adversarial pre-closure pass、sink universe adequacy、reset semantics | Coder (defect/root-cause)、Reviewer (late finding) |
| `execplan-checklist-standard.md` | ExecPlan 必須セクション、specialty-using slice の conditional field | Orchestrator / Coder |
| `common-task-contract.md` | task-contract.json envelope、goal boundary | Orchestrator / Coder intake |
| `delegation-metrics-schema.md` | JSONL v1、field semantics、release-gate integration | metrics consumer (tool/CI) |
| `agent-maintainer-guide.md` | harness maintenance playbook | maintainer |
| `developer-customization-guide.md` | canonical operating model、daily workflow | developer |
| `end-user-guide.md` | user-facing artifact trust | end user / product |
| `agent_review_loop.md` | review iteration workflow | reviewer operator |
| `skill-routing-matrix.md` | skill ↔ task mapping | Orchestrator |
| `skill-integration.md` | skill contract、handoff format | skill developer |
| `subscription-orchestration.md` | multi-model cost/capability、subscription lane | Orchestrator |
| `matrix-vocabulary.json` | canonical enum / field names、`_policy.domain_local` namespaces (handoff_state, execplan_state) | 全 vocabulary consumer |
| `harness-release-gate.md` | release gate verification、artifact integrity | release operator / CI |
| `frontier-evidence.md` | frontier validation | explorer |
| `self-evolution-proposal-queue.md` | self-improvement intake | self-optimizer |
| `worldclass-harness-operating-model.md` | vision、operational/design constraints | architect |
| `harness-user-guide.md` | user-facing operations | user |
| `cursor-cli-integration.md` | Cursor CLI wrapper role、rules integration、telemetry、out-of-scope | Orchestrator / Cursor lane operator |
| `cursor-rules-residual-risks.md` | Cursor rules integration の未保証領域と future hardening 候補 | Orchestrator / maintainer |

### `matrix-vocabulary.json` の役割

- **canonical enum / field の唯一の正本**。新規 enum は **ここに登録するか `_policy.domain_local` namespace を宣言** しないと envelope lint で reject
- `_policy.domain_local` namespace:
  - `handoff_state` (`ready_for_next` / `needs_fix` / `needs_more_context` / `blocked`) — worker lifecycle が matrix review status と独立
  - `execplan_state` (`proposed` / `accepted` / `superseded`) — artifact lifecycle
- 同期ガード: `scripts/check-matrix-vocabulary-sync.sh` (CI gate)

### `verification-truth-matrix.md` (中核)

- task class profile: light / standard / heavy → gate tier + schema profile + review/final-reviewer-gate required
- **canonical schema** (heavy only): task id / lineage ledger / prior task id / slice id / prior slice id / review request target (INTERMEDIATE\|FINAL) / discovery owner / bug class candidate / change surface / required checks / evidence destination / completion boundary / class closure sheet / sheet status / owned sink universe / closed universe status & basis / **8 counters** (fix-review loops used、closure resets used、reviewer-found same-class finding、re-slice count、cumulative reviewer requests、cumulative late findings、cumulative closure resets、task-level stall-or-wall-time budget) / scope delta
- canonical status machine: `in progress` → `pending review` → `pending verification` → `pending final review` → `pending acceptance` → `completed` | `blocked`
- verdict mapping: LGTM / BLOCK / Request Changes / Needs verification / Needs Discussion
- **final reviewer request gate** (6 conditions)
- **fail-closed block conditions**: loop ceiling exceeded、budget exhausted、provenance missing、weak universe、identical relabel など

---

## 14. Roles — Orchestrator / Coder / Reviewer

### Orchestrator (統括)

- **Allowed**: task classification、acceptance/LGTM/completion 判定 (matrix 根拠)、ExecPlan/SOW 作成、Coder/Reviewer への narrow slice handoff、status state machine 遷移
- **Forbidden**: code/docs/`.agent_rules/`/`.claude/` 編集、reviewer LGTM だけでの早期 completion、broad task 未分解 handoff
- **Required envelope**: task class、schema profile、change surface、required checks、completion boundary、(heavy のみ) task lineage ledger、prior task id、scope delta、fresh budget recheck

### Coder (実装、Claude/Codex 両方可)

- **Allowed**: blueprint-first + TDD、ExecPlan 草稿、Class Closure Sheet (defect/root-cause fix)、Adversarial pre-closure pass、`pending verification` 復帰時の verification、`blocked` 再開時の re-slice
- **Forbidden**: `completed` / `pending acceptance` 自己宣言、soft closeout、`light-change-record` なしの `light` handoff、`heavy` の不完全 packet
- **Required envelope**: `status` (pending review / pending verification / pending final review / blocked)、`worker outcome` (DIFF/NO-CHANGE/BLOCK)、slice contract、scope delta

### Reviewer (**Codex 固定**, `--role reviewer`)

- **Allowed**: multi-dimensional evaluation (security/perf/consistency/test/DX)、`pending review` / `pending final review` intake、verdict 発行、late same-class finding detection + closure reset 指示、final reviewer gate compliance
- **Forbidden**: `pending verification` のまま intake、generic completion wording、reviewer を same-class discovery primary 扱い、`FINAL` review で scope delta=none 不確認 LGTM
- **Required envelope**: incoming request status、worker outcome、evidence reviewed、verification commands/results、next status mapping、(heavy/standard) budget status fresh check

---

## 15. Governance — Truth Read Order と Fail-Closed Boundaries

```
User instruction
   │
   ▼
CLAUDE.md  (Orchestrator Hard Rules、wrapper 契約、4 層 context model)
   │
   ▼
.agent_rules/RULES.md  (Phase 0-5、core mandates、Class-First contract)
   │
   ▼
docs/roles/<role>.md  (3 canonical role definitions)
   │
   ▼
docs/manual/verification-truth-matrix.md  (deterministic checks、state machine、gate)
   │
   ▼
Runtime entrypoint  (codex-wrapper.sh、launch-semantic-mcp.sh、auto_orchestrate.sh)
```

**Acceptance authority は常に `verification-truth-matrix.md` の deterministic check** であり、wrapper 準拠や reviewer LGTM だけでは代替できません。

### AGENTS.md / .cursor/rules contract

`AGENTS.md` は vendor-neutral cross-agent invariants の置き場です。acceptance authority、evidence convention、secret redaction、cross-family delegation、change discipline のように、Claude / Codex / Cursor のいずれが読んでも矛盾しないルールだけを置きます。

Cursor-specific guidance は `.cursor/rules/` に分離します。`.cursor/rules/revharness-critical.mdc` は always-attached fail-closed invariants、`.cursor/rules/revharness-detailed.mdc` は description-based operational guidance です。Cursor official docs は CLI が project-root `AGENTS.md` / `CLAUDE.md` と `.cursor/rules` を rules として読むと説明しています: https://docs.cursor.com/en/cli/using and https://docs.cursor.com/en/context/rules。

Cursor Agent Skills は Rules とは別の task-specific capability surface です。RevHarness の既存 `.agents/skills/` と `.claude/skills/` は Cursor discovery / legacy compatibility の対象で、`.cursor/skills/` は canonical Cursor provider path として予約済みです。Skill を追加・移動する場合は `SKILL.md` の fenced frontmatter、`name:`、`description:`、folder-name parity を維持し、`.agents/skills/` 側との provider parity を崩さないでください。

`CLAUDE.md` は vendor-neutral bootstrap、`.claude/CLAUDE-LOCAL.md` は Claude-specific operating rules です。Root に vendor-specific instruction を混ぜず、runtime 固有の detail は各 vendor-local surface に置きます。

### 主要 fail-closed boundary

| 境界 | 条件 | 結果 |
|---|---|---|
| wrapper canonical | 非 canonical path / role escape / `--specialty + --resume` | exit non-zero (fail-closed) |
| matrix vocabulary sync | hash 不一致 / marker count error | `check-matrix-vocabulary-sync.sh` exit 1 |
| envelope lint | required field missing / enum off / domain-local boundary 逸脱 / specialty heading 欠落 | `envelope.*` rule_id error |
| execplan lint | specialty_id missing / canonical_role mismatch / invocation_path 不正 / manifest_hash stale / selection_reason thin | `execplan.*` rule_id error/warning |
| specialty lint | R1-R15 (manifest schema / role-aware body / placeholder-only / missing-example / deprecated-alias) | `specialty.*` rule_id error/warning |
| hook ingress | shim-only runtime / 範囲外 path / control-byte project_id | exit non-zero |
| semantic capsule | context_token 失効 / file_sha_rollup drift / INDEX_VERSION mismatch | sem.capsule 拒否 |
| QG-1 / QG-2 | quality_gate failed/skipped / 言語必須コマンド不在 | shadow verify fail-closed |

---

## 16. Operator Troubleshooting — 症状別レシピ

Section 4 で説明した runtime data plane のどこかが詰まったときの diagnostic レシピ。すべて read-only で書き換え操作は最後の手段。

### 16.1 「sem.* が空応答 / pending_count: 0 / 何も返らない」

最頻出。原因は 5 つ:

| 仮説 | 確認 | 対処 |
|---|---|---|
| **Rust db が未 migration** (schema が 4 tables だけで registry/symbol が無い) | `sqlite3 ~/Library/Application\ Support/Revharness/semantic-mcp/v1/$(cat .shared/project_id)/semantic.db ".tables" \| wc -w` で 16 でなければ未 migration | `bash scripts/launch-semantic-mcp.sh` を 1 回起動 (initialize JSON-RPC を送れば自動 migration、Ctrl-C で抜けても schema は保持) |
| **symbols テーブルが空** (db schema は OK だが indexer 未実行) | `sqlite3 "$DB" "SELECT COUNT(*) FROM symbols"` が 0 | [section 4.5 step 5](#45-bootstrap-order-新規-adopter-向け) の `agent-core context update` + `index-symbols` を実行 |
| **wrong project_id** (caller と server が別 id を見ている) | `cat .shared/project_id` と server stderr の `project_id=...` を照合 | identity を直す。`.shared/project_id` は immutable なので、間違っている場合は `scripts/project-id.sh bootstrap` 再実行ではなく orchestrator 側を直す |
| **context_token expired** (sem.context.top_k と sem.capsule の間に 30 分以上空いた) | sem.capsule error が `context_token TTL expired` | sem.context.top_k から取り直す |
| **changed_files が repo 外** (絶対 path / parent traversal) | server error `path validation failed` | 全 `changed_files` を repo-relative に直す |

### 16.2 「identity-check (advisory): source-style project_id outside the official source checkout」

`canonical-guard.sh` (0.0.12 default-warn) が ambiguous-copy を検知した時の advisory。

| 状況 | 何を意味するか | 対処 |
|---|---|---|
| `revharness-*` で始まる project_id を持っているが、official git remote (`github.com/sasuketorii/rev_harness.git`) でも canonical path (`$HOME/dev/rev_harness`) でもない | RevHarness の source-dev 用 id を adopter checkout が保持している (= 通常 init-project が起こす状態) | adoption であれば `scripts/project-id.sh bootstrap <your-name>` で target id を発行。source 開発であれば `export REV_HARNESS_CANONICAL_ROOT=$PWD` |
| 警告だけで wrapper は exit 0 で動く | 0.0.12 default が warn だから (release-gate と `harness-doctor --strict` のみ strict) | 本番 / CI では `REV_HARNESS_VENDOR_CHECK=strict` を export して fail-close に戻せる |

### 16.3 「identity-check (strict): repo identity is missing or malformed」 — fail-closed 終了

`invalid` 識別子 (project_id 欠落 / control char / 多重行) のときの strict-by-default 警告。downstream (semantic-mcp / queue / capsule) の data corruption を防ぐため必ず止まる。

```bash
cat .shared/project_id     # 欠損 or 化けてないか
ls -la .shared/             # ファイル権限 (600 期待)
hexdump -C .shared/project_id | head -3   # 不可視 control char 確認
```

直し方:

1. 別 checkout / バックアップから正しい id を復元 (immutable design なので「正しい元の値」が存在する前提)
2. それでも無い場合、最終手段は `scripts/project-id.sh bootstrap <new-name>` で**新規 id** を生成 — ただし `~/Library/.../v1/<old-pid>/` の db は孤児化するので、別途 `sem.admin.gc` で消す

### 16.4 「harness-doctor --quick が UNKNOWN を返す」

| unknown 内容 | 意味 | 対処 |
|---|---|---|
| `latest release-gate pointer is missing: .claude/tmp/harness-release-gate/latest.json` | release-gate を 1 回も走らせていない (新規 repo / adoption 直後) | 必要なら `bash test/integration/harness_release_gate.sh --tier quick`。adopter 環境では unknown のままで OK |
| `task lineage ledger is missing or unsafe: .agent/active/sow/task-lineage-ledger.md` | active task の系譜が無い (まだタスクを走らせていない) | 通常運用で task を 1 つでも回せば自動生成 |
| `dirty worktree detected: N changed/untracked paths` | git status が dirty (普通の作業中) | 警告のみ。commit/stash 進めば消える |

UNKNOWN は **acceptance authority ではない** (advisory-only)。LGTM や release 判定にはこの doctor 出力を使わず、必ず `docs/manual/verification-truth-matrix.md` の deterministic check を根拠にすること。

### 16.5 ディスク使用量が膨らんだ

```bash
# 4 repo 合計の db サイズ
du -sh ~/Library/Application\ Support/Revharness/semantic-mcp/v1/*/
du -sh ~/.semantic-mcp/*/

# 古い orphan project (使っていない id) の dry-run リスト
./harness-rust/target/release/semantic-mcp gc --older-than-days 30 --dry-run

# 実削除 (--dry-run 外す、RSEM marker のある db だけ対象)
./harness-rust/target/release/semantic-mcp gc --older-than-days 30 --force
```

過去の `queueruntime-*` (テスト用 db) も `~/.semantic-mcp/` に大量に残るので、定期的に gc 推奨。

### 16.6 「`tsc: command not found`」 / dependency 不足

| エラー | 原因 | 対処 |
|---|---|---|
| `tsc: command not found` | `scripts/semantic-mcp-server/dist/` 未 build | `cd scripts/semantic-mcp-server && npm install && npm run build` または `bash scripts/semantic-bootstrap.sh` (自動 build) |
| `cargo: command not found` | Rust toolchain 未インストール | https://rustup.rs/ |
| `node: command not found` | Node 20+ 未インストール | https://nodejs.org/ (`engines: node 20.x \|\| 22.x \|\| 23.x \|\| 24.x \|\| 25.x`) |
| `sqlite3: command not found` | SQLite CLI 未インストール (macOS は system 同梱、Linux は `apt install sqlite3`) | OS 依存 |

`scripts/harness-doctor.sh --quick` を最初に走らせれば dependency 不足を JSON 形式で一括検出します。

### 16.7 「`launch-semantic-mcp.sh` が即時 exit する」

stderr を見れば多くは判明 (`2>&1 | tail -20`)。よくある原因:

- `.shared/project_id` 欠損 → 16.3 参照
- Rust binary 未 build → `cd harness-rust && cargo build -p semantic-mcp`
- 別 server プロセスが同 db を locking 中 → `lsof | grep semantic.db` で確認、不要なら kill。`SemanticDbLock` は advisory なので強制的に並列起動はできるが、後発側は書き込みを行わない設計

### 16.8 「Codex CLI が計画文 1 行だけ吐いて exit / 実装 0 ファイル」 — 大型 prompt × high effort bail-out

2026-05-21 に multi-lane orchestration (Lane A–E parallel dispatch) で実機検出された
Codex CLI 側の **silent no-op 失敗モード**。RevHarness 側で再現可能、RevHarness 側で
未修復 (Codex CLI 本体の挙動)。

#### トリガー条件 (3 つ揃うと発火しやすい)

1. prompt size **≥ 5–7 KB** (slice-designer skill の推奨上限を超える)
2. effort 設定が **high** (`--role high-coder` / `--role reviewer` / `--effort high`)
3. self-driven multi sub-phase の連鎖を 1 prompt に詰め込んでいる
   (= 「8 sub-phase を順に自己駆動でやって」型の指示)

#### 症状

- smoke test (1-line prompt) では **再現しない** — 短 prompt は普通に通る
- 該当条件下では Codex が「計画書きました」相当の **1–3 行だけ** 吐いて exit 0
- 実装ファイル 0、変更 diff 0
- log file (`/tmp/lane_*_codex.log` 等) は存在するがサイズが 1KB 以下で打ち切られている
- 親の orchestrator は「正常終了」と誤認するので、reviewer ロールに進まないと気付けない
- 最悪ケース: process が 12+ 時間 silent hang (実際の事例あり)

#### 検出 (機械的に判定)

```bash
# 20 分以上書き込みなし & サイズ < 1KB の lane log = bail-out 強疑い
find /tmp -maxdepth 2 -name 'lane_*_codex.log' -mmin +20 -size -1k 2>/dev/null

# wrapper 経由起動なら metric line が出ているはず。出ていないと無音失敗
grep -h "REV_HARNESS_DELEGATION_METRIC" /tmp/lane_*.log 2>/dev/null | head

# 親 orchestrator が hang 検出していない場合の救出
ps aux | grep -E 'codex.*exec' | grep -v grep   # 12 時間放置プロセスが残ってないか
```

#### 対処 (3 段階)

1. **prompt を分割** (canonical): `slice-designer` skill のガイドに従って
   1 sub-phase = 1 prompt、目安 **≤ 2 KB / 1 file** に切る。Lane B 診断はこれで解消。
2. **長 prompt は coder を Claude Opus に振る**: `claude-wrapper.sh --role coder`
   は同じ大きさでも完走する (Opus は長 prompt 耐性が高い)。reviewer は Codex 固定
   (`codex-wrapper.sh --role reviewer`、`docs/roles/reviewer.md` 参照)。
3. **必ず canonical wrapper 経由**: raw `codex exec` を直接叩くと
   `REV_HARNESS_DELEGATION_METRIC` JSON line が出ず、失敗検知の手掛かりが消える。
   0.0.12+ canonical-guard は raw bypass に advisory 警告を出すが fail-close は
   しないので、orchestrator 側で wrapper 強制が必要。

#### 既知 (まだ自動化していない)

- wrapper 側で prompt size を測って **≥ 5KB × high effort の組合せを警告** する pre-check (0.0.17 候補)
- 上記 `find /tmp -name 'lane_*_codex.log' ...` を `harness-doctor --strict` に統合 (0.0.17 候補)

#### 関連 audit

- Lane B 診断 (2026-05-21): 7KB prompt × high effort で plan 1 行 → silent exit 再現
- Lane A 12 時間 hang (2026-05-21): 同条件で process が抜けず、SIGTERM 必要

---

## 17. Project Structure

```
rev_harness/
├── README.md                          ← 本ファイル
├── AGENTS.md                          ← vendor-neutral root invariants
├── CLAUDE.md                          ← vendor-neutral bootstrap
├── .cursor/rules/                     ← Cursor project rules (critical + detailed MDC)
├── .cursor/skills/                    ← Cursor canonical Agent Skills path (reserved)
├── .claude/CLAUDE-LOCAL.md            ← Claude-specific local operating rules
├── .agent_rules/RULES.md              ← Layer 0 ground truth (Phase 0-5, core mandates)
├── .shared/project_id                 ← immutable repo identity
│
├── harness-rust/                      ← Rust workspace (6 crates, ~44k LOC, 1,116 cargo test)
│   ├── Cargo.toml
│   └── crates/
│       ├── agent-core/                ← 22-subcommand CLI (envelope/specialty/execplan lint, task-stamp, secret scan, semantic gc, ...)
│       ├── semantic-mcp/              ← stdio MCP server (8 tools, FTS5, capsule)
│       ├── tree-sitter-index/         ← 6-language symbol indexer
│       ├── hook-review-queue/         ← hook ingress (Rust binary)
│       ├── harness-cache/             ← SQLite cache (LRU + token budget)
│       └── shared/                    ← foundation (error, freshness, lock, logging, ranker, semantic_gc, semantic_lock)
│
├── scripts/                           ← 50+ shell scripts (11 categories)
│   ├── codex-wrapper.sh               ← canonical Codex entrypoint (parent-process deny for cursor-agent origin)
│   ├── claude-wrapper.sh              ← deprecated 2026-07-14 (parent-process deny同様)
│   ├── cursor-wrapper.sh              ← Cursor `agent` CLI entrypoint (ask/agent/yolo roles)
│   ├── _outbound-deny.sh              ← parent-process check helper (cursor→codex/claude wrapper の machine-level 拒否)
│   ├── rev-harness-secret-guard.sh    ← agent-core secret scan passthrough + git hook installer
│   ├── launch-semantic-mcp.sh         ← MCP server launcher
│   ├── rev-harness-task-classifier.sh ← intent/files → task_class JSON
│   ├── collect-delegation-metrics.sh  ← JSONL aggregator
│   ├── compute-completion-delta.sh    ← baseline vs post delta
│   ├── ... (50+ more)
│   └── semantic-mcp-server/           ← Node.js compat surface (legacy)
│
├── .claude/                           ← Claude Code 用 (provider parity with .agents/)
│   ├── settings.json                  ← PostToolUse hook config
│   ├── commands/
│   │   ├── auto_orchestrate.sh        ← orchestration engine
│   │   └── lib/                       ← 14 shared lib (state.sh, coder.sh, reviewer.sh, ...)
│   ├── hooks/
│   │   └── codex-review-hook.sh       ← shell hook adapter ingress
│   ├── skills/                        ← 32 SKILL.md (Claude provider)
│   └── tmp/                           ← run state (state.json, capsule cache, evidence)
│
├── .agents/skills/                    ← 32 SKILL.md (cross-platform / Codex provider, parity)
│
├── .codex/                            ← Codex CLI 用
│   ├── config.toml                    ← model, sandbox, MCP server
│   └── agents/*.toml                  ← 9 native subagent preset
│
├── docs/
│   ├── roles/                         ← 3 canonical role docs + 16 specialty files
│   │   ├── orchestrator.md
│   │   ├── coder.md
│   │   ├── reviewer.md
│   │   ├── orchestrator/specialties/  ← 6 specialty (scope-guard, slice-designer, ...)
│   │   ├── coder/specialties/         ← 6 specialty (production-function-implementer, ...)
│   │   └── reviewer/specialties/      ← 4 specialty (staff-code-reviewer, ...)
│   ├── manual/                        ← 18 truth doc + matrix-vocabulary.json
│   │   ├── verification-truth-matrix.md  ← 最高位正本
│   │   ├── matrix-vocabulary.json     ← canonical vocabulary
│   │   ├── execplan-checklist-standard.md
│   │   ├── delegation-metrics-schema.md
│   │   └── ... (14 more)
│   └── prompts/                       ← role-operating-templates + 過去依頼の archive
│
├── test/
│   ├── unit/                          ← 9 shell unit suites / 517 件 (wrapper-specialty / delegation-metrics / classifier / matrix-vocab / secret-guard / cursor-wrapper / outbound-deny / cursor-rules-frontmatter / cursor-skills-compliance)
│   ├── integration/
│   │   ├── harness_release_gate.sh    ← LOCAL/FULL tier + cursor / secret-guard wire-in
│   │   └── root_instructions_test.sh  ← AGENTS.md / CLAUDE.md / CLAUDE-LOCAL.md migration smoke
│   └── fixtures/
│       ├── fake-codex/codex           ← CI API-budget-zero fixture
│       └── fake-cursor/agent          ← Cursor CLI semantic mimic (argv log + write-attempt hooks)
│
├── .agent/
│   ├── PROJECT_CONTEXT.md             ← project-specific context
│   ├── active/                        ← 進行中 plan / sow / prompts
│   │   ├── plan_YYYYMMDD_*.md
│   │   ├── sow/
│   │   └── prompts/
│   └── archive/                       ← 完了済み
│
├── setup/
│   └── setup_rules.md                 ← bootstrap 手順
│
└── src/                               ← Product workspace (新規 project 用、optional)
```

---

## 18. Maturity & Status

### crate / subsystem 別

| Subsystem | Maturity | 根拠 |
|---|---|---|
| `agent-core` | **High** | 22 subcommand、363 lib + 50+ integration tests、6 specialty が projection 有効、4 lint subsystem (envelope/execplan/specialty/...) で R1-R15 + 5 hard rules、新規 `secret scan` Rust scanner + `semantic gc` CLI |
| `semantic-mcp` | **High** | 8 MCP tool、FTS5 BM25、context_token replay-resistance、capsule SHA256 binding、183 lib tests + benchmark |
| `tree-sitter-index` | **High** | 6 言語 grammar version tracking、incremental cache、54 default / 69 all-languages tests |
| `harness-cache` | **High** | LRU + 220 token cap、_cache_meta versioning、43 lib tests |
| `hook-review-queue` | **Medium** | 単目的 binary、強い path validation、13 lib tests。tracing なし |
| `shared` | **High** | 全 crate 共通、freshness invariant の中心、`semantic_gc` / `semantic_lock` 抽出、41 lib tests |
| Shell scripts | **High** | 35+ fail-closed、canonical guard + outbound deny + shim log、Rust 側に委譲済み |
| Skills + specialties | **High** | 100% provider parity (`.claude/skills` ↔ `.agents/skills` + `.cursor/skills/` canonical path)、394 件 SKILL.md Cursor 公式 spec compliance test、6 projected with role-aware body、structural lint R13/R14/R15 |
| Cursor integration | **High** | Cursor 公式 Rules system (`.cursor/rules/*.mdc` alwaysApply + description) + Agent Skills system 経路 documented、wrapper preflight + dual telemetry + ask diff gate + parent-process outbound deny |
| Truth docs | **High** | 18 manual doc + cursor-rules-residual-risks.md、3 role doc、matrix-vocabulary.json (sync guard) |
| Tests | **High** | 1,633+ deterministic check (Rust 1,116 + shell 517+)、fake-codex / fake-cursor で CI 0-cost |

### 直近の検証 (2026-05-21)

- Opus 4.7 × Codex (gpt-5.5) 4 ラウンドの substantive grading で 9 / 9 項目 ≥90 を両 grader で達成
- End-to-end acceptance drill (`task-stamp` CLI を 6 slice ExecPlan で実装) で **15 / 15 LGTM 条件 PASS**
  - 全 role (orchestrator + research + coder + high-coder + reviewer × 2) 経路、specialty 4 種、semantic capsule (`context_token` 一致 + `FILE_SHA_ROLLUP`)、execplan/specialty/envelope lint 全 clean、metrics 全 wrapper invocation で 1 行/回、review/fix loop (BLOCK → fix → LGTM) 全部実走
- main 直近の 4 PR (merge commit):
  - `910ee38` PR #5 envelope toolchain + specialty projection (19 commits / 115 files / +9,974 LOC)
  - `9f940f3` PR #6 cursor wrapper (round 1-4、ask/agent/yolo roles align to Cursor 公式 mode)
  - `1a146df` PR #7 gap-fix (semantic-gc CLI + secret-scan Rust scanner + git hook installer)
  - `d8f9ec0` PR #8 cursor rules integration (round 5、`.cursor/rules/` + `.cursor/skills/` + AGENTS.md + CLAUDE-LOCAL.md migration + outbound deny + ask diff gate)、双方 grader 5/5 axes ≥9.0/10

### 既知の制約

- `claude-wrapper.sh` は 2026-07-14 で削除予定 (legacy shim)
- `scripts/semantic-mcp-server/` (Node.js compat) は新規利用非推奨、Rust 側に統合済み
- GitHub Actions CI は別途 billing 設定が必要 (PR #5 では billing 未解決のため local 検証のみで merge)
- semantic-mcp の `file_parse_cache` populate には `agent-core context index-symbols` の事前実行が必要

---

## 19. Customization & Contributing

### Adding a new specialty

1. `docs/roles/<role>/specialties/<slug>.md` を作成 (先頭に embedded JSON manifest、続けて required output sections の本文)
2. `cargo run -p agent-core -- specialty lint <file>` で R1-R15 を pass
3. `thin_skill_projection.enabled: true` にすれば `cargo run -p agent-core -- specialty project --all --provider all` で `.claude/skills/` + `.agents/skills/` に role-aware SKILL.md が自動生成

### Adding a vocabulary key

1. `docs/manual/matrix-vocabulary.json` に追加 (or `_policy.domain_local.<namespace>` に declare)
2. `scripts/check-matrix-vocabulary-sync.sh` を通す (hash 同期)
3. `verification-truth-matrix.md` の vocabulary-rev marker を更新

### Adding a wrapper role

`scripts/codex-wrapper.sh` の role 解決を拡張し、`test/unit/test-wrapper-specialty.sh` に test を追加。non-canonical path / role escape は fail-closed のまま維持。

### Adding a Cursor rule

`.cursor/rules/` に `.mdc` file を追加する場合は、既存の `revharness-critical.mdc` / `revharness-detailed.mdc` と同じ frontmatter contract に揃え、`bash test/unit/test-cursor-rules-frontmatter.sh` で deterministic subset を固定してください。Vendor-neutral invariant は `AGENTS.md`、Cursor-only guidance は `.cursor/rules/` に置きます。

### Adding a Cursor skill

Cursor Agent Skills は `.agents/skills/`、`.claude/skills/` (legacy compatibility)、`.cursor/skills/` の 3 path を意識して扱います。新規 skill は `SKILL.md` frontmatter に `name:` と `description:` を持たせ、`name:` は parent folder と一致させ、`bash test/unit/test-cursor-skills-compliance.sh` を通してください。既存 knowledge-pack compatibility alias 以外の新規 alias は別 slice で命名方針を更新してから追加します。`.cursor/skills/` に直接置く場合も `.agents/skills/` との provider parity を維持します。

### Install secret-scan hook

pre-push で staged/ref tuple ベースの secret scan を有効化するには、managed hook を install します。既存 hook がある場合は marker を確認し、non-managed hook は上書きせず手動統合手順を表示します。

```bash
scripts/rev-harness-secret-guard.sh install-hook --type pre-push
```

### Pointers

- 全体運用方針: `docs/manual/worldclass-harness-operating-model.md`
- maintainer 向け playbook: `docs/manual/agent-maintainer-guide.md`
- 新規 customization: `docs/manual/developer-customization-guide.md`
- skill 統合契約: `docs/manual/skill-integration.md` + `docs/manual/skill-routing-matrix.md`

---

## License & Distribution

新しい GitHub URL / release tag / package coordinates / distribution channel は **TBD**。本 README は repo rename / push / tag / package publish が完了したとは主張しません。

Canonical machine name は **`rev_harness`**、display name は **`Revharness`**。`agent_base` / `agent-base` は legacy alias として、既存 checkout / migration detection / 検索性のために維持されています。
