# v1.1 Follow-up — HermesAgent × rev_scraping Integration Design

**Status:** read-only investigation report (design only, no code, no secrets)
**Author:** Claude opus 4.7-high (HermesAgent integration investigator)
**Date:** 2026-05-20
**Scope:** Determine how rev_scraping's `stealth-mcp` (15-tool MCP stdio server)
can be consumed by HermesAgent. Map plugin spec, propose adapter, define
chained-call patterns, and clarify privilege/secret boundaries.

---

## 0. Executive summary

| Question | Answer |
|---|---|
| Does HermesAgent natively load MCP (JSON-RPC stdio) servers? | **No** (not in any of the three HermesAgent trees inspected — see §1.5). |
| Can rev_scraping be plugged in **as-is**? | **No.** A thin Python *adapter plugin* is required. |
| Is the required adapter trivial? | **Yes** — ~150–250 LOC: subprocess + JSON-RPC framing + `ctx.register_tool` fan-out. Comparable to `captcha_relay/rev_contact_invoke.py` (147 LOC) and the existing `cybertomo-case-sync` register block. |
| Where does the adapter live? | `~/.hermes/plugins/rev-scraping-mcp/` (the documented update-safe surface — see `LOCAL_EXTENSIONS.md`). |
| Risk class | Low. Subprocess boundary mirrors the existing `rev_contact` integration; no Hermes core patching required. |

**Recommendation:** ship a `rev-scraping-mcp` plugin scaffold in
`docs/integration/hermes/` of this repo (template only) and a minimum
verification script (`tests/integration/hermes_smoke.py`). Do not commit
plugin source into HermesAgent until the rev_scraping v1.1 GA release.

---

## 1. HermesAgent plugin spec — discovered facts

### 1.1 Project locations found

```
~/dev/sanuvps_hermesagent_bak/extensions/hermes/   # plugin reference impls
~/dev/contact_dev/services/hermes-agent/           # the v1.0.0 GA hermes-agent service (Telegram front-end for rev_contact)
~/dev/hermes_update/                                # update execplan docs only (no source)
~/dev/agent_base/                                   # unrelated agent harness (Rust + skills)
~/dev/rev_social/agent_base/                       # unrelated
```

The canonical plugin reference lives in
`~/dev/sanuvps_hermesagent_bak/extensions/hermes/plugins/`. Two
production plugins are committed there:

- `telegram-scoped-allowlist/` — monkey-patches `gateway.run.GatewayRunner`.
- `cybertomo-case-sync/` — registers **10 tools** via `ctx.register_tool(...)`.

### 1.2 Plugin layout (canonical)

```
~/.hermes/plugins/<plugin-name>/
├── plugin.yaml           # manifest
├── __init__.py           # entrypoint, must expose register(ctx) -> None
└── [arbitrary modules]
```

`plugin.yaml` minimal fields observed:

```yaml
name: <plugin-name>
version: 0.1.0
description: <one line>
provides_hooks: []            # optional
provides_tools:               # optional; declarative list (advisory only — real reg is via ctx.register_tool)
  - tool_name_1
  - tool_name_2
```

(There is no JSON-schema enforcement on this YAML in any Hermes file we
located; it appears to be primarily documentary. The runtime contract is
the `register(ctx)` Python entrypoint.)

### 1.3 The `ctx` plugin registration API (de-facto)

From `cybertomo-case-sync/__init__.py:3458`:

```python
def register(ctx) -> None:
    ctx.register_tool(
        "cybertomo_case_health_check",     # tool name (snake_case)
        TOOLSET,                            # toolset string, e.g. "cybertomo_case"
        HEALTH_SCHEMA,                      # dict — JSON-schema-ish, see §1.4
        _handle_health_check,               # callable: (args: dict, **kw) -> str (JSON)
        check_fn=_check_available,          # callable: () -> bool (gate)
    )
```

Notable invariants observed across the 10 calls:

- Handlers return **JSON strings** (via `_json(...)` helper) — not Python dicts.
- Handlers are **sync** callables `(args, **kw) -> str`. Hermes runs them itself; async is not required.
- `check_fn` runs at registration / dispatch time as a feature-flag gate (`return _bool_secret(...)` etc.).
- The `ctx` object's surface beyond `register_tool` is not enumerated in this backup. `register_hook` is mentioned in `LOCAL_EXTENSIONS.md` for the `pre_tool_call` hook used by `sales-spreadsheet-telegram`, but the binding signature was not located in this backup.

### 1.4 Tool schema dict shape

```python
HEALTH_SCHEMA = {
    "name": "cybertomo_case_health_check",
    "description": "...",
    "parameters": {"type": "object", "properties": {}},   # JSON-Schema draft-07 subset
}
```

This is **Anthropic-tool-use compatible** (matches the Messages API tool
spec). rev_scraping already emits a fully-conformant variant in
`tools/list` results (see `crates/stealth-mcp/src/tools.rs:33`
`tool_definitions()`), so per-tool schemas can be machine-translated
without manual rewrite.

### 1.5 MCP / JSON-RPC / stdio search — negative result

```
$ grep -lr -i 'mcp\|.mcp.json\|jsonrpc\|stdio' \
    ~/dev/sanuvps_hermesagent_bak/extensions/hermes
# (no matches)
```

→ Hermes core in this backup has **no MCP transport** and **no
`.mcp.json` loader**. Integration is *not* "drop into `.mcp.json` and go."

The pattern Hermes already uses to consume an external Rust/CLI service
is `asyncio.create_subprocess_exec` with JSONL on stdout — see
`contact_dev/services/hermes-agent/src/hermes_agent/captcha_relay/rev_contact_invoke.py`
(`run_rev_contact_submit`). This is the pattern we mirror.

### 1.6 Config + secrets surface

Per `LOCAL_EXTENSIONS.md`:

```
~/.hermes/config.yaml      # plugins.enabled: [<plugin-name>, ...]
~/.hermes/.env             # plain env vars
~/.hermes/secrets/<plugin>.env   # mode 0600, plugin-scoped secrets
~/.hermes/<plugin>/        # plugin data dir (SQLite etc.)
```

cybertomo-case-sync's `_secret_value()` (line 82-86) prefers `os.getenv`,
falls back to `~/.hermes/secrets/*.env`. We must follow this convention.

---

## 2. rev_scraping MCP surface (recap)

From `crates/stealth-mcp/src/`:

- Binary: `stealth-mcp` (`Cargo.toml [[bin]]`).
- Transport: stdio JSON-RPC 2.0. Methods: `initialize`,
  `notifications/initialized`, `tools/list`, `tools/call`
  (`src/server.rs:87-90`).
- 15 tools registered in `src/tools.rs:33`:

```
spider, relocate, cf_evaluate, doctor,
recipe_list, recipe_show, recipe_remove, recipe_propose_endpoint,
recipe_export, recipe_import,
auth_login_start, auth_login_complete, auth_list, auth_status,
vpn_rotate
```

Each `ToolDefinition` already carries `name: &'static str` and a JSON
schema, directly translatable to Hermes' schema dict shape.

`build_cli_argv(tool, args)` (line 240) shows that `stealth-mcp` is also
a usable CLI; either transport is viable for the adapter, but **stdio
JSON-RPC is preferred** (already long-lived; no per-call process spawn).

---

## 3. Integration design — `rev-scraping-mcp` Hermes plugin

### 3.1 Directory layout (target on the VPS)

```
~/.hermes/plugins/rev-scraping-mcp/
├── plugin.yaml
├── __init__.py                # register(ctx) — fan-out registrar
├── mcp_client.py              # JSON-RPC 2.0 stdio client (long-lived stealth-mcp)
├── tool_proxy.py              # builds per-tool handler closures from tools/list
├── lifecycle.py               # restart / health / EOF recovery
└── README.md
```

### 3.2 `plugin.yaml`

```yaml
name: rev-scraping-mcp
version: 0.1.0
description: HermesAgent bridge to rev_scraping stealth-mcp (15 MCP tools).
provides_tools:
  - rev_spider
  - rev_relocate
  - rev_cf_evaluate
  - rev_doctor
  - rev_recipe_list
  - rev_recipe_show
  - rev_recipe_remove
  - rev_recipe_propose_endpoint
  - rev_recipe_export
  - rev_recipe_import
  - rev_auth_login_start
  - rev_auth_login_complete
  - rev_auth_list
  - rev_auth_status
  - rev_vpn_rotate
provides_hooks: []
```

The `rev_*` prefix prevents collision with hypothetical future Hermes
core tools and makes the provenance explicit.

### 3.3 Adapter behaviour — pseudocode (NOT for commit)

```python
# __init__.py
from .mcp_client import StealthMcpClient

def register(ctx) -> None:
    client = StealthMcpClient.shared()       # lazy singleton, fork-safe
    tools = client.list_tools()              # tools/list once at register time
    for t in tools:
        hermes_name = f"rev_{t['name']}"
        schema = {
            "name": hermes_name,
            "description": t["description"],
            "parameters": t["inputSchema"],
        }
        handler = _make_handler(client, t["name"])
        ctx.register_tool(
            hermes_name, "rev_scraping", schema, handler,
            check_fn=client.is_alive,
        )

def _make_handler(client, rpc_name):
    def _h(args, **_kw):
        try:
            result = client.call(rpc_name, args, timeout=120)
            return json.dumps({"success": True, **result}, ensure_ascii=False)
        except McpError as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)
    return _h
```

`StealthMcpClient`:

- Spawns `stealth-mcp` once via `subprocess.Popen` (text mode, line-buffered).
- Writes Content-Length-framed JSON-RPC requests (the MCP standard) or
  newline-delimited JSON, whichever `crates/stealth-mcp/src/server.rs`
  emits — verify against `run_stdio` (line 50).
- Reads responses with `id` correlation; supports concurrent in-flight calls.
- Auto-restarts on EOF / non-zero exit; back-off 1 s → 5 s → 30 s.
- Drains stderr in a background thread (mirrors `_drain_stderr` from
  `rev_contact_invoke.py:44`) to prevent pipe deadlock.

### 3.4 Why singleton-per-process

- `stealth-mcp` likely holds heavy state (CDP sessions, recipe cache,
  auth profiles, vpn-rotate cooldowns). One process per Hermes worker
  preserves cache locality.
- Hermes' main process is single-asyncio-loop; a single subprocess is
  enough. If a future multi-worker model arrives, the singleton becomes
  per-worker — still safe.

### 3.5 Configuration

`~/.hermes/secrets/rev-scraping-mcp.env`:

```
REV_SCRAPING_MCP_BIN=/usr/local/bin/stealth-mcp
REV_SCRAPING_HOME=/var/lib/rev_scraping
REV_SCRAPING_LOG_LEVEL=info
REV_SCRAPING_VPN_PROFILE=lazy-on-fail
REV_SCRAPING_DEFAULT_TIMEOUT_SEC=120
# secrets passed *through* to the child process only if explicitly listed:
REV_SCRAPING_AUTH_PROFILE_DIR=/var/lib/rev_scraping/auth
```

Enable in `~/.hermes/config.yaml`:

```yaml
plugins:
  enabled:
    - rev-scraping-mcp
```

---

## 4. Chained-call patterns

### 4.1 Pattern A — single spider → LLM summarisation

Caller: a Hermes skill or the Anthropic-driven reasoning loop in
`hermes_agent.reasoning.llm_client`.

```
LLM → tool_call(rev_spider, {url, depth:1}) → adapter →
  stealth-mcp (JSON-RPC tools/call) → adapter → JSON string →
  LLM context → next turn → tool_call(rev_recipe_propose_endpoint, ...)
```

Latency budget: spider tail-latency dominates; the adapter overhead is a
single JSON-RPC round-trip (<2 ms on localhost stdio).

### 4.2 Pattern B — recipe build pipeline (chained tool sequence)

```
rev_recipe_list  → pick stale recipe
rev_spider       → probe live endpoints
rev_recipe_propose_endpoint → diff
rev_recipe_export → write JSON
(then) hermes-agent.db.client.upsert_recipe_metadata(...)
```

Each step's JSON output is re-fed to the LLM (or pure Python orchestrator)
— no rev_scraping side-state needs to be exposed through the adapter
beyond what each tool already returns.

### 4.3 Pattern C — auth-gated spider with VPN rotation

```
rev_auth_status → if expired: rev_auth_login_start → (out-of-band user) → rev_auth_login_complete
rev_vpn_rotate  → confirm fresh egress
rev_spider      → real run
```

Recovery rule: if `rev_spider` returns `{"success": false, "error":
"cf_challenge"}`, the orchestrator retries with `rev_cf_evaluate` and
`rev_vpn_rotate`. This logic lives in the **caller** (LLM or Python
orchestrator), not in the adapter — keep the adapter dumb.

### 4.4 Shared cache & recipe sync

- Recipe cache (`sites_recipe`) lives in rev_scraping's own data dir
  (`REV_SCRAPING_HOME`). Hermes never reads it directly; it reads
  *projections* via `rev_recipe_list` / `rev_recipe_show`.
- Auth profile (`auth_*` tools) likewise. The adapter passes
  `REV_SCRAPING_AUTH_PROFILE_DIR` to the child only.
- **Do not** mount `~/.hermes/cybertomo-case-sync/case_sync.db` into
  rev_scraping. They are different trust zones.

### 4.5 Context propagation (`session_id`)

Hermes' tool dispatch does not (today) thread a session id into the
`args` dict automatically. Two safe options:

1. **Stateless** — every call is independent; the LLM repeats
   relevant prior outputs in subsequent calls. Default.
2. **Caller-supplied `session_id`** — the orchestrator generates a
   UUID per chain and passes it explicitly in `args["session_id"]`.
   The adapter forwards verbatim. `stealth-mcp` already accepts this
   pattern for cookie-jar reuse (verify against `tools.rs` arg
   schemas before relying on it).

We recommend option 1 for v0.1; option 2 only if a real chain requires
cross-call cookie/jar continuity beyond what `recipe_*` already encodes.

---

## 5. Privilege & secret boundaries

| Concern | Behaviour |
|---|---|
| Process owner | `hermes-agent.service` runs as a dedicated systemd user (`User=hermes` per the ADR-024 hardened unit). The child `stealth-mcp` inherits that uid. |
| Filesystem reach | `stealth-mcp` reads/writes only under `REV_SCRAPING_HOME` (env-controlled). It must **not** be `~/.hermes/`. Use e.g. `/var/lib/rev_scraping/`. |
| Secret loading | The adapter loads `~/.hermes/secrets/rev-scraping-mcp.env` (mode 0600) and passes a **whitelisted subset** to the child via `env=` — never the entire Hermes env. |
| Anthropic / Supabase tokens | **Never forwarded** to `stealth-mcp`. The child has no business calling LLMs or the Hermes DB. |
| rev_scraping's own creds (proxy/vpn/site logins) | Stored under `REV_SCRAPING_HOME` only; Hermes does not see them. The adapter does not log child stdout/stderr beyond redacted summaries. |
| Telegram → tool exposure | Tool invocations remain mediated by Hermes' existing allowlist (`telegram-scoped-allowlist`). A Telegram-scoped user cannot invoke a `rev_*` tool unless the same authorization path admits them. |
| Logging redaction | The adapter MUST scrub URLs containing `?token=…` and Authorization headers from stderr before forwarding to Hermes' `structlog` (mirror `rev_contact_invoke.py`'s warning-only stderr log). |
| Capability cap | `stealth-mcp` itself should be invoked with `--read-only` where applicable (e.g. for LLM-initiated spidering, disable destructive recipe edits unless the caller has the `rev_writer` toolset enabled). This is a `check_fn` gate, not a runtime arg — toggle via `REV_SCRAPING_MCP_WRITE_ENABLE=0/1`. |

### 5.1 Failure-mode budget

| Mode | Adapter response |
|---|---|
| Child crash | Restart with back-off; up to 3 attempts in 60 s, then fail all calls with `child_unavailable` until next manual `rev_doctor`. |
| Child hang | Per-call timeout (env-configurable, default 120 s); cancel the JSON-RPC `id`, force-kill child if it doesn't respond to `tools/call` cancellation. |
| Stderr flood | Rate-limit (1 line / 100 ms) into Hermes log. |
| Pipe deadlock | Drain stderr in a daemon thread. |
| OOM in child | Killed by OS; restart loop catches it; circuit-break after 3× in 5 min. |

---

## 6. Verification — minimum test scripts

### 6.1 Smoke (no Hermes, no LLM)

`tests/integration/hermes_smoke.py` (committed in this repo; no Hermes
dep):

```python
# Talks the same JSON-RPC the adapter will. Pure stdlib.
import json, subprocess, sys, uuid, threading, time

BIN = "./target/release/stealth-mcp"
proc = subprocess.Popen(
    [BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, bufsize=1,
)

def _send(method, params):
    msg = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params}
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()
    return json.loads(proc.stdout.readline())

print(_send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}}))
print(_send("tools/list", {}))
print(_send("tools/call", {"name": "doctor", "arguments": {}}))
proc.stdin.close(); proc.wait(timeout=5)
```

**Pass criteria:**
1. `initialize` returns capabilities + serverInfo.
2. `tools/list` returns exactly 15 tools with non-empty `inputSchema`.
3. `tools/call name=doctor` returns `{"success": true, ...}` within 5 s.

### 6.2 Hermes-side dry run (on dogfood VPS only)

```
$ uv run python -m hermes_agent --check-config
$ uv run pytest tests/test_rev_scraping_plugin.py -k smoke
```

Tests to add inside the adapter package:

- `test_register_registers_15_tools` — stub `ctx`, assert call count.
- `test_handler_serialises_args` — invariant: `args` dict is forwarded
  byte-for-byte to JSON-RPC `arguments`.
- `test_child_restart_after_eof` — kill child, next call must succeed.
- `test_check_fn_blocks_when_bin_missing` — `REV_SCRAPING_MCP_BIN`
  pointing to /nonexistent ⇒ `check_fn() is False`.

### 6.3 End-to-end (real LLM, optional)

Drive the Anthropic loop with the Messages API + the adapter; ask
"crawl https://example.com depth 1, summarise". Expect two tool calls
(`rev_spider`, then a final assistant message). Latency budget: ≤ 6 s
on warm cache for the canonical example.com fixture.

---

## 7. Open questions / unknowns

1. **`ctx` full surface.** This backup shows only `register_tool` and
   the *existence* of `register_hook` / `pre_tool_call`. The
   newer `~/dev/hermes_update/` tree has docs but no source, and the
   live `~/.hermes/hermes-agent` repo is not in `~/dev`. Before
   committing the adapter on the VPS, dump `dir(ctx)` from a debug
   plugin to confirm: tool unregistration, hook surfaces, structured
   logger handle, secret loader helper.
2. **JSON-RPC framing.** Verify whether `stealth-mcp` uses
   newline-delimited JSON or Content-Length framing on stdio
   (`crates/stealth-mcp/src/server.rs:50` `run_stdio`). The smoke
   script assumes NDJSON; if MCP-standard Content-Length is used the
   adapter's reader needs the LSP-style header parser.
3. **`tools/call` cancellation.** MCP draft supports
   `notifications/cancelled` for `id`. Confirm `stealth-mcp` honours
   it before relying on timeouts.
4. **Concurrent tool calls.** Is `stealth-mcp` re-entrant on stdio
   (multiple in-flight `id`s) or is it strictly half-duplex? Server
   tests in `crates/stealth-mcp/src/server.rs` are sequential — assume
   serialised for v0.1 (queue inside the adapter), measure, then relax.
5. **Hermes update safety.** `LOCAL_EXTENSIONS.md` guarantees
   `~/.hermes/plugins/` survives `hermes update`. We rely on that. If
   the user wants the adapter pinned to a Hermes version, ship a
   `compat` block in `plugin.yaml` (no schema defined today — file an
   upstream request).
6. **Hermes core MCP support.** If upstream Hermes ever adds native
   `.mcp.json` support, this entire adapter collapses to a 4-line
   config entry. We should re-check at every `hermes update`.

---

## 8. Decision matrix

| Option | Effort | Risk | Recommendation |
|---|---|---|---|
| **A. Hermes plugin adapter (this doc)** | ~250 LOC + tests | Low — mirrors existing `rev_contact` subprocess pattern | **Adopt.** |
| B. Upstream a generic MCP loader into Hermes | ~600 LOC + RFC | Med — unblocks every future MCP integration but slow | Worthwhile in parallel as v0.2, not blocking. |
| C. Wrap `stealth-mcp` in an HTTP server, call via `urllib.request` from a plugin | ~400 LOC | Med — adds a network surface (auth, port mgmt, abuse) without removing the adapter | Reject. |
| D. Embed rev_scraping logic directly in a Hermes plugin (no `stealth-mcp`) | Huge | High — duplicates the entire CDP stack in Python | Reject. |

**Final recommendation:** Option A. Defer Option B to a separate v0.2
spike; track in `.agent/active/v1_2_hermes_mcp_native_loader.md` when
opened.

---

## 9. Action items (no code in this PR)

1. Add `docs/integration/hermes/README.md` referencing this report.
2. Add `tests/integration/hermes_smoke.py` (§6.1) — pure-stdlib, no
   Hermes dep. Runs under `cargo test`/CI as a Python smoke job.
3. Open a tracking issue for the open questions in §7 (especially
   §7.1 — `ctx` surface dump on the live VPS).
4. After v1.1 GA: cut a `rev-scraping-mcp` companion repo or
   subdirectory carrying the adapter; do **not** vendor it into the
   rev_scraping main crate (different language, different release
   cadence, different consumer).

---

## 10. References

- `~/dev/sanuvps_hermesagent_bak/extensions/hermes/docs/LOCAL_EXTENSIONS.md`
- `~/dev/sanuvps_hermesagent_bak/extensions/hermes/plugins/cybertomo-case-sync/__init__.py:3458` (`register(ctx)`)
- `~/dev/sanuvps_hermesagent_bak/extensions/hermes/plugins/telegram-scoped-allowlist/__init__.py:85` (`register(ctx)`)
- `~/dev/contact_dev/services/hermes-agent/src/hermes_agent/captcha_relay/rev_contact_invoke.py` (subprocess pattern + `_drain_stderr`)
- `~/dev/rev_scraping/crates/stealth-mcp/src/server.rs:50` (`run_stdio`)
- `~/dev/rev_scraping/crates/stealth-mcp/src/tools.rs:33` (`tool_definitions`)
- MCP spec: <https://modelcontextprotocol.io> (transport + JSON-RPC framing)

— end of report —
