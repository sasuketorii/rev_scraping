# Supabase MCP & SQL Audit Playbook

## MCPの初期接続例

productionではなくdevelopment/preview branchで使う。productionに接続する場合はread-onlyを原則にする。

```text
https://mcp.supabase.com/mcp?project_ref=<PROJECT_REF>&read_only=true&features=database,docs
```

作業がStorageやAccount/Billingを必要とする場合だけ、必要なfeature groupを足す。未指定で全projectにアクセスできる状態を避ける。

## MCPで最初に取る情報

- `get_project` / `list_projects`: project数、ref、region、compute、status。
- `get_cost`: 現在のcost/usageを確認。
- `get_advisors`: Security/Performance Advisorsを確認。
- `list_tables`: tables/views/RLSの概要。
- `list_extensions`: enabled extensions。
- `list_migrations`: migration履歴。
- `list_edge_functions` / `get_edge_function`: function一覧と設定。
- `get_logs`: API/Postgres/Auth/Storage/Realtime/Edge Functions logs。
- `search_docs`: 価格・上限・仕様の最新確認。

## SQL監査の読み方

同梱の `scripts/supabase-db-audit.sql` をSQL Editor、psql、またはread-only MCPで実行する。

結果のうち、以下は原則ブロッカー。

- `public` tableでRLS disabled。
- `anon`/`authenticated`への広すぎるGRANT。
- RLS policyが `true` だけで通る。
- `SECURITY DEFINER` functionに固定search_pathがない。
- `anon`/`authenticated`にSECURITY DEFINER functionのEXECUTEがある。
- storage public bucketでlisting可能なpolicyがある。
- `auth.users`、sensitive columns、foreign table、materialized viewがAPIから見える。
- Realtime publicationが広すぎる。
- pg_net/http/cron/FDW/pgmqなど外部通信・loopを生む拡張が用途不明。
