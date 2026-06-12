# Developer Customization Guide

## 誰向けか

この文書は、このハーネス自体をカスタム、拡張、改修する開発者向けです。成果物を作るユーザーではなく、Revharness / `rev_harness` の behavior を変える側を対象にします。`agent_base` / `agent-base` は legacy alias として扱います。

## Canonical Operating Model

Revharness v0.11.0 の canonical operating model は source-centric です。新規 Revharness project では、実際の target system / product code を `src/` 配下で開発することを既定にします。`agent_base` / `agent-base` は既存 checkout、古い install、migration detection、検索性のための legacy alias であり、新しい canonical identity ではありません。

変更判断は次の 3 層で切り分けます。

1. `Framework / Core Harness`
   - wrapper、commands、policy docs、CI gate、integration surface
2. `Project State`
   - `.agent/**`、project-local context、active plans、SOW、prompt、evidence pointer
3. `Product Code`
   - 新規 Revharness project の既定配置は `src/`。adopted / existing projects は compatibility / overlay path として project-native layout を維持してよい

外部 GitHub URL、release tag、package coordinates、distribution channel は `TBD` です。この guide が扱うのは operating model の canonicalization までであり、installer / upgrader tooling の実装、publish、tag、package release は含みません。

## 最初に読む文書

1. `README.md`
2. `docs/README.md`
3. `AGENTS.md`
4. `.agent_rules/RULES.md`
5. `.agent/PROJECT_CONTEXT.md`
6. `docs/manual/common-task-contract.md`
7. `docs/manual/verification-truth-matrix.md`

## 日常フロー

1. change surface を narrow slice に分解する
2. ExecPlan を切る
3. required checks と completion boundary を先に固定する
4. docs / scripts / tests を current truth に合わせて更新する
5. `git diff --check` と relevant deterministic checks を回す
6. reviewer evidence を揃えて closeout する

## 公式ドキュメント起点の更新

Codex / Claude Code / prompting / subagent / skill / hook / wrapper / Goal workflow に関わる Revharness behavior を変える場合、実装前に `.claude/skills/harness-official-docs-update/SKILL.md` を通す。

基本順序:

1. `docs/official-docs-links.md` の OpenAI / Anthropic 公式リンクから該当ページを確認する。
2. plan / SOW / research handoff に、参照した公式ページと適用判断を記録する。
3. 公式推奨をそのまま runtime truth にせず、Revharness の local authority へ割り当てる。
4. wrapper / role / skill / common task contract / acceptance matrix のどの層を変えるかを明示する。
5. `docs/manual/verification-truth-matrix.md` の acceptance / LGTM / completion truth を upstream workflow 機能で上書きしない。

Codex Goal、Claude Code subagents、OpenAI prompt guidance のような upstream workflow 機能は、まず Contract Envelope / durable artifact / deterministic evidence のどこへ写像するかを決めてから実装する。

## よく見る設計文書

- `docs/design/harness-plugin-boundary.md`
- `docs/design/harness-plugin-mcp-trust-matrix.md`
- `docs/design/safe-merge-protocol.md`
- `docs/design/world-class-harness-roadmap.md`

## 重要な current behavior

- external / manual Codex runs は `scripts/codex-wrapper.sh --role ...` が canonical
- automatic flow は non-interactive invariant を守る
- current orchestrated coder run は `task-contract.json` を emit / validate してから進む
- semantic MCP は core から auto-start しない。使う場合は semantic addon を明示 enable し、Claude / Codex の config を `scripts/ci/addon-absent-or-compliant-check.sh --semantic` で検証する
- semantic preflight / capsule は target-lock / ambiguity / duplicate-risk を signal として出す

## 触る前に注意すること

- `verification-truth-matrix` を wrapper 契約で上書きしない
- roadmap と implemented state を混同しない
- `semantic.db` を tmp/export と同列に扱わない
- role docs と README の summary が衝突したら、authority 側から直す

## 主要コマンド

- `git diff --check -- <files...>`
- `bash test/integration/harness_release_gate.sh`
- `bash test/integration/common_task_contract_smoke.sh`
- `( cd harness-rust && cargo test -p semantic-mcp )`
