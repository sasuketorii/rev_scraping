# supabase-deploy-guard

Supabase向けのCodex/Agent Skillです。公式Supabase Agent Skills/MCPに加えて、意図しない従量課金、RLS/API key漏洩、Storage/Auth/Realtime/Edge Functions、破壊的migration、MCP/AI agent運用リスクをデプロイ前に強制点検します。

## 推奨配置

```bash
mkdir -p .agents/skills
cp -R supabase-deploy-guard .agents/skills/
```

公式Supabase skillも併用します。

```bash
npx skills add supabase/agent-skills --skill supabase
npx skills add supabase/agent-skills --skill supabase-postgres-best-practices
```

## 使い方

Supabaseにデプロイ・設定変更する前にこのスキルを呼び出し、`DEPLOY: GO`になるまで変更しません。

```bash
python .agents/skills/supabase-deploy-guard/scripts/supabase-static-risk-scan.py . --markdown --fail-on high
```

DB監査はstagingで先に実行します。

```bash
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-db-audit.sql
psql "$SUPABASE_DB_URL" -f .agents/skills/supabase-deploy-guard/scripts/supabase-inventory-audit.sql
```

概算コスト試算の例です。

```bash
python .agents/skills/supabase-deploy-guard/scripts/supabase-cost-scenario-estimator.py \
  --compute-size micro --projects 1 --branches 1 \
  --edge-invocations 5000000 --realtime-messages 20000000 \
  --egress-uncached-gb 500 --image-origin-images 5000
```

## MCP推奨方針

本番は原則接続しません。読む必要がある場合は、project scoped + read-only + feature最小化で接続します。

```text
https://mcp.supabase.com/mcp?project_ref=<PROJECT_REF>&read_only=true&features=database,debugging,development,docs
```

Storage設定を読む必要があるときだけStorage feature groupを追加します。変更系toolは差分、課金影響、セキュリティ影響、rollback、人間承認が揃うまで実行しません。

## 重要な考え方

- Spend Capは万能ではありません。Compute、Branching Compute、Read Replica Compute、Custom Domain、追加Disk IOPS/Throughput、IPv4、Log Drains、MFA Phone、PITRは別管理します。
- `service_role`や`sb_secret_*`は絶対にfrontendへ出しません。
- RLSは「有効」だけでは不十分です。GRANT、policy内容、function権限、Storage RLS、Realtime publication、Auth redirectを合わせて見ます。
- 小規模サービスでも、Bot、OTP abuse、Storage egress、Realtime loop、Edge Function recursion、画像変換、migration事故で高額化・漏洩します。
