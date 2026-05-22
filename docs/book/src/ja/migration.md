# 移行ガイド (日本語要約)

- [Crawl4AI MCP からの移行](../en/migration/from-crawl4ai.md) — 英語版参照
- [Playwright MCP からの移行](../en/migration/from-playwright.md) — 英語版参照

主要差分:

- `rev-stealth` は **単一バイナリ** + 単一 MCP サーバー。Crawl4AI のように Python ランタイム + Playwright 依存をホストする必要がない。
- `rev-stealth` は **AUP / SSRF / VPN リーク**の三段ガードを CLI レイヤで強制する。
- すべての MCP ツールに `outputSchema` があり、AI エージェントは構造化応答を直接消費できる。
