# Vendored Copy Inventory (~/dev/) — 2026-05-14

スキャン日: 2026-05-14
ツール: rev_harness 0.0.4 `scripts/harness-doctor.sh --check-vendoring`
スキャン範囲: ~/dev/ 配下の git リポジトリ 28件 (rev_harness, rev_license は除外)

## サマリ

| 状態 | 件数 | 内容 |
|---|---|---|
| クリア | 10 | vendoring 検出なし |
| 要分離 | 13 | 全件 MUTATED (sha256 不一致) |
| 機械的処理可 (A) | 0 | rev_license 同型なし |

## 重要な所見

rev_license は `tools/rev_harness/` 一式コピーだったが、他13件はパターンが異なり、`scripts/` 直下に **claude-wrapper.sh / codex-wrapper.sh 単体** を配置している。全件 sha256 不一致 = 改変済 or 古いバージョン。**単純置換すると独自パッチを失う恐れあり、個別 diff 確認が必要**。

## クリア (10件)

vendoring 検出なし。0.0.4 doctor の現時点判定:
- Ad_Analytics, get_frontend, recap_core, rev_component, rev_devskills
- rev_line, rev_magic, rev_releaseline, sushi_no_te, tiktok_downloader

## 要分離 (13件、全 MUTATED)

| リポ | mutated件数 | dirty? | 最新commit | パス | 分類 | 推奨アクション |
|---|---|---|---|---|---|---|
| ad.mac | 1 | 18 | 2026-02-12 | scripts/codex-wrapper.sh | C/D | dirty解消後、wrapper単体置換 |
| adcom | 1 | 2 | 2026-02-05 | scripts/codex-wrapper.sh | C | wrapper単体置換 |
| agent_base | 4 | 1 | 2026-05-12 | scripts/{claude,codex}-wrapper.sh + .claude/worktrees/ | C | scripts/置換、worktreesは自然消滅 |
| broad_chat | 1 | 9 | 2026-01-31 (remote無) | scripts/codex-wrapper.sh | D | remote未設定+dirty、要事前整理 |
| call_agent | 1 | 12 | 2026-01-10 | scripts/codex-wrapper.sh | C/D | dirty多、古い |
| contact_dev | 3 | 1 | 2026-05-13 | scripts/ + .archive/ | C | .archive配下は履歴のみで除外可 |
| cyber_tomo | 2 | 31 | 2026-04-21 | scripts/{claude,codex}-wrapper.sh | D | dirty多、要事前整理 |
| ext_ chat | 1 | 1 | 2026-01-31 | scripts/codex-wrapper.sh (パス内スペース注意) | C | dir名スペース注意 |
| rev_builder | 2 | 0 | 2026-05-12 (remote無) | scripts/{claude,codex}-wrapper.sh | B/C | clean、remote未設定 |
| rev_frontend | 2 | 6 | 2026-05-12 | scripts/{claude,codex}-wrapper.sh | C | rev_clone リモート |
| rev_salescopilot | 2 | 396 | 2026-05-12 | .claude/worktrees/ のみ | D | dirty膨大、wt は自然消滅 |
| rev_stealth | 2 | 1 | 2026-05-09 | scripts/{claude,codex}-wrapper.sh | C | clean寄り、機械的処理可 |
| revclip | 2 | 75 | 2026-02-18 | scripts/codex-wrapper.sh + workspace/ | D | dirty多、古い |

## 分類

- **A**: rev_license 同型 (tools/rev_harness/ 一式) → **該当0件**
- **B**: clean だが remote 未設定 → rev_builder
- **C**: scripts/ 直下 wrapper のみ、改変あるが処理可能 → 8件
- **D**: dirty 多 or remote 未設定、要事前整理 → 5件

## 推奨実行順序

1. **Phase 1 (低リスク)**: rev_stealth, contact_dev, agent_base, rev_frontend, adcom, ext_ chat
   - dirty 少、最近活動、改変内容確認後 canonical 置換
2. **Phase 2 (要事前確認)**: rev_builder
   - remote 未設定。push 先を決定してから処理
3. **Phase 3 (Dirty 解消優先)**: ad.mac, call_agent, broad_chat, cyber_tomo, revclip, rev_salescopilot
   - 未保存作業 (rev_salescopilot 396変更!) をまず人間が整理

## 各リポでの作業テンプレート

```bash
REPO=~/dev/<repo>
# 1. dirty 確認
git -C "$REPO" status

# 2. 改変内容を確認 (canonical との diff)
diff "$REPO/scripts/codex-wrapper.sh" ~/dev/rev_harness/scripts/codex-wrapper.sh

# 3. 改変が意図的か確認後、削除
git -C "$REPO" rm scripts/codex-wrapper.sh
# claude-wrapper も同様に必要なら

# 4. PATH 経由参照に切り替え (該当があれば)
# rev_harness を ~/dev/rev_harness に install して PATH に追加
# 各リポでの呼出は $(command -v claude-wrapper.sh) で

# 5. CI / hooks の参照を grep
grep -rn "claude-wrapper\|codex-wrapper" "$REPO" --include="*.yml" --include="*.sh"

# 6. commit + push
git -C "$REPO" commit -m "chore: remove vendored rev_harness wrappers, use PATH-installed canonical"
git -C "$REPO" push
```

## 想定リスク

- **dirty 多数リポ**: 未保存作業を巻き込む危険。先に working tree を確認
- **Remote 未設定 (broad_chat, rev_builder)**: ローカル限定リポの可能性、push 先確認必須
- **MUTATED = 改変済**: 独自パッチを失う恐れ。各 wrapper の diff を必ず確認
- **CI 影響**: 各リポの .github/workflows 内の wrapper 参照は未スキャン、分離前に grep 必須
- **rev_salescopilot の .claude/worktrees/**: git worktree の一時領域。本体 scripts/ に vendored なしのため worktree 廃止で自然消滅可能

## 関連
- `scripts/harness-doctor.sh --check-vendoring` (検出ツール)
- `docs/adoption-guide.md` (PATH-based 正規 install)
- `docs/agent-sdk-policy.md` (6/15 Agent SDK 課金分離 policy)
- rev_license の分離事例: commit `a0a806f` (2026-05-14)

## 進捗トラッキング

| Phase | リポ | 状態 | 完了日 | 備考 |
|---|---|---|---|---|
| 1 | rev_stealth | TODO | - | - |
| 1 | contact_dev | TODO | - | - |
| 1 | agent_base | TODO | - | - |
| 1 | rev_frontend | TODO | - | - |
| 1 | adcom | TODO | - | - |
| 1 | ext_ chat | TODO | - | - |
| 2 | rev_builder | TODO | - | remote 確認 |
| 3 | ad.mac | TODO | - | dirty 18件 |
| 3 | call_agent | TODO | - | dirty 12件 |
| 3 | broad_chat | TODO | - | remote 無 |
| 3 | cyber_tomo | TODO | - | dirty 31件 |
| 3 | revclip | TODO | - | dirty 75件 |
| 3 | rev_salescopilot | TODO | - | dirty 396件 |

各リポを処理したらこの表を更新する。
