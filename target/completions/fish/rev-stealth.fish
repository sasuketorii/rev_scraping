# Print an optspec for argparse to handle cmd's options that are independent of any subcommand.
function __fish_rev_stealth_global_optspecs
	string join \n format= v/verbose h/help V/version
end

function __fish_rev_stealth_needs_command
	# Figure out if the current invocation already has a command.
	set -l cmd (commandline -opc)
	set -e cmd[1]
	argparse -s (__fish_rev_stealth_global_optspecs) -- $cmd 2>/dev/null
	or return
	if set -q argv[1]
		# Also print the command, so this can be used to figure out what it is.
		echo $argv[1]
		return 1
	end
	return 0
end

function __fish_rev_stealth_using_subcommand
	set -l cmd (__fish_rev_stealth_needs_command)
	test -z "$cmd"
	and return 1
	contains -- $cmd[1] $argv
end

complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -s V -l version -d 'Print version'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "captcha" -d 'CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "browser" -d 'Stealth browser operations (launch a profile, run a stealth-test sweep)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "vpn" -d 'VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "doctor" -d 'Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "spider" -d 'AUP-gated browse + optional CF eval + optional adaptive relocate'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "relocate" -d 'Locate a previously fingerprinted element in a saved HTML or fresh URL'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "cf-evaluate" -d 'Defender-testbed evaluation of Cloudflare Turnstile resilience'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "auth" -d 'Authenticated session capture / lifecycle (Phase 9d). Subcommands: login / list / show / delete / status / refresh'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "measure" -d 'v1.1.0 (P15): local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via `--enable-external`'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "config" -d 'v1.2.0 (P6.1): inspect the layered config (`show` / `paths` / `validate` / `diff` / `get`)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "hermes" -d 'v1.2.0 (P7.3): manage the Hermes plugin scaffold (`install` / `uninstall` / `verify`)'
complete -c rev-stealth -n "__fish_rev_stealth_needs_command" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -f -a "solve" -d 'Solve a CAPTCHA challenge'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -f -a "verify" -d 'Verify a previously-issued token (round-trips through the challenge provider\'s verify endpoint)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and not __fish_seen_subcommand_from solve verify help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l type -d 'Challenge type: `recaptcha-v2`, `recaptcha-v3`, `hcaptcha`, `turnstile`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l site-url -d 'Target site URL hosting the challenge' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l site-key -d 'Sitekey (auto-detected if omitted on supported challenge types)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l action -d 'reCAPTCHA v3 action label' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -l dry-run -d 'Skip the live solver and exercise the sidecar plumbing only. Useful for CI smoke tests'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from solve" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -l type -d 'Challenge type, same vocabulary as `solve --type`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -l token -d 'Token returned by `solve`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -l secret -d 'Provider secret (loaded from env in production)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from verify" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from help" -f -a "solve" -d 'Solve a CAPTCHA challenge'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from help" -f -a "verify" -d 'Verify a previously-issued token (round-trips through the challenge provider\'s verify endpoint)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand captcha; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -f -a "launch" -d 'Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -f -a "stealth-test" -d 'Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and not __fish_seen_subcommand_from launch stealth-test help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l profile -d 'Profile slug. One of: `desktop`, `mobile-ios`, `mobile-android`, `ipad`, `galaxy-ultra`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l stealth -d 'Stealth level: `off`, `basic`, `full`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l url -d 'Navigate to this URL after launch. Default: `about:blank`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l chrome -d 'Override the chrome executable path. By default, chromiumoxide auto-detects the system chrome' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l dwell -d 'Hold the page for this many seconds after navigation (lets a detector finish its work). Default 0 = exit as soon as `document.readyState` settles' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -l headed -d 'Run with a visible chrome window instead of new-headless mode'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from launch" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l target -d 'Detection page to probe' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l stealth -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l dwell -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l chrome -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -l headed
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from stealth-test" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from help" -f -a "launch" -d 'Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from help" -f -a "stealth-test" -d 'Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand browser; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -f -a "rotate" -d 'Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -f -a "status" -d 'Show the current public IP and the VPN container state'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and not __fish_seen_subcommand_from rotate status help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -l provider -d 'VPN provider slug (currently only `surfshark`)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -l strategy -d 'Rotation strategy: `lazy-on-fail`, `every-n`, `interval`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -l region -d 'Optional region (`jp`, `us-west`, `de`, ...). Cycled through when omitted' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -l reason -d 'Reason hint; recorded in the audit log for forensics' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from rotate" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from status" -l provider -d 'Provider slug to scope the status query' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from status" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from status" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from help" -f -a "rotate" -d 'Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from help" -f -a "status" -d 'Show the current public IP and the VPN container state'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand vpn; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l container -d 'VPN container name to inspect' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l expected-country -d 'Expected VPN exit country (ISO-2, e.g. "JP"). Skipped when omitted' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l output-format -d 'Output format for doctor diagnostic results: `json` (machine-parseable, default) or `text` (human-readable)' -r -f -a "json\t''
text\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l skip-exit-ip -d 'Skip the live `ipinfo.io` exit-IP probe (offline / CI mode)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l deep -d 'v1.1.0 (P16): run extended stack health checks (obscura binary, VPN instance pool, sites recipe count, auth profile validity, AuthStore key source). The default check set stays minimal so the existing fail-closed contract (exit 7 on leak) is unchanged; `--deep` adds non-leak diagnostic WARN/FAIL items'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -l vps -d 'P10.3: run VPS deploy readiness checks (systemd unit prerequisites, dedicated user, /var/log + /var/lib dir permissions, credstore, chrome/xvfb-run on PATH, docker + gluetun image, DISPLAY env). FAIL items exit 3 (permanent); WARN-only stays exit 0. Independent from the leak-fail-closed contract used by the base checks'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand doctor" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l url -d 'Target URL' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l session-id -d 'Session id (auto-generated when omitted)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l mobile-preset -d 'Mobile fingerprint preset slug' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l stable-id -d 'stable_id to locate via `stealth-parse` after navigation' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l threshold -d 'Similarity threshold for relocate' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l obscura -d 'Path to the obscura binary. Overridable via env' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l parse-store -d 'Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l use-auth -d 'Replay stored auth cookies and browser headers from the named profile' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l auth-domain -d 'Auth AAD/domain context to load; defaults to the target host' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l dump-html -d 'Dump the fetched HTML to the given path (UTF-8). With obscura, the post-render `document.documentElement.outerHTML` is captured (so SPAs land hydrated); with the reqwest fallback / `--http-only`, the raw response body is written. Parent directories are created as needed and the file is created with mode `0600` on Unix' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l wait-ms -d 'After obscura navigate completes, wait N milliseconds before dumping the HTML. Useful for SPA hydration. No-op on the reqwest fallback path' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l wait-selector -d 'After obscura navigate completes, wait until the given CSS selector appears in the DOM (max 30 seconds). Takes precedence over `--wait-ms`. No-op on the reqwest fallback path' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l vpn-instance -d 'Force this invocation to use the named VPN instance, overriding the HRW session-sticky pick. Useful for tests and reproducible runs. Must match a `name` in the configured `vpn_instances` list' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l proxy-tier -d 'Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l leak-poll-secs -d 'Polling interval (seconds) for the background leak monitor. Only honoured when `require_vpn=true`. Range [5, 300]; out-of-range values are clamped. Default 30s' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l cache-ttl -d 'Treat recipes whose `last_verified` is older than DAYS as expired. Default: 30 days. Expired recipes are refreshed and overwritten' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l recipe-dir -d 'Override the recipe directory (defaults to `~/.rev_scraping/sites/`)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l recipe-endpoint -d 'When a recipe is hit and exposes API endpoints, call the endpoint matching this `purpose` directly via reqwest, skipping browser entirely' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l recipe-param -d 'Placeholder substitutions for the recipe endpoint URL. Repeatable; e.g. `--recipe-param username=alice --recipe-param id=42`' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l cf-evaluate -d 'Evaluate Cloudflare Turnstile resilience (defender-testbed; no solver)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l vpn -d 'Route through `vpn-rotate` before launch'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l strict -d 'Treat Ambiguous relocate as a hard failure (exit code 10)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l i-have-authorization -d 'AUP bypass (logs a warn). Equivalent to env-ack for the day'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l http-only -d 'Skip obscura entirely and fetch via reqwest. Implies no JS execution, no CF eval, no DOM injection'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l auto-fallback -d 'When obscura launch / CDP fails, automatically retry with reqwest. Default true; set `--no-auto-fallback` to disable for deterministic agent workflows that need a hard exit-3 on browser failure'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l no-auto-fallback -d 'Explicit disable for `--auto-fallback` (overrides the default)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l require-vpn -d 'Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1` only in the sense that env can\'t be loosened further'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l allow-no-vpn -d 'Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1` (which is the only way to enforce the policy from outside the process)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l no-fallback -d 'Disable the fallback chain; one attempt at the selected tier only'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l no-cache -d 'Skip recipe lookup AND skeleton save for this invocation'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l cache-refresh -d 'Ignore any existing recipe, run full discovery, and overwrite the recipe on success'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l cache-only -d 'Hard-require a recipe hit. On miss, exit code 9 and do nothing'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -l recipe-no-learn -d 'Disable Phase 7c auto-learning (Network capture + JS bundle scan + recipe upsert). Privacy-sensitive runs may opt out; the skeleton save still applies unless `--no-cache` is set. Default: off (i.e. learning is ON)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand spider" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l session-id -d 'Session id (informational; not required to open the store)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l stable-id -d 'stable_id of the element to locate' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l html-file -d 'Local HTML file to scan' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l url -d 'Remote URL to fetch (HTTP-only, no browser launch)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l threshold -d 'Similarity threshold' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l parse-store -d 'Optional ParseStore path (defaults to `~/.rev_scraping/parse.sqlite`)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l vpn-instance -d 'Phase 6d: force a specific VPN instance from the configured pool' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l proxy-tier -d 'Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l use-auth -d 'Replay stored auth cookies and browser headers from the named profile' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l auth-domain -d 'Auth AAD/domain context to load; defaults to the target host' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l strict -d 'Treat Ambiguous as exit 10'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l i-have-authorization -d 'AUP bypass (logs a warn). Required when `--url` targets a non-allowlisted host'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l require-vpn -d 'Phase 6c: fail-closed VPN-required guard. Applies to `--url` only; `--html-file` is a local read'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l allow-no-vpn
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -l no-fallback -d 'Disable the fallback chain; one attempt at the selected tier only'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand relocate" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l url -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l session-id -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l obscura -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l vpn-instance -d 'Phase 6d: force a specific VPN instance from the configured pool' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l proxy-tier -d 'Force a named proxy tier (e.g. "direct", "surfshark", "warp", "iproyal") or "auto" to use the configured fallback chain. Mutually exclusive with `--vpn-instance` unless the tier is exactly "surfshark"' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l leak-poll-secs -d 'Phase 6e: background leak monitor poll interval (seconds)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l use-auth -d 'Replay stored auth cookies and browser headers from the named profile' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l auth-domain -d 'Auth AAD/domain context to load; defaults to the target host' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l i-have-authorization
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l require-vpn -d 'Phase 6c: fail-closed VPN-required guard. See spider --require-vpn'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l allow-no-vpn
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -l no-fallback -d 'Disable the fallback chain; one attempt at the selected tier only'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand cf-evaluate" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "login" -d 'Spawn `rev-auth` for interactive login; AUP-gated'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "list" -d 'List saved profiles (metadata only, cookie values never disclosed)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "show" -d 'Show a single profile\'s metadata (redacted)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "delete" -d 'Delete a profile with shred-on-delete'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "status" -d 'Report freshness/expiry status for a profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "refresh" -d 'Re-run interactive login, overwriting an existing profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and not __fish_seen_subcommand_from login list show delete status refresh help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l url -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l domain -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l completion-pattern -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l obscura-bin -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l rev-auth-bin -d 'Override the `rev-auth` helper binary path (defaults to `which rev-auth`)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l aad-context -d 'Additional AAD context (e.g. proxy route) bound to the cookie blob' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l require-vpn -d 'Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -l allow-no-vpn -d 'Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from login" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from list" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from show" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from show" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from show" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from show" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from delete" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from delete" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from delete" -l force -d 'Skip the interactive confirmation prompt'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from delete" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from delete" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from status" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from status" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from status" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l profile -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l url -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l domain -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l completion-pattern -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l obscura-bin -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l rev-auth-bin -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l aad-context -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l require-vpn -d 'Force the VPN-required guard ON for this invocation. Wins over `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -l allow-no-vpn -d 'Allow this invocation to proceed without a VPN. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from refresh" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "login" -d 'Spawn `rev-auth` for interactive login; AUP-gated'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "list" -d 'List saved profiles (metadata only, cookie values never disclosed)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "show" -d 'Show a single profile\'s metadata (redacted)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "delete" -d 'Delete a profile with shred-on-delete'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "status" -d 'Report freshness/expiry status for a profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "refresh" -d 'Re-run interactive login, overwriting an existing profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand auth; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l url -d 'URL to measure against. The page is not actually fetched unless `--enable-external` is set; we only validate the URL shape here' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l user-agent -d 'Optional override for the User-Agent we attribute the measurement to. When omitted we use a neutral rev-stealth placeholder' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l enable-external -d 'Opt-in to external fingerprint SaaS calls (CreepJS, bot.sannysoft.com, etc.). Default: disabled'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -l enable-egress-probe -d 'P10.5: Opt-in to a VPS egress probe (HEAD request against a minimal endpoint) to measure exit IP / TLS / DNS leak after deploy. Even with this flag set, the probe is only active when the binary was built with the `vps-egress-probe` Cargo feature; otherwise a deterministic `disabled` stub is returned. Default: disabled'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand measure" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -l output-format -d 'Output format. Overrides the global `--format` only for this subtree' -r -f -a "text\t''
json\t''
yaml\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "show" -d 'Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "paths" -d 'List each config file path (absolute), its existence, and permission bits (unix mode)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "validate" -d 'Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "diff" -d 'Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "get" -d 'Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "set" -d 'P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "edit" -d 'P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "migrate" -d 'P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "init" -d 'P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "history" -d 'P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "rollback" -d 'P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target\'s current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "gc" -d 'P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "profile" -d 'P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and not __fish_seen_subcommand_from show paths validate diff get set edit migrate init history rollback gc profile help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from show" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from show" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from show" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from paths" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from paths" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from paths" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from validate" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from validate" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from validate" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from diff" -l against -d 'Override the baseline (defaults to `templates/policy.toml`)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from diff" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from diff" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from diff" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from get" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from get" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from get" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from set" -l target -d 'Which file to mutate. Defaults to `policy`' -r -f -a "policy\t''
authorized\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from set" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from set" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from set" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from edit" -l target -d 'Which file to open. Defaults to `policy`' -r -f -a "policy\t''
authorized\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from edit" -l editor -d 'Override `$EDITOR`. Mostly for tests (e.g. `--editor "cp my.toml"`)' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from edit" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from edit" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from edit" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from migrate" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from migrate" -l dry-run -d 'Dry-run: print the migration plan without writing. (v1→v1 is a no-op either way; the flag is here so the future v2 migration path has a stable name.)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from migrate" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from migrate" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -l target -d 'Limit init to a single file. Default `all`' -r -f -a "all\t''
policy\t''
authorized\t''
sites\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -l force -d 'Overwrite existing files (routes through `.bak.<epoch>` backup via the P5.2 ConfigWriter — never destructive)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -l non-interactive -d 'Skip interactive confirmation. Required for CI / scripted use. The current implementation never prompts (init is non-destructive without --force), but the flag is reserved + tested so callers can adopt it now without a future breaking change'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from init" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from history" -l target -d 'Which file\'s backups to list. Defaults to `policy`' -r -f -a "policy\t''
authorized\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from history" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from history" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from history" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from rollback" -l target -d 'Which file to roll back. Defaults to `policy`' -r -f -a "policy\t''
authorized\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from rollback" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from rollback" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from rollback" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from gc" -l keep -d 'Number of newest backups to keep. Defaults to 5' -r
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from gc" -l target -d 'Which file\'s backups to GC. Defaults to `policy`' -r -f -a "policy\t''
authorized\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from gc" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from gc" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from gc" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -f -a "list" -d 'List every profile directory under `<base>/profiles/`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -f -a "create" -d 'Create a new profile directory and seed `policy.toml`, `authorized.toml`, and `sites/` via ConfigWriter (same skeleton as `config init`). Refuses if the profile already exists'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -f -a "switch" -d 'Print the shell-export line needed to activate the profile. We never mutate the operator\'s environment from inside the process — the operator must eval/source the printed line'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -f -a "delete" -d 'Best-effort overwrite-then-delete (`shred-like`) for the profile directory. Refuses if the profile is currently active per `$REV_SCRAPING_HOME` resolution'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from profile" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "show" -d 'Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "paths" -d 'List each config file path (absolute), its existence, and permission bits (unix mode)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "validate" -d 'Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "diff" -d 'Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "get" -d 'Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "set" -d 'P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "edit" -d 'P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "migrate" -d 'P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "init" -d 'P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "history" -d 'P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "rollback" -d 'P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target\'s current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "gc" -d 'P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "profile" -d 'P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -l output-format -d 'Output format for this subcommand: `human` (default) or `json`. Shadows the global `--format` for this invocation. Same value enum as the global flag; the JSON output is documented under `docs/json-schemas/cli/<subcommand>.output.json`' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -f -a "install" -d 'Install the Hermes plugin scaffold into `<prefix>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -f -a "uninstall" -d 'Remove a previously installed Hermes plugin'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -f -a "verify" -d 'Verify a Hermes plugin install on disk'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and not __fish_seen_subcommand_from install uninstall verify help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -l prefix -d 'Destination directory. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -l source -d 'Override the scaffold source directory (defaults to the `dist/hermes/rev-scraping-mcp` shipped with the repo)' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -l force -d 'Overwrite an existing non-empty destination'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from install" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from uninstall" -l prefix -d 'Plugin directory to remove. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from uninstall" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from uninstall" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from uninstall" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from verify" -l prefix -d 'Plugin directory to verify. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`' -r -F
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from verify" -l format -d 'Output format for agent / human consumers. Default `human`; pass `json` for machine-parseable output' -r -f -a "human\t''
json\t''"
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from verify" -l skip-python-check -d 'Skip the `python3 -c "import ast; ast.parse(...)"` syntax probe of `__init__.py`. The probe runs by default; pass this flag in environments without `python3` on `$PATH` (minimal containers, CI workers without the Python toolchain)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from verify" -s v -l verbose -d 'Verbose logging (`-v`, `-vv`, `-vvv`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from verify" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from help" -f -a "install" -d 'Install the Hermes plugin scaffold into `<prefix>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from help" -f -a "uninstall" -d 'Remove a previously installed Hermes plugin'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from help" -f -a "verify" -d 'Verify a Hermes plugin install on disk'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand hermes; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "captcha" -d 'CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "browser" -d 'Stealth browser operations (launch a profile, run a stealth-test sweep)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "vpn" -d 'VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "doctor" -d 'Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC). Exits with code 7 when any check fails (fail-closed)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "spider" -d 'AUP-gated browse + optional CF eval + optional adaptive relocate'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "relocate" -d 'Locate a previously fingerprinted element in a saved HTML or fresh URL'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "cf-evaluate" -d 'Defender-testbed evaluation of Cloudflare Turnstile resilience'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "auth" -d 'Authenticated session capture / lifecycle (Phase 9d). Subcommands: login / list / show / delete / status / refresh'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "measure" -d 'v1.1.0 (P15): local fingerprint diagnostics for monitoring. External SaaS calls are opt-in via `--enable-external`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "config" -d 'v1.2.0 (P6.1): inspect the layered config (`show` / `paths` / `validate` / `diff` / `get`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "hermes" -d 'v1.2.0 (P7.3): manage the Hermes plugin scaffold (`install` / `uninstall` / `verify`)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and not __fish_seen_subcommand_from captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from captcha" -f -a "solve" -d 'Solve a CAPTCHA challenge'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from captcha" -f -a "verify" -d 'Verify a previously-issued token (round-trips through the challenge provider\'s verify endpoint)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from browser" -f -a "launch" -d 'Launch a stealth browser, navigate to a URL, and emit JSON about the resulting page (UA / viewport / title / final URL). Useful as a smoke test that the launcher works on this host'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from browser" -f -a "stealth-test" -d 'Run a stealth self-test: launch a stealth browser, navigate to the target detection page (defaults to bot.sannysoft.com), wait briefly, then dump UA / viewport / title'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from vpn" -f -a "rotate" -d 'Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped unless the failure counter has crossed the threshold'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from vpn" -f -a "status" -d 'Show the current public IP and the VPN container state'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "login" -d 'Spawn `rev-auth` for interactive login; AUP-gated'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "list" -d 'List saved profiles (metadata only, cookie values never disclosed)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "show" -d 'Show a single profile\'s metadata (redacted)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "delete" -d 'Delete a profile with shred-on-delete'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "status" -d 'Report freshness/expiry status for a profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from auth" -f -a "refresh" -d 'Re-run interactive login, overwriting an existing profile'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "show" -d 'Print the merged effective config from all 4 source layers (policy.toml / authorized.toml / sites/* / env). Secret-looking env values are replaced with `<redacted>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "paths" -d 'List each config file path (absolute), its existence, and permission bits (unix mode)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "validate" -d 'Run the P5.1 validate engine over the live config files. Exit 0 on LGTM; exit 1 with structured issue list on violations'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "diff" -d 'Print a unified diff between the live `<path>` and the in-repo `templates/policy.toml` baseline. Headers use `---` / `+++`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "get" -d 'Resolve a dotted key path (e.g. `policy.require_vpn`) against the merged config and print the value. Secret-looking values redacted'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "set" -d 'P6.3: Set a dotted-path key on `policy.toml` (or another target file) to a value. Type is inferred from the literal text (`true`/`false` → bool, all-digits → int, otherwise string). The value is written through the atomic ConfigWriter only after the resulting document passes strict validation. Secret values are NOT echoed back'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "edit" -d 'P6.3: Open the target file in `$EDITOR` (falling back to `vi`). On editor exit, the candidate is validated. If validation succeeds the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`). If validation fails, the original file is left untouched and the temp file is preserved so the operator can recover their edits'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "migrate" -d 'P6.3: Migrate `policy.toml` (and authorized.toml) from its current `schema_version` to the latest known version. v1 → v1 is a no-op (returns exit 0 + an audit-trail line). The harness is in place for future v2+ migrations to plug into'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "init" -d 'P6.2: Initialize the per-user config tree under `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates `policy.toml` (0600), `authorized.toml` (0600), and `sites/` (0700) via the atomic ConfigWriter. Existing files are preserved unless `--force` is passed (which routes the overwrite through `.bak.<epoch>` backup)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "history" -d 'P6.4: List the `.bak.<epoch>` backups for the target config file in newest→oldest order (sorted by mtime, tie-broken by filename desc to match the epoch-ms suffix)'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "rollback" -d 'P6.4: Restore a previously captured `.bak.<epoch>` backup onto the target\'s current path. The current file (if any) is preserved as a fresh `.bak.<epoch>` by routing the restore write through `ConfigWriter::write_with_backup`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "gc" -d 'P6.4: Garbage-collect `.bak.<epoch>` backups for the target config file, keeping the newest `--keep` (default 5). All older backups are deleted; the current file is untouched'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "profile" -d 'P6.5: Manage per-profile config trees under `<base>/profiles/<name>/`. Profiles share the same internal layout as the top-level config (`policy.toml`, `authorized.toml`, `sites/`) and are activated by exporting `REV_SCRAPING_HOME=<base>/profiles/<name>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from hermes" -f -a "install" -d 'Install the Hermes plugin scaffold into `<prefix>`'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from hermes" -f -a "uninstall" -d 'Remove a previously installed Hermes plugin'
complete -c rev-stealth -n "__fish_rev_stealth_using_subcommand help; and __fish_seen_subcommand_from hermes" -f -a "verify" -d 'Verify a Hermes plugin install on disk'
