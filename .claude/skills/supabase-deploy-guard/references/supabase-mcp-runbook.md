# Supabase MCP Runbook

Supabase MCPは便利だが、プロジェクト設定・DB・SQL・ログに触れる強力な権限になり得る。AI Agentに繋ぐ場合は、最初に読み取り専用監査として使い、変更系操作は差分とロールバックを提示してからにする。

## 1. 読み取りフェーズ

Codex/Agentは最初に次を読む。

```text
Supabase MCPで対象organization/project/refを確認し、変更は行わずに次を読み取ってください。
- plan / compute size / region / spend cap / usage summary
- active projects / preview branches / read replicas / add-ons
- Security Advisor / Performance Advisor findings
- exposed schemas / RLS disabled tables / grants / functions / extensions
- Storage buckets: public/private, file size limit, MIME, policies
- Edge Functions: verify_jwt, CORS, env var names, public endpoints
- Auth: signup settings, providers, redirect URLs, captcha/MFA/password policy
- Realtime: publications, enabled tables, channels if available
- recent migrations and pending migrations
最後にDEPLOY: GO/NO-GO形式で報告してください。
```

## 2. 変更計画フェーズ

変更が必要な場合、Agentは実行前に次を出す。

```text
Change plan:
- target project/ref/env
- exact SQL/config/function files to change
- expected cost impact
- security impact
- rollback SQL/config
- emergency stop
- verification steps
```

## 3. 禁止操作

明示承認なしに実行禁止。

- productionでの`drop`、`truncate`、大量`update/delete`
- RLS無効化、policy削除、grant拡大
- secret値の読み取り・表示・ログ出力
- Edge Function deploy、env secret変更、Auth provider変更
- bucket public化、Storage policy緩和
- Realtime `FOR ALL TABLES`、publication拡大
- branch/project/replica削除、pause、restore
- Spend Cap OFF、add-on enable、compute size変更

## 4. MCP用トークン/認証の運用

- 個人の広範な権限をAIに渡しっぱなしにしない。
- staging/project限定の権限から始める。
- productionは変更系を原則禁止し、必要時だけ短時間有効化する。
- token/connectionは定期的に棚卸しする。
- Agentログにproject data、SQL結果のPII、secretを残さない。

## 5. AI Agentに与える標準プロンプト

```text
Supabaseへ変更する前に、supabase-deploy-guardを使ってDEPLOY: GO/NO-GO判定を出してください。
Supabase MCPは読み取り専用から開始し、変更系操作は差分、課金影響、セキュリティ影響、rollback、緊急停止手順を提示するまで実行しないでください。
本番データやsecret値は表示しないでください。
```
