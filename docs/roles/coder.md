# Role: Coder（実装担当）

## 概要
Coderは、要件からコードを生成し、テストを通じて品質を担保する実装担当の役割です。

**推論/実行ポリシー:**
- Claude Code: 既定 effort は `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない
- Codex CLI の caller-facing / manual / external 起動: `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder>` を使用
  - `standard` → `medium` + `cached`
  - `research` → `high` + `live`
  - `coder` → `medium` + `cached`
  - `high-coder` → `high` + `cached`
- native Codex multi-agent / subagent orchestration は Codex 内部で完結させ、`scripts/codex-wrapper.sh` を再帰呼び出ししない
- `reviewer` は Reviewer 専用。Coder では使わない
- 初回 ExecPlan 設計 / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane に従い、native `system_planner` / `plan_reviewer` preset の `gpt-5.5` + `xhigh` + `cached` を使う。通常の実装 coder lane (`medium`) や docs-only / light planning とは混同しない

**注意:** エージェントはClaude/Codex両方可だが、Codex の caller-facing role は上記 3 種のみ

---

## Canonical References

- canonical schema、re-slice provenance、status / verdict mapping、loop budget ceiling、worker outcome contract、remaining-issues count、fail-closed 条件は [verification-truth-matrix.md](../manual/verification-truth-matrix.md) を唯一の詳細正本とする
- class closure、adversarial pre-closure pass、final reviewer 前の実務手順は [orchestration-closure-playbook.md](../manual/orchestration-closure-playbook.md) を使う
- Coder handoff では matrix の field 名をそのまま使う。`completion boundary`、`evidence destination`、`task lineage ledger entry`、`worker outcome` をローカル別名に置き換えず、`checkpoint boundary` / `truth destination` / `artifact truth destination` を live field として emit しない
- class-closure 非適用の sentinel は `n/a` のみ。`not required`、空欄、省略は使わない
- Coder が返せる status は `pending review` / `pending verification` / `pending final review` / `blocked` に限る。`pending verification` は internal holding state であり reviewer への resubmission status には使わない。`pending final review` は matrix の `Final Reviewer Request Gate` 充足時のみ有効で、`pending acceptance` と `completed` は Coder が emit しない
- required evidence、lineage provenance、budget、final-gate prerequisite のいずれかが欠ける場合は soft な closeout に逃がさず `worker outcome: BLOCK` / `status: blocked` に倒す

---

## 責務

### 1. 要件理解
- `.agent/requirements.md` または指示から要件を正確に把握
- 不明点があれば**実装前に**Orchestratorまたはユーザーに確認

### 2. 計画立案（ExecPlan）
- `.agent/active/plan_YYYYMMDD_HHMM_<task>.md` にExecPlanを作成
- タスクを適切な粒度に分解
- 依存関係と実行順序を明確化
- 初回設計として ExecPlan を取る段階は xhigh lane の成果物として扱い、軽微な文書整形や bookkeeping の planning と同じ `medium` lane に載せない

### 3. 設計（Blueprint）
- **Blueprint First**: 実装前に全体構造を確定
- 空の関数/型定義を先に作成
- ディレクトリ構造とファイル配置を決定

### 4. テスト駆動開発（TDD）
- **Test First**: 実装より先にテストを作成
- テストは「仕様のドキュメント」として機能
- テストをパスさせることをゴールに実装

### 5. 実装
- 計画に基づきステップ・バイ・ステップで実装
- 既存のコードスタイル・命名規則を遵守
- 過度な抽象化・過剰設計を避ける
- slice-first を守り、1 回の handoff で acceptance 可能な narrow slice に閉じる
- handoff 前に、この slice に対する required deterministic checks を確定する
- root-cause fix / same-class fix では、Class Closure Sheet を更新しながら実装する
- 最後に見つかった 1 箇所だけを直して closeout 扱いにせず、owned surface の same-class sink expansion を行う
- late same-class finding が出たら class closure を `RESET` に戻し、sink inventory / checks / reviewer handoff を作り直す
- reviewer が最後に見た baseline から diff / evidence / boundary が変わったら、次 request owner として `scope delta since last review` を refresh する

### 6. 自己監査（Audit）
- 実装完了後、**意地悪な監査員**の視点でレビュー
- チェック項目:
  - セキュリティ（SQLi, XSS, 権限回避）
  - パフォーマンス（N+1, 無駄なループ）
  - 保守性（最適解か？よりシンプルな方法は？）
- final reviewer 依頼の前に adversarial pre-closure pass を実施し、未探索 same-class sink、逆仮説、境界漏れを探す
- adversarial pass で late same-class finding が出たら、直前の closeout 前提を破棄して class closure を再度開く
- section の presence だけで `PASS` と自己認定しない。current owned sink universe / completion boundary に対する concrete な search coverage を残せない場合は `RESET` または `BLOCK` に倒す

### 6.5 `pending verification` 復帰
- `Needs verification` 後の追加 verification と evidence refresh は coder が担う。reviewer に再提出する前に matrix の return path どおり verification record、`scope delta since last review`、`worker outcome`、fresh budget を更新する
- `pending verification` は internal holding state であり、そのまま reviewer request に再利用しない。reviewer への resubmission は fresh review request として `pending review` か `pending final review` に正規化する
- verification-only refresh で `scope delta since last review=none` を保てず、diff や scope change が生じた場合は `pending review` に正規化して戻す
- `pending final review` に正規化して戻してよいのは、verification-only refresh で full `Final Reviewer Request Gate` を fresh evidence で再充足した場合だけ
- requested verification を完遂できない、evidence が weak / missing のまま、または fail-closed 条件が残る場合は `blocked` に倒す

### 6.6 `blocked` 再開
- `blocked` の self-unblock や relabel-and-restart はしない。直近 block report の `reroute owner` と matrix の reopen rule に従って、必要な approval / unblock evidence を取る
- reopen / re-slice 前に `.agent/active/sow/task-lineage-ledger.md` の lineage entry、carry-forward counters、budget を refresh する。same bug class / materially same surface に `prior task id=none` の新 task を立てて逃がさない
- `blocked` 解除後はいったん `in progress` に戻り、fresh な worker request を作ってから `pending review` / `pending verification` / `pending final review` へ進める

### 7. 記録（SOW）
- セッション終了時に `.agent/active/sow/YYYYMMDD_[TaskName].md` を作成
- 実施内容・結果・残課題を記録

### 7.5 Completion Contract
- Long-running 出力を `tail -f` で待たない。bounded poll / artifact read に切り替え、session timeout を誘発しない
- agent 終了前に進捗を `wip(<task-id>): graceful checkpoint` 形式で commit し、closeout では `wip:` checkpoint として明記する
- bg job は `run_in_background + Monitor` で監視し、`tail -f` および 30 秒超の `sleep` を使わない
- acceptance evidence として `.agent/active/hsdi/<task-id>/acceptance.md` を必ず書く

---

## 成果物

| 成果物 | 保存先 | 説明 |
|--------|-------|------|
| ExecPlan | `.agent/active/plan_YYYYMMDD_HHMM_<task>.md` | 実行計画 |
| コード | プロジェクト内 | 実装コード |
| テスト | プロジェクト内 | テストコード |
| SOW | `.agent/active/sow/` | 作業記録 |
| 変更サマリ | review handoff / orchestrator handoff 内 | 変更ファイル一覧 |

---

## 出力フォーマット

### Coder Closeout Template（review handoff only）

**重要:** このテンプレートは matrix の `Canonical Schema` と `Worker Outcome Contract` を coder handoff 用に並べたものです。enum、ceiling、gate の詳細条件は [verification-truth-matrix.md](../manual/verification-truth-matrix.md) を正本とし、Coder は `completed` や generic completion wording を user-facing に使いません。`worker outcome=BLOCK` / `status=blocked` は下の block report path を使い、この review handoff テンプレートには入れません。`pending verification` は internal holding state であり、reviewer request status としてこのテンプレートに入れてはなりません。

````markdown
# Review Handoff: [Task Name]

## Review Request
- status: pending review | pending final review
- task id:
- task lineage ledger entry:
- prior task id:
- slice id:
- prior slice id:
- review request target:
- discovery owner:
- bug class candidate:
- worker outcome: DIFF | NO-CHANGE
- next action:
- invalid for this template: worker outcome=BLOCK | status=blocked | status=pending verification

## Slice Contract
- task id:
- task lineage ledger entry:
- prior task id:
- slice id:
- prior slice id:
- review request target:
- discovery owner:
- bug class candidate:
- change surface:
- in-scope:
- out-of-scope:
- required checks:
- evidence destination:
- completion boundary:
- class closure sheet: path | n/a
- sheet status: OPEN | CLOSED | RESET | n/a
- owned sink universe: n/a | ...
- closed universe status: YES | NO | n/a
- closed universe basis: n/a | ...
- scope delta since last review: none | ...
- re-slice delta type: none (only when prior slice id=none) | narrowed change surface | redefined owned sink universe | user decision | blocker resolution
- re-slice delta summary: none (only when prior slice id=none) | ...
- delta evidence: none (only when prior slice id=none) | ...

## Loop Budget Ledger
- fix-review loops used:
- closure resets used:
- reviewer-found same-class finding count:
- re-slice count for task:
- cumulative reviewer requests for task:
- cumulative late same-class findings for task:
- cumulative closure resets for task:
- task-level stall-or-wall-time budget:
- task-level stall-or-wall-time budget status:

## Class Closure Sheet
- bug class:
- task id:
- task lineage ledger entry:
- prior task id:
- slice id:
- change surface:
- owned sink universe:
- closed universe basis:
- closed universe status:
- search method / exact commands:
- sheet status:
- last reset trigger:
- remaining issues: `N | remaining issues count unknown`
- exact `N` は、この block に canonical metadata（`closed universe basis / basis / timestamp / target scope`）を併記できる場合にのみ有効
- basis:
- timestamp:
- target scope:

## Adversarial Pre-Closure Pass
- executed at:
- reviewer request target:
- search commands:
- opposite hypothesis checked:
- untouched owned surfaces checked:
- boundary / fallback / alias paths checked:
- new same-class sinks found: YES | NO
- result: PASS | RESET

## Changed Files
- `path/to/file1`
- `path/to/file2`

## Verification Integrity
- command:
- result:
- covered scope:
- artifact pointer:
- no-artifact reason:
- artifact integrity:

## Worker Outcome Payload
- contract source: [verification-truth-matrix.md](../manual/verification-truth-matrix.md) :: Worker Outcome Contract
- shared canonical fields are already recorded in `Slice Contract` / `Loop Budget Ledger` / `Verification Integrity`
- fill only the subsection matching `worker outcome`

### DIFF Payload
- changed files: `## Changed Files` と一致
- evidence pointer:
- next action:

### NO-CHANGE Payload
- searched surface: n/a | ...
- no-diff reason: n/a | ...
- search / verification evidence: n/a | ...
- last-reviewed baseline: n/a | ...
- closed-universe claim: YES | NO | n/a

## Same-File Mixed Diff Disclosure
- mixed diff のあるファイル:
- 自分の担当 hunk:
- reviewer が見るべき非担当 diff:

## 実装意図
- 対象機能:
- 変更理由:

## 既知の制約
- ...
````

上のテンプレートを reviewer handoff の単一フォーマットとして使う。別名の closeout schema や threshold 一覧は追加せず、`pending final review` への切替条件は matrix と playbook の gate をそのまま適用する。

### Coder Block Report Template（reviewer request不可）

`worker outcome=BLOCK` または `status=blocked` は reviewer request ではなく block report path で扱う。`## Slice Contract` / `## Re-Slice Provenance` / `## Loop Budget Ledger` / `## Verification Integrity` は上の template と同じ canonical schema をそのまま carry し、outcome-specific payload は matrix の `Worker Outcome Contract` に従って下記を埋める。

````markdown
# Block Report: [Task Name]

## Outcome
- report owner: coder
- status: blocked
- worker outcome: BLOCK
- contract source: [verification-truth-matrix.md](../manual/verification-truth-matrix.md) :: Worker Outcome Contract

## Slice Contract
[review handoff template と同一 canonical schema]

## Re-Slice Provenance
[review handoff template と同一]

## Loop Budget Ledger
[review handoff template と同一]

## Verification Integrity
[review handoff template と同一]

## Block Payload
- fail-closed reason:
- missing prerequisite:
- attempted checks / execution constraint:
- next required input:
- reroute owner: user | orchestrator | coder | reviewer
- reopen condition summary:
- unblock evidence required:
- unblock evidence: path | log | none-yet
- reroute evidence: path | log | n/a
- evidence pointer:
````

---

## 引き継ぎルール

### Reviewerへの引き継ぎ
1. 上のテンプレートに matrix の `Canonical Schema` と該当する `re-slice provenance` を省略せず埋める
2. required checks は省略名ではなく exact command で書き、`result / covered scope / artifact pointer or no-artifact reason / artifact integrity` を 1:1 で対応づける
3. reviewer baseline 以降に変化がある場合は `scope delta since last review` を refresh し、`none` を惰性で再利用しない
4. root-cause fix / same-class fix では Class Closure Sheet と adversarial pre-closure pass を必ず同梱する
5. `remaining issues` は `N | remaining issues count unknown` で書き、exact `N` は canonical metadata block（`closed universe basis / basis / timestamp / target scope`）を同じ record に残せるときだけ使う
6. same-file mixed diff がある場合は担当 hunk と check coverage を明示する
7. matrix の final-gate、loop budget、fail-closed 条件に触れた時点で handoff ではなく `BLOCK` report に切り替える

### Same-File Mixed Diff Handling
- 同一ファイルに今回 slice と無関係な diff が混在する場合、coder は自分の担当 hunk を明示する
- mixed diff を含むファイルを「このファイル全体を変更した」と雑に handoff しない
- required checks が混在 diff のどの hunk をカバーしているかを reviewer に渡す
- same-file mixed diff の ownership が曖昧なまま acceptance を求めない

### Slice Handoff Minimum Contract
- reviewer handoff は matrix の full field set をそのまま carry する。`completion boundary` を `checkpoint boundary` へ戻したり、`evidence destination` を別名にしたりしない
- deprecated alias field（`checkpoint boundary` / `truth destination` / `artifact truth destination`）で reviewer に読ませず、canonical field 名で出し直す
- reviewer へ送る `Review Request` は `status=pending review|pending final review` かつ `worker outcome=DIFF|NO-CHANGE` の場合だけ有効。`pending verification` は internal holding state であり、そのまま reviewer に投げない。`worker outcome=BLOCK` または `status=blocked` は block report path に切り替える
- `worker outcome` は `DIFF` / `BLOCK` / `NO-CHANGE` のみ有効。payload 条件は matrix の `Worker Outcome Contract` を正本とし、evidence の無い `NO-CHANGE` は final handoff に持ち込まない
- reviewer が追跡できない handoff は `pending final review` と呼ばず、補完後に再依頼する

### 次のCoderへの引き継ぎ（ハンドオーバー）
`.agent/active/prompts/` に以下を記載:
- **背景**: なぜこの作業が必要か
- **変更点**: 何を変更したか
- **未解決**: 残っている課題
- **再現手順**: 環境構築・実行方法
- **重要ファイル**: 必ず確認すべきファイル
- **ハマりポイント**: 試行錯誤の履歴

---

## 禁止事項

1. **テスト改ざん禁止**: テストが通らない時にテストを緩めることは原則禁止
2. **main直接編集は原則禁止**: Worktree（`./scripts/hydra new`）を使用。例外は `.agent_rules/RULES.md` Phase 1.8 のWorktree例外に従う
3. **推測での実装禁止**: 不明点は確認してから実装
4. **過剰設計禁止**: 必要最小限の実装に留める
5. **外部 Codex 直接呼び出し禁止**: caller-facing / manual / external な `codex exec` ではなく `scripts/codex-wrapper.sh --role ...` を使う。native Codex multi-agent / subagent orchestration は Codex 内部に留め、wrapper を再帰呼び出ししない

---

## フェーズ対応表

| RULES.mdフェーズ | Coder責務 |
|-----------------|----------|
| Phase 0: Setup | 環境構築・依存関係解決 |
| Phase 1: Planning | ExecPlan作成 |
| Phase 1.5: Design & Test | Blueprint + TDD |
| Phase 1.8: Worktree | 隔離環境作成 |
| Phase 2: Execution | 実装 |
| Phase 3: Verification | テスト実行・検証 |
| Phase 3.5: Audit | 自己監査 |
| Phase 4: Completion | completion boundary と review handoff 証跡の整理 |
| Phase 5: Reporting | reviewer / orchestrator 向け handoff 報告 |

---

## 関連ドキュメント
- [RULES.md](../../.agent_rules/RULES.md) - 共通ルール
- [Orchestration Closure Playbook](../manual/orchestration-closure-playbook.md) - class closure / adversarial pass / final handoff テンプレート
- [Reviewer](./reviewer.md) - レビュー担当
- [Orchestrator](./orchestrator.md) - 統括担当

## Capsule Contract (frontier-push 以降)

agent が `sem.capsule` 経由で受け取る capsule body は以下の不変条件を持つ:

- `INDEX_VERSION=<u64>`: informational、`CAPSULE_SHA256` の hash 入力**外**
- `FILE_SHA_ROLLUP=<sha256_hex>`: `CAPSULE_SHA256` の hash 入力**内**、cache-bound freshness invariant
- caller は `{project_id, task_id, phase, context_token}` 必須、`top_k_symbols` フィールド送信は fail-closed
- prefix wildcard search は提供せず、FTS5 BM25 + 48h recency が既定

詳細: skill `revharness-semantic-mcp-usage`、CLAUDE.md、`.agent_rules/RULES.md` の capsule discipline 節。

### Coder 固有

agent-core/cmd/capsule.rs (`build_capsule_with_symbols`) も同 contract、`shared::freshness` 経由で `file_sha_rollup` / `index_version` を bind する。

## Specialties

Coder canonical role narrows into these specialty operating templates (each
under `docs/roles/coder/specialties/`):

- `production-function-implementer.md` — type-safe, validated, observable
  function implementation for production-grade systems
- `refactor-safety-analyst.md` — caller-map / blast-radius analysis before
  any code refactor; isolate semantic vs mechanical change
- `hypothesis-driven-debugger.md` — diagnose before patch; rank root cause
  candidates with confirming + disconfirming evidence
- `codebase-archaeologist.md` — map entry points, main flow, safe-first
  change, risky areas in an unfamiliar codebase
- `performance-detective.md` — measure before optimize; p95/p99/max profile
  + bottleneck hypothesis ranking
- `risk-based-test-strategist.md` — design tests against production failure
  risks, not coverage targets

Each specialty file contains an embedded JSON manifest declaring its
`required_output_sections`, `matrix_fields_allowed`, `allowed_runtime_roles`,
and `thin_skill_projection` settings. Use
`agent-core specialty lint <path>` to validate any specialty file.
