# Supabase コスト・セキュリティ総合チェックリスト

## 0. 判定原則

- 初期値は `DEPLOY: NO-GO`。
- `UNKNOWN` は `OK` ではない。
- 課金、RLS、secret、migration、rollback、monitoring のどれかが弱ければ `NO-GO`。
- MCP/agent は最初 read-only inventory。書き込み系は承認制。

## 1. 課金チェック

### 1.1 Organization / Plan / Spend Cap

確認:

- 対象 organization と project ref が正しい。
- plan、Spend Cap、usage、upcoming invoice、billing owner を確認した。
- Spend Cap がカバーする項目と、カバーしない項目を分けて見積もった。

Spend Cap 対象:

- Disk Size
- Egress
- Edge Function Invocations
- Monthly Active Users
- Monthly Active SSO Users
- Monthly Active Third Party Users
- Realtime Messages
- Realtime Peak Connections
- Storage Image Transformations
- Storage Size

Spend Cap 非対象:

- Compute
- Branching Compute
- Read Replica Compute/resources
- Custom Domain
- additional Disk IOPS / Disk Throughput
- IPv4 address
- Log Drain Hours / Events
- Advanced MFA Phone
- Point-in-Time Recovery

ブロッカー:

- Spend Cap OFF かつ public endpoint / bot / loop / egress の上限設計なし。
- 非対象 add-on を試しに有効化する。
- billing email が誰も見ていない。

### 1.2 Compute / projects

確認:

- paid org の project は compute hours を発生させる。
- 複数 project、staging、dev、preview の owner と expiry がある。
- compute size 変更は cost と downtime を確認した。

ブロッカー:

- 不要 project が active。
- performance 問題を index/RLS/query 改善なしに compute upgrade で隠す。

### 1.3 Branching

確認:

- branch は別 environment として compute/disk/storage/egress を消費する。
- preview branch は短命、persistent branch は owner/expiry 必須。
- merge/delete 自動化または棚卸しがある。

ブロッカー:

- PRごとにbranchを作るが削除されない。
- persistent branch が目的なしに残る。

### 1.4 Read Replicas

確認:

- replica は primary と同じ compute size を使い、disk/IOPS/throughput/IPv4 も追加され得る。
- replication lag を許容できる path にだけ使う。
- deletion/disable plan がある。

ブロッカー:

- latency目的だけで費用・lag・削除日がない。

### 1.5 Disk / Database size

確認:

- database size は data/index/materialized view 等。
- disk size は WAL や Postgres の追加ファイルも含む。
- large import、event table、logs、JSONB、embeddings、chat history、analytics、indexes の増加を見積もった。
- retention、partition、archive、vacuum、index strategy がある。

ブロッカー:

- 無制限 event/log/embedding table。
- 大量 import 前に disk/read-only リスクを確認していない。

### 1.6 Egress

確認:

- Egress は Database/Auth/Storage/Edge Functions/Realtime/Log Drains/Supavisor で発生する。
- Storage CDN の cached/uncached egress を分ける。
- endpoint ごとに response bytes、rows、requests、cache、rate limit を見積もる。

ブロッカー:

- public API が大量 rows/large JSON/file を返せる。
- `select('*')` や export/download が無制限。
- log drain の event/egress/destination cost が不明。

### 1.7 Edge Functions

確認:

- invocation は status code に関係なく発生し得る。OPTIONS は例外。
- webhook replay、bot、client retry、cron、self-call、third-party API を見積もる。
- JWT/signature verification、rate limit、timeout、idempotency、retry budget がある。

ブロッカー:

- public function が誰でも叩ける。
- `--no-verify-jwt` なのに内部 auth なし。
- webhook signature なし。

### 1.8 Storage / Image Transformations

確認:

- Storage size は total asset size。
- Image Transformations は origin image ベースの package 課金。
- public transformed URL に crawler が来る想定をした。
- width/height/quality は allowlist か clamp。
- upload は size/MIME/path ownership/overwrite policy を持つ。

ブロッカー:

- user upload が public bucket。
- private attachments/invoices/exports が public URL。
- transform endpoint が無制限公開。

### 1.9 Realtime

確認:

- message count と peak connections を見積もる。
- `postgres_changes` は table/event/filter を限定。
- React/Vue/Svelte などの component lifecycle で cleanup している。
- publication に含む table を監査。

ブロッカー:

- `event: '*'` や high-write table 全体 subscribe。
- unsubscribe/removeChannel なし。
- presence/broadcast spam 対策なし。

### 1.10 Auth / MAU / SMS

確認:

- MAU、Third-Party MAU、SSO MAU、Advanced MFA Phone、外部 SMS/SMTP/provider cost を見積もる。
- public signup、anonymous sign-in、OTP、phone auth、OAuth は abuse control がある。
- Auth rate limits、CAPTCHA/Turnstile、email confirmation、redirect URL allowlist を確認。

ブロッカー:

- anonymous sign-in を bot 対策なしで公開。
- SMS/phone auth/provider quota がない。
- redirect URL wildcard。

### 1.11 Log Drains

確認:

- hours、events、egress、destination cost を見積もる。
- gzip、filtering、sampling、redaction を設定。
- secret/PII/payment data を出さない。

ブロッカー:

- 全ログを高頻度転送。
- Authorization header や raw body をログ化。

### 1.12 PITR / backups

確認:

- daily backup と PITR の違いを理解。
- Free では外部 dump/offsite backup。
- migration 前 backup と restore test。
- project deletion は backup 含め不可逆。

ブロッカー:

- 本番データなのに restore test なし。
- destructive migration 前 backup なし。

## 2. セキュリティチェック

### 2.1 API keys / secrets

- frontend は publishable key または legacy anon key のみ。
- `sb_secret_*` と `service_role` は backend/Edge/server only。
- `service_role` は RLS を bypass するため、user-facing request では必ず app-level authz を行う。
- public env prefix に secret を入れない: `NEXT_PUBLIC_*`, `VITE_*`, `NUXT_PUBLIC_*`, `EXPO_PUBLIC_*`, `PUBLIC_*`。
- `.env` は gitignore。repo history も scan。
- key rotation plan を持つ。

ブロッカー:

- client bundle に secret/service-role/database URL。
- MCP/agent が secret 値を表示できる。

### 2.2 RLS

- exposed schema、特に `public` の table は RLS enabled。
- SQL/migration で作った table は RLS を明示。
- policy は `TO authenticated` / `TO anon` を明示。
- owner/non-owner/anon/authenticated/admin/service-role のテスト。
- policy columns に index。
- `raw_user_meta_data` を authorization に使わない。

ブロッカー:

- RLS disabled table が public API で触れる。
- `using (true)` を anon に付ける。
- `for all` policy を雑に使う。

### 2.3 Views / functions / grants

- Postgres views は RLS を bypass し得る。Postgres 15+ なら `security_invoker = true`。
- older Postgres では view access revoke または unexposed schema。
- `SECURITY DEFINER` は private schema、fixed `search_path`、least EXECUTE grants。
- `GRANT ALL` や default privileges を広く与えない。

ブロッカー:

- public schema の security definer が anon から実行可能。
- view 経由で RLS が無効化される。

### 2.4 Storage RLS

- Storage は `storage.objects` の RLS policies で操作を許可。
- upload/select/update/delete を分けて考える。
- object path に tenant/user ownership を組み込む。
- upsert/overwrite を最小化。

ブロッカー:

- user が他 user の path を上書き/削除できる。
- public bucket に sensitive data。

### 2.5 Edge Functions

- JWT verification または custom auth。
- service role は caller and ownership check 後だけ。
- CORS origin を最小化。
- webhook signature/timestamp/replay/idempotency。
- secrets は Supabase secrets。ログに出さない。

ブロッカー:

- `user_id` を body/query で受け取り service role で操作。
- `Authorization` header 無視。
- webhook signature 無検証。

### 2.6 Migration

- staging -> production の順で実行。
- destructive/risky SQL は backup、transaction、down migration、rollback、lock impact を確認。
- RLS change は matrix test。
- extension/trigger/cron/publication/grant/security definer は high-risk。

ブロッカー:

- `DROP`, `TRUNCATE`, `DELETE`, `UPDATE`, `DISABLE RLS` に rollback なし。

## 3. デプロイ後監視

T+1h / T+6h / T+24h / 次回請求前:

- Usage/upcoming invoice。
- Egress breakdown。
- Edge Function invocations, errors, top paths。
- Realtime messages/peak connections。
- Storage size/image transformations。
- Auth signups/MAU/OTP/email/SMS。
- Disk size/database size/WAL/read-only risk。
- Branches/replicas/add-ons still active。
- Logs for bots/retry loops/4xx/5xx。
- Security Advisor / Performance Advisor。

## 4. Kill switches

- Feature flag off。
- Edge Function disable/block/503。
- Proxy/WAF rate limit/block。
- Storage bucket private、signed URL TTL短縮。
- Realtime publication removal。
- Auth provider/signup/anonymous sign-in停止。
- Spend Cap ON、branch delete、replica delete、log drain disable、add-on remove。
- API key rotate、secret revoke、session invalidate。
- Bad cron/trigger/job disable。
