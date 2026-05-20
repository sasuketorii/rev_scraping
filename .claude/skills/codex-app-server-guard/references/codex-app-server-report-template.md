# Codex app-server guard report

```text
RUN/DEPLOY: GO | NO-GO
Date:
Reviewer:
Repository / branch / commit:
Client/app:
Deployment environment:
Codex CLI/app-server version:
OpenAI project:
Transport:
Auth mode:
```

## Assumptions

-

## Static scan

Command:

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-static-risk-scan.py . --markdown --fail-on high
```

Summary:

- critical:
- high:
- medium:
- low:

## Launch command review

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-launch-guard.py '<command>'
```

Findings:

-

## Transport risk

| Item | Value | Risk | Decision |
|---|---|---|---|
| listen |  |  |  |
| ws auth |  |  |  |
| TLS/proxy |  |  |  |
| firewall/IP allowlist |  |  |  |
| rate limit |  |  |  |
| per-user isolation |  |  |  |

## Auth/token risk

| Secret/token | Storage | Exposed to client? | Logs redacted? | Rotation path |
|---|---|---|---|---|
| OpenAI API key |  |  |  |  |
| Codex WS token |  |  |  |  |
| ChatGPT token |  |  |  |  |
| MCP OAuth token |  |  |  |  |

## Sandbox/approval risk

| Setting | Value | Risk | Fix |
|---|---|---|---|
| sandbox_mode |  |  |  |
| approval_policy |  |  |  |
| network_access |  |  |  |
| web_search |  |  |  |
| workspace root |  |  |  |
| secret deny-read |  |  |  |

## JSON-RPC method surface

| Method | Used? | User-facing? | Approval/auth required | Risk |
|---|---|---|---|---|
| thread/start |  |  |  |  |
| command/exec |  |  |  |  |
| thread/shellCommand |  |  |  |  |
| account/login/start |  |  |  |  |
| thread/list/read |  |  |  |  |
| mcpServer/oauth/login |  |  |  |  |
| marketplace/add/upgrade |  |  |  |  |

## MCP/plugin risk

| Server/plugin | Tools | Write/destructive? | OAuth scope | Approval | Audit |
|---|---|---|---|---|---|
|  |  |  |  |  |  |

## Cost blast-radius

| Scenario | Volume | Tokens/tools | Estimated cost | Stop action |
|---|---:|---:|---:|---|
| Normal day |  |  |  |  |
| Bot/untrusted user loop |  |  |  |  |
| Parallel agents maxed |  |  |  |  |
| Retry storm |  |  |  |  |
| Tool use enabled |  |  |  |  |

## Blockers

| Severity | Area | Evidence | Required fix | Owner |
|---|---|---|---|---|
|  |  |  |  |  |

## Required fixes before run/deploy

1.

## Post-run monitors for first 24h

- Active app-server connections:
- Auth failures:
- Approval requested/accepted/declined:
- command/exec count:
- thread/shellCommand count:
- network approvals by host:
- MCP tool calls by server/tool:
- OpenAI tokens by model:
- Tool usage costs:
- Project budget usage:
- Error/overload `-32001`:

## Kill switch / rollback

- Stop app-server:
- Disable proxy:
- Revoke WS token:
- Revoke OpenAI API key:
- Disable model usage:
- Disable MCP connector:
- Turn network off:
- Clear/secure CODEX_HOME:
