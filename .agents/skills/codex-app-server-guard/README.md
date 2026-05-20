# codex-app-server-guard

OpenAI Codex `app-server` を独自クライアント、remote WebSocket、MCP/apps/plugins、OpenAI API課金基盤として扱う前のセキュリティ・課金ガードです。

## Install

```bash
mkdir -p .agents/skills
cp -R codex-app-server-guard .agents/skills/
```

## Quick use

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-static-risk-scan.py . --markdown --fail-on high
```

起動コマンドだけを確認:

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-launch-guard.py 'codex app-server --listen stdio://'
```

コストシナリオ:

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-cost-estimator.py \
  --turns-per-day 100 \
  --avg-input-tokens 50000 \
  --avg-output-tokens 5000 \
  --parallel-agents 2 \
  --retry-multiplier 1.2 \
  --days 30 \
  --input-price-per-1m 1.75 \
  --output-price-per-1m 14.00
```

価格は必ず公式pricingで更新してください。

Safe configテンプレートの正本:

```text
references/codex-safe-config-template.toml
```

`scripts/codex-app-server-safe-config-template.toml` は旧参照互換のredirect stubです。
