# PayloadCMS Cost & Security Checklist

確認時点: 2026-05-05。Payload本体はOSSだが、本番運用ではhosting、database、object storage、CDN、email/SMS、search、AI、observability、backupが課金源になる。料金は必ず各プロバイダの公式Pricingで再確認する。

## 1. Project / Hosting

- [ ] Hosting providerを特定した: Vercel / Netlify / Cloudflare / Fly / Render / Railway / AWS / GCP / Azure / VPS / Docker
- [ ] serverless / edge / container / VMの実行モデルを把握した
- [ ] API route、admin、GraphQL、uploads、jobs runnerが同じruntimeで動くか分離されているか確認した
- [ ] cold start、function duration、CPU/memory、concurrency、max request body、timeoutを確認した
- [ ] preview deploymentsが本番DB/storage/email/AI providerに接続していない
- [ ] build minutes、ISR/revalidation、on-demand cache purgeの課金を確認した
- [ ] WAF/CDN/rate limit/maintenance modeで緊急停止できる

## 2. Payload Config

- [ ] `secret: process.env.PAYLOAD_SECRET`であり、直書きではない
- [ ] `PAYLOAD_SECRET`が十分長く、本番とpreview/stagingで分離されている
- [ ] `routes.api`、`routes.admin`、GraphQL routeを把握した
- [ ] `cors`は本番originのallowlistで、wildcardではない
- [ ] `csrf`はcookie authを許可するoriginだけに限定している
- [ ] `maxDepth`を最小にしている。public APIでは原則1-2、必要時でも理由を記録する
- [ ] GraphQLは不要なら`disable: true`
- [ ] GraphQLが必要なら`maxComplexity`、rate limit、query log、Playground無効化を設定した
- [ ] Admin routeはHTTPS、secure cookie、login attempt制限、監査ログを備える

## 3. Access Control

- [ ] Collection/Global/Fieldごとのcreate/read/update/delete表を作った
- [ ] public readは`published`やstatus条件に限定している
- [ ] tenant/organization/owner境界をAccess Controlで保証している
- [ ] Field-level secret、PII、internal flags、payment/customer ids、tokens、draft/private fieldsを隠している
- [ ] `read: () => true`をprivate/tenant/owner dataに使っていない
- [ ] `create/update/delete: () => true`をspam/改ざん可能な経路に使っていない
- [ ] Access Operationで`id`、`doc`、`data`がundefinedになるケースを考慮している
- [ ] Local APIのユーザー起点操作は`user` + `overrideAccess: false`を明示している
- [ ] server-only bypassは用途、呼び出し元、入力検証、監査ログを記録している

## 4. REST / GraphQL / Custom Endpoints

- [ ] public REST endpointsにlimit、pagination、select、depth制限がある
- [ ] user-controlled `where`、`sort`、`depth`、`limit`をそのままPayloadへ渡していない
- [ ] unbounded regex、full text、relationship sort、deep populateにindex/上限がある
- [ ] custom endpointはmethod、auth、role、tenant、body size、rate limit、CSRF/CORSを確認する
- [ ] webhook endpointは署名検証、timestamp、idempotency、replay防止、retry制御を持つ
- [ ] draft/preview endpointはpreview secretとcache分離を持つ
- [ ] user-specific responseをCDN/ISRで共有cacheしない

## 5. Auth / Admin

- [ ] Auth collectionは`maxLoginAttempts`と`lockTime`を設定している
- [ ] email verificationを必要なsignup flowで有効にしている
- [ ] bot prevention / CAPTCHA / WAF / rate limitを検討した
- [ ] password reset、email change、OTP、inviteにrate limitと監査ログがある
- [ ] admin rolesを最小権限にしている
- [ ] first admin/bootstrap user作成後、seed credentialsを削除・rotateした
- [ ] cookiesはsecure、sameSite、domain/pathを本番originに合わせて設定している

## 6. Uploads / Storage / Images

- [ ] Upload collectionのcreate/update/read/delete accessを明示した
- [ ] MIME allowlistを設定した
- [ ] max file sizeを設定した
- [ ] user/org/project単位のquotaを設定した
- [ ] dangerous MIME、SVG、HTML、JS、PDFなどの扱いを定義した
- [ ] malware/virus scanまたは隔離フローを設計した
- [ ] ephemeral filesystemではなく永続ストレージを使っている
- [ ] public assetとprivate assetをbucket/path/policyで分離した
- [ ] signed URLのTTL、scope、reuse可否を定義した
- [ ] CDN cache/hotlink/rate limitを設定した
- [ ] imageSizes/variants数を制限し、bot大量upload時のSharp CPUとstorage増加を試算した
- [ ] Next Image/CDN transformationとPayload imageSizesの二重最適化を避けている

## 7. Hooks / Jobs Queue / Cron

- [ ] `afterChange`で同じcollectionを更新する場合、`req.context`などで再帰防止している
- [ ] `afterRead`に高価な外部API、DB write、jobs queueを置いていない
- [ ] `afterChange`のrevalidationはidempotentで、burst制御されている
- [ ] `payload.jobs.queue()`はpublic endpointから無制限に呼ばれない
- [ ] jobsにidempotency key、dedupe、timeout、retry上限、manual pauseがある
- [ ] schedule/autoRunが複数instanceで重複実行しない
- [ ] job retention/cleanup/indexを設定した
- [ ] email/search/AI/webhook連携の外部課金を試算した

## 8. Database / Migration

- [ ] DB adapterを特定した: Postgres / MongoDB / SQLite
- [ ] 本番migrationは明示的に作成・commit・実行される
- [ ] destructive SQL/DDL/DMLはbackup、staging rehearsal、lock時間、rollbackがある
- [ ] Postgresではfilter/sort/tenant/relationship fieldsにindexを検討した
- [ ] Mongoではquery shape、compound index、collection size、document growthを確認した
- [ ] versions/drafts/localization/array/block/join fieldsのstorage増加を試算した
- [ ] connection pooling、serverless connection storm、statement timeout、backup/PITRを確認した

## 9. Secrets / Supply Chain

- [ ] `PAYLOAD_SECRET`、DB URL、storage keys、SMTP/API keys、webhook secretsをpublic envに置いていない
- [ ] `.env*`、seed dump、migration dump、logs、screenshots、error reportsにsecretがない
- [ ] package lock、dependency updates、Sharp/native deps、storage pluginsを確認した
- [ ] Admin custom componentsやrich text renderingでXSS sanitizationを確認した
- [ ] webhook/AI/search/email provider keysは最小権限・環境分離・rotate可能

## 10. Emergency Stop

- [ ] Uploadを止める手順がある
- [ ] Jobs runner/cronを止める手順がある
- [ ] GraphQLを止める、またはcomplexity/depthを下げる手順がある
- [ ] revalidation/webhookを止める手順がある
- [ ] storage/CDN hotlink/rate limitを切り替える手順がある
- [ ] DB connection/statement timeout/read-only化手順がある
- [ ] secret rotation、admin session invalidate、rollback deploy手順がある
