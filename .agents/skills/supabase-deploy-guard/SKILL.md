---
name: supabase-deploy-guard
description: Supabaseへのデプロイ、DB migration、Edge Functions、Auth/Storage/Realtime設定、Branch/Replica/Add-on、MCP/API操作の前に、意図しない従量課金・RLS/権限漏れ・secret漏洩・破壊的migration・Bot/abuse・復旧不能リスクを強制点検する。
---

# Supabase Deploy Guard

Supabase公式Agent Skills、Supabase MCP、Supabase CLI、DashboardのSecurity Advisor/Performance Advisorを補完する本番デプロイ前ゲート。Database、Auth、Storage、Edge Functions、Realtime、Branching、Read Replicas、PITR、Log Drains、MCP/AI agentによる変更では必ず使う。

## 絶対ルール

- すべて `DEPLOY: NO-GO` から始める。未確認項目が1つでもあれば `GO` にしない。
- migration、Edge Function deploy、Dashboard/SQL Editorでの本番変更、MCP変更系tool、Branch merge、Terraform applyは、課金影響・セキュリティ影響・rollback・kill switch・人間承認が揃うまで禁止。
- Supabase MCPは最初に `project_ref` で対象を固定し、可能なら `read_only=true` と最小feature groupで棚卸しする。
- Supabase公式skillが使えるなら併用する。このスキルは公式skillを置き換えず、課金・セキュリティ・本番事故のゲートとして上乗せする。
- 価格、quota、Spend Cap対象、API keyモデル、CLI flagは公式Docs、MCP `search_docs`、Dashboardの現在値で確認する。
- Spend Capは万能ではない。対象外課金、rate limit、WAF/proxy、feature flag、停止スイッチ、監視、外部費用管理を別に用意する。
- `service_role`、`sb_secret_*`、DB URL、JWT secret、OAuth/SMTP/SMS/webhook secretはfrontend、mobile、`NEXT_PUBLIC_*`、`VITE_*`、ログ、MCP出力へ絶対に出さない。
- `anon` / publishable keyの安全性はRLS、GRANT、Storage policy、Auth redirect、Rate limit、Edge側検証に依存する。
- 「PVが少ない」「個人開発」「無料枠/Spend Capがある」は安全根拠にしない。

## 起動条件

- `supabase/migrations/**`、`supabase/config.toml`、`supabase/functions/**`、DB schema、RLS policy、function、trigger、view、extension、publicationを変更する。
- Auth、OAuth、email/SMS OTP、redirect URL、JWT expiry、MFA、anonymous sign-in、custom SMTP、user metadata/app metadataを触る。
- Storage bucket、public bucket、signed URL、upload/download/list、image transformations、CDN、CORS、file size/MIME制限を触る。
- Edge Functions、webhooks、Cron、pg_cron、pg_net/http、Queues、Realtime、Vectors/pgvector、外部API/LLM/メール/SMS連携を触る。
- Branching、Preview branch、Read Replica、PITR、custom domain、Network Restrictions、SSL enforcement、Log Drains、IPv4、compute size、disk IOPS/throughputを変更する。
- Supabase MCP、CLI、PAT/OAuth、CI/CD、Terraform、AI agentにSupabase変更権限を渡す。

## 必須アウトプット

```text
DEPLOY: GO | NO-GO
対象: <org/project/ref/env/repo>
変更概要: <何を変えるか>
公式確認: <参照したSupabase Docs/Changelog/MCP/CLI/Dashboard項目>
課金対象棚卸し: <Compute/Disk/Egress/Auth MAU/Storage/Image Transform/Functions/Realtime/Branch/PITR/Log Drains/...>
最大リスク: <1〜5行>
ブロッカー: <未解決ならDEPLOY:NO-GO>
推奨対応: <優先順位順>
コスト試算: expected / 10x / bot-abuse / bug-loop / migration-failure
セキュリティ差分: <RLS/GRANT/API key/Auth/Storage/Edge/Network/MCP>
データ保護: <backup/PITR/export/rollback/restore test>
キルスイッチ: <即時停止・縮退・遮断手順>
ロールバック: <migration rollback / restore / function revert / config revert>
監視: <Usage/Upcoming Invoice/logs/advisors/DB metrics/alerts>
残余リスク: <受け入れるなら明記>
```

## 必須スキャン

```bash
python .agents/skills/supabase-deploy-guard/scripts/supabase-static-risk-scan.py . --markdown --fail-on high
```

stagingで先にDB監査を実行し、安全ならproductionで実行する。

```bash
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-db-audit.sql
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-inventory-audit.sql
```

概算コスト試算:

```bash
python .agents/skills/supabase-deploy-guard/scripts/supabase-cost-scenario-estimator.py --help
```

## Hard blockers: 課金・利用量

- Spend Cap状態、Usage、Upcoming Invoice、Plan、add-on、branch/replicaが未確認。
- Spend Cap対象外項目を有効化するのに月額最大見積もりと停止条件がない。対象外例: Compute、Branching Compute、Read Replica Compute、Custom Domain、追加Disk IOPS/Throughput、IPv4、Log Drains、MFA Phone、PITR。
- public/user-facing codeが `select('*')`、無制限list、巨大join、export、Storage download、LLM/外部APIを認証・rate limit・paginationなしで実行する。
- Edge Function、webhook、trigger、cron、queue、pg_net/httpが再帰・retry storm・外部API費用ループを起こし得る。
- public Storage、image transformations、signed URL、無制限upload/download/listにBot/crawler/egress対策がない。
- Realtimeが高write tableやsensitive tableを広くpublishし、message/peak connections見積もりと停止手順がない。
- Auth signup、anonymous sign-in、OTP、phone auth、OAuthがBotでMAU/メール/SMS/外部費用を増やし得る。
- T+1h、T+6h、T+24h、月末前のusage確認予定がない。

## Hard blockers: セキュリティ・データ保護

- `service_role`、`sb_secret_*`、DB URL、JWT secret、provider secretがfrontend、public env、client bundle、repo、ログ、MCP出力に出る可能性がある。
- exposed schema、特に`public`のtable/view/functionでRLS、GRANT、policy、security_invoker、security definer、search_path、default privilegesが未確認。
- RLS policyが `using (true)`、`with check (true)`、`for all`、広すぎる `to anon/public`、`raw_user_meta_data` / `user_metadata` 認可に依存する。
- viewがRLSを迂回し得る、または`SECURITY DEFINER` functionがexposed schemaにあり、固定`search_path`やcaller検証がない。
- Storage bucket policyがbucket_id、path、tenant/user prefix、MIME、file size、ownerを検証していない。
- Edge FunctionがpublicでJWT検証/署名検証/独自認可なし、またはservice_role使用前にcaller認可を行わない。
- webhookにprovider signature、timestamp、replay防止、idempotency、retry budgetがない。
- migrationにdrop/truncate/delete/disable RLS/large table rewrite/extension変更/trigger変更があり、backup・restore test・rollback・lock対策がない。
- Supabase MCPがproduction real dataへ書き込み可能で、project scoping、read-only、manual approvalがない。

## GO条件

- 公式docs/MCP/Dashboard/CLIで現在値を確認済み。
- static scanとSQL auditのcritical/highを解消または根拠付きで受容済み。
- RLS/GRANT/API keys/Storage policies/Edge auth/Auth redirect/Realtime publicationをテスト済み。
- expected / 10x / bot-abuse / bug-loop / migration-failure の費用シナリオがある。
- backup/restore/rollback/kill switch/monitoringがある。
- 人間の明示承認がある。

## Incident response

1. deployを凍結し、`INCIDENT: ACTIVE` と記録する。
2. 増えたmeterを特定する: Compute、Branching、Replica、Disk、Egress、Edge Functions、Realtime、Storage、Image Transformations、Auth MAU、Log Drains、Add-ons、外部API。
3. Spend Capを確認する。ただし対象外meterは別に止める。
4. changed pathを遮断する: feature flag、proxy/WAF、Edge Function、Realtime publication、public bucket、transform endpoint、auth provider、webhook、cron、branch、replica、log drain、add-on。
5. 露出したsecret/keyをrotateし、必要ならsessionを無効化する。
6. logs/advisors/usageを保存し、最小安全修正だけを出す。
7. RCAと恒久対策を作り、同じ事故が再発しないチェックをこのスキルへ反映する。

## 同梱ファイル

- `references/supabase-cost-security-checklist.md` — 詳細チェックリスト。
- `references/supabase-risk-matrix.md` — 課金・セキュリティリスク表。
- `references/supabase-mcp-playbook.md` — MCP/Agent運用手順。
- `references/source-links.md` — 公式データソースの正本。価格・仕様確認はこのファイルを入口にする。
- `references/data-sources.md` / `references/source-manifest.md` / `references/supabase-sources.md` — legacy/derived redirect。新規更新は `references/source-links.md` に集約する。
- `prompts/codex-prompt.md` — Codexへ貼る短縮プロンプト。
- `scripts/supabase-static-risk-scan.py` — 静的リスクスキャン。
- `scripts/supabase-db-audit.sql` / `scripts/supabase-inventory-audit.sql` — DB監査SQL。
- `scripts/supabase-cost-scenario-estimator.py` — 概算コスト試算。
