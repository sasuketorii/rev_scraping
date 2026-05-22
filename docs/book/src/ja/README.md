# rev_scraping — AI エージェント向け黒帯 CLI

> 言語: [English](../en/README.md) | **日本語**

`rev_scraping` は、Claude Code / Cursor / Hermes などの AI エージェントが
ステルス級の web スクレイピングを 1 つの CLI と 1 つの MCP サーバーで
完結させるための、単一バイナリの Rust ツールキットです。

## このドキュメントの目的

対象読者は **AI エージェント開発者** です。各ページは次の 1 つの基準で
評価されます。

> このページを読んだ熟練エージェント開発者が、Crawl4AI / Playwright MCP
> ではなく `rev-stealth` を**迷わず選ぶか?**

そのため、

- すべての CLI サブコマンドに実行可能な例があります。
- すべての MCP ツールに実 JSON-RPC リクエスト / レスポンス、および
  失敗例があります。
- 26 個の `ErrorKind` すべてに、再現コードと修復手順を含む
  個別ページがあります。

## 読み始めるべき場所

- **5 分**しかなければ、
  [English: Claude Code 連携](../en/tutorial/05-claude-code.md) へ。
- **30 分**あれば、
  [English: Quickstart](../en/tutorial/README.md) を通読してください。

日本語ページは現在 5 章のみカバーしています。完全リファレンスは英語側を
参照してください。
