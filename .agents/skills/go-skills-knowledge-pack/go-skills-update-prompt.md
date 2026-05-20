# GoSkills Update Prompt v0.1.1-strict

以下を ChatGPT / Claude / Gemini Deep Research / 高性能モデルに貼り付けて、GoSkillsを更新する。

---

あなたは世界トップ1%のGoシステムアーキテクト兼パフォーマンスエンジニアです。REV-C のGo技術体系「GoSkills」を最新化してください。

## 背景

対象ドメイン:

1. 高負荷API・クローラー・フォーム送信基盤
2. ブラウザ自動化 / CDP / SPAフォーム解析
3. 自律型AIエージェント / MCP / LLM API連携
4. CRM / Social Psychometrics / データ・検索・ベクトル基盤
5. CLI / TUI / 運用ツール
6. 秘匿通信 / E2EE / セキュリティ
7. Observability / CI / supply-chain governance

既存思想:

- RustSkillsの極限性能思想: ゼロコピー、SIMD、ロックフリー、alloc削減、tail latency、監査可能性。
- TypeScriptSkillsの実用フルスタック思想: API、Agent、Web、Edge、tooling、release governance。
- GoSkillsでは Go 標準ライブラリ、goroutine、context、単一バイナリ運用を最大活用する。

## 必須調査方法

日本語と英語の両方で検索してください。一次ソースを優先してください。

優先ソース:

- go.dev official docs / release notes / security docs
- pkg.go.dev
- GitHub Releases / tags
- project official docs
- OpenAI official docs for OpenAI SDK
- Model Context Protocol official docs for MCP
- Go vulnerability database / govulncheck docs
- OSV / deps.dev when needed

## 更新対象ファイル

- `go-skills-master.md`
- `SKILL.md`
- `go-skills-sources.md`
- `go-skills-update-prompt.md`
- `README.md`
- `AGENTS.md`
- `references/*.md`
- audit report

## 厳格ルール

1. pre / beta / rc / alpha はCore採用しない。
2. v0.x module は最新タグでもstable扱いしない。Watch/R&Dで扱う。
3. 公式ソースでversion、release date、module pathを確認する。
4. `pkg.go.dev` の “Stable version” 表示を確認する。
5. security advisory / Go vulnerability database / govulncheckの影響を確認する。
6. 最新版とLTS/サポート範囲を混同しない。
7. 実repoで検証可能なコマンドを必ず提示する。

## 重点確認リスト

- Go latest stable patch
- Go release support policy
- `golang.org/x/*` module latest versions
- `chi`, `connect-go`, `grpc-go`, `huma`, `gin`, `fiber`, `fasthttp`
- `pgx`, `sqlc`, `ent`, `gorm`, `go-redis`, `qdrant/go-client`, `pgvector-go`
- `colly`, `chromedp`, `rod`, `goquery`
- `openai-go`, MCP Go SDKs, LangChain Go
- `nats.go`, Temporal SDK, Asynq, Kafka-Go
- `zap`, `zerolog`, `otel`, Prometheus, automaxprocs
- `govulncheck`, `gosec`, `golangci-lint`, `staticcheck`, `testcontainers-go`, `go-cmp`, `testify`
- `x/crypto`, CIRCL, Noise, age, TLS/mTLS updates

## 出力形式

1. 変更サマリ
2. バージョン差分表
3. 危険な取り違え・yanked・CVE・v0.x注意点
4. 更新済みMaster案
5. 更新済みSKILL案
6. 更新済みSources案
7. 監査レポート
8. 実repo検証コマンド

## 実repo検証コマンド

最低限以下を含めてください。

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
go test -bench=. -benchmem ./...
```
