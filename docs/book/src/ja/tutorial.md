# クイックスタート (日本語要約)

英語版の 7 ステップチュートリアル
([English](../en/tutorial/README.md))
の日本語サマリーです。完全な手順は英語版を参照してください。

1. **ローカルインストール** — `brew install` または `cargo install`。
2. **最初のレシピ** — `rev-stealth recipe propose --url ...`。
3. **ブラウザプロファイル** — `rev-stealth auth login --site ...`。
4. **VPN ローテーション** — `rev-stealth vpn rotate --country JP`。
5. **Claude Code 連携** — `claude mcp add rev-stealth -- rev-stealth mcp`。
6. **Hermes オーケストレーション** — Hermes プロジェクト側で `rev-stealth` を MCP として登録。
7. **VPS デプロイ** — `systemd` ユニットを `make install` で配備。
