---
name: cloudflare-deploy-guard
description: Cloudflareへデプロイ、設定変更、MCP/API変更を行う前に、意図しない従量課金・セキュリティ・Bot/Crawler・OpenNext/Next.js画像最適化・R2/KV/Durable Objects/Queues/D1/Workers・Cloudflare Tunnel/origin露出のリスクを強制的に点検する。
---

# Cloudflare Deploy Guard

このスキルは、Cloudflare公式MCP/Docs/API/Observabilityを補完する「デプロイ前ゲート」です。Cloudflareへのデプロイ、Wrangler設定変更、MCP経由の変更、課金対象プロダクト追加、Next.js/OpenNext移行、R2/Images/Workers/KV/Durable Objects/Queues/D1、Cloudflare Tunnel、Access、Zero Trust、origin firewallを触る作業では必ず実行します。

## 絶対ルール

- このスキルの点検結果が `DEPLOY: GO` になるまで、`wrangler deploy`、Pages Deploy、MCP/APIによる設定変更、Terraform apply、マイグレーション、キュー/cron有効化を実行しない。
- Cloudflare MCP/APIを使う場合、最初は読み取り専用で棚卸しする。変更系ツールは、差分・影響・ロールバック手順を提示して明示承認を得てから実行する。
- 予算アラートや使用量通知は「通知」であり、サービス停止や課金停止のハードキャップとして扱わない。コード側・WAF側・設定側のキルスイッチを必ず別に用意する。
- 不明な価格、上限、課金単位、機能仕様は、Cloudflare Docs MCPまたは公式ドキュメントで最新情報を確認する。古い記憶で判断しない。
- 「PVが少ないから大丈夫」「Cloudflareは安いから大丈夫」「R2はエグレス無料だから大丈夫」は却下する。Bot、crawler、再試行、ループ、未キャッシュ、List/Write系操作で破綻する前提で見る。

## このスキルを起動する条件

次のいずれかに該当したら必ず実行する。

- Cloudflare Workers / Pages / OpenNext / Next.js / Wrangler / Terraform / MCPでデプロイまたは設定変更をする。
- `wrangler.toml`、`wrangler.jsonc`、`next.config.*`、`open-next.config.*`、Cloudflare Terraform、GitHub Actions、CI/CD、MCP設定を変更する。
- R2、Cloudflare Images、Image Transformations、`next/image`、`/_next/image`、`/cdn-cgi/image`、画像プロキシ、キャッシュを扱う。
- Workers KV、Durable Objects、Queues、D1、Hyperdrive、Vectorize、Workers AI、AI Gateway、Browser Rendering、Stream、Logpush、Load Balancing、Argoなど課金対象または高負荷対象を扱う。
- WAF、Rate Limiting、Bot、AI Crawl Control、robots.txt、Turnstile、Access、API Token、DNS、SSL/TLS、Origin設定を扱う。
- Cloudflare Tunnel / `cloudflared` / Zero Trust route / Hetzner・VPS firewall / Tailscale subnet / origin direct access制御を扱う。

## 必須アウトプット

毎回、以下の形式で結果を出す。

```text
DEPLOY: GO | NO-GO
対象: <worker/page/zone/account/repo>
変更概要: <何を変えるか>
課金対象棚卸し: <Workers/R2/Images/KV/DO/Queues/D1/...>
最大リスク: <1〜5行>
ブロッカー: <未解決ならDEPLOY:NO-GO>
推奨対応: <優先順位順>
コスト試算: expected / 10x / bot-crawler / bug-loop
セキュリティ差分: <トークン/Secrets/WAF/Origin/DNS/認証/Tunnel/Access/firewall>
キルスイッチ: <即時停止・緩和手順>
ロールバック: <コマンドまたは手順>
監視: <確認するメトリクス・閾値・通知先>
残余リスク: <受け入れるなら明記>
```

## 手順 1: 静的スキャン

リポジトリのルートで次を実行する。結果は判断材料であり、誤検知があっても無視せず確認する。

```bash
python .agents/skills/cloudflare-deploy-guard/scripts/cloudflare-static-risk-scan.py . --markdown
```

スクリプトが配置されていない場合は、同梱の `scripts/cloudflare-static-risk-scan.py` を使う。スキャンは秘密値の中身を出力しない。`.env` や `.dev.vars` の存在のみを警告する。

## 手順 2: Cloudflare MCP/APIで読み取り棚卸し

利用可能なCloudflare MCP/Docs/API/Observabilityから、少なくとも以下を読み取る。取得できない項目は「未確認」として `DEPLOY: NO-GO` 側に倒す。

### Account/Billing

- Account ID、対象Zone、対象Worker/Pages、現在のプラン、Pay-as-you-go/Enterprise種別。
- Billable Usage、前月・当月のプロダクト別使用量、異常増加。
- Budget alerts、Usage notifications、通知先、閾値。
- 有効な有料サブスクリプションとアドオン。

### Workers/Pages

- 対象Worker、route、workers.dev公開状態、preview環境、deploy hook、Cron Triggers。
- bindings: R2、KV、D1、Durable Objects、Queues、Images、AI、Vectorize、Hyperdrive、Secrets。
- Workers metrics: requests、errors、CPU time、subrequests、duration、colo、status、user-agent上位。
- LogpushまたはWorkers Logs/Observabilityの有効化状況。

### Storage/Data

- R2 buckets: public access、r2.dev、custom domain、CORS、lifecycle、cache、object count、Class A/B operations。
- KV namespaces: reads/writes/list/delete、list利用箇所、TTL、キー設計。
- Durable Objects: storage backend、row reads/writes、indexes、storage.put/sql.execの頻度、alarms/websocket。
- Queues: producers/consumers、retry、DLQ、batch、pause/purge手順、backlog、recursionリスク。
- D1: rows read/written、インデックス、クエリ上限、pagination、migration/backup。

### Security/Traffic

- WAF custom rules、rate limiting rules、managed rules、security events。
- Bot/AI crawler設定、robots.txt、AI Crawl Control、Block AI Bots。
- Turnstile、Access、Zero Trust、Service Tokens。
- API tokens、members、2FA、audit logs。
- DNS proxy状態、SSL/TLS mode、Authenticated Origin Pulls、origin IP露出、Cache Rules。
- Cloudflare Tunnel: tunnel ID/name、connector数、`Healthy` status、公開hostname、service URL、ingress catch-all、token保管場所、`cloudflared`実行方式、outbound firewall許可、origin inbound firewall状態。

## 手順 3: 課金リスクのブロッカー

以下は未対応なら `DEPLOY: NO-GO`。

### A. 全体課金ガード

- [ ] Budget alertが設定済み。最低でも「低額早期検知」「月間許容額の50%」「80%」「100%相当」を用意。
- [ ] 高ボリュームメトリクスごとのUsage notificationを設定済み。Images transformations、Workers requests/CPU、R2 Class A/B、KV reads/writes/list、DO rows written、Queues ops、D1 rows read/writtenなど。
- [ ] 請求ダッシュボードをデプロイ後24時間以内に確認する運用がある。
- [ ] コスト試算が「通常」「10倍」「crawler/bot」「バグループ」の4パターンである。
- [ ] すべての課金対象プロダクトに、停止・縮退・迂回のキルスイッチがある。
- [ ] Cloudflareにハード課金停止を期待していない。通知・Rate Limit・WAF・コード側制限で守る。

### B. Next.js / OpenNext / Images / R2画像配信

- [ ] `next/image`、`/_next/image`、Cloudflare Images binding、`cf.image`、`/cdn-cgi/image` の有無を確認済み。
- [ ] R2や外部origin上の画像に対し、無意識にImage Transformationsが有効になっていない。
- [ ] 画像最適化を使わない方針なら `images.unoptimized = true` を明示済み。
- [ ] 画像最適化を使う方針なら、変換元originがR2 bucket等に限定され、wildcard remotePatternsを使っていない。
- [ ] `width`、`quality`、`format`、`fit`、`dpr`などの変換パラメータがユーザー入力で無制限に増えない。許可値リストだけを使う。
- [ ] `/_next/image` や画像プロキシにWAF/Rate Limiting/Bot/AI crawler対策がある。
- [ ] AI crawler、SNS crawler、OGP crawler、Meta/Googlebot/Bingbot等が画像変換URLを大量に叩く前提で試算済み。
- [ ] 署名付きURLやqueryが毎回変わる設計で、同一画像が別URL扱いになって変換/キャッシュが爆発しない。
- [ ] 画像キャッシュTTLとcache keyが明示され、レスポンスが `private`、`no-cache`、cookie、Authorizationで意図せずBYPASSしない。
- [ ] 緊急時は `/_next/image` をWAFでblock/challenge/rate-limitするか、最適化なしのURLへ迂回できる。

### C. R2

- [ ] 「エグレス無料」だけを根拠にしていない。Class A/B operationsとstorage、Infrequent Access retrieval/minimum durationを試算済み。
- [ ] public access、r2.dev、custom domain、CORS、bucket policyを確認済み。
- [ ] 画像や静的ファイルのGETがR2直撃にならず、Cloudflare cacheが効く構成である。
- [ ] ListObjects系をユーザーリクエストごとに実行していない。必要ならmanifest/indexを持つ。
- [ ] upload、delete、copy、multipart、lifecycleの権限が最小である。
- [ ] ライフサイクル、オブジェクト数、不要データ削除、ログ保管期間を定義済み。

### D. Workers / Pages

- [ ] routeが広すぎない。静的アセットや画像配信を不必要にWorker経由にしていない。
- [ ] `workers_dev`、preview URL、staging URLが公開されたまま高コスト処理へ到達しない。
- [ ] CPU time、subrequests、external fetch、retry、timeout、streamingの上限を意識している。
- [ ] 無認証API、検索、OGP、RSS、sitemap、webhook、cron、admin endpointにRate Limitがある。
- [ ] `waitUntil`、background task、cron、queue consumerが無制限に増殖しない。
- [ ] デプロイ後にtraffic split/canary/rollbackを取れる。

### E. Workers KV

- [ ] `kv.list()` を通常リクエスト、認証、fallback、middleware、cronの高頻度経路で使っていない。
- [ ] legacy fallbackやprefix scanが全リクエストで走らない。
- [ ] write/delete/listは高価な前提で、TTL、negative cache、index key、batch、local cacheを設計済み。
- [ ] キーのprefix/hash設計があり、認証・検索・一覧がscanに依存しない。
- [ ] KVを強整合が必要な用途に使っていない。

### F. Durable Objects

- [ ] `storage.put()` / SQL writesが1リクエストあたり何回発生するか計測済み。
- [ ] 複数putをbatch化し、ackや一時状態に永続writeを乱用していない。
- [ ] indexやtriggerでrow writesが増えることを試算済み。
- [ ] TTL、alarm、ephemeral memory、cacheで不要writeを減らしている。
- [ ] WebSocket/long-lived connectionが想定外にDOを起こし続けない。

### G. Queues

- [ ] producerとconsumerの責務が分離され、consumerが同じqueueへ無条件に再投入しない。
- [ ] user-facingな `async` / `write_mode` / `retry` が内部APIにそのまま伝播しない。
- [ ] idempotency key、dedupe、max retries、DLQ、batch size、backoff、poison message処理がある。
- [ ] queue backlog、consumer error、retries、DLQの監視がある。
- [ ] 緊急時に `wrangler queues pause-delivery` と `purge` の判断基準がある。

### H. D1

- [ ] 全クエリにindex/pagination/LIMITがある。フィード、検索、JOIN、GROUP BYのrows readを試算済み。
- [ ] N+1 queryやリクエストごとの全件scanがない。
- [ ] migrationは本番バックアップ/Time Travel/rollback手順付き。
- [ ] read replicaやcacheを使う場合も、row reads課金と一貫性を理解済み。

### I. その他の課金対象

- [ ] Workers AI / AI Gateway / Vectorize / Browser Rendering / Stream / Images storage & delivery / Logpush / Load Balancing / Argo / Web Analytics / Email Workers / Hyperdrive / Workflows / Containersなどが追加されていないか確認済み。
- [ ] 外部API課金、LLM API、Webhook先、DB、メール送信、検索APIなどCloudflare外の従量課金も試算済み。

## 手順 4: セキュリティブロッカー

以下は未対応なら `DEPLOY: NO-GO`。

### Account / MCP / API token

- [ ] Cloudflareアカウントは2FA、できれば複数のsecurity keyを設定済み。
- [ ] MCP/Codex用tokenは最小権限、対象account/zone限定、短寿命またはローテーション可能。
- [ ] Global API Keyを使っていない。必要権限だけのAPI tokenを使う。
- [ ] Billing、DNS、Workers Scripts、R2、KV、D1、Queues、Rulesetsなどの権限が用途ごとに分離されている。
- [ ] audit logsで直近の変更者・変更内容を確認済み。
- [ ] Codex/MCPが実行する変更はPRまたは差分レビューを通す。

### Secrets / CI

- [ ] `wrangler.toml` / `wrangler.jsonc` の `vars` にsecret、token、password、API keyを置いていない。
- [ ] Cloudflare SecretsまたはSecrets Storeを使う。
- [ ] `.env`、`.dev.vars`、service account json、private keyがgit管理外である。
- [ ] CI/CDのCloudflare tokenはdeploy専用で、production/stagingを分離。
- [ ] GitHub Actionsのpull_request from forkで本番secretが露出しない。

### Edge / App / Origin

- [ ] WAF Managed Rules、Custom Rules、Rate Limitingが有効。
- [ ] login、signup、password reset、search、upload、webhook、expensive API、image transform、adminには個別Rate Limit。
- [ ] TurnstileやAccessで人間確認/管理画面保護が必要な箇所を守っている。
- [ ] AI crawler/Botの許可・拒否方針を決め、robots.txtとAI Crawl Control/Block AI Botsを整備。
- [ ] OriginはCloudflare経由以外で直接叩けない。必要に応じてAuthenticated Origin Pulls、IP allowlist、mTLS、Accessを使う。
- [ ] VPS/origin公開が必要な場合はCloudflare Tunnelを第一候補にする。`cloudflared` がアウトバウンド接続を張り、public inbound 80/443/管理portを閉じられる構成か確認する。
- [ ] Tunnel利用時はorigin firewallで不要な全inboundを拒否し、管理アクセスはTailscale/Cloudflare Access/限定SSHだけに絞る。Cloudflare Tunnel connector用のoutbound `7844` TCP/UDPを許可し、更新/API/Access検証/診断に必要なHTTPS egressは用途別に明示許可する。
- [ ] `cloudflared` tunnel tokenはsecret扱い。repo、README、shell history、systemd unitの平文露出を避け、漏洩時はtoken rotate後に既存Tunnel接続をforce-disconnectし、全replicaを新tokenで再接続する手順を用意する。
- [ ] Public hostnameのservice URLは原則 `localhost` / private IP を向け、originアプリは可能ならloopback/private interfaceだけでlistenする。
- [ ] Tunnel ingressには明示的なhostnameごとのrouteとcatch-all deny/404を置く。意図しないsubdomainやadmin serviceを公開しない。
- [ ] `cloudflared` はsystemd等で自動起動し、`Healthy` status、connector数、ログ、再起動loopを監視する。単一connectorがSPOFならreplicaを検討する。
- [ ] SSL/TLS modeは原則Full(strict)。Flexibleは使わない。
- [ ] DNS proxy状態、origin IP漏洩、不要subdomain、old staging domainを確認。
- [ ] CORSは必要originのみ。`*` とcredentials併用などを避ける。
- [ ] Cache Rulesがcookie/Authorization/private/no-cacheで壊れていない。

## 手順 5: コスト試算テンプレート

最低限、次の表を作る。

```markdown
| Product | Meter | Free/Included | Unit price | Expected/month | 10x | Bot/Crawler | Bug loop | Mitigation |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Images Transformations | unique source+params/month | ... | ... | ... | ... | ... | ... | disable or allowlist widths + rate limit |
| R2 | Class A/B ops, GB-month | ... | ... | ... | ... | ... | ... | cache + avoid list + lifecycle |
| Workers | requests, CPU ms | ... | ... | ... | ... | ... | ... | route scope + WAF + CPU budget |
| KV | reads, writes/list/delete | ... | ... | ... | ... | ... | ... | no list in request path |
| Durable Objects | row reads/writes, storage | ... | ... | ... | ... | ... | ... | batch writes + TTL |
| Queues | operations | ... | ... | ... | ... | ... | ... | no recursion + DLQ + pause |
| D1 | rows read/written, storage | ... | ... | ... | ... | ... | ... | indexes + LIMIT |
```

## 手順 6: 緊急停止・縮退ランブック

デプロイ前に具体化する。

- Workers routeを外す、またはprevious versionへrollback。
- WAFで高コストpathをblock/challenge/rate-limitする。
- `/_next/image` / `/cdn-cgi/image` / 画像proxyを即時ブロックまたはオリジナル画像へ迂回。
- Queue consumerをpause、必要に応じてpurge。DLQへ退避。
- Cron Triggerを無効化。
- KV list fallback、legacy scan、async write、image optimizationを環境変数でoffにする。
- R2 public/custom domainを止める、CORSを絞る、cache ruleを変更。
- Tunnel route/public hostnameを削除またはAccess必須化し、`cloudflared` service停止、VPS firewallでpublic inbound denyを再確認する。
- API tokenをrevoke/rotateし、audit logsを確認。

## 手順 7: 最終判定

### `DEPLOY: GO` 条件

- ブロッカーが0。
- コスト試算、キルスイッチ、監視、ロールバックが明文化されている。
- Cloudflare公式情報で価格・上限・仕様を確認済み。
- セキュリティ変更は最小権限・差分レビュー済み。

### `DEPLOY: NO-GO` 条件

- 価格・上限・課金単位が未確認。
- Budget alert/Usage notification/監視がない。
- `next/image` + Images/R2 + crawler対策なし。
- `kv.list()` / DO writes / Queue recursion / D1 scan / Worker route過大のいずれかが未解決。
- Secrets、API tokens、WAF、Origin保護が未確認。
- Tunnel導入時にorigin firewall、token保管、Access適用、health監視、rollbackが未確認。
- ロールバックまたはキルスイッチがない。

## 同梱ファイル

- `references/source-links.md` — 公式Docs、価格、事故例の参照先。仕様・価格確認はここを入口にし、最新情報を公式Docsで再確認する。
- `references/cloudflare-deploy-report-template.md` — `DEPLOY: GO / NO-GO` 判定レポートのテンプレート。
- `references/cloudflare-cost-security-checklist.md` — 課金・セキュリティの詳細チェックリスト。
- `references/cloudflare-tunnel-origin-lockdown.md` — Cloudflare TunnelでVPS/originを直叩き不能にするための点検項目。
- `references/cloudflare-risk-matrix.md` — プロダクト別リスク表。
- `scripts/cloudflare-static-risk-scan.py` — 静的リスクスキャン。
