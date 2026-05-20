# Cloudflare課金・セキュリティ事前チェックリスト

## 0. 判断方針

Cloudflareは低コストで始めやすいが、従量課金の爆発は「ユーザー数」ではなく「課金メーターに触れる回数」で起きる。小規模サイトでも、画像変換URL、KV list、DO write、Queue loop、D1 scan、R2 GET/List、Worker route過大、AI crawler、外部API再試行で高額化する。

## 1. 高額化しやすい典型パターン

### 画像

- `next/image` が `/_next/image` を生成し、Cloudflare Images Transformationsを使う。
- R2画像を最適化済みなのに、OpenNext/Cloudflare adapterで再変換している。
- width/quality/dpr/fitなどが無制限で、同一画像のvariantが増殖する。
- crawlerが実ユーザーより多く画像変換URLを叩く。
- 署名付きURLやqueryが毎回違い、キャッシュ/ユニーク変換が増える。

対策: `images.unoptimized=true`、固定variant、origin allowlist、Rate Limit、AI crawler block、cache key正規化、緊急WAFブロック。

### KV

- 認証fallbackで `kv.list()`。
- legacy key migrationが全リクエストでscan。
- write/list/deleteが安い前提でログ・ack・状態を書きまくる。

対策: hash/prefix index、negative cache、migration完了後flag off、list禁止、TTL。

### Durable Objects

- 1リクエストで複数 `storage.put()`。
- ack、pending、job stateをすべて永続write。
- index更新でrows writtenが増える。

対策: batch、ephemeral state、TTL、write数計測、不要index削減。

### Queues

- consumerが同じqueueへ再投入。
- `async` や `write_mode` が内部APIへ伝播。
- retries/DLQなし。

対策: producer/consumer分離、idempotency、max retries、DLQ、pause/purge手順。

### D1

- feed/searchでJOIN/GROUP BY/scan。
- LIMITなし、N+1、indexなし。

対策: EXPLAIN、index、pagination、cache、row reads試算。

### Workers/R2

- すべてのpathをWorker routeに通す。
- 静的画像/assetをWorker経由にしてCPU/subrequests/R2 GETを増やす。
- R2のListObjectsをリクエストごとに実行。

対策: route最小化、staticはcache直配信、manifest、Cache Rules、WAF。

### Cloudflare Tunnel / Origin lockdown

- VPS/originの80/443/管理portをpublic Internetへ開けたまま、Cloudflare proxyだけに頼る。
- Origin IPがDNS履歴、メール、外部API callback、旧staging domainから漏れている。
- `cloudflared` tokenをrepo、README、shell history、systemd unit、Docker commandへ平文で残す。
- Tunnel ingressのcatch-allがdeny/404ではなく内部serviceへ流れる。
- 管理画面、SSH、DB admin、CMS adminをTunnelで公開しているのにAccessやMFAがない。
- `cloudflared` health、connector数、systemd restart loopを監視していない。

対策: Cloudflare Tunnelを使う場合はpublic inboundをdenyし、connector用outbound `7844` TCP/UDPを許可する。更新、API操作、Access JWT検証、診断が必要な場合は `api.cloudflare.com`、`update.argotunnel.com`、GitHub、`<team>.cloudflareaccess.com` などへのHTTPS egressを用途別に明示許可する。管理はTailscale/Access/限定SSHに分離、tokenはsecret管理、ingressはhostnameごとに明示してcatch-all deny/404、health/ログ/replicaを監視。

## 2. デプロイ前に必ず作るもの

1. 課金対象棚卸し表
2. 通常/10倍/Bot/Bug loopのコスト試算
3. Budget alerts + Usage notifications
4. WAF/Rate Limiting/Bot/AI crawler設定
5. Cloudflare Tunnel / origin firewall / Access / Tailscale の到達性設計
6. キルスイッチ一覧
7. ロールバック手順
8. Cloudflare MCP/API読み取り結果
9. Security diff
10. 監視メトリクスと閾値
11. 残余リスク

## 3. 最低限の監視メトリクス

- Billing: daily cost by product、budget threshold。
- Workers: requests、errors、CPU ms、subrequests、duration、status、colo、UA。
- Images: unique transformations、top image paths、error code、origin。
- R2: Class A/B operations、object count、storage、top paths。
- KV: reads、writes、list、deletes、namespace別。
- DO/D1: rows read、rows written、storage。
- Queues: operations、backlog、retries、DLQ、consumer errors。
- WAF/Bot: challenged/blocked/allowed、top UA/IP/ASN/path。
- Tunnel/Access: connector health、connector数、Access auth logs、tunnel audit logs、cloudflared restart count、origin firewall denies。

## 4. 推奨Rate Limit例

実際の閾値はアクセス規模で調整する。

- `/_next/image*`: anonymous IPごとに短時間の上限、known good bot以外はchallenge/block。
- `/cdn-cgi/image/*` または画像proxy: origin/variantごとに上限。
- `/api/search`, `/api/feed`: IP + user IDで上限。
- `/api/auth/*`: IP + account/email hashで上限。
- `/api/upload`: authenticated user + body size + Turnstile。
- webhook: 署名検証 + provider IP/UA + replay防止。
- admin: Access必須。

## 5. MCP運用

- CodexにはCloudflare Docs/Read系MCPを優先接続。
- 変更系Cloudflare MCPはtokenを分離し、stagingとproductionを分ける。
- Production変更は、Codexが差分・リスク・ロールバックを出した後だけ実行。
- MCPから取得した情報を最終レポートに残す。
- 不明なAPI/ツールの出力は、Cloudflare公式ドキュメントで照合する。
