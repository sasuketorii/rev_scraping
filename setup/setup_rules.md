# Setup Rules & Workflow

このドキュメントは、プロジェクトを新規に立ち上げる際、要件定義書（`.agent/requirements.md`）から開発環境とルールを整合させるための標準手順書です。
エージェントは、プロジェクトの初期段階でこの手順に従い、**爆速スタートダッシュ**のための基盤を構築してください。

## 1. 前提条件

### 必須依存関係
以下のツールが事前にインストールされていること:
- **jq** - JSONパーサー（Hooksで使用）
  - macOS: `brew install jq`
  - Linux: `apt install jq` / `yum install jq`
- **Git** - バージョン管理（Worktree対応）
- **claude** - Claude Code CLI（Coder実行時）
- **codex** - Codex CLI（Reviewer実行時）

### その他の前提
- ユーザーから「プロジェクトの要件定義書」または「初期構想」が提示されていること。
- または、`.agent/` 配下に要件定義ファイル（例: `.agent/requirements.md`）が作成されていること。

## 2. セットアップ・ワークフロー

### Step 1: 要件定義の解析
提示された要件定義書を読み込み、以下の重要項目を抽出します。
1.  **プロジェクトのゴール:** 何を作るのか（Webアプリ、CLI、ライブラリ等）。
2.  **技術スタック:** 言語、フレームワーク、DB、インフラ等（指定がなければ推奨構成を提案）。
3.  **制約条件:** ターゲットOS、パフォーマンス要件、セキュリティ要件等。

### Step 2: プロジェクト固有ルールの生成
抽出した情報を元に、汎用ルール（`.agent_rules/RULES.md`）ではカバーしきれない固有情報を定義します。

1.  **`PROJECT_CONTEXT.md` の作成:**
    - `.agent/PROJECT_CONTEXT.md` に、技術スタックや開発ルールをまとめたコンテキストファイルを作成します。
    - 記載内容:
        - 使用する言語・フレームワークのバージョン
        - ディレクトリ構造の設計図
        - テスト実行コマンド
        - リンター/フォーマッターの設定

### Step 3: Worktree環境の整備 (Hydra Flow)
並列開発を行うためのGit Worktree環境をセットアップします。
1.  **スクリプト配置:** `hydra` (または同等のWorktree管理スクリプト) を `scripts/` 等に配置し、実行権限を付与します。
2.  **ディレクトリ初期化:** `.shared/` ディレクトリを作成し、共通リソース（node_modules等）の共有設定を行います。

### Step 4: ディレクトリ構造の初期化
`PROJECT_CONTEXT.md` の設計に基づき、必要なディレクトリとボイラープレートを作成します。
- `src/`, `apps/`, `test/` 等の主要ディレクトリ。
- **Pythonの場合:** `uv init` を使用して爆速で環境を構築すること（`pip/venv` は使用しない）。
- `.gitignore`, `package.json` 等の設定ファイル。

### Step 5: 初回ExecPlanの作成
セットアップ完了後、最初の機能実装に向けた `ExecPlan`（`.agent/active/plan_YYYYMMDD_HHMM_init.md` 等）を作成します。
- 内容: 環境構築の検証、Hello Worldの実装、CI/CDのセットアップ等。

## 3. テンプレート: プロジェクト要件定義書 (`.agent/requirements.md`)

```markdown
# プロジェクト要件定義書

## プロジェクト名
(例: Next.js Dashboard)

## ゴール
(例: ユーザーがログインして売上データを確認できるダッシュボードを作成する)

## 技術スタック
- Frontend: Next.js 14 (App Router)
- UI: Tailwind CSS, Shadcn/UI
- Backend: Supabase (PostgreSQL)
- Language: TypeScript

## ディレクトリ構造案
/apps/web ... Frontend
/packages/ui ... Shared UI
...

## 制約事項
- Vercelにデプロイ可能であること
- Mobile Firstデザイン
```