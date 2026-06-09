---
name: system-planner
description: Own the reusable planning workflow for Phase 2. Use for planning workflow, ExecPlan drafting, slice planning, scope decomposition.
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: System Planner

Phase 2 の planning と plan handoff はこの skill が所有する。要件整理、スコープ分解、検証方針、次の担当への受け渡しを定義する。

## 使う場面
- ExecPlan が未作成
- 既存 plan が古い、またはスコープ変更で更新が必要
- 調査結果を実装計画へ落とし込みたい

## 期待成果物
- `.agent/active/plan_YYYYMMDD_HHMM_<task>.md`
- 実装/レビューに渡す要約プロンプト
- 依存関係、リスク、検証項目の整理
- required checks の exact command / artifact landing path / completion boundary

## Phase 2 の境界
- `.codex/agents/system_planner.toml` は **native subagent preset**。caller-facing runtime contract ではない。
- 初回設計 / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane を正本とし、`gpt-5.5` + `xhigh` + `cached` で扱う。通常の docs-only / light planning、typo、bookkeeping と混同して `medium` へ落とさない。
- 人や script から Codex を呼ぶ入口は、引き続き `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使う。
- Codex 呼び出し構文そのものは `codex-caller` skill を参照する。

## Planning Contract
- planning 前に `docs/manual/verification-truth-matrix.md` を読み、slice record を作る。
- 各 slice には `in-scope` / `out-of-scope` / `required checks` / `completion boundary` を必ず記録する。
- stable truth は manual / README / skill に置き、session 依存の内容は `.agent/active/plan_*.md` / `.agent/active/sow/*.md` / handoff prompt / `.claude/tmp/**` に置く。
- stable document に dated rerun 結果、個別 run artifact、暫定 blocker を混在させない。
- Codex / Claude Code / prompting / Goal / subagent / skill / hook / settings behavior を変える plan では、`.claude/skills/harness-official-docs-update/SKILL.md` または `research-handoff` の official-docs provenance を先に記録する。
- upstream recommendation は local authority mapping に変換してから slice 化する。公式 docs だけを根拠に wrapper / acceptance / security boundary を上書きしない。

## Deterministic Verification Commands
planner は change surface ごとに、最低でも次の exact commands を plan に書く。

| Change surface | Required commands |
|----------------|-------------------|
| 純粋な説明文書のみ | `git diff --check -- <files>` |
| コマンド、パス、gate、review 条件、運用例を追加・変更する文書 | `git diff --check -- <files>` と、追加・変更した参照先ごとの `test -e <path>` |
| script / wrapper / 実行入口 | `git diff --check -- <files>`、`bash -n <file>`、変更した入口の非破壊 help / syntax / existence probe |

- planner は `<files>` と `<path>` を省略せず、実際の対象ファイルに展開したコマンドを残す。
- command / script 契約に触れる slice では、`bash <script> --help` のような非破壊 probe も required checks に含める。
- release gate が必要な surface は、補助 gate ではなく `bash test/integration/harness_release_gate.sh` を authoritative gate として記録する。

## Artifact Landing Paths
- slice 定義、required checks、completion boundary: `.agent/active/plan_YYYYMMDD_HHMM_<task>.md`
- 実行中の blocker、rerun 判断、補足 evidence: `.agent/active/sow/*.md`
- reviewer / coder への handoff 文面: `.agent/active/prompts/*.md`
- command stdout / stderr などの run artifact: `.claude/tmp/**`

## Checkpoint Blockers
- broad task が未分解で、scope-bounded slice を定義できない
- required checks の exact command が書けない
- artifact landing path が決まっていない
- stable と volatile の置き場が混在している
- 環境制約で required checks を実行できないのに reroute / block 方針が未記録

上記のいずれかがある場合、planner は completion boundary を開けず `BLOCK` として返す。

## 運用メモ
- Claude Orchestrator の effort 既定値は `medium`。
- 軽量な plan 整形なら Codex は `--role standard` を検討できる。ただし初回 ExecPlan 設計、mutation-authorizing ExecPlan drafting、ExecPlan review planning は native `system_planner` / `plan_reviewer` の xhigh lane を使う。
- 外部の不確実性が残る場合は `research-handoff` を先に通す。

## 参照
- `docs/manual/verification-truth-matrix.md`
- `docs/roles/orchestrator.md`
- `.claude/skills/auto-orchestrator/SKILL.md`
- `.claude/skills/codex-caller/SKILL.md`
- `.claude/skills/harness-official-docs-update/SKILL.md`
