# shim-hits.log JSONL Schema

`scripts/claude-wrapper.sh` が shim 化された期間 (2026-06-15 〜 2026-07-14) に
記録されるヒットログのスキーマ定義です。実装は `scripts/_shim-log.sh`。

## File location

```
~/.rev_harness/shim-hits.log
```

- 形式: JSONL (1 イベント = 1 行 = 1 JSON オブジェクト)
- 文字コード: UTF-8
- 改行: LF
- パーミッション: ユーザ既定 (umask 依存)

## Schema

| field          | type             | description                                                  |
|----------------|------------------|--------------------------------------------------------------|
| `ts`           | string (ISO8601) | イベントタイムスタンプ (UTC, `YYYY-MM-DDTHH:MM:SSZ`)         |
| `caller_hash`  | string (hex64)   | `sha256(ppid + ":" + parent_exe_path)`                       |
| `pid`          | integer          | shim プロセス自身の PID                                      |
| `ppid`         | integer          | 呼出元プロセス PID                                           |
| `rewrite_target` | string (enum)  | 移行先候補識別子。enum: `"task-tool"` \| `"codex-job-start"` \| 他 (将来拡張可能) |
| `argv_hash`    | string (hex64)   | `sha256(全argv を 0x1F で連結した文字列)`、PII 排除          |
| `job_id`       | string (optional) | 0.0.5 で追加。`REV_HARNESS_SHIM_JOB_ID` 環境変数経由で渡された場合のみ記録。codex-job.sh の job-id (ULID 風 18桁) と shim hit を join する用途 |

### 例

```json
{"ts":"2026-06-15T12:34:56Z","caller_hash":"a1b2...","pid":12345,"ppid":12300,"rewrite_target":"task-tool","argv_hash":"deadbeef..."}
{"ts":"2026-06-15T12:34:56Z","caller_hash":"a1b2...","pid":12345,"ppid":12300,"rewrite_target":"task-tool","argv_hash":"deadbeef...","job_id":"01HX...XYZ"}
```

## Environment overrides

- `REV_HARNESS_SHIM_HITS_LOG` (0.0.5): 設定されている場合、既定パス `~/.rev_harness/shim-hits.log` の代わりにそのパスへ追記する。テスト隔離・別 retention 運用・CI matrix で活用。空文字や未設定なら既定パスを使う。
- `REV_HARNESS_SHIM_JOB_ID` (0.0.5): 設定されている場合、その値が `job_id` フィールドとして 1 行に追加される。未設定なら `job_id` フィールドは emit しない (backward-compatible)。

## PII 方針

- **prompt 本文・引数の生値は一切記録しない**。
- 引数はすべて連結 → sha256 化したハッシュのみ記録 (`argv_hash`)。
- 呼出元の識別もハッシュ (`caller_hash`) のみ。プロセス名や絶対パスは生では残さない。
- 環境変数・stdin・ファイル内容は記録対象外。

## Retention

- **60 日** (cron rotate 想定)。
- ローテーション仕様は PR-C の migration doc を参照: `docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md`。
- 60 日超のレコードは集計対象外。

## 用途

1. **6/14 中間レビュー**: ヒット件数・呼出元分布を集計し、移行候補の優先度を決定。
2. **7/14 ゲート判定**: 直近 **14 日連続 0 ヒット** であれば `claude-wrapper.sh` を完全削除可能と判定。
   - 1 件でもヒットがあれば原因を特定し、shim 期間を延長するか個別に移行依頼。

## 失敗時挙動 (fail-open)

- ログディレクトリ作成失敗・書込失敗時は stderr に `[shim-log] WARN: ...` を出力し、
  本来の `claude --print ...` passthrough は継続する。
- sha256 計算ツール (`shasum` / `sha256sum`) がいずれも無い場合は
  ハッシュをゼロ埋め文字列にして継続 (ログ品質を犠牲にしても呼出は壊さない)。

## 関連ファイル

- 実装: `scripts/_shim-log.sh`
- 呼出元: `scripts/claude-wrapper.sh` (冒頭で source)
- ポリシー: `docs/agent-sdk-policy.md`
- 移行計画: `docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md`
