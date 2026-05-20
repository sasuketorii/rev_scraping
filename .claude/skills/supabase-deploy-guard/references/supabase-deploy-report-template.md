# Supabase Deploy Guard Report Template

```text
DEPLOY: NO-GO
対象:
- org:
- project ref:
- environment:
- change:

確認した証拠:
- Static scan:
- SQL inventory:
- Security Advisor:
- Performance Advisor:
- Usage/Billing:
- Storage buckets:
- Edge Functions:
- Auth settings:
- Realtime publication:

Blockers:
1.
2.
3.

Required fixes:
1.
2.
3.

Cost exposure:
- Compute:
- Branching/Replica:
- Disk/IOPS/Throughput:
- Egress:
- Storage:
- Image Transformations:
- Edge Functions:
- Auth MAU/SSO/MFA:
- Realtime:
- Log Drain/PITR/IPv4/Custom Domain:
- Spend Cap coverage:
- Spend Cap gaps:

Security exposure:
- RLS:
- Grants:
- API keys/secrets:
- Storage:
- Edge Functions:
- Auth:
- Realtime:
- DB Functions/RPC:
- MCP:

Rollback:
- migration rollback:
- config rollback:
- function rollback:
- key rotation:
- data restore:

Emergency stop:
- block routes:
- disable function:
- private bucket:
- stop auth signup:
- shrink realtime publication:
- stop cron/webhook:
- disable add-ons:

Post-deploy watch:
- first 1h:
- first 24h:
- first 72h:
- thresholds:
- owner:
```
