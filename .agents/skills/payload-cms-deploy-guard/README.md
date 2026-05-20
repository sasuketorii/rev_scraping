# payload-cms-deploy-guard

Payload CMSの本番デプロイ・schema/config変更・access control変更・Upload/Jobs/API公開前に、意図しない従量課金、データ漏洩、Local API権限バイパス、GraphQL/REST abuse、file upload abuse、DB migration事故を止めるためのAgent Skillです。

## 推奨配置

```bash
mkdir -p .agents/skills
cp -R payload-cms-deploy-guard .agents/skills/
```

公式Payload Skillsも併用します。

```bash
npx skills add payloadcms/skills
```

## Codexへの指示例

```text
Payload CMS関連の変更を本番へ入れる前に、必ず payload-cms-deploy-guard を使って DEPLOY: GO / NO-GO 判定を出して。
公式Payload Skillは実装・調査に使ってよいが、このSkillを最終ゲートにして、access control、Local API、uploads、GraphQL、jobs、migrations、cost scenarioを全部確認して。
```

## 静的スキャン

```bash
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-static-risk-scan.py . --markdown
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-static-risk-scan.py . --markdown --fail-on high
```

## Postgres監査

PayloadがPostgres adapterを使う場合、まずstaging/read-onlyで実行してください。

```bash
psql "$DATABASE_URL" -f .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-postgres-audit.sql
```

## コストシナリオ計算

```bash
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-cost-scenario-estimator.py --template > payload-cms-cost-scenario.json
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-cost-scenario-estimator.py payload-cms-cost-scenario.json --markdown
```

料金テーブルはプロバイダごとに変わるため、このスクリプトは主に「課金メーターの単位」を出します。Vercel/Neon/Supabase/S3/R2/Cloudflare/Resend/Algolia/OpenAIなどの最新料金はデプロイ前に公式Pricingで再確認してください。

## 主要ブロッカー

- private/tenant/owner dataに対する`read: () => true`
- Local APIのユーザー起点処理で`overrideAccess: false`なし
- GraphQL有効かつ`maxComplexity`/depth/rate limitなし
- UploadのMIME/file size/quota/access制限なし
- ephemeral filesystemへの本番Upload保存
- hooks/jobs/revalidation/webhookの再帰・再投入・無制限retry
- destructive migrationのbackup/rehearsal/rollbackなし
- `PAYLOAD_SECRET`、DB URL、S3/R2/SMTP/API keysのpublic env/client/log/repo露出
- CORS/CSRF wildcardでcookie auth
- object storage/image transform/email/search/AI providerのquota/kill switchなし

## MongoDB監査

PayloadがMongoDB adapterを使う場合、まずstagingまたはread-only userで実行してください。

```bash
mongosh "$MONGODB_URI" .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-mongo-audit.js
```

## ランタイム軽量プローブ

自分のstaging/productionドメインだけに使ってください。CORS、GraphQL到達性、GraphQL introspectionの軽い確認を行います。

```bash
python .agents/skills/payload-cms-deploy-guard/scripts/payload-cms-runtime-probe.py https://example.com
```
