# Verification / Truth Matrix

vocabulary-rev: 39ab54db69ded2c81d79789b9b616be86cce54aeeac8df11245cf88158b3f9b4
Machine-readable vocabulary mirror and consumer policy: docs/manual/matrix-vocabulary.json (`_policy.vocabulary_consumer_contract`).

## Must Read

この文書は、verification / truth placement / reviewer LGTM validity の現行正本である。
計画分解、Coder着手、Reviewer判定、最終受け入れの前に必ず読むこと。
他文書の例や古い手順と衝突する場合は、本書と `.agent_rules/RULES.md` を優先する。

## Task Class Profiles

`light / standard / heavy` の task class は、slice contract より先に判定する。heavy 用の完全 Canonical Schema を全タスクへ機械的に適用してはならない。

Canonical classifier entrypoint は `scripts/rev-harness-task-classifier.sh classify --intent <intent> --files <path>... --json` とする。分類結果の `task_class / gate_tier / schema_profile / review_required / final_reviewer_gate_required` が、その task の acceptance envelope を決める。

| task class | gate tier | schema profile | review / final gate | 用途 |
|------------|-----------|----------------|----------------------|------|
| `light` | `quick` | `light-change-record` | reviewer 不要、Final Reviewer gate 不要 | typo、reference cleanup、admin、prompt wording など、runtime / policy / acceptance / security に触れない小変更 |
| `standard` | `local` | `standard-slice-contract` | scoped reviewer signoff 必須、Final Reviewer gate 不要 | 通常の実装、テスト、docs 更新。release / security / acceptance 正本をまたがない変更 |
| `heavy` | `full` | `heavy-canonical-final-packet` | reviewer 必須、Final Reviewer gate 必須 | release、security、live orchestration、wrapper、role / acceptance matrix、release gate、semantic authority など高リスク変更 |

## Classifier Specialty Selection

| Surface | Truth source | Acceptance evidence | Hint surface | Note |
|---------|--------------|---------------------|--------------|------|
| classifier specialty selection | `scripts/rev-harness-task-classifier.sh` + `docs/manual/matrix-vocabulary.json` | `bash test/unit/test-classifier-specialty-surface.sh` (7 tests) + `scripts/check-matrix-vocabulary-sync.sh` | generated `.claude/skills/<slug>/SKILL.md` + `.agents/skills/<slug>/SKILL.md` | SKILL projection auto-trigger is a discovery hint only. Primary invocation is `scripts/codex-wrapper.sh --role <coder|high-coder|reviewer> --specialty <slug>` for coder / reviewer specialties, or direct `Read` of `docs/roles/orchestrator/specialties/<slug>.md` for orchestrator-canonical specialties. |

`light-change-record` の必須 field:

- `task class: light`
- `intent`
- `changed files`
- `why light is valid`
- `required quick checks`
- `check results`
- `completion boundary`

`standard-slice-contract` の必須 field:

- `task class: standard`
- `task id / slice id`
- `change surface / in-scope / out-of-scope`
- `required local checks`
- `evidence destination`
- `completion boundary`
- `worker outcome`
- `scope delta since last review`
- defect / root-cause / same-class fix の場合だけ class-closure fields

`heavy-canonical-final-packet` は下記 `Canonical Schema` の全 field を使う。`light` と `standard` に heavy-only field を要求して、reviewer loop、lineage ledger、Final Reviewer gate、full release gate を常時強制してはならない。

## Slice Contract

広いタスクは slice に分解してから扱う。`standard` / `heavy` の各 slice は着手前に slice contract を記録する。`light` は `light-change-record` で足りる。`slice record` は plan / SOW / handoff に永続化された slice contract の copy を指す。task lineage の authoritative registry は常に `.agent/active/sow/task-lineage-ledger.md` であり、plan / SOW / handoff は registry 自体の代替ではなく `task lineage ledger entry` を参照して使う。

### Canonical Schema

以下を `heavy-canonical-final-packet` の canonical schema とする。対応する概念は必ずこの名前で記録すること。

| 項目 | 必須内容 |
|------|----------|
| task id | task-level aggregate ceiling を数える単位 |
| task lineage ledger entry | authoritative registry `.agent/active/sow/task-lineage-ledger.md` 内の対応 entry ref。例: `.agent/active/sow/task-lineage-ledger.md :: task-20260418-remediation` |
| prior task id | 初回 lineage は `none`。同じ bug class / materially same change surface を新しい task id で再開する場合は直前 lineage の task id を指す |
| slice id | slice を一意に識別する ID |
| prior slice id | 初回は `none`。mandatory re-slice 時は直前 slice を指す |
| review request target | `INTERMEDIATE` または `FINAL` |
| discovery owner | `coder | orchestrator`。same-class sink の初期発見責務を持つ owner |
| bug class candidate | `n/a` または concrete な bug-class summary。class-closure 要否を判定する canonical field |
| change surface | この slice で変更してよいファイル、レイヤ、責務 |
| in-scope | この slice が変更・検証するファイル、サーフェス、責務 |
| out-of-scope | 今回触らないファイル、責務、保護対象 |
| required checks | 受け入れ前に実行する deterministic checks の正確な一覧 |
| evidence destination | command result、artifact pointer、review report の保存先。slice 固有の volatile truth を置く場所 |
| completion boundary | この slice を完了と呼べる境界。旧 `checkpoint boundary` は deprecated / non-canonical |
| scope delta since last review | 前回 review request 以降の scope 差分。初回は `none` |
| class closure sheet | `path | n/a`。`bug class candidate != n/a` または relevant / unclear な slice では `n/a` 不可 |
| sheet status | `OPEN | CLOSED | RESET | n/a`。`class closure sheet=n/a` の場合だけ `n/a` 可 |
| owned sink universe | `n/a | ...`。same-class slice の completeness を判定する canonical field。class-closure 非適用 slice のみ `n/a` 可 |
| closed universe status | `YES | NO | n/a`。`n/a` は class-closure 非適用 slice のみ。`YES` は all owned sink statuses known のときだけ有効 |
| closed universe basis | `closed universe status=YES` を主張する場合の再現可能な根拠。該当しない場合は `n/a` |
| fix-review loops used | 現 slice で消費した reviewer request 数。`INTERMEDIATE` / `FINAL` の両方を含む |
| closure resets used | 現 slice で実施した class closure reset 数 |
| reviewer-found same-class finding count | coding / handoff 開始後に reviewer iteration で見つかった同一 class sink 数 |
| re-slice count for task | task 全体で消費した mandatory re-slice 数。初回 slice は数えない |
| cumulative reviewer requests for task | task 全体で送った reviewer request 数。`INTERMEDIATE` / `FINAL` を合算する |
| cumulative late same-class findings for task | task 全体で発生した late same-class finding の累積数。re-slice / session / handoff をまたいで持ち越す |
| cumulative closure resets for task | task 全体で実施した class closure reset の累積数。re-slice / session / handoff をまたいで持ち越す |
| task-level stall-or-wall-time budget | `stall<=<minutes>m; wall<=<minutes>m; basis=<task-lineage-opened-at|user-approved-reopen-at>; start=<RFC3339Z>; last-progress=<RFC3339Z>` 形式の mandatory field |
| task-level stall-or-wall-time budget status | `within-budget | exhausted`。`not-defined` / `unknown` / 空欄は deprecated / non-canonical であり fail-closed で `BLOCK` |

補助 provenance として、以下は該当時に必須である。

- `re-slice delta type`: `none | narrowed change surface | redefined owned sink universe | user decision | blocker resolution`
- `re-slice delta summary`: prior slice から何が変わったか。初回は `none`
- `delta evidence`: blocker ticket、user decision、探索ログなど。初回は `none`

class-closure 関連 field の canonical non-applicable sentinel は `n/a` のみとする。`bug class candidate / class closure sheet / sheet status / owned sink universe / closed universe status / closed universe basis` で `not required`、空欄、省略を使ってはならない。
`bug class candidate=n/a` は、その slice が defect / regression / root-cause / same-class fix と無関係だと evidence-backed に示せる場合に限り有効である。relevant か不明な slice は concrete な `bug class candidate` を持ち、`class closure sheet` を required にしなければならない。
`re-slice delta type=none / re-slice delta summary=none / delta evidence=none` は `prior slice id=none` の初回 slice にだけ有効である。`prior slice id != none` で `none` を使った re-slice は fail-closed で `BLOCK` とする。
`worker outcome` は post-execution の worker report / review request / acceptance gate でのみ使う canonical field であり、pre-flight の slice contract には置かない。
deprecated live field alias の `checkpoint boundary`、`truth destination`、`artifact truth destination` は historical label としてしか扱わない。slice contract / worker report / review request / review report では active schema key として使ってはならず、intake は canonical `completion boundary` / `evidence destination` による再提出を要求する。

canonical counter semantics:

1. `fix-review loops used` / `closure resets used` / `reviewer-found same-class finding count` は per-slice counter であり、新しい valid slice を開いたときだけ reset してよい。
2. `re-slice count for task` / `cumulative reviewer requests for task` / `cumulative late same-class findings for task` / `cumulative closure resets for task` / `task-level stall-or-wall-time budget` / `task-level stall-or-wall-time budget status` は task-level ledger であり、re-slice・session・handoff・task id をまたぐ reopen を跨いでも必ず carry-forward する。ceiling 判定ではこの task-level ledger を authoritative とする。
3. `task-level stall-or-wall-time budget` は mandatory である。budget subfield は `basis / start / last-progress` のみを使う。budget が未定義、`basis / start / last-progress` のいずれかが無い、または `task-level stall-or-wall-time budget status` を示せない場合は fail-closed で `BLOCK` とする。
4. default budget は `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=<task-opened RFC3339Z>; last-progress=<same or newer RFC3339Z>` とする。auto-loop で許容できる最大 ceiling は `stall<=60m; wall<=480m` であり、これより soft な budget は invalid で `BLOCK` とする。
5. counter field は `<actual>/<non-blocking ceiling>` で記録する。ceiling 超過の terminal state でも値を丸めず、`fix-review loops used=3/2` や `reviewer-found same-class finding count=2/1` のように actual overflow をそのまま残したうえで `BLOCK` とする。

### Scope Delta Since Last Review

`scope delta since last review` は reviewer が最後に読んだ baseline と current request の差分を表す canonical field である。

1. 初回 review request だけが `none` を使える。以後は同一 lineage の最新 reviewer-reviewed baseline と比較して記録する。
2. 次の request を作る owner（通常は coder）が refresh 責務を持つ。`change surface`、`in-scope`、`out-of-scope`、`required checks`、`evidence destination`、`completion boundary`、Class Closure Sheet / owned sink universe、changed files、または reviewer が再確認すべき verification evidence が変わった場合は concrete な delta を書かなければならない。
3. verification artifact のみを再生成し、reviewer-visible scope が変わらない場合に限り `none` を維持できる。ただし verification record、worker outcome payload、`task-level stall-or-wall-time budget status` は fresh に更新しなければならない。
4. reviewer は `scope delta since last review` を diff / evidence / request target と照合して validate する。欠落、stale、または現 diff / evidence と矛盾する delta は fail-closed で `BLOCK` とする。
5. `scope delta since last review != none` が発生した時点で、既存の residual count、ready for final reviewer LGTM claim、`review request target=FINAL` は失効する。次 request で refresh されるまで再利用してはならない。

## Canonical Status / Verdict State Machine

canonical non-completion statuses は `in progress` / `pending review` / `pending verification` / `pending final review` / `pending acceptance` / `blocked` とする。status field を持つ template / handoff / report はこの exact enum を使う。
reviewer-intake-valid な `Review Request` status は `pending review` / `pending final review` のみである。`pending verification` は reviewer verdict `Needs verification` を受けた後の internal holding state であり、そのまま reviewer に再提出してはならない。

1. `pending final review` は gated status であり、`Final Reviewer Request Gate` を満たした request にだけ使える。conditions-not-met の generic fallback として使ってはならない。
2. `in progress` は slice contract を作成済みだが、まだ review request や required verification が揃っていない状態。
3. `pending review` は reviewer へ渡せるが、`Final Reviewer Request Gate` は未充足の状態。`INTERMEDIATE` request と、`FINAL` request が `Request Changes` で invalidated された後の戻り先はここに統一する。
4. `pending verification` は required checks または reviewer-request 前の追加 verification が未完了の internal holding state である。reviewer-intake-valid ではなく、fail-closed な不足をこの status に downgrade してはならない。
5. `pending acceptance` は reviewer が valid な `LGTM` を返した後、orchestrator acceptance が完了するまでの holding status である。reviewer は `completed` を直接返してはならない。
6. `blocked` は fail-closed、ceiling 超過、provenance 不足、または human/user unblock を要する状態。
7. `completed` は orchestrator 専用 completion status であり、`pending acceptance` から task class profile acceptance gate を再確認した後にだけ使える。fresh な `task-level stall-or-wall-time budget status=within-budget` recheck は `standard` / `heavy` で必須、`light` では不要。

reviewer verdict mapping:

1. `LGTM` は task class profile に応じて有効性を判定する。`standard` では `standard-slice-contract` と required local checks が current evidence で満たされた scoped reviewer signoff として有効であり、release readiness や final closeout を意味しない。`heavy` では `review request target=FINAL` かつ `Final Reviewer Request Gate` 充足時にのみ有効であり、next status は `pending acceptance` とする。`completed` は orchestrator だけが返せる。
2. `BLOCK` は fail-closed verdict であり、next status は `blocked`。
3. `Request Changes` は non-fail-closed だが actionable な issue がある verdict である。current request が `FINAL` の場合、その request は即時に `INTERMEDIATE` へ automatic downgrade され、next status は `pending review` に戻る。`pending final review` は gate 再充足まで再利用不可。
4. `Needs verification` は non-blocking な追加 verification を要求する verdict であり、next status は `pending verification`。required checks failure や provenance 欠落を隠す用途には使えない。`FINAL` request または `ready for final reviewer LGTM` claim から `Needs verification` へ戻った場合、`pending final review` へ再昇格する前に full `Final Reviewer Request Gate` と fresh budget recheck を再充足しなければならない。
5. `Needs Discussion` は human / user decision が必要な verdict であり、next status は `blocked`。

### Return Path From `pending verification`

1. `pending verification` に入った後の追加 verification は、次の worker request を作る owner（通常は coder。reviewer は実行 owner にならない）が行う。
2. `pending verification` は internal holding state であり、reviewer へ再提出する review request の `incoming request status` にそのまま使ってはならない。verification 完了後は fresh な review request を再発行し、status を `pending review` または `pending final review` に正規化するか、return-path 条件を満たせなければ `blocked` に倒す。
3. return 前に refresh 必須なのは、requested verification の `command / result / covered scope / artifact pointer or no-artifact reason / artifact integrity`、`scope delta since last review`、current `worker outcome` payload、fresh な `task-level stall-or-wall-time budget status`、および verification で invalidated された Class Closure Sheet / adversarial pre-closure pass / residual count である。
4. `pending review` に正規化して戻るのは、verification 作業で reviewer-visible diff または scope delta が発生した、`review request target` が `INTERMEDIATE` のまま、または full `Final Reviewer Request Gate` を fresh に再充足できていない場合である。
5. `pending final review` に正規化して戻れるのは、直前 verdict が `Needs verification`、request target が引き続き `FINAL`、`scope delta since last review=none`、新しい diff / late same-class finding / blocker が無く、full `Final Reviewer Request Gate` と fresh budget recheck を current evidence で再充足した場合に限る。
6. requested verification を実行できない、evidence がなお weak / contradictory / missing、lineage や budget refresh を完了できない、または verification が fail-closed issue を露呈した場合は `blocked` に移す。

## Task Lineage / Reopen Guard

task-level ledger は cosmetic な task id ではなく、bug class と materially same な change surface を共有する lineage に紐づく。authoritative lineage registry は `.agent/active/sow/task-lineage-ledger.md` とし、lineage の正本は常にここだけに置く。

1. 同じ bug class / materially same change surface を新しい task id で reopen / relabel する場合、slice contract / handoff / worker report には `task lineage ledger entry` と `prior task id` を必ず残し、`scope delta since last review` と evidence record で reopen 理由を明示する。
2. `.agent/active/sow/task-lineage-ledger.md` には `task id / prior task id / bug class candidate / materially same change surface summary / reopen delta summary / delta evidence / carried task-level counters / timestamp` を記録し、plan / SOW / handoff は registry の代わりにその ledger entry を参照して一致しなければならない。
3. `prior task id != none` の場合、`re-slice count for task` / `cumulative reviewer requests for task` / `cumulative late same-class findings for task` / `cumulative closure resets for task` / `task-level stall-or-wall-time budget` / `task-level stall-or-wall-time budget status` は reset せず carry-forward する。
4. `task lineage ledger entry` が無い、`prior task id` が無い、reopen delta / evidence が無い、ledger entry が無い、または counters を reset した relabel task は invalid であり、fail-closed で `BLOCK` とする。
5. materially same な bug class / change surface に対して `prior task id=none` の新 task id を立てることも invalid であり、fail-closed で `BLOCK` とする。

slice contract 自体の記録先は `.agent/active/plan_*.md`、`.agent/active/sow/*.md`、または明示的な handoff prompt のいずれかとする。ただし task lineage の authoritative registry は常に `.agent/active/sow/task-lineage-ledger.md` であり、他の面は `task lineage ledger entry` を参照するだけに留める。
未分解の broad task をそのまま Coder / Reviewer に渡してはならない。

### Reopen Path From `blocked`

1. `blocked` の解除 owner は、直近の block report に記録された `reroute owner` に従う。restart authority のような別 authority field は持たず、reopen authority は `reroute owner` と block report に記録された `reopen condition summary / unblock evidence required / unblock evidence / reroute evidence` の組合せで判定する。user / orchestrator approval が必要な blocker では、その approval が block report の required evidence として揃うまで coder / reviewer は self-unblock してはならない。
2. unblock 前に、`.agent/active/sow/task-lineage-ledger.md` の対応 entry を refresh し、`prior task id`、unblock reason、unblock evidence、reroute evidence、carried task-level counters、current budget を記録する。explicit approval を伴う reopen では budget basis を `user-approved-reopen-at` に更新する。
3. blocker 解消で slice 境界が変わる場合は mandatory re-slice を行い、`prior slice id` と `re-slice delta type / summary / evidence` を必ず残す。identical relabel-and-restart は無効であり、同じ bug class / change surface に `prior task id=none` を新設してはならない。
4. reopened task は同一 lineage 上で `in progress` に戻る。`blocked` から `pending review` / `pending verification` / `pending final review` へ直接飛ぶことはできず、fresh な worker request を再作成してから進める。

## Universe Adequacy Before Coding

root-cause fix / same-class fix では、coding 前に owned sink universe の妥当性を検証する。

最低条件:

1. owned sink universe が列挙可能で、探索方法が exact command で書かれている
2. closed universe basis を主張する場合、その根拠が再現可能である
3. out-of-scope sink には owner または target owner が付いている
4. target scope、required checks、evidence destination、completion boundary が同じ slice contract に結び付いている

`similar places`、`likely all`、owner 未確定、探索方法不明のような weak universe definition は fail-closed で `BLOCK` または mandatory re-slice とする。
`bug class candidate` が `n/a` のままでも relevant か不明な slice は weak classification とみなし、fail-closed で `BLOCK` とする。

## Mandatory Re-Slice Gate

mandatory re-slice は escape hatch ではない。許可条件は次のとおり。

1. `prior slice id` が埋まっている
2. `re-slice delta type / re-slice delta summary / delta evidence` が埋まっている
3. 少なくとも `change surface の縮小または再定義`、`owned sink universe または closed universe basis の再定義`、`user decision`、`blocker resolution` のいずれかの explicit delta がある

legacy `re-slice delta type=other` は deprecated / non-canonical であり無効とする。分類不能なら user escalation + evidence を要求し、そのままの自動継続は fail-closed で `BLOCK` とする。
`prior slice id != none` なのに `re-slice delta type / re-slice delta summary / delta evidence` のいずれかが `none` の re-slice も fail-closed で `BLOCK` とする。
prior slice と実質同一の slice をラベルだけ変えて再投入することは無効であり、fail-closed で `BLOCK` とする。

## Class Closure / Sink Universe

defect / regression / root-cause fix / same-class fix を完了扱いにする前に、Class Closure Sheet を作成し、少なくとも以下を埋める。

1. bug class の定義
2. owned sink universe と closed universe の根拠
3. sink を列挙した inventory
4. 各 sink の status (`fixed` / `not-present` / `out-of-scope` / `unknown` など)
5. late same-class finding があった場合の reset 状態と再探索結果

closed universe が無い、または `unknown` sink が 1 件でも残る場合、`remaining issues: N`、`root cause fixed`、`class closed`、final reviewer LGTM request は fail-closed で禁止する。
`late same-class finding` は coding / handoff 開始後に同じ owned surface / bug class に対して reviewer が見つけた新規 sink を指し、`INTERMEDIATE` / `FINAL` を問わず timing-independent に扱う。
late same-class finding が出た場合、旧 closeout claim は失効し、sink expansion / verification / final review request をやり直す。

late same-class finding の責務分界:

1. reviewer は finding を review report に concrete な sink / evidence 付きで記録し、verdict で class-closure claim を失効させる。reviewer は authoritative ledger を代理更新しない。
2. 次の request を作る owner（通常は coder、task reopen / re-slice を跨ぐ場合は orchestrator）が、Class Closure Sheet、`scope delta since last review`、per-slice counters、`.agent/active/sow/task-lineage-ledger.md` の task-level counters を refresh してから次 request を出す。
3. reviewer は次 request で authoritative ledger / counters の carry-forward が refresh 済みかを validate し、未更新なら fail-closed で `BLOCK` とする。

## Loop / Stall Rules

1. same slice の reviewer request は `INTERMEDIATE` / `FINAL` を問わず最大 2 回までとする。`fix-review loops used` は最初の reviewer request から毎回加算する。
2. 3 回目の reviewer request for the same slice は automatic `BLOCK` とし、user escalation または mandatory re-slice を行う。
3. `reviewer-found same-class finding count` は per-slice counter であり、新しい valid slice を開いたときだけ reset できる。same slice で 2 回目の late same-class finding に到達した時点で automatic `BLOCK` とし、自動 loop を止める。
4. `closure resets used` は per-slice counter であり、新しい valid slice を開いたときだけ reset できる。same slice で 3 回目の late same-class finding / reset が必要になった時点で automatic `BLOCK` とする。
5. late same-class finding が 1 件発生するたびに `cumulative late same-class findings for task` を加算し、class closure reset を 1 回実施するたびに `cumulative closure resets for task` を加算する。
6. task-level aggregate ceiling として `re-slice count for task` は最大 2、`cumulative reviewer requests for task` は最大 6、`cumulative late same-class findings for task` は最大 2、`cumulative closure resets for task` は最大 2 とする。3 回目の re-slice、7 回目の reviewer request、3 回目の cumulative late same-class finding、または 3 回目の cumulative closure reset が必要になった時点で fail-closed で `BLOCK` とする。ただし `User-Approved Reviewer Ceiling Extension` が成立する場合だけ、`cumulative reviewer requests for task` の non-blocking ceiling を同一 task lineage 内で最小限に引き上げてよい。
7. `standard` / `heavy` では `task-level stall-or-wall-time budget` は mandatory であり、budget 未定義、`basis / start / last-progress` のいずれかが不明、または `task-level stall-or-wall-time budget status` を `within-budget | exhausted` のいずれかで示せない場合は fail-closed で `BLOCK` とする。`light` では不要。
8. `standard` / `heavy` で `task-level stall-or-wall-time budget status=exhausted` なら fail-closed で `BLOCK` とする。
9. `standard` / `heavy` の `task-level stall-or-wall-time budget status` は少なくとも `reviewer request` 発行前、`mandatory re-slice` 作成時、`late same-class finding` または `closure reset` 発生時、material な code/doc/evidence change 後、そして `pending review` / `pending verification` / `pending final review` へ status を上げる直前、および `pending acceptance -> completed` 昇格の直前に再評価する。
10. `standard` / `heavy` では budget が明示されていない場合でも blank のまま進めてはならない。default budget を materialize してから handoff しなければならない。
11. `standard` / `heavy` の default budget は `stall<=30m; wall<=240m` とし、auto-loop での最大 ceiling は `stall<=60m; wall<=480m` とする。これを超える soft budget は invalid で `BLOCK`。
12. late same-class finding または scope delta が 1 件でも発生したら、既存の residual count、ready for final reviewer LGTM claim、`review request target=FINAL` は即時失効する。

### User-Approved Reviewer Ceiling Extension

この例外は、ユーザーが特定 task lineage の継続と LGTM 取得を明示承認した場合に限り、`cumulative reviewer requests for task` の non-blocking ceiling だけを最小限に引き上げる。これは抜け道ではなく、実際の reviewer request 数を reset せずに記録し続けるための governance 表現である。

成立条件:

1. `.agent/active/sow/task-lineage-ledger.md` と該当 SOW に `ceiling extension authority / scope / delta / evidence / expiry` がある。
2. `ceiling extension evidence` はユーザーの明示指示を指す。
3. `ceiling extension scope` は特定 task lineage と次の bounded review pair に限定する。
4. `ceiling extension delta` は actual counter を丸めず、`<actual>/<new-ceiling>` として最小限の増分だけを記録する。
5. `ceiling extension expiry` は次の review pair、push rejection、scope 外実装、または新しい blocker 発生のいずれかで失効する。

この例外で許可できないもの:

- per-slice `fix-review loops used` の 2 回上限超過
- `re-slice count for task` の 2 回上限超過
- `cumulative late same-class findings for task` または `cumulative closure resets for task` の上限超過
- failed / missing deterministic checks
- artifact integrity `MISSING`
- `task-level stall-or-wall-time budget status=exhausted`
- force push、tag overwrite、または reviewer LGTM 前の release/tag/push

## Change Surface Matrix

| Change surface | 代表例 | Required deterministic checks |
|----------------|--------|-------------------------------|
| 純粋な説明文書のみ。コマンド、パス、ポリシー、受け入れ条件を変更しない | 用語整理、誤字修正、説明順の調整 | `git diff --check -- <files>` |
| ルール / role / skill / command policy docs | `.agent_rules/RULES.md`、`AGENTS.md`、`CLAUDE.md`、`docs/roles/*`、`.claude/skills/*`、`.claude/commands/README.md` | `git diff --check -- <files>` と、追加・変更した参照先ごとの `test -e <path>` |
| role boundary / specialty operating templates | `docs/roles/**/specialties/*.md` | `git diff --check -- <files>`、追加・変更した参照先ごとの `test -e <path>`、`cd harness-rust && cargo run -p agent-core -- specialty lint ../docs/roles/*/specialties/*.md` |
| README / manual docs | `README.md`、`docs/manual/*.md`、運用ガイド | `git diff --check -- <files>`、追加・変更した参照先ごとの `test -e <path>`、stable-vs-volatile placement check（stable truth を README / manual に置き、dated rerun / artifact / closeout を混在させないことの確認） |
| active orchestration docs | `.agent/active/plan_*`、`.agent/active/sow/*`、`.agent/active/prompts/*` | `git diff --check -- <files>`、task class profile に応じた envelope completeness check。`light` は `light-change-record`、`standard` は `standard-slice-contract`、`heavy` だけが Canonical Schema 全 field と handoff provenance completeness を要求する |
| prompt / context / plan など運用文書でコマンド、パス、gate、review 条件、運用例を追加・変更する | `.agent/PROJECT_CONTEXT.md`、handoff prompt、plan、SOW | `git diff --check -- <files>`、追加・変更した参照先ごとの `test -e <path>`、コマンドや script 契約に触れる場合は非破壊の help / syntax / existence probe |
| `.github/workflows/*.yml` / `.github/workflows/*.yaml` | GitHub Actions workflow | `git diff --check -- <files>`、YAML parse、`actionlint`、変更した workflow が属する relevant gate |
| wrapper / session / orchestrator shell | `scripts/*wrapper*.sh`、`.claude/commands/*.sh`、`.claude/commands/lib/*.sh` | `git diff --check -- <files>`、変更ファイルごとの `bash -n <file>`、`bash test/integration/cross_agent_wrapper_matrix_test.sh`、必要に応じて related smoke / coordination checks（例: phase / native-surface / semantic coordination 系の smoke） |
| durable authority / queue backend / release-gate surface | repo-local semantic-mcp backend（`scripts/semantic-mcp-server/**`、`harness-rust/crates/semantic-mcp/**`）、public shell ingress / adapter（`scripts/semantic-review-queue.sh`）、`test/integration/harness_release_gate.sh` | `git diff --check -- <files>`、変更 surface の relevant subset checks、semantic preflight / registry mutation hardening では `bash test/integration/semantic_registry_mutation_flow_test.sh`、`bash test/integration/semantic_coordination_test.sh`、`bash test/integration/semantic_project_id_contract_test.sh` を含める。acceptance boundary が release / closeout をまたぐ場合は `bash test/integration/harness_release_gate.sh` |
| reviewer policy / acceptance matrix / truth matrix | acceptance policy、review 判定基準、truth placement の正本 | 該当する上記 row の checks を満たしたうえで、Reviewer は実行済み checks の証跡を確認する。reasoning-only では代替できない |
| build / test / CI / quality gate 設定（workflow 以外） | `Makefile`、quality gate script、test harness 設定 | `git diff --check -- <files>` と、その surface が所有する deterministic validation |
| 実装コード / テスト | `src/**`、`test/**`、アプリ実装 | `git diff --check -- <files>` と、変更 surface に対応する lint / typecheck / unit / integration などの deterministic checks |

`sem.search` is advisory discovery only. A `sem.search` result, excerpt, or
capsule may help locate candidate files or symbols, but it is not acceptance
truth, not class-closure evidence, not reviewer LGTM evidence, and not a
replacement for deterministic checks. Any claim that depends on discovered code
must be backed by the corresponding file diff, source read, test output, or
other deterministic evidence required by this matrix.

### Frontier Phase Verification Checks

For frontier-push / semantic MCP / tree-sitter-index / capsule freshness changes,
deterministic evidence must include the following checks when in scope. Each log
is recorded under `.claude/tmp/frontier-push/` unless the row explicitly names a
benchmark JSON artifact.

| ID | Command | Expected result | Evidence |
|----|---------|-----------------|----------|
| V1 | `cd harness-rust && cargo check --workspace --all-features` | 0 errors | `.claude/tmp/frontier-push/v1.log` |
| V2 | `cd harness-rust && cargo test --workspace --all-features` | all pass | `.claude/tmp/frontier-push/v2.log` |
| V3 | `cd harness-rust && cargo test --doc --workspace --all-features` | pass | `.claude/tmp/frontier-push/v3.log` |
| V4 | `cd harness-rust && cargo clippy --workspace --all-features --all-targets -- -D warnings` | clean | `.claude/tmp/frontier-push/v4.log` |
| V5 | `cd harness-rust && cargo audit && cargo audit --json \| jq -e '(.warnings // []) \| length == 0'` | clean | `.claude/tmp/frontier-push/v5.log` |
| V6 | `cd harness-rust && cargo deny check advisories sources licenses` | clean | `.claude/tmp/frontier-push/v6.log` |
| V7 | `cd harness-rust && cargo test -p semantic-mcp --test agent_core_capsule_freshness` | agent-core capsule `file_sha_rollup` / `index_version` changes after re-index; no byte-identical SHA claim | `.claude/tmp/frontier-push/v7.log` |
| V8 | `cd harness-rust && cargo test -p semantic-mcp --test parallel_path_eliminated` | `agent-core/cmd/capsule.rs` imports `shared::freshness` | `.claude/tmp/frontier-push/v8.log` |
| V9 | `cd harness-rust && cargo test -p semantic-mcp --test fts5_basic` | `components_fts MATCH` returns BM25-ranked rows | `.claude/tmp/frontier-push/v9.log` |
| V10 | `cd harness-rust && cargo test -p semantic-mcp --test fts5_vs_legacy_set` | token-aligned whole-word FTS5 result set is a superset of legacy LIKE | `.claude/tmp/frontier-push/v10.log` |
| V11 | `cd harness-rust && cargo test -p semantic-mcp --test fts5_escape` | quotes/operators are escaped or fail closed | `.claude/tmp/frontier-push/v11.log` |
| V12 | `cd harness-rust && REVHARNESS_TEST_HARNESS=1 cargo test -p semantic-mcp --test placement_v2` | main_loop, agent-core, and harness-cache resolve the same placement v2 path | `.claude/tmp/frontier-push/v12.log` |
| V13 | `cd harness-rust && cargo test -p semantic-mcp --test legacy_migration_wal` | `semantic.db`, `-wal`, and `-shm` migrate with checkpointing | `.claude/tmp/frontier-push/v13.log` |
| V14 | `cd harness-rust && cargo test -p semantic-mcp --test legacy_db_adopt_marker` | `application_id`: `0 -> adopt`, RevHarness marker -> ok, foreign marker -> fail closed | `.claude/tmp/frontier-push/v14.log` |
| V15 | `cd harness-rust && REVHARNESS_TEST_HARNESS=1 cargo test -p semantic-mcp --test gc_admin_dry_run` | dry-run reports candidates and deletes nothing without force | `.claude/tmp/frontier-push/v15.log` |
| V16 | `cd harness-rust && cargo test -p semantic-mcp --test token_cache_lru` | 257th token evicts oldest and expired tokens sweep on insert | `.claude/tmp/frontier-push/v16.log` |
| V17 | `cd harness-rust && cargo test -p tree-sitter-index --test delete_rename_gc` | missing snapshot files remove symbols, dependencies, and parse-cache rows in one IMMEDIATE transaction | `.claude/tmp/frontier-push/v17.log` |
| V18 | `cd harness-rust && cargo bench --bench search_fts5` or `scripts/bench_runner.sh` | p95(fts5) <= p95(legacy-like) / 10 and absolute p95 recorded | `.claude/tmp/frontier-push/bench_search.json` |
| V19 | `cd harness-rust && cargo bench --bench context_top_k` or `scripts/bench_runner.sh` | p95(now) <= p95(baseline) / 2 and absolute p95 recorded | `.claude/tmp/frontier-push/bench_topk.json` |
| V20 | `cd harness-rust && cargo bench --bench index_files` or `scripts/bench_runner.sh` | cold p95 < 5s and warm p95 < 1s for 100 Rust files x 1k LOC | `.claude/tmp/frontier-push/bench_index.json` |
| V21 | `rg -n '\.semantic-mcp\b' harness-rust/crates/ --glob '*.rs' --glob '!**/tests/**'` | 0 matches | `.claude/tmp/frontier-push/v21.log` |
| V22 | `cd harness-rust && cargo metadata --all-features --locked --format-version 1` | `(name, version)` diff only allows `lru-0.18.x`, `fs2-0.4.x`, `scopeguard-1.x`, `allocator-api2-0.2.x`, `foldhash-0.2.x` (`lru` transitives), and dev-only `criterion-*` | `.claude/tmp/frontier-push/v22_v23.log` |
| V23 | `cd harness-rust && cargo tree -e features -p semantic-mcp --all-features` | no unintended feature unification growth versus base | `.claude/tmp/frontier-push/v22_v23.log` |
| V24 | `cd harness-rust && cargo deny check sources licenses` | `lru` / `fs2` / `scopeguard` licenses compatible; `criterion` dev-deps allowed | `.claude/tmp/frontier-push/v24_fixed.log` |
| V25 | `cd harness-rust && cargo test -p semantic-mcp --test foreign_db_rejected` | `application_id = 0xDEADBEEF` DB is rejected fail-closed | `.claude/tmp/frontier-push/v25.log` |

Node TS parity coverage for `sem.capsule` caller-supplied `top_k_symbols` is
quarantined in `test/integration/semantic_backend_contract_parity_test.sh`
with the sentinel `QUARANTINED: see plan_20260516_ts-wire-and-freshness §3`.
The quarantine is limited to the old Node parity top-k input cases; Rust
semantic-mcp treats `top_k_symbols` as server-issued state behind
`sem.context.top_k`.

## Truth Placement

| 種別 | Stable placement | Volatile placement |
|------|------------------|--------------------|
| repo-wide hard rules / fail-closed acceptance policy | `.agent_rules/RULES.md` | なし |
| verification / truth placement / LGTM validity の正本 | `docs/manual/verification-truth-matrix.md` | なし |
| role boundary and specialty operating templates | `docs/roles/**` (canonical role docs + specialty files under `docs/roles/<canonical>/specialties/*.md` with embedded JSON manifest) | なし |
| orchestration closure の checklist / template / 実務手順 | `docs/manual/orchestration-closure-playbook.md` | なし |
| project-local operating context | `.agent/PROJECT_CONTEXT.md` | なし |
| authoritative task lineage registry | なし | `.agent/active/sow/task-lineage-ledger.md` のみ。plan / SOW / handoff は `task lineage ledger entry` 参照のみを持つ |
| slice 固有の change surface / in-scope / out-of-scope / required checks / evidence destination / completion boundary / loop budget ledger | なし | `.agent/active/plan_*.md` / `.agent/active/sow/*.md` / handoff prompt |
| 実行ログ、check 結果、blocker、未解決事項 | なし | `.agent/active/sow/*.md` / `.claude/tmp/**` |

Stable truth は長期参照先に置き、セッション依存の内容を混在させない。
Volatile truth は恒久ルールを上書きしない。例外や不足は waiver ではなく `BLOCK` として扱う。
slice contract の `evidence destination` は、この表の volatile placement にぶら下がる slice 固有の保存先を指す。`truth placement` 自体の別名ではない。

## Verification Artifact Integrity

required deterministic check ごとに、少なくとも以下を 1:1 で結びつける。

1. exact command
2. result (`PASS` / `FAIL`)
3. covered scope / hunk / slice
4. artifact pointer、または explicit な no-artifact reason

artifact pointer がファイル path の場合は、その path が存在することを確認できなければならない。
required check の未実行、skip、結果不明、または未記録は enum ではなく fail-closed `FAIL` 条件として扱う。
`MISSING` とは、artifact pointer が欠落している、存在確認できない、command / scope に対応付けられない、または reviewer / orchestrator が追跡できない状態を指す。
artifact integrity が `MISSING` の場合は fail-closed で `BLOCK` とする。

## Adversarial Pre-Closure Pass

1. adversarial pre-closure pass は coder が `FINAL` request または ready-for-final claim の前に実施し、exact search commands と coverage を残す。
2. valid な `PASS` には、current owned sink universe / completion boundary に対して `opposite hypothesis checked`、`untouched owned surfaces checked`、`boundary / fallback / alias paths checked` が concrete に埋まっていなければならない。`checked`、`manual review done`、空欄、placeholder のような weak pass は無効である。
3. pass が新規 sink、boundary leak、alias path、または same-class risk を見つけた場合、result は `RESET` とし、Class Closure Sheet、`scope delta since last review`、verification record、counters を refresh してから次 request を作る。
4. reviewer は section の存在だけでなく、current slice / Class Closure Sheet に照らして substantive coverage があるかを validate する。weak / stale / non-reproducible な pass は final gate の根拠に使えず、fail-closed で `BLOCK` とする。

## Reviewer LGTM Validity

Reviewer が `LGTM` を出せるのは、task class profile に応じた envelope をすべて満たす場合のみ。

共通条件:

1. 対象が scope-bounded な slice である。
2. task class classifier の結果と schema profile が記録されている。
3. required checks が実行済みで、正確なコマンドと結果が追跡できる。
4. deterministic-check surface に対して reasoning-only の判定をしていない。
5. required checks に失敗、skip、未実行、結果不明がない。
6. worker outcome が `DIFF` または evidence-backed `NO-CHANGE` である。

`standard` LGTM の追加条件:

1. `standard-slice-contract` の必須 field が揃っている。
2. artifact integrity が relevant artifact に対して `complete`、artifact が無い場合は no-artifact reason が command / scope と対応している。
3. root-cause fix / same-class fix の場合だけ Class Closure Sheet が最新で closed である。
4. `standard` LGTM は scoped local acceptance だけを意味し、release readiness、final closeout、remaining issues exact count を主張してはならない。

`heavy` LGTM の追加条件:

1. `heavy-canonical-final-packet` として Canonical Schema の全 field（`task lineage ledger entry` と `owned sink universe` と `bug class candidate` を含む）と、該当する `re-slice delta type / re-slice delta summary / delta evidence` がある。
2. artifact integrity が `complete` である。
3. root-cause fix / same-class fix では Class Closure Sheet が最新で closed である。
4. late same-class finding があった場合、reset と再探索が反映済みである。
5. adversarial pre-closure pass が final reviewer request 前に完了し、substantive coverage まで validate できる。

## Worker Outcome Contract

final gate や completion 判定に使える worker outcome は次の条件を満たすものに限る。

1. `worker outcome` は `DIFF` / `BLOCK` / `NO-CHANGE` のいずれかである。
2. `worker outcome=DIFF` には task class profile に対応する schema、`changed files`、verification record (`command / result / covered scope / artifact pointer or no-artifact reason / artifact integrity`)、evidence pointer、next action がある。`heavy` では `re-slice delta type / re-slice delta summary / delta evidence` も必須。
3. `worker outcome=BLOCK` には task class profile に対応する schema、fail-closed reason、足りない前提、attempted checks または execution constraint、next required input がある。`standard` / `heavy` では reroute owner、reopen condition summary、unblock evidence required、unblock evidence、reroute evidence を含める。`heavy` block report では discovery owner / bug class candidate / required checks / class-closure state / lineage provenance / budget counters を省略してはならない。
4. `worker outcome=NO-CHANGE` には task class profile に対応する schema、探索した surface、差分が出なかった理由、exact search / verification evidence、last-reviewed baseline、closed-universe claim の有無がある。
5. reviewer へ送る `Review Request` は `incoming request status=pending review | pending final review` かつ `worker outcome=DIFF | NO-CHANGE` の組合せである場合のみ有効である。`pending verification` は internal holding state であり review intake ではない。`worker outcome=BLOCK`、`status=blocked`、欠落した status / worker outcome、または invalid intake は review intake ではなく separate な block report path とする。

evidence を欠く `NO-CHANGE` は無効であり、final gate / completion / LGTM の根拠に使ってはならない。

`worker outcome=NO-CHANGE` の review routing:

1. reviewer は `searched surface`、`search / verification evidence`、`last-reviewed baseline`、`scope delta since last review` の対応が追跡できる場合にのみ `NO-CHANGE` intake を有効とみなす。
2. `INTERMEDIATE` request で、不足が narrow な追加 search / verification evidence だけに限定され、canonical schema / lineage / baseline が揃っている場合に限り `Needs verification` を返せる。
3. `NO-CHANGE` の searched surface、baseline、lineage、または evidence が weak / stale / contradictory な場合は、`INTERMEDIATE` / `FINAL` を問わず fail-closed で `BLOCK` とする。

## Completion / Archive Language Semantics

1. `LGTM` を user-facing に使えるのは、required checks PASS、artifact integrity が `complete`、reviewer acceptance 成立、completion boundary 充足、worker outcome が `DIFF` または evidence-backed `NO-CHANGE` のときだけ。`light` では reviewer acceptance が無いため `LGTM` ではなく `completed` / `accepted` を使う。
2. `completed` を user-facing に使えるのは、task class profile に対応する required checks PASS、artifact integrity または explicit no-artifact reason、completion boundary 充足、worker outcome または `light-change-record` が揃ったときだけ。
3. `archived` を user-facing に使えるのは、`LGTM` / `completed` 条件に加えて archive-action evidence が追跡可能なときだけ。
4. canonical non-completion statuses は `in progress` / `pending review` / `pending verification` / `pending final review` / `pending acceptance` / `blocked` とする。`pending final review` は `Final Reviewer Request Gate` 充足時にだけ使え、conditions-not-met の fallback は `in progress` / `pending review` / `pending verification` / `blocked` に限る。`pending verification` は internal holding state であり review intake ではない。`pending acceptance` は reviewer `LGTM` 後の holding status であり、`completed` は orchestrator 専用である。
5. `pending acceptance -> completed` は reviewer verdict の延長ではなく、orchestrator による task class profile acceptance gate 再確認である。truth read order、deterministic evidence、completion boundary、worker outcome validity、artifact integrity または no-artifact reason を再確認できない限り `completed` へ進めない。fresh な `task-level stall-or-wall-time budget status=within-budget` は `standard` / `heavy` で必須、`light` では不要。

## Remaining-Issues Count / Final-LGTM Claims

`remaining issues: N` を主張してよいのは、closed universe を持つ Class Closure Sheet があり、all owned sink statuses known、basis、timestamp、target scope が明記されている場合のみ。
exact count を書く場合は、count line の直下に `closed universe basis / basis / timestamp / target scope` を必ず置く。
late same-class finding または scope delta が発生した時点で既存 count は失効する。
その条件を満たさない場合は `remaining issues count unknown` を使う。

`Final Reviewer Request Gate` を通して final reviewer LGTM request を出してよいのは、少なくとも次を満たす場合のみ。

1. review request target が `FINAL` として固定済み
2. slice scope と completion boundary が固定済み
3. Class Closure Sheet が closed
4. late same-class finding reset が反映済み
5. adversarial pre-closure pass 完了かつ substantive coverage が trace できる
6. required checks PASS
7. artifact integrity が `complete`
8. scope delta since last review が `none` または明示的に反映済み
9. worker outcome が `DIFF` または evidence-backed `NO-CHANGE`
10. loop budget ledger within ceiling であり、`task-level stall-or-wall-time budget status=within-budget` を示せる

上記のいずれかが欠けた状態で `FINAL` を要求した場合は fail-closed で `BLOCK` とする。soft downgrade は不可。`Needs verification` を経由した request が `pending final review` に戻る場合も、この gate を全項目再充足し、fresh budget recheck を記録しなければならない。

### Plan LGTM Gate (Condition #41: independent reviewer required before slice execution)

Mutation を授権する ExecPlan は、slice 起票前に **independent reviewer (Codex xhigh role=reviewer) の LGTM を 1 回取得する**。user approval は plan 起票の gate、reviewer LGTM は coder 委譲前の gate という二段構え。

Initial design / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane に従い、`gpt-5.5` + `xhigh` + `cached` とする。既存の `system_planner` / `plan_reviewer` native preset はこの xhigh lane として扱い、通常の docs-only / light planning とは混同しない。

適用対象:
- mutation を導出する ExecPlan（コード改変、file mutation、schema change 等）
- harness-level 改変（skill / role / matrix / policy 追加・改訂）

非適用（user approval のみで可）:
- read-only inventory の single-slice ExecPlan
- orchestrator 自身の内部メモ（active orchestration docs のみ触る）

Fail-closed condition: Plan LGTM 未取得のまま slice を起票した場合、対応する orchestration packet は `BLOCKED` 扱いとする。retrospective に後から Plan LGTM を取ることは許容する（本 session の例）。

Evidence: Plan LGTM の reviewer 出力は `.agent/active/prompts/plan_lgtm_<slice_id>_output.md` に記録する。LGTM / CHANGES REQUIRED / BLOCKED のいずれかが明示されていなければ gate 成立としない。

## Fail-Closed Block Conditions

以下のいずれかに該当する場合、判定は `BLOCK` とする。

1. broad task が未分解のまま Coder / Reviewer に渡されている。
2. task class profile に対応する contract が欠落している、または profile-required fields が欠落している。loop budget ledger 欠落は `standard` / `heavy` で `BLOCK` とし、`light` では対象外。
3. required checks が未定義、未実行、skip、失敗、または結果不明である。
4. 追加・変更したパスやコマンド参照の存在確認がない。
5. deterministic-check surface なのに reasoning-only で accept / LGTM しようとしている。
6. runner や環境不足で required checks を実行できないのに、そのまま先へ進めようとしている。
7. semantic preflight が `target_lock.status == blocked` または `ambiguity.status == blocked` を返しているのに、mutation / accept / closeout へ進めようとしている。
8. authoritative registry mutation が target-lock mismatch または registry ownership mismatch を返したのに、同一 slice を成功扱いしようとしている。
9. root-cause fix / same-class fix なのに Class Closure Sheet が無い、closed universe が無い、または `unknown` sink が残っている。
10. artifact integrity が `MISSING`、存在確認不能、または command / scope と対応付け不能である。
11. late same-class finding が出たのに class closure reset と sink expansion をやり直していない。
12. closed universe が無いのに `remaining issues: N` を主張している。
13. final reviewer LGTM request が Class Closure Sheet / adversarial pre-closure pass / artifact integrity / valid worker outcome を欠いている。
14. weak owned-sink-universe definition のまま coding / review / closeout に進もうとしている。
15. same slice で 3 回目の reviewer request に進もうとしている。
16. `reviewer-found same-class finding count` が 2 回目なのに auto-loop を継続しようとしている。
17. 3 回目の late same-class finding / class closure reset が必要なのに auto-loop を継続しようとしている。
18. mandatory re-slice に explicit delta が無い、または identical relabeled slice を再投入しようとしている。
19. task-level aggregate ceiling（3 回目の re-slice、7 回目の reviewer request、3 回目の cumulative late same-class finding、3 回目の cumulative closure reset、または `task-level stall-or-wall-time budget status=exhausted`）を超えて auto-loop を継続しようとしている。ただし reviewer request ceiling だけは、`User-Approved Reviewer Ceiling Extension` の成立条件を満たす場合に限り、その bounded scope 内で継続してよい。
20. stale residual count / ready for final reviewer LGTM claim を、late same-class finding や scope delta 後も使い続けている。
21. exact residual count を書いているのに、その直下に `closed universe basis / basis / timestamp / target scope` が無い。
22. `NO-CHANGE` を evidence なしで final gate / completion / LGTM の根拠に使っている。
23. `completed` / `LGTM` / `archived` を、required evidence より先に closeout language として使っている。
24. `archived` を archive-action evidence なしで user-facing closeout language として使っている。
25. `standard` / `heavy` で `task-level stall-or-wall-time budget` が未定義、`basis / start / last-progress` のいずれかが無い、または `task-level stall-or-wall-time budget status` を示せない。
26. `re-slice delta type=other`、`task-level stall-or-wall-time budget status=not-defined`、`task-level stall-or-wall-time budget status=unknown`、`task-level stall-or-wall-time budget: not-defined` などの deprecated / non-canonical schema 値を使っている。
27. 同じ bug class / materially same change surface を新しい task id に relabel したのに `prior task id`、reopen delta / evidence、または carried task-level ledger が無い。
28. `.agent/active/sow/task-lineage-ledger.md` の対応 entry が無い、`task lineage ledger entry` が handoff / plan / SOW に無い、または lineage claim と矛盾している。
29. `bug class candidate=n/a` のまま relevant / unclear な slice を class-closure 非適用として扱っている。
30. `class closure sheet / sheet status / owned sink universe / closed universe status / closed universe basis` の非適用表現に `n/a` 以外を使っている。
31. `prior slice id != none` なのに `re-slice delta type / re-slice delta summary / delta evidence` のいずれかを `none` のまま re-slice している。
32. `pending acceptance -> completed` の前に task class profile acceptance gate を省略している、または `standard` / `heavy` で fresh `task-level stall-or-wall-time budget status=within-budget` recheck を省略している。
33. `Needs verification` から `pending final review` へ戻す際に full `Final Reviewer Request Gate` の再充足を省略している。
34. `pending verification` から戻る request なのに refreshed verification record、`scope delta since last review`、current `worker outcome`、または fresh budget recheck のいずれかが欠けている。
35. `blocked` を authoritative ledger refresh、carry-forward counters、または unblock evidence なしで reopen しようとしている、または `blocked` から直接 `pending review` / `pending verification` / `pending final review` へ飛ぼうとしている。
36. `scope delta since last review` が欠落、stale、または current diff / evidence と矛盾している。
37. `checkpoint boundary`、`truth destination`、`artifact truth destination` などの deprecated alias field を live schema key として使っている。
38. adversarial pre-closure pass が weak / placeholder / non-reproducible なのに `PASS` 扱いしている。
39. review request を `pending verification` のまま reviewer intake に出している、または verification return path を `pending review` / `pending final review` / `blocked` に正規化せずに再提出している。
40. block report に `reroute owner`、`reopen condition summary`、`unblock evidence required`、`unblock evidence`、`reroute evidence` のいずれかが欠けており、blocked reopen 条件を再構成できない。
41. Plan LGTM Gate の適用対象である mutation-authorizing ExecPlan なのに、independent reviewer LGTM を取得しないまま slice を起票している。

実行不能は免除ではない。制約を記録し、reroute するか `BLOCK` を返す。
