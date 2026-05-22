module completions {

  def "nu-complete rev-stealth format" [] {
    [ "human" "json" ]
  }

  # Defender-facing evaluation toolkit: captcha resilience / browser stealth / VPN rotation / adaptive scraping (authorized targets only)
  export extern rev-stealth [
    --format: string@"nu-complete rev-stealth format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    --version(-V)             # Print version
  ]

  def "nu-complete rev-stealth captcha output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth captcha format" [] {
    [ "human" "json" ]
  }

  # CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)
  export extern "rev-stealth captcha" [
    --output-format: string@"nu-complete rev-stealth captcha output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --format: string@"nu-complete rev-stealth captcha format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth captcha solve format" [] {
    [ "human" "json" ]
  }

  # Solve a CAPTCHA challenge
  export extern "rev-stealth captcha solve" [
    --type: string            # Challenge type: `recaptcha-v2`, `recaptcha-v3`, `hcaptcha`, `turnstile`
    --site-url: string        # Target site URL hosting the challenge
    --site-key: string        # Sitekey (auto-detected if omitted on supported challenge types)
    --action: string          # reCAPTCHA v3 action label
    --dry-run                 # Skip the live solver and exercise the sidecar plumbing only. Useful for CI smoke tests
    --format: string@"nu-complete rev-stealth captcha solve format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth captcha verify format" [] {
    [ "human" "json" ]
  }

  # Verify a previously-issued token (round-trips through the challenge provider's verify endpoint)
  export extern "rev-stealth captcha verify" [
    --type: string            # Challenge type, same vocabulary as `solve --type`
    --token: string           # Token returned by `solve`
    --secret: string          # Provider secret (loaded from env in production)
    --format: string@"nu-complete rev-stealth captcha verify format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth captcha help" [
  ]

  # Solve a CAPTCHA challenge
  export extern "rev-stealth captcha help solve" [
  ]

  # Verify a previously-issued token (round-trips through the challenge provider's verify endpoint)
  export extern "rev-stealth captcha help verify" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth captcha help help" [
  ]

  def "nu-complete rev-stealth browser output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth browser format" [] {
    [ "human" "json" ]
  }

  # Stealth browser operations (launch a profile, run a stealth-test sweep)
  export extern "rev-stealth browser" [
    --output-format: string@"nu-complete rev-stealth browser output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --format: string@"nu-complete rev-stealth browser format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth browser launch format" [] {
    [ "human" "json" ]
  }

  # Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host
  export extern "rev-stealth browser launch" [
    --profile: string         # Profile slug. One of: `desktop`, `mobile-ios`, `mobile-android`, `ipad`, `galaxy-ultra`
    --stealth: string         # Stealth level: `off`, `basic`, `full`
    --url: string             # Navigate to this URL after launch. Default: `about:blank`
    --headed                  # Run with a visible chrome window instead of new-headless mode
    --chrome: path            # Override the chrome executable path. By default, chromiumoxide auto-detects the system chrome
    --dwell: string           # Hold the page for this many seconds after navigation (lets a detector finish its work). Default 0 = exit as soon as `document.readyState` settles
    --format: string@"nu-complete rev-stealth browser launch format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth browser stealth-test format" [] {
    [ "human" "json" ]
  }

  # Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title
  export extern "rev-stealth browser stealth-test" [
    --target: string          # Detection page to probe
    --profile: string
    --stealth: string
    --dwell: string
    --headed
    --chrome: path
    --format: string@"nu-complete rev-stealth browser stealth-test format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth browser help" [
  ]

  # Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host
  export extern "rev-stealth browser help launch" [
  ]

  # Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title
  export extern "rev-stealth browser help stealth-test" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth browser help help" [
  ]

  def "nu-complete rev-stealth vpn output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth vpn format" [] {
    [ "human" "json" ]
  }

  # VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)
  export extern "rev-stealth vpn" [
    --output-format: string@"nu-complete rev-stealth vpn output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --format: string@"nu-complete rev-stealth vpn format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth vpn rotate format" [] {
    [ "human" "json" ]
  }

  # Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold
  export extern "rev-stealth vpn rotate" [
    --provider: string        # VPN provider slug (currently only `surfshark`)
    --strategy: string        # Rotation strategy: `lazy-on-fail`, `every-n`, `interval`
    --region: string          # Optional region (`jp`, `us-west`, `de`, ...). Cycled through when omitted
    --reason: string          # Reason hint; recorded in the audit log for forensics
    --format: string@"nu-complete rev-stealth vpn rotate format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth vpn status format" [] {
    [ "human" "json" ]
  }

  # Show the current public IP and the VPN container state
  export extern "rev-stealth vpn status" [
    --provider: string        # Provider slug to scope the status query
    --format: string@"nu-complete rev-stealth vpn status format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth vpn help" [
  ]

  # Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold
  export extern "rev-stealth vpn help rotate" [
  ]

  # Show the current public IP and the VPN container state
  export extern "rev-stealth vpn help status" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth vpn help help" [
  ]

  def "nu-complete rev-stealth doctor doctor_format" [] {
    [ "json" "text" ]
  }

  def "nu-complete rev-stealth doctor format" [] {
    [ "human" "json" ]
  }

  # Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)
  export extern "rev-stealth doctor" [
    --container: string       # VPN container name to inspect
    --expected-country: string # Expected VPN exit country (ISO-2, e.g. "JP"). Skipped when omitted
    --output-format: string@"nu-complete rev-stealth doctor doctor_format" # Output format for doctor diagnostic results: `json` (machine-parseable, default) or `text` (human-readable)
    --skip-exit-ip            # Skip the live `ipinfo.io` exit-IP probe (offline / CI mode)
    --deep                    # v1.1.0 (P16): run extended stack health checks (obscura binary, VPN instance pool, sites recipe count, auth profile validity, AuthStore key source). The default check set stays minimal so the existing fail-closed contract (exit 7 on leak) is unchanged; `--deep` adds non-leak diagnostic WARN/FAIL items
    --vps                     # P10.3: run VPS deploy readiness checks (systemd unit prerequisites, dedicated user, /var/log + /var/lib dir permissions, credstore, chrome/xvfb-run on PATH, docker + gluetun image, DISPLAY env). FAIL items exit 3 (permanent); WARN-only stays exit 0. Independent from the leak-fail-closed contract used by the base checks
    --format: string@"nu-complete rev-stealth doctor format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth spider output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth spider format" [] {
    [ "human" "json" ]
  }

  # AUP-gated browse + optional CF eval + optional adaptive relocate
  export extern "rev-stealth spider" [
    --output-format: string@"nu-complete rev-stealth spider output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --url: string             # Target URL
    --session-id: string      # Session id (auto-generated when omitted)
    --mobile-preset: string   # Mobile fingerprint preset slug
    --cf-evaluate             # Evaluate Cloudflare Turnstile resilience (defender-testbed; no solver)
    --vpn                     # Route through `vpn-rotate` before launch
    --stable-id: string       # stable_id to locate via `stealth-parse` after navigation
    --threshold: string       # Similarity threshold for relocate
    --strict                  # Treat Ambiguous relocate as a hard failure (exit code 10)
    --i-have-authorization    # AUP bypass (logs a warn). Equivalent to env-ack for the day
    --obscura: path           # Path to the obscura binary. Overridable via env
    --parse-store: path       # Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`)
    --use-auth: string        # Replay stored auth cookies and browser headers from the named profile
    --auth-domain: string     # Auth AAD/domain context to load; defaults to the target host
    --http-only               # Skip obscura entirely and fetch via reqwest. Implies no JS execution, no CF eval, no DOM injection
    --auto-fallback           # When obscura launch / CDP fails, automatically retry with reqwest. Default true; set `--no-auto-fallback` to disable for deterministic agent workflows that need a hard exit-3 on browser failure
    --no-auto-fallback        # Explicit disable for `--auto-fallback` (overrides the default)
    --dump-html: path         # Dump the fetched HTML to the given path (UTF-8). With obscura, the post-render `document.documentElement.outerHTML` is captured (so SPAs land hydrated); with the reqwest fallback / `--http-only`, the raw response body is written. Parent directories are created as needed and the file is created with mode `0600` on Unix
    --wait-ms: string         # After obscura navigate completes, wait N milliseconds before dumping the HTML. Useful for SPA hydration. No-op on the reqwest fallback path
    --wait-selector: string   # After obscura navigate completes, wait until the given CSS selector appears in the DOM (max 30 seconds). Takes precedence over `--wait-ms`. No-op on the reqwest fallback path
    --require-vpn             # Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1` only in the sense that env can't be loosened further
    --allow-no-vpn            # Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1` (which is the only way to enforce the policy from outside the process)
    --vpn-instance: string    # Force this invocation to use the named VPN instance, overriding the HRW session-sticky pick. Useful for tests and reproducible runs. Must match a `name` in the configured `vpn_instances` list
    --proxy-tier: string      # Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"
    --no-fallback             # Disable the fallback chain; one attempt at the selected tier only
    --leak-poll-secs: string  # Polling interval (seconds) for the background leak monitor. Only honoured when `require_vpn=true`. Range [5, 300]; out-of-range values are clamped. Default 30s
    --no-cache                # Skip recipe lookup AND skeleton save for this invocation
    --cache-refresh           # Ignore any existing recipe, run full discovery, and overwrite the recipe on success
    --cache-only              # Hard-require a recipe hit. On miss, exit code 9 and do nothing
    --cache-ttl: string       # Treat recipes whose `last_verified` is older than DAYS as expired. Default: 30 days. Expired recipes are refreshed and overwritten
    --recipe-dir: path        # Override the recipe directory (defaults to `~/.rev_scraping/sites/`)
    --recipe-endpoint: string # When a recipe is hit and exposes API endpoints, call the endpoint matching this `purpose` directly via reqwest, skipping browser entirely
    --recipe-param: string    # Placeholder substitutions for the recipe endpoint URL. Repeatable; e.g. `--recipe-param username=alice --recipe-param id=42`
    --recipe-no-learn         # Disable Phase 7c auto-learning (Network capture + JS bundle scan + recipe upsert). Privacy-sensitive runs may opt out; the skeleton save still applies unless `--no-cache` is set. Default: off (i.e. learning is ON)
    --format: string@"nu-complete rev-stealth spider format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth relocate output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth relocate format" [] {
    [ "human" "json" ]
  }

  # Locate a previously fingerprinted element in a saved HTML or fresh URL
  export extern "rev-stealth relocate" [
    --output-format: string@"nu-complete rev-stealth relocate output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --session-id: string      # Session id (informational; not required to open the store)
    --stable-id: string       # stable_id of the element to locate
    --html-file: path         # Local HTML file to scan
    --url: string             # Remote URL to fetch (HTTP-only, no browser launch)
    --threshold: string       # Similarity threshold
    --parse-store: path       # Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`)
    --strict                  # Treat Ambiguous as exit 10
    --i-have-authorization    # AUP bypass (logs a warn). Required when `--url` targets a non-allowlisted host
    --require-vpn             # Phase 6c: fail-closed VPN-required guard. Applies to `--url` only; `--html-file` is a local read
    --allow-no-vpn
    --vpn-instance: string    # Phase 6d: force a specific VPN instance from the configured pool
    --proxy-tier: string      # Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"
    --no-fallback             # Disable the fallback chain; one attempt at the selected tier only
    --use-auth: string        # Replay stored auth cookies and browser headers from the named profile
    --auth-domain: string     # Auth AAD/domain context to load; defaults to the target host
    --format: string@"nu-complete rev-stealth relocate format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth cf-evaluate output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth cf-evaluate format" [] {
    [ "human" "json" ]
  }

  # Defender-testbed evaluation of Cloudflare Turnstile resilience
  export extern "rev-stealth cf-evaluate" [
    --output-format: string@"nu-complete rev-stealth cf-evaluate output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --url: string
    --session-id: string
    --i-have-authorization
    --obscura: path
    --require-vpn             # Phase 6c: fail-closed VPN-required guard. See spider --require-vpn
    --allow-no-vpn
    --vpn-instance: string    # Phase 6d: force a specific VPN instance from the configured pool
    --proxy-tier: string      # Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"
    --no-fallback             # Disable the fallback chain; one attempt at the selected tier only
    --leak-poll-secs: string  # Phase 6e: background leak monitor poll interval (seconds)
    --use-auth: string        # Replay stored auth cookies and browser headers from the named profile
    --auth-domain: string     # Auth AAD/domain context to load; defaults to the target host
    --format: string@"nu-complete rev-stealth cf-evaluate format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth auth format" [] {
    [ "human" "json" ]
  }

  # Authenticated session capture / lifecycle (Phase 9d). Subcommands: login / list / show / delete / status / refresh
  export extern "rev-stealth auth" [
    --output-format: string@"nu-complete rev-stealth auth output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --format: string@"nu-complete rev-stealth auth format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth login format" [] {
    [ "human" "json" ]
  }

  # Spawn `rev-auth` for interactive login; AUP-gated
  export extern "rev-stealth auth login" [
    --profile: string
    --url: string
    --domain: string
    --completion-pattern: string
    --obscura-bin: path
    --rev-auth-bin: path      # Override the `rev-auth` helper binary path (defaults to `which rev-auth`)
    --aad-context: string     # Additional AAD context (e.g. proxy route) bound to the cookie blob
    --require-vpn             # Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`
    --allow-no-vpn            # Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`
    --format: string@"nu-complete rev-stealth auth login format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth list format" [] {
    [ "human" "json" ]
  }

  # List saved profiles (metadata only, cookie values never disclosed)
  export extern "rev-stealth auth list" [
    --format: string@"nu-complete rev-stealth auth list format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth show format" [] {
    [ "human" "json" ]
  }

  # Show a single profile's metadata (redacted)
  export extern "rev-stealth auth show" [
    --profile: string
    --format: string@"nu-complete rev-stealth auth show format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth delete format" [] {
    [ "human" "json" ]
  }

  # Delete a profile with shred-on-delete
  export extern "rev-stealth auth delete" [
    --profile: string
    --force                   # Skip the interactive confirmation prompt
    --format: string@"nu-complete rev-stealth auth delete format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth status format" [] {
    [ "human" "json" ]
  }

  # Report freshness/expiry status for a profile
  export extern "rev-stealth auth status" [
    --profile: string
    --format: string@"nu-complete rev-stealth auth status format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth auth refresh format" [] {
    [ "human" "json" ]
  }

  # Re-run interactive login, overwriting an existing profile
  export extern "rev-stealth auth refresh" [
    --profile: string
    --url: string
    --domain: string
    --completion-pattern: string
    --obscura-bin: path
    --rev-auth-bin: path
    --aad-context: string
    --require-vpn             # Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`
    --allow-no-vpn            # Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`
    --format: string@"nu-complete rev-stealth auth refresh format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth auth help" [
  ]

  # Spawn `rev-auth` for interactive login; AUP-gated
  export extern "rev-stealth auth help login" [
  ]

  # List saved profiles (metadata only, cookie values never disclosed)
  export extern "rev-stealth auth help list" [
  ]

  # Show a single profile's metadata (redacted)
  export extern "rev-stealth auth help show" [
  ]

  # Delete a profile with shred-on-delete
  export extern "rev-stealth auth help delete" [
  ]

  # Report freshness/expiry status for a profile
  export extern "rev-stealth auth help status" [
  ]

  # Re-run interactive login, overwriting an existing profile
  export extern "rev-stealth auth help refresh" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth auth help help" [
  ]

  def "nu-complete rev-stealth measure output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth measure format" [] {
    [ "human" "json" ]
  }

  # v1.1.0 (P15): local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via `--enable-external`
  export extern "rev-stealth measure" [
    --output-format: string@"nu-complete rev-stealth measure output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --url: string             # URL to measure against. The page is not actually fetched unless `--enable-external` is set; we only validate the URL shape here
    --enable-external         # Opt-in to external fingerprint SaaS calls (CreepJS, bot.sannysoft.com, etc.). Default: disabled
    --enable-egress-probe     # P10.5: Opt-in to a VPS egress probe (HEAD request against a minimal endpoint) to measure exit IP / TLS / DNS leak after deploy. Even with this flag set, the probe is only active when the binary was built with the `vps-egress-probe` Cargo feature; otherwise a deterministic `disabled` stub is returned. Default: disabled
    --user-agent: string      # Optional override for the User-Agent we attribute the measurement to. When omitted we use a neutral rev-stealth placeholder
    --format: string@"nu-complete rev-stealth measure format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config config_output_format" [] {
    [ "text" "json" "yaml" ]
  }

  def "nu-complete rev-stealth config format" [] {
    [ "human" "json" ]
  }

  # v1.2.0 (P6.1): inspect the layered config (`show` / `paths` / `validate` / `diff` / `get`)
  export extern "rev-stealth config" [
    --output-format: string@"nu-complete rev-stealth config config_output_format" # Output format. Overrides the global `--format` only for this subtree
    --format: string@"nu-complete rev-stealth config format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config show format" [] {
    [ "human" "json" ]
  }

  # Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`
  export extern "rev-stealth config show" [
    --format: string@"nu-complete rev-stealth config show format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config paths format" [] {
    [ "human" "json" ]
  }

  # List each config file path (absolute), its existence, and permission bits (unix mode)
  export extern "rev-stealth config paths" [
    --format: string@"nu-complete rev-stealth config paths format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config validate format" [] {
    [ "human" "json" ]
  }

  # Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations
  export extern "rev-stealth config validate" [
    --format: string@"nu-complete rev-stealth config validate format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config diff format" [] {
    [ "human" "json" ]
  }

  # Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`
  export extern "rev-stealth config diff" [
    --against: path           # Override the baseline (defaults to `templates/policy.toml`)
    --format: string@"nu-complete rev-stealth config diff format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    path: path                # Path to the live config file (e.g. `~/.rev_scraping/policy.toml`)
  ]

  def "nu-complete rev-stealth config get format" [] {
    [ "human" "json" ]
  }

  # Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted
  export extern "rev-stealth config get" [
    --format: string@"nu-complete rev-stealth config get format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    key: string               # Dotted key, e.g. `policy.require_vpn` or `env.VPN_INSTANCES`
  ]

  def "nu-complete rev-stealth config set target" [] {
    [ "policy" "authorized" ]
  }

  def "nu-complete rev-stealth config set format" [] {
    [ "human" "json" ]
  }

  # P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back
  export extern "rev-stealth config set" [
    --target: string@"nu-complete rev-stealth config set target" # Which file to mutate. Defaults to `policy`
    --format: string@"nu-complete rev-stealth config set format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    key: string               # Dotted key, e.g. `policy.require_vpn` or `require_vpn`. A leading `policy.` / `authorized.` segment is treated as a layer hint and stripped before traversing the TOML document
    value: string             # Value as a literal token. Inferred as bool (`true`/`false`), int (all-digits, optional leading `-`), or string (everything else). To force string mode wrap the value in quotes from the shell
  ]

  def "nu-complete rev-stealth config edit target" [] {
    [ "policy" "authorized" ]
  }

  def "nu-complete rev-stealth config edit format" [] {
    [ "human" "json" ]
  }

  # P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits
  export extern "rev-stealth config edit" [
    --target: string@"nu-complete rev-stealth config edit target" # Which file to open. Defaults to `policy`
    --editor: string          # Override `$EDITOR`. Mostly for tests (e.g. `--editor "cp my.toml"`)
    --format: string@"nu-complete rev-stealth config edit format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config migrate format" [] {
    [ "human" "json" ]
  }

  # P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into
  export extern "rev-stealth config migrate" [
    --dry-run                 # Dry-run: print the migration plan without writing. (v1→v1 is a no-op either way; the flag is here so the future v2 migration path has a stable name.)
    --format: string@"nu-complete rev-stealth config migrate format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config init target" [] {
    [ "all" "policy" "authorized" "sites" ]
  }

  def "nu-complete rev-stealth config init format" [] {
    [ "human" "json" ]
  }

  # P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)
  export extern "rev-stealth config init" [
    --target: string@"nu-complete rev-stealth config init target" # Limit init to a single file. Default `all`
    --force                   # Overwrite existing files (routes through `.bak.<epoch>` backup via the P5.2 ConfigWriter — never destructive)
    --non-interactive         # Skip interactive confirmation. Required for CI / scripted use. The current implementation never prompts (init is non-destructive without --force), but the flag is reserved + tested so callers can adopt it now without a future breaking change
    --format: string@"nu-complete rev-stealth config init format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config history target" [] {
    [ "policy" "authorized" ]
  }

  def "nu-complete rev-stealth config history format" [] {
    [ "human" "json" ]
  }

  # P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)
  export extern "rev-stealth config history" [
    --target: string@"nu-complete rev-stealth config history target" # Which file's backups to list. Defaults to `policy`
    --format: string@"nu-complete rev-stealth config history format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config rollback target" [] {
    [ "policy" "authorized" ]
  }

  def "nu-complete rev-stealth config rollback format" [] {
    [ "human" "json" ]
  }

  # P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target's current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`
  export extern "rev-stealth config rollback" [
    --target: string@"nu-complete rev-stealth config rollback target" # Which file to roll back. Defaults to `policy`
    --format: string@"nu-complete rev-stealth config rollback format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    bak_name: string          # The exact backup filename to restore (e.g. `policy.toml.bak.1700000000000`). Resolved relative to the target file's parent directory. Path traversal is rejected
  ]

  def "nu-complete rev-stealth config gc target" [] {
    [ "policy" "authorized" ]
  }

  def "nu-complete rev-stealth config gc format" [] {
    [ "human" "json" ]
  }

  # P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched
  export extern "rev-stealth config gc" [
    --keep: string            # Number of newest backups to keep. Defaults to 5
    --target: string@"nu-complete rev-stealth config gc target" # Which file's backups to GC. Defaults to `policy`
    --format: string@"nu-complete rev-stealth config gc format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config profile format" [] {
    [ "human" "json" ]
  }

  # P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`
  export extern "rev-stealth config profile" [
    --format: string@"nu-complete rev-stealth config profile format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config profile list format" [] {
    [ "human" "json" ]
  }

  # List every profile directory under `<base>/profiles/`
  export extern "rev-stealth config profile list" [
    --format: string@"nu-complete rev-stealth config profile list format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth config profile create format" [] {
    [ "human" "json" ]
  }

  # Create a new profile directory and seed `policy.toml`, `authorized.toml`, and `sites/` via ConfigWriter (same skeleton as `config init`). Refuses if the profile already exists
  export extern "rev-stealth config profile create" [
    --format: string@"nu-complete rev-stealth config profile create format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    name: string              # Profile name. Must match `[A-Za-z0-9_-]{1,64}` (no `/`, `\`, `.`, whitespace, control chars). Path-traversal is rejected
  ]

  def "nu-complete rev-stealth config profile switch format" [] {
    [ "human" "json" ]
  }

  # Print the shell-export line needed to activate the profile. We never mutate the operator's environment from inside the process — the operator must eval/source the printed line
  export extern "rev-stealth config profile switch" [
    --format: string@"nu-complete rev-stealth config profile switch format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    name: string              # Profile name (must already exist)
  ]

  def "nu-complete rev-stealth config profile delete format" [] {
    [ "human" "json" ]
  }

  # Best-effort overwrite-then-delete (`shred-like`) for the profile directory. Refuses if the profile is currently active per `$REV_SCRAPING_HOME` resolution
  export extern "rev-stealth config profile delete" [
    --yes                     # Required for non-interactive deletion. Without it we exit 2 with an error so an operator typo cannot wipe a profile
    --format: string@"nu-complete rev-stealth config profile delete format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
    name: string              # Profile name to remove
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth config profile help" [
  ]

  # List every profile directory under `<base>/profiles/`
  export extern "rev-stealth config profile help list" [
  ]

  # Create a new profile directory and seed `policy.toml`, `authorized.toml`, and `sites/` via ConfigWriter (same skeleton as `config init`). Refuses if the profile already exists
  export extern "rev-stealth config profile help create" [
  ]

  # Print the shell-export line needed to activate the profile. We never mutate the operator's environment from inside the process — the operator must eval/source the printed line
  export extern "rev-stealth config profile help switch" [
  ]

  # Best-effort overwrite-then-delete (`shred-like`) for the profile directory. Refuses if the profile is currently active per `$REV_SCRAPING_HOME` resolution
  export extern "rev-stealth config profile help delete" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth config profile help help" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth config help" [
  ]

  # Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`
  export extern "rev-stealth config help show" [
  ]

  # List each config file path (absolute), its existence, and permission bits (unix mode)
  export extern "rev-stealth config help paths" [
  ]

  # Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations
  export extern "rev-stealth config help validate" [
  ]

  # Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`
  export extern "rev-stealth config help diff" [
  ]

  # Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted
  export extern "rev-stealth config help get" [
  ]

  # P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back
  export extern "rev-stealth config help set" [
  ]

  # P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits
  export extern "rev-stealth config help edit" [
  ]

  # P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into
  export extern "rev-stealth config help migrate" [
  ]

  # P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)
  export extern "rev-stealth config help init" [
  ]

  # P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)
  export extern "rev-stealth config help history" [
  ]

  # P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target's current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`
  export extern "rev-stealth config help rollback" [
  ]

  # P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched
  export extern "rev-stealth config help gc" [
  ]

  # P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`
  export extern "rev-stealth config help profile" [
  ]

  # List every profile directory under `<base>/profiles/`
  export extern "rev-stealth config help profile list" [
  ]

  # Create a new profile directory and seed `policy.toml`, `authorized.toml`, and `sites/` via ConfigWriter (same skeleton as `config init`). Refuses if the profile already exists
  export extern "rev-stealth config help profile create" [
  ]

  # Print the shell-export line needed to activate the profile. We never mutate the operator's environment from inside the process — the operator must eval/source the printed line
  export extern "rev-stealth config help profile switch" [
  ]

  # Best-effort overwrite-then-delete (`shred-like`) for the profile directory. Refuses if the profile is currently active per `$REV_SCRAPING_HOME` resolution
  export extern "rev-stealth config help profile delete" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth config help help" [
  ]

  def "nu-complete rev-stealth hermes output_format" [] {
    [ "human" "json" ]
  }

  def "nu-complete rev-stealth hermes format" [] {
    [ "human" "json" ]
  }

  # v1.2.0 (P7.3): manage the Hermes plugin scaffold (`install` / `uninstall` / `verify`)
  export extern "rev-stealth hermes" [
    --output-format: string@"nu-complete rev-stealth hermes output_format" # Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`
    --format: string@"nu-complete rev-stealth hermes format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth hermes install format" [] {
    [ "human" "json" ]
  }

  # Install the Hermes plugin scaffold into `<prefix>`
  export extern "rev-stealth hermes install" [
    --prefix: path            # Destination directory. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`
    --source: path            # Override the scaffold source directory (defaults to the `dist/hermes/rev-scraping-mcp` shipped with the repo)
    --force                   # Overwrite an existing non-empty destination
    --format: string@"nu-complete rev-stealth hermes install format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth hermes uninstall format" [] {
    [ "human" "json" ]
  }

  # Remove a previously installed Hermes plugin
  export extern "rev-stealth hermes uninstall" [
    --prefix: path            # Plugin directory to remove. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`
    --format: string@"nu-complete rev-stealth hermes uninstall format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  def "nu-complete rev-stealth hermes verify format" [] {
    [ "human" "json" ]
  }

  # Verify a Hermes plugin install on disk
  export extern "rev-stealth hermes verify" [
    --prefix: path            # Plugin directory to verify. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`
    --skip-python-check       # Skip the `python3 -c "import ast; ast.parse(...)"` syntax probe of `__init__.py`. The probe runs by default; pass this flag in environments without `python3` on `$PATH` (minimal containers, CI workers without the Python toolchain)
    --format: string@"nu-complete rev-stealth hermes verify format" # Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output
    --verbose(-v)             # Verbose logging (`-v`, `-vv`, `-vvv`)
    --help(-h)                # Print help (see more with '--help')
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth hermes help" [
  ]

  # Install the Hermes plugin scaffold into `<prefix>`
  export extern "rev-stealth hermes help install" [
  ]

  # Remove a previously installed Hermes plugin
  export extern "rev-stealth hermes help uninstall" [
  ]

  # Verify a Hermes plugin install on disk
  export extern "rev-stealth hermes help verify" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth hermes help help" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth help" [
  ]

  # CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)
  export extern "rev-stealth help captcha" [
  ]

  # Solve a CAPTCHA challenge
  export extern "rev-stealth help captcha solve" [
  ]

  # Verify a previously-issued token (round-trips through the challenge provider's verify endpoint)
  export extern "rev-stealth help captcha verify" [
  ]

  # Stealth browser operations (launch a profile, run a stealth-test sweep)
  export extern "rev-stealth help browser" [
  ]

  # Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host
  export extern "rev-stealth help browser launch" [
  ]

  # Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title
  export extern "rev-stealth help browser stealth-test" [
  ]

  # VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)
  export extern "rev-stealth help vpn" [
  ]

  # Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold
  export extern "rev-stealth help vpn rotate" [
  ]

  # Show the current public IP and the VPN container state
  export extern "rev-stealth help vpn status" [
  ]

  # Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)
  export extern "rev-stealth help doctor" [
  ]

  # AUP-gated browse + optional CF eval + optional adaptive relocate
  export extern "rev-stealth help spider" [
  ]

  # Locate a previously fingerprinted element in a saved HTML or fresh URL
  export extern "rev-stealth help relocate" [
  ]

  # Defender-testbed evaluation of Cloudflare Turnstile resilience
  export extern "rev-stealth help cf-evaluate" [
  ]

  # Authenticated session capture / lifecycle (Phase 9d). Subcommands: login / list / show / delete / status / refresh
  export extern "rev-stealth help auth" [
  ]

  # Spawn `rev-auth` for interactive login; AUP-gated
  export extern "rev-stealth help auth login" [
  ]

  # List saved profiles (metadata only, cookie values never disclosed)
  export extern "rev-stealth help auth list" [
  ]

  # Show a single profile's metadata (redacted)
  export extern "rev-stealth help auth show" [
  ]

  # Delete a profile with shred-on-delete
  export extern "rev-stealth help auth delete" [
  ]

  # Report freshness/expiry status for a profile
  export extern "rev-stealth help auth status" [
  ]

  # Re-run interactive login, overwriting an existing profile
  export extern "rev-stealth help auth refresh" [
  ]

  # v1.1.0 (P15): local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via `--enable-external`
  export extern "rev-stealth help measure" [
  ]

  # v1.2.0 (P6.1): inspect the layered config (`show` / `paths` / `validate` / `diff` / `get`)
  export extern "rev-stealth help config" [
  ]

  # Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`
  export extern "rev-stealth help config show" [
  ]

  # List each config file path (absolute), its existence, and permission bits (unix mode)
  export extern "rev-stealth help config paths" [
  ]

  # Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations
  export extern "rev-stealth help config validate" [
  ]

  # Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`
  export extern "rev-stealth help config diff" [
  ]

  # Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted
  export extern "rev-stealth help config get" [
  ]

  # P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back
  export extern "rev-stealth help config set" [
  ]

  # P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits
  export extern "rev-stealth help config edit" [
  ]

  # P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into
  export extern "rev-stealth help config migrate" [
  ]

  # P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)
  export extern "rev-stealth help config init" [
  ]

  # P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)
  export extern "rev-stealth help config history" [
  ]

  # P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target's current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`
  export extern "rev-stealth help config rollback" [
  ]

  # P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched
  export extern "rev-stealth help config gc" [
  ]

  # P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`
  export extern "rev-stealth help config profile" [
  ]

  # List every profile directory under `<base>/profiles/`
  export extern "rev-stealth help config profile list" [
  ]

  # Create a new profile directory and seed `policy.toml`, `authorized.toml`, and `sites/` via ConfigWriter (same skeleton as `config init`). Refuses if the profile already exists
  export extern "rev-stealth help config profile create" [
  ]

  # Print the shell-export line needed to activate the profile. We never mutate the operator's environment from inside the process — the operator must eval/source the printed line
  export extern "rev-stealth help config profile switch" [
  ]

  # Best-effort overwrite-then-delete (`shred-like`) for the profile directory. Refuses if the profile is currently active per `$REV_SCRAPING_HOME` resolution
  export extern "rev-stealth help config profile delete" [
  ]

  # v1.2.0 (P7.3): manage the Hermes plugin scaffold (`install` / `uninstall` / `verify`)
  export extern "rev-stealth help hermes" [
  ]

  # Install the Hermes plugin scaffold into `<prefix>`
  export extern "rev-stealth help hermes install" [
  ]

  # Remove a previously installed Hermes plugin
  export extern "rev-stealth help hermes uninstall" [
  ]

  # Verify a Hermes plugin install on disk
  export extern "rev-stealth help hermes verify" [
  ]

  # Print this message or the help of the given subcommand(s)
  export extern "rev-stealth help help" [
  ]

}

export use completions *
