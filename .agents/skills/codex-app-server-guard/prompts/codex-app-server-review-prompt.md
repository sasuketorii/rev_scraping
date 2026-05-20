# Codex Prompt: Codex App Server Review

```text
codex app-server関連の実装・公開・運用変更を入れる前に、必ず codex-app-server-guard を使ってレビューしてください。

前提:
- 初期判定は DEPLOY: NO-GO から開始。
- App ServerのWebSocket公開、command/exec、dynamicTools、MCP/App connector、multi-tenant、approval/sandbox変更は危険変更として扱う。
- 本番・共有環境でdanger-full-access、approval never、認証なしWebSocketを使わない。

実施してほしいこと:
1. 用途を分類する: local stdio / loopback ws / remote ws / hosted custom client / multi-tenant / CI。
2. scripts/codex-app-server-static-risk-scan.py を実行し、critical/highを整理する。
3. ~/.codex/config.toml、.codex/config.toml、requirements.toml、MCP/App config、Docker/systemd/k8s/proxy設定を確認する。
4. transport/auth、sandbox、approvals、command/exec、filesystem、network、dynamicTools、MCP/App connector、skills/plugins、logs/thread historyを審査する。
5. multi-tenantならprocess、CODEX_HOME、auth、workspace、thread、logs、approval routingの分離を証明する。
6. normal / bot / bug / reconnect / retry のusage scenarioを出す。
7. emergency stop: listener停止、proxy deny、token revoke、process kill、MCP disable、network disable、secret rotationを確認する。
8. DEPLOY: GO / NO-GO を出す。

出力形式:
- DEPLOY: GO | NO-GO
- Critical blockers
- High risks
- Usage / cost exposure
- Security exposure
- Checks performed
- Required fixes before GO
- Post-deploy monitoring plan
- Emergency stop / rollback
```
