---
name: baseline-protection
description: Ensure baseline stability across coder→reviewer cycles. Use pre-write prompt pair + pre-touch output stub + no-write-during-agent to prevent orchestrator write amplification from causing baseline stale.
---

# Skill: Baseline Protection

## When to use
- slice 起票時
- coder と reviewer を順次呼ぶすべてのケース
- 特に dirty worktree 上、fix-review loop、複数 agent 並列実行時

## Why
orchestrator が coder 起動後に reviewer prompt を書くと、reviewer が live `git status` を取った瞬間に coder snapshot との差分が発生し、`baseline stale` 判定で CHANGES REQUIRED になる。

## Protocol
1. pre-write prompt pair: coder prompt と reviewer prompt を同時に orchestrator 1 ターンで書き出す。
2. pre-touch output stubs: coder output file と reviewer output file を 0 bytes で `touch` する。
3. coder 起動 -> 完了 -> reviewer 起動の間、orchestrator は一切書き込まない。
4. reviewer 自身の output file は baseline 比較から reviewer own activity として除外することを reviewer prompt に明記する。
5. coder 自身の output file は `dirty_sha256.txt` から除外する。

## Automation
`./.claude/commands/lib/baseline_freeze.sh` を使う。
- `snapshot <evidence_dir>`: `git status --porcelain=v1` と SHA-256 を保存
- `pretouch <path>`: output stub を事前作成
- `verify <evidence_dir> --exclude <path>`: reviewer output などを除外して baseline 差分を検証

## Fallback
primitive 未起動ならマニュアル運用に戻し、本 skill の 5 steps をそのまま手順書として使う。

## References
- `$CLAUDE_HOME/projects/<project-slug>/memory/feedback_baseline_protection_pattern.md`
- `.agent/active/prompts/reviewer_wsA_execution_s1_provenance_v2_output.md`
