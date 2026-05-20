# Cloudflare Deploy Guard Report Template

```text
DEPLOY: GO | NO-GO
対象:
変更概要:
公式確認:
課金対象棚卸し:
最大リスク:
ブロッカー:
推奨対応:
コスト試算: expected / 10x / bot-crawler / bug-loop
セキュリティ差分:
キルスイッチ:
ロールバック:
監視:
残余リスク:
```

## Source verification

- Source links reviewed: `references/source-links.md`
- Cloudflare Dashboard / MCP / API current values checked:
- Pricing / quota pages checked on:
- Unknown or unverified items:

## Product inventory

| Product | Enabled? | Meter | Current usage | Expected | 10x | Bot/Crawler | Bug loop | Kill switch |
|---|---|---|---:|---:|---:|---:|---:|---|
| Workers / Pages | | requests, CPU, subrequests | | | | | | |
| R2 | | storage, Class A/B ops | | | | | | |
| Images / Transformations | | unique transformations | | | | | | |
| KV | | reads, writes, list, deletes | | | | | | |
| Durable Objects | | row reads/writes, storage | | | | | | |
| Queues | | operations, backlog, retries | | | | | | |
| D1 | | rows read/written, storage | | | | | | |
| Other paid features | | | | | | | | |

## Security review

| Area | Current state | Risk | Required fix |
|---|---|---|---|
| API tokens / MCP | | | |
| Secrets / CI | | | |
| WAF / Rate Limiting | | | |
| Bot / AI crawler controls | | | |
| Origin / DNS / SSL | | | |
| Tunnel / Access / firewall | | | |
| Access / Turnstile | | | |

## Checks performed

- Static scan:
- Account/billing inventory:
- Workers/Pages inventory:
- Storage/data inventory:
- Security/traffic inventory:
- Tunnel/origin firewall inventory:
- Rollback drill:

## Required fixes before GO

1.

## Post-deploy monitoring

- First 15 min:
- First 1 h:
- First 24 h:
- Emergency stop:
