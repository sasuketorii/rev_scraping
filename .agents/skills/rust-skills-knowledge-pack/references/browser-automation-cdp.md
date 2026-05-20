# Browser Automation / CDP Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crate**: `chromiumoxide`
- **Primary standard**: Chrome DevTools Protocol

## Use cases

Use `chromiumoxide` when `reqwest + scraper` is insufficient because the page state requires a real browser:

- JS-rendered DOM extraction on authorized targets.
- SPA form behavior verification.
- Screenshot / PDF / visual QA.
- Network, Page, Runtime, DOM event inspection for own or permitted systems.
- Web Builder / Leptos app regression tests that need real Chromium behavior.

## Non-goals

- Do not standardize stealth, anti-bot bypass, CAPTCHA bypass, or evasion workflows.
- Do not use Chromium for static HTML when `reqwest + scraper` is enough.
- Do not spawn one browser process per URL.

## Architecture

```text
input URL/job
  -> policy check / allowlist
  -> bounded browser job queue
  -> chromiumoxide browser pool
  -> page context with timeout
  -> navigation / DOM / screenshot / network capture
  -> normalized result event
  -> audit sink
```

## Engineering rules

- Pool browser instances and bound tabs/pages.
- Set per-navigation, per-page, and total-job timeouts.
- Add kill switch for stuck browser processes.
- Store only necessary HTML/screenshot artifacts.
- Attach trace/job IDs to every browser action.
- Monitor Chrome/Chromium version, CDP compatibility, memory per browser, crash rate, and queue wait time.
