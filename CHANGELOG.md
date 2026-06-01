# Changelog

All notable changes to this project are documented in this file.

## [0.0.17] - 2026-05-21

### Changed — §16.8 strict-grading R2/R3 closure + version-ref accuracy

Iterative refinement of README §16.8 driven by Opus 4.7 xhigh × Codex
gpt-5.5 xhigh strict 10-axis grading rounds:

- **R2 (commit 0bf5cc6)**: closed the 3 must-fix items from R1 grading
  (slice-designer xref backed by canonical source, sentinel-write
  detection step, Lane A–E vocabulary defined, CHANGELOG audit
  pointers added). Both graders → 93/100.
- **R3 (commit 085ca21)**: closed the 1 shared nice-to-have (ps etime
  awk regex now correctly excludes HH=00 sub-hour processes,
  preventing false positives in the hang-detection fallback).
  Verified with 5-input simulation (05:23, 00:05:23, 01:23:45,
  12:34:56, 1-02:00:00 → no/no/yes/yes/yes). Both graders → ~97/100.
- **R4 (commit ef3129d)**: added a real `REV_HARNESS_DELEGATION_METRIC`
  JSON sample under detection step 2 (3-line comment block, schema:
  `delegation_id` / `wrapper_role` / `exit_code` / `duration_ms` /
  `dry_run`, dated 2026-05-21) so fresh adopters can recognize the
  expected wrapper output without guessing. Promoted
  `incident context (語彙定義)` from bold paragraph to `####` heading
  to match sibling §16.8 subsections.

### Fixed
- §16.8 "既知 (まだ自動化していない)" labels referenced "(0.0.17 候補)"
  but 0.0.17 IS this release — corrected to "(0.0.18 候補)" so the
  forward-debt pointer accurately tracks what is deferred vs shipped.

### Why this matters
- Locks in the canonical Codex CLI bail-out diagnostic across two
  independent strict gating passes (Opus + Codex both reach ≥ 95+ on
  all 10 axes for the section).
- Demonstrates the RevHarness "review-driven iteration" pattern in
  practice: ship → strict grade → close gaps → re-grade until
  convergence. Audit trail is the proof; each round's grading prompt
  and verdict file is committed.

### Audit trail (this release)
- `.agent/active/prompts/grade_016_strict.md` (R1/R2 grading prompt)
- `.agent/active/prompts/grade_017_round3.md` (R3/R5 grading prompt)
- `.claude/tmp/multi-repo-sync/codex_016_strict_grade.md` (Codex R1)
- `.claude/tmp/multi-repo-sync/codex_016_strict_grade_r2.md` (Codex R2)
- `.claude/tmp/multi-repo-sync/codex_017_grade_r3.md` (Codex R3)
- `.claude/tmp/multi-repo-sync/codex_017_grade_r5.md` (Codex R5)
- `.claude/tmp/multi-repo-sync/codex_017_grade_r7.md` (Codex R7)
- `.claude/tmp/multi-repo-sync/codex_017_grade_r8.md` (Codex R8 — final)

Iteration converged at R8 (commit 11ad1d7) with the R6 self-referential
"to be appended" TODO at line 51 of the draft resolved in-place. Per
the lessons of R7 (which introduced a stale future-tense pointer while
fixing the previous one) and R8 (which repeated the same anti-pattern
one round downstream), **this CHANGELOG entry intentionally does not
predict any future grading round**. The artifact paths above are the
canonical evidence; any future re-grading writes into a new file and
is recorded by amending or superseding this entry, not by leaving a
forward TODO in the shipped release notes.

### Deferred to 0.0.18 (next release)
- wrapper-side prompt-size pre-check (≥ 5 KB × `high` effort warn /
  strict-mode fail-close)
- `harness-doctor --strict` integration of the hung-lane scan
- Plus the cyber_tomo / agent_base etc. cross-project path leak
  pattern table (audit-driven from the 0.0.15 history sanitization
  Codex verdict).

## [0.0.16] - 2026-05-21

### Added — Codex CLI bail-out troubleshooting

- **README §16.8** "Codex CLI が計画文 1 行だけ吐いて exit / 実装 0
  ファイル": new troubleshooting entry documenting the Codex CLI
  silent-no-op failure mode discovered during 2026-05-21 multi-lane
  orchestration. Trigger conditions (prompt ≥ 5-7 KB × `high` effort
  × self-driven multi sub-phase), detection commands (sentinel-write +
  mtime + size + etime-based hang scan + `REV_HARNESS_DELEGATION_METRIC`
  presence check), and 3-step remediation (prompt splitting, mixed-model
  fallback to Claude Opus for long prompts, canonical wrapper enforcement).
- **`docs/roles/orchestrator/specialties/slice-designer.md` §"Prompt
  size budget per sub-phase"**: new normative section codifying the
  **≤ 2 KB per sub-phase** prompt budget and the **>5 KB × `high`
  effort hard reject** rule. Re-projected to `.claude/skills/
  slice-designer/SKILL.md` via `agent-core specialty project`. This is
  the canonical authority §16.8 cross-references; the audit gap from
  the Opus×Codex grading round on 0.0.16 (slice-designer xref claim
  unbacked) is now closed.

### Why this matters

- The 2026-05-21 incident (rev_harness session, internally labeled
  Lane A through Lane E) showed Codex CLI hanging silently 12+ hours
  on one lane and exiting with 1 plan-line / 0 implementation on
  another. Both were Codex CLI behavior (not RevHarness), but
  RevHarness adopters need a documented diagnostic to catch this fast
  next time.
- Codifies the canonical mitigation already implied by
  `docs/roles/reviewer.md` (reviewer = Codex 固定) and now made
  explicit in the slice-designer specialty (≤ 2 KB per sub-phase):
  when you hit this failure mode, you are off the canonical RevHarness
  recipe.
- §16.8 also flags two automation candidates for 0.0.17:
  wrapper-side prompt-size pre-check, and integration of the
  hung-lane scan into `harness-doctor --strict`.

### Audit trail (this release)

- Grading prompt:
  [`.agent/active/prompts/grade_016_strict.md`](./.agent/active/prompts/grade_016_strict.md)
  (10-axis strict rubric, Opus 4.7 xhigh × Codex gpt-5.5 xhigh).
- Initial verdict (109579b): Opus 78 / Codex 83 — LGTM-with-nits.
  3 shared must-fix items identified.
- Revision (this commit): all 3 must-fix items resolved:
  1. slice-designer canonical source now documents ≤ 2 KB budget
     (xref claim backed).
  2. §16.8 incident-context paragraph defines "Lane A–E" terminology
     so fresh adopters can parse the section without internal context.
  3. CHANGELOG entry (this block) carries explicit audit-artifact
     pointers per 0.0.15 entry precedent.
- Re-grading round target: both graders ≥ 90 / 100. See
  `.claude/tmp/multi-repo-sync/codex_016_strict_grade.md` (Codex) and
  conversation transcript (Opus) for the revised scores.

## [0.0.15] - 2026-05-21

### Added — history sanitization hardening (Opus × Codex verdict)

Following the 2026-05-21 substantive debate between Opus 4.7 xhigh and
Codex (gpt-5.5 xhigh) on whether to rewrite the rev_harness git history
to remove pre-0.0.13 personal info, the verdict was **Option C: preserve
history** based on:

- 0 real secrets in the 107-commit history (`sk-ant-*`, `AKIA*`,
  `ghp_*`, private keys all empty).
- Private repo + 0 forks → blast radius bounded by GitHub access control.
- Surgical filter-repo coverage risk = HIGH (audit under-counted
  cross-project path leaks 6×: agent_base, claude_skills_base,
  contact_dev, rev_builder, rev_frontend, cyber_tomo).
- Just-in-time sanitization at client handoff is the correct lifecycle
  point.

Three reversible hardenings shipped instead of destructive operations:

- **`scripts/rev-harness-path-leak-guard.sh`**: pre-commit-style guard
  that blocks staged changes introducing `/Users/<user>/dev/` or
  `/home/<user>/dev/` absolute paths. Existing leaks are grandfathered
  (the guard only inspects `+added` lines from `git diff --cached`).
  Opt-in marker `# rev-harness-path-leak-guard: allow` for legitimate
  fixture cases.

- **`scripts/install-rev-harness-hooks.sh`**: idempotent installer that
  wires `.git/hooks/pre-commit` to delegate to path-leak-guard +
  existing secret-guard. `--status` / `--uninstall` supported.

- **`docs/manual/client-export-runbook.md`**: canonical runbook for
  producing a clean tarball / fresh repo at distribution time
  (`git archive` → fresh init → tag 1.0.0). Documents what to strip
  (`.agent/active/prompts/`, `.claude/tmp/`, build artifacts) and what
  to keep (`docs/`, skills, rules). Per-client redaction stub included.

### Changed
- Local git config now uses `128899873+sasuketorii@users.noreply.github.com`
  instead of the auto-derived `maintainer@localhost`. New
  commits will no longer leak the macOS hostname. Historical author
  lines (102/107 commits) are unchanged.

### Why this matters
- Stops the leak surface from growing on every new commit.
- Provides a documented escape valve (path-leak guard) so adopters of
  RevHarness who copy these scripts into their own repos get the same
  hygiene by default once they run `install-rev-harness-hooks.sh`.
- Makes "client distribution" a 5-minute runbook execution instead of a
  destructive force-push to upstream.

### Audit trail
- `.claude/tmp/multi-repo-sync/codex_history_sanitize_debate.md`:
  full Codex grading + verdict (350+ lines).
- `.agent/active/prompts/debate_history_sanitize_strategy.md`: the
  debate prompt that drove the decision.

## [0.0.14] - 2026-05-21

### Added (documentation)
- **README section 4 "Runtime Data Plane"**: new ~180-line architecture
  deep dive covering the two parallel SQLite db systems (Rust canonical
  16-table + Node legacy 7-table), `project_id` namespace isolation
  with concrete path tree, the `application_id=0x5253454D` (RSEM)
  marker mechanism, and an ASCII sequence diagram showing the full
  wrapper-invocation call flow (guard → MCP server startup →
  `sem.context.top_k` → `context_token` → `sem.capsule` → metrics).
- **README section 6.3 "本格運用前のフル準備"**: explicit step-by-step
  for adopters covering `semantic-bootstrap.sh`, `agent-core context
  update`, `agent-core context index-symbols`, plus a `sqlite3` sanity
  check on the `symbols` table.
- **README section 16 "Operator Troubleshooting"**: 7-sub-section
  symptom-to-recipe table (sem.* empty, advisory identity-check,
  strict fail-close on invalid id, doctor UNKNOWN, disk usage,
  dependency missing, launch-semantic-mcp.sh immediate exit). Each
  row points at the diagnosis command and the minimal fix.

### Changed
- Renumbered sections 5-17 (was) to 5-19 (now) to accommodate the new
  section 4. TOC and intra-document anchor links updated to match.

### Why this matters
- The pre-0.0.14 README catalogued *what existed* (crates, scripts,
  skills, test counts) but did not document *how the runtime actually
  flows*. Adopters who hit "sem.* returns nothing" or "table missing"
  had no in-tree diagnostic recipe. Section 16 is built directly from
  the 0.0.12 -> 0.0.13 multi-repo rollout incidents.
- The two-db reality (Rust canonical at Library path + Node legacy at
  `~/.semantic-mcp/`) was a tribal-knowledge fact. Now first-class.
- `application_id=RSEM` was mentioned once buried in section 6.2 tool
  table. Now explained as a deliberate safety mechanism.

## [0.0.13] - 2026-05-21

### Added
- **`scripts/semantic-bootstrap.sh`**: explicit, idempotent bootstrap
  for the Node semantic-mcp layer's SQLite db. Builds
  `scripts/semantic-mcp-server/dist/` if needed, triggers the auto-
  migration that previously only fired on first ad-hoc CLI use, then
  verifies the 7-table registry schema (`capsules`, `components`,
  `outbox_queue`, `projects`, `registry_deltas`, `review_queue_items`,
  `review_runs`). `--json` for CI use, `--skip-build` for repeat runs.
  Sources canonical-guard so respects 0.0.12 identity-check semantics.
- **`.claude/skills/semantic-bootstrap/SKILL.md`**: documents when
  adopters / re-syncers should run the bootstrap, the two-implementation
  reality (Node registry db vs Rust index/capsule db), and the known
  Rust-side gap (no analog bootstrap yet).

### Fixed (gap closure)
- 0.0.12 and earlier auto-migrated the Node semantic-mcp schema on
  first CLI invocation only, leaving adopters who never touched the
  CLI with a stale 4-table symbol-only db. Symptoms: `sem.*` calls
  returning empty / "no such table", queue/review surfaces silently
  reporting `pending_count: 0`. `semantic-bootstrap.sh` makes the
  migration step explicit and verifiable. This was a real harness
  gap surfaced during the 0.0.12 multi-repo rollout.

### Known gap (tracked, not closed)
- The Rust semantic-mcp under `harness-rust/crates/semantic-mcp/` has
  its own db path (`Library/Application Support/Revharness/semantic-
  mcp/v1/<project_id>/` on macOS) and its own implicit "migrate on
  first use" behavior. `semantic-bootstrap.sh` does not touch it.
  Documented in the skill as a TODO for a future
  `--include-rust` flag.

## [0.0.12] - 2026-05-21

### Changed
- **canonical-guard default-warn (Option E_new resolution)**: Opus 4.7 ×
  Codex (gpt-5.5 xhigh) substantive debate verdict LGTM-to-implement.
  Runtime guard no longer fail-closes adoption use cases:
  - `ambiguous-copy` (revharness-* project_id outside official source
    checkout): default WARN (advisory, exit 0). Strict mode is opt-in via
    `REV_HARNESS_VENDOR_CHECK=strict`.
  - `invalid` (missing / malformed project_id): default STRICT (exit 70).
    `REV_HARNESS_VENDOR_CHECK=warn` downgrades for debug/migration.
    Asymmetry rationale: identity-dependent downstream (semantic-mcp DB
    namespace / queue / capsule) breaks before the user sees what went
    wrong if setup error is silenced.
  - `canonical-dev` (path or official remote match) and `managed-adopter`
    (non-revharness-* valid id): silent pass, unchanged.
- Neutralized warning wording from `VENDOR GUARD` / `ambiguous RevHarness
  identity` → `identity-check (advisory|strict)`. Adopters are no longer
  told their copy is being treated as theft.

### Added
- `scripts/harness-doctor.sh --strict`: sources the canonical-guard and
  fail-closes on identity-class violations. Use on release-gate / CI
  surfaces while runtime wrappers stay advisory by default.
- `test/integration/harness_release_gate.sh` entrypoint now exports
  `REV_HARNESS_VENDOR_CHECK="${REV_HARNESS_VENDOR_CHECK:-strict}"` so
  release acceptance is the canonical strict surface; user override is
  preserved.
- `test/unit/test-canonical-guard.sh` rewritten for new semantics
  (14 cases: path / managed-adopter silent / ambiguous default-warn /
  ambiguous strict fail / invalid default-strict / invalid warn-downgrade
  / control-char / multiline / unknown-VENDOR_CHECK fallback /
  mixed-char id / official-remote silent / wording neutralization).

### Migration
- No env var rename. `REV_HARNESS_VENDOR_CHECK` retained; default is now
  `warn`. Existing CI that already exports `strict` is unaffected.
- Adopters who copied RevHarness into a project with `revharness-*`
  project_id and were blocked at exit 70 will now see an advisory
  message instead. Recommended remediation remains
  `scripts/init-project.sh` to bootstrap a target identity.

### Verification
- `test/unit/test-canonical-guard.sh`: 14/14 pass.
- `test/unit/test-cursor-wrapper.sh`: 30/30 pass (regression).
- env-less `bash scripts/codex-wrapper.sh --role coder --dry-run`:
  exit 0, no identity-check wording leak (canonical-dev path).
- Codex grade of implementation vs E_new design verdict: 9.4 / LGTM
  (must_fix empty). `.claude/tmp/multi-repo-sync/codex_guard_012_grade.md`.

## [0.0.6] - 2026-05-14

### Added
- gpt-5.5-high × 5並列監査 (codex-job.sh dogfood) を実施、検出した CRITICAL 2 + HIGH 18 を一掃
- `scripts/codex-job.sh` の境界テスト: X15f (wait --timeout 0/1), X15g (gc --ttl 入力検証), X15h (path traversal 防御)
- `scripts/shim-hits-rotate.sh` 新設 (ログローテーション、--max-size / --keep / cron 例)
- `.github/CODEOWNERS` 新設 (private リポ owner 設定、wrapper/guard/test/policies/CI を @sasuketorii 配下)
- `docs/mid-review-template.md` 新設 (6/14 中間レビュー雛形、shim-hits 集計手法 + Plan v3 判定マトリクス)
- `docs/release-notes/0.0.3.md` / `0.0.4.md` / `0.0.5.md` 新設 (GitHub Releases 用素材)
- `docs/plans/2026-05-perfecting-harness/plan-v5.md` (本リリースの起案 Plan)
- CHANGELOG に 0.0.2 entry 追加 (歴史補完)

### Fixed
- **codex-job.sh exit_code race condition**: tmp + mv の atomic rename に修正
- **codex-job.sh PID reuse 判定順序**: exit_code ファイル先確認 → pid_alive の順に変更、PID 再利用で永続 running になる問題を解消
- **codex-job.sh wait --timeout 0/1 境界**: 完了済 job → exit 0、未完了 + timeout=0 → exit 124、sleep min(remaining, POLL_INTERVAL) に修正
- **codex-job.sh gc --ttl 入力未検証**: `^[0-9]+$` 検証 + 上限 365日、違反は EX_USAGE (exit 64)
- **codex-job.sh gc rm 失敗ハンドリング**: rm 失敗時も継続、`deleted=N failed=M` サマリ出力
- **codex-job.sh start --timeout 削除**: help にあるが未実装の引数を削除 (実装は 0.0.7+ で再検討)
- **codex-job.sh path traversal 防御**: job-id 正規表現 `^[0-9a-f]{16,32}$`、realpath で RUN_DIR/jobs/ 配下に閉じ込め
- **CI 失敗 (since 0.0.4)**: `.github/workflows/ci.yml` の harness-release-gate job に `REV_HARNESS_CANONICAL_ROOT: ${{ github.workspace }}` を設定。canonical-guard が CI runner clone path を vendored と誤判定して exit 70 する問題を修正

### Security
- **codex-job.sh artifact 権限強化**: `umask 077` 適用、jobs/<id>/ を 700、各ファイル (cmd/prompt/pid/log/exit_code/status.json) を 600
- **prompt 非永続化**: jobs/<id>/prompt は job 完了時に rm、`--keep-prompt` 明示 opt-in で保持

### Changed
- `docs/shim-spec.md` schema に optional `job_id` フィールド追加、`REV_HARNESS_SHIM_HITS_LOG` / `REV_HARNESS_SHIM_JOB_ID` 環境変数を明文化、`rewrite_target` を enum 化 (task-tool | codex-job-start)
- `README.md` の Codex role 一覧に `high-coder` を追加 (AGENTS.md と整合)
- `README.md` の claude-wrapper.sh 説明を「Canonical Claude wrapper」→「deprecated compatibility shim」に統一
- `docs/migration-agent-sdk-2026-06.md` の shim 期間と shim-hits.log retention を分離記述 (shim 期間 30日、retention 60日)
- `CHANGELOG.md` の `Migration notes` → `Migration` に表記統一
- `scripts/claude-wrapper.sh` のヘッダコメントを「DEPRECATED COMPATIBILITY SHIM」に統一

### Compatibility
- `scripts/codex-wrapper.sh` の API 表面無変更
- 既存 matrix test X1-X14b + X15a-e は全件 PASS 維持 (23/23 PASS、X15f-h 追加)
- `REV_HARNESS_VENDOR_CHECK=warn` soft-mode 利用可能 (削除は次のマイナー候補に維持)
- CI 環境変数 `REV_HARNESS_CANONICAL_ROOT` は CI でのみ必要、ローカル既存ユーザーは無影響

### Deferred to 0.0.7+
- codex-wrapper `-c` の allowlist 化 (Audit-2 HIGH-1、破壊的変更で X14c+ テスト追加必要)
- claude-wrapper `--add-dir` / `--mcp-config` の allowlist 化 (Audit-1 HIGH-3 + Audit-2 HIGH-2、同様に破壊的)
- 各 wrapper の trap cleanup 統一 / exit code 統一 / dependency platform matrix / community profile / ROADMAP
- 詳細: `docs/plans/2026-05-perfecting-harness/plan-v5.md` §4

## [0.0.5] - 2026-05-14

### Added
- `scripts/codex-job.sh` 新設 — 非同期 codex ジョブマネージャ。start/status/wait/result/gc サブコマンド、ULID風 18桁 job-id、`~/.rev_harness/jobs/<id>/` 配下に cmd/pid/log/exit_code/status.json を atomic write
- shim-hits.log への job_id フィールド紐付け (オプショナル、`REV_HARNESS_SHIM_JOB_ID` 環境変数経由)
- `test/integration/cross_agent_wrapper_matrix_test.sh` X15a-e (start+status / wait block / wait timeout / gc 並列 / shim-hits join)
- `docs/adoption-guide.md` §8 "Long-running codex execution" セクション
- `docs/plans/2026-05-reporting-reliability/plan-v4-final.md` (採用案: Option A + C ハイブリッド)

### Changed
- README Quickstart に codex-job.sh 例追加

### Fixed
- Claude Code orchestrator の sub-agent が codex-wrapper.sh 同期実行を polling 待ちして token 予算枯渇 → レポート脱落する問題を構造的に解決 (codex-job.sh の非同期パターンを推奨)

### Compatibility
- `scripts/codex-wrapper.sh` の API 表面は無変更
- `scripts/_shim-log.sh` の既存フィールド 6つ (ts/caller_hash/pid/ppid/rewrite_target/argv_hash) は無変更、job_id は backward-compatible にオプショナル追加
- 既存 X1-X14b matrix 全件 PASS 維持
- `REV_HARNESS_VENDOR_CHECK=warn` (soft mode) は 0.0.5 でも利用可能。0.0.4 で告知した「0.0.5 削除」は運用フィードバック取得のため次のマイナーに延期。matrix X14b 継続維持

## [0.0.4] - 2026-05-14

### Added

- VENDOR GUARD: `scripts/_canonical-guard.sh` 新設、`claude-wrapper.sh` / `codex-wrapper.sh` が非 canonical install 配下からの起動を refuse (exit 70)
- `scripts/harness-doctor.sh --check-vendoring [--path <p>] [--allow-vendored]` サブコマンド (sha256/inode 比較で vendored copy 検出、exit 70/71)
- `docs/adoption-guide.md` 新設 (PATH-based install、CI 設定、submodule 例外、FAQ)
- `test/integration/cross_agent_wrapper_matrix_test.sh` X14/X14b (vendoring refuse の regression test)
- `test/integration/rev_harness_doctor_vendoring_test.sh` 新設 (doctor 単体テスト 4ケース)

### Changed

- `README.md` に "Installation: PATH-based use only (DO NOT VENDOR)" セクション追加

### Security

- 物理コピー vendoring を構造的に refuse、`REV_HARNESS_VENDOR_CHECK=warn` 経由の soft-mode escape hatch のみ提供 (次のマイナーで削除予定)

### Migration

- 既存ユーザー (`~/dev/rev_harness` clone + PATH export) はゼロ変更で 0.0.4 動作
- 非標準 install location の場合は `REV_HARNESS_CANONICAL_ROOT` を export
- CI/CD では runner clone path を `REV_HARNESS_CANONICAL_ROOT` に明示 set 必須

### Deprecated

- `REV_HARNESS_VENDOR_CHECK=warn` (soft mode escape hatch) は次のマイナーで削除予定。恒久利用不可

## [0.0.3] - 2026-05-14

### Added

- `docs/migration-agent-sdk-2026-06.md`: 2026-06-15 Agent SDK 課金分離対応の移行ガイド (shim 期間 60日、ゲート判定、opt-in 復活手順、緊急対応プラン)

### Changed

- README: Agent SDK Billing Separation セクション追加

### Deprecated

- `scripts/claude-wrapper.sh` (PR-A で shim 化、2026-07-14 ゲート判定後に完全削除 or opt-in 化を決定)

## [0.0.2] - 2026-05-12

### Added

- Initial tagged release (tag `0.0.2`)。Revharness の wrapper / hydra / semantic runtime / role docs / release gate 一式を含む。詳細な変更履歴は git log を参照。
