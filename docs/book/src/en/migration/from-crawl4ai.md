# Migrating from Crawl4AI MCP

[Crawl4AI](https://github.com/unclecode/crawl4ai) is a Python +
Playwright-based scraping toolkit with an MCP server. It is feature-rich
but heavy: Python runtime, Playwright bundle, custom browser channels.
`rev-stealth` covers the same agent-driven scraping use case in a single
static binary.

## Conceptual mapping

| Crawl4AI concept | rev_scraping equivalent |
|---|---|
| `AsyncWebCrawler.arun(url=...)` | `tools/call` → `spider` |
| `CrawlerRunConfig.css_selector` | recipe `extractors[*].selector` |
| `CacheMode.BYPASS` | `--no-cache` flag (CLI) |
| Custom Python hook | recipe endpoint definition |
| `BrowserConfig.user_data_dir` | `~/.local/share/rev-stealth/profiles/<site>/` |
| `playwright install` | (none — Chromium auto-discovered or sidecar image) |
| `arun_many(urls=[...])` | shell loop or Hermes workflow |

## Side-by-side: spider a single URL

**Crawl4AI** (Python):

```python
from crawl4ai import AsyncWebCrawler
async with AsyncWebCrawler() as c:
    result = await c.arun(url="https://example.com")
    print(result.markdown)
```

**rev_scraping** (CLI):

```sh
rev-stealth spider --url https://example.com --output-format json | jq '.markdown'
```

**rev_scraping** (MCP, from Claude / Hermes / your agent):

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"spider","arguments":{"url":"https://example.com"}}}' \
  | rev-stealth mcp
```

## Side-by-side: extraction with a CSS selector

**Crawl4AI**:

```python
from crawl4ai import AsyncWebCrawler, CrawlerRunConfig
config = CrawlerRunConfig(css_selector=".product-card")
async with AsyncWebCrawler() as c:
    r = await c.arun(url="https://shop.example.com", config=config)
```

**rev_scraping** (proposes a recipe once, reuses forever):

```sh
rev-stealth recipe propose-endpoint \
  --url https://shop.example.com \
  --selector ".product-card" \
  --output-format json
rev-stealth spider --recipe shop_example_com --output-format json
```

## What you gain

- Single binary; no Python interpreter, no `playwright install`.
- AUP / SSRF / VPN-leak triad enforced at the CLI layer.
- Published `outputSchema` on every MCP tool.
- 26 documented error variants with `doc_url` in the envelope.
- Idempotent retries via `--idempotency-key`.

## What you lose (be honest)

- No Python ecosystem (no `pandas` integration out of the box).
- No bundled LLM extraction (Crawl4AI ships `LLMExtractionStrategy`; in
  rev_scraping the LLM is the **caller**, not a stage in the pipeline).
- No SaaS dashboard.

## See also

- [Quickstart](../tutorial/README.md)
- [Competitive landscape](../landscape.md)
