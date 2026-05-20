Supabase へデプロイ、migration、Edge Function、Auth/Storage/Realtime 設定、branch/add-on/replica 作成、または本番 MCP/API 操作を行う前に、必ず `supabase-deploy-guard` を使ってください。

最初は `DEPLOY: NO-GO` から始め、Supabase MCP/API で org/project/billing/add-ons/advisors/logs/tables/edge functions/branches を読み取り、ローカルで `supabase-static-risk-scan.py`、DBで `supabase-sql-audit.sql` を実行し、hard blocker が解消された場合だけ `DEPLOY: GO` に変更してください。

書き込み系操作は、差分・課金影響・セキュリティ影響・rollback・monitoring・exact command を提示し、人間の承認があるまで実行しないでください。secret の値は表示しないでください。
