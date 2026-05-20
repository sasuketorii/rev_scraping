# Supabase SQL Audit Queries

読み取り専用のDB監査クエリは `scripts/supabase-db-audit.sql` と `scripts/supabase-inventory-audit.sql` に同梱しています。

実行例:

```bash
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-db-audit.sql
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-inventory-audit.sql
```

結果に含まれる次の項目は、原則として本番デプロイのブロッカーです。

- exposed schemaのRLS disabled table
- `anon` / `authenticated` への広すぎるGRANT
- `using (true)` / `with check (true)` / `for all` policy
- `SECURITY DEFINER` functionの固定`search_path`なし
- `anon` / `authenticated`が実行可能なprivileged function
- public Storage bucketと広すぎる`storage.objects` policy
- Realtime publicationの広すぎる対象
- unindexed FK、巨大table、locking migrationの可能性
