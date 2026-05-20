# Codex app-server risk matrix

| Area | Failure mode | Cost impact | Security impact | Blocker? | Controls |
|---|---|---:|---:|---|---|
| Transport | non-loopback WebSocket exposed | Medium | Critical | Yes | stdio/loopback, WSS, auth, firewall |
| Transport | WebSocket auth omitted | Medium | Critical | Yes | capability token or signed bearer token |
| Transport | token in CLI args/logs | Low | Critical | Yes | token file, redaction, rotation |
| Auth | API key in browser | Critical | Critical | Yes | server-side auth, project-scoped key |
| Auth | shared ChatGPT account | Medium | High | Maybe | per-user auth, account isolation |
| Auth | external ChatGPT tokens mishandled | Medium | Critical | Yes | secure refresh/storage, per-user isolation |
| Sandbox | danger-full-access/no sandbox | Medium | Critical | Yes | workspace-write/read-only |
| Sandbox | approval never | Medium | Critical | Yes | on-request/untrusted |
| Filesystem | secrets readable and network enabled | Critical | Critical | Yes | deny-read, network off/allowlist |
| Filesystem | shared CODEX_HOME | Low | High | Yes for multi-user | per-user home, encryption |
| Command | thread/shellCommand exposed | High | Critical | Yes | do not expose; explicit approval; sandbox alternative |
| Command | command/exec raw user input | High | Critical | Yes | command builder, denylist, approval |
| Approval | acceptForSession default | Medium | High | Yes if broad | per-action accept, scoped session |
| Approval | network approval UI ambiguous | High | High | Maybe | render host/protocol/port |
| JSON-RPC | thread history cross-tenant | Low | Critical | Yes | authorization, tenant-scoped IDs |
| Experimental | experimentalApi in prod | Medium | Medium | Maybe | version pin, fallback, tests |
| MCP | destructive tools enabled | High | Critical | Yes without approval | read-only, approval, audit |
| MCP | plugin marketplace auto-upgrade | Medium | High | Yes | pin source, human approval |
| Network | live web and arbitrary egress | Critical | High | Maybe | cached/disabled, allowlist, egress logs |
| Prompt injection | repo/web/MCP output treated as trusted | High | High | Maybe | instruction hierarchy, tool confirmation |
| Cost | no project budget/model limits | Critical | Low | Yes for paid prod | budgets, model usage, quotas |
| Cost | unbounded parallel agents | Critical | Medium | Yes | concurrency limit, max turns |
| Cost | retries without backoff | High | Low | Maybe | backoff, retry budget |
| Cost | web/file search/tool costs unbounded | High | Medium | Maybe | disable/quotas |
| Logs | command output/history to analytics | Low | High | Maybe | redaction, retention, opt-in |
| Incident | no key revocation/kill switch | Critical | Critical | Yes | playbook, owner, automation |
