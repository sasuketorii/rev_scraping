#compdef rev-stealth

autoload -U is-at-least

_rev-stealth() {
    typeset -A opt_args
    typeset -a _arguments_options
    local ret=1

    if is-at-least 5.2; then
        _arguments_options=(-s -S -C)
    else
        _arguments_options=(-s -C)
    fi

    local context curcontext="$curcontext" state line
    _arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
'-V[Print version]' \
'--version[Print version]' \
":: :_rev-stealth_commands" \
"*::: :->rev-stealth" \
&& ret=0
    case $state in
    (rev-stealth)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-command-$line[1]:"
        case $line[1] in
            (captcha)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__captcha_commands" \
"*::: :->captcha" \
&& ret=0

    case $state in
    (captcha)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-captcha-command-$line[1]:"
        case $line[1] in
            (solve)
_arguments "${_arguments_options[@]}" : \
'--type=[Challenge type\: \`recaptcha-v2\`, \`recaptcha-v3\`, \`hcaptcha\`, \`turnstile\`]:TYPE:_default' \
'--site-url=[Target site URL hosting the challenge]:URL:_default' \
'--site-key=[Sitekey (auto-detected if omitted on supported challenge types)]:KEY:_default' \
'--action=[reCAPTCHA v3 action label]:ACTION:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--dry-run[Skip the live solver and exercise the sidecar plumbing only. Useful for CI smoke tests]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
'--type=[Challenge type, same vocabulary as \`solve --type\`]:TYPE:_default' \
'--token=[Token returned by \`solve\`]:TOKEN:_default' \
'--secret=[Provider secret (loaded from env in production)]:SECRET:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__captcha__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-captcha-help-command-$line[1]:"
        case $line[1] in
            (solve)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(browser)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__browser_commands" \
"*::: :->browser" \
&& ret=0

    case $state in
    (browser)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-browser-command-$line[1]:"
        case $line[1] in
            (launch)
_arguments "${_arguments_options[@]}" : \
'--profile=[Profile slug. One of\: \`desktop\`, \`mobile-ios\`, \`mobile-android\`, \`ipad\`, \`galaxy-ultra\`]:PROFILE:_default' \
'--stealth=[Stealth level\: \`off\`, \`basic\`, \`full\`]:STEALTH:_default' \
'--url=[Navigate to this URL after launch. Default\: \`about\:blank\`]:URL:_default' \
'--chrome=[Override the chrome executable path. By default, chromiumoxide auto-detects the system chrome]:CHROME:_files' \
'--dwell=[Hold the page for this many seconds after navigation (lets a detector finish its work). Default 0 = exit as soon as \`document.readyState\` settles]:DWELL:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--headed[Run with a visible chrome window instead of new-headless mode]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(stealth-test)
_arguments "${_arguments_options[@]}" : \
'--target=[Detection page to probe]:TARGET:_default' \
'--profile=[]:PROFILE:_default' \
'--stealth=[]:STEALTH:_default' \
'--dwell=[]:DWELL:_default' \
'--chrome=[]:CHROME:_files' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--headed[]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__browser__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-browser-help-command-$line[1]:"
        case $line[1] in
            (launch)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(stealth-test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(vpn)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__vpn_commands" \
"*::: :->vpn" \
&& ret=0

    case $state in
    (vpn)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-vpn-command-$line[1]:"
        case $line[1] in
            (rotate)
_arguments "${_arguments_options[@]}" : \
'--provider=[VPN provider slug (currently only \`surfshark\`)]:PROVIDER:_default' \
'--strategy=[Rotation strategy\: \`lazy-on-fail\`, \`every-n\`, \`interval\`]:STRATEGY:_default' \
'--region=[Optional region (\`jp\`, \`us-west\`, \`de\`, ...). Cycled through when omitted]:REGION:_default' \
'--reason=[Reason hint; recorded in the audit log for forensics]:REASON:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'--provider=[Provider slug to scope the status query]:PROVIDER:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__vpn__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-vpn-help-command-$line[1]:"
        case $line[1] in
            (rotate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(doctor)
_arguments "${_arguments_options[@]}" : \
'--container=[VPN container name to inspect]:CONTAINER:_default' \
'--expected-country=[Expected VPN exit country (ISO-2, e.g. "JP"). Skipped when omitted]:EXPECTED_COUNTRY:_default' \
'--output-format=[Output format for doctor diagnostic results\: \`json\` (machine-parseable, default) or \`text\` (human-readable)]:OUTPUT_FORMAT:(json text)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--skip-exit-ip[Skip the live \`ipinfo.io\` exit-IP probe (offline / CI mode)]' \
'--deep[v1.1.0 (P16)\: run extended stack health checks (obscura binary, VPN instance pool, sites recipe count, auth profile validity, AuthStore key source). The default check set stays minimal so the existing fail-closed contract (exit 7 on leak) is unchanged; \`--deep\` adds non-leak diagnostic WARN/FAIL items]' \
'--vps[P10.3\: run VPS deploy readiness checks (systemd unit prerequisites, dedicated user, /var/log + /var/lib dir permissions, credstore, chrome/xvfb-run on PATH, docker + gluetun image, DISPLAY env). FAIL items exit 3 (permanent); WARN-only stays exit 0. Independent from the leak-fail-closed contract used by the base checks]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(spider)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--url=[Target URL]:URL:_default' \
'--session-id=[Session id (auto-generated when omitted)]:SESSION_ID:_default' \
'--mobile-preset=[Mobile fingerprint preset slug]:MOBILE_PRESET:_default' \
'--stable-id=[stable_id to locate via \`stealth-parse\` after navigation]:STABLE_ID:_default' \
'--threshold=[Similarity threshold for relocate]:THRESHOLD:_default' \
'--obscura=[Path to the obscura binary. Overridable via env]:OBSCURA:_files' \
'--parse-store=[Optional ParseStore path (defaults to \`~/.rev_scraping/parse.sqlite\`)]:PARSE_STORE:_files' \
'--use-auth=[Replay stored auth cookies and browser headers from the named profile]:USE_AUTH:_default' \
'--auth-domain=[Auth AAD/domain context to load; defaults to the target host]:AUTH_DOMAIN:_default' \
'--dump-html=[Dump the fetched HTML to the given path (UTF-8). With obscura, the post-render \`document.documentElement.outerHTML\` is captured (so SPAs land hydrated); with the reqwest fallback / \`--http-only\`, the raw response body is written. Parent directories are created as needed and the file is created with mode \`0600\` on Unix]:DUMP_HTML:_files' \
'--wait-ms=[After obscura navigate completes, wait N milliseconds before dumping the HTML. Useful for SPA hydration. No-op on the reqwest fallback path]:WAIT_MS:_default' \
'--wait-selector=[After obscura navigate completes, wait until the given CSS selector appears in the DOM (max 30 seconds). Takes precedence over \`--wait-ms\`. No-op on the reqwest fallback path]:WAIT_SELECTOR:_default' \
'--vpn-instance=[Force this invocation to use the named VPN instance, overriding the HRW session-sticky pick. Useful for tests and reproducible runs. Must match a \`name\` in the configured \`vpn_instances\` list]:VPN_INSTANCE:_default' \
'--proxy-tier=[Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with \`--vpn-instance\` unless the tier is exactly "surfshark"]:PROXY_TIER:_default' \
'--leak-poll-secs=[Polling interval (seconds) for the background leak monitor. Only honoured when \`require_vpn=true\`. Range \[5, 300\]; out-of-range values are clamped. Default 30s]:LEAK_POLL_SECS:_default' \
'--cache-ttl=[Treat recipes whose \`last_verified\` is older than DAYS as expired. Default\: 30 days. Expired recipes are refreshed and overwritten]:CACHE_TTL:_default' \
'--recipe-dir=[Override the recipe directory (defaults to \`~/.rev_scraping/sites/\`)]:RECIPE_DIR:_files' \
'--recipe-endpoint=[When a recipe is hit and exposes API endpoints, call the endpoint matching this \`purpose\` directly via reqwest, skipping browser entirely]:RECIPE_ENDPOINT:_default' \
'*--recipe-param=[Placeholder substitutions for the recipe endpoint URL. Repeatable; e.g. \`--recipe-param username=alice --recipe-param id=42\`]:KEY=VALUE:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--cf-evaluate[Evaluate Cloudflare Turnstile resilience (defender-testbed; no solver)]' \
'--vpn[Route through \`vpn-rotate\` before launch]' \
'--strict[Treat Ambiguous relocate as a hard failure (exit code 10)]' \
'--i-have-authorization[AUP bypass (logs a warn). Equivalent to env-ack for the day]' \
'--http-only[Skip obscura entirely and fetch via reqwest. Implies no JS execution, no CF eval, no DOM injection]' \
'--auto-fallback[When obscura launch / CDP fails, automatically retry with reqwest. Default true; set \`--no-auto-fallback\` to disable for deterministic agent workflows that need a hard exit-3 on browser failure]' \
'--no-auto-fallback[Explicit disable for \`--auto-fallback\` (overrides the default)]' \
'(--allow-no-vpn)--require-vpn[Force the VPN-required guard ON for this invocation. Wins over \`policy.toml\`. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\` only in the sense that env can'\''t be loosened further]' \
'(--require-vpn)--allow-no-vpn[Allow this invocation to proceed without a VPN. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\` (which is the only way to enforce the policy from outside the process)]' \
'--no-fallback[Disable the fallback chain; one attempt at the selected tier only]' \
'--no-cache[Skip recipe lookup AND skeleton save for this invocation]' \
'--cache-refresh[Ignore any existing recipe, run full discovery, and overwrite the recipe on success]' \
'--cache-only[Hard-require a recipe hit. On miss, exit code 9 and do nothing]' \
'--recipe-no-learn[Disable Phase 7c auto-learning (Network capture + JS bundle scan + recipe upsert). Privacy-sensitive runs may opt out; the skeleton save still applies unless \`--no-cache\` is set. Default\: off (i.e. learning is ON)]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(relocate)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--session-id=[Session id (informational; not required to open the store)]:SESSION_ID:_default' \
'--stable-id=[stable_id of the element to locate]:STABLE_ID:_default' \
'(--url)--html-file=[Local HTML file to scan]:HTML_FILE:_files' \
'--url=[Remote URL to fetch (HTTP-only, no browser launch)]:URL:_default' \
'--threshold=[Similarity threshold]:THRESHOLD:_default' \
'--parse-store=[Optional ParseStore path (defaults to \`~/.rev_scraping/parse.sqlite\`)]:PARSE_STORE:_files' \
'--vpn-instance=[Phase 6d\: force a specific VPN instance from the configured pool]:VPN_INSTANCE:_default' \
'--proxy-tier=[Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with \`--vpn-instance\` unless the tier is exactly "surfshark"]:PROXY_TIER:_default' \
'--use-auth=[Replay stored auth cookies and browser headers from the named profile]:USE_AUTH:_default' \
'--auth-domain=[Auth AAD/domain context to load; defaults to the target host]:AUTH_DOMAIN:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--strict[Treat Ambiguous as exit 10]' \
'--i-have-authorization[AUP bypass (logs a warn). Required when \`--url\` targets a non-allowlisted host]' \
'(--allow-no-vpn)--require-vpn[Phase 6c\: fail-closed VPN-required guard. Applies to \`--url\` only; \`--html-file\` is a local read]' \
'(--require-vpn)--allow-no-vpn[]' \
'--no-fallback[Disable the fallback chain; one attempt at the selected tier only]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(cf-evaluate)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--url=[]:URL:_default' \
'--session-id=[]:SESSION_ID:_default' \
'--obscura=[]:OBSCURA:_files' \
'--vpn-instance=[Phase 6d\: force a specific VPN instance from the configured pool]:VPN_INSTANCE:_default' \
'--proxy-tier=[Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with \`--vpn-instance\` unless the tier is exactly "surfshark"]:PROXY_TIER:_default' \
'--leak-poll-secs=[Phase 6e\: background leak monitor poll interval (seconds)]:LEAK_POLL_SECS:_default' \
'--use-auth=[Replay stored auth cookies and browser headers from the named profile]:USE_AUTH:_default' \
'--auth-domain=[Auth AAD/domain context to load; defaults to the target host]:AUTH_DOMAIN:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--i-have-authorization[]' \
'(--allow-no-vpn)--require-vpn[Phase 6c\: fail-closed VPN-required guard. See spider --require-vpn]' \
'(--require-vpn)--allow-no-vpn[]' \
'--no-fallback[Disable the fallback chain; one attempt at the selected tier only]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__auth_commands" \
"*::: :->auth" \
&& ret=0

    case $state in
    (auth)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-auth-command-$line[1]:"
        case $line[1] in
            (login)
_arguments "${_arguments_options[@]}" : \
'--profile=[]:PROFILE:_default' \
'--url=[]:URL:_default' \
'--domain=[]:DOMAIN:_default' \
'--completion-pattern=[]:COMPLETION_PATTERN:_default' \
'--obscura-bin=[]:OBSCURA_BIN:_files' \
'--rev-auth-bin=[Override the \`rev-auth\` helper binary path (defaults to \`which rev-auth\`)]:REV_AUTH_BIN:_files' \
'--aad-context=[Additional AAD context (e.g. proxy route) bound to the cookie blob]:AAD_CONTEXT:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'(--allow-no-vpn)--require-vpn[Force the VPN-required guard ON for this invocation. Wins over \`policy.toml\`. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\`]' \
'(--require-vpn)--allow-no-vpn[Allow this invocation to proceed without a VPN. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\`]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
'--profile=[]:PROFILE:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
'--profile=[]:PROFILE:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--force[Skip the interactive confirmation prompt]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'--profile=[]:PROFILE:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(refresh)
_arguments "${_arguments_options[@]}" : \
'--profile=[]:PROFILE:_default' \
'--url=[]:URL:_default' \
'--domain=[]:DOMAIN:_default' \
'--completion-pattern=[]:COMPLETION_PATTERN:_default' \
'--obscura-bin=[]:OBSCURA_BIN:_files' \
'--rev-auth-bin=[]:REV_AUTH_BIN:_files' \
'--aad-context=[]:AAD_CONTEXT:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'(--allow-no-vpn)--require-vpn[Force the VPN-required guard ON for this invocation. Wins over \`policy.toml\`. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\`]' \
'(--require-vpn)--allow-no-vpn[Allow this invocation to proceed without a VPN. Loses to env \`REV_SCRAPING_REQUIRE_VPN=1\`]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__auth__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-auth-help-command-$line[1]:"
        case $line[1] in
            (login)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(refresh)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(measure)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--url=[URL to measure against. The page is not actually fetched unless \`--enable-external\` is set; we only validate the URL shape here]:URL:_default' \
'--user-agent=[Optional override for the User-Agent we attribute the measurement to. When omitted we use a neutral rev-stealth placeholder]:USER_AGENT:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--enable-external[Opt-in to external fingerprint SaaS calls (CreepJS, bot.sannysoft.com, etc.). Default\: disabled]' \
'--enable-egress-probe[P10.5\: Opt-in to a VPS egress probe (HEAD request against a minimal endpoint) to measure exit IP / TLS / DNS leak after deploy. Even with this flag set, the probe is only active when the binary was built with the \`vps-egress-probe\` Cargo feature; otherwise a deterministic \`disabled\` stub is returned. Default\: disabled]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(config)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format. Overrides the global \`--format\` only for this subtree]:config_output_format:(text json yaml)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__config_commands" \
"*::: :->config" \
&& ret=0

    case $state in
    (config)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-config-command-$line[1]:"
        case $line[1] in
            (show)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(paths)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(validate)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(diff)
_arguments "${_arguments_options[@]}" : \
'--against=[Override the baseline (defaults to \`templates/policy.toml\`)]:AGAINST:_files' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- Path to the live config file (e.g. `~/.rev_scraping/policy.toml`):_files' \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':key -- Dotted key, e.g. `policy.require_vpn` or `env.VPN_INSTANCES`:_default' \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
'--target=[Which file to mutate. Defaults to \`policy\`]:TARGET:(policy authorized)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':key -- Dotted key, e.g. `policy.require_vpn` or `require_vpn`. A leading `policy.` / `authorized.` segment is treated as a layer hint and stripped before traversing the TOML document:_default' \
':value -- Value as a literal token. Inferred as bool (`true`/`false`), int (all-digits, optional leading `-`), or string (everything else). To force string mode wrap the value in quotes from the shell:_default' \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
'--target=[Which file to open. Defaults to \`policy\`]:TARGET:(policy authorized)' \
'--editor=[Override \`\$EDITOR\`. Mostly for tests (e.g. \`--editor "cp my.toml"\`)]:EDITOR:_default' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(migrate)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--dry-run[Dry-run\: print the migration plan without writing. (v1→v1 is a no-op either way; the flag is here so the future v2 migration path has a stable name.)]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(init)
_arguments "${_arguments_options[@]}" : \
'--target=[Limit init to a single file. Default \`all\`]:TARGET:(all policy authorized sites)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--force[Overwrite existing files (routes through \`.bak.<epoch>\` backup via the P5.2 ConfigWriter — never destructive)]' \
'--non-interactive[Skip interactive confirmation. Required for CI / scripted use. The current implementation never prompts (init is non-destructive without --force), but the flag is reserved + tested so callers can adopt it now without a future breaking change]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
'--target=[Which file'\''s backups to list. Defaults to \`policy\`]:TARGET:(policy authorized)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(rollback)
_arguments "${_arguments_options[@]}" : \
'--target=[Which file to roll back. Defaults to \`policy\`]:TARGET:(policy authorized)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':bak_name -- The exact backup filename to restore (e.g. `policy.toml.bak.1700000000000`). Resolved relative to the target file'\''s parent directory. Path traversal is rejected:_default' \
&& ret=0
;;
(gc)
_arguments "${_arguments_options[@]}" : \
'--keep=[Number of newest backups to keep. Defaults to 5]:KEEP:_default' \
'--target=[Which file'\''s backups to GC. Defaults to \`policy\`]:TARGET:(policy authorized)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(profile)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__config__subcmd__profile_commands" \
"*::: :->profile" \
&& ret=0

    case $state in
    (profile)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-config-profile-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Profile name. Must match `\[A-Za-z0-9_-\]{1,64}` (no `/`, `\`, `.`, whitespace, control chars). Path-traversal is rejected:_default' \
&& ret=0
;;
(switch)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Profile name (must already exist):_default' \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--yes[Required for non-interactive deletion. Without it we exit 2 with an error so an operator typo cannot wipe a profile]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Profile name to remove:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__config__subcmd__profile__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-config-profile-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(switch)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__config__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-config-help-command-$line[1]:"
        case $line[1] in
            (show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(paths)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(validate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(diff)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(migrate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(init)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(rollback)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(gc)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(profile)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__config__subcmd__help__subcmd__profile_commands" \
"*::: :->profile" \
&& ret=0

    case $state in
    (profile)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-config-help-profile-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(switch)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(hermes)
_arguments "${_arguments_options[@]}" : \
'--output-format=[Output format for this subcommand\: \`human\` (default) or \`json\`. Shadows the global \`--format\` for this invocation. Same value enum as the global flag; the JSON output is documented under \`docs/json-schemas/cli/<subcommand>.output.json\`]:OUTPUT_FORMAT:(human json)' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_rev-stealth__subcmd__hermes_commands" \
"*::: :->hermes" \
&& ret=0

    case $state in
    (hermes)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-hermes-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
'--prefix=[Destination directory. Defaults to \`\$HOME/.hermes/plugins/rev-scraping-mcp\`]:PREFIX:_files' \
'--source=[Override the scaffold source directory (defaults to the \`dist/hermes/rev-scraping-mcp\` shipped with the repo)]:SOURCE:_files' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--force[Overwrite an existing non-empty destination]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
'--prefix=[Plugin directory to remove. Defaults to \`\$HOME/.hermes/plugins/rev-scraping-mcp\`]:PREFIX:_files' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
'--prefix=[Plugin directory to verify. Defaults to \`\$HOME/.hermes/plugins/rev-scraping-mcp\`]:PREFIX:_files' \
'--format=[Output format for agent / human consumers. Default \`human\`; pass \`json\` for machine-parseable output]:FORMAT:(human json)' \
'--skip-python-check[Skip the \`python3 -c "import ast; ast.parse(...)"\` syntax probe of \`__init__.py\`. The probe runs by default; pass this flag in environments without \`python3\` on \`\$PATH\` (minimal containers, CI workers without the Python toolchain)]' \
'*-v[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'*--verbose[Verbose logging (\`-v\`, \`-vv\`, \`-vvv\`)]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__hermes__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-hermes-help-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-command-$line[1]:"
        case $line[1] in
            (captcha)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__captcha_commands" \
"*::: :->captcha" \
&& ret=0

    case $state in
    (captcha)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-captcha-command-$line[1]:"
        case $line[1] in
            (solve)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(browser)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__browser_commands" \
"*::: :->browser" \
&& ret=0

    case $state in
    (browser)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-browser-command-$line[1]:"
        case $line[1] in
            (launch)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(stealth-test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(vpn)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__vpn_commands" \
"*::: :->vpn" \
&& ret=0

    case $state in
    (vpn)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-vpn-command-$line[1]:"
        case $line[1] in
            (rotate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(doctor)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(spider)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(relocate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(cf-evaluate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__auth_commands" \
"*::: :->auth" \
&& ret=0

    case $state in
    (auth)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-auth-command-$line[1]:"
        case $line[1] in
            (login)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(refresh)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(measure)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(config)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__config_commands" \
"*::: :->config" \
&& ret=0

    case $state in
    (config)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-config-command-$line[1]:"
        case $line[1] in
            (show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(paths)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(validate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(diff)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(migrate)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(init)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(rollback)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(gc)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(profile)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__config__subcmd__profile_commands" \
"*::: :->profile" \
&& ret=0

    case $state in
    (profile)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-config-profile-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(switch)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(hermes)
_arguments "${_arguments_options[@]}" : \
":: :_rev-stealth__subcmd__help__subcmd__hermes_commands" \
"*::: :->hermes" \
&& ret=0

    case $state in
    (hermes)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:rev-stealth-help-hermes-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(verify)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
}

(( $+functions[_rev-stealth_commands] )) ||
_rev-stealth_commands() {
    local commands; commands=(
'captcha:CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)' \
'browser:Stealth browser operations (launch a profile, run a stealth-test sweep)' \
'vpn:VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)' \
'doctor:Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)' \
'spider:AUP-gated browse + optional CF eval + optional adaptive relocate' \
'relocate:Locate a previously fingerprinted element in a saved HTML or fresh URL' \
'cf-evaluate:Defender-testbed evaluation of Cloudflare Turnstile resilience' \
'auth:Authenticated session capture / lifecycle (Phase 9d). Subcommands\: login / list / show / delete / status / refresh' \
'measure:v1.1.0 (P15)\: local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via \`--enable-external\`' \
'config:v1.2.0 (P6.1)\: inspect the layered config (\`show\` / \`paths\` / \`validate\` / \`diff\` / \`get\`)' \
'hermes:v1.2.0 (P7.3)\: manage the Hermes plugin scaffold (\`install\` / \`uninstall\` / \`verify\`)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth_commands] )) ||
_rev-stealth__subcmd__auth_commands() {
    local commands; commands=(
'login:Spawn \`rev-auth\` for interactive login; AUP-gated' \
'list:List saved profiles (metadata only, cookie values never disclosed)' \
'show:Show a single profile'\''s metadata (redacted)' \
'delete:Delete a profile with shred-on-delete' \
'status:Report freshness/expiry status for a profile' \
'refresh:Re-run interactive login, overwriting an existing profile' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth auth commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help_commands() {
    local commands; commands=(
'login:Spawn \`rev-auth\` for interactive login; AUP-gated' \
'list:List saved profiles (metadata only, cookie values never disclosed)' \
'show:Show a single profile'\''s metadata (redacted)' \
'delete:Delete a profile with shred-on-delete' \
'status:Report freshness/expiry status for a profile' \
'refresh:Re-run interactive login, overwriting an existing profile' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth auth help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__list_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__login_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__login_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help login commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__refresh_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__refresh_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help refresh commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__show_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__help__subcmd__status_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth help status commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__list_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__login_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__login_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth login commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__refresh_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__refresh_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth refresh commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__show_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__auth__subcmd__status_commands] )) ||
_rev-stealth__subcmd__auth__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth auth status commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser_commands] )) ||
_rev-stealth__subcmd__browser_commands() {
    local commands; commands=(
'launch:Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host' \
'stealth-test:Run a stealth self-test\: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth browser commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__help_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__help_commands() {
    local commands; commands=(
'launch:Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host' \
'stealth-test:Run a stealth self-test\: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth browser help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth browser help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__help__subcmd__launch_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__help__subcmd__launch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth browser help launch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__help__subcmd__stealth-test_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__help__subcmd__stealth-test_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth browser help stealth-test commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__launch_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__launch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth browser launch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__browser__subcmd__stealth-test_commands] )) ||
_rev-stealth__subcmd__browser__subcmd__stealth-test_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth browser stealth-test commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha_commands] )) ||
_rev-stealth__subcmd__captcha_commands() {
    local commands; commands=(
'solve:Solve a CAPTCHA challenge' \
'verify:Verify a previously-issued token (round-trips through the challenge provider'\''s verify endpoint)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth captcha commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__help_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__help_commands() {
    local commands; commands=(
'solve:Solve a CAPTCHA challenge' \
'verify:Verify a previously-issued token (round-trips through the challenge provider'\''s verify endpoint)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth captcha help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth captcha help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__help__subcmd__solve_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__help__subcmd__solve_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth captcha help solve commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__help__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__help__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth captcha help verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__solve_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__solve_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth captcha solve commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__captcha__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__captcha__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth captcha verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__cf-evaluate_commands] )) ||
_rev-stealth__subcmd__cf-evaluate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth cf-evaluate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config_commands] )) ||
_rev-stealth__subcmd__config_commands() {
    local commands; commands=(
'show:Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with \`<redacted>\`' \
'paths:List each config file path (absolute), its existence, and permission bits (unix mode)' \
'validate:Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations' \
'diff:Print a unified diff between the live \`<path>\` and the in-repo \`templates/policy.toml\` baseline. Headers use \`---\` / \`+++\`' \
'get:Resolve a dotted key path (e.g. \`policy.require_vpn\`) against the merged config and print the value. Secret-looking values redacted' \
'set:P6.3\: Set a dotted-path key on \`policy.toml\` (or another target file) to a value. Type is inferred from the literal text (\`true\`/\`false\` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back' \
'edit:P6.3\: Open the target file in \`\$EDITOR\` (falling back to \`vi\`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + \`.bak.<epoch>\`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits' \
'migrate:P6.3\: Migrate \`policy.toml\` (and authorized.toml) from its current \`schema_version\` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into' \
'init:P6.2\: Initialize the per-user config tree under \`~/.rev_scraping/\` (or \`\$REV_SCRAPING_HOME\`). Creates \`policy.toml\` (0600), \`authorized.toml\` (0600), and \`sites/\` (0700) via the atomic ConfigWriter. Existing files are preserved unless \`--force\` is passed (which routes the overwrite through \`.bak.<epoch>\` backup)' \
'history:P6.4\: List the \`.bak.<epoch>\` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)' \
'rollback:P6.4\: Restore a previously captured \`.bak.<epoch>\` backup onto the target'\''s current path. The current file (if any) is preserved as a fresh \`.bak.<epoch>\` by routing the restore write through \`ConfigWriter\:\:write_with_backup\`' \
'gc:P6.4\: Garbage-collect \`.bak.<epoch>\` backups for the target config file, keeping the newest \`--keep\` (default 5). All older backups are deleted; the current file is untouched' \
'profile:P6.5\: Manage per-profile config trees under \`<base>/profiles/<name>/\`. Profiles share the same internal layout as the top-level config (\`policy.toml\`, \`authorized.toml\`, \`sites/\`) and are activated by exporting \`REV_SCRAPING_HOME=<base>/profiles/<name>\`' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth config commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__diff_commands] )) ||
_rev-stealth__subcmd__config__subcmd__diff_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config diff commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__edit_commands] )) ||
_rev-stealth__subcmd__config__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config edit commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__gc_commands] )) ||
_rev-stealth__subcmd__config__subcmd__gc_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config gc commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__get_commands] )) ||
_rev-stealth__subcmd__config__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config get commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help_commands() {
    local commands; commands=(
'show:Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with \`<redacted>\`' \
'paths:List each config file path (absolute), its existence, and permission bits (unix mode)' \
'validate:Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations' \
'diff:Print a unified diff between the live \`<path>\` and the in-repo \`templates/policy.toml\` baseline. Headers use \`---\` / \`+++\`' \
'get:Resolve a dotted key path (e.g. \`policy.require_vpn\`) against the merged config and print the value. Secret-looking values redacted' \
'set:P6.3\: Set a dotted-path key on \`policy.toml\` (or another target file) to a value. Type is inferred from the literal text (\`true\`/\`false\` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back' \
'edit:P6.3\: Open the target file in \`\$EDITOR\` (falling back to \`vi\`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + \`.bak.<epoch>\`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits' \
'migrate:P6.3\: Migrate \`policy.toml\` (and authorized.toml) from its current \`schema_version\` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into' \
'init:P6.2\: Initialize the per-user config tree under \`~/.rev_scraping/\` (or \`\$REV_SCRAPING_HOME\`). Creates \`policy.toml\` (0600), \`authorized.toml\` (0600), and \`sites/\` (0700) via the atomic ConfigWriter. Existing files are preserved unless \`--force\` is passed (which routes the overwrite through \`.bak.<epoch>\` backup)' \
'history:P6.4\: List the \`.bak.<epoch>\` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)' \
'rollback:P6.4\: Restore a previously captured \`.bak.<epoch>\` backup onto the target'\''s current path. The current file (if any) is preserved as a fresh \`.bak.<epoch>\` by routing the restore write through \`ConfigWriter\:\:write_with_backup\`' \
'gc:P6.4\: Garbage-collect \`.bak.<epoch>\` backups for the target config file, keeping the newest \`--keep\` (default 5). All older backups are deleted; the current file is untouched' \
'profile:P6.5\: Manage per-profile config trees under \`<base>/profiles/<name>/\`. Profiles share the same internal layout as the top-level config (\`policy.toml\`, \`authorized.toml\`, \`sites/\`) and are activated by exporting \`REV_SCRAPING_HOME=<base>/profiles/<name>\`' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth config help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__diff_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__diff_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help diff commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__edit_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help edit commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__gc_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__gc_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help gc commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__get_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help get commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__history_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help history commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__init_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help init commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__migrate_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__migrate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help migrate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__paths_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__paths_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help paths commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__profile_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__profile_commands() {
    local commands; commands=(
'list:List every profile directory under \`<base>/profiles/\`' \
'create:Create a new profile directory and seed \`policy.toml\`, \`authorized.toml\`, and \`sites/\` via ConfigWriter (same skeleton as \`config init\`). Refuses if the profile already exists' \
'switch:Print the shell-export line needed to activate the profile. We never mutate the operator'\''s environment from inside the process — the operator must eval/source the printed line' \
'delete:Best-effort overwrite-then-delete (\`shred-like\`) for the profile directory. Refuses if the profile is currently active per \`\$REV_SCRAPING_HOME\` resolution' \
    )
    _describe -t commands 'rev-stealth config help profile commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__create_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help profile create commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help profile delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__list_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help profile list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__switch_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__switch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help profile switch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__rollback_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__rollback_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help rollback commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__set_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help set commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__show_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__help__subcmd__validate_commands] )) ||
_rev-stealth__subcmd__config__subcmd__help__subcmd__validate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config help validate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__history_commands] )) ||
_rev-stealth__subcmd__config__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config history commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__init_commands] )) ||
_rev-stealth__subcmd__config__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config init commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__migrate_commands] )) ||
_rev-stealth__subcmd__config__subcmd__migrate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config migrate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__paths_commands] )) ||
_rev-stealth__subcmd__config__subcmd__paths_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config paths commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile_commands() {
    local commands; commands=(
'list:List every profile directory under \`<base>/profiles/\`' \
'create:Create a new profile directory and seed \`policy.toml\`, \`authorized.toml\`, and \`sites/\` via ConfigWriter (same skeleton as \`config init\`). Refuses if the profile already exists' \
'switch:Print the shell-export line needed to activate the profile. We never mutate the operator'\''s environment from inside the process — the operator must eval/source the printed line' \
'delete:Best-effort overwrite-then-delete (\`shred-like\`) for the profile directory. Refuses if the profile is currently active per \`\$REV_SCRAPING_HOME\` resolution' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth config profile commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__create_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile create commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help_commands() {
    local commands; commands=(
'list:List every profile directory under \`<base>/profiles/\`' \
'create:Create a new profile directory and seed \`policy.toml\`, \`authorized.toml\`, and \`sites/\` via ConfigWriter (same skeleton as \`config init\`). Refuses if the profile already exists' \
'switch:Print the shell-export line needed to activate the profile. We never mutate the operator'\''s environment from inside the process — the operator must eval/source the printed line' \
'delete:Best-effort overwrite-then-delete (\`shred-like\`) for the profile directory. Refuses if the profile is currently active per \`\$REV_SCRAPING_HOME\` resolution' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth config profile help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__create_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile help create commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile help delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__list_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile help list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__switch_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__switch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile help switch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__list_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__profile__subcmd__switch_commands] )) ||
_rev-stealth__subcmd__config__subcmd__profile__subcmd__switch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config profile switch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__rollback_commands] )) ||
_rev-stealth__subcmd__config__subcmd__rollback_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config rollback commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__set_commands] )) ||
_rev-stealth__subcmd__config__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config set commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__show_commands] )) ||
_rev-stealth__subcmd__config__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__config__subcmd__validate_commands] )) ||
_rev-stealth__subcmd__config__subcmd__validate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth config validate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__doctor_commands] )) ||
_rev-stealth__subcmd__doctor_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth doctor commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help_commands] )) ||
_rev-stealth__subcmd__help_commands() {
    local commands; commands=(
'captcha:CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)' \
'browser:Stealth browser operations (launch a profile, run a stealth-test sweep)' \
'vpn:VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)' \
'doctor:Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)' \
'spider:AUP-gated browse + optional CF eval + optional adaptive relocate' \
'relocate:Locate a previously fingerprinted element in a saved HTML or fresh URL' \
'cf-evaluate:Defender-testbed evaluation of Cloudflare Turnstile resilience' \
'auth:Authenticated session capture / lifecycle (Phase 9d). Subcommands\: login / list / show / delete / status / refresh' \
'measure:v1.1.0 (P15)\: local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via \`--enable-external\`' \
'config:v1.2.0 (P6.1)\: inspect the layered config (\`show\` / \`paths\` / \`validate\` / \`diff\` / \`get\`)' \
'hermes:v1.2.0 (P7.3)\: manage the Hermes plugin scaffold (\`install\` / \`uninstall\` / \`verify\`)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth_commands() {
    local commands; commands=(
'login:Spawn \`rev-auth\` for interactive login; AUP-gated' \
'list:List saved profiles (metadata only, cookie values never disclosed)' \
'show:Show a single profile'\''s metadata (redacted)' \
'delete:Delete a profile with shred-on-delete' \
'status:Report freshness/expiry status for a profile' \
'refresh:Re-run interactive login, overwriting an existing profile' \
    )
    _describe -t commands 'rev-stealth help auth commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__list_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__login_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__login_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth login commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__refresh_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__refresh_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth refresh commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__show_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__auth__subcmd__status_commands] )) ||
_rev-stealth__subcmd__help__subcmd__auth__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help auth status commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__browser_commands] )) ||
_rev-stealth__subcmd__help__subcmd__browser_commands() {
    local commands; commands=(
'launch:Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host' \
'stealth-test:Run a stealth self-test\: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title' \
    )
    _describe -t commands 'rev-stealth help browser commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__browser__subcmd__launch_commands] )) ||
_rev-stealth__subcmd__help__subcmd__browser__subcmd__launch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help browser launch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__browser__subcmd__stealth-test_commands] )) ||
_rev-stealth__subcmd__help__subcmd__browser__subcmd__stealth-test_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help browser stealth-test commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__captcha_commands] )) ||
_rev-stealth__subcmd__help__subcmd__captcha_commands() {
    local commands; commands=(
'solve:Solve a CAPTCHA challenge' \
'verify:Verify a previously-issued token (round-trips through the challenge provider'\''s verify endpoint)' \
    )
    _describe -t commands 'rev-stealth help captcha commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__captcha__subcmd__solve_commands] )) ||
_rev-stealth__subcmd__help__subcmd__captcha__subcmd__solve_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help captcha solve commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__captcha__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__help__subcmd__captcha__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help captcha verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__cf-evaluate_commands] )) ||
_rev-stealth__subcmd__help__subcmd__cf-evaluate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help cf-evaluate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config_commands() {
    local commands; commands=(
'show:Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with \`<redacted>\`' \
'paths:List each config file path (absolute), its existence, and permission bits (unix mode)' \
'validate:Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations' \
'diff:Print a unified diff between the live \`<path>\` and the in-repo \`templates/policy.toml\` baseline. Headers use \`---\` / \`+++\`' \
'get:Resolve a dotted key path (e.g. \`policy.require_vpn\`) against the merged config and print the value. Secret-looking values redacted' \
'set:P6.3\: Set a dotted-path key on \`policy.toml\` (or another target file) to a value. Type is inferred from the literal text (\`true\`/\`false\` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back' \
'edit:P6.3\: Open the target file in \`\$EDITOR\` (falling back to \`vi\`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + \`.bak.<epoch>\`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits' \
'migrate:P6.3\: Migrate \`policy.toml\` (and authorized.toml) from its current \`schema_version\` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into' \
'init:P6.2\: Initialize the per-user config tree under \`~/.rev_scraping/\` (or \`\$REV_SCRAPING_HOME\`). Creates \`policy.toml\` (0600), \`authorized.toml\` (0600), and \`sites/\` (0700) via the atomic ConfigWriter. Existing files are preserved unless \`--force\` is passed (which routes the overwrite through \`.bak.<epoch>\` backup)' \
'history:P6.4\: List the \`.bak.<epoch>\` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)' \
'rollback:P6.4\: Restore a previously captured \`.bak.<epoch>\` backup onto the target'\''s current path. The current file (if any) is preserved as a fresh \`.bak.<epoch>\` by routing the restore write through \`ConfigWriter\:\:write_with_backup\`' \
'gc:P6.4\: Garbage-collect \`.bak.<epoch>\` backups for the target config file, keeping the newest \`--keep\` (default 5). All older backups are deleted; the current file is untouched' \
'profile:P6.5\: Manage per-profile config trees under \`<base>/profiles/<name>/\`. Profiles share the same internal layout as the top-level config (\`policy.toml\`, \`authorized.toml\`, \`sites/\`) and are activated by exporting \`REV_SCRAPING_HOME=<base>/profiles/<name>\`' \
    )
    _describe -t commands 'rev-stealth help config commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__diff_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__diff_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config diff commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__edit_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config edit commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__gc_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__gc_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config gc commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__get_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config get commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__history_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config history commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__init_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config init commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__migrate_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__migrate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config migrate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__paths_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__paths_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config paths commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__profile_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__profile_commands() {
    local commands; commands=(
'list:List every profile directory under \`<base>/profiles/\`' \
'create:Create a new profile directory and seed \`policy.toml\`, \`authorized.toml\`, and \`sites/\` via ConfigWriter (same skeleton as \`config init\`). Refuses if the profile already exists' \
'switch:Print the shell-export line needed to activate the profile. We never mutate the operator'\''s environment from inside the process — the operator must eval/source the printed line' \
'delete:Best-effort overwrite-then-delete (\`shred-like\`) for the profile directory. Refuses if the profile is currently active per \`\$REV_SCRAPING_HOME\` resolution' \
    )
    _describe -t commands 'rev-stealth help config profile commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__create_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config profile create commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__delete_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config profile delete commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__list_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config profile list commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__switch_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__switch_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config profile switch commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__rollback_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__rollback_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config rollback commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__set_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config set commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__show_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config show commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__config__subcmd__validate_commands] )) ||
_rev-stealth__subcmd__help__subcmd__config__subcmd__validate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help config validate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__doctor_commands] )) ||
_rev-stealth__subcmd__help__subcmd__doctor_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help doctor commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__hermes_commands] )) ||
_rev-stealth__subcmd__help__subcmd__hermes_commands() {
    local commands; commands=(
'install:Install the Hermes plugin scaffold into \`<prefix>\`' \
'uninstall:Remove a previously installed Hermes plugin' \
'verify:Verify a Hermes plugin install on disk' \
    )
    _describe -t commands 'rev-stealth help hermes commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__hermes__subcmd__install_commands] )) ||
_rev-stealth__subcmd__help__subcmd__hermes__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help hermes install commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__hermes__subcmd__uninstall_commands] )) ||
_rev-stealth__subcmd__help__subcmd__hermes__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help hermes uninstall commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__hermes__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__help__subcmd__hermes__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help hermes verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__measure_commands] )) ||
_rev-stealth__subcmd__help__subcmd__measure_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help measure commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__relocate_commands] )) ||
_rev-stealth__subcmd__help__subcmd__relocate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help relocate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__spider_commands] )) ||
_rev-stealth__subcmd__help__subcmd__spider_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help spider commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__vpn_commands] )) ||
_rev-stealth__subcmd__help__subcmd__vpn_commands() {
    local commands; commands=(
'rotate:Trigger a VPN rotation. With \`lazy-on-fail\`, rotation is skipped unless the failure counter has crossed the threshold' \
'status:Show the current public IP and the VPN container state' \
    )
    _describe -t commands 'rev-stealth help vpn commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__vpn__subcmd__rotate_commands] )) ||
_rev-stealth__subcmd__help__subcmd__vpn__subcmd__rotate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help vpn rotate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__help__subcmd__vpn__subcmd__status_commands] )) ||
_rev-stealth__subcmd__help__subcmd__vpn__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth help vpn status commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes_commands] )) ||
_rev-stealth__subcmd__hermes_commands() {
    local commands; commands=(
'install:Install the Hermes plugin scaffold into \`<prefix>\`' \
'uninstall:Remove a previously installed Hermes plugin' \
'verify:Verify a Hermes plugin install on disk' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth hermes commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__help_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__help_commands() {
    local commands; commands=(
'install:Install the Hermes plugin scaffold into \`<prefix>\`' \
'uninstall:Remove a previously installed Hermes plugin' \
'verify:Verify a Hermes plugin install on disk' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth hermes help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__help__subcmd__install_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__help__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes help install commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__help__subcmd__uninstall_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__help__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes help uninstall commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__help__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__help__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes help verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__install_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes install commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__uninstall_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes uninstall commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__hermes__subcmd__verify_commands] )) ||
_rev-stealth__subcmd__hermes__subcmd__verify_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth hermes verify commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__measure_commands] )) ||
_rev-stealth__subcmd__measure_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth measure commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__relocate_commands] )) ||
_rev-stealth__subcmd__relocate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth relocate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__spider_commands] )) ||
_rev-stealth__subcmd__spider_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth spider commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn_commands] )) ||
_rev-stealth__subcmd__vpn_commands() {
    local commands; commands=(
'rotate:Trigger a VPN rotation. With \`lazy-on-fail\`, rotation is skipped unless the failure counter has crossed the threshold' \
'status:Show the current public IP and the VPN container state' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth vpn commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__help_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__help_commands() {
    local commands; commands=(
'rotate:Trigger a VPN rotation. With \`lazy-on-fail\`, rotation is skipped unless the failure counter has crossed the threshold' \
'status:Show the current public IP and the VPN container state' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'rev-stealth vpn help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__help__subcmd__help_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth vpn help help commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__help__subcmd__rotate_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__help__subcmd__rotate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth vpn help rotate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__help__subcmd__status_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth vpn help status commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__rotate_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__rotate_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth vpn rotate commands' commands "$@"
}
(( $+functions[_rev-stealth__subcmd__vpn__subcmd__status_commands] )) ||
_rev-stealth__subcmd__vpn__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'rev-stealth vpn status commands' commands "$@"
}

if [ "$funcstack[1]" = "_rev-stealth" ]; then
    _rev-stealth "$@"
else
    compdef _rev-stealth rev-stealth
fi
