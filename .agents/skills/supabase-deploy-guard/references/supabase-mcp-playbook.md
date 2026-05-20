# Supabase MCP / Agent 運用プレイブック

## Read-only inventory

最初は必ず:

```text
MODE: READ-ONLY INVENTORY
DEPLOY: NO-GO
```

取得する情報:

- organization / plan / Spend Cap / usage
- projects / compute / disk / add-ons
- branches / read replicas
- migrations / tables / RLS / policies / grants / views / functions / extensions
- Security Advisor / Performance Advisor
- logs: api, postgres, auth, storage, realtime, edge-function
- Edge Functions source / JWT verify / secrets usage
- Auth providers / redirect URLs / rate limits / MFA
- Storage buckets / image transforms / Realtime publications

## Approval required

以下は人間承認なしに実行しない:

- create_project, create_branch, read replica, compute/disk/add-on changes
- disable Spend Cap
- apply_migration, execute_sql, deploy Edge Function
- Auth/Storage/Realtime settings
- secret/key rotation or display
- delete project/branch/bucket/table/function

承認フォーマット:

```text
ACTION REQUIRES APPROVAL
Operation:
Target:
Billing impact:
Spend Cap coverage:
Security impact:
Data-loss risk:
Rollback:
Monitoring:
Exact command/API call:
```

## Migration review

1. DDL/DML: create/alter/drop/truncate/delete/update/grant/revoke/policy/function/trigger/extension/publication。
2. New table RLS。
3. Policies role-scoped。
4. Views security_invoker/revoke/unexposed。
5. Functions security definer/search_path/grants。
6. Indexes and query plans。
7. Data volume and lock risk。
8. Backup/down migration。
9. RLS matrix tests。

## Edge Function review

- JWT verify or custom auth。
- service role usage。
- CORS origin。
- rate limit。
- idempotency。
- webhook signature。
- timeout/retry/circuit breaker。
- external API cost。
- logs redaction。
- recursion/self-call/cron/trigger loop。
