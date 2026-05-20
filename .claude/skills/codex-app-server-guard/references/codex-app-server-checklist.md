# Codex app-server cost & security checklist

## 0. Architecture

- [ ] Use case is correct for app-server: rich client integration, not simple CI/background automation.
- [ ] Client type is identified: local desktop/IDE, browser frontend, server-side web app, CLI wrapper, remote SaaS, internal platform.
- [ ] Transport is identified: stdio, loopback websocket, remote websocket, proxy, unix socket, off.
- [ ] Trust boundary is identified: single developer machine, internal team, multi-user SaaS, untrusted users.
- [ ] Process isolation is defined: per-user process, per-session process, shared process.
- [ ] `CODEX_HOME` and thread storage are per-user/per-tenant and not shared accidentally.
- [ ] Supported OS sandbox behavior is known for deployment environment.

## 1. Transport and network exposure

- [ ] `stdio://` is used wherever possible.
- [ ] Loopback WebSocket is limited to localhost/SSH tunnel.
- [ ] Non-loopback WebSocket is not used, or has documented exception approval.
- [ ] Remote access uses WSS/TLS termination.
- [ ] WebSocket auth is enabled before JSON-RPC initialize.
- [ ] Capability token uses `--ws-token-file /absolute/path` or verifier hash with separate secret store.
- [ ] Signed bearer token uses shared secret file, issuer, audience, exp, nbf, clock skew.
- [ ] Token files are 0600 and not world-readable.
- [ ] Tokens are not passed via CLI args, shell history, logs, browser storage, or URLs.
- [ ] Proxy has auth, rate limit, max connections, request size limit, IP allowlist/firewall.
- [ ] Health endpoints are not used as auth bypass.
- [ ] Bounded queue overload is retried with exponential backoff and jitter.

## 2. Authentication and account handling

- [ ] OpenAI API keys are project-scoped and stored server-side.
- [ ] API keys are never exposed to browsers or untrusted clients.
- [ ] API keys can be revoked quickly.
- [ ] API project has model usage restrictions.
- [ ] API project has project-level rate limits where needed.
- [ ] Project budget alerts and usage owner are configured.
- [ ] ChatGPT managed auth is per-user, not shared.
- [ ] External ChatGPT token mode is avoided unless the host app owns secure auth lifecycle.
- [ ] Access/refresh tokens are encrypted at rest.
- [ ] Token refresh errors do not leak token contents.
- [ ] Account info and rate limits are only visible to the authenticated user/tenant.

## 3. Sandbox and filesystem

- [ ] Default sandbox is read-only or workspace-write.
- [ ] `approval_policy` is `on-request` or stricter.
- [ ] `danger-full-access`, `danger-no-sandbox`, and `--yolo` are absent.
- [ ] Workspace root is narrow and expected.
- [ ] Home directory is not mounted as writable workspace.
- [ ] `.env`, `.ssh`, cloud credentials, kubeconfig, npm tokens, GitHub tokens, production DB dumps are deny-read.
- [ ] `.git`, `.agents`, `.codex` protections are understood and not relied on as the only control.
- [ ] Temporary directories do not persist sensitive files across users.
- [ ] Command timeout and process tree cleanup are configured.
- [ ] Background terminals are cleaned up.
- [ ] File diffs are reviewed before write approval.

## 4. Approval UX

- [ ] Command approval shows command, cwd, reason, and risk.
- [ ] Network approval shows host, protocol, and port.
- [ ] File change approval shows diff and grantRoot.
- [ ] Experimental additional permissions are rendered clearly.
- [ ] Proposed exec policy amendments are rendered clearly.
- [ ] `acceptForSession` is not default.
- [ ] Session-level approval has scope and expiry.
- [ ] Decline/cancel paths work and are audited.
- [ ] Approval requests cannot be auto-accepted by hidden client logic.
- [ ] Destructive MCP/app tools always require explicit approval.
- [ ] UI distinguishes network approval from command approval.

## 5. JSON-RPC client safety

- [ ] `initialize` only advertises needed capabilities.
- [ ] `experimentalApi` is false unless necessary.
- [ ] JSON-RPC ids are mapped per connection and cannot cross sessions.
- [ ] threadId/turnId/requestId are scoped to authenticated user/session.
- [ ] `thread/shellCommand` is not exposed to untrusted users.
- [ ] `command/exec` does not take raw user input as shell command.
- [ ] `thread/inject_items` cannot inject hidden system/developer instructions from untrusted sources.
- [ ] `thread/list/read/turns/list` enforce per-user/tenant history access.
- [ ] `thread/archive/unarchive/rollback` has authorization.
- [ ] `account/logout` cannot log out another user.
- [ ] Streaming stdout/stderr is redacted before logs/analytics.

## 6. Network and prompt injection

- [ ] Sandbox network access is off by default.
- [ ] If network is needed, domains and ports are allowlisted.
- [ ] Live web search is disabled or approval-gated.
- [ ] Web results, docs, repo files, issue titles, branch names, terminal output, MCP outputs are treated as untrusted.
- [ ] Agent cannot both read secrets and access arbitrary network.
- [ ] Dependency install is isolated to setup or explicit approval.
- [ ] Package manager scripts are reviewed.
- [ ] SSRF-sensitive internal URLs are blocked.
- [ ] Egress logs are reviewed.

## 7. MCP / apps / plugins

- [ ] MCP servers are inventoried.
- [ ] MCP tools/resources/prompts are classified read-only vs write/destructive.
- [ ] OAuth scopes are minimal.
- [ ] MCP tokens are per-user and revocable.
- [ ] Destructive tools require approval even if the tool annotation is incomplete.
- [ ] Tool args are validated by strict schema.
- [ ] Tool outputs have size/token limits.
- [ ] `marketplace/add` and `marketplace/upgrade` require human approval.
- [ ] Plugin sources are pinned and trusted.
- [ ] Dynamic tools are disabled unless necessary.
- [ ] MCP logs redact secrets and PII.

## 8. Cost controls

- [ ] Project budget alert is configured, with owner who reads it.
- [ ] Model usage restrictions prevent expensive models unless needed.
- [ ] Project and model rate limits are configured where possible.
- [ ] Per-user/per-tenant quotas are enforced by the host app.
- [ ] Max parallel agents are limited.
- [ ] Max turns per user/day are limited.
- [ ] Max tokens / max output / max file attachments / max repository size are limited.
- [ ] Tool costs are disabled or quota-controlled: web search, file search, containers, image, video, realtime.
- [ ] Retries have backoff and max attempts.
- [ ] Background continuation/automation cannot run indefinitely.
- [ ] Usage dashboard is checked after launch.
- [ ] Kill switch can revoke API key, block model, stop app-server, disable proxy, disconnect MCP.

## 9. Logging, privacy, retention

- [ ] Command outputs are not logged wholesale.
- [ ] Conversation history is encrypted at rest.
- [ ] Retention period is defined.
- [ ] User can delete/export history if product requires it.
- [ ] Logs are per-user/tenant isolated.
- [ ] Sensitive paths and file contents are redacted.
- [ ] Approval decisions are auditable.
- [ ] Token refresh/account updates are auditable without leaking tokens.
- [ ] Crash dumps do not include secrets.

## 10. Incident response

- [ ] Stop app-server process.
- [ ] Disable proxy route.
- [ ] Revoke WebSocket token.
- [ ] Revoke OpenAI API key.
- [ ] Force ChatGPT/account logout where possible.
- [ ] Revoke MCP OAuth tokens.
- [ ] Turn off sandbox network access.
- [ ] Rotate repository/GitHub/cloud tokens if workspace was exposed.
- [ ] Preserve redacted audit logs.
- [ ] Check OpenAI usage and tool spend for anomaly window.
