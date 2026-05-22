# rev_scraping — The Black-Belt CLI for AI Agents

> Language: **English** | [日本語](../ja/README.md)

`rev_scraping` is a single-binary Rust toolkit that lets an AI agent (Claude
Code / Cursor / Hermes / homegrown orchestrators) drive a stealth-grade web
scraping pipeline with one command — and one MCP server — without paying the
Crawl4AI / Playwright MCP integration tax.

## Why this docs site exists

The reference user is an **AI agent developer**, not a human scraper. Every
page is graded against one bar:

> Would a sophisticated agent dev pick `rev-stealth` over Crawl4AI /
> Playwright MCP **without hesitation** after reading this page?

That means:

- Every CLI sub-command has a runnable example.
- Every MCP tool has a real JSON-RPC request + response + at least one
  failure example.
- Every `ErrorKind` (26 of them) has its own troubleshooting page with
  reproduction code and a fix path.
- The migration guides show side-by-side examples, not abstract feature
  matrices.

## How to read this book

If you have **5 minutes**, jump to
[05. Claude Code integration](./tutorial/05-claude-code.md).

If you have **30 minutes**, read the
[Quickstart tutorial](./tutorial/README.md) end-to-end.

If you are evaluating against another tool, read the
[Competitive landscape](./landscape.md) and the
[migration guides](./migration/README.md).

## Project status

- **Version**: v1.3.0 (Q3 2026)
- **Stability**: MCP schema 2-major guarantee; CLI flags 1-major.
  See [`compat.md`](./compat.md).
- **Source of truth**: every tool / error description in this book is
  generated from the in-tree Rust sources and verified by
  `mcp_reference_freshness` in CI.

## Languages

Toggle between English and 日本語 in the sidebar header. The Japanese pages
are intentionally shorter — they cover the same 80 % surface that an
operator needs, not the full reference.
