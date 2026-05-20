# Cursor Rules Residual Risks

date: 2026-05-21
task id: `cursor-rules-integration-20260521`
slice id: `c5-D-docs-grading`

This document fixes the known residual risks for the round 5 Cursor rules integration. It separates what Cursor official docs state from what RevHarness can enforce deterministically in this PR.

## 1. Precedence opacity

**状況**: User Rules / Team Rules / Project Rules / `AGENTS.md` / `CLAUDE.md` の conflict precedence は Cursor official docs で deterministic acceptance contract として未保証。

**本 PR の対応**: `AGENTS.md` は vendor-neutral invariant のみに制限し、Cursor-specific operational guidance は `.cursor/rules/` に置いた。critical rule は fail-closed invariant、detailed rule は operational guidance に分離。

**Residual**: User Rules や Team Rules が conflicting instruction を持つ環境では、Cursor 側の実適用順が RevHarness の deterministic check だけでは証明できない。

**Future round 候補**: live Cursor smoke で conflict fixture を用意し、User / Team / Project / root markdown の precedence observation artifact を保存する。

## 2. Live rules honoring opacity

**状況**: fake fixture は wrapper argv と local self-check を検証できるが、実 Cursor model が rules を honor したことは証明できない。

**本 PR の対応**: wrapper metric に `cursor_rules_files_present` と enum `cursor_rules_selfcheck_status` を追加し、rules inputs の存在確認と self-check slot を記録。Round 5 の deterministic frontmatter validation は `test/unit/test-cursor-rules-frontmatter.sh` に固定。

**Residual**: model behavior の遵守は deterministic unit test ではなく live smoke 領域。Cursor service-side behavior や model routing 変更の影響を受ける。

**Future round 候補**: opt-in live smoke を追加し、rule-specific sentinel instruction を Cursor CLI に確認させる。

## 3. `--print` mode + rules behavior unverified

**状況**: `-p` / print mode で `.cursor/rules/` がどのタイミング・粒度で attach されるかは official docs の acceptance-level detail として未明示。

**本 PR の対応**: wrapper は `-p --output-format text` の argv contract を維持し、rules self-check metric を出す。

**Residual**: print mode の live context attachment は wrapper self-check だけでは証明できない。

**Future round 候補**: `agent -p` live smoke で `.cursor/rules` sentinel を観測し、interactive mode との差分を記録する。

## 4. `--mode ask` write enforcement weakness

**状況**: Cursor CLI docs は ask mode を read-only と説明するが、RevHarness acceptance としては CLI flag だけで write 完全 block を証明しない。

**本 PR の対応**: Slice C3 で `--role ask` 実行前後に git snapshot を取り、worktree diff が発生したら wrapper-level read-only violation として fail-closed。

**Residual**: git 不在、`.git` 外、または git が追跡しない外部 side effect は diff gate では検出できない。

**Future round 候補**: sandboxed temp workspace smoke と filesystem watch を組み合わせ、untracked / ignored file drift の観測範囲を拡張する。

## 5. Sandbox Mode is not shell-exec deterrent

**状況**: Cursor Sandbox Mode docs は network/file restriction の surface であり、shell exec 自体を確実に block する deterrent としては未明示。

**本 PR の対応**: sandbox flag に依存せず、Cursor-origin process が Codex/Claude wrappers を呼ぶ経路を `_outbound-deny.sh` で hardening。

**Residual**: Cursor 自身の shell tool behavior と sandbox policy の実 enforcement は local environment と Cursor implementation に依存する。

**Future round 候補**: Enterprise Hooks sample と local sandbox live probe を追加し、shell command attempt の audit artifact を残す。

## 6. Enterprise Hooks gating is plan-locked

**状況**: `beforeShellCommand` allowlist は Cursor Enterprise plan 必須で、base RevHarness contract には含められない。

**本 PR の対応**: Enterprise Hooks を mandatory gate にせず、wrapper-level outbound deny と ask diff gate を baseline hardening とした。

**Residual**: Enterprise plan のない環境では Cursor shell command allowlist を Cursor-native hook として強制できない。

**Future round 候補**: Enterprise Hooks sample policy を docs/examples に置き、plan available environment で opt-in verification する。

## 7. `AGENTS.md` cross-vendor leakage

**状況**: Cursor CLI が `AGENTS.md` を読む公式 docs はあるが、Codex / Claude が同じ semantics で `AGENTS.md` を読むことは Cursor docs では保証されない。

**本 PR の対応**: `AGENTS.md` には vendor-neutral content だけを置き、Claude-specific rules は `.claude/CLAUDE-LOCAL.md`、Cursor-specific rules は `.cursor/rules/` に分離。

**Residual**: vendor ごとの root instruction reading behavior は異なるため、`AGENTS.md` だけに vendor-specific safety rule を置くと漏れる可能性がある。

**Future round 候補**: root instruction integration test を vendor family ごとに拡張し、read-order drift を検出する。

## 8. MDC frontmatter syntax

**状況**: `.mdc` frontmatter の正確な grammar と future-compatible field set は深掘りしていない。

**本 PR の対応**: `test/unit/test-cursor-rules-frontmatter.sh` で RevHarness が使う deterministic subset を固定し、18 checks で expected fields と basic shape を検証。

**Residual**: Cursor 側が `.mdc` grammar を変更した場合、local lint が pass しても live Cursor attach が変わる可能性がある。

**Future round 候補**: official docs の `.mdc` examples と local lint rule の sync check を追加する。

## 9. Outbound deny scope

**状況**: `_outbound-deny.sh` は `ps -o comm=` と PPID walk depth 16 による parent-process check で実装している。container / chroot / abnormal PPID context では process tree visibility が環境依存。

**本 PR の対応**: unit test で normal Cursor-origin path と non-Cursor path を固定し、Codex/Claude wrapper 側で hardening を適用。

**Residual**: process ancestry が見えない runtime や wrapper を経由しない direct binary invocation は対象外。

**Future round 候補**: process tree unavailable case の explicit metric と, wrapper bypass detection の advisory guard を追加する。

## 10. Ask diff gate boundary

**状況**: git command 不在 / `.git` 外 invocation では ask diff gate は skip され、advisory log のみになる。CI container compatibility のための trade-off。

**本 PR の対応**: git repository 内では pre/post snapshot を比較し、diff があれば read-only violation として fail-closed。

**Residual**: git unavailable environment では ask mode read-only enforcement が Cursor CLI semantics と logs に依存する。

**Future round 候補**: git unavailable mode を explicit blocked mode にする opt-in strict flag、または portable directory snapshot fallback を追加する。

## 11. Cursor Skills discovery in `--print` mode unverified

**状況**: Cursor Agent Skills の file layout と `SKILL.md` frontmatter は documented standard だが、`cursor-agent -p` / print mode で project skills がどのタイミングで agent context に注入されるかは acceptance-level detail として未検証。

**本 PR の対応**: `.cursor/skills/` canonical path を確保し、既存 `.agents/skills/` / `.claude/skills/` projection が Cursor-visible skill asset であることを docs に明記。`test/unit/test-cursor-skills-compliance.sh` で両 provider tree の `name:` / `description:` / frontmatter fence / folder-name parity or documented compatibility alias / lowercase / non-empty description を deterministic check 化。

**Residual**: live Cursor runtime、slash menu、`--print` context injection は local file-format test だけでは証明できない。Cursor CLI version、runtime mode、settings、service-side behavior の影響を受ける可能性がある。

**Future round 候補**: opt-in live smoke で `cursor-agent -p` に skill sentinel を問い合わせ、`.agents/skills/`、`.claude/skills/`、`.cursor/skills/` の discovery 差分を evidence artifact として保存する。
