# Universal Agent Rules

## Primary Directives
1. **Language:** Think in English, interact with the user in Japanese. Worker-to-worker communication, handoff prompts, reviewer prompts, internal artifacts, and cross-agent coordination packets should be written in English by default to reduce token and context footprint. The orchestrator's user-facing reports remain Japanese unless the user explicitly asks otherwise.
2. **ExecPlans:** 複雑な機能追加や大規模なリファクタリングを行う際は、設計から実装に至るまで、必ず `.agent/active/plan_YYYYMMDD_HHMM_<task>.md` 形式の **ExecPlan** を使用すること。
   - 新規 ExecPlan は `docs/manual/execplan-checklist-standard.md` に従い、最低でも `Status Board` と `Slice Board` を checkbox で持つこと。
   - 再利用する雛形が必要な場合は `.agent/templates/execplan_checklist_template.md` を起点にすること。
   - 初回設計、つまり ExecPlan を取る段階は `.agent/registry/model_policy.json` の `initial_execplan_design` lane に従い、`gpt-5.5` + `xhigh` + `cached` を使う。`system_planner` / `plan_reviewer` の native preset はこの xhigh lane として扱い、通常の docs-only / light planning と混同して `medium` へ落としてはならない。

---

このドキュメントは、本プロジェクトにおけるAIエージェント（Cursor, Gemini, Claude等）の共通行動規範です。
すべてのエージェントは、以下のルールを厳格に遵守して開発を行ってください。

## 1. 基本原則 (Core Mandates)
- **自律性:** 指示待ちにならず、ゴールに向けて能動的に計画・実行・検証・報告を行うこと。
- **安全性:** ファイルの削除や破壊的な変更を行う際は、必ず事前に確認を取るか、復元可能な手段を確保すること。
- **一貫性:** 既存のコードスタイル、プロジェクト構造、命名規則を遵守すること。
- **一次情報主義:** 技術的な不明点やエラー解決においては、推測で進めるのではなく、必ず `docs/official-docs-links.md` に記載された**公式ドキュメント（一次情報）**を参照して正解を得ること。
- **Revharness Identity:** Revharness は速度、精度、低メモリ/低CPU/低トークン負荷、潜在バグの少なさ、拡張性/保守性/アップデート容易性を最上位の設計制約として扱う。prompt は短くしてよいが、acceptance、evidence、security、lease closeout、deterministic checks を削ってはならない。
- **Rust-first Backend:** runtime backend、control-plane、lease registry、artifact index、process supervision、semantic/indexing、validation runner など、実行時複雑性・性能・安全性が重要な surface は Rust-first で設計する。既存 shell / docs / compatibility entrypoint の全面移行を意味しない。

## 2. 開発プロセス (Development Workflow)

### Phase 0: セットアップ (Setup / Bootstrap)
- **新規プロジェクトの場合:**
  - 環境が未構築、または要件定義書のみが存在する状態であれば、まず `setup/setup_rules.md` を参照し、その手順に従って初期セットアップとルール整合を行うこと。

### Phase 1: 計画 (Planning)
- 作業を開始する前に、必ず `.agent/active/` 配下の計画ファイル（`plan_YYYYMMDD_HHMM_<task>.md`）を確認すること。
- Primary Directivesに従い、詳細な実行計画（ExecPlan）を作成し、ユーザーの承認を得ること。
- ExecPlan には少なくとも以下を含めること:
  - `Status Board`（task / release 境界の完了状況）
  - `Slice Board`（child slice の完了 / 未完了状況）
  - `Required Deterministic Checks`
  - `Completion Boundary`

### Phase 1.5: 設計とテスト (Design & Test - Blueprint Driven)
- **Blueprint First:** 実装に入る前に、全てのファイル構成と「中身が空の関数/型定義」のみを作成し、全体構造を確定させること。
- **Test First (TDD):** Blueprintに対して、要件を満たすテストコードを**実装よりも先に**作成すること。
- これにより、「テストをパスさせる」という明確なゲームとして実装を進めることができる。

#### 簡略化例外（軽微修正）
以下の**いずれか**を満たし、かつ**省略理由をSOWに明記**する場合のみ、Blueprint/TDDを省略可能:
1. 変更対象がドキュメント（`*.md`、`docs/`）または設定ファイル（`*.json`、`*.toml`、`*.yaml`、`*.yml`）のみ
2. 既存関数の1-2行の修正のみ（ロジック変更を伴わないtypo修正、コメント修正）

### Phase 1.8: Worktreeの作成 (Isolation - Hydra Flow)
- **Direct Edit Prohibition:** `main`、`develop`、`release/*` の統合ブランチを直接編集することを**原則禁止**する（ただし下記のWorktree例外を除く）。
- **Worktree First:** 実装作業を開始する際は、通常 `./scripts/hydra new [task-name]` を実行し、隔離されたWorktree環境を作成・移動してから作業を行うこと。
  - **代替手段:** `scripts/hydra` が存在しない場合は、`git worktree add` コマンドを使用すること（例: `git worktree add ../workspace/feat-xxx -b feat-xxx`）。

#### Worktree例外（セッション単位）
**原則:** `main`、`develop`、`release/*` の統合ブランチの直接編集は禁止。

**例外は以下のいずれかを満たす場合に許可:**

**A. ドキュメント/設定/メタ情報のみ**
- 変更対象はドキュメント/設定/メタ情報に限定（`*.md`, `docs/`, `*.json`, `*.toml`, `*.yaml`, `*.yml`, `.env*`, `.gitignore`, `.editorconfig` 等。拡張子は例示）
- `src/`、`test/`、`apps/` 等の実装コードは対象外

**B. ユーザーまたはオーケストレーターによる明示的許可**
- ユーザーが「メインでOK」「ブランチ不要」「現在のブランチで作業して」等を明示
- またはオーケストレーターがプロンプト/プランファイルで「メインで作業可」「Worktree不要」と指示
- 許可は**現在の統合ブランチ**（`main`, `develop`, `release/*` のいずれか）に対するものとして扱う
- この場合、Worktree作成は**不要**。慎重かつ自律的に作業を進めること

**共通条件:**
- 許可は当該セッション限り。継続する場合は再承認が必要
- 例外適用時は SOW に「許可内容・変更ファイル」を記録

### Phase 2: 実行 (Execution)
- 計画に基づき、ステップ・バイ・ステップで実装を行うこと。
- 複雑なタスクはサブタスクに分解し、進捗を都度記録すること。
- **Class-First Contract:** broad task をそのまま coder / reviewer に流してはならない。先に `scripts/rev-harness-task-classifier.sh classify --intent <intent> --files <path>... --json` で `light / standard / heavy` と schema profile を確定する。`light` は `light-change-record`、`standard` は `standard-slice-contract`、`heavy` だけが `docs/manual/verification-truth-matrix.md` の完全 `Canonical Schema` と該当時の re-slice provenance を採用する。`slice record` は copy に過ぎず、task lineage の authoritative registry は `.agent/active/sow/task-lineage-ledger.md` のみとする。旧 `checkpoint boundary` は deprecated / non-canonical であり、必ず `completion boundary` に統一すること。
- **Pre-flight Classification:** 実装前に少なくとも `task class / schema profile / change surface / required checks / evidence destination / completion boundary` を確定すること。詳細な field semantics、truth placement、task lineage、loop budget ledger、fail-closed 条件は `docs/manual/verification-truth-matrix.md` を正本とし、本書で再定義しない。
- **Task-size / Risk Classifier:** canonical classifier は `light` / `standard` / `heavy` とする。`lightweight` は過去 plan 名・artifact path・古い section title の historical alias のみであり、新規の canonical class 名として使わない。`light = dev + quick`、`standard = review + local`、`heavy = release + full` を基本対応とし、`heavy` のみ full canonical final packet / Final Reviewer gate / full release gate を既定要求する。acceptance / LGTM / completion の正本は引き続き `docs/manual/verification-truth-matrix.md` と deterministic checks とする。
- **Orchestrator Light Direct Handling Exception:** Orchestrator は、non-normative typo、prompt wording、admin bookkeeping、既存参照整理のみで、runtime code、role/policy/skill behavior、wrapper/model-policy、semantic MCP/index/registry/review queue、security/trust boundary、release/tag/merge、gate-runner/release-gate evidence、acceptance/final-signoff、その他 high-risk surface に触れない `light` task に限り、直接処理してよい。role / policy / skill の挙動を変える文書変更は `standard` または `heavy` として通常の Coder / Reviewer / release discipline に委譲する。scope が曖昧な場合は fail-closed で委譲する。
- **Worker Outcome Timing:** `worker outcome` は post-execution の worker report / review request / acceptance gate でのみ使う。詳細は `docs/manual/verification-truth-matrix.md` の `Worker Outcome Contract` を正本とする。
- **Class-Closure Canonicality:** `bug class candidate`、class-closure 関連 field の `n/a` sentinel、non-applicable 表現の正否は `docs/manual/verification-truth-matrix.md` の `Canonical Schema` を正本とする。relevant / unclear な slice を自己申告だけで class-closure 非適用にしてはならない。
- **Fail-Closed Routing:** change surface を分類できない、または safe に slice 化できない場合は reviewer に進めず `BLOCK` とする。
- **Class Closure Sheet First:** 不具合修正、根本原因修正、再発防止、または「同一クラスを閉じた」と主張する変更では、coding 前に `Class Closure Sheet` を plan / SOW / handoff に置くこと。sheet には bug class、owned sink universe、探索方法、各 sink の status を含める。sheet が無い状態で「根本原因を直した」「クラスを閉じた」と表現してはならない。
- **Same-Class Sink Expansion:** 最後に見つかった 1 箇所だけを直して終了してはならない。owned surface 内の同一 class sink を横展開し、late same-class finding が 1 件でも出たら class closure を reset して sink inventory / verification / review request をやり直すこと。
- **Owned Sink Universe Adequacy:** same-class / root-cause fix では coding 前に owned sink universe の妥当性を検証すること。required fields、weak universe definition、late same-class finding の定義と reset semantics は `docs/manual/verification-truth-matrix.md` と `docs/manual/orchestration-closure-playbook.md` を正本とする。
- **Mandatory Re-slice Gate:** mandatory re-slice は escape hatch ではない。許可条件、deprecated enum、identical relabel slice の禁止は `docs/manual/verification-truth-matrix.md` の `Mandatory Re-Slice Gate` を正本とする。条件未達は fail-closed で `BLOCK` とする。
- **Loop Stop / Stall Rule:** `standard` / `heavy` の loop budget ledger の counter semantics、carry-forward、ceiling、budget subfield (`basis / start / last-progress`) と再評価タイミングは `docs/manual/verification-truth-matrix.md` の `Canonical Schema` / `Loop / Stall Rules` / `Fail-Closed Block Conditions` を正本とする。本書では threshold を再定義しない。`standard` / `heavy` での ceiling 超過、budget 未定義、または stale な final-claim / residual-count の持ち越しは fail-closed で `BLOCK` とする。`light` では loop budget ledger を要求しない。
- **Task Lineage Guard:** reopen / relabel lineage の provenance、carry-forward counters、invalid relabel 条件、および authoritative registry の使い方は `docs/manual/verification-truth-matrix.md` の `Task Lineage / Reopen Guard` を正本とする。task lineage registry は `.agent/active/sow/task-lineage-ledger.md` のみであり、ledger entry と一致しない lineage claim は fail-closed で `BLOCK` とする。

### Phase 3: 検証 (Verification)
- **Anti-Cheating:** 実装フェーズにおいて、テストが通らない場合に**テストコードを修正して基準を下げることは原則禁止**とする。テストを変更できるのは「仕様変更」または「テスト自体のバグ」の場合のみであり、その際は理由を明確に記録すること。
- 実装後は必ずテストを行い、要件を満たしているか確認すること。
- エラーが発生した場合は、根本原因を突き止め、対症療法ではない本質的な修正を行うこと。
- **Deterministic Checks First:** deterministic-check surface では、required machine checks を通す前の reasoning-only な accept / LGTM は無効。
- **Verification Evidence:** reviewer に渡す前に、required checks の exact command・result・covered scope・artifact pointer または explicit no-artifact reason を残すこと。required checks / artifact integrity / missing-evidence の fail-closed 条件は `docs/manual/verification-truth-matrix.md` の `Verification Artifact Integrity` と `Fail-Closed Block Conditions` を正本とする。

### Phase 3.5: 監査 (Audit)
- 実装完了後、エージェントは**「意地悪な監査員」**の視点に切り替えて、自身のコードを厳しくレビューすること。甘いチェックは禁止する。
  1.  **脆弱性:** SQLインジェクション、XSS、権限回避、機密情報のハードコードはないか？
  2.  **パフォーマンス:** N+1問題、無駄な再レンダリング、巨大なループ処理はないか？
  3.  **最適解:** それは本当にベストな実装か？ よりシンプルで保守しやすい方法はないか？
- **Adversarial Pre-Closure Pass:** completion / final-close claim の前に、未探索 same-class sink、逆仮説、境界漏れを探す `adversarial pre-closure pass` を必ず実施すること。結果 enum は `PASS | RESET` のみとし、未実施は valid enum ではなく fail-closed `BLOCK` で扱う。ここで同一 class の late finding が出たら closure を reset して Phase 2 に戻る。

### Phase 4: 完了とアーカイブ (Completion & Archiving)
- **Plan:** canonical `completed` が `docs/manual/verification-truth-matrix.md` に従う orchestrator acceptance recheck で成立した後に、archive-action evidence を追跡可能に残しつつ、該当する計画ファイルを `.agent/archive/plans/` ディレクトリへ自律的に移動させること。ユーザー確認は communication event として扱ってよいが、completion / archive authority の代替や競合条件にしてはならない。
- **Tests & Docs:** 機能廃止や仕様変更により**不要になったテストコード**や**古くなったドキュメント**は、削除せずにそれぞれ `.agent/archive/test/`、`.agent/archive/docs/` へ移動させ、リポジトリを常に最新かつクリーンに保つこと。
- **SOW Merge:** Worktreeで作成されたSOWファイルが、ファイル名重複なくメインブランチにマージされるよう確認すること。
- **Completion / Verdict Semantics:** `LGTM` / `completed` / `archived` の使用条件、canonical status enum、reviewer verdict と next-status mapping、`pending final review` の gate、`pending acceptance -> completed` の acceptance recheck、`Needs verification` の round-trip、および fail-closed 条件は `docs/manual/verification-truth-matrix.md` の `Canonical Status / Verdict State Machine` / `Completion / Archive Language Semantics` / `Remaining-Issues Count / Final-LGTM Claims` / `Fail-Closed Block Conditions` を正本とする。本書では詳細条件を再定義しない。
- **No Shortcut Completion:** reviewer `LGTM` の直後の next status は常に `pending acceptance` であり、reviewer が `completed` を返してはならない。`completed` は orchestrator が task class profile acceptance recheck を確認した後にのみ使える。fresh budget recheck は `standard` / `heavy` で必須、`light` では不要。
- **Pending Verification Return Path:** `Needs verification` verdict の next status は `pending verification` のままとするが、これは internal holding state であり reviewer-intake-valid ではない。reviewer への再提出は fresh review request として `pending review` または `pending final review` に正規化し、return-path 条件を満たせなければ `blocked` に倒す。
- **Residual Count Guard:** exact `remaining issues: N` は matrix で定義された metadata (`closed universe basis / basis / timestamp / target scope`) を併記できる場合に限る。条件未達では `remaining issues count unknown` を使うこと。

### Phase 5: 報告 (Reporting)
報告は generic な completion template を使わず、worker outcome と gate 状態を明示した neutral なフォーマットで行うこと。`completed` / `LGTM` は Completion Language Guard の条件を満たした場合にのみ status として使える。

```markdown
# Task Report: [Task Name]

## Outcome
- report owner: `coder|reviewer|orchestrator`
- worker outcome: `DIFF|BLOCK|NO-CHANGE`
- status: `in progress|pending review|pending verification|pending final review|pending acceptance|blocked|completed`
- `pending verification` は internal holding state であり reviewer request status としては使わない
- reviewer request に流せるのは `status=pending review|pending final review` かつ `worker outcome=DIFF|NO-CHANGE` の report のみ
- `status=blocked`、`status=pending verification` の reviewer 再提出、または `worker outcome=BLOCK` は reviewer request ではなく separate な block report path
- `completed` は `report owner=orchestrator` かつ下記 `Acceptance Recheck` を完全に記録した場合にのみ有効
- completion language allowed: `YES|NO`
- latest review verdict: `LGTM|BLOCK|Request Changes|Needs verification|Needs Discussion|not-yet-issued`
- `latest review verdict=not-yet-issued` は reviewer 返答前にのみ有効であり、reviewer-produced report、`status=pending acceptance`、`status=completed` では無効

## Slice Contract
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
- owned sink universe: `n/a|...`
- sheet status: `OPEN|CLOSED|RESET|n/a`
- closed universe status: `YES|NO|n/a`
- closed universe basis: `n/a|...`
- scope delta since last review: `none|...`
- fix-review loops used: `0/2`
- closure resets used: `0/2`
- reviewer-found same-class finding count: `0/1|1/1|2/1 (BLOCK)`
- re-slice count for task: `0/2`
- cumulative reviewer requests for task: `0/6`
- cumulative late same-class findings for task: `0/2`
- cumulative closure resets for task: `0/2`
- counter examples above show common shapes only; if a ceiling is exceeded, record the actual overflow value as-is (for example `3/2`, `7/6`) and defer terminal-state semantics to the matrix
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-18T09:00:00Z; last-progress=2026-04-18T09:00:00Z`
- task-level stall-or-wall-time budget status: `within-budget|exhausted`

## Re-Slice Provenance
- re-slice delta type: `none (only when prior slice id=none)|narrowed change surface|redefined owned sink universe|user decision|blocker resolution`
- re-slice delta summary: `none (only when prior slice id=none)|...`
- delta evidence: `none (only when prior slice id=none)|...`

## Verification
- command: `...`
- result: `PASS|FAIL`
- covered scope: `...`
- artifact pointer: `path/to/artifact | n/a`
- no-artifact reason: `n/a|...`
- artifact integrity: `complete|MISSING`

## Worker Outcome Payload
- contract source: `docs/manual/verification-truth-matrix.md :: Worker Outcome Contract`
- shared canonical fields are carried by `Slice Contract` / `Re-Slice Provenance` / `Verification`
- `worker outcome=BLOCK` の report でも `Slice Contract` / `Re-Slice Provenance` にある lineage / prior task-slice / loop counter / budget status を省略してはならない
- fill only the subsection matching `worker outcome`

### DIFF Payload
- changed files: `...`
- evidence pointer: `path|log`
- next action: `...`

### BLOCK Payload
- fail-closed reason: `...`
- missing prerequisite: `...`
- attempted checks / execution constraint: `...`
- next required input: `...`
- reroute owner: `user|orchestrator|coder|reviewer`
- reopen condition summary: `...`
- unblock evidence required: `...`
- unblock evidence: `path|log|none-yet`
- reroute evidence: `path|log|n/a`
- evidence pointer: `path|log`

### NO-CHANGE Payload
- searched surface: `...`
- no-diff reason: `...`
- search / verification evidence: `...`
- last-reviewed baseline: `...`
- closed-universe claim: `YES|NO|n/a`

## Acceptance Recheck (`pending acceptance -> completed` を試行した場合のみ記録)
- transition attempted: `YES`
- final reviewer request gate previously satisfied: `YES|NO`
- pending acceptance source review verdict: `LGTM`
- truth read order rechecked: `YES|NO`
- deterministic evidence rechecked: `YES|NO`
- completion boundary rechecked: `YES|NO`
- worker outcome validity rechecked: `YES|NO`
- artifact integrity rechecked: `complete|MISSING`
- acceptance recheck evidence: `path|log`
- fresh budget recheck status: `within-budget|exhausted`
- fresh budget recheck evidence: `path|log`

## Residual Count Record (exact count only)
- remaining issues: `N`
- closed universe basis: ...
- basis: ...
- timestamp: ...
- target scope: ...

## Next Action
1. ...
2. ...
```

## 3. UI/UXガイドライン (Shadcn & Template First)

**適用範囲:** 本ガイドラインは、要件定義において `shadcn/ui` の使用が指定されたWebフロントエンド開発において**絶対遵守**すること。

**優先順位:** shadcn/ui使用時は本ガイドラインが最優先。`.claude/skills/design-principles/SKILL.md` は本ガイドラインと矛盾しない一般原則（グリッド/タイポ等）の補助参照に限定する。shadcn/ui未使用時はSKILL.mdを適用すること。

**詳細デザイン原則:** `.claude/skills/design-principles/SKILL.md` を参照すること。4pxグリッド、タイポグラフィ階層、深度戦略、アンチパターン等の詳細な設計指針を提供。

- **例外ケース:**
  - **Mobile Apps (Flutter/Swift/Kotlin):** 各プラットフォームの標準デザイン（Material Design / Human Interface Guidelines）に従うこと。
  - **OSS Customization:** 既存のOSSプロジェクトを改修する場合は、そのプロジェクトの既存デザインシステム・ルールを最優先すること。

### 必須フレームワーク
- **Next.js (最新安定版):** Webフロントエンドは Next.js を使用すること。App Router を標準とし、Server Components を活用。
  - `npx create-next-app@latest --typescript --tailwind --eslint --app`
  - **Turbopack:** Next.js 16+では既定バンドラー。必要な場合のみ `--turbo` を明示
  - React 19+ / TypeScript 5+ を前提

### 状態管理・データフェッチング
- **サーバー状態:** Server Components/Route Handlersで取得（Client Componentsで必要な場合のみTanStack Queryを使用）
- **クライアント状態:** Zustand を推奨（軽量、TypeScript親和性）
- **フォーム:** React Hook Form + Zod（バリデーション）

### Server/Client Components の使い分け
- デフォルトはServer Components
- Client Componentsは以下の場合のみ使用:
  - useState, useEffect等のフック使用時
  - onClick等のイベントハンドラ使用時
  - ブラウザAPI（localStorage, window等）使用時
- 「クライアントの島」パターン：大部分をServer Componentに保ち、インタラクティブな部分のみをClient Componentとして分離

### Shadcn/ui 使用時の鉄の掟
対象プロジェクトにおいては、以下のルールを厳守し、「良かれと思ったカスタム」は禁止する。

- **Template First (テンプレート優先):**
  - **推奨テンプレート:**
    1. [next-shadcn-dashboard-starter](https://github.com/Kiranism/next-shadcn-dashboard-starter) - Next.js 16対応、RBAC、マルチテナント（5,800+ stars）
    2. [Vercel Admin Dashboard](https://vercel.com/templates/next.js/next-js-and-shadcn-ui-admin-dashboard) - 軽量スターター
  - ランディングページが必要な場合は [shadcn/ui公式blocks](https://ui.shadcn.com/blocks) を併用
  - **原則:** ゼロからコンポーネントを組むのではなく、上記テンプレートを採用し、そのコンポーネントやブロックを最大限活用する。
  - **Assembly over Creation:** 画面構築は「新規作成」ではなく、既存ブロックの「組み合わせ」で行うこと。
- **Shadcn/ui 至上主義:**
  - テンプレートにない要素が必要な場合のみ `shadcn/ui` の標準コンポーネントを使用する。
  - **独自のCSSやStyleでのカスタムは原則禁止。**
  - エージェントの役割は「デザイン」ではなく、既存ブロックの「配置 (Layout)」と「構成 (Composition)」のみである。
- **配色とフォント:**
  - **Primary Color:** `#007FFF` (Azure Blue)
  - **Font:** System Font (OS標準)
- **アイコン:**
  - **Phosphor Icons** (`@phosphor-icons/react`) を使用すること。軽量でモダン、Linear/Raycast風のミニマルUIに最適。
- **ローカライゼーション (Japanese First):**
  - **日本人向けの自然な日本語**を使用すること。直訳調や不要なカタカナ語は避ける。
    - ❌ Subscription → ⭕ 購読 / 課金ユーザー数
    - ❌ Address1 / City → ⭕ 住所 / 市区町村
    - ❌ +20% from last month → ⭕ +20%/先月比
  - **例外:** 一般的なマーケティング用語（CPA, CVR, ROAS等）は英語表記可。
  - **フォーム順序:** 日本の慣習に従うこと（郵便番号 → 都道府県 → 市区町村 → 番地 → 建物名）。
- **思考プロセス:**
  - ❌ 「ここの余白を調整して、色を薄くして…」
  - ⭕ 「Cardコンポーネントの中にButtonを置く。以上。」

### アクセシビリティ (Accessibility)
**WCAG 2.2 AA準拠**を目標とする。

- **セマンティックHTML:** 適切な要素を使用（`<button>`, `<nav>`, `<main>`, `<article>`等）
- **キーボード操作:** 全てのインタラクティブ要素はキーボードでアクセス可能に
- **フォーカス表示:** フォーカス状態を視覚的に明示（`focus-visible`を活用）
- **ARIAラベル:** アイコンのみのボタンには `aria-label` を必須
- **カラーコントラスト:**
  - 通常テキスト: 4.5:1 以上
  - 大きいテキスト（18px+）: 3:1 以上
- **スクリーンリーダー対応:** 重要な状態変化は `aria-live` で通知
- **検証ツール:** axe DevTools, Lighthouse Accessibility を CI に組み込み

#### WCAG 2.2 追加要件
- **フォーカスが隠れない (Focus Not Obscured: Minimum):** フォーカス要素が固定ヘッダー等で完全に隠れないこと
- **ドラッグ操作代替:** ドラッグ必須の操作にはクリック/タップ代替を提供
- **タッチターゲット:** 最小24x24px、推奨44x44px
- **一貫したヘルプ:** ヘルプ・サポート機能は全ページで同一位置に配置
- **冗長入力の回避 (Redundant Entry):** 同一プロセス内の再入力は自動補完/選択提供
- **認証の認知負荷軽減:** パスワード入力にコピペ許可、パスワードマネージャー対応

#### フォーカス管理
- **モーダル/ダイアログ:** フォーカストラップ必須、ESCで閉じる、閉じた後は起点に戻す
- **ページ遷移:** 新ページのメインコンテンツ先頭にフォーカス移動
- **動的コンテンツ追加:** 適切なフォーカス移動またはaria-live通知

#### アニメーション制御
- `prefers-reduced-motion: reduce` を尊重し、不要なアニメーションを無効化
- 自動再生コンテンツには停止ボタンを提供
- 点滅は3回/秒を超えない（光過敏性発作リスク回避）

### React/Next.js アクセシビリティ
- **クライアントサイドルーティング:** ページ遷移時に `<main>` にフォーカス移動、ルート変更をスクリーンリーダーに通知
- **Server Components:** ARIA属性はサーバー側の静的HTMLに付与可能。動的な状態変化や `aria-live` 更新はClient Componentsで扱う
- **Suspense/Streaming:** ローディング状態を `aria-busy="true"` で通知、Skeleton UIには適切な `aria-label`

### レスポンシブデザイン (Responsive Design)
**Mobile First**アプローチを採用。

- **ブレークポイント（Tailwind準拠）:**
  | 名前 | サイズ | 用途 |
  |-----|-------|------|
  | `sm` | 640px+ | 大きめスマホ、小タブレット |
  | `md` | 768px+ | タブレット |
  | `lg` | 1024px+ | 小型デスクトップ |
  | `xl` | 1280px+ | デスクトップ |
  | `2xl` | 1536px+ | 大型デスクトップ |

- **実装原則:**
  - ベーススタイルはモバイル向けに記述
  - `min-width` でブレークポイントを追加（Tailwindデフォルト）
  - タッチターゲットは最低 44x44px を確保
  - 横スクロールは原則禁止（テーブル等の例外は明示）

### パフォーマンス基準 (Performance Standards)
**Core Web Vitals**を指標とする。

- **目標値:**
  | 指標 | 目標 | 計測ツール |
  |-----|------|----------|
  | LCP (Largest Contentful Paint) | ≤ 2.5s | Lighthouse |
  | INP (Interaction to Next Paint) | ≤ 200ms | Lighthouse |
  | CLS (Cumulative Layout Shift) | ≤ 0.1 | Lighthouse |

- **実装要件:**
  - **画像最適化:** `next/image` を使用、WebP/AVIF形式を優先
  - **フォント最適化:** `next/font` で自動最適化、`font-display: swap`
  - **コード分割:** 動的インポート（`next/dynamic`）を活用
  - **バンドルサイズ:** 初期JSは 200KB 以下を目標
  - **SSR/SSG活用:** 静的生成可能なページは `generateStaticParams` を使用

- **計測:**
  - 本番デプロイ前に Lighthouse スコア 90+ を確認
  - Vercel Analytics または Web Vitals API でリアルユーザー計測

### ダークモード (Dark Mode)
**システム設定連動**を基本とし、ユーザー切替も提供。

- **実装方法:**
  - `next-themes` ライブラリを使用
  - `class` ストラテジー（Tailwind `darkMode: 'class'`）
  - `<html>` 要素に `dark` クラスをトグル

- **カラー設計:**
  - CSS変数でライト/ダーク両方のトークンを定義
  - ダークモードでは影よりボーダーを優先
  - 彩度を10-20%下げてハーシュさを軽減

- **切替UI:**
  - ヘッダー右上にアイコンボタンを配置
  - 3状態（Light / Dark / System）を提供

- **注意点:**
  - 純粋な `#000` 背景は避ける（`#0a0a0a` 〜 `#171717` 推奨）
  - 純粋な `#fff` テキストは避ける（`#fafafa` 〜 `#e5e5e5` 推奨）
  - 画像・イラストはダークモード用の代替を検討

## 4. ドキュメンテーション (Documentation & SOW)
- **SOW (Statement of Work):**
  - 作業の節目やセッション終了時に、実施した内容・結果・残課題を記録したSOWファイルを作成すること。
  - **保存場所:** `.agent/active/sow/`
  - **命名規則:** 並列開発時のマージ競合を防ぐため、必ず `YYYYMMDD_[TaskName].md` （例: `20251206_feat-login.md`）という形式で保存すること。
  - 原則として「1セッションにつき1ファイル」を作成し、後から追跡可能な状態にすること。
  - slice ごとに task class profile に対応する contract を残すこと。`light` は `light-change-record`、`standard` は `standard-slice-contract`、`heavy` は `docs/manual/verification-truth-matrix.md` の完全 `Canonical Schema` と該当時の re-slice provenance を追跡可能な形で残すこと。
  - **運用:** `./scripts/hydra close` は `.agent/active/sow/` の存在を検知して停止します。不要な場合は `--force` を使うこと。
  - **完了後:** タスク完了時に `.agent/archive/sow/` へ移動させること。

## 5. ハンドオーバー (Handover)
- コンテキストウィンドウが圧迫された場合、またはタスクが長期間に及ぶ場合は、次のエージェントへの引き継ぎ（ハンドオーバー）を行うこと。
- **前提:** 次のエージェントは、これまでの経緯や暗黙知を一切持たない**「完全に無知な他人」**であると想定すること。
- **引き継ぎ手順:**
  1. 詳細な現状報告（ディレクトリ構造、成功/失敗した試み、判明した事実、ハマりポイントなど）を含むプロンプト（`.agent/active/prompts/`）を作成する。「言わなくてもわかるだろう」は禁止。
  2. 引き継ぎが完了したら、そのプロンプトファイルを `.agent/archive/prompts/` へ移動させること。
- **運用:** `./scripts/hydra close` は `.agent/active/prompts/` の存在を検知して停止します。不要な場合は `--force` を使うこと。

## 6. ストール時の第三者レビュー (Stall-Break Review)
- 進捗が完全に行き詰まった場合は、第三者エージェントによるレビューで突破を試みること。
- `.agent/active/prompts/` 配下に**超詳細なレビュー依頼プロンプト**を作成する。目的・背景・再現手順・関連ファイル/パス・試行済みアプローチ・期待するアウトプットなどを網羅し、受け手が前提知識ゼロでも理解できるようにする。
- 作成したプロンプトを第三者エージェントに渡し、第三者は `.agent/active/prompts/` にフィードバックを返すこと（ファイル名で区別）。
- 問題を解決・突破できたら、依頼元エージェントはプロンプトを `.agent/archive/prompts/` へ、フィードバックを `.agent/archive/feedback/` へ自律的に移動させ、他の一時ファイル同様に整理すること。

## 7. 推奨ツールスタック (Recommended Tool Stack)
エージェントは、特別な理由がない限り以下の最新ツールチェーンを使用すること。

- **Python:**
  - **`uv`** (by Astral) を使用すること。
  - `pip` および `venv` の直接使用は、レガシー環境でない限り**原則禁止**とする。
  - コマンド例: `uv init`, `uv add [pkg]`, `uv run pytest`
- **Node.js:**
  - `npm` または `pnpm` を使用すること（プロジェクト内で統一）。
  - CI/CD速度向上のため、可能な限り `pnpm` を推奨する。

## 8. タグ作成時の例外 (Tagging Exception)
- ユーザーから「新規タグのバージョンを指定してコミット・プッシュして」と明示的な依頼があった場合に限り、`main` への直接コミットおよびプッシュを許可する（Phase 1.8のWorktree制約の例外として扱う）。

## 9. フォルダ構成ガイド

### .agent/ の構造（エージェント駆動開発の中核）

```
.agent/
├── requirements.md          # 要件定義書（ユーザー投下）
├── PROJECT_CONTEXT.md       # プロジェクト固有コンテキスト
│
├── active/                  # 現在進行中のタスク
│   ├── plan_YYYYMMDD_HHMM_<task>.md   # ExecPlan（実装中）
│   ├── sow/                 # セッション別SOW
│   └── prompts/             # ハンドオーバー/レビュー用
│
└── archive/                 # 完了した作業
    ├── plans/               # 完了したプラン
    ├── sow/                 # 完了したSOW
    ├── prompts/             # 完了したハンドオーバー
    ├── feedback/            # 過去のレビューフィードバック
    ├── test/                # アーカイブされたテスト
    └── docs/                # アーカイブされたドキュメント
```

### フォルダ責務定義

| フォルダ | 責務 | 作成者 | 生存期間 |
|---------|-----|------|--------|
| `requirements.md` | ユーザーの要件定義 | ユーザー | プロジェクト全期間 |
| `PROJECT_CONTEXT.md` | プロジェクト固有ルール | 初期エージェント | プロジェクト全期間 |
| `active/plan_YYYYMMDD_HHMM_<task>.md` | 現在進行中のExecPlan | エージェント | タスク完了まで |
| `active/sow/` | 実施結果記録 | エージェント | タスク完了まで |
| `active/prompts/` | ハンドオーバー/レビュー依頼 | エージェント | 引継ぎ/レビュー完了まで |
| `archive/*` | 完了した作業の履歴 | 自動移動 | 永続保持 |

### ワークフロー

1. **要件投下**: ユーザーが `.agent/requirements.md` に要件を記載
2. **プラン生成**: エージェントが `.agent/active/plan_YYYYMMDD_HHMM_<task>.md` を生成
3. **実装・レビュー**: workflow owner skill を選び、必要時 `auto_orchestrate.sh` で自動反復
4. **完了**: タスク完了後、`.agent/archive/` に自動移動

### docs/ の構造

```
docs/
├── requirements/      # 要件定義書、ユーザーストーリー
├── design/            # アーキテクチャ設計、DBスキーマ、API仕様
├── manual/            # 運用マニュアル、セットアップガイド
├── roles/             # 役割定義（Coder/Reviewer/Orchestrator）
├── prompts/           # レビュワープロンプトテンプレート
├── release-notes/     # リリースノート
├── incidents/         # インシデント記録
└── entitlements/      # 署名・公証用設定
```

### scripts/ の利用

| スクリプト | 用途 |
|-----------|------|
| `init-project.sh` | プロジェクト初期化 |
| `hydra` | Git Worktree 管理 |
| `codex-wrapper.sh` | Codex CLI 呼び出しの caller-facing / manual / external canonical runtime entrypoint |
| `codex-wrapper-medium.sh` | 互換 shim（`--role standard`） |
| `codex-wrapper-high.sh` | 互換 shim（`--role high-coder`、historical name） |
| `codex-wrapper-xhigh.sh` | 互換 shim（`--role reviewer`） |
| `quality_gate.sh` | 品質ゲート実行 |

### Phase 2 責務マトリクス

| サーフェス | 責務 | 補足 |
|-----------|------|------|
| `.codex/config.toml` | 共有ベースラインと native agent 登録 | safe default。caller-facing role 契約は持たない |
| `.codex/agents/*.toml` | native subagent preset | Codex 内部プリセット。native multi-agent / subagent orchestration はここで解決し、wrapper を通さない |
| `scripts/codex-wrapper.sh --role ...` | caller-facing / manual / external runtime truth | Phase 2 の外部 Codex 呼び出し入口 |
| `.claude/skills/*.md` | 再利用可能 workflow の owner | planner / review / research / router を分担 |
| MCP | capability transport | workflow owner ではない |
| semantic MCP | Claude / Codex 両 CLI の repo-local parity は設定済み | Claude は `.claude/settings.json`、Codex は `.codex/config.toml` から `./scripts/launch-semantic-mcp.sh` を自動起動 |

## 10. プロジェクト固有情報
- 本ルールは汎用的なものです。プロジェクト固有の技術スタック、要件、仕様については、プロジェクトルートの `README.md` や `.agent/` 内の要件定義書を最優先で参照すること。

## 11. Codex CLI 呼び出しルール（CRITICAL / MUST FOLLOW）

外部 caller（Claude Code、手動実行、外部スクリプト等）が Codex CLI を起動する際、以下を**厳守**すること。

### 禁止事項
1. **モデル指定の禁止:** `-c model=...` オプションは**絶対に付与しない**
2. **reasoning effort 指定の禁止:** `-c model_reasoning_effort=...` も**付与しない**
3. **手動上書きの禁止:** 直接 `codex` を呼ぶ側が `.codex/config.toml` やモデル/effort をコマンドラインで上書きしない（必要な固定値は wrapper が適用）
4. **native orchestration の wrapper 経由禁止:** native Codex multi-agent / subagent orchestration を `scripts/codex-wrapper.sh` 経由の再帰起動に逃がさない

### 必須事項
- **ラッパー経由での呼び出し:** `codex` を直接呼ばず、必ず専用ラッパー経由で呼び出すこと
  - **Canonical:** `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`
  - caller-facing な role は `--role` で明示する。`CODEX_WRAPPER_ROLE` / `AGENT_ROLE` は `--role` 省略時の互換フォールバックであり、caller-facing 契約としては使わない
  - Reviewer は `--role reviewer` に固定し、legacy shim は互換入口として同じ固定 role に委譲する
  - **Role map:**
    - `standard` → `model_reasoning_effort=medium`, `web_search=cached`
    - `research` → `model_reasoning_effort=high`, `web_search=live`
    - `coder` → `model_reasoning_effort=medium`, `web_search=cached`
    - `high-coder` → `model_reasoning_effort=high`, `web_search=cached`
    - `reviewer` → `model_reasoning_effort=xhigh`, `web_search=cached`
    - role 未指定時は `standard`
  - **互換 shim:** `medium.sh -> standard`, `high.sh -> high-coder`（historical name）, `xhigh.sh -> reviewer`
- **境界の明示:** 上記 wrapper 契約は caller-facing / manual / external な Codex 起動にのみ適用する。native Codex multi-agent / subagent orchestration は `.codex/agents/*.toml` などの Codex 内部 surface で完結させ、wrapper を再帰呼び出ししない
- ラッパーが `gpt-5.5` と role allowlist を強制適用し、`workspace-write` / `approval_policy=never` も固定する
- **入力ガード:** canonical wrapper が存在しない、role 解決に失敗した、または shim 固定 role に対する role escape が検出された場合は fail-closed で停止する。`--cd` / `--add-dir` は警告して strip し、`codex exec` への直接フォールバックは禁止

### 正しい呼び出し例
```bash
# Coder（実装）用
cat prompt.md | ./scripts/codex-wrapper.sh --role coder --stdin > output.md

# Reviewer（レビュー）用
cat prompt.md | ./scripts/codex-wrapper.sh --role reviewer --stdin > output.md
```

**注意:** 以下の直接実行は概念図であり、実運用では必ずラッパー経由で呼び出すこと。
```bash
# 概念図（実運用ではラッパー必須）
cat prompt.md | codex exec --stdin > output.md
```

### 禁止される呼び出し例
```bash
# NG: モデルを上書きしている
cat prompt.md | codex exec -c model=example_forbidden_model --stdin > output.md

# NG: reasoning effort を上書きしている
cat prompt.md | codex exec -c model_reasoning_effort=high --stdin > output.md

# NG: caller から作業ディレクトリを差し込んでいる
cat prompt.md | ./scripts/codex-wrapper.sh --role coder --cd /tmp --stdin > output.md
```

### 背景
LLM は「最新モデル」を独自に推論し、誤ったモデル名を指定する可能性がある。
`.codex/config.toml` の設定が上書きされることを防ぐため、本ルールを厳守すること。

---

## 12. コード署名・公証フローの実行ルール（Kinder/Tauri）
- ローカル開発のビルド確認は必ず `scripts/build-dev.sh --platform macos` を使用し、署名／公証プロンプトを出さないこと。
- リリース配布用の署名・公証は `scripts/sign-and-build.sh --platform macos` を使用する。公証を行う場合は `--skip-notarize` を外し、APIキー方式(APPLE_NOTARY_*)またはApple ID方式(APPLE_ID/APPLE_TEAM_ID/APPLE_APP_SPECIFIC_PASSWORD)のどちらかの資格情報を設定する。
- CI 自動実行条件は `.github/workflows/build-and-sign.yml` に従う（push main / tags v* / release published / workflow_dispatch）。iOSジョブは `ENABLE_IOS_SIGNING` が true のときのみ有効。
- 詳細手順・ハッシュ記録・運用メモは `docs/code-signing-implementation-plan.md` を参照し、更新があれば同ファイルに追記すること。

---

## 13. 役割定義（Role Definitions）

### 設計原則: 役割とエージェントの対応
- **役割（Role）**: Coder / Reviewer / Orchestrator - タスクの種類に応じた責務
- **エージェント（Agent）**: Claude / Codex / その他 - 実行主体

| 役割 | エージェント | 推論努力 | 備考 |
|-----|------------|---------|------|
| **Coder** | Claude/Codex両方可 | 実行経路で解決 | Codex は `coder` が既定、delegated `light` 時のみ `standard`、外部調査時のみ `research` |
| **Reviewer** | **Codex 固定** | `reviewer` (`xhigh` + `cached`) | canonical wrapper 経由で固定 |
| **Orchestrator** | **dual-native** | 既定 `medium`、caller-facing effort は `low|medium|high|xhigh` のみ | Claude top-level は Claude-native、Codex top-level は Codex-native。`max` は使わない |

> 注記: Codex の caller-facing role は `standard|research|coder|high-coder|reviewer` のみ。呼び出し側は `--role` を使い、`CODEX_WRAPPER_ROLE` / `AGENT_ROLE` は互換フォールバックとしてのみ扱う。legacy shim は移行期間の互換入口であり、role を差し替える escape hatch ではない。caller-facing / manual / external な source of truth は常に canonical wrapper であり、native Codex multi-agent / subagent orchestration はその内側で完結する。Claude-native same-family delegation も Claude Code 内部で完結し、`scripts/claude-wrapper.sh` を再帰起動しない。Cross-family Claude / Codex coordination は artifact packet と lease closeout を使い、live chat を completion evidence にしない。

### Role: Coder（実装担当）
| 項目 | 内容 |
|-----|------|
| **責務** | 要件理解 → ExecPlan → Blueprint → TDD → 実装 → 自己監査 → SOW |
| **成果物** | ExecPlan, コード, テスト, SOW, 変更サマリ |
| **遵守フェーズ** | Phase 1.5 (Design & Test), Phase 1.8 (Worktree), Phase 3.5 (Audit) |
| **引き継ぎ** | `.agent/active/prompts/` へ背景/変更点/未解決/再現手順/重要ファイルを記録 |
| **詳細** | → `docs/roles/coder.md` |

### Role: Reviewer（レビュー担当）【Codex固定】
| 項目 | 内容 |
|-----|------|
| **責務** | 仕様適合・安全性・性能・一貫性・テスト妥当性の評価 |
| **観点** | Security / Performance / Consistency / Test Coverage / DX |
| **出力形式** | 省略形で再定義しない。正本は `docs/roles/reviewer.md#出力フォーマット（必須）` の full review report template であり、`[High]` `[Medium]` `[Low]` はその Findings セクション内でのみ使う |
| **禁止** | 推測LGTM禁止、なんとなくLGTM禁止、deterministic-check surface への reasoning-only LGTM 禁止 |
| **固定** | **Codex CLI `--role reviewer`** (`xhigh` + `cached`)。legacy shim も reviewer に固定であり、caller から別 role へ差し替えない |
| **詳細** | → `docs/roles/reviewer.md` |

### Role: Orchestrator（統括担当）【dual-native】
| 項目 | 内容 |
|-----|------|
| **責務** | タスク分割、エージェント割当、進捗管理、役割切替、終端判断 |
| **選定ロジック** | タスクの性質・制約・利用可能ツール・得意分野で決定 |
| **成果物** | 役割割当表, 依頼プロンプト, 進捗ログ |
| **衝突回避** | 同一ファイルを複数エージェントが同時編集しない |
| **固定** | **top-level runtime native**（Claude top-level は Claude-native subagents、Codex top-level は Codex-native subagents。既定 effort は `medium`、caller-facing effort は `low|medium|high|xhigh` のみ。`max` は使わない） |
| **詳細** | → `docs/roles/orchestrator.md` |

### 役割トリガー
| ユーザー指示 | 割り当てる役割 |
|------------|--------------|
| 「実装して」「作って」「修正して」 | Coder |
| 「レビューして」「確認して」「チェックして」 | Reviewer |
| 「計画して」「分担して」「管理して」 | Orchestrator |
| 「調査して」「探して」 | Orchestrator → 必要に応じてCoder |
| 「設計して」「方針を決めて」 | Orchestrator |
| 「相談したい」「どう思う？」 | Orchestrator |

#### Reviewer LGTM Validity
- Reviewer LGTM の成立条件、valid な `worker outcome` の条件、completion language の使用条件は、`docs/manual/verification-truth-matrix.md` の `Reviewer LGTM Validity` / `Worker Outcome Contract` / `Completion / Archive Language Semantics` を canonical gate とする。本書はその要約や再定義を行わない。いずれか未充足なら fail-closed で `BLOCK` とする。

### 役割間の引き継ぎフロー
```
[Orchestrator] タスク分析・役割割当
       ↓
[Coder] 実装 → 成果物
       ↓
[Reviewer] レビュー → フィードバック
       ↓
   ├── valid reviewer `LGTM` → [pending acceptance]
   ├── orchestrator acceptance recheck complete → [completed]
   ├── Request Changes → [Coder] 修正 → fresh review request(`pending review|pending final review`) → [Reviewer] 再レビュー
   ├── Needs verification → [Coder] 追加検証 (`pending verification` internal) → normalized review request(`pending review|pending final review`) → [Reviewer] 再レビュー
   └── BLOCK / invalid final-review gate / budget exhausted → [blocked]
```

`BLOCK` は fail-closed stop であり、同じ handoff / report を `pending review` / `pending final review` に読み替えたり、`pending verification` のまま reviewer intake に戻したりして通常の coder-fix-review loop へ戻してはならない。

※ Shadow Verify ゲートが有効な運用では、実行順は **Coder -> Shadow Verify -> Reviewer** に変更され、Shadow Verify 未通過のまま Reviewer へ進めない。Shadow Verify の再試行は同じ task lineage の `evidence destination` と `task-level stall-or-wall-time budget` に束ね、別系統の churn loop を作ってはならない。

### Codex セッション管理ルール（外部 caller / オーケストレーター経由）

| Codex 呼び出し経路 | 動作モード | オーケストレーター経由 |
|------------------|----------|---------------------|
| `./scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` | 非インタラクティブ | ✅ 使用可能 |
| `codex resume` | インタラクティブのみ | ❌ 不可 |
| `codex exec` | wrapper 内部実装詳細 | ❌ caller-facing 経路としては不可 |

**運用ルール:**
1. **外部 caller / オーケストレーターから Codex セッションを新規起動する場合は、`./scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使い、前回のコンテキストをプロンプトに含める**
2. **`codex resume` は手動実行（ターミナルから直接）でのみ使用可能**
3. **`codex exec` は wrapper の内部実装詳細としてのみ扱い、caller-facing / manual / external な経路として提示しない**
4. **イテレーション間のコンテキスト維持は、プロンプトファイルに前回のレビュー結果を含めることで実現**

**技術的背景:** `codex resume` は完全なインタラクティブターミナル（カーソル位置読み取り機能）を必要とし、`setsid`/擬似TTY環境では動作しない。

### 役割衝突時の対応ルール

ユーザー指示が複数ロールにまたがる場合や、現在の役割と矛盾する場合の対応規定。

#### 衝突パターンと対応

| 衝突パターン | 対応 |
|------------|------|
| Orchestrator 指定 + 実装要求 | 役割変更の確認 → 承認後に Coder へ切替、または Coder に委譲 |
| Reviewer 指定 + 実装要求 | Reviewer は実装不可。Orchestrator へ委譲／新規 Coder セッション開始を提案（役割変更は Orchestrator 経由のみ） |
| Coder 指定 + レビュー要求 | 標準フロー（Coder → Reviewer、Shadow Verifyゲート有効時は Coder → Shadow Verify → Reviewer）に分割、または Orchestrator 経由で Reviewer に委譲 |
| 複数役割の同時要求（「レビューして直して」等） | 優先順位の確認 → 役割分割（Orchestrator → Coder → Reviewer、Shadow Verifyゲート有効時は Orchestrator → Coder → Shadow Verify → Reviewer） or 委譲 |
| 曖昧な指示（「ちょっと直して」等） | 確認質問を挟み、役割を明確化してから実行 |

#### 役割変更の原則

1. **明示宣言必須**: 役割変更時は必ず宣言してから切替える
2. **最終ロール優先**: 明示宣言がない限り、最後に確定したロールを維持（「確定」= ユーザー承認 + 役割変更宣言済み。承認前は現ロール維持）
3. **Orchestrator は dual-native**: Claude top-level runtime では Claude-native subagents、Codex top-level runtime では Codex-native subagents を使う。同一 family delegation は wrapper 再帰起動に逃がさず、cross-family は artifact packet と lease closeout でつなぐ

#### 役割変更宣言テンプレート

```
役割を [現在の役割] → [新しい役割] に変更します。
以降、[新しい役割の責務] を行います。
```

#### 禁止される役割変更

- **暗黙の切替禁止**: 宣言なしでの役割変更は禁止
- **Reviewer からの直接実装禁止**: Reviewer は実装に切替不可（一度 Orchestrator に戻す）

### Acceptance Gate / Truth Placement

- acceptance と truth placement の正本は `docs/manual/verification-truth-matrix.md` とする。slice 固有の保存先は `evidence destination` と呼び、truth placement そのものと混同しない
- 各 slice contract / handoff / worker report は task class profile に対応する schema を採用する。完全 `Canonical Schema` と該当時の re-slice provenance は `heavy` で必須、`standard` では defect / root-cause / same-class fix の場合だけ必要項目を昇格する
- stable doc に latest artifact や dated closeout status を直書きしてはならない
- completion language、status transition、remaining-issues count、worker outcome validity、fail-closed 条件の正本は matrix の対応 section を使い、この節で詳細条件を再定義しない
- user acknowledgement / approval は communication event に留め、completion / archive authority の代替や競合条件にしてはならない
- reviewer は discovery surface ではなく validation gate として使う。same-class sink discovery を reviewer に外注した状態で final reviewer LGTM を要求してはならない
- delegated worker / subagent / slice loop の返答は `DIFF` / `BLOCK` / `NO-CHANGE` の 3 種に固定し、required payload は `docs/manual/verification-truth-matrix.md` の `Worker Outcome Contract` を正本とする
- `DIFF` / `BLOCK` / `NO-CHANGE` 以外の曖昧な「対応済み」「問題なし」「完了」は worker outcome として無効

---

## 14. コード配置ルール（Project Structure）

### テンプレート運用
Revharness（machine name: `rev_harness`）を新規システム開発の基盤テンプレートとして使用する。新規プロジェクトは Revharness を起点にし、実プロダクトコードは既定で `src/` に配置する。`agent_base` / `agent-base` は旧名称・既存導入・移行検出のための legacy alias / historical compatibility としてのみ扱う。

### 推奨ディレクトリ構造

| ディレクトリ | 用途 | 備考 |
|-------------|------|------|
| `src/` | **アプリケーションコード** | 推奨配置場所 |
| `test/` | テストコード | src/と対応する構造 |
| `workspace/` | Hydra worktree作業用 | **恒久的コード配置禁止**（.gitignore済み）※Hydra worktree内の作業コードは可 |

### 禁止事項
1. **workspace/ への恒久的コード配置禁止**: `workspace/` 直下に恒久的なコードを置かない（コミット禁止）。Hydra worktree内の作業コードは可
2. **Revharness基盤ファイルの改変禁止**: `.agent_rules/`, `scripts/`, `.claude/`, `.codex/` は原則変更しない。legacy alias としての `agent_base` / `agent-base` 由来の既存基盤ファイルも同じ保護対象とする

### 詳細
→ `.agent/PROJECT_CONTEXT.md` を参照

---

## 15. Safe Merge Protocol（Merge Queue + Hydra）

複数のGit Worktreeで並行開発を行う際、`main`/`develop`ブランチへの安全なマージを保証するためのプロトコル。

### 基本原則

1. **Merge Queue経由必須**: `main`/`develop`へのマージはMerge Queue経由のみ。直接プッシュは**禁止**
2. **Branch Protection必須**: 「Require merge queue」を有効化すること
3. **Preflight必須**: `hydra preflight <task>` の成功が `hydra close` の前提条件
4. **同一ファイル競合はBLOCK**: 複数worktreeで同一ファイルを編集している場合、自動マージ不可（手動解決必須）

### マージ前チェックリスト

```markdown
## Pre-Merge Checklist（必須）
- [ ] `hydra preflight <task>` を実行しPASSを確認
- [ ] ローカルでテストが全てパス
- [ ] コードレビュー承認済み
- [ ] コンフリクトなし
```

### Hydra拡張コマンド

| コマンド | 用途 | 必須/推奨 |
|---------|------|----------|
| `hydra preflight <task>` | コンフリクト事前検出・依存分析 | **必須** |
| `hydra merge-order` | 複数worktreeのマージ順序計算 | 推奨 |
| `hydra rollback --pr=N` | 問題発生時のロールバック | 緊急時 |

### ワークフロー

```
1. hydra preflight <task>     # 事前検証（PASS必須）
2. hydra close <task>         # PR作成
3. GitHub UI: Add to queue    # Merge Queueに投入
4. 自動マージ完了待機
```

### 例外フロー

以下の条件を**すべて**満たす場合のみ、直接マージを許可:

1. **Owner承認**: リポジトリOwnerの明示的な承認
2. **緊急性**: 本番障害対応等、Merge Queue経由では間に合わない緊急事態
3. **事後レビュー**: 24時間以内の事後レビュー必須
4. **ドキュメント記録**: 例外適用の理由・影響範囲・承認者を記録

### 詳細
→ `docs/design/safe-merge-protocol.md` を参照

---

## 16. Semantic Coordination 追補ルール（Task 6.2 / CRITICAL）

以下は既存ルールへの**追記**であり、矛盾時は本セクションを優先する。

### 4層コンテキスト最適化モデル（Layer 0-3）

```
Layer 0: Ground Truth（事実源）
  - repo core policy
  - .shared/project_id
  - <platform data dir>/Revharness/semantic-mcp/v1/{project_id}/semantic.db / authoritative registry

Layer 1: Pre-flight（事前検証）
  - scope/conflict/lock check
  - diff -> changed symbols -> impact
  - graph rank -> Top-K selection
  - .agent/context/** や exported JSONL は derived export / cache / debug artifact

Layer 2: Prompt Capsule（最小注入）
  - capsule本体 200tok
  - meta/JSON 上限 20tok
  - 合計 220tok 上限（fail-closed）

Layer 3: Execution Feedback（実行検証）
  - Shadow Verify（機械的検証）
  - review/fix loop（論理レビュー）
```

### Shadow Verify 運用ルール（QG-1 / QG-2）

- 実行順は **Coder -> Shadow Verify -> Reviewer** とし、Shadow Verify未通過でReviewerに進めない。
- **QG-1（fail-closed）**: `quality_gate.status in {failed, skipped}` を検出した場合は即失敗扱い。
- **QG-2（fail-closed）**: 言語別必須コマンド（`pnpm|npm` / `cargo` / `pytest` 等）が不足している場合は即失敗扱い。
- Shadow Verifyは機械的検証（lint/typecheck/test および必要時SAST）を担当し、論理的・設計的レビューはReviewerが担当する。
- Shadow Verify の失敗・再試行・追加検証は、同じ task lineage の `evidence destination` と `task-level stall-or-wall-time budget` に記録し、review/fix loop と別建ての retry ceiling を作ってはならない。
- Shadow Verify 失敗後に progress / evidence / budget recheck を追跡できない場合、または matrix の fail-closed 条件に触れる場合は `pending verification` へ曖昧に留めず `BLOCK` とする。

### カプセル生成ルール（fail-closed / 220tok上限）

- カプセルは **合計220tok上限**（本体200tok + メタ/JSON 20tok）を厳守する。
- 220tokを超過した場合は `BLOCK` を返す fail-closed とし、過長カプセルを許容して処理継続してはならない。
- `sem.capsule` では caller 提供の `top_k_symbols` を禁止し、`sem.context.top_k` が発行した `context_token` を必須とする。token 期限切れ、token cache miss、または `file_parse_cache` 由来 rollup の変化は fail-closed とし、`sem.context.top_k` の再発行を要求する。
- capsule body は `INDEX_VERSION=<u64>` と `FILE_SHA_ROLLUP=<sha256>` を含める。`INDEX_VERSION` は hash 入力から固定 slot index で除外し、`FILE_SHA_ROLLUP` は `CAPSULE_SHA256` の hash 入力に含める。
- `agent-core/cmd/capsule.rs::build_capsule_with_symbols` も `shared::freshness` 経由で `file_sha_rollup` を bind し、semantic MCP と同じ freshness invariant を維持する。
- `agent-core/cmd/capsule.rs::build_capsule`（symbols 無し fallback、現行 line 262 近傍）は freshness 無し fallback として残置する。これは本規約のゴール外であり、別 plan で対処する。
- カプセルには `CAPSULE_SHA256` 参照を含め、外部参照時も同じ fail-closed 方針を維持する。

### モデルルーティング（Coder）

- 既定の実装タスク: `codex-wrapper.sh --role coder`
- delegated `light` タスク: `codex-wrapper.sh --role standard`
- 複雑 / security-sensitive な実装タスク: `codex-wrapper.sh --role high-coder`
- 外部調査が本質なタスク: `codex-wrapper.sh --role research`
- 初回 ExecPlan 設計 / ExecPlan drafting / ExecPlan review planning: native `system_planner` / `plan_reviewer` preset の `initial_execplan_design` lane（`gpt-5.5` + `xhigh` + `cached`）。これは docs-only / light planning ではない。
- `security-sensitive=true` タスク: **full-context + `high-coder` (`high` + `cached`)** を強制（diff-only推論を禁止）
- `reviewer` は Reviewer 専用とし、Coder では使用しない。

### `dependency_preflight` / `dependency_policy` 境界仕様（P1）

- 依存管理は三層境界で扱う:
  1. Layer 1: Dependabot / Renovate
  2. Layer 1.5: `dependency_preflight`（policy gate）
  3. Layer 2: Agent修復ループ
- semantic-coordination 側の責務は **`dependency_verdict` の受理・表示のみ**とする。
- `dependency_preflight` の判定ロジック本体と `.agent/registry/dependency_policy.json` の運用は、独立ExecPlan（P1）で管理する。
- 境界I/Fが未接続でもP0フローをブロックしない（後方互換維持）。
