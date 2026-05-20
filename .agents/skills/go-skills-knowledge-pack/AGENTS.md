# AGENTS.md — GoSkills Repository Instructions

このリポジトリでGoコード・GoSkills文書を編集するAIエージェントは、以下に従う。

## Language and output

- 既定の説明・レビュー・提案は日本語。
- コード、コマンド、module path、package name は原文維持。
- 外部情報を更新する場合は、日本語・英語の両方で確認し、公式ソースを優先する。

## Version policy

- Goは最新安定patchを基準にする。
- `go.mod` は曖昧な `latest` ではなく、実解決されたversionを記録する。
- v0.x module は stable ではない。採用する場合は Watch/R&D として扱い、破壊的変更を警戒する。
- `pkg.go.dev` で “Stable version unchecked” が出るmoduleは、Master上で Core に昇格させない。

## Coding policy

- `context.Context` をI/O境界の第一引数にする。
- goroutineは必ず上限・キャンセル・エラー回収を設計する。
- `http.Client` / `http.Transport` は再利用する。
- `Response.Body.Close()` を徹底する。
- ログは構造化し、秘密値を出さない。
- `panic` はCLI entrypointやテスト以外では原則禁止。

## CI policy

最低限:

```bash
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

性能系変更では追加:

```bash
go test -bench=. -benchmem ./...
go tool pprof
```

## Review policy

- セキュリティ、暗号、クローラー、ブラウザ自動化、外部API大量通信は必ず監査観点を入れる。
- 高負荷送信やクローリングは、許可済み対象・自社管理対象・正当な業務処理を前提に、rate limit、allowlist、audit log、backpressureを入れる。
- “速いから採用” ではなく、profile/benchmark/lockfile/security scan を根拠に採用する。


## Multi-skill co-loading

When CloudflareSkills, SupabaseSkills, RustSkills, TypeScriptSkills, and GoSkills are all available, follow this precedence:

1. Platform runtime rules first: Cloudflare/Supabase.
2. Security and secret-handling rules override language preference.
3. Rust owns low-level crypto/performance kernels unless explicitly reassigned.
4. TypeScript owns browser/frontend/general Cloudflare Worker glue.
5. Go owns backend APIs, durable workflows, CLIs, and service daemons.

Read `references/multiskill-interop.md` before changing cross-language boundaries.
