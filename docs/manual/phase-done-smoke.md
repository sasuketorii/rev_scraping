# phase-done-smoke.sh — Smoke Gate Reference

**Status:** HSDI Phase H deliverable, docs sweep 2026-05-26.
**Enforcement script(s):** `scripts/ci/phase-done-smoke.sh`,
`scripts/state-transition-guard.sh`
**Canonical invariant(s):** I-12 (Smoke-gated dual-LGTM)
**Acceptance criterion (AC):** see `docs/manual/verification-truth-matrix.md` L10
(invariant acceptance gates)
**Joint axis script:** `scripts/state-transition-guard.sh --require-lgtm-final`

> I-12 (Smoke-gated dual-LGTM) を機械的に enforce する mktemp adopter smoke test
> runner. 13 個の固定 step を fresh sandbox 上で実走し、JSONL 形式の
> `smoke_evidence_sha256` を発行する。これが `state-transition-guard.sh` の
> `lgtm_stage=final` 遷移条件として消費される。

---

## 1. 目的

agent ベース dual-LGTM (Opus 4.7 xhigh / Codex xhigh、9+/10) は構造上
**provisional** verdict にすぎない。HSDI Phase A–G の 7 phase で観測された通り、
agent-only 9+/10 LGTM は production 相当の install/verify flow を実際には踏まず、
実体不在の合格判定を返し得る。

`phase-done-smoke.sh` はこのギャップを閉じる:

- `mktemp -d` で空の adopter project (sandbox) を作る
- 実 `rev-harness install` を実走する
- identity / Node DB / Rust binary / privacy scan / state.json / hooks /
  doctor / status / clean / self-install guard を順に検証する
- 全 step exit 0 のときだけ `smoke_evidence_sha256` を含む summary JSONL を
  発行する
- `state.json.phase = "done"` への advance は `lgtm_stage = final` を必須にし、
  `lgtm_stage = final` は summary JSONL に sourced な `smoke_evidence_sha256`
  を必須にする (= 二重バインド)

これが invariant I-12 の機械的実体である (`AGENTS.md` §I-12)。

---

## 2. CLI

| flag | 動作 |
|---|---|
| `--phase <X>` | phase identifier。`[A-Z]` または `[A-Z][A-Z0-9_-]*` (デフォルト `H`)。JSONL 行の `phase` field に literal で出る |
| `--keep-sandbox` | EXIT trap でも `mktemp` sandbox を削除しない (debug 用) |
| `--help`, `-h` | usage を stdout に出して exit 0 |

実装上、`--verbose` flag は **存在しない**。詳細 stdout は失敗 step に限り
自動で stderr に redact 済みで吐かれる (`run_step` 内 `redact_text` 経由)。

`run_step` は 1 step ずつ stdout/stderr を `mktemp` log に capture し、
exit 0 のときは `[phase-done-smoke] step pass: <name>`、非 0 のときは
`step fail: <name> exit=<rc>` の 1 行と redact 済みの全 captured log を
stderr に流す。

### 環境変数で挙動を上書き

| env | 役割 | 既定 |
|---|---|---|
| `REV_HARNESS_SMOKE_HARNESS_ROOT` | rev-harness 本体 repo root | repo の `pwd -P` |
| `REV_HARNESS_SMOKE_METRICS_FILE` | JSONL 出力先 | `.agent/metrics/phase_done_smoke.jsonl` |
| `REV_HARNESS_SMOKE_TMPDIR` | sandbox 親 dir | `/tmp` |
| `REV_HARNESS_SMOKE_SKIP_HEAVY` | `1` で Node DB step を軽量 (paths.json 読みのみ) に切り替え | `1` |
| `REV_HARNESS_BIN` | 使用する `rev-harness` 実体 | `scripts/rev-harness` |
| `REV_HARNESS_DOCTOR_BIN` | 使用する `harness-doctor` 実体 | `scripts/harness-doctor.sh` |
| `REV_HARNESS_PRIVACY_SCAN` | privacy scan script | `scripts/ci/release-binary-privacy-scan.sh` |
| `REV_HARNESS_SMOKE_BINARY` | strings 対象の Rust binary | `harness-rust/target/release/semantic-mcp` |

---

## 3. 13 step 動作

実行順は固定。`main` 内で `run_step <name> <fn>` を 13 回呼ぶ
(`scripts/ci/phase-done-smoke.sh` L289–L301)。

| # | step name | 内容 |
|---|---|---|
| 1 | `sandbox` | `mktemp -d "$TMP_ROOT/phase-done-smoke-${PHASE}-${ts}.XXXXXX"` + `Cargo.toml` / `src/lib.rs` / `pyproject.toml` / `python_sample/sample.py` 配置 + `git init` + initial commit |
| 2 | `install` | `(cd $HARNESS_ROOT && REV_HARNESS_SMOKE_SKIP_HEAVY=$SMOKE_SKIP_HEAVY rev-harness install --target $SANDBOX)` |
| 3 | `identity` | `$SANDBOX/.shared/project_id` が存在、`^[A-Za-z0-9_.-]{1,64}$`、`revharness-*` プレフィックス禁止 |
| 4 | `semantic_db` | heavy mode: `paths.json.semantic_db` / `paths.json.rust_db` が指す Rust semantic DB file が存在。skip-heavy mode: 同 path が非空 string |
| 5 | `rust_binary` | `$BINARY_PATH --help` exit 0。未ビルドなら `cargo build --release -p semantic-mcp` を走らせる |
| 6 | `strings_privacy_scan` | `bash scripts/ci/release-binary-privacy-scan.sh` exit 0 (I-2b joint check) |
| 7 | `state_json` | `$SANDBOX/.rev-harness-state/state.json` が `schema == "rev-harness-state/v1"` かつ `phase == "done"` かつ `current_phase == "done"` |
| 8 | `paths_json` | `$SANDBOX/.rev-harness-state/paths.json` が `schema == "rev-harness-paths/v1"`、`backend == "rust"`、`semantic_db == rust_db`、`node_db` 不在 |
| 9 | `hooks` | `$SANDBOX/.git/hooks/pre-commit` が存在 |
| 10 | `doctor` | `PROJECT_ROOT=$SANDBOX harness-doctor --quick` exit 0 |
| 11 | `status` | `rev-harness status --target $SANDBOX` 出力中に literal `phase: done` |
| 12 | `clean` | `env -u REVHARNESS_PARALLEL_QUIESCE rev-harness clean --target $SANDBOX --dry-run` exit 0。**かつ** 出力中に literal `skip: PARALLEL_QUIESCE active` を **検出した場合は fail** (=quiesce 残留検出ガード) |
| 13 | `self_install_guard` | rev-harness 本体 dir で `rev-harness install` を流したとき exit code が **`72` ちょうど** であること (self-install 禁止 invariant 確認) |

13 step 終了後、`emit_summary_metric` が summary 行 1 本を append。
全 step exit 0 で `final_rc = 0`、それ以外で `final_rc = 1`。
`exit "$final_rc"`。

---

## 4. Exit codes

| exit | 意味 |
|---|---|
| 0 | 全 13 step PASS。summary JSONL の `smoke_evidence_sha256` は `lgtm_stage = final` 遷移に使える |
| 1 | いずれかの step が fail。stderr 末尾に `phase-done-smoke: failed steps: <names>` が出る。`smoke_evidence_sha256` は出るが、summary 行の `exit_code != 0` のため `smoke_sha_is_sourced` チェックで弾かれ、`lgtm_stage = final` には進めない |
| 2 | usage error (`--phase` の値欠落、不正 phase ID、未知 flag)。JSONL は emit されない |

---

## 5. JSONL schema (`phase-done-smoke/v1`)

出力先は `.agent/metrics/phase_done_smoke.jsonl` (env で上書き可)。
全行 `schema: "phase-done-smoke/v1"`。

### per-step row

```json
{
  "schema": "phase-done-smoke/v1",
  "ts": "2026-05-26T10:30:00Z",
  "event": "step",
  "step": "identity",
  "exit_code": 0,
  "passed": true,
  "phase": "H",
  "smoke_evidence_sha256": "<sha256 of the base object>"
}
```

`smoke_evidence_sha256` は base object (= `smoke_evidence_sha256` フィールドを
含まない上記オブジェクト) を `jq -c` で正規化した文字列の SHA-256 を取った
もの。step ごとに 1 行 append される。

### summary row

```json
{
  "schema": "phase-done-smoke/v1",
  "event": "summary",
  "phase": "H",
  "total_steps": 13,
  "passed_count": 13,
  "failed_count": 0,
  "exit_code": 0,
  "smoke_evidence_sha256": "<sha256 of the base summary object>"
}
```

`state-transition-guard.sh` は `event == "summary"` かつ `exit_code == 0` の
行の `smoke_evidence_sha256` のみ受理する (`smoke_sha_is_sourced` 内 jq filter,
`scripts/state-transition-guard.sh` L85–L91)。

JSONL は append-only。新規 run でも overwrite せず追記される。golden schema は
`test/golden/metrics/phase_done_smoke.jsonl.schema.json` に置く (CI で
`scripts/ci/check-metric-schemas.sh` が validate)。

---

## 6. state-transition-guard との連携 (I-12 enforcement)

phase-done-smoke 完走後、JSONL summary 行から `smoke_evidence_sha256` を抽出し、
state-transition-guard 経由で state.json に inject する。

```bash
# 1. 最後の summary 行の SHA を抽出
SHA="$(jq -rs 'map(select(.event=="summary" and .exit_code==0))
       | last.smoke_evidence_sha256' .agent/metrics/phase_done_smoke.jsonl)"

# 2. provisional confirmed -> final confirmed への遷移を要求
bash scripts/state-transition-guard.sh \
  --plan-id <plan-id> \
  --round <int> \
  --target-state dual_lgtm_confirmed \
  --target-stage final \
  --smoke-evidence-sha256 "$SHA" \
  --state-file .agent/state/dual_lgtm_state.json \
  --evidence-paths "opus=<path>,codex=<path>" \
  --reason "smoke gate passed"

# 3. phase advance 直前の最終 gate
bash scripts/state-transition-guard.sh \
  --require-lgtm-final .agent/state/dual_lgtm_state.json
```

state-transition-guard 側の不変条件 (`validate_joint_transition`):

- `lgtm_stage=final` への遷移には `--smoke-evidence-sha256` 必須かつ 64 桁 hex
- 渡された SHA は `phase_done_smoke.jsonl` の summary 行のうち
  `exit_code == 0` のもののみと一致しなければならない
- `final -> provisional` の regress は I-12 violation で exit 1
- `--require-lgtm-final <state-file>` は `state.lgtm_stage != "final"` で
  即 exit 1 (phase advance 直前 gate)

詳細は `docs/manual/state-transition-guard.md` 参照。

---

## 7. Failure recovery

smoke fail 時:

1. **失敗 step を特定** — stderr 末尾の
   `phase-done-smoke: failed steps: <names>` を見る
2. **redact 済み captured log を読む** — 該当 step の stderr block が
   `~/` 形式に redact された状態で出ている
3. **sandbox 内で再現** — `--keep-sandbox` 付きで再走し、生 sandbox 上で
   手動 verify。`[phase-done-smoke] kept sandbox: <path>` が log に出る
4. **fix → re-run** — fail 原因の component (install / Rust binary /
   privacy / state.json / hooks / doctor / clean / self-install guard) を
   修正し、`phase-done-smoke.sh` を再実行

`--keep-sandbox` を使った後の sandbox は `/tmp/phase-done-smoke-*` に残り
続けるので、終わったら `/bin/rm -rf` で明示削除する。

### よくある fail 原因

| step | 典型原因 | 確認場所 |
|---|---|---|
| `install` | adopter setup script の壊れ | `scripts/rev-harness-adopter-setup.sh` |
| `semantic_db` | Rust semantic DB migration 未適用 / paths manifest drift | `paths.json.semantic_db` (heavy mode) |
| `rust_binary` | release build 失敗 | `harness-rust/target/release/semantic-mcp` |
| `strings_privacy_scan` | I-2b 違反 (binary に `/Users/` 等 leak) | `scripts/ci/release-binary-privacy-scan.sh` |
| `state_json` | phase advance 未完了 / schema drift | `$SANDBOX/.rev-harness-state/state.json` |
| `clean` | quiesce 残留 (`PARALLEL_QUIESCE active` literal) | env / lock file 状態 |
| `self_install_guard` | rev-harness 本体での self-install 検出 logic 退行 | `scripts/rev-harness` の exit 72 path |

---

## 8. Privacy guard

`phase-done-smoke.sh` は path leak 防止を built-in している:

- `redact_text` / `redact_value` 関数 (L43–L49) が
  `${HOME}/`、`/Users/<name>/`、`/home/<name>/` を `~/` に置換
- `log` 関数 (L51–L53) は全 stderr 出力を `redact_value` 経由で流す
- 失敗 step の captured stdout/stderr も `run_step` 内で `redact_text`
  経由で stderr に転送される
- JSONL の `smoke_evidence_sha256` は raw absolute path を含まない
  (path は base object に直接入らないため)

ただし sandbox path 文字列 (`/tmp/phase-done-smoke-...`) は redact 対象外。
debug log を共有する場合は `/tmp/phase-done-smoke-*` の literal を手で
潰すこと。

---

## 9. CI 配線

phase-done-smoke は HSDI Phase H done gate (`scripts/ci/hsdi-phase-H-done.sh`)
の step として実走される。flock concurrent guard は
`.agent/state/hsdi-phase-H-done.lock` で取られる。

新規 phase (Wave 22 Phase I / J / …) を作る場合は `--phase I`、`--phase J`
… で実走できる。phase ID は `[A-Z]` または `[A-Z][A-Z0-9_-]*` の正規表現
に合えば良いので、`PHASE-H-DOC` のような長い ID も通る。

CI 上の典型呼び出し:

```bash
REV_HARNESS_PHASE_DONE_SMOKE_METRICS=.agent/metrics/phase_done_smoke.jsonl \
  bash scripts/ci/phase-done-smoke.sh --phase H
```

---

## 10. self-test とユニット

- state-transition-guard 側: `bash scripts/state-transition-guard.sh --self-test`
  が joint axis (`provisional -> final` 遷移、smoke SHA 必須化、
  final regress 拒否、`--require-lgtm-final` 動作) を確認する
- metric schema 側: `bash scripts/ci/check-metric-schemas.sh` が
  `test/golden/metrics/*.jsonl.schema.json` に対し JSONL を validate する
- 13 step そのもの: smoke test 自体が adopter project 上の end-to-end
  verifier として機能するため、専用 unit はない (= smoke が unit)

---

## 11. Cross-references

- canonical invariant: `docs/canonical-invariants.md#I-12` (Smoke-gated
  dual-LGTM)
- joint invariant: `docs/canonical-invariants.md#I-2b` (Binary privacy
  stable) — phase-done-smoke step 6 で direct enforcement
- state machine spec:
  `.agent/active/plan_20260526_hsdi-phase-H-rfc-round2-patches/i12-state-machine-spec.md`
- state-transition-guard 仕様: `docs/manual/state-transition-guard.md`
- release-binary-privacy-scan 仕様:
  `docs/manual/release-binary-privacy.md`
- adopter lifecycle (rev-harness install / repair / uninstall):
  `docs/manual/rev-harness-lifecycle.md`、`docs/adoption-guide.md`
- verification 全体: `docs/manual/verification-truth-matrix.md`
- AGENTS.md 該当節: `AGENTS.md` §I-2b、§I-12
- 実装本体: `scripts/ci/phase-done-smoke.sh`
- joint guard 本体: `scripts/state-transition-guard.sh`
