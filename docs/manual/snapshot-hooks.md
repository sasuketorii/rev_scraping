# Snapshot Hooks Reference (I-8)

> Pre/Post/Stop hook で Edit/Write 前後の file state を `.agent/snapshots/` に保存
> する仕組み. **I-8 invariant** (`scripts/safe-dispatch.sh` の Pre/Post SHA256
> snapshot) を runtime で支える基礎 layer であり, 並列 dispatch 中の race を
> 検出 → restore するための material evidence を残す.

本書は HSDI Phase B (commit `d660e2d`) で導入された 3 hook
(`snapshot-pre.sh` / `snapshot-post.sh` / `snapshot-stop.sh`) と共通 library
`scripts/snapshot-dispatch.sh` を operator / reviewer 向けに整理した reference.

---

## 1. 目的

HSDI (Harness Snapshot/Dispatch Invariants) Phase B で導入された I-8 の目的は
2 つ:

1. **race recovery**: 並列 worker 同士が同一 file に書き戻して破壊した場合に,
   pre-snapshot から逐次 restore できる material を残す.
2. **integrity enforcement**: `safe-dispatch.sh` が宣言した
   `file_owner_token` (write 許可 file) に対し,
   pre/post の sha256 を比較し, 想定外 write を即座に検出する.

これらは Claude Code が Edit/Write/MultiEdit/NotebookEdit を実行する直前/直後/
セッション終了時に, 副作用無しで file の copy + sha256 + index 行追記を行う
ことで実現される.

> 設計原則: **fail-open**. snapshot 系の不具合が agent 本作業 (Edit/Write) を
> 1 件たりとも阻害してはならない. すべての error は `2>/dev/null || true`
> + `exit 0` で吸収される.

---

## 2. 3 hooks + 1 library 概要

### 2.1 snapshot-pre.sh (PreToolUse)

- **trigger**: Edit / Write / MultiEdit / NotebookEdit 直前.
- **入力**: stdin から Claude Code が JSON event を流し込む
  (`{"tool_name": "Edit", "tool_input": {"file_path": "..."}}` 形式).
- **処理**:
  1. `tool_name` が Edit/Write/MultiEdit/NotebookEdit でなければ即 exit 0.
  2. `file_path` を抽出 → `_snapshot_repo_rel` で repo-relative に正規化.
  3. privacy denylist (後述) に match すれば即 exit 0.
  4. target file の **旧版** を
     `.agent/snapshots/<ts>/<task>/pre/<repo-relative-path>` に `cp -p`.
  5. `index.jsonl` に `event=pre` 行追記 (tool / file_path / task_id /
     snapshot_path / sha256).
- **fail-open**: 全段で error は無視. exit 0 を必ず返す.

### 2.2 snapshot-post.sh (PostToolUse)

- **trigger**: Edit / Write / MultiEdit / NotebookEdit 直後.
- **処理**: `snapshot-pre.sh` と同形だが, copy 先が `pre/` → `post/`,
  記録される sha256 は **書き込み後** の値.
- **役割**: pre/post 比較で I-8 invariant の sha256 一致/不一致判定を成立させる.

### 2.3 snapshot-stop.sh (Stop)

- **trigger**: agent session 終了 (Claude Code の Stop event).
- **入力**: stdin は読み捨て.
- **処理**:
  1. `.agent/state/locks/<task>.after.sha256` を読み込む
     (= safe-dispatch.sh が dispatch 開始時に書く宣言).
  2. 各 lock 行 (`<sha>  <path>`) を parse.
  3. denylist match を除外し, `snapshot_file stop <path>` で
     `.agent/snapshots/<ts>/<task>/stop/<path>` へ session 終了時点の state を保存.
  4. 各 file について `event=stop` の index 行を追記.
- **lock file が無い場合**: 空の stop 行 1 件を append し exit 0
  (downstream 解析が "stop event 自体は発火した" と区別できるように).

### 2.4 snapshot-dispatch.sh (library)

3 hook が `source` して共有する core. **このファイルは hook ではない**
(matcher で発火しない). 公開関数:

| 関数 | 役割 |
| ---- | ---- |
| `snapshot_file <kind> <path>` | `kind` = pre/post/stop で `.agent/snapshots/<ts>/<task>/<kind>/<repo-rel>` に copy. `HARNESS_SNAPSHOT_LAST_PATH` に dest path をセット. |
| `snapshot_index_append <event> <details_json>` | `.agent/snapshots/index.jsonl` に 1 行追記 (python3 で JSON serialize, sha256 は 64hex のみ受理). |

内部 helper (`_snapshot_repo_root` / `_snapshot_repo_rel` /
`_snapshot_file_abs` / `_snapshot_is_denied` / `_snapshot_sha256` /
`_snapshot_timestamp` / `_snapshot_task_id`) は library 内部専用で,
hook 側からも参照される (denylist 判定/path 正規化目的).

---

## 3. JSONL schema (`snapshot-index/v1`)

`.agent/snapshots/index.jsonl` は 1 行 = 1 event の append-only stream.

```json
{
  "ts": "2025-05-25T02:47:00Z",
  "event": "pre",
  "tool": "Edit",
  "file_path": "docs/manual/snapshot-hooks.md",
  "task_id": "wave21-docs-writer",
  "snapshot_path": "/abs/.agent/snapshots/20250525-024700/wave21-docs-writer/pre/docs/manual/snapshot-hooks.md",
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

| field | 型 | 備考 |
| ----- | -- | ---- |
| `ts` | ISO8601 UTC | `date -u +"%Y-%m-%dT%H:%M:%SZ"`. |
| `event` | `"pre"\|"post"\|"stop"` | hook 種別. |
| `tool` | `"Edit"\|"Write"\|"MultiEdit"\|"NotebookEdit"\|"Stop"\|null` | stop hook は `"Stop"`. |
| `file_path` | repo-relative path | 絶対 path / `../` 含む path は record されない. |
| `task_id` | `$HARNESS_TASK_ID` or `"unknown"` | `/` や `..` 含む値は `"unknown"` に sanitize. |
| `snapshot_path` | 絶対 path or `null` | copy 失敗時は `null`. |
| `sha256` | 64hex lower or `null` | 64hex に match しない値は弾かれる. |

---

## 4. Privacy denylist

snapshot **対象から完全除外** される pattern (default, colon 区切り glob):

```
*.env:*credential*:secrets/*:*.key:*.pem
```

`HARNESS_SNAPSHOT_DENYLIST` env で override 可能. 例:

```bash
export HARNESS_SNAPSHOT_DENYLIST='*.env:*.pem:*.token:secrets/*:apps/web/.env*'
```

denylist match した file は:

- snapshot copy されない (`pre`/`post`/`stop` 全て対象).
- index.jsonl にも追記されない.
- hook は exit 0 を返し続ける.

これにより credential / token / private key 等が `.agent/snapshots/` に
うっかり保存される事故を防ぐ.

---

## 5. settings.json 配線

`.claude/settings.json` は以下の matcher で 3 hook を配線する:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{ "command": ".claude/hooks/snapshot-pre.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{ "command": ".claude/hooks/snapshot-post.sh" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "command": ".claude/hooks/snapshot-stop.sh" }]
      }
    ]
  }
}
```

matcher は正規表現. Pre/Post は同じ 4 tool に閉じている. Stop hook は
matcher 無しで session 終了時に必ず発火する.

---

## 6. Failure recovery (race detection)

`scripts/safe-dispatch.sh` の Pre/Post SHA256 比較と組み合わせると, 以下が成立:

1. dispatch 開始時に safe-dispatch.sh が
   `.agent/state/locks/<task>.before.sha256` に write 対象の sha を宣言.
2. snapshot-pre.sh が **書き込み直前** の旧版を `pre/` に保存.
3. agent が Edit/Write 実行.
4. snapshot-post.sh が **書き込み直後** の新版を `post/` に保存 + sha 記録.
5. dispatch 終了時に safe-dispatch.sh が
   `.agent/state/locks/<task>.after.sha256` を生成.
6. snapshot-stop.sh が `after.sha256` を読み, 各 file の最終 state を `stop/`
   に保存 + index 追記.
7. 違反 (= 宣言 file 外の write, あるいは NO-WRITE 宣言下での sha 変化) を
   検出した場合, `silent_bail.jsonl` 行が emit され downstream agent は abort.
8. 復旧時は `.agent/snapshots/<ts>/<task>/pre/<path>` を origin に戻す
   ことで race 直前の状態に restore 可能.

index.jsonl を時系列に grep すれば, どの tool が / どの task で / どの file を
触ったか, sha 単位で完全再構成できる.

---

## 7. fail-open 保証

全 hook と library で次が守られている:

- `set -u` のみ (`set -e` は使わない). 個別 error は `2>/dev/null || true` で吸収.
- `python3` / `cat` / `cp` / `sha256sum` / `shasum` のいずれが欠けても
  `exit 0` を返す.
- `mkdir -p` 失敗時も snapshot 行を諦めて `exit 0`.
- 不正な `file_path` (絶対 path / `..` 含む) は黙って drop.
- stdin の JSON parse 失敗時は tool/file_path を空文字として扱い即 exit.

結果として, Edit/Write 本作業を **1 件も妨げない**. snapshot は best-effort で
副作用ゼロ.

---

## 8. CI 配線

- `scripts/ci/hsdi-phase-B-done.sh` が Phase B 完了条件として
  `test/unit/test-snapshot-hooks.sh` (6 case) の PASS を要求する.
- 各 hook の self-test は denylist 動作 / `..` reject / lock-file 不在時の
  stop 空行 / index.jsonl の sha 64hex validation などを cover.
- いずれかが FAIL すると HSDI Phase B 完了は不可となり, I-8 invariant 行も
  matrix で red になる.

---

## 9. 運用 tips

- **`HARNESS_TASK_ID` を必ず export** すること.
  未設定だと `task_id=unknown` で全 event が 1 dir に集約され, 並列 task の
  証跡が混ざる. orchestrator は dispatch 直前に必ず set する.
- **`HARNESS_SNAPSHOT_TS` を共有**したい場合 (1 dispatch 内で pre/post/stop の
  ts を揃えたい) も export 可能. 未設定なら hook 呼び出しごとに新規生成
  (= 同一 session 内でも別 ts になり得る).
- **`HARNESS_SNAPSHOT_DIR`**: default `.agent/snapshots`. 絶対 path も受理.
- **`HARNESS_REPO_ROOT`**: git rev-parse できない場所で動かす場合に override.

---

## 10. Cross-references

- I-8 invariant 定義: `docs/canonical-invariants.md` の "I-8 Pre/Post SHA256 snapshot".
- safe-dispatch (= pre/post SHA256 と直接連携する dispatch facade):
  `scripts/safe-dispatch.sh` (運用 doc は今後追記予定).
- path-leak-advise (= 同 PostToolUse の sibling hook):
  `.claude/hooks/path-leak-advise.sh` + `scripts/rev-harness-path-leak-guard.sh`.
- agent-graceful-shutdown (= Stop hook の sibling, snapshot-stop と並列発火):
  `.claude/hooks/agent-graceful-shutdown.sh`.
- HSDI 全体像: `docs/manual/hsdi-architecture-overview.md`.
- verification truth matrix: `docs/manual/verification-truth-matrix.md`
  (I-8 行の PASS 条件 = snapshot test exit 0).
