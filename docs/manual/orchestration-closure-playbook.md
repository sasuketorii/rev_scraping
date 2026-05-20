# Orchestration Closure Playbook

## Purpose

この playbook は、orchestrator が「最後に見つかった 1 sink だけを直して closeout する」運用を禁止し、same-class bug を owned surface 全体で閉じるための実務テンプレートである。
次のいずれかを主張する前に使う。

- `root cause fixed`
- `remaining issues: N`
- `ready for final reviewer LGTM`
- `completed`
- `archived`

## Mandatory Use

以下では必須。

1. defect / regression / root-cause fix
2. same-class bug の横展開を含む修正
3. blocker / remaining issue を exact count で報告する場合
4. final reviewer LGTM を要求する場合
5. completion / archive language を使う場合

## Canonical Dependency

- canonical schema、status / verdict mapping、task-lineage reopen semantics、loop budget ceiling、worker outcome contract、remaining-issues count、completion language、fail-closed 条件は [verification-truth-matrix.md](./verification-truth-matrix.md) を唯一の詳細正本とする
- この playbook は matrix を置き換えず、same-class closure を安全に進めるための実務手順と addendum テンプレートだけを補足する
- field 名は matrix をそのまま使う。`completion boundary`、`evidence destination`、`task lineage ledger entry`、`worker outcome` をローカル別名へ変換しない
- class-closure 非適用の sentinel は `n/a` のみ。`truth placement` は stable / volatile の配置概念であり、slice 固有の保存先名としては常に `evidence destination` を使う

## Step 0. Lock Slice Contract Before Coding

root-cause fix / same-class fix では、まず matrix の `Canonical Schema` をそのまま slice contract に materialize する。playbook で追加確認するポイントは次のとおり。

- owned sink universe が列挙可能で、search method を exact command で残せること
- out-of-scope sink に owner があること
- required checks、evidence destination、completion boundary が同じ slice に結び付いていること
- exact residual count を将来主張したい場合、後で `closed universe basis` を再現可能にできる見込みがあること
- weak universe definition、曖昧な re-slice、budget / lineage provenance 不足があるなら coder / reviewer へ流さず `BLOCK` または mandatory re-slice に倒すこと

## Step 1. Open Class Closure Sheet

lineage 識別子は slice contract を再利用し、別の registry を作らない。closeout 実務では次の addendum を付ける。

```md
## Class Closure Sheet
- bug class:
- owned sink universe:
- closed universe basis:
- closed universe status:
- search method / exact commands:
- sheet status:
- last reset trigger:

| sink id | path / surface | why in universe | owner | status | evidence |
|---------|----------------|-----------------|-------|--------|----------|
```

運用ルール:

- `unknown` sink が 1 件でもある間は closeout 不可
- `closed universe status=YES` は `closed universe basis` が再現可能で、all owned sink statuses known の場合だけ使う
- `closed universe basis`、target scope、owner、探索方法のいずれかが weak なら exact residual count を止め、必要なら mandatory re-slice する

## Step 2. Expand Same-Class Sinks

1 件直して終わりにせず、owned sink universe 全体を更新する。

- touched file 以外の owned surface も検索したか
- 同じ helper / wrapper / role policy / closeout path に同 class sink がないか
- same-file mixed diff の外側に同 class sink が潜んでいないか
- out-of-scope にした sink に明示 owner があるか
- `change surface` と `owned sink universe` の対応関係が崩れていないか

## Step 3. Reset On Late Same-Class Finding

late same-class finding が 1 件でも出たら、次を即時実施する。

1. Class Closure Sheet を `RESET` に戻す
2. 新しい sink を inventory に追加する
3. same-class sink expansion をやり直す
4. required checks と adversarial pre-closure pass をやり直す
5. 旧 `remaining issues: N`、`review request target=FINAL`、final-close claim を失効させる
6. `scope delta since last review` と loop / task ledger を更新する

matrix の loop ceiling、stall budget、task-level carry-forward 条件を 1 つでも超える見込みがあるなら、その場で自動継続を止めて `BLOCK` に倒す。playbook 側で別 threshold を再定義しない。

## Step 4. Run Adversarial Pre-Closure Pass

final reviewer LGTM や completion claim の前に、same-class sink を探し直す。

```md
## Adversarial Pre-Closure Pass
- executed at:
- reviewer request target:
- search commands:
- opposite hypothesis checked:
- untouched owned surfaces checked:
- boundary / fallback / alias paths checked:
- new same-class sinks found:
- result:
```

最低限の観点:

- 「修正した場所」ではなく「同じ失敗が起きる場所」を探したか
- 直近の変更差分に出ていない owned surface を見たか
- completion / archive / reviewer request path で同 class sink が残っていないか
- count claim と sink inventory が一致しているか

新しい same-class sink が見つかったら結果は `RESET` に戻し、closeout を止める。

## Step 5. Record Verification Integrity

required deterministic check ごとに、次の対応を残す。

```md
## Verification Integrity
- command:
- result:
- covered scope:
- artifact pointer:
- no-artifact reason:
- artifact integrity:
```

運用ルール:

- file artifact を指す場合は `test -e <path>` で存在確認できること
- artifact が無い check では `no-artifact reason` を明示すること
- command / result / scope / artifact の対応が曖昧なら `artifact integrity: MISSING`
- required check 未実行、結果未記録、`artifact integrity: MISSING` は matrix に従って fail-closed `BLOCK`

## Step 6. Record Residual Count Carefully

exact `remaining issues: N` は matrix の条件を満たす場合だけ使う。満たせない間は `remaining issues count unknown` を使う。

```md
## Residual Count Record (exact count only)
- remaining issues: N
- closed universe basis:
- basis:
- timestamp:
- target scope:
```

late same-class finding または scope delta が出た時点で既存 count は stale になる。reviewer finding count を closed-universe の残件数へ流用してはならない。

## Step 7. Request Final Reviewer LGTM

`pending final review` を目指すときは、matrix の `Final Reviewer Request Gate` をそのまま handoff に貼り付けて再評価する。playbook 側で gate の local variant を作らない。

確認ポイント:

- reviewer intake 用 handoff に canonical `status` field と `worker outcome` field があり、FINAL request では `status=pending final review` と `worker outcome=DIFF|NO-CHANGE` が明記されている
- Class Closure Sheet が最新で `sheet status=CLOSED`
- adversarial pre-closure pass が current slice に対して実施済み
- worker outcome が `DIFF` または evidence-backed `NO-CHANGE`
- late same-class finding や scope delta で stale になった final claim を持ち越していない
- `Needs verification` から戻す場合も、matrix gate と fresh budget recheck を全項目やり直し、reviewer 再提出 status を `pending review` または `pending final review` に正規化する

`pending verification` は internal holding state であり、reviewer intake 用 handoff の `status` として使わない。`worker outcome=BLOCK` も review-intake-valid ではなく、separate な block report path に送る。

いずれかが欠けるなら、その FINAL handoff 試行は soft downgrade せず fail-closed で `BLOCK` とする。同じ handoff を `pending review` / `pending final review` に読み替えたり、`pending verification` のまま reviewer に流したりしてはならない。追加作業が必要なら、blocker resolution / mandatory re-slice / fresh verification を記録した新しい handoff を起票する。

## Step 8. Guard Completion Language

`ready for final reviewer LGTM`、`LGTM`、`completed`、`archived` の許可条件は matrix のみを正本とする。conditions-not-met の fallback は `in progress` / `pending review` / `pending verification` / `blocked` に限る。

- reviewer `LGTM` だけでは `completed` にならない
- `pending acceptance -> completed` は orchestrator による acceptance recheck と fresh budget recheck が必要
- user acknowledgement / approval は communication event に留め、completion / archive authority の代替や競合条件にしない
- `worker outcome` は `DIFF` / `BLOCK` / `NO-CHANGE` 以外の曖昧語へ置き換えない

## Minimum Closure Addendum

copy 用の最小テンプレートは、matrix の full `Slice Contract` と `Worker Outcome` を前提に、review request addendum と block report addendum を分けて使う。

```md
## Review Request Envelope
- status: `pending review|pending final review`
- worker outcome: `DIFF|NO-CHANGE`
- reviewer intake rule: `pending review|pending final review` plus `worker outcome=DIFF|NO-CHANGE` only
- `pending verification` は internal holding state であり、この envelope では使わない
- missing status / worker outcome、`status=blocked`、`status=pending verification`、または `worker outcome=BLOCK` means fail-closed `BLOCK` via separate block report path

## Class Closure Sheet
- bug class:
- owned sink universe:
- closed universe basis:
- closed universe status:
- search method / exact commands:
- sheet status:
- last reset trigger:

| sink id | path / surface | why in universe | owner | status | evidence |
|---------|----------------|-----------------|-------|--------|----------|

## Adversarial Pre-Closure Pass
- executed at:
- reviewer request target:
- search commands:
- opposite hypothesis checked:
- untouched owned surfaces checked:
- boundary / fallback / alias paths checked:
- new same-class sinks found:
- result:

## Verification Integrity
- command:
- result:
- covered scope:
- artifact pointer:
- no-artifact reason:
- artifact integrity:

## Residual Count Record (exact count only)
- remaining issues: N
- closed universe basis:
- basis:
- timestamp:
- target scope:
```

```md
## Block Report
- status: `blocked`
- worker outcome: `BLOCK`
- review-intake-valid: `NO`

## Block Payload
- fail-closed reason:
- missing prerequisite:
- attempted checks / execution constraint:
- next required input:
- reroute owner:
- reopen condition summary:
- unblock evidence required:
- unblock evidence:
- reroute evidence:
- evidence pointer:
```
