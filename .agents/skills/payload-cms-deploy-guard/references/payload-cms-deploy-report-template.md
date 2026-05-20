# PayloadCMS Deploy Review Report Template

```text
DEPLOY: GO | NO-GO
対象:
- App:
- Environment:
- Host:
- Database:
- Storage:
- CDN/WAF:
- Email/Search/AI providers:

変更概要:

Critical blockers:
1.

High risks:
1.

Access Control inventory:
| Slug | Sensitivity | Create | Read | Update | Delete | Field restrictions | Local API paths |
|---|---|---|---|---|---|---|---|

API exposure:
- REST:
- GraphQL:
- Custom endpoints:
- Preview/draft:
- Admin:

Upload/storage exposure:
- Upload collections:
- Storage provider:
- File size/MIME/quota:
- imageSizes/transformations:
- public/private separation:
- hotlink/rate limit:

Jobs/hooks exposure:
- Hooks:
- Jobs:
- Cron/schedule:
- External APIs:
- Idempotency/retry/pause:

Migration review:
- Files:
- Destructive changes:
- Backup:
- Staging rehearsal:
- Rollback/down:
- Lock/downtime:

Cost exposure:
| Meter | Normal | Bot/Bug | Guardrail | Owner |
|---|---:|---:|---|---|

Security exposure:
- Secrets:
- CORS/CSRF:
- Auth/admin:
- Multi-tenant:
- Cache:

Checks performed:
- Static scan:
- Manual code review:
- Official Payload Skill/docs:
- DB/storage/hosting dashboard:
- Tests:

Required fixes before GO:
1.

Post-deploy monitoring:
- First 15 min:
- First 1 h:
- First 24 h:
- Emergency stop:
```
