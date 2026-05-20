# Cursor CLI Integration (round 5)

date: 2026-05-21

RevHarness は Claude Code と Codex に加え、**Cursor CLI** (binary: `agent`) を 3 つ目の orchestration target としてサポートします。本ドキュメントは Cursor 統合の正本です。

## 立ち位置

| Vendor | Wrapper | 主用途 | Default model surface |
|---|---|---|---|
| Claude Code | `scripts/claude-wrapper.sh` (deprecated 2026-07-14) | top-level orchestrator (Claude native) | claude opus/sonnet |
| **Codex** | `scripts/codex-wrapper.sh` | mid/heavy coder + reviewer 固定 | gpt-5.5 (effort: medium/high/xhigh) |
| **Cursor (新)** | `scripts/cursor-wrapper.sh` | **read-only Q&A / 軽量 edit / 自動化 lane** (role: ask / agent / yolo) | composer-2.5 などの Cursor 提供モデル (model 選択は Cursor 側) |

Cursor は **軽量タスクのためのコスト/速度最適 lane** として位置付け、Codex の coder/high-coder/reviewer/research を置き換えるものではありません。"composer" は Cursor が内部で選ぶ model 名の一つであって wrapper の role 名ではありません (role は `ask` / `agent` / `yolo` の 3 種)。

## Safety model (Cursor 公式 docs に基づく — round 1 で誤認していた点)

`https://cursor.com/docs/cli/reference/parameters` に基づく Cursor CLI の実際の semantic:

- **`agent -p` (default agent mode)** は "**Has access to all tools, including write and shell**"。proposal-only ではない。デフォルトで write/shell ツールにフルアクセス。
- **`--force` / `--yolo`** は "**Force allow commands unless explicitly denied**"。これは **command auto-approval** であり、file-write の gate ではない。
- **`--mode ask`** が Cursor が公式に保証する唯一の **true read-only** モード。

Round 1 では `composer` role を proposal-only と主張していたが、これは誤り。Round 2 で role 名を Cursor 公式 mode 用語に align し、false advertising を排除した。

## Round 5 integration with Cursor official rules system

Round 5 adds the Cursor rules layer to the existing wrapper contract without replacing the wrapper safety model.

Cursor official docs state that project rules live under `.cursor/rules`, and the Cursor CLI also reads project-root `AGENTS.md` and `CLAUDE.md` when present and applies them alongside `.cursor/rules`:

- https://docs.cursor.com/en/cli/using
- https://docs.cursor.com/en/context/rules

RevHarness uses a two-layer attach model:

| File | Attach role | Responsibility |
|---|---|---|
| `AGENTS.md` | vendor-neutral root instruction | Cross-agent invariants only: acceptance authority, evidence, secret redaction, delegation boundaries, change discipline |
| `.cursor/rules/revharness-critical.mdc` | always-attached Cursor project rule | Fail-closed invariants Cursor must not miss: truth matrix authority, scope discipline, no secret leakage, wrapper boundaries |
| `.cursor/rules/revharness-detailed.mdc` | description-based Cursor project rule | Operational guidance that should be attached when Cursor is working on RevHarness orchestration, docs, wrappers, tests, or rules |

`revharness-critical.mdc` is intentionally small and strict. `revharness-detailed.mdc` can carry longer operational guidance without making every Cursor context heavier. `CLAUDE.md` remains the vendor-neutral bootstrap for Claude-compatible readers, while `.claude/CLAUDE-LOCAL.md` remains the Claude-specific rule surface.

Round 5 also adds dual telemetry to cursor wrapper invocations:

- `cursor_rules_files_present`: wrapper-time check that the expected root/rules inputs are present (`AGENTS.md` and `.cursor/rules/revharness-critical.mdc` in the current wrapper implementation).
- `cursor_rules_selfcheck_status`: reserved enum self-check field. Round 5 emits `"unimplemented"`; future probes may emit `"passed"` or `"failed"`. The deterministic `.mdc` frontmatter validation remains in `test/unit/test-cursor-rules-frontmatter.sh`.

These fields prove local rule-file availability and preserve a metric slot for self-check status. They do not prove that a live Cursor model honored the instructions; that remains a residual risk and requires a live smoke.

Outbound deny is a separate hardening layer in `_outbound-deny.sh`. It is sourced by Codex/Claude wrapper paths and uses a parent-process walk to reject calls that originate from Cursor before they can invoke those other wrappers. Cursor itself is not blocked from running; the guard prevents Cursor from escalating into Codex/Claude wrapper lanes.

For `--role ask`, the wrapper records a pre/post git snapshot and fails if the read-only ask path changes the worktree. This ask diff gate is a wrapper-level defense because the Cursor CLI flag alone is not treated as sufficient evidence of write enforcement.

## Cursor Agent Skills Integration

Cursor Agent Skills are a separate official mechanism from always-attached rules. Rules are best for session-wide invariants and operational guidance; Skills are task-specific capability bundles that an agent can discover or invoke when the skill's `name` / `description` matches the work.

RevHarness already has a Cursor-visible skill asset base:

| Path | Role in RevHarness | Cursor relevance |
|---|---|---|
| `.agents/skills/<slug>/SKILL.md` | Cross-platform project-level skill projection | Project-level Agent Skills discovery path |
| `.claude/skills/<slug>/SKILL.md` | Claude Code provider projection | Cursor legacy compatibility path per the docs cited for this slice |
| `.cursor/skills/` | Cursor canonical project-level path | Reserved for direct Cursor provider projection or parity copies |

The current checkout contains 32 `SKILL.md` files in `.agents/skills/` and the matching 32 files in `.claude/skills/`, including `cursor-caller`, `production-function-implementer`, and `staff-code-reviewer`. Their frontmatter follows Cursor's skill shape: a fenced YAML block with `name:` and `description:`. `test/unit/test-cursor-skills-compliance.sh` deterministically checks both provider trees for frontmatter fences, required fields, parent-folder name parity or documented compatibility aliases, lowercase names, and non-empty descriptions.

`.cursor/skills/` is intentionally present even though it is not yet populated with direct skill copies. If a future round writes `SKILL.md` files there, it must preserve provider parity with `.agents/skills/` and pass the same frontmatter compliance checks. This avoids creating a Cursor-only skill drift path.

Rules and Skills are split by attachment semantics:

| Surface | Use for |
|---|---|
| `AGENTS.md` + `.cursor/rules/*.mdc` | Fail-closed invariants, root read order, wrapper boundaries, secret redaction, evidence discipline |
| `.agents/skills/` / `.claude/skills/` / `.cursor/skills/` | Specialized workflows such as `cursor-caller`, `production-function-implementer`, `staff-code-reviewer`, deployment guards, and language knowledge packs |

This PR does not prove that `cursor-agent -p` injects project skills in every live Cursor runtime. That remains a live-smoke residual because official docs and current public reports distinguish deterministic file format support from runtime slash-menu / print-mode behavior.

## Roles (Cursor 公式 mode に align)

| Role | wrapper が agent に渡す argv | 実挙動 |
|---|---|---|
| `ask` (default) | `-p --output-format text --mode ask` | **真の read-only**。file write / shell exec しない |
| `agent` | `-p --output-format text` | default agent mode。write/shell 可。各 command は Cursor 側で個別承認 prompt |
| `yolo` | `-p --output-format text --force` | agent + command auto-approval。**書き込み制御ではない**、危険、明示 opt-in 専用 |

`ask` を default にした理由: 唯一 hard-guaranteed な read-only path のため、保守的 default は安全側。書きたい場合は explicit opt-in (`--role agent` or `--role yolo`) を要求。

## Invocation contract

```bash
# Default (read-only)
cat prompt.md | scripts/cursor-wrapper.sh --role ask --stdin > answer.md

# Standard write-capable
cat prompt.md | scripts/cursor-wrapper.sh --role agent --stdin > output.md

# Full automation (command auto-approval、書き込み可)
cat prompt.md | scripts/cursor-wrapper.sh --role yolo --stdin > output.md

# 0-cost validation
scripts/cursor-wrapper.sh --role ask --dry-run
```

`--stdin` は必須 (argv-prompt mode はサポート外)。wrapper は内部で `agent -p ... "$(cat -)"` に置き換えます。

`--role` を 2 回以上指定すると **role escape 拒否** で fail-closed。

## Delegation metric

各 invocation で `REV_HARNESS_DELEGATION_METRIC` JSONL を stderr に 1 行 emit:

```json
{
  "schema_version": 1,
  "delegation_id": "<uuid>",
  "timestamp": "2026-05-21T...",
  "wrapper_role": "cursor-ask",
  "vendor": "cursor",
  "specialty": null,
  "canonical_role": null,
  "manifest_hash": null,
  "exit_code": 0,
  "duration_ms": 1234,
  "tokens_in": null,
  "tokens_out": null,
  "total_tokens": null,
  "dry_run": false,
  "specialty_status": "none",
  "cursor_force_flag": "",
  "cursor_mode": "ask",
  "cursor_rules_files_present": true,
  "cursor_rules_selfcheck_status": "unimplemented"
}
```

- `vendor: "cursor"` で Codex / Claude metrics と区別
- `cursor_mode`: `"ask"` for `role=ask`、その他 empty
- `cursor_force_flag`: `"--force"` for `role=yolo`、その他 empty。**command 承認動作の記録であり、write permission の記録ではない**
- `cursor_rules_files_present`: expected root/rules inputs の存在確認結果
- `cursor_rules_selfcheck_status`: self-check enum slot。round 5 では `"unimplemented"`、future probe は `"passed"` / `"failed"`
- `tokens_*` は null (Cursor stderr の token report 仕様が公式 docs で未確立、parser は将来追加)
- `scripts/collect-delegation-metrics.sh` は既存 schema 互換のまま aggregate 可能 (新 field は ignored)

## Auth / 認証

Cursor CLI 認証は **wrapper 外で完結** します。

```bash
# 初回 (interactive)
~/.local/bin/agent login
```

wrapper は authentication を駆動せず、不認証時は Cursor 側の error を素通しします (fail-closed 経路には載せません)。

## Fail-closed conditions

- `agent` binary 不在: `$HOME/.local/bin/agent` → `/usr/local/bin/agent` → `$PATH` を順に探索、全て不在で exit non-zero
- 未知 role: `ask | agent | yolo` のみ受理
- `--role` 2 回以上指定: role escape として reject
- `--stdin` 不在の non-dry-run invocation: reject
- SIGINT / SIGTERM 受信時: child agent process に signal forward + exit 130
- vendoring 検出: canonical guard が `REV_HARNESS_CANONICAL_ROOT` 不一致で exit 70 (Codex/Claude wrapper と同じ)
- `--role ask` の pre/post git snapshot で worktree diff を検出: read-only violation として reject
- Cursor rules files missing: expected root/rules inputs の presence metric を false として emit
- Cursor-origin process が Codex/Claude wrapper を呼ぼうとした場合: `_outbound-deny.sh` が parent-process check で reject

## Tests

`test/unit/test-cursor-wrapper.sh` (**30 件 PASS、round 5**):

Role resolution:
1. help renders
2. default role ask
3. ask / agent / yolo dry-run validates (×3)
6. unknown role rejected
7. **duplicate `--role` rejected** (role escape guard、Codex round 1 amendment)

Metric schema:
8. exactly 1 metric per invocation
9. `REV_HARNESS_METRICS_DISABLE=1` suppresses
10. ask metric: `cursor_mode=ask`
11. yolo metric: `cursor_force_flag=--force`, `cursor_mode=""`
12. agent metric: no `--force`, no `--mode` (default agent mode)

**Argv assertions** (Codex round 1 amendment、fake fixture が argv をログして検証):
13. ask passes `--mode ask`, no `--force`
14. agent has neither `--mode` nor `--force`
15. yolo passes `--force`, no `--mode`
16. `-p` and `--output-format text` are always passed
17. stdin prompt is forwarded as the positional arg to agent

Process semantics:
18. real fake-agent invocation succeeds
19. wrapper propagates fake-agent exit code 3
20. missing agent binary fail-closed
21. `--stdin` omitted on real invocation rejected

Signal + vendoring (round 3 で追加):
22. SIGINT/SIGTERM trap が wrapper source 上に登録され、`exit 130` まで wired (trap registration regression、real-signal の OS/bash version 依存 timing を避ける)
23. `forward_signal` が受信 signal を `METRICS_CHILD_PID` へ propagate (signal forwarding wiring 確認)
24. vendoring guard が non-canonical `REV_HARNESS_CANONICAL_ROOT` で `VENDOR GUARD` を出して exit non-zero (cursor wrapper 固有の dedicated case)

Round 5 rules + ask hardening:
25. Cursor rules files present metric is emitted
26. Cursor rules self-check metric is emitted as `"unimplemented"` for round 5
27. missing `AGENTS.md` emits `cursor_rules_files_present=false`
28. `--role ask --dry-run` skips the read-only diff gate
29. `--role ask` pre/post git snapshot rejects write drift
30. `--role agent` does not trigger the ask-only diff gate

Additional round 5 regression:

- `test/unit/test-outbound-deny.sh` (**13 件 PASS**) validates Cursor-origin outbound denial for Codex/Claude wrapper paths, non-Cursor allowance, and that generic `agent` process names do not false-positive.
- `test/unit/test-cursor-rules-frontmatter.sh` (**18 件 PASS**) validates deterministic `.mdc` frontmatter shape for RevHarness Cursor rules.
- `test/unit/test-cursor-skills-compliance.sh` validates Cursor Agent Skills frontmatter compliance for `.agents/skills/` and `.claude/skills/`.
- `test/integration/root_instructions_test.sh` validates the root instruction split across `AGENTS.md`, `CLAUDE.md`, and vendor-specific local files.

Fake fixture `test/fixtures/fake-cursor/agent` は CI 0-cost で wrapper の挙動を検証するため。**Cursor 公式 semantic に正しく align**: default print mode は write/shell capable、`--mode ask` だけが read-only、`--force` は command auto-approval。Test hooks: `FAKE_CURSOR_EXIT_CODE`, `FAKE_CURSOR_EMIT_STDERR=1`, `FAKE_CURSOR_ARGV_LOG=<path>` (argv 記録)。

`test/integration/harness_release_gate.sh` の **LOCAL + FULL** tier に `cursor_rules_root`、`cursor_rules_frontmatter`、`cursor_outbound_deny`、`cursor_skills_compliance`、および既存 `cursor_wrapper` step が wire-in されており、これらの tier で Cursor rules / skills / wrapper regression を catch。`quick` tier は cursor wrapper を含みません (quick は metrics smoke + harness doctor 程度の最小スコープ)。

## Round 5 で意図的 out-of-scope

- **live cursor smoke**: 実機 Cursor CLI が `.cursor/rules/` / `AGENTS.md` / `CLAUDE.md` を honor することの検証は orchestrator が別途実行する。
- **Enterprise Hooks beforeShellCommand allowlist**: Cursor Enterprise plan 必須機能のため base contract には含めない。sample / opt-in は後続 round。
- **token metrics parsing**: Cursor stderr の token report 形式が公式 docs で未確立。後続 round で追加。
- **live Cursor skills smoke**: local `SKILL.md` compliance は検証済みだが、`cursor-agent -p` で Skills が context injection される live behavior は未検証。
- **specialty 統合**: Codex の specialty (production-function-implementer 等) と同等の wrapper flag lens system は cursor wrapper には未導入。ただし Agent Skills としての projection は Cursor discovery path に載る。
- **classifier auto-routing への 3-vendor 追加**: `scripts/rev-harness-task-classifier.sh` への 3-vendor routing 追加は別 PR。orchestrator が `--role` を明示的に選ぶ運用。
- **`--output-format json|stream-json`**: wrapper は `text` 固定。
- **`--sandbox enabled|disabled`** 制御: wrapper は cursor default に任せる (`--sandbox` の明示制御は後続)。

## Round 1 → Round 2 → Round 3 → Round 5 修正履歴

### Round 1 → Round 2 (Codex BLOCK 7.5/10 → LGTM 9.0/10)

Round 1 の grading で Codex (gpt-5.5 xhigh) が **BLOCK** verdict + 5 amendment を出し、それを全て取り込んで round 2 を構築:

1. **Role rename**: `composer/coder/ask` → `ask/agent/yolo` (Cursor 公式 mode 用語に align)
2. **`composer` proposal-only 主張削除**: `agent -p` は default で write/shell 可能なので false advertising だった
3. **`--allow-edits` 廃止**: `--force` は file-write gate ではなく command auto-approval。混同を避けるため flag そのものを廃止
4. **`yolo` role 明示**: `--force` を明示 opt-in する形に再設計
5. **duplicate `--role` reject**: codex-wrapper.sh と同じ role-escape guard
6. **Argv assertion test 追加**: fake fixture が argv をログ、test が `--mode ask` / `--force` / `-p` の経路を実確認
7. **Fake fixture を Cursor 真 semantic に修正**: `--force` を command auto-approve として扱い、`--mode ask` を read-only として扱う
8. **Signal handling**: SIGINT/SIGTERM の child forward + exit 130 (codex-wrapper.sh と整合)
9. **Release gate に wire-in**: `harness_release_gate.sh` で cursor wrapper test の regression catch

### Round 2 → Round 3 (Codex BLOCK 9.0/10 docs axis 8.4 → LGTM 9.0+/10 target)

Round 2 で Codex は 4/5 axis ≥9.0 PASS、docs axis のみ 8.4/10 で BLOCK。指摘された stale residue + 追加 regression を round 3 で解消:

1. Title `(round 1)` → `(round 2)`、date `2026-05-20` → `2026-05-21`
2. Vendor table cell の `lightweight composer / ask` → `read-only Q&A / 軽量 edit / 自動化 lane (role: ask / agent / yolo)`。"composer" は Cursor 内部 model 名であって wrapper role 名ではない、と明記
3. Metric sample の `wrapper_role: "cursor-composer"` → `"cursor-ask"`、`cursor_mode: ""` → `"ask"`、timestamp も round 3 日付に更新
4. Release gate 記述の "全 tier (quick / local / full)" → "LOCAL + FULL のみ"
5. Decision table に "Reviewer LGTM / deterministic checks が必要な場合は Codex coder + production-function-implementer に戻す" 行を追加
6. **Binary name portability note** 新規 (公式 `cursor-agent` vs alias `agent` + `CURSOR_WRAPPER_AGENT_BIN` 明示)
7. **Signal forwarding regression test** + **vendoring guard dedicated test** を追加 (21 → 24 PASS)
8. 本セクション (round 3 履歴 + test 22-24 documentation) を追加

### Round 3 → Round 5 (Cursor rules integration + residual risks officialization)

Round 5 は Cursor CLI wrapper の既存 role semantic を維持したまま、公式 rules system と RevHarness の root instruction contract を接続:

1. Title を `(round 5)` に更新し、`AGENTS.md` + `.cursor/rules/revharness-critical.mdc` + `.cursor/rules/revharness-detailed.mdc` の二段 attach を明文化
2. Cursor CLI が `AGENTS.md` / `CLAUDE.md` / `.cursor/rules` を読む公式 docs link を追加
3. critical rule と detailed rule の責務分担を fail-closed invariant / operational guidance として固定
4. delegation metric に `cursor_rules_files_present` と `cursor_rules_selfcheck_status` を追加
5. `_outbound-deny.sh` の scope を明文化: Codex/Claude wrapper 側の parent-process check、Cursor 自身は対象外
6. `--role ask` の pre/post git snapshot diff gate を wrapper-level read-only defense として記録
7. `docs/manual/cursor-rules-residual-risks.md` を新設し、公式 docs で未保証な領域と本 PR の対応範囲を固定

### Round 5 → Round 2 BLOCK fix (Cursor Agent Skills + hardening amendments)

Codex r1 grading は wrapper enforcement / tests / docs residual risk を BLOCK。Round 2 fix では user critique の核心だった Cursor Agent Skills を明文化し、同時に wrapper/test hardening を追加:

1. nullable bool self-check field を `cursor_rules_selfcheck_status: "unimplemented"` enum に変更し、pseudo-pass に見える nullable bool を排除
2. `_outbound-deny.sh` の match を `cursor-agent` のみに tighten し、generic `agent` process name の false positive を防止
3. ask diff gate の write-simulation cleanup を top-level `trap` で保護
4. `.cursor/skills/` canonical directory を追加し、`.agents/skills/` / `.claude/skills/` が Cursor Agent Skills discovery 対象であることを docs に明記
5. `test/unit/test-cursor-skills-compliance.sh` を追加し、`SKILL.md` frontmatter compliance と sample skill の precise parent/name parity を deterministic check 化
6. LOCAL + FULL release gate に `cursor_rules_root`、`cursor_rules_frontmatter`、`cursor_outbound_deny`、`cursor_skills_compliance` を wire-in

## 公式 Cursor docs 参照

- https://cursor.com/cli
- https://cursor.com/docs/cli/overview
- https://cursor.com/docs/cli/installation
- https://cursor.com/docs/cli/headless
- https://cursor.com/docs/cli/shell-mode
- https://cursor.com/docs/cli/github-actions
- **https://cursor.com/docs/cli/reference/parameters** ← flag の正確な semantic はここに
- **https://docs.cursor.com/en/cli/using** ← CLI が `.cursor/rules` と root `AGENTS.md` / `CLAUDE.md` を読む根拠
- **https://docs.cursor.com/en/context/rules** ← `.cursor/rules/*.mdc` project rules の根拠
- **https://cursor.com/docs/skills** ← Agent Skills の `SKILL.md` packaging と project-level discovery path の根拠

公式 docs では「Claude Code / Codex から Cursor CLI を wrapper として呼ぶ三者連携」は記述されていません。本統合は Cursor CLI の公式 automation surface を RevHarness の wrapper 規約に合わせて利用する自前オーケストレーションです。flag semantic は常に公式 reference parameters page を一次情報源とすること。

### Binary name portability note

公式 docs では CLI invocation を **`cursor-agent`** と表記することが多く、`agent` は短縮 alias として install script (`curl https://cursor.com/install | bash`) が `~/.local/bin/agent` を作る形で提供されます。wrapper は `$HOME/.local/bin/agent` → `/usr/local/bin/agent` → `$PATH` の順で探索しますが、環境によっては `cursor-agent` のみ存在する場合があるため、その際は `CURSOR_WRAPPER_AGENT_BIN=$(command -v cursor-agent)` を明示指定してください。`agent` という汎用名は他ツールとの衝突可能性もあるため、portability を最大化したい environment では `cursor-agent` を直接指定する運用が安全です。
