# semantic-mcp-server

> **Note (frontier-push 後)**: 本 Node TS server は Rust replacement (`harness-rust/crates/semantic-mcp/`) と並行運用されており、`top_k_symbols` caller-provided ケースは **`if false` で quarantine** されています。新 contract (`context_token` 必須、FILE_SHA_ROLLUP binding) は Rust 側のみで実装済み。Node 側の parity 復元は別 plan。canonical reference は `.claude/skills/revharness-semantic-mcp-usage/SKILL.md`。

`semantic-mcp-server` は、`agent_base` の semantic registry、preflight coordination、capsule compaction、review queue durable state を支える repo-local MCP runtime です。

## Current Scope

現在の stable surface は次です。

- stdio transport の MCP server
- SQLite durable store
- project-scoped database path: legacy fallback path `~/.semantic-mcp/{project_id}/semantic.db`。現 canonical は `revharness-semantic-mcp-usage` skill の placement v2 を参照してください。
- preflight coordination
  - target-lock
  - ambiguity
  - duplicate-risk
- capsule compaction
  - compacted output でも `TARGET_LOCK` / `AMBIGUITY` / `DUPLICATE_RISK` を保持
- semantic registry
  - upsert
  - query
  - set_status
  - delete
- health surface
- review queue / review run CLI helpers

## MCP Tools

registered tool names:

- `sem.preflight`
- `sem.capsule`
- `sem.registry.upsert`
- `sem.registry.query`
- `sem.registry.set_status`
- `sem.registry.delete`
- `sem.health`

tool schema と server-side types の source of truth は `src/server.ts` と `src/types.ts` です。

## Database

- path: legacy fallback path `~/.semantic-mcp/{project_id}/semantic.db`。現 canonical は `revharness-semantic-mcp-usage` skill の placement v2 を参照してください。
- clean distribution rule: do not ship this DB. It is regenerated on first use
  from `.shared/project_id`, repo-local configuration, and the semantic MCP
  launcher. If the DB is missing after cleanup or adoption, start
  `scripts/launch-semantic-mcp.sh` or run the explicit reindex workflow instead
  of restoring an old development DB.
- required tables:
  - `projects`
  - `components`
  - `registry_deltas`
  - `capsules`
  - `outbox_queue`
  - `review_queue_items`
  - `review_runs`

DB PRAGMA と migration detail は runtime 実装に従います。運用上は、この DB を host-local durable authority と見なし、`.claude/tmp/**` や JSON export を正本扱いしません。

## Install

```bash
npm --prefix scripts/semantic-mcp-server install
```

## Build And Test

```bash
npm --prefix scripts/semantic-mcp-server run build
npm --prefix scripts/semantic-mcp-server test
```

## Run

repo-local launcher を使うのが canonical です。

```bash
./scripts/launch-semantic-mcp.sh
```

直接 server 起動する場合は、flag-led な server-style invocation で `project_id` を明示します。未知の positional token と未知 flag は server mode にフォールバックせず fail-closed します。

```bash
npm --prefix scripts/semantic-mcp-server run dev -- --project-id demo
npm --prefix scripts/semantic-mcp-server start -- --project-id demo
```

`--project-id <id>` は必須です。環境変数による暗黙注入は前提にしません。

## Auto-Start Parity

この repo では、semantic MCP は Claude / Codex の両方から repo-local 設定で自動起動します。

- Claude: `.claude/settings.json`
- Codex: `.codex/config.toml`
- command: `./scripts/launch-semantic-mcp.sh`

## Queue / Review CLI

MCP tool とは別に、repo-local semantic-mcp backend には review queue と review-run record 用の CLI surface があります。public / caller-facing な queue entrypoint は引き続き `scripts/semantic-review-queue.sh` で、この README の直接 CLI 例は backend compatibility / debug 用です。caller-facing な public ingress としてサポートする起動方法は実行ビット付きの `./scripts/semantic-review-queue.sh ...` で、absolute shebang から起動します。`bash scripts/semantic-review-queue.sh ...` のような明示 interpreter override は shebang hardening を迂回するため public contract には含めません。shell adapter は `harness-rust/` workspace、`harness-rust/Cargo.toml`、`harness-rust/crates/semantic-mcp/src/main.rs` の 3 path が存在し、かつ各 path が repo-local real-path validation を通る場合に限って Rust の `semantic-mcp` CLI を使います。manifest 不在に限らず、この 3 path のいずれかが欠ける場合や、これらの path が symlink component を含む、または repo 外へ解決されるため repo-local real-path validation を通らない場合は repo-local Node CLI にフォールバックします。Node fallback 側でも `scripts/semantic-mcp-server/dist/cli.js` が repo-local real file でなければ fail-closed です。runtime 解決は safe な PATH 上の先頭候補を基準にし、rustup/mise shim に当たった場合は `rustup which cargo` / `mise which <bin>` で active に選択された concrete executable を引きます。install/toolchain の走査で別 version を推測せず、lookup に失敗するか shim/proxy しか返せない先頭候補は fail-closed です。

public shell ingress の例:

```bash
./scripts/semantic-review-queue.sh enqueue --file-path src/app.ts
./scripts/semantic-review-queue.sh lease --lease-run-id demo-run --lease-seconds 600
./scripts/semantic-review-queue.sh export-json --output /tmp/review-queue.json
```

`./scripts/semantic-review-queue.sh enqueue --file-path ...` の omitted `--source` は public/manual ingress として `manual` に正規化します。hook ingress は `--source hook` を明示的に渡す contract です。

direct backend invocation の例:

```bash
cargo run --quiet --manifest-path harness-rust/Cargo.toml -p semantic-mcp -- project-id validate --value demo
cargo run --quiet --manifest-path harness-rust/Cargo.toml -p semantic-mcp -- queue enqueue --project-id demo --repo-root <repo> --file-path src/app.ts
cargo run --quiet --manifest-path harness-rust/Cargo.toml -p semantic-mcp -- queue lease --project-id demo --lease-run-id demo-run --lease-seconds 600
cargo run --quiet --manifest-path harness-rust/Cargo.toml -p semantic-mcp -- queue export-json --project-id demo --output /tmp/review-queue.json
cargo run --quiet --manifest-path harness-rust/Cargo.toml -p semantic-mcp -- review-run record --project-id demo --input /tmp/review-run.json
```

`queue enqueue` は direct backend では `--repo-root` 必須です。wrapper/public ingress では repo root を自動解決します。

Node backend を direct invocation で確認したい場合は、同じ verb 群を `node scripts/semantic-mcp-server/dist/cli.js ...` で実行できます。たとえば `node scripts/semantic-mcp-server/dist/cli.js queue enqueue --project-id demo --repo-root <repo> --file-path src/app.ts` のように呼びます。ただし caller-facing な queue ingress としては扱いません。

`queue complete` と `queue requeue` は、shell adapter / direct backend CLI のどちらから到達しても strict expected files を要求します。`--expected-file` を省略した completion / requeue は受け付けません。

Node / Rust direct backend CLI は `project-id validate` の normalization と `unknown command` failure wording を parity contract として共有します。drift は `test/integration/semantic_cli_contract_parity_test.sh` と unit test で fail-closed に検出します。

## What This README Is Not

この README は stable backend/runtime reference です。public queue ingress の cutover 完了や latest rerun result、latest reviewer sign-off をここに固定しません。最新の evidence は `.claude/tmp/harness-release-gate/<timestamp>/summary.md`、`.agent/active/sow/*.md`、`.agent/active/prompts/*.md` を見てください。
