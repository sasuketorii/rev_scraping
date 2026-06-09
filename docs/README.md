# Documentation

`docs/` は、このハーネスの stable documentation を置く場所です。日付つき rerun result やその場限りの handover はここに固定せず、stable rule と volatile evidence を分離して管理します。

## Operating Model

この repo の stable docs が前提にする canonical operating model は、Revharness（machine name: `rev_harness`）を source-centric な harness として採用し、新規 Revharness project の実 product code を既定で `src/` 配下に置くことです。`agent_base` / `agent-base` は既存 checkout、古い install、migration detection、検索性のための legacy alias であり、新しい canonical identity や distribution authority として扱いません。

docs 上では次の 3-layer split を canonical summary として扱います。

1. `Framework / Core Harness`
   - harness framework、wrapper、policy doc、CI gate、integration surface
2. `Project State`
   - `.agent/**`、project-local context、active plan / SOW / prompt、evidence pointer
3. `Product Code`
   - 実際の product code。新規 Revharness project では `src/` が canonical default workspace。adopted / existing projects は compatibility / overlay path として native layout（例: `apps/`, `packages/`, `services/`）を維持してよい

新規 distribution URL、release tag、package coordinates、distribution channel は `TBD` です。overlay 型の `install-harness` / `adopt-harness` / `upgrade-harness` は adoption / upgrade direction として扱いますが、この docs index は publish 済み外部 distribution や tooling completion を主張しません。

## Audience Routing

### 開発者向け

このハーネス自体をカスタムする人は次から読み始めます。

1. `README.md`
2. `docs/manual/developer-customization-guide.md`
3. `docs/manual/common-task-contract.md`
4. `docs/manual/verification-truth-matrix.md`

### ユーザー向け

このハーネスを使って成果物を生み出す人は次から読み始めます。

1. `docs/manual/end-user-guide.md`
2. `docs/manual/harness-user-guide.md`
3. `docs/manual/harness-release-gate.md`
4. `docs/manual/verification-truth-matrix.md`

### エージェント向け

このハーネスを保守・見直し・アップグレードする次のエージェントは次から読み始めます。

1. `AGENTS.md`
2. `.agent_rules/RULES.md`
3. `.agent/PROJECT_CONTEXT.md`
4. `docs/manual/agent-maintainer-guide.md`
5. `docs/roles/orchestrator.md`

## Stable Doc Reading Order

`README.md` と audience guides は入口です。運用判断に必要な stable docs を辿る順序は次です。

1. `AGENTS.md`
2. `.agent_rules/RULES.md`
3. `.agent/PROJECT_CONTEXT.md`
4. `docs/roles/coder.md`
5. `docs/roles/reviewer.md`
6. `docs/roles/orchestrator.md`
7. `docs/manual/verification-truth-matrix.md`
8. `docs/manual/harness-user-guide.md`
9. `docs/manual/harness-release-gate.md`
10. 必要な `docs/design/world-class-harness-roadmap.md`
11. 必要な `docs/prompts/README.md`

## ドキュメントマップ

### Manual

- `docs/manual/end-user-guide.md`: 成果物を作るユーザー向けの最短ガイド
- `docs/manual/developer-customization-guide.md`: ハーネスを拡張・改修する開発者向けガイド
- `docs/manual/agent-maintainer-guide.md`: 次のエージェント向け保守ガイド
- `docs/manual/harness-user-guide.md`: 現在の完成境界、authority、日常運用
- `docs/manual/common-task-contract.md`: common task contract Slice A の current surface
- `docs/manual/verification-truth-matrix.md`: acceptance / LGTM / deterministic checks の正本
- `docs/manual/self-evolution-proposal-queue.md`: HermesAgent-inspired self-evolution proposal queue contract; proposals only, no autonomous mutation
- `docs/manual/skill-routing-matrix.md`: task class -> allowed skill routing contract, provenance rule, and light-path non-escalation invariant
- `docs/manual/harness-release-gate.md`: authoritative release gate と rerun 手順
- `docs/manual/agent_review_loop.md`: coder -> reviewer -> fix -> re-review loop の運用ガイド

### Design

- `docs/design/harness-plugin-boundary.md`: plugin-ready boundary
- `docs/design/harness-plugin-mcp-trust-matrix.md`: plugin / MCP trust matrix
- `docs/design/world-class-harness-roadmap.md`: current roadmap。planned surface はここを読む
- `docs/design/safe-merge-protocol.md`: merge / rollback 設計

### Roles

- `docs/roles/coder.md`: 実装担当の責務
- `docs/roles/reviewer.md`: reviewer contract と出力フォーマット
- `docs/roles/orchestrator.md`: task 分割、handover、completion judgment の責務

### Prompts

- `docs/prompts/README.md`: prompt template の位置づけ
- `docs/prompts/reviewer_batch.md`: batch reviewer prompt template
- `docs/prompts/reviewer_safety.md`: safety reviewer prompt
- `docs/prompts/reviewer_perf.md`: performance reviewer prompt
- `docs/prompts/reviewer_consistency.md`: consistency reviewer prompt

### Skill Packages

- `docs/manual/skill-integration.md`: installed skill package index, no-mirror rule, freshness rule, and update protocol. Skill internals stay under `.claude/skills/*` and `${CODEX_HOME:-$HOME/.codex}/skills/*`; docs link to them rather than duplicating their references, scripts, prompts, or source registries.
  Current package index includes deploy guards, Go/Rust/TypeScript knowledge packs, self-growth proposal triage, and skill naming normalization.

### Other Stable References

- `docs/official-docs-links.md`: 一次情報参照用の公式 docs 集
- `docs/requirements/README.md`: requirements 用の placeholder index。現在ここに書かれた `features.md` / `constraints.md` / `api-spec.md` は repo 上に未作成
- `harness-rust/crates/semantic-mcp/`: semantic MCP runtime（Rust 実装）の reference

## Stable と Volatile の分離

- stable docs: `docs/**`, `README.md`
- dated SOW / handover: `.agent/active/sow/*.md`, `.agent/active/prompts/*.md`
- gate artifacts: `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`; latest pointer: `.claude/tmp/harness-release-gate/latest.json`
- wrapper stderr: `scripts/codex-wrapper.sh`, `scripts/claude-wrapper.sh`, and `.claude/commands/lib/reviewer.sh` callers use run-local `stderr/` directories under `.claude/tmp/**`, with output-adjacent pointer metadata only
- active runtime artifacts: `.claude/tmp/<task>/state.json`, `.claude/tmp/<task>/task-contract.json`

stable docs には日付つき rerun result を固定せず、最新の証跡は volatile 側を参照します。

## 更新ルール

- コードの変更に合わせて関連 docs を更新する
- acceptance を説明する文書は `docs/manual/verification-truth-matrix.md` を優先する
- runtime entrypoint の caller-facing 契約は `AGENTS.md` と wrapper 実装に合わせる
- current state と roadmap を混同しない
- outdated docs は `.agent/archive/docs/` などの適切な場所へ退避する
