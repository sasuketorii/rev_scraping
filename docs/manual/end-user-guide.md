# End User Guide

## 誰向けか

この文書は、このハーネスを使ってアプリケーションや機能を生み出すユーザー向けです。ハーネス自体を改造するのではなく、正しい入口を使って成果物を作ることが目的です。

## 最初に読む文書

1. `README.md`
2. `docs/manual/harness-user-guide.md`
3. `docs/manual/harness-release-gate.md`
4. `docs/manual/verification-truth-matrix.md`

## 日常フロー

1. 目的に対応する ExecPlan を確認する
2. `./setup/bootstrap.sh --check-only` で前提を確認する
3. `./scripts/resolve-semantic-project-id.sh --print` で `project_id` を確認する
4. 必要なら `./scripts/hydra new <task-name>` で worktree を切る
5. `./.claude/commands/auto_orchestrate.sh --plan <plan> --phase impl --run-coder` を使う
6. `.claude/tmp/<task>/task-contract.json` と `.claude/tmp/<task>/state.json` を確認する
7. 最後に slice-local checks と `bash test/integration/harness_release_gate.sh` を回す

## よく使うコマンド

- `./setup/bootstrap.sh --check-only`
- `./scripts/resolve-semantic-project-id.sh --print`
- `./scripts/codex-wrapper.sh --role coder --stdin`
- `./scripts/claude-wrapper.sh --output <file> "prompt"`
- `./scripts/hydra new <task-name>`
- `./.claude/commands/auto_orchestrate.sh --plan <plan> --phase impl --run-coder`
- `bash test/integration/harness_release_gate.sh`

## 重要な artifact

- `.agent/active/plan_*.md`: current plan
- `.claude/tmp/<task>/task-contract.json`: current orchestrated run の contract
- `.claude/tmp/<task>/state.json`: current run state
- `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`: gate run evidence; latest pointer is `.claude/tmp/harness-release-gate/latest.json`
- wrapper / reviewer stderr: run-local `stderr/` directories under `.claude/tmp/**`, with only `*.stderr-pointer.txt` metadata near user-facing outputs

## 信じてよいもの / だめなもの

信じてよいもの:

- `docs/manual/verification-truth-matrix.md`
- `docs/manual/harness-release-gate.md`
- current plan / current SOW / latest gate artifact

信じてはいけないもの:

- 古い dated handover を current truth だと思うこと
- `.claude/tmp/**` の scratch JSON を durable authority だと思うこと
- roadmap 上の planned feature を current implementation だと思うこと
- `README.md` の summary だけで acceptance を判断すること
