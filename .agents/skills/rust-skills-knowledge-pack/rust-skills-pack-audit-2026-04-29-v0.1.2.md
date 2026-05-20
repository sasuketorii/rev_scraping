# RustSkills Pack Audit v0.1.2 - Chromiumoxide patch

## Finding

`chromiumoxide` was not present in v0.1.1. This was a meaningful omission for JS-rendered pages, SPA form verification, screenshot/PDF generation, visual QA, and CDP-level network/runtime inspection.

## Fix

Added:

- `A015 chromiumoxide` to `rust-skills-master.md` Crate Register.
- Browser Automation/CDP row to `SKILL.md`.
- `SRC-A015 chromiumoxide` and `SRC-STANDARD-CDP` to `rust-skills-sources.md`.
- `references/browser-automation-cdp.md`.
- Watchlist entries for Chrome/Chromium process dependency, CDP update frequency, browser pooling, timeouts, and kill switch requirements.

## Policy

`chromiumoxide` is allowed for authorized QA, own-system tests, JS-rendered page extraction, and rendering verification. Stealth/anti-bot bypass and unauthorized automation are not included as standard RustSkills guidance.
