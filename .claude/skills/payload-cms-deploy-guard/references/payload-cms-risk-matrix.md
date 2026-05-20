# PayloadCMS Risk Matrix

| 領域 | 破綻パターン | 課金/被害メーター | ブロッカー | 必須対策 |
|---|---|---:|---|---|
| Access Control | private dataに`read: () => true` | 情報漏洩、egress、DB read | private/tenant/owner dataで条件なしread | status/tenant/owner filter、field access、tests |
| Local API | public routeで`overrideAccess` bypass | 情報漏洩、権限昇格 | user起点処理で`overrideAccess: false`なし | `user`を渡す、server-only bypassを限定 |
| GraphQL | 深いrelationship query | CPU、DB read、memory、egress | maxComplexityなし、maxDepth高い | disable、complexity、rate limit、query log |
| REST | user-controlled depth/limit/where | DB read、egress | 無制限limit/depth/where | server-side allowlist、pagination、select |
| Upload | bot大量upload | storage、PUT、egress、Sharp CPU | size/MIME/quotaなし | quota、MIME allowlist、WAF、scan |
| Image sizes | 1 uploadから多数variant生成 | storage、CPU、DB write | variant過多、public upload無制限 | imageSizes最小化、async化、quota |
| Object storage | hotlink/download abuse | GET、egress、CDN miss | private/public混在、signed URL長期 | CDN cache、referer/token、TTL、rate limit |
| Hooks | `afterChange`が自己更新 | DB write、jobs、revalidation | 再帰防止なし | `req.context`、idempotency、dedupe |
| Jobs Queue | public APIからqueue連打 | DB writes、worker CPU、外部API | retry/timeout/pauseなし | auth、quota、dedupe、pause/purge |
| Revalidation | 各編集で全ページpurge/build | build minutes、function duration | global revalidate storm | tag/path限定、batch、debounce |
| Email/Auth | bot signup/password reset | email/SMS課金、abuse | rate limit/CAPTCHAなし | maxLoginAttempts、captcha、SMTP quota |
| Search/AI | hookでembedding再生成 | AI tokens、vector/search writes | all docs再indexが無制限 | diff-based、batch、budget、kill switch |
| Migration | drop/alter/backfill事故 | downtime、data loss | backup/rehearsal/rollbackなし | staging、backup、forward plan |
| Cache | user/draft response共有 | 情報漏洩 | cookie/private responseをCDN cache | no-store、cache key、draft isolation |
| CORS/CSRF | wildcard cookie auth | CSRF、account takeover | wildcard/empty allowlist | exact origin、sameSite、CSRF |
| Secrets | public env/client/log露出 | account takeover、cost abuse | secret in repo/public bundle | env isolation、rotate、secret scan |
| Multi-tenant | tenant filter漏れ | cross-tenant leak | tenant field/index/access不備 | access+query両方、tests |
