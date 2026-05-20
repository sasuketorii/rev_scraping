---
name: review-workflow
description: Own the reusable review and fix loop for Phase 2.
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: Review Workflow

Phase 2 の review/fix loop はこの skill が所有する。`auto-orchestrator` はここへルーティングし、実行面は `./.claude/commands/auto_orchestrate.sh` が担う。

## 使う場面
- 実装後に Codex reviewer を走らせたい
- 指摘を集約し、修正して再レビューしたい
- `--fix-until` 基準で完了判定したい

## 固定契約
- Reviewer は常に `scripts/codex-wrapper.sh --role reviewer`。
- `codex-wrapper-medium.sh` / `high.sh` / `xhigh.sh` は互換 shim であり、review 手順の primary guidance にはしない。
- 自動運用では常に新規セッションで回す。`--resume` は手動 TTY 専用。
- レビュー出力形式は `docs/roles/reviewer.md` の `Code Review Report` テンプレートに統一する。
- 指摘ゼロでもテンプレートは省略しない。`## Findings` は `- None.` とし、`## Verdict` は Acceptance Gate と Verdict Rules に従って決める。

## Claude / Opus Review Auth Guard

Root cause: `claude -p --bare ...` は Claude.ai OAuth/keychain login を無視し、API key または `apiKeyHelper` を要求する。OAuth/keychain 認証で補助的な Claude/Opus review を非対話実行する場合、`--bare` を既定にしない。

Safe direct invocation:

```bash
claude -p \
  --model opus \
  --no-session-persistence \
  --allowed-tools Read,Grep,Glob \
  --permission-mode dontAsk \
  --max-budget-usd 5 \
  < review_prompt.md > opus_review.md
```

- `--bare` は `ANTHROPIC_API_KEY` または明示的な `apiKeyHelper` 設定がある場合だけ使う。
- `--bare` を使う caller は、必要な context/config をすべて自分で供給する。
- `scripts/claude-wrapper.sh` 経由では、API-key auth が確認できない `--bare` は fail-closed になる。

## Acceptance Gate
- acceptance / verdict の正本は `docs/manual/verification-truth-matrix.md`。
- reviewer が `LGTM` を出せるのは、scope-bounded slice で required deterministic checks が実行済みかつ証跡が明示されている場合だけ。
- required machine checks のコマンド、結果、artifact path、対象 slice / hunk が追跡できない場合、verdict は `LGTM` ではなく `Needs verification` にする。
- wrapper 準拠、review 実施、reasoning-only の妥当性判断は acceptance の代替証拠にならない。
- Codex / Claude Code behavior update の review では、official-docs provenance と local authority mapping を review input として確認する。ただし upstream docs 参照は acceptance truth ではなく、matrix と deterministic evidence の代替にならない。

## Scope Boundary
- review scope は current slice に限定し、変更ファイル・変更 hunk・completion boundary を先に確定する。
- slice 外の未変更領域を新規 acceptance gate に昇格させない。
- same-file mixed diff がある場合は、coder 担当 hunk、required checks の適用範囲、未担当差分の有無を明示的に disclosure する。
- mixed diff の ownership が曖昧なまま、または reviewer が対象 hunk を特定できないまま `LGTM` を出さない。

## ループ
1. diff、slice record、required checks、テスト結果、coder 出力、前回レビューを集める。
2. review scope と same-file mixed diff の有無を確認し、scope 外は明示的に除外する。
3. reviewer を必要数だけ並列実行する。
4. 重大度別に集約し、`--fix-until` 基準と acceptance gate で判定する。
5. 未解決があれば coder に戻す。`--run-coder` がなければ paused にする。
6. 必要な deterministic checks を再実行し、証跡を更新してから再レビューする。

## 出力
- `.claude/tmp/<task>/<phase>_review_*.md`
- `.claude/tmp/<task>/<phase>_reviews.md`
- `.claude/tmp/<task>/state.json`
- review report 内の `Required Verification` / `Evidence Reviewed`

## Verdict Rules
- `LGTM`: required checks が PASS で、artifact path と review scope が追跡可能。
- `Request Changes`: scope 内に未解決の blocker / defect がある。
- `Needs verification`: required checks が未実行、失敗、skip、結果不明、artifact 不明。
- `Needs Discussion`: slice boundary や acceptance 条件に未解決の論点がある。

## 参照
- `docs/manual/verification-truth-matrix.md`
- `docs/roles/reviewer.md`
- `docs/manual/agent_review_loop.md`
- `.claude/commands/README.md`
- `.claude/skills/codex-caller/SKILL.md`
