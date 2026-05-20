---
name: auto-orchestrator
description: Route Phase 2 orchestration tasks to the appropriate workflow skill (system-planner / research-handoff / review-workflow / codex-caller / baseline-protection / harness-official-docs-update / codex-app-server-product-integration / client-distribution-readiness / deploy guards / shadcn frontend workflow / language knowledge packs). Use at the start of any orchestrator turn to perform pre-flight classification (change surface, required checks, evidence destination, completion boundary) before delegating execution.
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: Auto Orchestrator

Phase 2 の `auto-orchestrator` は、再利用可能な実務フローの実装本体ではなく、**適切な workflow skill に処理を振り分ける薄いルーター**として扱う。

## 目的
- タスクの現在地を見て、どの skill が次の責務を持つかを即座に決める。
- 実行面では `./.claude/commands/auto_orchestrate.sh` と prompt/state 管理を使い、詳細手順は各 skill に委譲する。
- ルーティング前に pre-flight classification を行い、change surface / required checks / evidence destination / completion boundary を確定する。

## Pre-flight Classification
ルーティング前に、必ず `docs/manual/verification-truth-matrix.md` を shared source of truth として読み、少なくとも次を分類する。

| 項目 | 必須内容 |
|------|----------|
| change surface | 何を変更する slice か。docs only なのか、command/path/policy を含むのか、script 実行入口なのか |
| required checks | その surface に必要な deterministic checks の正確なコマンド |
| evidence destination | slice 固有の volatile evidence を置く plan / SOW / tmp。acceptance truth は `docs/manual/verification-truth-matrix.md` のまま維持する |
| completion boundary | 次 slice / reviewer に渡してよい境界 |

- slice record は `.agent/active/plan_*.md` / `.agent/active/sow/*.md` / handoff prompt のいずれかに残す。
- broad task のまま owner skill へ渡さない。安全に slice 化できない場合は fail-closed で停止し、`BLOCK` として planner へ戻す。
- routine work の active surface は最小化する。必要な active set は current request、該当 plan / SOW、lineage が slice scope に入る場合の task lineage ledger、touched files、次 gate に必要な deterministic check output までとする。
- ordinary `dev` / `review` iteration で、tracked evidence manifest、dirty manifest、reviewer prompt artifact、normal-work final evidence packet を毎回増やさない。
- reviewer intake は current diff / status / required checks 結果 / plan-SOW scope から生成する volatile review input であり、acceptance truth ではない。materialize する場合は stdout または `.claude/tmp/**` に限定し、registry / daemon / queue / durable manifest / control-plane subsystem を作らない。

### Task-size / Risk Classifier

Canonical classifier は `light` / `standard` / `heavy`。`lightweight` は historical alias のみで、新規の canonical class 名として使わない。

| classifier | mode + tier | owner default |
|------------|-------------|---------------|
| `light` | `dev + quick` | non-normative typo / prompt wording / admin bookkeeping / 既存参照整理のみなら Orchestrator 直接処理可 |
| `standard` | `review + local` | Coder / scoped review discipline |
| `heavy` | `release + full` | release / full review discipline |

Orchestrator 直接処理できる `light` は、runtime code、role/policy/skill behavior、wrapper/model-policy、semantic MCP/index/registry/review queue、security/trust boundary、release/tag/merge、gate-runner/release-gate evidence、acceptance/final-signoff、その他 high-risk surface に触れない場合だけ。role / policy / skill の挙動を変える文書変更や曖昧な scope は fail-closed で `standard` 以上に上げる。

## Specialty Surface Boundary

Specialty selection is owned by `scripts/rev-harness-task-classifier.sh` and its matrix in `docs/manual/matrix-vocabulary.json`. Generated `SKILL.md` files under `.claude/skills/<specialty-slug>/` and `.agents/skills/<specialty-slug>/` are selection hints, or lenses, not workflow owners. The primary invocation surface is:

- orchestrator-canonical specialties: direct `Read` of `docs/roles/orchestrator/specialties/<slug>.md`
- coder / reviewer canonical specialties: `scripts/codex-wrapper.sh --role <coder|high-coder|reviewer> --specialty <slug>`

Auto-trigger via SKILL description matching is a discovery hint only. Specialty correctness is enforced by the classifier surface, not by SKILL projection. Future SKILL projections MUST NOT drift into workflow-owner language; the role-aware `skill_body` generator in `agent-core specialty.rs` is the single source of truth for projected bodies.

## ルーティング表

| 状況 | owner skill | 実行面 |
|------|-------------|--------|
| プラン未作成、または更新が必要 | `system-planner` | `.agent/active/plan_*.md` の作成/更新 |
| 実装後レビュー、修正反復、合格判定 | `review-workflow` | `./.claude/commands/auto_orchestrate.sh` と `.claude/tmp/` |
| 外部調査や最新版確認が必要 | `research-handoff` | 調査メモを planner/coder に受け渡し |
| Codex / Claude Code / prompting / Goal / subagent / skill / hook / settings の upstream 仕様に基づく harness 更新 | `harness-official-docs-update` | 公式ドキュメント参照から local authority mapping を作る |
| agent-enabled GUI / Mac app / IDE-like client / image-generation GUI / product integration で Codex を裏側 engine として使う | `codex-app-server-product-integration` | `codex app-server` / `codex exec` / SDK / `codex-plugin-cc` の住み分けを決める |
| `codex app-server` を露出・proxy・deploy・rich client に組み込む | `codex-app-server-guard` | app-server transport / auth / approval / sandbox / tool side effects の GO/NO-GO gate |
| Client handoff / clean distribution / final cleanup readiness / stale archive or absolute-path audit | `client-distribution-readiness` | 配布直前の stale refs、local path、semantic DB regeneration、skill sync、doctor clean-distribution 前提を inspect-first で確認 |
| Cloudflare Workers / Pages / Wrangler / R2 / KV / D1 / Queues / Durable Objects / OpenNext を deploy する | `cloudflare-deploy-guard` | 課金・Bot・security・rollback gate。Cloudflare 公式 skill と併用 |
| Supabase migration / Edge Functions / Auth / Storage / Realtime / MCP/API 変更を deploy する | `supabase-deploy-guard` | RLS・secret・billing・rollback gate。Supabase 公式 skill と併用 |
| Payload CMS production deploy / schema / access-control / upload / Jobs Queue / migration を行う | `payload-cms-deploy-guard` | data exposure・privilege・upload・queue・rollback gate。Payload 公式 skill と併用 |
| Go system design / review / implementation / dependency governance | `go-skills-architecture` | `go-skills-knowledge-pack` 由来の REV-C Go architecture skill |
| Rust system design / implementation / benchmarking / dependency governance | `rust-skills-architecture` | `rust-skills-knowledge-pack` 由来の REV-C Rust architecture skill |
| TypeScript / Node / Bun / Deno / React / Next / edge runtime system design / review / implementation | `typescript-skills-architecture` | `typescript-skills-knowledge-pack` 由来の REV-C TypeScript architecture skill |
| REV-C frontend UI/UX with shadcn/ui, shadcn CLI/MCP, React, or Next.js | `revc-shadcn-frontend-workflow` | shadcn-first workflow。公式 shadcn skill / CLI / MCP と React/Next 最新 security/update docs freshness gate を要求 |
| Skill / knowledge pack addition, import, rename, or reorganization | `naming-normalization-guard` | Skill package naming, required entrypoint filenames, internal references, and stale-path hygiene |
| Self-growth, skill promotion, proposal queue triage, HermesAgent-inspired workflow evolution, or cleanup evolution | `self-growth-proposal-triage` | proposal-only workflow; classifier + skill routing matrix + provenance check before any mutation slice |
| Codex の CLI 呼び出し方法を決める | `codex-caller` | canonical wrapper 契約 |
| semantic-mcp 関連質問 / 操作 | `revharness-semantic-mcp-usage` | `sem.context.top_k` -> `sem.capsule`、FTS5 search、admin GC、test isolation の契約 |

## この skill の責務
- plan、prompt、state.json を読んで次の owner skill を決める。
- routing 前に pre-flight classification を実施し、slice record の有無を確認する。
- session 開始時または handover 直後は `./.claude/skills/orchestrator-bootstrap/SKILL.md` を先に呼び、semantic capsule と memory consult で bootstrap する。
- 自動化が必要なら `./.claude/commands/auto_orchestrate.sh` を実行入口として使う。
- handoff 用の入力ファイルと出力ファイルの置き場を揃える。
- coder -> reviewer の順で agent を回す slice では `./.claude/skills/baseline-protection/SKILL.md` と `./.claude/commands/lib/baseline_freeze.sh` を使い、baseline を固定してから起動する。
- change surface に応じた required checks を matrix 参照で owner skill に引き渡す。

## この skill の非責務
- review/fix loop の詳細定義
- research memo の詳細フォーマット
- planning template の詳細定義
- Codex wrapper 契約の定義
- MCP の機能定義

## ガードレール
- acceptance / completion の正本は `docs/manual/verification-truth-matrix.md`。wrapper 契約や command 実行そのものを acceptance 証拠に昇格させない。
- Codex の caller-facing runtime truth は常に `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`。
- `codex-wrapper-medium.sh` / `high.sh` / `xhigh.sh` は互換 shim であり、primary guidance にはしない。
- Claude 側の effort 既定値は `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない。
- 初回設計 / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane として `gpt-5.5` + `xhigh` + `cached` を使う。これは routine docs-only / light planning ではない。
- MCP は capability transport に留める。semantic MCP は `.claude/settings.json` と `.codex/config.toml` から `./scripts/launch-semantic-mcp.sh` を自動起動する repo-local surface として扱う。
- 新 contract (frontier-push 以降): capsule 生成は `sem.context.top_k` -> `sem.capsule` の 2-step、`top_k_symbols` を caller 提供しない。詳細は skill `revharness-semantic-mcp-usage`。
- 検索: `sem.search` の既定は `kind="fts5"`（BM25 + 48h recency）。prefix wildcard は提供しない、`legacy-like` は opt-in のみ。
- Admin: orphan DB GC は `sem.admin.gc` (`dry_run=true && force=false` 既定、実削除は `--dry-run=false --force` 両方明示)。
- Test isolation 時は `REVHARNESS_TEST_HARNESS=1` + `SEMANTIC_MCP_HOME=$TMPDIR/...` を併設。
- slice record 欠落、required checks 未定義、evidence destination 不明、completion boundary 不明のいずれかがあれば fail-closed で停止する。
- generated reviewer intake 欠落は acceptance truth 欠落と同一視しない。ただし reviewer に渡す時点では current diff / status / required checks 結果 / plan-SOW scope を再生成または handoff に明記する。

## 最小ランブック
1. `plan` と `.claude/tmp/<task>/state.json` を確認する。
2. `docs/manual/verification-truth-matrix.md` に従って change surface / required checks / evidence destination / completion boundary を分類する。
3. slice record が不足していれば `system-planner` へ戻す。安全に slice 化できない broad task は `BLOCK` にする。
4. 必要な workflow owner skill を 1 つ選ぶ。
5. Codex / Claude Code behavior update の場合は、実装前に `harness-official-docs-update` か `research-handoff` で公式参照と local authority mapping を作る。
6. agent-enabled product / GUI / local app integration では、`codex-app-server-product-integration` で app-server vs exec/wrapper vs SDK vs plugin を先に選ぶ。
7. Client handoff / clean distribution / final cleanup readiness では `client-distribution-readiness` を読み、stale archive refs、local absolute paths、semantic DB regeneration、skill sync、doctor clean-distribution assumptions を確認する。
8. 本番 deploy / external exposure / hosted service 変更では、該当 deploy guard を実装前と release 前に使い、GO/NO-GO を evidence として残す。
9. Go / Rust / TypeScript の設計・実装・レビューでは該当 architecture skill を読み、公式 docs / latest stable / security checks の不足を required checks に反映する。
10. REV-C frontend UI/UX、shadcn/ui、React、Next.js を触る場合は `revc-shadcn-frontend-workflow` を読み、公式 shadcn skill / CLI / MCP と React/Next security freshness gate を required checks に入れる。
11. Skill / knowledge pack の追加・取り込み・リネームでは `naming-normalization-guard` を読み、package 名、`SKILL.md` entrypoint、内部参照、install target の stale path を確認する。
12. Self-growth / skill promotion / proposal queue / cleanup evolution では `self-growth-proposal-triage` を読み、`scripts/rev-harness-task-classifier.sh` と `scripts/rev-harness-skill-routing-check.sh` の順で class と allowed skill set を固定する。
13. Codex を呼ぶ必要がある場合だけ `codex-caller` の契約に従う。
14. stable truth は該当 manual / README に残す。reviewer intake は current facts から stdout または `.claude/tmp/**` に生成する volatile input として扱い、tracked truth に昇格させない。

## 関連
- `docs/manual/verification-truth-matrix.md`
- `./.claude/skills/system-planner/SKILL.md`
- `./.claude/skills/review-workflow/SKILL.md`
- `./.claude/skills/research-handoff/SKILL.md`
- `./.claude/skills/codex-caller/SKILL.md`
- `./.claude/skills/codex-app-server-product-integration/SKILL.md`
- `./.claude/skills/client-distribution-readiness/SKILL.md`
- `./.claude/skills/codex-app-server-guard/SKILL.md`
- `./.claude/skills/cloudflare-deploy-guard/SKILL.md`
- `./.claude/skills/supabase-deploy-guard/SKILL.md`
- `./.claude/skills/payload-cms-deploy-guard/SKILL.md`
- `./.claude/skills/go-skills-knowledge-pack/SKILL.md`
- `./.claude/skills/rust-skills-knowledge-pack/SKILL.md`
- `./.claude/skills/typescript-skills-knowledge-pack/SKILL.md`
- `./.claude/skills/revc-shadcn-frontend-workflow/SKILL.md`
- `./.claude/skills/naming-normalization-guard/SKILL.md`
- `./.claude/skills/self-growth-proposal-triage/SKILL.md`
- `./.claude/skills/harness-official-docs-update/SKILL.md`
- `./.claude/commands/README.md`
