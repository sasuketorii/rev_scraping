# Wave 22 Roadmap

> HSDI (Wave 21) で deferred された項目の formal roadmap. priority 順.

## 1. Background

HSDI Phase A-H で adopter lifecycle + smoke gate + self-defense layer を完成.
以下は意図的に Wave 22 deferred:
- 理由 1: HSDI scope 拡大防止 (= 完成度優先)
- 理由 2: schema-only/CLI surface の安全性確認後の本実装
- 理由 3: TS migration の準備期間

HSDI delivered adopter install / doctor / upgrade-inspect /
uninstall-checklist, smoke gate (I-12), and 13 invariants. Wave 21 の主眼は
safe surface を固めることであり、実行系の destructive path まで広げると
acceptance evidence が薄くなるため、apply 系は意図的に外した。

Deferred items は 3 種類に分かれる。第一に、schema は landed したが reader が
未実装の decisions table。第二に、schema-only / CLI preview を越えて実際に
filesystem や adopter state を変更する upgrade / uninstall apply path。第三に、
Bash facade から Typed TS orchestrator へ移行できるかを検証する長期 PoC である。

Wave 22 は、HSDI の完了状態を崩さず、deferred item を priority と dependency
順に閉じる。HIGH priority は agent が decision rationale を読める状態まで進め、
MED priority は double opt-in と rollback を満たす destructive surface を実装し、
LOW priority は production replacement ではなく feasibility check として扱う。

Wave 22 の共通方針:
- Acceptance は reasoning ではなく durable evidence で判断する。
- すべての milestone で dual-LGTM + smoke gate (I-12) を必須にする。
- apply 系は fail-closed を基本にし、ambiguous state では halt する。
- agent-facing response は secret redaction と deterministic error を前提にする。
- deferred-again が発生した場合は理由と次の owner を明記する。

## 2. Deferred items (5 items)

Canonical item literals:

- `decision.rs` Rust reader for `decisions` table
- `sem.decision.get` MCP tool
- `rev-harness upgrade --apply`
- `rev-harness uninstall --apply`
- TS Orchestrator PoC

### 2.1 `decision.rs` Rust reader for `decisions` table (HIGH priority)

HSDI Phase F (commit 25fd3d0) で
harness-rust/crates/semantic-mcp/migrations/0001_add_decisions_table.sql
(additive) を landed. schema は ready, reader 実装が deferred.

**Scope**:
- harness-rust/crates/semantic-mcp/src/decision.rs (新規)
- decisions table CRUD operations
- 既存 sem.* tool flow との integration
- TTL handling (= expires_at field の自動 expire)
- Rust type mapping for decision_id / rationale / metadata / expires_at
- deterministic error mapping for not-found, duplicate-id, and expired rows
- bounded list operation with stable ordering
- metadata JSON encode / decode with validation

**Design notes**:
- `decision.rs` は storage boundary として実装し、MCP handler に SQL を漏らさない。
- expired decision は SELECT から除外し、物理削除は別 concern とする。
- duplicate-id は caller bug として扱い、silent overwrite しない。
- timestamp handling は UTC baseline に統一する。
- rationale body は Markdown を許容するが raw secret を保存しない運用にする。
- concurrent write は DB constraint と retry policy のどちらで扱うか明示する。
- tests は deterministic clock を使い、現在時刻依存を避ける。

**Acceptance**:
- Rust unit test: 7+ scenarios (insert / fetch / list / expire / not-found / duplicate-id / concurrent-write)
- migration replay test (fresh DB + existing DB の両方)
- ttl expire test (= expires_at < now で SELECT から除外)
- malformed metadata test (= typed error, panic 無し)
- pagination or limit test (= unbounded scan を防ぐ)
- schema round-trip test (= rationale と metadata が lossless)
- evidence artifact に command, exit status, covered scope を保存

**Estimated effort**: 1-1.5 dev-days.

### 2.2 `sem.decision.get` MCP tool (HIGH priority, depends on 2.1)

agent-facing tool で decision rationale を query 可能に.

**Scope**:
- harness-rust/crates/semantic-mcp/src/main_loop.rs に MCP tool 追加
- JSON-RPC handler (request: decision_id, response: rationale + metadata)
- response schema (markdown frontmatter で structured fields)
- sem.* tool registry / capability listing への追加
- expired decision と missing decision の separate error path
- request validation for decision_id
- log redaction for rationale body

**Design notes**:
- `sem.decision.get` は `decision.rs` の thin wrapper とし、storage logic を再実装しない。
- response は agent が handoff に貼れる程度に concise かつ structured にする。
- markdown frontmatter は stable keys のみにする。
- project identity と DB path を明示的に束縛する。
- logs には decision_id までを出し、rationale body を安易に出さない。
- timeout と error code は existing sem.* tool flow に合わせる。

**Acceptance**:
- MCP integration test (real semantic-mcp 起動 -> tool call -> assert response)
- agent-facing trigger word example (e.g., "decision X の rationale 確認")
- error path: 存在しない decision_id / expired decision
- response schema snapshot test
- capability listing test
- log redaction check
- docs snippet が actual tool name と一致

**Estimated effort**: 0.5-1 dev-day.

### 2.3 `rev-harness upgrade --apply` (MED priority)

HSDI Phase G で upgrade inspect/plan まで, apply は deferred.

**Scope**:
- schema migration safety (= additive only enforcement; destructive を fail-closed で reject)
- rollback path (= previous tag への戻し; .agent/state/upgrade_backup/ snapshot)
- adopter project state preservation (= worktree / staged change の検出と halt)
- .cargo/config.toml, settings.json 等 user customization の diff merge (3-way merge prefer adopter)
- version compatibility matrix validation
- preflight doctor and post-apply doctor
- partial failure marker の durable 保存
- backup retention policy

**Design notes**:
- `upgrade --apply` は dry-run output と同じ plan を入力として使う。
- dirty worktree / staged changes / unknown local edits は apply 前に halt する。
- destructive migration は Wave 22 では reject し、明示 opt-in でも実行しない。
- rollback は best-effort ではなく testable path として扱う。
- .agent/state/upgrade_backup/ は project-local evidence として扱う。
- user customization conflict は自動解決せず、adopter review に戻す。
- command output は secrets を含む可能性を前提に redaction を通す。

**Acceptance**:
- 5+ upgrade scenarios (= minor / major / breaking / dirty-worktree / customized-settings)
- failure recovery test (mid-upgrade abort -> doctor green に戻ること)
- I-11 destructive opt-in 維持 (= --apply + --confirm-upgrade 等の double opt-in)
- rollback artifact が作成され、参照可能であること
- destructive migration detection test
- customized settings 3-way merge test
- preflight / postflight doctor の both recorded evidence

**Estimated effort**: 2-3 dev-days.

### 2.4 `rev-harness uninstall --apply` (MED priority)

HSDI Phase G で uninstall --print-checklist まで.

**Scope**:
- shell rc 編集 (PATH export 除去, idempotent な sed marker block)
- .shared/project_id の安全削除 (= 他 project 確認後, last-project gate)
- ~/.semantic-mcp/<pid>/ cleanup (DB + index)
- ~/Library/Application Support/Revharness/<pid>/ cleanup (state + logs)
- doctor 経由で post-uninstall 検証 (= 残骸無し確認)
- dry-run preview を default に維持
- partial install の検出と cleanup plan 生成
- shell rc backup の作成

**Design notes**:
- `uninstall --apply` は checklist の executable counterpart とする。
- default は no-op preview で、apply には explicit confirm を必要とする。
- rc file edit は marker block のみを対象にする。
- marker が無い unmanaged line は自動削除しない。
- project_id 削除は last-project gate を通った場合のみ許可する。
- semantic-mcp state は pid scoped path のみを対象にする。
- partial install は成功扱いにせず、deterministic remediation を返す。

**Acceptance**:
- 4+ uninstall scenarios (= single project / multi project / dirty state / partial install)
- multi-project coexistence test (= 他 project の semantic-mcp を破壊しないこと)
- I-11 maintain (= --apply --confirm-uninstall 等の double opt-in)
- shell rc marker block idempotency test
- last-project gate test
- post-uninstall doctor evidence
- partial install cleanup test

**Estimated effort**: 2-3 dev-days.

### 2.5 TS Orchestrator PoC (LOW priority, exploratory)

現状 Bash facade を Typed TS orchestrator に migration する PoC.

**Scope**:
- 13 invariants の TS spec (Zod schema で declarative 化)
- state machine の typed expression (XState 等)
- safe-dispatch / state-transition-guard の TS reimplementation
- 既存 Bash と coexistence (= migration path; feature flag で TS path 選択)
- CLI command contract の typed model
- smoke gate invocation の typed wrapper
- evidence artifact schema の typed definition
- Bash facade との parity matrix

**Design notes**:
- TS Orchestrator は production replacement ではなく PoC として扱う。
- Bash remains source of truth until parity is proven.
- Zod schema は runtime validation と docs generation の両方に使える形にする。
- state machine は transition evidence を出力できることを条件にする。
- `any` は禁止し、strict mode を前提にする。
- feature flag は adopter が容易に Bash path へ戻せる設計にする。
- PoC の artifact は Wave 23 planning input として保存する。

**Acceptance**:
- PoC が rev-harness install --target を実行 (実 adopter で smoke gate pass)
- TypeScript 100% type-safe (= no any, strict mode)
- 既存 Bash と feature parity (= 13 invariants 全部 pass)
- feature flag off で Bash path が unchanged
- state machine transition test
- Zod schema validation test
- safe-dispatch parity test

**Estimated effort**: 1-2 dev-weeks.

## 3. Wave 22 milestone

| Milestone | Scope | Estimated effort |
|---|---|---|
| **W22.0** | **Docs catch-up (= 7 stale operator docs HSDI 反映)** | **~700 LOC, 1-2 dev-days** |
| W22.1 | decision.rs reader + sem.decision.get tool | 1.5-2.5 dev-days |
| W22.2 | upgrade --apply | 2-3 dev-days |
| W22.3 | uninstall --apply | 2-3 dev-days |
| W22.4 | TS Orchestrator PoC (optional) | 1-2 dev-weeks |

各 milestone で dual-LGTM + smoke gate (I-12) 必須.
W22.4 は exploratory のため reviewer 2 名のうち 1 名は research role 可.

## 3.5 Stale operator docs (deferred to Wave 22)

HSDI Phase H で識別された **HSDI 反映ゼロかつ explicitly Wave-22-deferred されていない** operator-facing docs. Wave 22 で各々 HSDI 機能 reference を追加予定. 現状は **HSDI 機能の説明は新規作成済 operator manuals (`docs/manual/{phase-done-smoke,release-binary-privacy,safe-dispatch,state-transition-guard,rev-harness-lifecycle,path-leak-soft-layer,snapshot-hooks,hsdi-architecture-overview}.md`) を参照**.

| Doc | 現状 | Wave 22 update scope |
|---|---|---|
| `docs/manual/harness-user-guide.md` | HSDI 反映ゼロ | adopter lifecycle (rev-harness facade) + smoke gate 追加 |
| `docs/manual/end-user-guide.md` | HSDI 反映ゼロ | 1-step install pattern + dev junk cleanup |
| `docs/manual/agent-maintainer-guide.md` | HSDI 反映ゼロ | 13 invariant + state-transition-guard + safe-dispatch |
| `docs/manual/harness-release-gate.md` | HSDI 反映ゼロ | I-2b binary privacy + I-12 smoke gate enforcement |
| `docs/manual/orchestration-closure-playbook.md` | HSDI 反映ゼロ | dual-LGTM + lgtm_stage joint axis |
| `docs/manual/agent_review_loop.md` | HSDI 反映ゼロ | reviewer markdown verdict 強制 + dual_lgtm_gap.jsonl |
| `docs/README.md` (= docs index) | HSDI 反映ゼロ | 新規 10 docs の routing 追加 |

**Estimated effort**: ~700 LOC update 合計, 7 file (Wave 22 W22.0 = "Docs catch-up" milestone として組み込み推奨).

Update 完了で:
- 全 operator manual が HSDI 機能を反映
- `docs/README.md` index 経由で adopter が HSDI 機能 docs に到達可能
- 新規/既存 docs の HSDI 反映率 100%

Milestone closure は implementation completion と acceptance completion を分けて記録する。
worker outcome は DIFF / NO-CHANGE / BLOCK とし、final acceptance は truth matrix と
smoke gate result によって決める。W22.2 と W22.3 は destructive surface を含むため、
reviewer comment だけでは closure としない。

## 4. Out-of-Wave-22 (= long-term)

- multi-language tree-sitter expansion (現状 6 languages → 10+)
- distributed semantic-mcp (= 複数 host 跨ぎ; replication / quorum read)
- AI model 拡張 (= Anthropic + OpenAI 以外の vendor; Gemini / DeepSeek 等)
- adopter telemetry opt-in (= usage metric 集約, privacy-preserving)

These items remain outside Wave 22 because they change architectural boundaries
rather than closing HSDI deferrals. They should be planned with separate RFCs,
dedicated risk registers, and explicit privacy / operations reviews.

## 5. Cross-references

- HSDI overview: docs/manual/hsdi-architecture-overview.md
- CHANGELOG: CHANGELOG.md 0.0.18 entry (Wave 22 deferral list)
- canonical invariants: docs/canonical-invariants.md
- truth matrix: docs/manual/verification-truth-matrix.md
- phase-done smoke: docs/manual/phase-done-smoke.md
- Wave 21 RFCs: .agent/active/plan_20260525_hsdi-phase-G-rfc.md §7,
  .agent/active/plan_20260526_hsdi-phase-H-rfc.md §9

Additional implementation references should be added only when they become
stable. Avoid linking volatile scratch notes as normative sources unless the
milestone explicitly records them as evidence.

## 6. Risk register

- **R1 (decisions reader)**: schema landed but not exercised; risk that field
  semantics shift before reader is implemented. Mitigation: freeze schema in
  W22.1 plan, add migration replay test on every Wave 22 PR.
- **R2 (upgrade --apply)**: highest blast radius; mid-upgrade failure can
  leave adopter in half-migrated state. Mitigation: snapshot-first under
  .agent/state/upgrade_backup/, mandatory rollback path test.
- **R3 (uninstall --apply)**: multi-project coexistence; over-eager cleanup
  can delete another project's semantic-mcp state. Mitigation: last-project
  gate, dry-run preview default, --apply explicit opt-in.
- **R4 (TS PoC)**: feature parity drift; TS path diverges from Bash facade.
  Mitigation: keep Bash as source of truth until 13 invariants all pass on TS.

## 7. Acceptance criteria for Wave 22 closure

- All HIGH-priority items (2.1, 2.2) shipped with dual-LGTM.
- At least one MED-priority item (2.3 or 2.4) shipped with dual-LGTM.
- smoke gate (I-12) green on every W22.x merge.
- CHANGELOG 0.0.19 entry enumerates which Wave 22 items landed vs deferred again.
- This roadmap file updated with completion markers per milestone.

Wave 22 closure must also record:
- milestone status for W22.1 through W22.4
- exact accepted scope
- exact deferred-again scope
- tests and smoke commands that ran
- tests that could not run, with blocker reason
- reviewer identity or role label
- final acceptance state

Completion markers should be appended near the relevant milestone rather than
rewriting historical scope. If an item is deferred again, preserve the original
acceptance target and add the reason, new owner, and next review date.
