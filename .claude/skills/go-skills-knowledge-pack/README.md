# GoSkills Knowledge Pack v0.1.1-strict

REV-C 向けの Go 技術体系ナレッジパックです。RustSkills / TypeScriptSkills と同じ設計思想で、Goの最新安定版・公式ドキュメント・実運用CIを前提に構成しています。

## Document roles

`go-skills-master.md` が単一の真実源です。`SKILL.md` はCodex/Claude/ChatGPT Skills用の軽量入口で、重要ルールと参照先だけを持ちます。`references/` はmasterから分野別に切り出した詳細資料、`go-skills-sources.md` は公式ソースとregistry確認先です。

## Files

```text
go-skills-knowledge-pack/
  README.md
  AGENTS.md
  SKILL.md
  go-skills-master.md
  go-skills-sources.md
  go-skills-update-prompt.md
  go-skills-pack-audit-2026-05-06.md              # historical input audit
  go-skills-pack-audit-2026-05-06-v0.1.1.md       # current versioned audit
  references/
    runtime-toolchain.md
    api-backend-rpc.md
    highload-crawler-browser.md
    data-persistence-search.md
    ai-agents-mcp.md
    tui-cli-audio.md
    crypto-security-e2ee.md
    messaging-workflows.md
    performance-memory.md
    observability-governance.md
    testing-release.md
    multiskill-interop.md
```

## Core principle

GoSkillsは「全部最新安定版を使う」を前提にします。ただしGo moduleのv0.xは、最新タグであってもsemantic import versioning上はstable扱いしません。Core / Adopt / Watch / R&D / Hold を分けて、実repoの `go.mod` と `go.sum` で検証します。

## Recommended first commands

```bash
go version
go env GOVERSION
go list -m -u -json all
go mod tidy
go mod verify
go test ./...
go test -race ./...
go vet ./...
govulncheck ./...
gosec ./...
golangci-lint run
staticcheck ./...
```

## Best next step

実際のGoプロジェクトrepoにこのPackを置いた後、`go.mod` / `go.sum` / CI / benchmark / pprof 結果を突き合わせて `v0.1.1-strict` に更新してください。


## Audit history

この節は履歴です。現在の採用判断は必ず `go-skills-master.md` の module register と `go-skills-sources.md` の公式ソース確認で行います。

- `v0.1.1-strict`: `go.uber.org/zap`、`go.uber.org/ratelimit` のmodule pathを修正。
- `v0.1.1-strict`: `github.com/klauspost/compress v1.18.6`、`github.com/qdrant/go-client v1.17.1`、`golangci-lint v2.12.1` を反映。
- `v0.1.1-strict`: Cloudflare / Supabase / Rust / TypeScript / Go co-loading用に `references/multiskill-interop.md` を追加。
