# Supabase Risk Matrix

## 課金メーター別リスク

| Area | Meter / Risk | 破綻パターン | ブロッカー | 対策 |
|---|---|---|---|---|
| Spend Cap | Covered vs not covered | Spend Cap ONなのにCompute/Branch/Read Replica/PITR/Log Drain等で課金 | 対象外項目の棚卸しなし | 対象外項目を別表で管理、不要add-on削除、Usage/Invoice監視 |
| Compute | project/branch/replica hours | Preview branch/replicaを消し忘れて時間課金 | branch TTLなし | auto-delete運用、branch一覧レビュー、downsize/pause |
| Disk | size/IOPS/throughput | 大量upload、WAL、replica、provisioned IOPS放置 | disk見積もりなし | quota/lifecycle、IOPS review、cleanup job |
| Egress | GB out | public bucket hotlink、large JSON、Realtime、DB export、Log Drain | egress経路不明 | CDN/cache、public URL制限、pagination、gzip、rate limit |
| Storage Size | GB-hours | user upload無制限、preview/test file蓄積 | quotaなし | per-user quota、lifecycle、admin cleanup |
| Image Transformations | origin images | ユーザー画像が多く、thumbnailをオンデマンド生成 | 事前サムネ設計なし | upload時生成、size allowlist、transform off、crawler対策 |
| Edge Functions | invocations | public endpointをbotが叩く、webhook retry storm、cron過多 | verify/rate limitなし | verify_jwt、signature、rate limit、body limit、feature flag |
| Auth MAU | unique users | anonymous signup bot、token refreshでMAU増 | signup abuse対策なし | CAPTCHA、rate limit、anonymous off、allowlist/approval |
| SMS/MFA Phone | phone events | OTP連打、海外番号abuse | SMS制御なし | phone auth off/地域制限/rate limit/monitoring |
| Realtime | messages/peak connections | reconnect storm、multi-tab、presence spam | backoff/limitなし | subscription最小化、unsubscribe、backoff、kill switch |
| Log Drains | hours/events/egress | verbose logsやPIIを全送信、drain放置 | drain棚卸しなし | sampling/redaction/GZIP/disable unused drains |
| External API | tokens/emails/SMS | Edge/cron/webhookが外部APIをループ | 外部コスト未試算 | timeout、retry上限、idempotency、budget、circuit breaker |

## セキュリティリスク

| Area | 事故 | ブロッカー | 対策 |
|---|---|---|---|
| service_role / secret | frontend bundleやログへ漏洩し、RLSを迂回される | `NEXT_PUBLIC_*`やclient codeにsecret | secret store、server-only module、rotate、bundle scan |
| RLS disabled | Data API経由で全件read/write | exposed schema tableでRLSなし | RLS enable、policy、GRANT最小化、tests |
| Broad policy | `USING true`や`TO public`で全員アクセス | 例外理由なし | tenant/user条件、operation別policy、pgTAP |
| GRANT過多 | RLS前にobjectへ到達可能 | `GRANT ALL TO anon/authenticated` | 必要操作だけGRANT、schema分離 |
| user_metadata authz | ユーザー編集可能metadataで権限昇格 | `raw_user_meta_data`利用 | app_metadataまたはDB権限表 |
| SECURITY DEFINER | RLS/権限迂回、search_path攻撃 | public schema、search_path未固定 | private schema、search_path固定、EXECUTE制限 |
| Views | RLS bypass | security_invokerなし、GRANT広い | `security_invoker=true`、private schema、GRANT revoke |
| Storage public bucket | 機微ファイル公開、hotlink | public bucket目的不明 | bucket分離、RLS、list禁止、private化手順 |
| Signed URL | URL漏洩で読まれる | TTL長い、path推測可能 | 短TTL、path entropy、ログ管理 |
| Auth redirect | open redirect/token leak | wildcard/preview/localhost混入 | strict allowlist、環境分離 |
| Edge Function public | 認証なしadmin処理 | `verify_jwt=false` + 署名なし | JWT/署名検証、method/body/rate limits |
| MCP prompt injection | DB内ユーザー入力がagentに悪意ある指示 | manual approvalなし | read-only、project_ref、feature groups、手動承認 |
| Extensions | SSRF/外部接続/cron loop | http/pg_net/FDWがexposed | private schema、EXECUTE revoke、timeout |

## Migration / Availabilityリスク

| Change | 事故 | ブロッカー | 対策 |
|---|---|---|---|
| DROP/TRUNCATE/DELETE | データ消失 | backup/restore未確認 | backup/PITR、影響行数、rollback、maintenance |
| ALTER TYPE / SET NOT NULL | table lock / downtime | lock_timeoutなし | expand-contract、段階migration、timeout |
| CREATE INDEX | lock / long query | large tableでCONCURRENTLY検討なし | concurrent index、traffic低い時間 |
| Backfill | CPU/IO枯渇、replication lag | batch設計なし | batched update、sleep、monitoring |
| RLS変更 | 本番で見えない/見えてはいけない | RLS testsなし | anon/authenticated tests、canary |
| Function deploy | webhook/cron failure | rollbackなし | previous version、feature flag |
| Config/Auth redirect | login不能/token leak | staging未検証 | staging login test、rollback config |
| Branch merge | prod schema破壊 | diff未review | branch migration review、advisors、backup |
