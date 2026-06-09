# rev_harness Adoption Guide

効力: 2026-05-14 (0.0.4) 以降

## 1. なぜ vendor (物理コピー) してはいけないか

過去に rev_license プロジェクトに rev_harness 一式が物理コピーで取り込まれた事例があり、以下の問題が発生した:

- 双方の wrapper が乖離 (上流の bug fix が下流に届かない)
- 下流の `claude --print` 呼出が上流の意図と独立に課金・実行される
- セキュリティ修正の伝播が遅延

0.0.4 以降、wrappers は canonical install 配下でのみ起動を許可する (VENDOR GUARD)。

## 2. 推奨インストール: PATH-based

```bash
git clone https://github.com/sasuketorii/rev_harness.git ~/dev/rev_harness
export PATH="$HOME/dev/rev_harness/scripts:$PATH"
```

シェル初期化 (`~/.zshrc`, `~/.bashrc`) に上記 export を追加して恒久化してください。

## 3. CI / 非標準レイアウト

CI runner 等で `~/dev/rev_harness` 以外の場所に clone する場合は、明示的に環境変数を set:

```bash
export REV_HARNESS_CANONICAL_ROOT="/runner/_work/_actions/sasuketorii/rev_harness/0.0.4"
```

これにより VENDOR GUARD はその path を正規 install と認める。

## 4. submodule 経由 (例外的に許可)

どうしても他リポに同梱したい場合は git submodule で取り込み、その submodule path を `REV_HARNESS_CANONICAL_ROOT` に set する:

```bash
git submodule add https://github.com/sasuketorii/rev_harness.git tools/rev_harness
export REV_HARNESS_CANONICAL_ROOT="$PWD/tools/rev_harness"
```

submodule は「コミットを pin した参照」であり、物理コピーとは区別される。upstream の更新は `git submodule update --remote` で取り込む。

## 5. doctor で既存 vendored copy を検出

```bash
~/dev/rev_harness/scripts/harness-doctor.sh --check-vendoring --path /path/to/project
```

出力:

- exit 0 `no vendoring detected` — クリーン
- exit 70 `VENDORED COPY detected: <path>` — 同一内容のコピー検出
- exit 71 `MUTATED COPY detected: <path>` — 改変コピー検出 (より危険)

`--allow-vendored` で「許可された vendor」を suppress 可能 (CI が submodule を含む等の正当な場合)。

## 6. Soft mode (deprecated)

0.0.4 では escape hatch として `REV_HARNESS_VENDOR_CHECK=warn` を提供する。これを set すると VENDOR GUARD は warning のみで exit 0 を返す。
ただし **次のマイナーで削除予定 (0.0.6 候補)**。恒久利用は不可、移行期間のみの暫定措置と理解すること。0.0.5 では運用フィードバック取得のため継続利用可能。

## 7. FAQ

**Q1: macOS の `/private/var` と `/var` で path が不一致になる**

A: wrapper は `pwd -P` で realpath 化するので両者は等価扱い。問題なし。

**Q2: git worktree で `../rev_harness-wt` を使いたい**

A: `REV_HARNESS_CANONICAL_ROOT` を worktree path に明示 set する。CI runner と同じ扱い。

**Q3: 一時的に vendored copy で動かしたい (例: PR レビュー時)**

A: `REV_HARNESS_VENDOR_CHECK=warn` で soft mode (次のマイナーで削除予定なので恒久化禁止)。

**Q4: rev_license に取り込まれていた rev_harness は今どこ?**

A: 2026-05-14 に分離済 (rev_license commit a0a806f)。歴史記録は rev_license の `docs/archive/REVHARNESS_ADOPTION.md` を参照。

**Q5: codex-job.sh の wait が timeout した、job は生きてる?**

A: timeout (exit 124) は wait コマンドの待機を打ち切るだけで、job プロセスは継続。
   `status` で確認、必要なら `kill $(cat ~/.rev_harness/jobs/<id>/pid)` で停止。
   完了済 job の result は引き続き取得可能。

## 8. Long-running codex execution

Codex の `--effort high` 系タスクは 5〜15 分かかる。Claude Code orchestrator の
sub-agent から `codex-wrapper.sh` を同期呼出すると、wait 中に sub-agent の
token 予算が枯渇してレポートが脱落する問題があった (0.0.5 で構造的解決)。

### 推奨パターン: `scripts/codex-job.sh`

```bash
# 1. start (即 return)
job_id=$(scripts/codex-job.sh start --role coder "implement feature X")

# 2. 別の作業を進めるか、status/wait で確認
scripts/codex-job.sh status "$job_id"
```

### Claude Code orchestrator UX (Monitor 利用可)

Monitor tool が使える orchestrator では、1 turn で起動から完了まで完結:

```bash
job_id=$(scripts/codex-job.sh start --role reviewer "...")
scripts/codex-job.sh wait "$job_id" --timeout 1800  # Monitor で block-wait
scripts/codex-job.sh result "$job_id" --field exit_code
```

### Bash 直接利用 / CI

```bash
job_id=$(scripts/codex-job.sh start --role coder "...")
# 他作業
scripts/codex-job.sh wait "$job_id" --timeout 1800
```

### Job ファイル構成

```
~/.rev_harness/jobs/<job-id>/
├── cmd          # 実行コマンド (引数のみ、プロンプト本文は別)
├── pid          # PID
├── log          # stdout + stderr マージ
├── exit_code    # 完了時の exit code (atomic write)
└── status.json  # job_id, state, started_at, ended_at, role, exit_code
```

`REV_HARNESS_RUN_DIR` で base path を上書き可能。

### Exit codes

| code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 通常エラー (job 未完了で result 等) |
| 64 | 引数エラー (sysexits.h) |
| 70 | VENDOR GUARD refuse (canonical-path 不一致) |
| 124 | wait timeout (GNU timeout 慣例) |

### Garbage collection

`gc --ttl <days>` で完了済 job ディレクトリを削除。cron 化推奨:

```
0 3 * * * ~/dev/rev_harness/scripts/codex-job.sh gc --ttl 7
```

### shim-hits.log との関係

`codex-job.sh start` は `shim_log_hit "codex-job-start"` で hits log にエントリを残す。
0.0.5 以降は `job_id` フィールドが含まれるため、shim-hits.log と
`jobs/<id>/status.json` を join key で突き合わせ可能。

## 9. 関連

- README "Installation" セクション
- `scripts/_canonical-guard.sh` (実装)
- `scripts/harness-doctor.sh --check-vendoring` (検出ツール)
- `scripts/codex-job.sh` (非同期 job manager)
- `test/integration/cross_agent_wrapper_matrix_test.sh` X14/X14b/X15a-e (テスト)

## 10. 1-step adopter setup (Phase G)
### Before Phase G
手動導入では、operator が以下 6 steps を順に実行していた。

- init: project-local の初期ファイルと状態を作る
- bootstrap: semantic bootstrap を起動する
- cargo: Rust semantic MCP の build/check を通す
- wire: MCP 設定へ rev_harness entry を接続する
- hooks: Claude/Codex 用 hook を install する
- doctor: vendored copy や canonical root の不整合を確認する

### After Phase G

```bash
bash scripts/rev-harness install
```

```bash
bash scripts/rev-harness-adopter-setup.sh setup
```

### Status check

```bash
bash scripts/rev-harness status
```

### Cleanup

```bash
bash scripts/rev-harness clean --dry-run
bash scripts/rev-harness clean --apply --ack-rebuild-cost
```

### Skill trigger 例

- 「revharness 入れて」
- 「壊れた、直して」
- 「doctor 回して」

### Wave 22 deferral

`upgrade apply` と `uninstall --apply` は次 phase に延期する。

References:
- `scripts/rev-harness-adopter-setup.sh` (Phase G T-G-1)
- `scripts/rev-harness` façade (T-G-3)
- `.claude/skills/rev-harness-lifecycle/SKILL.md` (T-G-4)
