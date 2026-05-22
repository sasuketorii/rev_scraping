# Step 3 — Browser profile & cookies

Some sites require an authenticated session. `rev-stealth` uses a
**device-flow-style** login: you start the flow on the CLI, complete the
in-browser auth on a real Chromium, and rev-stealth captures the cookies
into an encrypted profile on disk.

## Start a login

```sh
rev-stealth auth login start \
  --site example_com \
  --output-format json
```

The response includes a `session_id` and a `browser_pid`. A Chromium window
opens. Log in normally.

## Complete the login

```sh
rev-stealth auth login complete \
  --session-id <id-from-previous-step>
```

Cookies are now encrypted at rest under
`~/.local/share/rev-stealth/profiles/<site>/`. They are AES-256-GCM
sealed with a per-machine key (see [`auth-flow.md`](../../../auth-flow.md)
in the repo for the threat model).

## Verify

```sh
rev-stealth auth list --output-format json | jq '.sites[]'
rev-stealth auth status --site example_com
```

## Smoke test

```sh
rev-stealth auth status --site example_com --output-format json \
  | jq '.status' | grep -q '"authenticated"'
```
