Codex app-serverを起動、組み込み、公開、WebSocket化、独自クライアント接続、MCP/apps/plugins連携、OpenAI API-backed agent基盤として運用する前に、必ず `codex-app-server-guard` を使って `RUN/DEPLOY: GO / NO-GO` を出してください。

最初はNO-GOから始め、以下を確認してください。

1. `python .agents/skills/codex-app-server-guard/scripts/codex-app-server-static-risk-scan.py . --markdown --fail-on high` を実行する。
2. 起動コマンド、listen transport、WebSocket auth、TLS/proxy、sandbox、approval policy、network access、OpenAI project limits、MCP/apps/plugins、logging/retentionを棚卸しする。
3. remote WebSocket、danger sandbox、approval never、token露出、thread/shellCommand、MCP destructive tools、plugin marketplace変更、network allowlist拡張は、人間承認なしに進めない。
4. Project budgetはソフト通知である前提で、per-user quota、model allowlist、rate limits、kill switchを要求する。
5. 結果は `RUN/DEPLOY: GO | NO-GO`、Blockers、Required fixes、Cost blast-radius、Sandbox/approval risk、Kill switch付きで出す。
