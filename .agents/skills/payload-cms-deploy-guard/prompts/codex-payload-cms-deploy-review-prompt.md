# Codex Prompt: PayloadCMS Deploy Review

```text
Payload CMS関連の変更を本番へ入れる前に、必ず payload-cms-deploy-guard を使ってレビューしてください。

前提:
- 公式Payload Skillは実装・設計・ドキュメント確認に使ってよい。
- このSkillは最終ゲートとして使う。
- 初期判定は DEPLOY: NO-GO から開始。
- 本番DB、storage、email、search、AI provider、hosting設定への変更は自動実行しない。

実施してほしいこと:
1. payload.config.ts、collections、globals、fields、hooks、custom endpoints、REST/GraphQL、Local API、Uploads、Jobs Queue、migrations、Next.js routesを棚卸しする。
2. scripts/payload-cms-static-risk-scan.py を実行し、critical/highを整理する。
3. Access Control表を作る。特に public read、tenant/owner境界、field-level secret、Local API overrideAccessを確認する。
4. Uploads、imageSizes、storage、CDN/cache、hotlink、MIME/file size/quotaを確認する。
5. GraphQL/RESTのdepth、limit、select、complexity、rate limitを確認する。
6. hooks/jobs/webhooks/revalidation/search/AI/emailの再帰・retry・idempotency・kill switchを確認する。
7. migrationのbackup、staging rehearsal、lock、rollback/down、indexを確認する。
8. normal / bot / bug / retry / preview の課金シナリオを出す。
9. DEPLOY: GO / NO-GO を出す。

出力形式:
- DEPLOY: GO | NO-GO
- Critical blockers
- High risks
- Cost exposure
- Security exposure
- Checks performed
- Required fixes before GO
- Post-deploy monitoring plan
- Emergency stop / rollback
```
