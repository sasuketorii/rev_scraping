---
name: payload-cms-deploy-guard
description: Use before any Payload CMS production deploy, payload.config.ts change, collection/global schema change, access-control change, auth change, upload/storage/image-processing change, Jobs Queue/cron change, custom endpoint, REST/GraphQL exposure, database migration, or integration with hosting, database, object storage, CDN, email, search, webhook, or AI providers. Produces a GO/NO-GO gate for unintended billing, data exposure, privilege escalation, API abuse, file-upload abuse, performance collapse, and rollback readiness.
---

# PayloadCMS Deploy Guard

このSkillは、Payload CMSを本番へ出す前に、**意図しない従量課金・データ漏洩・アクセス制御ミス・ファイルアップロード事故・DB migration事故・Jobs Queue暴走**を止めるための最終ゲートです。

公式のPayload Skillは実装・設計・デバッグに使い、このSkillはリリース前に必ず通す **DEPLOY: GO / NO-GO 判定**として使います。

## 同梱ファイル

- `references/source-links.md` — Payload公式Docs、Pricing、adapter、uploads、Jobs、deploymentの参照先。仕様・価格確認はここを入口にする。
- `references/payload-cms-cost-security-checklist.md` — 課金・セキュリティ・運用事故の詳細チェックリスト。
- `references/payload-cms-risk-matrix.md` — hosting、DB、storage、images、GraphQL、jobs、外部APIのリスク表。
- `references/payload-cms-deploy-report-template.md` — `DEPLOY: GO / NO-GO` 判定レポートのテンプレート。
- `references/payload-cms-official-skill-playbook.md` — 公式Payload SkillとこのDeploy Guardの使い分け。
- `prompts/codex-payload-cms-deploy-review-prompt.md` — Codexへ貼る短縮レビュー指示。
- `scripts/payload-cms-static-risk-scan.py` — 静的リスクスキャン。
- `scripts/payload-cms-postgres-audit.sql` / `scripts/payload-cms-mongo-audit.js` — DB adapter別のread-only監査。
- `scripts/payload-cms-runtime-probe.py` — 自分のstaging/productionだけに使う軽量runtime probe。
- `scripts/payload-cms-cost-scenario-estimator.py` — 課金メーター洗い出し用の概算テンプレート。

## 公式Skillとの併用

先に公式Payload Skillsを入れる。

```bash
npx skills add payloadcms/skills
```

通常の実装は公式`payload` Skillで進める。このSkillは、実装済みの差分を課金・セキュリティ・運用事故の観点で審査する。

## 最重要ルール

1. 初期判定は常に `DEPLOY: NO-GO` から始める。
2. `payload.config.ts`、Collections、Globals、Hooks、custom endpoints、REST、GraphQL、Local API、Uploads、Jobs Queue、DB migrations、Next.js routesを全て棚卸しするまでGOにしない。
3. publicに読ませるCollection/Globalは、`published`、tenant、owner、role、localeなどの条件を明示する。`read: () => true`は原則ブロッカーとして扱う。
4. PayloadのLocal APIはaccess controlをデフォルトでスキップする。ユーザー起点の処理では必ず`user`を渡し、`overrideAccess: false`を明示する。
5. public route handler、server component、server action、webhook、job、hook内の`payload.find/create/update/delete`は、認可・tenant境界・limit・depth・select・idempotencyを確認する。
6. GraphQLは不要なら`graphQL.disable: true`。使うなら`maxComplexity`、`maxDepth`、rate limit、query log、abuse testを必須にする。
7. `maxDepth`は最小化する。relationship/uploadの再帰、循環参照、深いpopulateはDB/CPU/メモリ/egressを急増させる。
8. Uploadsは、`create/update/read` access、MIME allowlist、file size上限、ユーザー別quota、ウイルス/危険ファイル検査、hotlink対策、CDN/cache、永続ストレージを必須にする。
9. ephemeral filesystemのホストでは、PayloadのUploadをローカル保存で本番運用しない。S3/R2/Vercel Blob/GCS/Azure Blobなどの永続ストレージを使う。
10. image sizes、Sharp処理、Next Image、CDN画像変換、object storage egressはbotや大量uploadで膨らむため、variant数と変換経路を制限する。
11. Auth collectionは`maxLoginAttempts`、`lockTime`、email verification、bot対策、MFA/SSO要否、admin user管理を確認する。
12. Cookie authを使うならCORSとCSRFのallowed originsを完全一致で管理する。wildcardや空配列、preview URLの過剰許可はNO-GO。
13. Jobs Queue、cron、hooks、webhooks、revalidation、email、AI embedding、search indexingは、再帰・再投入・リトライ嵐・外部API課金を想定して設計する。
14. Migrationはforward-only。破壊的DDL/DMLはbackup、staging rehearsal、lock時間、rollback/down、data backfill、監視がなければNO-GO。
15. `PAYLOAD_SECRET`、`DATABASE_URL`、S3/R2 keys、SMTP/API keys、webhook secrets、OpenAI/LLM keysをpublic env、client bundle、ログ、画像metadata、seed dumpに出さない。
16. 課金試算は「現在PV」ではなく、bot、crawler、retry、preview環境、画像/ファイル大量upload、GraphQL深掘り、Jobs loop、hook stormで行う。

## 必須出力フォーマット

必ず次の形式で返す。

```text
DEPLOY: GO | NO-GO
対象: <project/environment/host/database/storage>
変更概要: <config/schema/access/upload/job/migration/endpoint/etc>
判定理由: <1-3行>

Critical blockers:
- ...

High risks:
- ...

Cost exposure:
- Meter: <hosting CPU/memory/duration, DB IO/storage, object storage ops/egress, image transforms, email/SMS, search, AI tokens, CDN, build/revalidation>
  Normal: <estimate>
  Bot/Bug scenario: <estimate>
  Guardrail: <quota, rate limit, CDN/WAF, kill switch, disable GraphQL/upload/job, maxDepth/maxComplexity, backup>

Security exposure:
- Access Control / Local API / Auth / CORS-CSRF / Uploads / GraphQL / Jobs / Secrets / DB / Admin / Multi-tenant

Checks performed:
- Static scan: <script result>
- Official Payload Skill/docs review: <what was checked>
- DB/storage/hosting dashboard or config review: <evidence or not available>
- Migration review: <files>
- Rollback drill: <status>

Required fixes before GO:
1. ...

Post-deploy monitoring plan:
- First 15 min:
- First 1 h:
- First 24 h:
- Emergency stop:
```

`DEPLOY: GO`にしてよいのは、Critical blockersが0で、High risksに所有者・緩和策・監視・停止手順が付いている場合だけ。

## 実行手順

### 1. 変更差分を棚卸しする

必ず次を列挙する。

- `src/payload.config.ts`、`payload.config.ts`、`payload.config.*`
- `collections/**`、`globals/**`、`fields/**`、`hooks/**`、`access/**`
- `src/app/api/**`、`app/api/**`、`pages/api/**`、server actions、route handlers
- `supabase/migrations/**`、`drizzle/**`、`src/migrations/**`、Payload migrations
- `next.config.*`、`middleware.*`、`vercel.json`、Dockerfile、docker-compose、k8s、Terraform
- Upload storage plugins、S3/R2/GCS/Azure/Vercel Blob/UploadThing設定
- Jobs Queue、task/workflow、cron、webhook、revalidation、search/AI/email連携
- GraphQL、REST、custom endpoints、admin route、preview route
- env/secrets、public env、CI/CD、hosting dashboard、DB/storage/CDN/email/AI providerのquota

### 2. 静的スキャンを実行する

```bash
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-static-risk-scan.py . --markdown --fail-on high
```

スキャンが使えない場合は、同等の観点を手で確認する。secret値は絶対に出力せず、ファイル名・行番号・種別だけ出す。

### 3. DB/Runtime監査を実行する

対象adapterと環境に応じて、stagingまたはread-only userで先に実行する。productionに対して実行する場合は、接続先、権限、負荷、出力にsecret/PIIが含まれないことを確認してから行う。

Postgres adapter:

```bash
psql "$DATABASE_URL" -f .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-postgres-audit.sql
```

MongoDB adapter:

```bash
mongosh "$MONGODB_URI" .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-mongo-audit.js
```

自分のstaging/productionドメインだけに対して、CORS、GraphQL到達性、GraphQL introspectionを軽く確認する。

```bash
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-runtime-probe.py https://example.com
```

### 4. 公式Payload Skillを使って設計を確認する

公式Skillを使って、以下を確認する。

- Collection/Global/Field access controlが用途に合っているか
- Local APIで`overrideAccess: false`が必要な経路がないか
- hooksで無限ループ、再帰更新、revalidation stormが起きないか
- relationship/query/depth/select/limitが過剰でないか
- Jobs Queueのtask/workflow/queue/schedule/autoRunが安全か
- migrationがPostgres/Mongo/SQLite adapterの期待動作に沿っているか

### 5. Access Controlを監査する

Collectionごとに表を作る。

```text
collection/global: <slug>
data sensitivity: public | authenticated | tenant | owner | admin | secret
create: <who + condition>
read: <who + condition>
update: <who + condition>
delete: <who + condition>
field-level restrictions: <secret fields hidden/access>
local API paths: <overrideAccess/user handling>
REST/GraphQL exposure: <enabled/disabled + limits>
```

以下はCritical blockerにする。

- private/tenant/owner dataで`read: () => true`、`read: true`、または条件なしpublic read
- `create/update/delete: () => true`でspam、改ざん、権限昇格が可能
- field-level secret、internal status、payment/customer id、email、token、draft/private fieldsがpublic responseに出る
- public routeからLocal APIを呼び、`overrideAccess: false`または独自認可がない
- multi-tenant collectionでtenant filterがaccess/read/queryの全経路に入っていない
- custom endpointが`req.user`、role、tenant、method、body size、rate limitを確認していない

### 6. API abuseを監査する

以下を必須確認する。

- REST: `limit`上限、pagination、select、depth、whereの自由度、sort対象index
- GraphQL: disabled or `maxComplexity`、depth、rate limit、query log、Playground本番無効
- Admin/auth: `maxLoginAttempts`、`lockTime`、email verification、bot対策、CSRF、CORS
- Preview/draft: preview secret、draft dataがpublicに出ないこと、cache分離
- Next.js cache: user-specific response、cookie response、draft response、admin/API responseを共有cacheしない
- Search/filter: unbounded regex、full text、sort without index、relationship deep sortを制限する

### 7. Uploadsと画像処理を監査する

Upload collectionごとに次を確認する。

```text
collection: <media/files/etc>
storage: local persistent | S3 | R2 | GCS | Azure | Vercel Blob | UploadThing
public read: yes/no + condition
create/update access: <who>
max file size: <bytes>
MIME allowlist: <list>
imageSizes/variants: <count and dimensions>
virus/malware scan: <yes/no>
hotlink/CDN/cache/rate limit: <yes/no>
storage ops/egress scenario: <normal/bot/abuse>
```

以下はCritical blockerにする。

- ephemeral filesystemで本番Uploadをローカル保存
- public uploadでMIME/file size/quotaがない
- user uploadをそのままpublic配信し、危険MIMEやHTML/SVG/scriptを許可
- private fileのsigned URLやpublic URLを長期・無制限に配る
- imageSizes/Sharp/Next Image/CDN transformationをbotや任意variantに開放
- upload hookが外部API、AI、search indexing、emailを無制限に呼ぶ

### 8. Jobs Queue、hooks、cronを監査する

以下を必須確認する。

- hook内で同じcollectionを更新していないか。必要なら`req.context`やidempotency keyで再帰防止する。
- `afterChange`、`afterDelete`、`afterRead`で外部API、email、AI embedding、revalidation、jobs.queueを呼ぶ場合、上限・重複排除・失敗時挙動を持つ。
- `payload.jobs.queue()`がユーザー入力やpublic endpointから無制限に呼ばれない。
- schedule/autoRun/cronが複数instanceで重複実行されない。
- retry、timeout、dead-letter相当、manual pause、purge、kill switchがある。
- jobs collectionの肥大化、retention、cleanup、indexを確認する。

### 9. DB migrationとadapterを監査する

Postgres/Mongo/SQLite adapterごとに確認する。

- migration fileがcommitされ、本番で同じpackage manager経由で実行される。
- destructive SQL/DDL/DMLはbackup、staging rehearsal、lock時間、down/forward rollbackがある。
- Postgresの`push`挙動を本番で期待しない。明示migrationで運用する。
- 新しいfilter/sort/relationship/tenant fieldにindexがある。
- versions/drafts/localization/array/block/join fieldsのstorage増加を試算する。
- DB connection pooling、serverless cold start、max connections、statement timeoutを確認する。

### 10. 課金シナリオを作る

`references/payload-cms-risk-matrix.md`を見ながら、normal / bot / bug / retry / previewの5パターンを出す。

特に以下を分ける。

- Hosting: request count、serverless duration、CPU、memory、cold starts、build minutes
- DB: compute、connection、rows read/written、IOPS、storage、backup/PITR、replica
- Object storage: storage、PUT/GET/LIST、egress、signed URL、CDN miss
- Images: imageSizes at upload、Next Image、CDN transformations、Sharp CPU
- Email/SMS: auth email、transactional email、webhook retry
- Search/AI: embeddings、indexing、LLM tokens、vector DB/search provider
- Jobs: retries、scheduled tasks、external API calls、queue backlog

### 11. Emergency stopを用意する

最低限、次を用意する。

- Upload routeをWAF/CDN/app configで止める
- GraphQL routeを止める、またはcomplexity/depthを下げる
- Jobs runner/cron/autoRunを止める
- webhook受信を止める
- image transform/Next Image/Sharp pathを止める
- public APIをread-onlyまたはmaintenanceへ切り替える
- storage bucket policy/CDN cache/rate limitを切り替える
- DBをread-only/connection limit/statement timeoutへ切り替える
- secret rotationとadmin session invalidation

## Critical blocker一覧

以下が1つでもあれば `DEPLOY: NO-GO`。

- public/private境界が不明なCollection/Global/Fieldがある
- `read/create/update/delete: () => true`がprivate/tenant/user dataに使われている
- Local APIのユーザー起点操作で`overrideAccess: false`または明示認可がない
- user-specific、draft、private、admin、cookie responseを共有cacheする可能性がある
- GraphQLが不要なのに有効、または`maxComplexity`/depth/rate limitがない
- `maxDepth`が高いままpublic APIに露出している
- UploadにMIME/file size/quota/access制限がない
- ephemeral filesystemにUploadを保存している
- hook/job/revalidation/webhookが再帰・再投入・無制限retryする
- destructive migrationにbackup/rehearsal/rollbackがない
- DB/storage/email/AI providerのquotaとkill switchがない
- `PAYLOAD_SECRET`、DB URL、storage keys、SMTP/API keysがpublic env/client/log/repoにある
- CORS/CSRF wildcardでcookie authが通る
- multi-tenant境界をaccess controlとqueryの両方で保証していない
