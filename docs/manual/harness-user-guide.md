# Harness User Guide

## 0. Operating Truth

- authoritative full rerun command は `bash test/integration/harness_release_gate.sh` です。
- Codex / Opus の cross-family coordination は artifact packet と lease closeout が正本です。`bash test/integration/cross_family_artifact_smoke_test.sh` は deterministic contract smoke であり、live CLI conversation の成功主張とは分けて扱います。
- live Codex / Opus smoke を実行する前には `bash scripts/cross-family-live-smoke-preflight.sh check --json --workspace workspace/<task> --artifact-root .claude/tmp/<task>` を通してください。この preflight は read-only で、モデルプロセスを開始せず、成功しても live conversation 完了の証明にはなりません。
- 実際の短命 Codex -> Opus artifact smoke は `bash scripts/cross-family-live-artifact-smoke.sh --json` です。これは subscription CLI を使うため default CI では走らせず、GitHub Actions の `workflow_dispatch` で `live_cross_family_smoke=true` を指定した時だけ opt-in 実行します。
- cleanup / self-cleaning は inspect / dry-run / proposal-first です。release gate の janitor step は `inspect --json` に加えて `delete_enabled=false` / `archive_enabled=false` / `apply_enabled=false` を検証し、証跡を無人削除しません。
- benchmark / memory evidence の canonical benchmark surface は `scripts/harness-benchmark.sh` です。required args は `bash scripts/harness-benchmark.sh --help` で確認してください。
- この manual は stable guidance です。最新 rerun 結果、最新 artifact、最新 sign-off level はここに固定しません。
- volatile evidence は、current dated SOW / handover（`.agent/active/sow/*.md` と `.agent/active/prompts/*.md`）および `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`（latest pointer は `.claude/tmp/harness-release-gate/latest.json`）を参照してください。
- fresh external reviewer `LGTM` が dated evidence として記録されるまでは、現在の境界は `full gate green` / `test-backed local sign-off` として扱ってください。

## 1. このハーネスは何か

このハーネスは、Claude Code と Codex を同じリポジトリ内で安全に協調させるための、repo-local 運用基盤です。

v0.11.0 以降の canonical display name は `Revharness`、canonical machine name は `rev_harness` です。`agent_base` と `agent-base` は legacy alias として、既存 checkout、古い install、migration detection、検索性のために扱います。新しい GitHub URL、release tag、package coordinates、distribution channel は `TBD` であり、この guide は repo rename、push、tag、package publish が完了したとは主張しません。

目的は 3 つです。

- 役割を分けること
  - Coder、Reviewer、Orchestrator の責務を分離する
- 実行境界を固定すること
  - wrapper、sandbox、approval、project identity、DB authority を fail-closed に保つ
- 継続運用しやすくすること
  - ゼロコンテキストの次担当でも、正本ファイルを読めば再開できる

この repo は「巨大な monolithic plugin」を目指していません。repo の外に authority を逃がさず、repo core と local intelligence を残したまま、native capability と薄い coordinator を組み合わせる方針です。plugin / MCP の境界判断は `docs/design/harness-plugin-boundary.md` と `docs/design/harness-plugin-mcp-trust-matrix.md` が正本です。

### Canonical Operating Model

Revharness v0.11.0 の canonical operating model は source-centric です。新規 Revharness project では、実際の target system / product code を `src/` 配下で開発することを既定にします。Harness surface は、その `src/` 開発を計画、検証、レビュー、昇格、保護するための substrate です。

運用上は次の 3 層で考えると境界を崩しにくくなります。

1. `Framework / Core Harness`
   - harness framework、wrapper、policy doc、CI gate、integration surface
2. `Project State`
   - `.agent/**`、project-local context、active plan / SOW / prompt、evidence pointer
3. `Product Code`
   - project 自身の codebase。新規 Revharness project の既定配置は `src/`

既存 adopted projects は explicit compatibility / overlay path として project-native layout を維持できます。`apps/`, `packages/`, `services/` などの既存配置を `src/` へ強制移設しません。ただし新規 Revharness project の primary model は `src/` です。overlay `install-harness` / `adopt-harness` / `upgrade-harness` の最終的な external distribution contract は `TBD` です。

## 2. Historical Baseline

この表は 2026-04-06 時点の historical baseline です。client-ready distribution では古い `.agent/archive/**` の plan / SOW / handover 本体は同梱しません。現在の rerun 状態や最新 boundary health は current dated SOW / handover と最新 artifact で再確認してください。

| Phase | 名称 | 状態 |
| --- | --- | --- |
| 0 | Baseline and Invariants | 完了 |
| 1 | Runtime Defaults and Profile Convergence | 完了 |
| 2 | Native Surface Migration | 完了 |
| 3 | State and Memory Convergence | 完了 |
| 4 | Shell and Coordinator Reduction | 完了 |
| 5 | Plugin-Ready Boundary, Not Plugin Monolith | 完了 |
| 6 | Verification and Rollout | historical baseline では release gate green を記録 |

運用上の結論は、この表を historical baseline として使うことです。最新の rerun 成否や reviewer-accepted completion は、この表ではなく current dated evidence で判断してください。

## 3. まず読む順番

ゼロコンテキストで着任した運用担当は、次の順で読んでください。

1. `AGENTS.md`
2. `.agent_rules/RULES.md`
3. `.agent/PROJECT_CONTEXT.md`
4. `docs/manual/end-user-guide.md`
5. `docs/manual/common-task-contract.md`
6. `docs/roles/coder.md`
7. `docs/roles/reviewer.md`
8. `docs/roles/orchestrator.md`
9. `docs/design/harness-plugin-boundary.md`
10. `docs/design/harness-plugin-mcp-trust-matrix.md`
11. `docs/manual/harness-release-gate.md`

ここで重要なのは、`AGENTS.md`、`.agent_rules/RULES.md`、`.agent/PROJECT_CONTEXT.md`、`docs/roles/*.md` が日常運用の正本であり、配布版から削除された古い plan や古い handover は runtime truth ではない、という点です。

## 4. 実務アーキテクチャ

このハーネスは、実務上は 5 層で理解すると迷いません。

```mermaid
flowchart TD
    A[Repo Core] --> B[Native Capability Layer]
    B --> C[Thin Coordinator]
    C --> D[Common Task Contract Layer]
    D --> E[Local Intelligence Layer]
    E --> F[(<data_root>/Revharness/semantic-mcp/v1/{project_id}/semantic.db)]
```

### Repo Core

repo の方針・安全境界を持つ層です。

- `AGENTS.md`
- `.agent_rules/RULES.md`
- `.agent/PROJECT_CONTEXT.md`
- `.codex/config.toml`
- `.claude/settings.json`

### Native Capability Layer

CLI が本来持っている機能を使う層です。

- `.codex/agents/*.toml`
- `.claude/skills/*.md`
- Claude / Codex の native multi-agent、subagent、skill、hook、MCP

### Thin Coordinator

実行入口と fail-closed routing を持つ薄い層です。

- `scripts/codex-wrapper.sh`
- `scripts/claude-wrapper.sh`
- `./.claude/commands/auto_orchestrate.sh`
- `./.claude/commands/lib/*.sh`

### Common Task Contract Layer

orchestrated coder run の前に scope / checks / task-contract runtime artifact destination を machine-readable に固定する層です。planning / review の canonical field 名は引き続き `evidence destination` であり、task-contract runtime ではその保存先を `artifact_destination` として保持します。

- `./.claude/commands/lib/task_contract.sh`
- `.claude/tmp/<task>/task-contract.json`
- `.claude/tmp/<task>/state.json`

current task-contract surface では、少なくとも次を持つ contract を emit / validate します。

- `task_id`
- `plan_path`
- `phase`
- `coder_engine`
- `in_scope`
- `out_of_scope`
- `required_checks`
- `artifact_destination` (`evidence destination` の runtime artifact path)
- `completion_boundary`
- `allowed_capabilities`

### Local Intelligence Layer

repo-local durable state と analysis を持つ層です。

- `harness-rust/crates/semantic-mcp/**`
- `scripts/launch-semantic-mcp.sh`
- `scripts/project-id.sh`
- `scripts/resolve-semantic-project-id.sh`
- `<platform data dir>/Revharness/semantic-mcp/v1/{project_id}/semantic.db`
- `.shared/project_id`

実務上の重要点は、durable authority は `semantic.db` であり、`state.json` や JSONL は原則として scratch / export / cache だということです。`task-contract.json` は runtime envelope であり、acceptance 正本そのものではありません。acceptance は引き続き `docs/manual/verification-truth-matrix.md` が正本です。

Client-ready distribution does not ship `<platform data dir>/Revharness/semantic-mcp/v1/{project_id}/semantic.db`. The semantic database is regenerated on first use from `.shared/project_id` and the semantic MCP launcher. If the database is missing, start the semantic MCP through `scripts/launch-semantic-mcp.sh` or run the project's explicit reindex/doctor workflow; do not restore old DB files from prior development sessions.

## 5. 正本ファイルと歴史ファイル

### 今日の正本

運用判断で迷ったら、次を優先します。

- `AGENTS.md`
  - Codex 側の wrapper 契約、role、session 制約、multi-agent 境界
- `.agent_rules/RULES.md`
  - repo-wide hard rule、phase process、worktree 例外
- `docs/manual/verification-truth-matrix.md`
  - acceptance / truth placement / reviewer LGTM validity の正本
- `.agent/PROJECT_CONTEXT.md`
  - この repo をどう使うかという project-local context
- `docs/roles/*.md`
  - 役割ごとの責務と出力フォーマット
- `.codex/config.toml`
  - Codex の shared safe defaults、native agent 登録、semantic MCP 登録
- `.claude/settings.json`
  - Claude hook と semantic MCP 登録
- `docs/manual/common-task-contract.md`
  - common task contract Slice A の stable guide
- `docs/design/harness-plugin-boundary.md`
  - plugin-ready boundary の正本
- `docs/design/harness-plugin-mcp-trust-matrix.md`
  - plugin / MCP trust decision の正本
- `docs/manual/harness-release-gate.md`
  - harness release gate の正本
- `test/integration/harness_release_gate.sh`
  - 実行可能な最終ゲート

### 歴史・背景として読むもの

次は背景理解には有用ですが、runtime truth ではありません。

- 配布版から削除された historical archive artifacts
- それ以前の `harness-completion` / `harness-perfectization` 系 plan
- 2026-04-05 以前の handover / SOW
- `docs/README.md` や repo root の README の要約記述

特に、summary 文書と正本文書が衝突したら、summary 側ではなく正本側を採用してください。

## 6. ディレクトリマップ

採用時に最低限覚えるべきパスは次のとおりです。

| パス | 用途 |
| --- | --- |
| `.agent/` | 要件、ExecPlan、SOW、handover、archive |
| `.agent/active/` | 現在進行中の計画、prompt、SOW |
| `.agent_rules/RULES.md` | 共通 hard rule |
| `.shared/project_id` | authoritative project identity artifact path。通常は repo-local `.shared/project_id` で、pointer-back 検証を通った正当な linked worktree だけ common identity root 側へ解決される |
| `.claude/commands/` | Claude 系の実行入口 |
| `.claude/hooks/` | PostToolUse hook など |
| `.claude/settings.json` | Claude hook / semantic MCP 登録 |
| `.claude/tmp/` | run-local scratch。authority ではない |
| `.claude/tmp/<task>/task-contract.json` | current orchestrated run の common task contract artifact |
| `.codex/config.toml` | Codex baseline config、native agents、semantic MCP 登録 |
| `.codex/agents/` | Codex native subagent preset |
| `docs/design/` | 境界設計、信頼境界、その他設計 |
| `docs/manual/` | 運用マニュアル |
| `docs/roles/` | 役割定義 |
| `scripts/` | wrapper、Hydra、project_id、semantic runtime |
| `scripts/semantic-review-queue.sh` | review queue の public shell ingress / adapter（Rust backend path が repo-local real-path validation を通る場合に Rust CLI を起動し、それ以外は fail-closed。旧 Node fallback は de-overkill S3-B3 で削除） |
| `harness-rust/crates/semantic-mcp/` | semantic-mcp backend（Rust 実装。唯一の対応バックエンド） |
| `.agent/skills/rustskills-architecture/` | RustSkills canonical source。backend / runtime / control-plane で Rust-first が合理的な作業に使う |
| `.claude/skills/rustskills-architecture/` | RustSkills Claude projection |
| `.agent/generated/skills/codex/rustskills-architecture/` | RustSkills Codex projection bundle |
| `test/integration/` | harness regression suite |
| `workspace/` | Hydra worktree 用。恒久配置しない |

## 7. 役割

### Orchestrator

Orchestrator は top-level runtime に合わせて dual-native で統括します。Claude Code 側で起動しているなら Claude-native subagents / Task-agent teams を使い、Codex 側で起動しているなら Codex native subagents / `.codex/agents/*.toml` を使います。役割定義は `docs/roles/orchestrator.md` を見てください。タスク分割、割り当て、進捗管理、handover、documentation provenance の責任を持ちます。

### Coder

実装担当です。役割定義は `docs/roles/coder.md` を見てください。Claude でも Codex でも実行できますが、external/manual な Codex 実行は wrapper 契約に従います。

### Reviewer

レビュー担当です。役割定義は `docs/roles/reviewer.md` を見てください。外部 reviewer は Codex 固定で、caller-facing / manual / external 実行は常に `scripts/codex-wrapper.sh --role reviewer` です。

## 8. Wrapper 方針

この repo では、Codex の caller-facing / manual / external 実行は `scripts/codex-wrapper.sh` が canonical entrypoint です。

### 外部から Codex を起動するときのルール

- `codex exec` を直接呼ばない
- `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使う
- `reviewer` は Reviewer 専用で、`scripts/codex-wrapper.sh --role reviewer` 固定
- `scripts/codex-wrapper-medium.sh`、`scripts/codex-wrapper-high.sh`、`scripts/codex-wrapper-xhigh.sh` は互換 shim であり source of truth ではない
- `-c model=...`、`-c model_reasoning_effort=...` などで勝ち筋を変えない
- `--cd` と `--add-dir` は caller から前提にしない

### Wrapper role と意味

| role | 用途 |
| --- | --- |
| `standard` | 軽量な標準実行 |
| `research` | 外部調査を伴う実行 |
| `coder` | 実装タスクの既定 |
| `reviewer` | レビュー専用 |

### Codex-native multi-agent の no-wrapper rule

ここが最重要です。

Codex の native multi-agent / subagent orchestration は、すでに起動済みの Codex セッション内部で完結させます。`scripts/codex-wrapper.sh` を再帰的に呼び出してはいけません。

実務上の解釈は次のとおりです。

- 外から Codex を起動する時だけ wrapper を使う
- いったん Codex が起動した後の subagent / preset は `.codex/config.toml` と `.codex/agents/*.toml` に従う
- external role 契約と native preset を混同しない

たとえば `.codex/config.toml` は top-level default と native agent 登録を持ち、`.codex/agents/coder.toml` などは internal preset を持ちます。しかし external/manual 実行時の runtime truth はあくまで wrapper です。

### Dual-native orchestration rule

Claude と Codex は、それぞれ自前の native multi-agent surface を持つ前提で扱います。

- Claude top-level orchestrator: Claude Code native subagents / Task-agent teams を使う。同一 family delegation のために `scripts/claude-wrapper.sh` を再帰起動しない
- Codex top-level orchestrator: Codex native subagents / `.codex/agents/*.toml` を使う。同一 family delegation のために `scripts/codex-wrapper.sh` を再帰起動しない
- Cross-family Claude / Codex: durable artifact packet、lease closeout、deterministic evidence を使う。live chat は completion evidence にしない
- 外部から Codex を起動する manual/caller-facing 経路だけ `scripts/codex-wrapper.sh --role ...` を使う

この境界は速度と負荷のためのルールでもあります。同じ family 内の delegation を wrapper 経由で多重起動すると、プロセス・コンテキスト・ログが増え、`light / standard / heavy` の意味が崩れます。

## 8.5. Current Orchestrated Flow

current の実装済みフローは、少なくとも次です。

1. ExecPlan を用意する
   - 新規 ExecPlan は `docs/manual/execplan-checklist-standard.md` に従い、`Status Board` と `Slice Board` を checkbox で持つ
2. `./.claude/commands/auto_orchestrate.sh --plan <plan> --phase impl --run-coder` を実行する
3. orchestrator が `task-contract.json` を emit / validate する
4. coder が実装する
5. reviewer が review loop を回す
6. `required_checks` と `harness_release_gate` で最終確認する

この時点で未実装なのは、browser evidence の default rollout や policy compiler です。roadmap で議論している Playwright / Chrome DevTools MCP / Browser Use は current stable flow ではありません。

## 8.6. Lightweight Operating Modes

日常開発では、release closeout と同じ重さの手順を毎回実行しません。`dev` / `review` / `release` の 3 mode を使い分けます。

Task-size / risk routing uses the executable classifier `scripts/rev-harness-task-classifier.sh`: `light = dev + quick`, `standard = review + local`, and `heavy = release + full`. The older `lightweight` wording remains a historical alias only. The classifier does not replace `docs/manual/verification-truth-matrix.md` or release-gate authority.

Orchestrator may handle only the narrow `light` subset directly: non-normative typo fixes, prompt wording, admin bookkeeping, or reference cleanup that does not touch runtime code, role/policy/skill behavior, wrapper/model-policy, semantic MCP/index/registry/review queue, security/trust boundaries, release/tag/merge, gate-runner/release-gate evidence, acceptance/final-signoff, or another high-risk surface. Ambiguous scope escalates to `standard` or `heavy` and uses the normal implementation, review, and release discipline.

Routine work should keep the active surface small. The minimum active set is the current user request, the applicable ExecPlan or SOW when one exists, the task lineage ledger when lineage is part of the slice, the touched source files, and the exact deterministic check output needed for the next gate. Do not add tracked evidence manifests, dirty-surface manifests, reviewer prompt artifacts, or final evidence packets for ordinary `dev` / `review` iterations when current repository state and check output are sufficient.

Reviewer intake is volatile review input generated from current facts: `git status`, current diff/stat, required check commands and results, and the relevant plan/SOW scope. It is not acceptance truth, not durable evidence, and not a normal-work tracked manifest. If an intake packet needs to be materialized, write it to stdout or a run-local `.claude/tmp/**` path; otherwise summarize the same current facts in the review handoff. Do not introduce a registry, daemon, queue, durable manifest, or control-plane subsystem for this packet.

| Mode | 用途 | 既定の確認 |
| --- | --- | --- |
| `dev` | 通常の実装ループ | changed files から選んだ syntax / focused tests |
| `review` | reviewer に出す直前 | `dev` checks plus review surface checks |
| `release` | release candidate / closeout | authoritative `bash test/integration/harness_release_gate.sh` |

Planned harness work では approved ExecPlan が引き続き実装許可境界です。ただし `dev` mode の各 iteration では、SOW / ledger 更新、full artifact traceability、reviewer LGTM、release gate を既定要求にしません。これらは `review` / `release` 境界で必要に応じて戻します。

changed files から候補 checks を出すには、次を使います。

```bash
bash scripts/harness-check-planner.sh --mode dev -- docs/manual/harness-user-guide.md scripts/harness-check-planner.sh
bash scripts/harness-check-planner.sh --mode review -- docs/manual/harness-user-guide.md .claude/skills/auto-orchestrator/SKILL.md
```

`review` mode の候補 check output は reviewer intake に含める current fact であり、tracked manifest 化しません。`release` mode では必ず authoritative release gate が候補に含まれます。

## 8.7. Typed BLOCK Routing

通常開発ループでは、すべての `BLOCK` を同じ重さで扱いません。軽量ルーティングでは次の 4 種類に分けます。

| Type | Owner | Meaning |
| --- | --- | --- |
| `code-block` | coder | 実装またはテストを直して targeted checks を再実行する |
| `process-block` | orchestrator | plan、ledger、artifact、check record の不整合を直す |
| `governance-block` | user-or-orchestrator | 明示的な判断、scope change、policy exception が必要 |
| `terminal-block` | user | その lineage を止め、新しい明示 task が必要 |

この分類は release acceptance を置き換えません。目的は、修正可能な code/process 問題をすぐ担当へ戻し、user decision が必要なものだけを重く止めることです。

ルーティング契約は `.agent/registry/harness_block_routing.json` にあり、確認には次を使います。

```bash
bash scripts/harness-block-router.sh --type code-block
bash scripts/harness-block-router.sh --type governance-block --json
```

## 8.8. Projection Schema Preflight

reviewer verdict から next status への projection 契約は `.agent/registry/orchestration_policy_projection.json` にあります。通常開発では、重い orchestration runtime を起動する前に軽量 preflight で schema と既知 status を確認できます。

```bash
bash scripts/harness-projection-preflight.sh --validate
bash scripts/harness-projection-preflight.sh --list-statuses
bash scripts/harness-projection-preflight.sh --status "pending acceptance" --json
bash scripts/harness-projection-preflight.sh --status "blocked" --field matching_review_verdicts
```

この preflight は projection / next-status registry の構造と既知 status を fail-closed で確認するためのものです。acceptance semantics、release readiness、reviewer LGTM validity は書き換えず、引き続き `docs/manual/verification-truth-matrix.md` と current dated review evidence が正本です。

## 8.9. Shadow Verify Runtime Bridge

`shadow_verify.sh run` は temporary worktree に changed files を overlay した後、既存 lint / typecheck / test / quality gate の前に lightweight planner bridge を実行します。

bridge は `scripts/harness-check-planner.sh --mode review -- <changed files>` が出した repo-local planned commands だけを対象にし、現行 planner の deterministic command vocabulary に一致する行だけを実行します。planned check failure、planner failure、planner missing は shadow verify failure として扱われます。

failure result には `harness_check_planner` と `block_route` が入り、detail log には `### [HARNESS_CHECK_PLANNER]` section と planner command log が残ります。この bridge は targeted review checks の runtime 接続であり、acceptance / release readiness / reviewer validity の正本は引き続き `docs/manual/verification-truth-matrix.md` と release gate evidence です。

## 8.10. Active Artifact Pruning

`.claude/tmp` は run-local scratch であり、authority ではありません。ただし active harness run artifacts は肥大化しやすいため、古い timestamp-shaped run directory、named mktemp scratch directory、または `artifact-lifecycle-manifest.json` を持つ managed run root を dry-run first で棚卸しできます。

```bash
bash scripts/harness-active-artifact-pruner.sh --root .claude/tmp/harness-release-gate --keep-latest 20 --max-age-days 14
```

default は dry-run です。移動する場合だけ `--execute` と repo-local `.claude/tmp` 配下の `--archive-dir` を明示します。helper は削除せず、candidate を archive directory へ移動します。

```bash
bash scripts/harness-active-artifact-pruner.sh \
  --root .claude/tmp/harness-release-gate \
  --keep-latest 20 \
  --max-age-days 14 \
  --execute \
  --archive-dir .claude/tmp/harness-release-gate/.archive
```

安全境界は fail-closed です。`--root` は repo-local `.claude/tmp` 配下の既存 non-symlink directory に限定され、空 root、`/`、repo 外 root、symlink root は拒否されます。latest pointer と pinned baseline は manifest field と pointer JSON で管理され、`latest_pointer != none` または `pinned_baseline != none` の managed run は archive candidate になりません。unmanifested legacy artifact は archive-only candidate までで、safe-delete candidate にはなりません。

JSON counts が必要な場合は `--json` を付けます。この helper は artifact hygiene 用であり、acceptance、release readiness、reviewer validity、release closeout の証拠や代替 gate ではありません。

Managed artifact manifest の最小 contract は `schema_version=artifact-lifecycle/v1` です。producer は `owner`, `producer`, `purpose`, `authority`, `task_id`, `slice_id`, `run_id`, `state`, `disposition`, `latest_pointer`, `pinned_baseline`, `run_disposable`, `supersedes`, `superseded_by`, `ttl`, `archive_after`, `safe_delete_after`, `safe_delete_class`, `manifest_path`, `created_at`, `completed_at` を記録します。canonical benchmark topology は `.claude/tmp/benchmarks/<task-id>/<slice-id>/runs/<run-id>/`, `.claude/tmp/benchmarks/<task-id>/<slice-id>/archive/<run-id>/`, `.claude/tmp/benchmarks/<task-id>/<slice-id>/baselines/<baseline-id>.json` です。

## 8.11. Development Junk Cleanup Skill

定期的な開発ジャンク整理は `.claude/skills/development-junk-cleanup/SKILL.md` を使います。この skill は新しい cleanup engine ではなく、既存の安全境界を持つ helper への routing layer です。

通常の入口は read-only です。

```bash
bash scripts/rev-harness-janitor.sh inspect --root .claude/tmp --json
bash scripts/rev-harness-janitor.sh plan --root .claude/tmp --json
```

active run artifact の候補確認は既存 pruner の dry-run を使います。

```bash
bash scripts/harness-active-artifact-pruner.sh --root .claude/tmp/harness-release-gate --keep-latest 20 --max-age-days 14 --json
```

MCP helper residue は report-first です。

```bash
bash scripts/cleanup-codex-mcp-zombies.sh report --include-semantic
```

この導線は削除を実行しません。live movement、PID cleanup、release/lineage evidence に関わる整理は、別sliceで plan / review / deterministic checks を通してから扱います。

## 8.12. Client Distribution Readiness Skill

クライアントへ渡す直前、tag/push 前、または「cleanup で見逃しがないか」を確認する場合は `.claude/skills/client-distribution-readiness/SKILL.md` を使います。これは日常の一時ファイル整理ではなく、配布物に古い履歴・ローカル絶対パス・古い semantic DB 前提・skill sync 漏れ・doctor の historical artifact 前提が残っていないかを inspect-first で確認する入口です。

基本確認:

```bash
jq empty .agent/registry/rev_harness_distribution_manifest.json .agent/registry/skill_projection_manifest.json .agent/registry/skill_routing_matrix.json
bash scripts/rev-harness-skill-routing-check.sh --json
bash scripts/rev-harness-skill-projection.sh --check --json
bash scripts/harness-doctor.sh --quick --json
```

この skill も削除を実行しません。tracked file の削除、distribution manifest 変更、doctor / skill projection / routing の変更は、通常 slice と reviewer gate を通して扱います。

`rev_harness_distribution_manifest.json` の `preserve_globs` は adoption / upgrade 時に既存プロジェクトのローカル状態を壊さないための保持対象です。クライアント配布物に含めない対象は `client_distribution.exclude_globs` で別管理します。少なくとも `.agent/archive/**`、`.claude/tmp/**`、`workspace/**`、legacy `~/.semantic-mcp/*/semantic.db`、および placement v2 の `<platform data dir>/Revharness/semantic-mcp/v1/*/semantic.db` は配布除外です。

## 9. Durable state と identity

このハーネスでは、repo identity と durable state を曖昧にしないことが重要です。

- `.shared/project_id`
  - authoritative project identity artifact。通常は repo-local `.shared/project_id` で、pointer-back 検証を通った正当な linked worktree だけ common identity root 側へ解決される
- `.agent/project_id`
  - legacy identity artifact。`.shared/project_id` と一致すれば `aligned`、両方が valid で値が違えば `warn-drift`、canonical authority が欠落または不正なら `block-authority-ambiguous`
- `<platform data dir>/Revharness/semantic-mcp/v1/{project_id}/semantic.db`
  - semantic registry、review queue、review trace などの durable authority
- `.claude/tmp/<task>/state.json`
  - active run の scratch state
- `.claude/tmp/review_queue.json`
  - 互換用の残存物として見なし、authority と見なさない
- `.agent/context/**` と `.agent/registry/*.jsonl`
  - export / cache / debug artifact として扱う
- `.agent/registry/policy_sources.json` と `.agent/registry/dependency_policy.json`
  - stable policy JSON として tracked のまま維持する

運用ルールは単純です。`semantic.db` を authority とし、JSON / JSONL / tmp を authority に戻さないでください。

identity drift と active/archive 候補は移動せずに先に確認します。

```bash
bash scripts/project-id.sh health
bash scripts/resolve-semantic-project-id.sh --health
bash scripts/project-id.sh active-audit
```

MCP helper residue は `scripts/cleanup-codex-mcp-zombies.sh` で分類します。Playwright / Computer Use / semantic MCP に加え、`chrome-devtools-mcp-zombie-report.md` と chrome-devtools MCP helper family は `zombie-report` lifecycle class の residual として扱い、root mystery として削除しません。

```bash
bash scripts/cleanup-codex-mcp-zombies.sh report --include-semantic
```

## 9.5 Semantic Target-Lock Preflight

semantic mutation 系の slice では、`sem.preflight` と `sem.registry.*` を advisory ではなく fail-closed boundary として扱います。

- `sem.preflight` は `target_lock`、`ambiguity`、`duplicate_risk` を返します。
- path/module 比較は `./`、`\`、case-only variant を canonicalize して判定します。表記ゆれで target-lock や ownership guard を迂回してはいけません。
- `target_lock.status == blocked` は、expected file target と proposal が食い違っている状態です。accept / mutation 継続ではなく `BLOCK` です。
- `ambiguity.status == blocked` は、既存実装に十分近い候補があり、target が曖昧な状態です。新規実装を黙って許可してはいけません。
- `duplicate_risk` は advisory に見える signal でも、`ambiguity` と組み合わさって `BLOCK` へ昇格しうるため、closeout では status と summary の両方を確認します。
- `sem.search` は bounded advisory discovery です。明示 `scope_paths` の中から候補 file / symbol / excerpt を探すだけで、acceptance truth、class-closure evidence、LGTM evidence、deterministic check の代替にはなりません。
- `sem.registry.upsert` は最終 guard です。payload が preflight をすり抜けても、target-lock mismatch や existing registry ownership mismatch を見つけた時点で mutation を止めます。
- preflight response が budget compaction に入っても、capsule から `TARGET_LOCK` / `AMBIGUITY` / `DUPLICATE_RISK` 行を落としてはいけません。closeout での fail-closed signal は保持されます。

つまり、repo-local durable authority に対する mutation は「preflight で止める」「registry で再度止める」の二段 fail-closed です。片方が赤なら、もう片方の green で相殺しません。

## 10. セットアップ

### 前提ツール

最低限、次が必要です。

- `git`
- `jq`
- `claude`
- `codex`
- `cargo`
- `node` / `npm`

`./scripts/hydra close` で PR を作るなら `gh` も必要です。

補足:

- `scripts/semantic-review-queue.sh` は caller-facing な public ingress です。サポート対象の呼び出し方は実行ビット付きの `./scripts/semantic-review-queue.sh ...` で、absolute shebang から起動します。`bash scripts/semantic-review-queue.sh ...` のような明示 interpreter override は shebang hardening を迂回するため、public 契約としては扱いません。
- `scripts/semantic-review-queue.sh` は `harness-rust/` workspace、`harness-rust/Cargo.toml`、`harness-rust/crates/semantic-mcp/src/main.rs` の 3 path が存在し、かつ各 path が repo-local real-path validation を通る場合に限って repo-local semantic-mcp backend（Rust）を使います。manifest 不在に限らず、この 3 path のいずれかが欠ける場合や、これらの path が symlink component を含む、または repo 外へ解決されるため repo-local real-path validation を通らない場合は fail-closed（"Rust semantic backend required"）です。旧 Node compatibility surface は de-overkill S3-B3 で削除済みで、escape env `REV_HARNESS_ALLOW_NODE_SEMANTIC` は no-op です。queue ingress / hook ingress は unsafe runtime resolution を検出した時点で fail-closed です。この経路では built-in の trusted runtime dir allowlist 上で canonical path matching により最初に見つかった `cargo` 候補だけを尊重し、trusted direct binary ならそのまま使い、rustup/mise shim なら `rustup which cargo` / `mise which cargo` で active に選択された concrete executable を引きます。install/toolchain を走査して別バージョンを推測しません。trusted roots は real-user canonical home を基準に固定され、caller-overridden な `HOME` では widen しません。built-in allowlist は `/usr/bin`、`/bin`、`/usr/local/bin`、`/opt/homebrew/bin`、`<real-user-canonical-home>/.cargo/bin`、`<real-user-canonical-home>/.rustup/toolchains/*/bin`、`<real-user-canonical-home>/.local/bin`、`<real-user-canonical-home>/.local/share/mise/{shims,installs/*/*/bin}`、`<real-user-canonical-home>/.mise/{shims,installs/*/*/bin}` を含みます。public env から trusted runtime dir を追加して widen する escape hatch はありません。canonical path matching を使うため、symlink 済み trusted dir と symlink binary は reject します。`$HOME/.local/bin/<bin>` と mise path は real-user canonical home trust root 配下にある場合だけ trusted です。temp fixture の `$HOME/.local/bin` や temp mise root は authoritative な trusted root になりません。shim 扱いは manager-owned path（`<real-user-canonical-home>/.local/share/mise/shims/<bin>`、`<real-user-canonical-home>/.mise/shims/<bin>`、`<real-user-canonical-home>/.cargo/bin/cargo`）に限定します。先頭 shim の lookup に失敗する、shim/proxy しか返せない、または manager が allowlist 外の binary を返す場合は後続 PATH に逃がさず fail-closed です。空 PATH 要素、`.`、相対 PATH entry、allowlist 外の absolute prefix は runtime 候補として数えません。
- semantic backend は Rust 専用です（`cargo` が必要）。`node` は generic trusted runtime としてのみ解決され（一部 tooling が `node` binary を必要とする）、semantic backend 自体は Node を使いません。旧 Node compatibility surface（`scripts/semantic-mcp-server/`）は de-overkill S3-B3 で削除済みです。trusted runtime 解決は同じ allowlist 上の先頭候補を基準にし、mise shim は `mise which <bin>` で active に選択された concrete executable を引ける場合だけ使い、install 走査で別 version を推測しません。canonical path matching を使い、symlink 済み trusted dir と symlink binary は reject します。temp fixture `$HOME/.local/bin` や temp mise roots は authoritative な trusted roots ではありません。空 PATH 要素、`.`、相対 PATH entry、allowlist 外の absolute prefix は runtime 候補に含めません。
- authoritative helper path は raw artifact bytes で `^[A-Za-z0-9_-]{1,64}\n?$` を満たす `.shared/project_id` だけを受け入れます。malformed、control-byte（CR byte と terminal CRLF を含む）、multiline の値は fail-closed で reject します。
- hook の poison-PATH に関する記述は blanket claim ではなく、focused repro で裏付けられた挙動だけを対象にします。

### 既存 adopted repo を compatibility / overlay path で運用する場合

既存 repo は native layout を維持できます。`src/` は新規 Revharness project の primary model ですが、採用済み project では compatibility / overlay path として `apps/`, `packages/`, `services/` などを明示し、無理に移設しません。

1. 依存を確認する

```bash
which git jq claude codex cargo node npm
```

2. semantic MCP backend (Rust) をビルドする

```bash
cargo build -p semantic-mcp --manifest-path harness-rust/Cargo.toml
```

3. project_id artifact を確認する

```bash
bash scripts/project-id.sh artifact-path
```

artifact がまだ無い、または adoption 直後で repo identity を初期化したい場合は、次を使います。

```bash
bash scripts/project-id.sh bootstrap <ProjectName>
```

### 新規 Revharness repo として採用する場合

`.agent/PROJECT_CONTEXT.md` にあるとおり、adoption 後に repo identity を作り直してください。新規 Revharness project では target system を `src/` に置きます。`agent_base` / `agent-base` literal は legacy alias であり、新しい canonical identity として流用してはいけません。external Revharness distribution URL は `TBD` です。

```bash
# external distribution URL is TBD until the Revharness repository/package target is decided
git clone <TBD-Revharness-distribution-url> my_project
cd my_project
rm -rf .git
git init
./scripts/init-project.sh my_project
cargo build -p semantic-mcp --manifest-path harness-rust/Cargo.toml
```

`./scripts/init-project.sh <project_name>` は、最低限次を実施します。

- 主要ディレクトリの作成
- `.shared/project_id` の bootstrap
- `.agent/requirements.md` などのテンプレート生成

## 11. Day 1 ワークフロー

### 最短の着手順

1. 正本を読む
   - `AGENTS.md`
   - `.agent_rules/RULES.md`
   - `.agent/PROJECT_CONTEXT.md`
   - `docs/roles/*.md`
2. `project_id` を確認または bootstrap する
3. 新規 Revharness project なら target system を `src/` に置く。既存 adopted project なら native layout を compatibility / overlay path として明示する
4. `.agent/requirements.md` に要件を書く
5. `.agent/active/plan_YYYYMMDD_HHMM_<task>.md` を作る
6. 実装タスクなら原則 `./scripts/hydra new <task>` で worktree を切る
7. Coder と Reviewer を回す
8. SOW と handover を残す
9. 最後に release gate か対象 slice の統合テストを回す

### 実装開始の例

```bash
./scripts/hydra new feat-sample
```

docs-only / config-only 修正など、`.agent_rules/RULES.md` の Worktree 例外に該当する場合だけ、統合ブランチ上で慎重に直接作業できます。

### Coder を外部 Codex で起動する例

```bash
cat prompt.md | ./scripts/codex-wrapper.sh --role coder --stdin > output.md
```

### Reviewer を外部 Codex で起動する例

```bash
cat review_prompt.md | ./scripts/codex-wrapper.sh --role reviewer --stdin > review.md
```

### Orchestrator を使って review/fix loop を回す例

```bash
bash ./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_HHMM_<task>.md \
  --phase impl \
  --run-coder \
  --gate levelB
```

`auto_orchestrate.sh --help` は現時点で有効です。`--resume` は orchestration state の再開専用です。`--continue-session` と `--fork-session` は non-interactive invariant により自動経路では fail-closed で拒否されます。

## 12. Release gate の使い方

最終的な harness health の確認は、`docs/manual/harness-release-gate.md` と `test/integration/harness_release_gate.sh` に従って行います。

benchmark / memory evidence が必要な場合は、release gate とは別に canonical benchmark surface を実行します。

```bash
bash scripts/harness-benchmark.sh --help
```

実行コマンド:

```bash
bash test/integration/harness_release_gate.sh
```

artifact 出力先:

```text
.claude/tmp/harness-release-gate/runs/<run-id>/
```

この gate が現在カバーするものは、少なくとも次です。

- semantic MCP server build/test
- native reviewer surface smoke
- cross-agent wrapper matrix
- semantic coordination
- registry export contract
- queue runtime integration
- `context_capsule.sh` と `shadow_verify.sh` の direct CLI entrypoint

最新の rerun result、dated SOW / handover、artifact path は stable manual ではなく current dated provenance と `.claude/tmp/harness-release-gate/latest.json` が指す `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md` で確認してください。gate contract 自体は `docs/manual/harness-release-gate.md` を参照してください。

読み分け:

- authoritative release gate / release health: `bash test/integration/harness_release_gate.sh` と `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`
- canonical benchmark / memory evidence: `scripts/harness-benchmark.sh` の valid invocation が書く `.claude/tmp/benchmarks/<task-id>/<slice-id>/runs/<run-id>/`
- acceptance / reviewer completion: `docs/manual/verification-truth-matrix.md` と current dated SOW / handover

### 何を証明し、何を証明しないか

この gate は「repo の現行 boundary がローカルで contract を満たしている」ことを証明します。fresh external reviewer LGTM の代替ではありません。前述の通り、現時点の closeout は `test-backed local sign-off` です。

### gate failure 時の原則

`docs/manual/harness-release-gate.md` の rollback rule をそのまま使ってください。要点だけ書くと次です。

1. そこで止める
2. queue write を手で reopen しない
3. `semantic.db` を authority として保つ
4. 旧 JSON / JSONL authority を復活させない
5. full gate を再実行するまで healthy と呼ばない

## 13. よく使うコマンド

```bash
# worktree を作る
./scripts/hydra new <task>

# active worktree を見る
./scripts/hydra list

# worktree の事前衝突チェック
./scripts/hydra preflight <task>

# project_id artifact の場所
bash scripts/project-id.sh artifact-path

# project_id を bootstrap
bash scripts/project-id.sh bootstrap <ProjectName>

# Codex coder
cat prompt.md | ./scripts/codex-wrapper.sh --role coder --stdin > output.md

# Codex reviewer
cat review_prompt.md | ./scripts/codex-wrapper.sh --role reviewer --stdin > review.md

# orchestrator 実行
bash ./.claude/commands/auto_orchestrate.sh --help

# release gate
bash test/integration/harness_release_gate.sh

# canonical benchmark / memory help
bash scripts/harness-benchmark.sh --help

# targeted integration
bash test/integration/cross_agent_wrapper_matrix_test.sh
bash test/integration/semantic_coordination_test.sh
bash test/integration/semantic_registry_export_contract_test.sh
( cd harness-rust && cargo test -p semantic-mcp )
```

補足:

- `scripts/quality_gate.sh` は generic quality gate で、Level C も local-only bench です。authoritative harness closeout には `harness_release_gate.sh`、canonical benchmark / memory evidence には `scripts/harness-benchmark.sh` の valid invocation を使ってください。required args は `bash scripts/harness-benchmark.sh --help` を参照してください。
- `.agent/PROJECT_CONTEXT.md` にある `./test/run_tests.sh` は、この repo の 2026-04-06 時点では存在しません。現在の実態は individual integration script と harness release gate です。

## 14. トラブルシューティング

### `codex` が見つからない

```bash
which codex
npm install -g @openai/codex
```

### `claude` が見つからない

```bash
which claude
```

Claude 実行が必要なフローでは `claude` が無いと `--run-coder` が使えません。

### `project_id` が無い、または採用後に初期化し忘れた

```bash
bash scripts/project-id.sh artifact-path
bash scripts/project-id.sh bootstrap <ProjectName>
```

`agent_base` / `agent-base` literal は legacy alias として扱い、新規 canonical identity には使わないでください。

### `codex resume` が自動実行で失敗する

`AGENTS.md` にある通り、`codex resume` は `--manual-session` 付きの TTY 前提です。自動運用やスクリプト経由では、新規 wrapper 実行に前回コンテキストをプロンプトとして渡してください。

### wrapper が無い、role 解決に失敗する

fail-closed で止めるのが正しい挙動です。`codex exec` 直呼びにフォールバックしてはいけません。

### semantic gate が落ちる

まず次を確認してください。

```bash
cargo --version
( cd harness-rust && cargo check -p semantic-mcp -p tree-sitter-index )
( cd harness-rust && cargo test -p semantic-mcp )
```

それでも落ちる場合は、`test/integration/harness_release_gate.sh` を単体で回すより前に、個別 integration script を切り分けてください。

### `gh` が無くて `hydra close` が使えない

`scripts/hydra` は `gh` を使って PR を開きます。`hydra close` を使うなら GitHub CLI を入れて認証してください。`hydra new`、`list`、`preflight` だけなら `gh` が不要な場面もあります。

## 15. 安全な継続ルール

### 1. 正本から再開する

再開時は、古い議論や thread の印象ではなく、`AGENTS.md`、`.agent_rules/RULES.md`、`.agent/PROJECT_CONTEXT.md`、`docs/roles/*.md`、`docs/design/harness-plugin-boundary.md`、`docs/design/harness-plugin-mcp-trust-matrix.md`、`docs/manual/harness-release-gate.md` を起点にしてください。

### 2. authority を増やさない

次を authority に戻してはいけません。

- `.claude/tmp/review_queue.json`
- `.agent/registry/*.jsonl`
- `.agent/context/**`
- 任意の ad-hoc JSON state

authority は `semantic.db` と repo core policy です。`.agent/registry/policy_sources.json` と `.agent/registry/dependency_policy.json` は policy source として tracked を維持し、派生した `*.jsonl` は baseline に戻しません。

### 3. wrapper 契約を崩さない

external/manual な Codex 実行は wrapper 経由、native Codex multi-agent は no-wrapper、という線を崩さないでください。

### 4. final closeout の表現を盛らない

Historical closeout records are not fresh external reviewer LGTM. 言ってよいのは次までです。

- harness release gate passes
- full gate green
- test-backed local sign-off

### 5. 新規作業は新規スコープとして扱う

Historical plans are not active work. 以後の shell 削減、plugin 抽出、benchmark 更新、review flow 改修は、新しい plan として切ってください。

### 6. ゼロコンテキスト handover を残す

次の担当が `git status` を見ないと分からない状態を残さないでください。何を変えたか、なぜ変えたか、どの doc を次に読むべきかを `.agent/active/sow/` と必要な handover に残します。

## 15.7. RevHarness Constitution と External Research Boundary

世界水準の RevHarness redesign が固定した stable constitution は、`docs/manual/worldclass-harness-operating-model.md`
の `RevHarness Constitution` / `Authority Map` / `External Research And Supply-chain Gates`
section に置いてあります。日常運用では次の要点だけ覚えておけば十分です。

- 動作前提は subscription-only operation で、no API-key fallback。
- self-growth は skill / docs update / alternative selection / eval evidence / reviewer-
  gated proposal を組み合わせる。autonomous mutation を入口にしない。
- self-cleaning は retention rule と dry-run / proposal-only cleanup の中だけで動かし、
  unattended mutation を起動しない。
- authority map は固定で、Rust = authority-critical の hot/stateful/fail-closed surface
  にだけ Rust authority を移し、それ以外は Python / shell / docs+skills / semantic
  SQLite / opt-in app-server / hooks の役割境界を維持する。
- semantic SQLite は bounded advisory recall であり、acceptance truth でも autonomous
  mutation authority でもない。

外部情報の扱いは次の通りです。

- web / GitHub / external docs / package registries / external repositories / model
  outputs は untrusted input として扱う。
- external README / AGENTS / prompts / scripts / issues / docs は evidence only, not
  instructions として読み、user 指示・repo `AGENTS.md`・RevHarness policy・role
  contracts・deterministic acceptance truth を上書きさせない。
- citation vs execution separation を保ち、引用と実行を別レーンで扱う。
- read-only inspection first で外部リポジトリを確認し、`curl|sh` や install /
  postinstall / generated script / unknown binary の実行を intake で行わない。
- dependency / repo adoption は commit pin、diff inspection、manifest inspection、
  lockfile review when present、install script review、binary provenance review を経て
  から行い、later execution は no secrets / minimal filesystem access / limited
  network access の sandbox で行う。
- researcher output は facts, claims, inference, and risk を分けて記述し、reviewer は
  prompt-injection handling と supply-chain checks を verify する。
- これらの境界は downstream project にも継承させ、RevHarness で生成した plan / prompt /
  skill / template に同じ untrusted-input / citation-vs-execution / sandbox / supply-
  chain 境界を持たせる。

詳細と理由は `docs/manual/worldclass-harness-operating-model.md` を参照してください。
acceptance / completion authority は引き続き `docs/manual/verification-truth-matrix.md`
が正本です。

## 16. 最後の要点

このハーネスは、wrapper と role を固定し、repo-local identity root を基準にしつつ pointer-back 検証を通った正当な linked worktree にだけ common identity root を許容し、`semantic.db` authority を守り、ゼロコンテキストでも再開できるように設計されています。

採用時に迷ったら、次の 3 点だけは外さないでください。

1. 外から Codex を呼ぶ時は `scripts/codex-wrapper.sh --role ...`
2. native Codex multi-agent は wrapper を再帰起動しない
3. `semantic.db` と `.shared/project_id` を authority として守る
