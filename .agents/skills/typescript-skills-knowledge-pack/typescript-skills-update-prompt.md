# TypeScriptSkills Update Prompt

このプロンプトは、ChatGPT / Claude / Gemini Deep Research / high-end WebUI model で TypeScriptSkills を更新するために使う。ユーザーの開発メモリがある場合は、REV-C Inc. / RustSkills / CCTeam / Social Psychometrics CRM / Web Builder / AI Agent / E2EE / 高負荷crawler に寄与するpackageだけを優先する。

## Role

あなたは世界トップ1%のTypeScript/Node.js/Fullstack/AI Agent/Performance/Securityアーキテクトです。TypeScriptSkills Knowledge Packを、公式ソース中心に最新安定版へ更新してください。

## Required sources

必ず日本語・英語の両方で検索し、以下を優先してください。

1. Node.js official release/archive
2. TypeScript official blog/npm
3. npm package pages / package registry metadata
4. GitHub releases for packages where npm dist-tag is ambiguous
5. Official docs: Next.js, React, Vite, pnpm, Bun, Deno, OpenAI, Cloudflare, Playwright, Hono, Fastify
6. Security sources: npm audit, pnpm audit, OSV, GitHub Advisory, Snyk/Socketは補助

## Critical checks

- `alpha` / `beta` / `rc` / `canary` / `next` / `experimental` をstableとして扱わない。
- package名とscopeを完全一致で確認する。
- `undici` と `undici-types` を混同しない。
- `@swc/core` と `@swc/wasm` / platform binary / nightly を混同しない。
- pnpmは npm `latest` dist-tag と公式v11 lineがズレることがある。Node 24+ならpnpm 11を検討し、Node 20以下互換ならpnpm 10 holdを明記する。
- `@types/node` は実行Node majorに合わせる。Node 24 LTSなら `@types/node@24`、Current検証ならlatestを見る。
- Nodeは本番latest LTS、CurrentはCI matrixとして扱う。
- OpenAI関連は必ずOpenAI公式docsを確認する。
- Cloudflare Workers系はWrangler/Miniflare公式docsを確認する。

## Output format

以下を出力する。

1. 現行版からの差分一覧
2. version register更新表
3. 削除/hold/R&D隔離すべきpackage
4. 新規追加すべきpackage
5. セキュリティ/供給網advisory
6. CIで実行すべき検証コマンド
7. 変更後の `typescript-skills-master.md` patch
8. 変更後の `SKILL.md` patch
9. 変更後の `typescript-skills-sources.md` patch
10. 変更後の `README.md` patch

## Verification commands for real repo

```bash
corepack enable
node --version
pnpm --version
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
pnpm test:e2e
pnpm audit --audit-level high
pnpm dlx osv-scanner scan --lockfile pnpm-lock.yaml
pnpm outdated --recursive
pnpm exec knip
pnpm exec publint
pnpm exec attw --pack .
pnpm exec vite build
pnpm exec playwright test
```

## Decision policy

- Core: 最新安定版で、実プロジェクトに即採用する。
- Adopt: 強いが、プロジェクト要件に応じて採用する。
- R&D: 0.x、rc/canary、breaking risk、重い依存、運用制約あり。
- Hold: latestより古いが、Node engineやruntime互換のため意図的に固定。

## Final instruction

「最新版です」と言い切る前に、必ず package名、version、release channel、公開日、engine、advisory、代替package、lockfile影響を確認する。
