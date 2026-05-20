# cloudflare-deploy-guard

Codex/Agent Skills用のCloudflareデプロイ前ガードです。

推奨配置:

```bash
mkdir -p .agents/skills
cp -R cloudflare-deploy-guard .agents/skills/
```

使い方:

1. Cloudflareにデプロイ・設定変更する前にこのスキルを呼び出す。Cloudflare Tunnel / Zero Trust / Origin firewall を触るVPS運用変更も対象にする。
2. 静的スキャンを実行する。
3. Cloudflare MCP/APIで読み取り棚卸しを行う。
4. `DEPLOY: GO` になるまで変更系MCP/APIやdeployを実行しない。

```bash
python .agents/skills/cloudflare-deploy-guard/scripts/cloudflare-static-risk-scan.py . --markdown
```

同梱ファイル:

- `references/source-links.md` — 公式Docs、価格、事故例の参照入口。
- `references/cloudflare-deploy-report-template.md` — `DEPLOY: GO / NO-GO` レポートテンプレート。
- `references/cloudflare-cost-security-checklist.md` — 詳細チェックリスト。
- `references/cloudflare-tunnel-origin-lockdown.md` — Cloudflare TunnelでVPS/originを直叩き不能にするための点検項目。
- `references/cloudflare-risk-matrix.md` — リスク表。
