# RustSkills Repository Agent Instructions

Use `rust-skills-master.md` as the single source of truth, `SKILL.md` as the compact skill entrypoint, and `rust-skills-sources.md` as the source registry. For implementation details, load the relevant file under `references/`.

Hard rules:
- Do not implement unbounded concurrency, unbounded channels, request-per-client construction, callback allocations, lock-held awaits, or unchecked crypto nonce/key reuse.
- Run `cargo audit`, `cargo deny check`, `cargo tree -e features`, tests, and benchmarks when dependency or hot-path changes are made.
- For QUIC/HPKE/TLS/crypto, verify transitive advisories in `Cargo.lock`, not only top-level crate versions.
- Treat high-load sending and private communication as authorized, audited, rate-limited, legally compliant systems only.


## Browser Automation/CDP

When browser automation is required, prefer `chromiumoxide` only for authorized JS-rendered pages, SPA form verification, screenshots, and QA. Static HTML should remain `reqwest + scraper`. Do not add stealth or anti-bot bypass workflows as standard implementation guidance. Browser processes must be pooled, bounded, timeout-protected, and kill-switchable.
