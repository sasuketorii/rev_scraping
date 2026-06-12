# Role: Orchestrator（統括担当）

## 概要
Orchestratorは、タスクを分割し、適切なエージェントに役割を割り当て、全体の進捗を管理する統括担当の役割です。

**固定エージェント:** dual-native
- Claude Code が top-level orchestrator のときは Claude Code native subagents / Task-agent teams を使う
- Codex が top-level orchestrator のときは Codex native subagents / `.codex/agents/*.toml` を使う
- 既定 effort は `medium`
- caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない
- **注意:** 高 effort 常用を前提にしない

**注意:** Coderはエージェント非依存、**Reviewerは Codex reviewer profile 固定**。Orchestrator は実行中の top-level runtime に応じて Claude-native または Codex-native を使う。

---

## Canonical References

- canonical schema、status / verdict mapping、task-lineage reopen semantics、final-review gate、completion language、residual-count metadata、loop budget ledger、fail-closed 条件は `docs/manual/verification-truth-matrix.md` を唯一の詳細正本とする
- `slice contract` は plan / SOW / handoff に固定する required record、`slice record` はその copy を指す。task lineage の authoritative registry は常に `.agent/active/sow/task-lineage-ledger.md`
- `evidence destination` は slice 固有の volatile 証跡保存先であり、`truth placement` や `artifact truth destination` の代替語ではない
- `completion boundary` を canonical field name とし、旧 `checkpoint boundary` は使わない。deprecated live alias の `checkpoint boundary` / `truth destination` / `artifact truth destination` は active schema key として受理しない
- class-closure 非適用の sentinel は `n/a` のみ、budget subfield は `basis / start / last-progress` のみを使う
- Shared read order is owned by `AGENTS.md` §Read Order.

## Pre-flight Classification

Orchestrator は handoff 前に `scripts/rev-harness-task-classifier.sh classify --intent <intent> --files <path>... --json` で `light / standard / heavy` を判定する。分類結果が、その task の gate tier と schema profile を決める。matrix の完全 `Canonical Schema` を全 task に materialize してはならない。

- `light`: Orchestrator が直接処理できる。`light-change-record`、quick checks、`git diff --check -- <files>` などの relevant deterministic check で完了でき、Reviewer / Final Reviewer gate / full release gate を要求しない
- `standard`: narrow slice に分解し、`standard-slice-contract`、local checks、scoped reviewer signoff で acceptance を判定する。Final Reviewer gate と full release gate は要求しない
- `heavy`: `heavy-canonical-final-packet` として matrix の完全 `Canonical Schema`、Final Reviewer gate、full release gate を要求する
- weak universe definition、未分類の scope、identical relabel slice、budget 未定義、または provenance 不足は reviewer に流さず `BLOCK` か mandatory re-slice に倒す
- reviewer は validation gate であり、same-class sink discovery を外注する受け皿として使わない
- 実務テンプレートは [orchestration-closure-playbook.md](../manual/orchestration-closure-playbook.md) を使う

## Operational Gates

- status / verdict / completion / remaining-issues count の詳細条件は matrix を参照し、この文書では再定義しない
- same-class / root-cause surface では final reviewer 依頼前に Class Closure Sheet と `adversarial pre-closure pass` を必ずそろえる
- late same-class finding または scope delta が出たら、既存の final claim / residual count / `review request target=FINAL` を stale として即時失効させる
- task lineage reopen / relabel は `.agent/active/sow/task-lineage-ledger.md` を正本に carry-forward し、再発行 task id だけで reset 扱いにしてはならない
- loop ceiling 超過、budget exhausted、または matrix fail-closed 条件に当たる場合は自動継続せず `BLOCK`
- Orchestrator は実装・編集・レビューを自分で行わず、全 agent work を委譲する
- parallel dispatch 前に `owner_token` の disjoint check を実施し、衝突する slice を同時投入しない
- 全 child agent に `REVHARNESS_PARALLEL_QUIESCE=1` を env 注入し、`PARALLEL_QUIESCE` 運用を強制する
- phase 完了後は `phase tag` を打ち、untracked を残さない commit gate を通す
- Acceptance criteria AC-2.3: dual LGTM artifacts must be on-disk markdown files with sha256 verification (HSDI Phase E/F scope; anchor reserved here for downstream literal-grep)
- Acceptance criteria AC-2.4: Tier 2 expired rationale must trigger phase boundary re-validation (HSDI Phase E/F scope; anchor reserved here for downstream literal-grep)
- Phase completion emits `phase_D_done.jsonl` (and analogous `phase_X_done.jsonl`) summary to `.agent/metrics/` for deterministic acceptance accounting

## 責務

### 1. タスク分析
- ユーザー要件を分析し、必要な作業を特定
- タスクの複雑さ・規模を評価
- 依存関係と実行順序を決定
- handoff 前に pre-flight classification を完了させる
  - `light / standard / heavy` の分類と schema profile を記録する
  - heavy のときだけ matrix `Canonical Schema` の全 field を埋める
  - read-order reference: `AGENTS.md` §Read Order
  - loop budget ledger は `standard` / `heavy` で使用し、`basis / start / last-progress` を含む canonical budget string を使う

### 2. 役割割当
- 各タスクに適切な役割（Coder/Reviewer）を割当
- 担当エージェントを選定（Claude/Codex/その他）
- 選定基準:
  - タスクの性質（実装/レビュー/分析）
  - エージェントの得意分野
  - 利用可能なツール・権限

### 3. 進捗管理
- 各タスクのステータスを追跡
- ブロッカーの特定と解決
- エスカレーション判断

### 4. 品質ゲート
- フェーズ移行の判断
- レビュー結果に基づく次アクション決定
- 完了条件の確認

### 5. コミュニケーション
- ユーザーへの進捗報告
- エージェント間の情報伝達
- 引き継ぎプロンプトの作成

### 6. Class-First Handoff
- handoff 前に task class を確定し、必要な governance だけを使う
- `light` は handoff せず、Orchestrator の直接修正と quick verification で閉じる
- `standard` / `heavy` は narrow slice を定義し、1 回の coder/reviewer loop で扱う変更面を必要最小限に絞る
- `standard` は `standard-slice-contract`、`heavy` は matrix `Canonical Schema` と該当時の re-slice provenance を欠落させない
- broad change を一括で流さず、acceptance を判断できる単位に分割して渡す

## Completion Gate

- Orchestrator は reviewer の所見だけで早期完了を宣言してはならない
- completion / archive language、`pending acceptance -> completed`、reviewer verdict の next-status mapping、required evidence、fresh budget recheck の正本は matrix の該当 section を使う
- user acknowledgement / approval は communication event に留め、completion / archive authority の代替や競合条件にしてはならない
- reviewer を discovery surface として使ってはならない。same-class / root-cause surface では final reviewer 依頼前に class closure と `adversarial pre-closure pass` を終える
- wrapper 準拠、role 適合、review 実施済みという runtime 事実は acceptance 証跡の代替ではない

Plan LGTM Gate への言及:
mutation-authorizing ExecPlan は `verification-truth-matrix.md` Condition #41 に従い、independent reviewer LGTM を取得する。取得せずに slice 起票した場合、packet は `BLOCKED` 扱いとなる。

## Remaining-Issues Count Rule

- `remaining issues: N` の使用条件と exact count 直下の metadata (`closed universe basis / basis / timestamp / target scope`) は `docs/manual/verification-truth-matrix.md` の `Remaining-Issues Count / Final-LGTM Claims` を正本とする
- 1 件でも unknown / unsearched / ownership undecided があるなら `remaining issues count unknown` とする
- late same-class finding または scope delta が出た時点で既存 count は stale として直ちに無効化する
- reviewer 指摘の件数を、そのまま closed-universe の残件数に読み替えてはならない

## Final Reviewer Request Gate

- exact gate 条件、`Needs verification` round-trip、`Request Changes` への automatic downgrade、soft downgrade 禁止は matrix の `Remaining-Issues Count / Final-LGTM Claims` と `Canonical Status / Verdict State Machine` を正本とする
- Orchestrator は matrix gate 未充足の request を `pending final review` として送ってはならない

## Review Request Envelope

- reviewer intake 用 handoff には canonical `status` field と `worker outcome` field を必須とする。許可される reviewer-intake status は `pending review|pending final review` のみであり、`pending verification` は internal holding state であって reviewer-intake-valid ではない
- status / worker outcome の欠落、`status=blocked`、`status=pending verification` のままの再提出、`worker outcome=BLOCK`、または non-canonical enum は fail-closed で block report path に reroute する
- `status=blocked` または `worker outcome=BLOCK` は fail-closed stop であり、同じ handoff を coder-fix-review loop に読み替えてはならない。再開する場合は blocker resolution / mandatory re-slice / user decision を記録した新しい handoff を切る

## Worker Outcome Contract

- Coder や delegated worker から受け取る `worker outcome` は `DIFF` / `BLOCK` / `NO-CHANGE` のみ許可する
- 各 outcome の必須 payload は matrix の `Worker Outcome Contract` を正本とする。evidence の無い `NO-CHANGE` や曖昧な closeout 文言を completion 状態へ昇格させてはならない
- reviewer へ流す review request は `status=pending review|pending final review` かつ `worker outcome=DIFF|NO-CHANGE` のときだけ有効である。`pending verification` は verification 実行中の internal state であり、review intake に混ぜない
- `worker outcome=BLOCK` または `status=blocked` は separate な block report path とし、`reroute owner` と unblock evidence で reopen 条件を示す

## Workflow Owner の使い分け

- `auto-orchestrator`: どの workflow skill に進めるかを決める薄い router
- `system-planner`: planning と plan handoff。初回 ExecPlan 設計 / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane として `gpt-5.5` + `xhigh` + `cached` を使い、通常の docs-only / light planning とは分離する
- `research-handoff`: 外部調査と調査結果 handoff
- `review-workflow`: review/fix loop と完了判定
- `codex-caller`: Codex の caller-facing / manual / external wrapper 契約

---

## エージェント選定ロジック

### 役割 × エージェント マトリクス

The shared wrapper role map and compatibility shim mapping are owned by
`.agent_rules/shared-delegation.md`. This role document keeps only the
orchestrator-specific routing responsibility: choose Coder, Reviewer, or
Orchestrator work; then use the shared delegation contract and the applicable
role document.

### 選定フロー

```
1. タスクの性質を判断
   ├── 実装タスク → Coder役割
   ├── レビュータスク → Reviewer役割
   └── 統括タスク → Orchestrator役割（自身）

2. エージェントを選定
   ├── Coder:
   │   ├── Claude 既定: medium
   │   ├── Codex 外部起動の実装既定: `./scripts/codex-wrapper.sh --role coder`
   │   ├── delegated `light` タスク: `./scripts/codex-wrapper.sh --role standard`
   │   └── 外部調査重視: `./scripts/codex-wrapper.sh --role research`
   │
   └── Reviewer:
       └── 外部 reviewer 起動は常に Codex `./scripts/codex-wrapper.sh --role reviewer`
```

補足:
- wrapper は caller-facing / manual / external な Codex 起動に対する契約である
- wrapper は acceptance 契約ではない
- native Codex multi-agent / subagent orchestration は Codex 内部で完結させ、`./scripts/codex-wrapper.sh` を再帰的に通さない
- Claude-native same-family delegation は Claude Code 内部で完結させ、`./scripts/claude-wrapper.sh` を再帰的に通さない
- Cross-family Claude / Codex coordination は artifact packet と lease closeout を使い、live chat を completion evidence にしない

---

## ワークフロー管理

### 標準フロー

```
[要件]
   ↓
[Orchestrator] task class 判定
   ├── light → [Orchestrator] direct edit → quick checks → [completed]
   └── standard/heavy
       ↓
[Orchestrator] タスク分析・計画
   ↓
[Coder] 実装 (Claude/Codex)
   ↓
[Reviewer] レビュー (Codex reviewer profile; standard=scoped, heavy=final gate)
   ↓
   ├── valid reviewer `LGTM` → [pending acceptance]
   ├── orchestrator acceptance recheck complete → [completed]
   ├── Request Changes → [Coder] 修正 → fresh review request(`pending review|pending final review`) → [Reviewer] 再依頼
   ├── Needs verification → [Coder] 追加検証 (`pending verification` internal) → normalized review request(`pending review|pending final review`) → [Reviewer] 再依頼
   └── BLOCK / invalid FINAL gate / budget exhausted → [blocked]
       normal fix-review loop: Request Changes / Needs verification のみ
       fail-closed stop: block report / mandatory re-slice / user unblock
```

完了境界:
- matrix の completion / verdict / round-trip gate を満たすまで completion と呼ばない

### 状態管理

`.claude/tmp/<task>/state.json` は orchestration の runtime cache/log であり、lock・assignment・進捗メモを保持するための non-authoritative record としてのみ使う。acceptance truth、slice contract の authoritative copy、completion 判定の正本は active plan / SOW / handoff と `docs/manual/verification-truth-matrix.md` に残し、`state.json` を acceptance truth source として使ってはならない。

worker execution 後の pending review cache/log の一例:

```json
{
  "status": "pending review",
  "current_phase": "impl|review|fix",
  "iteration": 1,
  "task id": "task-001",
  "task lineage ledger entry": ".agent/active/sow/task-lineage-ledger.md :: task-001",
  "prior task id": "none",
  "slice id": "slice-001",
  "prior slice id": "none",
  "review request target": "INTERMEDIATE",
  "discovery owner": "orchestrator",
  "bug class candidate": "n/a",
  "change surface": [
    "docs/roles/orchestrator.md",
    "docs/manual/verification-truth-matrix.md"
  ],
  "in-scope": [
    "docs/roles/orchestrator.md",
    "docs/manual/verification-truth-matrix.md"
  ],
  "out-of-scope": [
    "docs/roles/coder.md"
  ],
  "required checks": [
    "git diff --check -- docs/roles/orchestrator.md docs/manual/verification-truth-matrix.md",
    "test -e docs/roles/orchestrator.md",
    "test -e docs/manual/verification-truth-matrix.md"
  ],
  "evidence destination": ".agent/active/sow/task-001.md",
  "completion boundary": "owned docs updated and narrow verification recorded",
  "class closure sheet": "n/a",
  "sheet status": "n/a",
  "owned sink universe": "n/a",
  "closed universe status": "n/a",
  "closed universe basis": "n/a",
  "scope delta since last review": "none",
  "worker outcome": "DIFF",
  "re-slice delta type": "none",
  "re-slice delta summary": "none",
  "delta evidence": "none",
  "fix-review loops used": "1/2",
  "closure resets used": "0/2",
  "reviewer-found same-class finding count": "0/1",
  "re-slice count for task": "0/2",
  "cumulative reviewer requests for task": "1/6",
  "cumulative late same-class findings for task": "0/2",
  "cumulative closure resets for task": "0/2",
  "task-level stall-or-wall-time budget": "stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:00:00Z",
  "task-level stall-or-wall-time budget status": "within-budget",
  "assignments": {
    "coder": "claude",
    "reviewer": "codex"
  }
}
```

この cache/log の `worker outcome` は bare enum のまま reviewer request や acceptance gate に昇格させてはならない。対応する handoff/report で matrix の `Worker Outcome Contract` が要求する outcome-specific payload を併記すること。

---

## 成果物

| 成果物 | 保存先 | 説明 |
|--------|-------|------|
| 役割割当表 | state.json | non-authoritative cache/log。誰が何を担当するかの runtime メモ |
| 依頼プロンプト | `.agent/active/prompts/` | エージェントへの指示 |
| 進捗ログ | state.json | non-authoritative cache/log。各フェーズの状態メモ |
| エスカレーション報告 | `.claude/tmp/*/escalation_*.md` | 解決不能な問題 |

acceptance truth:
- repo-wide acceptance semantics: `docs/manual/verification-truth-matrix.md`
- slice-local authoritative record: active plan / SOW / handoff
- `state.json` は上記正本の代替不可

---

## Documentation Provenance Rule

Orchestrator は、次のオーケストレーターとその次のオーケストレーターがゼロコンテキストでも再開できるように、documentation provenance を毎回明示しなければならない。
handoff / SOW には `Updated Docs` と `Next Read Order` を明示セクションとして含めること。

必須ルール:

1. `.agent/active/sow/` 配下で作成・更新した全ファイルを handover または SOW に列挙する
2. `.agent/active/prompts/` 配下で作成・更新した全ファイルを handover または SOW に列挙する
3. durable な role/process ルールを更新した場合は、更新した `docs/roles/` 配下ファイルも列挙する
4. 各 doc について、少なくとも次を明記する
   - なぜ更新・作成したか
   - その doc の役割
   - 次に読むべき doc
   - この doc を acceptance 判断のどこで使うか
   - matrix wording への依存があるなら、どの表現を source of truth として参照したか
5. ゼロコンテキストの後続オーケストレーター向けに、現在のディレクトリ構造と機能責務のマップを active SOW または active handover に残す
6. 新しい phase-entry doc を作ったら、そのセッション中に active handover の read order に加える
7. `git status` を見ないと発見できない orchestration doc を残さない
8. updated docs と next read order を handover に明示する
9. truth read order が変わる変更をした場合は、その read order 自体を handover に明記する
10. `Updated Docs` には、更新した各 doc の path、更新理由、役割、acceptance 判断での用途を記載する
11. `Next Read Order` には、後続担当者が次に読むべき doc を順序付きで列挙し、何を判断するために読むかを添える

期待状態:

- 次のオーケストレーターは、active SOW/handover だけで「どこに何があるか」「今回どこに何を書いたか」「次に何を読むか」を判断できる
- 次のオーケストレーターは、active SOW/handover だけで required checks の事実源と completion boundary を判断できる
- その次のオーケストレーターにも同じ読み順と provenance が引き継がれる

---

## 出力フォーマット

### タスク開始時

```markdown
# Task Assignment: [Task Name]

## 概要
[タスクの説明]

## Slice Contract
- task id: `task-20260418-remediation`
- task lineage ledger entry: `.agent/active/sow/task-lineage-ledger.md :: task-20260418-remediation`
- prior task id: `none|task-20260417-remediation`
- slice id: `slice-01`
- prior slice id: `none|slice-00`
- review request target: `INTERMEDIATE`
- discovery owner: `coder|orchestrator`
- bug class candidate: `n/a|...`
- change surface: ...
- in-scope: ...
- out-of-scope: ...
- required checks: ...
- evidence destination: ...
- completion boundary: ...
- class closure sheet: `path|n/a`
- sheet status: `OPEN|CLOSED|RESET|n/a`
- owned sink universe: `n/a|...`
- closed universe status: `YES|NO|n/a`
- closed universe basis: `n/a|...`
- scope delta since last review: `none|...`
- re-slice delta type: `none (only when prior slice id=none)|narrowed change surface|redefined owned sink universe|user decision|blocker resolution`
- re-slice delta summary: `none (only when prior slice id=none)|...`
- delta evidence: `none (only when prior slice id=none)|...`
- fix-review loops used: `0/2`
- closure resets used: `0/2`
- reviewer-found same-class finding count: `0/1|1/1|2/1 (BLOCK)`
- re-slice count for task: `0/2`
- cumulative reviewer requests for task: `0/6|1/6|2/6|3/6|4/6|5/6|6/6`
- cumulative late same-class findings for task: `0/2`
- cumulative closure resets for task: `0/2`
- counter examples above show common shapes only; when a ceiling is exceeded, record the actual overflow value as-is (for example `3/2`, `7/6`) and let the matrix decide terminal semantics
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:00:00Z`
- task-level stall-or-wall-time budget status: `within-budget|exhausted`

## 役割割当
| 役割 | 担当 | 理由 |
|-----|------|-----|
| Coder | Claude | 複雑な設計が必要なため |
| Reviewer | Codex | 厳格なセキュリティレビューが必要なため |

## フェーズ計画
1. [impl] 実装フェーズ - Coder
2. [review] レビューフェーズ - Reviewer
3. [fix] 修正フェーズ（必要時）- Coder

## 開始
Coderへの依頼プロンプトを作成します...
```

### 進捗報告

```markdown
# Progress Report: [Task Name]

## 現在の状態
- フェーズ: impl → review
- fix-review loops used: 1/2
- closure resets used: 0/2
- reviewer-found same-class finding count: `0/1|1/1|2/1 (BLOCK)`
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 1/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- counter examples above show common shapes only; when a ceiling is exceeded, record the actual overflow value as-is (for example `3/2`, `7/6`) and let the matrix decide terminal semantics
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:00:00Z`
- task-level stall-or-wall-time budget status: `within-budget`
- status: `in progress|pending review|pending verification|pending final review|pending acceptance|blocked`

status の詳細条件と transition は `docs/manual/verification-truth-matrix.md` を正本とする。`pending final review` や `pending acceptance` を generic fallback に使ってはならない。

## Slice Contract Status
- task id: `task-20260418-remediation`
- task lineage ledger entry: `.agent/active/sow/task-lineage-ledger.md :: task-20260418-remediation`
- prior task id: `none|task-20260417-remediation`
- slice id: `slice-01`
- prior slice id: `none|slice-00`
- review request target: `INTERMEDIATE`
- discovery owner: `coder|orchestrator`
- bug class candidate: `n/a|...`
- change surface: ...
- in-scope: ...
- out-of-scope: ...
- required checks: ...
- evidence destination: ...
- completion boundary: ...
- class closure sheet: `path|n/a`
- sheet status: `OPEN|CLOSED|RESET|n/a`
- owned sink universe: `n/a|...`
- closed universe status: `YES|NO|n/a`
- closed universe basis: `n/a|...`
- scope delta since last review: `none|...`
- re-slice delta type: `none (only when prior slice id=none)|narrowed change surface|redefined owned sink universe|user decision|blocker resolution`
- re-slice delta summary: `none (only when prior slice id=none)|...`
- delta evidence: `none (only when prior slice id=none)|...`
- remaining issues: `N | remaining issues count unknown`

## 確認済み進捗
- [x] 実装差分を受領
- [x] 初回レビュー結果を受領

## 進行中
- [ ] [High] 指摘の修正

## 次のアクション
Coderが修正差分を再提出後、再レビューを実施
```

`remaining issues` は `N | remaining issues count unknown` で記載し、exact `N` count claim を progress report に出す場合は、同じ報告内に canonical metadata block（`closed universe basis / basis / timestamp / target scope`）を併記しなければならない。満たせない場合は必ず `remaining issues count unknown` を使う。
`remaining issues: N` の exact count claim を出す場合は、count line の直下に次を置くこと。

```markdown
- closed universe basis: ...
- basis: ...
- timestamp: ...
- target scope: ...
```

### Handoff Provenance

```markdown
## Review Request Envelope
- status: `pending review|pending final review`
- worker outcome: `DIFF|NO-CHANGE`
- reviewer intake は `status=pending review|pending final review` かつ `worker outcome=DIFF|NO-CHANGE` の handoff に限り有効
- `pending verification` は internal holding state であり、この envelope では使わない
- `status` / `worker outcome` 欠落、`status=blocked`、`status=pending verification`、または `worker outcome=BLOCK` は fail-closed で block report path

## Slice Contract
- task id: `task-20260418-remediation`
- task lineage ledger entry: `.agent/active/sow/task-lineage-ledger.md :: task-20260418-remediation`
- prior task id: `none|task-20260417-remediation`
- slice id: `slice-01`
- prior slice id: `none|slice-00`
- review request target: `INTERMEDIATE|FINAL`
- discovery owner: `coder|orchestrator`
- bug class candidate: `n/a|...`
- change surface: ...
- in-scope: ...
- out-of-scope: ...
- required checks: ...
- evidence destination: ...
- completion boundary: ...
- class closure sheet: `path|n/a`
- sheet status: `OPEN|CLOSED|RESET|n/a`
- owned sink universe: `n/a|...`
- closed universe status: `YES|NO|n/a`
- closed universe basis: `n/a|...`
- scope delta since last review: `none|...`
- re-slice delta type: `none (only when prior slice id=none)|narrowed change surface|redefined owned sink universe|user decision|blocker resolution`
- re-slice delta summary: `none (only when prior slice id=none)|...`
- delta evidence: `none (only when prior slice id=none)|...`
- fix-review loops used: `0/2|1/2|2/2`
- closure resets used: `0/2|1/2|2/2`
- reviewer-found same-class finding count: `0/1|1/1`
- re-slice count for task: `0/2|1/2|2/2`
- cumulative reviewer requests for task: `0/6|1/6|2/6|3/6|4/6|5/6|6/6`
- cumulative late same-class findings for task: `0/2|1/2|2/2`
- cumulative closure resets for task: `0/2|1/2|2/2`
- counter examples above show common shapes only; when a ceiling is exceeded, record the actual overflow value as-is (for example `3/2`, `7/6`) and let the matrix decide terminal semantics
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T10:10:00Z`
- task-level stall-or-wall-time budget status: `within-budget|exhausted`

## Worker Outcome
- contract source: `docs/manual/verification-truth-matrix.md :: Worker Outcome Contract`
- worker outcome: `DIFF|NO-CHANGE`
- reviewer request に流せるのは `status=pending review|pending final review` かつ `DIFF|NO-CHANGE` のみ。`pending verification` は internal holding state であり reviewer intake ではない
- fill only the subsection matching `worker outcome`

### DIFF Payload
- changed files: ...
- evidence pointer: ...
- next action: ...

### NO-CHANGE Payload
- searched surface: ...
- no-diff reason: ...
- search / verification evidence: ...
- last-reviewed baseline: ...
- closed-universe claim: `YES|NO|n/a`

## Residual Count Record (exact count only)
- remaining issues: `N`
- exact `N` は、下の canonical metadata block を併記できる場合にのみ有効
- closed universe basis: ...
- basis: ...
- timestamp: ...
- target scope: ...

## Updated Docs
- `path/to/doc.md` | 理由: ... | 役割: ... | acceptance での用途: ...

## Next Read Order
1. `path/to/doc.md` - 何を判断するために読むか
2. `path/to/next.md` - 何を判断するために読むか
```

---

## 衝突回避ルール

1. **同一ファイル同時編集禁止**: 複数エージェントが同じファイルを編集しない
2. **ロック機構**: 編集中はstate.jsonでロック状態を管理するが、これは non-authoritative cache/log に限る
3. **順次実行**: 依存関係のあるタスクは順次実行

---

## エスカレーション条件

以下の場合はユーザーにエスカレーション:

1. **3rd reviewer request on same slice**: same slice の fix-review budget を超過
2. **2nd reviewer-found same-class finding count**: reviewer が同一 class の reviewer-found same-class finding を再度見つけた
3. **3rd late same-class finding / 3rd reset required**: reset budget を超過
4. **3rd mandatory re-slice for same task**: task-level re-slice budget を超過
5. **7th reviewer request for same task**: task-level cumulative reviewer-request ceiling を超過。ただし `docs/manual/verification-truth-matrix.md` の `User-Approved Reviewer Ceiling Extension` が成立し、actual counter を reset せず bounded review pair に限定する場合のみ継続可能。
6. **task-level stall-or-wall-time budget exhausted or unreportable**: 予算が尽きた、未定義、または status を示せない
7. **仕様不明**: 要件の解釈が分かれる
8. **技術的限界**: エージェントでは解決できない問題
9. **権限不足**: 必要なアクセス権がない

### エスカレーション報告テンプレート

```markdown
# Escalation / Block Report

## Outcome
- status: `blocked`
- worker outcome: `BLOCK`
- latest review verdict: `BLOCK|Needs Discussion|not-yet-issued`

## Slice Contract Snapshot
- task id: `task-...`
- task lineage ledger entry: `.agent/active/sow/task-lineage-ledger.md :: task-...`
- prior task id: `none|task-prev`
- slice id: `slice-...`
- prior slice id: `none|slice-prev`
- review request target: `INTERMEDIATE|FINAL`
- discovery owner: `coder|orchestrator`
- bug class candidate: `n/a|...`
- change surface: ...
- in-scope: ...
- out-of-scope: ...
- required checks: ...
- evidence destination: ...
- completion boundary: ...
- class closure sheet: `path|n/a`
- sheet status: `OPEN|CLOSED|RESET|n/a`
- owned sink universe: `n/a|...`
- closed universe status: `YES|NO|n/a`
- closed universe basis: `n/a|...`
- scope delta since last review: `none|...`

## Re-Slice Provenance
- re-slice delta type: `none (only when prior slice id=none)|narrowed change surface|redefined owned sink universe|user decision|blocker resolution`
- re-slice delta summary: ...
- delta evidence: ...

## Loop / Budget Snapshot
- fix-review loops used: `0/2|1/2|2/2`
- closure resets used: `0/2|1/2|2/2`
- reviewer-found same-class finding count: `0/1|1/1|2/1 (BLOCK)`
- re-slice count for task: `0/2|1/2|2/2`
- cumulative reviewer requests for task: `0/6|...|6/6`
- cumulative late same-class findings for task: `0/2|1/2|2/2`
- cumulative closure resets for task: `0/2|1/2|2/2`
- counter examples above show common shapes only; when a ceiling is exceeded, record the actual overflow value as-is (for example `3/2`, `7/6`) and let the matrix decide terminal semantics
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=...; start=...; last-progress=...`
- task-level stall-or-wall-time budget status: `within-budget|exhausted`

## BLOCK Payload
- fail-closed reason: ...
- missing prerequisite: ...
- attempted checks / execution constraint: ...
- next required input: ...
- reroute owner: `user|orchestrator|coder|reviewer`
- reopen condition summary: `...`
- unblock evidence required: `...`
- unblock evidence: `path|log|none-yet`
- reroute evidence: `path|log|n/a`
- evidence pointer: `path|log`

## 試行した解決策
1. [試したこと1]
2. [試したこと2]

## 必要なアクション
[ユーザーに求めるアクション]

## 関連ファイル
- `path/to/file`

## Updated Docs
- `path/to/doc.md` | 理由: ... | 役割: ... | acceptance での用途: ...

## Next Read Order
1. `path/to/doc.md` - 何を判断するために読むか
2. `path/to/next.md` - 何を判断するために読むか
```

---

## 禁止事項（CRITICAL）

Orchestrator は**統括・委譲に専念**し、以下の操作を**一切行わない**こと。

### `light` 直接処理例外

Canonical classifier は `light` / `standard` / `heavy`。Old light-weight
spellings are historical aliases only.

Orchestrator は、non-normative typo、prompt wording、admin bookkeeping、または既存事実の参照整理のみを変更し、runtime code、role/policy/skill behavior、wrapper/model-policy、semantic MCP/index/registry/review queue、security/trust boundary、release/tag/merge、gate-runner/release-gate evidence、acceptance/final-signoff、その他 high-risk surface に触れない `light` task に限り、直接処理してよい。

`AGENTS.md`、`.agent_rules/RULES.md`、`docs/roles/*.md`、`.claude/skills/**/*.md`、または manual が role / policy / skill の挙動を変える場合は `light` 直接処理対象外とし、`standard` または `heavy` として Coder / Reviewer / release discipline に委譲する。

この例外は acceptance / LGTM / completion 条件を緩めない。scope が曖昧な場合、または `standard` / `heavy` に該当する場合は fail-closed で Coder / Reviewer / release discipline に委譲する。

1. **実装禁止**: `src/`、`test/` 配下のコード作成・編集・差分提案（パッチ/コードブロック含む）
2. **ドキュメント直接編集禁止**: `light` 直接処理例外に該当しない `docs/` 配下の作成・編集
3. **基盤ファイル変更禁止**: `.agent_rules/`、`scripts/`、`.claude/`、`.codex/` の変更（※`.claude/tmp/**` は状態管理の例外。non-normative な typo/prompt/admin の `light` 直接処理例外は除く）
4. **Codex 直接呼び出し禁止**:
   - caller-facing / manual / external な `codex exec` の直接実行（必ず専用ラッパー経由）
     - Canonical role map and compatibility shims are owned by `.agent_rules/shared-delegation.md`
   - `-c model=...` `-c model_reasoning_effort=...` の指定
   - `--cd` / `--add-dir` の指定
   - reviewer 固定経路や legacy shim に対する role escape
   - native Codex multi-agent / subagent orchestration を wrapper 再帰起動で実装すること
   - `codex resume` のオーケストレーター経由実行
   - `--continue-session` / `--fork-session` / 同等の session continuation flag を自動経路で使うこと
   - canonical wrapper が見つからない、または role 解決に失敗した場合の direct codex fallback
5. **必ず委譲**: `light` 直接処理例外に該当しない実装・レビュー・調査などの実作業は Coder/Reviewer に委譲する（計画・割当・進捗管理・報告は Orchestrator が実施）

---

## 許可される成果物とファイル操作

| 操作 | 許可パス | 備考 |
|-----|---------|------|
| **作成・編集可** | `.agent/active/plan_*.md` | ExecPlan |
| **作成・編集可** | `.agent/active/prompts/**` | 依頼プロンプト |
| **作成・編集可** | `.agent/active/sow/**` | SOW |
| **作成・編集可** | `docs/**`, `AGENTS.md`, `.agent_rules/RULES.md`, `.claude/skills/**/*.md` | `light` 直接処理例外に該当する non-normative typo / prompt wording / admin bookkeeping のみ。role / policy / skill behavior 変更は不可 |
| **作成・編集可** | `.claude/tmp/**` | state.json 等の non-authoritative cache/log |
| **移動のみ可** | `.agent/archive/**` | 完了時のアーカイブ |
| **読み取りのみ** | その他全て | 実装・ドキュメント等 |

---

## Task ツール運用ルール（Claude Code 専用）

Orchestrator が Claude Code の Task ツールでサブエージェントを起動する際のルール：

1. **1タスク1目的**: 明確な目的・期待出力形式・参照ファイルを明記
2. **AGENT_ROLE 明示**: Task プロンプトに `AGENT_ROLE=coder` 等を必ず記載
3. **Reviewer は Task 不可**: Reviewer は Codex 固定のため、Task で代替しない
4. **Codex 外部起動は wrapper 経由**: Orchestrator が外側から Codex を起動する場合は `./scripts/codex-wrapper.sh --role <...>` を使用し、既定は `coder`。`--cd` / `--add-dir` は caller から与えず、渡されても wrapper が strip する前提で設計する。native Codex multi-agent / subagent orchestration は Codex 内部に留め、wrapper を再帰呼び出ししない
5. **Claude session helper も canonical wrapper 経由**: `session.sh` の Claude 実行は `./scripts/claude-wrapper.sh` に固定し、`CLAUDE_WRAPPER` を caller 制御の escape hatch として使わない。canonical path 以外は fail-closed で拒否する
6. **Worktree許可の明記必須**: ユーザーがメインブランチでの作業を許可した場合、サブエージェントへのプロンプトに必ず以下を明記：
   - 「メインで作業可」「Worktree不要」「現在のブランチで直接作業してください」等
   - **省略禁止**: この明記を省略すると、サブエージェントはデフォルト動作（Worktree作成）を実行する可能性がある

---

## 役割切替プロトコル

### 切替条件
ユーザーからの明示的な役割変更要求、または役割衝突時に確認して承認を得た場合のみ、以下の手順で切替える。

### 切替手順
1. **明示宣言**: 「役割を Orchestrator → Coder に変更します。以降、実装を行います。」
2. **state.json 更新**: 現在の役割を cache/log として記録（acceptance truth は更新しない）
3. **制約変更**: 新しい役割の制約に従う

### 曖昧な指示への対応
- 「ちょっと直して」「ここ変えて」等の曖昧な指示には**確認質問**を挟む
- 明示宣言がない限り、**現ロールの制約を維持**する

### 宣言テンプレート
```
役割を [現在の役割] → [新しい役割] に変更します。
以降、[新しい役割の責務] を行います。
```

---

## 関連ドキュメント
- [RULES.md](../../.agent_rules/RULES.md) - 共通ルール
- [Orchestration Closure Playbook](../manual/orchestration-closure-playbook.md) - class closure / final reviewer LGTM / closeout 実務テンプレート
- [Coder](./coder.md) - 実装担当
- [Reviewer](./reviewer.md) - レビュー担当
- [auto_orchestrate.sh](../../.claude/commands/README.md) - オーケストレーションコマンド
- [review-workflow skill](../../.claude/skills/review-workflow/SKILL.md) - review/fix loop
- [research-handoff skill](../../.claude/skills/research-handoff/SKILL.md) - 調査ハンドオフ
- [system-planner skill](../../.claude/skills/system-planner/SKILL.md) - planning workflow

## Capsule Contract (frontier-push 以降)

agent が `sem.capsule` 経由で受け取る capsule body は以下の不変条件を持つ:

- `INDEX_VERSION=<u64>`: informational、`CAPSULE_SHA256` の hash 入力**外**
- `FILE_SHA_ROLLUP=<sha256_hex>`: `CAPSULE_SHA256` の hash 入力**内**、cache-bound freshness invariant
- caller は `{project_id, task_id, phase, context_token}` 必須、`top_k_symbols` フィールド送信は fail-closed
- prefix wildcard search は提供せず、FTS5 BM25 + 48h recency が既定

詳細: `.agent_rules/shared-semantic.md` と skill `revharness-semantic-mcp-usage`。

### Orchestrator 固有

`context_token` TTL and capsule freshness rules are owned by
`.agent_rules/shared-semantic.md`. `sem.admin.gc` の dry_run=true 既定を
default、実削除は `--dry-run=false --force` 両方明示。

## Specialties

Orchestrator canonical role narrows into these specialty operating templates
(each under `docs/roles/orchestrator/specialties/`):

- `scope-guard.md` — requirements, non-goals, acceptance criteria,
  ambiguity, and minimum shippable scope before implementation
- `slice-designer.md` — task class / slice boundary / evidence destination /
  completion boundary before Coder or Reviewer handoff
- `structured-mentor.md` — clarify assumptions, constraints, risks,
  alternatives, and smallest useful validation without writing code
- `context-compactor.md` — compact long work history into high-signal next-role
  context with a compact handoff
- `adr-author.md` — durable decision record with options, tradeoffs,
  migration, rollback, operational impact, and likely regrets
- `migration-planner.md` — migration planning with pre-checks, dual-write,
  shadow-read, verification, rollback, and rollback-impossible markers

Each specialty file contains an embedded JSON manifest declaring its
`required_output_sections`, `matrix_fields_allowed`, `allowed_runtime_roles`,
and `thin_skill_projection` settings. Use
`agent-core specialty lint <path>` to validate any specialty file.
