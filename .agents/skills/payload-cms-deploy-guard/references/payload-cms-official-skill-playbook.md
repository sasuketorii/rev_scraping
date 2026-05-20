# Payload Official Skill Playbook

Payload公式Skillは実装支援、このguardは本番前審査に使う。

## Install

```bash
npx skills add payloadcms/skills
```

## 使い分け

- `$payload`: collections、fields、hooks、access control、queries、database adapters、jobs queue、pluginsの実装・修正・デバッグ
- `payload-cms-deploy-guard`: 本番前に課金・セキュリティ・運用事故を潰す最終ゲート

## Codexでの推奨フロー

1. `$payload`でcollection/access/hook/queryを実装する
2. stagingでseed dataと権限別testを作る
3. `payload-cms-deploy-guard`でDEPLOY: NO-GOから審査する
4. critical/highを修正する
5. migration rehearsalとrollback rehearsalを行う
6. GO判定後、本番deploy後15分/1時間/24時間のmonitoringを行う

## 公式Skillに確認させる観点

```text
公式Payload Skillを使って、以下を確認して:
- Local APIでoverrideAccessが必要な経路
- Access ControlのRBAC/tenant/owner filter
- hooksの再帰とreq.contextの使い方
- GraphQL/REST queryのlimit/depth/select
- Jobs Queueのtask/workflow/schedule/autoRun
- Postgres/Mongo/SQLite adapterとmigration
```
