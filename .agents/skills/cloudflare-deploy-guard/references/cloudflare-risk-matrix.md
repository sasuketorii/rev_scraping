# Cloudflareリスクマトリクス

| 領域 | 主な課金メーター | 破綻パターン | ブロッカー | 主要対策 |
|---|---|---|---|---|
| Images Transformations | unique transformation/month | crawlerが`/_next/image`を叩く、variant爆発 | `next/image`利用方針未定 | unoptimized、variant allowlist、origin allowlist、rate limit |
| R2 | GB-month、Class A/B ops | R2 GET/Listが大量発生 | R2 operations試算なし | cache、manifest、List禁止、lifecycle |
| Workers | requests、CPU ms | route過大、外部fetch/CPU高騰 | route/CPU/Rate Limit未確認 | route最小化、WAF、cache、timeout |
| KV | reads、writes/list/delete、storage | `kv.list()`が全リクエスト | list in hot path | index/TTL/cache、list禁止 |
| Durable Objects | rows read/written、storage | 多数`storage.put()`、index write | write回数未計測 | batch、TTL、ephemeral state |
| Queues | operations | consumer再投入loop | idempotency/DLQなし | write_mode固定、DLQ、pause/purge |
| D1 | rows read/written、storage | LIMITなしscan、N+1 | EXPLAIN/row試算なし | index、LIMIT、pagination、cache |
| WAF/Bot | 一部機能はプラン依存 | crawler/攻撃で課金対象に到達 | expensive path無防備 | Rate Limiting、Bot、AI Crawl Control |
| Secrets/API | token権限 | MCP/CI token過大、secret漏洩 | global key/vars secret | least privilege、secrets、audit logs |
| Origin/DNS | origin負荷/侵害 | origin直接アクセス、IP漏洩 | AOP/allowlist未確認 | Authenticated Origin Pulls、proxy、Full(strict) |
| Tunnel/Origin lockdown | Access seats、Logpush等は構成次第 | tunnel token漏洩、catch-all誤公開、connector停止、origin firewall未遮断 | public inbound開放、token平文、Accessなしadmin | Cloudflare Tunnel、inbound deny、7844 + 必要HTTPS egress、Access/Tailscale、catch-all deny、health監視 |
