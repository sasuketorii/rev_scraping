# Codex App Server Deploy Review Report Template

```text
DEPLOY: GO | NO-GO
対象:
- Pattern: local stdio / loopback ws / remote ws / hosted custom client / multi-tenant / CI
- Environment:
- Host:
- Client:
- Codex version:
- Transport:

変更概要:

Critical blockers:
1.

High risks:
1.

Transport/Auth:
- Listen address:
- Auth mode:
- Token storage:
- TLS/proxy/IP allowlist:
- Rate limit/backoff:

Sandbox/Approvals:
- sandbox_mode:
- approval_policy:
- requirements.toml:
- network access:
- filesystem deny rules:
- approval routing:

Protocol surface:
| Method/surface | Used? | Risk | Guardrail |
|---|---|---|---|
| thread/start | | | |
| turn/start | | | |
| command/exec | | | |
| review/start | | | |
| fs/watch | | | |
| skills/list/config/write | | | |
| app/MCP tools | | | |
| dynamicTools | | | |

Multi-tenant isolation:
- Process isolation:
- CODEX_HOME/auth/config isolation:
- Workspace/thread/log isolation:
- Approval routing:
- Quota/kill switch:

Usage / cost exposure:
| Meter | Normal | Bot/Bug | Guardrail | Owner |
|---|---:|---:|---|---|

Logs/data retention:
- Stored data:
- Redaction:
- Retention:
- Access control:

Checks performed:
- Static scan:
- Config review:
- Protocol review:
- Deployment/proxy review:
- Tests:

Required fixes before GO:
1.

Post-deploy monitoring:
- First 15 min:
- First 1 h:
- First 24 h:
- Emergency stop:
```
