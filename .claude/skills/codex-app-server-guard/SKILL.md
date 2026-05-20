---
name: codex-app-server-guard
description: Use before integrating, exposing, proxying, or deploying Codex app-server or a custom rich Codex client. Produces a GO/NO-GO gate for WebSocket/auth exposure, approvals, sandbox policy, tool/app/MCP side effects, credential isolation, process storms, token/usage cost, protocol compatibility, logging, and emergency kill switches.
---

# Codex App Server Guard

このSkillは、`codex app-server`を自作アプリ、IDE拡張、Web UI、社内ツール、SRE/レビューagent、Payload/Supabase/Cloudflare連携などに組み込む前に、**意図しない課金・認証情報漏洩・任意コマンド実行・承認UI不備・sandbox破り・process storm・agent tool暴走**を止めるためのゲートです。

初期判定は常に `DEPLOY: NO-GO`。公式ドキュメントを読んだだけではGOにしない。実際のtransport、auth、approval、sandbox、workspace分離、tool権限、usage上限、logs、kill switchを確認してからだけGOにする。

## 必須出力フォーマット

必ず次の形式で返す。

```text
DEPLOY: GO | NO-GO
対象: <client/app/proxy/service/environment>
変更概要: <transport/auth/approval/sandbox/tool/client/proxy/deploy/etc>
判定理由: <1-3行>

Critical blockers:
- ...

High risks:
- ...

Cost / usage exposure:
- Meter: <model usage/thread/process/command/runtime/log/external tools/etc>
  Normal: <estimate>
  Bot/Bug scenario: <estimate>
  Guardrail: <quota/rate limit/backpressure/approval/kill switch/etc>

Security exposure:
- Transport/Auth/Credential isolation/Approval/Sandbox/Tools/MCP/Apps/Logs/Web proxy

Checks performed:
- Static scan: <script result>
- Protocol/version review: <schema/generated/types/version pin>
- Approval UI review: <command/file/network/app/MCP/dynamic tool>
- Sandbox review: <cwd/worktree/fs/network/process/env>
- Runtime/observability review: <usage/logs/alerts/dashboards>

Required fixes before GO:
1. ...

Post-deploy monitoring plan:
- First 15 min:
- First 1 h:
- First 24 h:
- Emergency stop:
```

`DEPLOY: GO`にしてよいのは、Critical blockersが0で、High risksに所有者・緩和策・監視・停止手順が付いている場合だけ。

## 必須コマンド

対象リポジトリで静的スキャンを実行する。

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-static-risk-scan.py . --markdown --fail-on high
```

ローカルstdio統合を実装している場合、`codex`が入っていればstaging/localでsmoke testする。

```bash
python .agents/skills/codex-app-server-guard/scripts/codex-app-server-smoke-test.py --mode stdio --message "Reply with OK only."
```

production credentialやproduction workspaceに対してsmoke testしない。人間が明示承認した検証環境だけで実行する。

## app-serverの位置づけ

`codex app-server`は、Codexのrich clientを支えるためのinterfaceで、conversation history、approval、streamed events、thread/turn/itemの状態管理を扱う。CIや非対話の自動ジョブなら、まずCodex SDKや一回実行型のCLIで足りるか確認する。app-serverを使うのは、approval、差分表示、streaming、会話継続、rich UIが本当に必要な場合だけ。

## 即NO-GO: Transport / exposure

- `--listen ws://0.0.0.0:*`、public IP、container network、LAN、reverse proxy、tunnelでWebSocketを出しているのに、WebSocket authがない。
- WebSocket modeをproduction依存にしているのに、experimental/unsupportedであることをリスクとして扱っていない。
- `Authorization: Bearer` tokenをCLI引数、process list、logs、frontend bundle、URL queryに出している。
- browserやremote clientからproxy/app-serverへ接続できるが、app側の認証・認可・CSRF/origin check・rate limit・tenant isolationがない。
- app-server process、thread、cwd、workspace、logs、auth state、MCP/app connector tokenがuser/tenant間で混線する。
- clientから任意の`cwd`、absolute path、symlink、親directory、host filesystem pathを指定できる。
- health check、debug endpoint、SSE/WebSocket endpointがthread ID、path、auth状態、model/plan/usage、内部errorを認証なしで返す。

## 即NO-GO: Auth / credentials

- `~/.codex/auth.json`、`CODEX_HOME`、OpenAI API key、ChatGPT OAuth state、MCP token、app connector tokenをDocker image、shared volume、artifact、logs、browser storage、repoに置いている。
- 複数end userが同じCodex auth stateを共有するのに、service account設計、quota、監査、責任分界がない。
- app-serverが不要なproduction secrets、database URL、cloud credentials、deploy token、SSH key、GitHub tokenを読める。
- `account/read`、login/logout、rate limit、plan/usage、account metadataを、本来見せるべきでないuserへ露出している。
- 認証情報のrotation、logout、revoke、credential deletion手順がない。

## 即NO-GO: Approval / side effects

- command execution、file change、network access、MCP tool call、app connector、dynamic tool、destructive operationを自動承認している。
- `acceptForSession`を広いscopeで使う、またはsession/workspace/thread/userを越えて残る。
- `approvalPolicy: "never"`または同等の自動実行設定を、`workspaceWrite`、`dangerFullAccess`、network enabled、MCP/apps enabledの状態で使う。
- approval UIがcommand、cwd、diff、target host/port/protocol、grantRoot、requested permission、tool name、arguments、side effectsを表示しない。
- approval requestとresponseが`threadId`/`turnId`/`itemId`に紐づいておらず、別threadの承認に誤適用され得る。
- userがdecline/cancelしたoperationをretry、fallback、別tool、別commandで実行し得る。
- destructive app/tool callを「readっぽい名前」やmodel判断だけで通している。

## 即NO-GO: Sandbox / command execution

- `dangerFullAccess`をproductionやuntrusted user workspaceで使っている。
- `externalSandbox`を指定しているが、本当にcontainer/VM/seccomp/AppArmor/Firecracker等の外部sandboxがある証拠がない。
- network accessがdefaultでenabled、またはhost allowlistなしで外部通信できる。
- app-server processがhost userのhome、SSH keys、cloud config、browser profile、password manager files、private repos、secretsへ読める。
- writable workspaceが本番repo checkoutや本番configと同じ場所。
- `command/exec`にtimeout、output cap、process termination、cwd allowlist、env allowlistがない。
- shell commandをuntrusted textから文字列連結で組み立てる。
- long-running commandやPTY sessionをuser/browser disconnect時に止められない。

## 即NO-GO: Tools / apps / MCP / skills

- MCP server、apps/connectors、dynamicTools、skills/config/write、externalAgentConfig/importを、user承認なしで有効化・変更できる。
- `apps._default.destructive_enabled = true`、`open_world_enabled = true`、または同等の広いconnector設定をproductionで許している。
- MCP toolsにproduction DB/cloud/payment/email/storage/deploy権限があり、agentが自由に呼べる。
- `dynamicTools`などexperimental APIをproductionで使うが、version pin、schema gate、feature flag、fallbackがない。
- tool argumentsをschema validationしない。
- tool resultにsecrets/PII/private documentsが含まれるのにredactionやaccess checkがない。
- skill import/config writeを通じて、repo外の任意skillやprompt injectionされたskillを読める。

## 即NO-GO: Process lifecycle / cost

- user requestごとに新しい`codex app-server` processを無制限にspawnする。
- thread数、turn数、parallel agents、process数、CPU/memory、runtime、token usage、command runtime、log volumeにquotaがない。
- `Server overloaded; retry later`やtransport errorに対し、jitter/backoffなしの即retry loopがある。
- failed turn、disconnect、browser refresh、network reconnectで同じ高コストtaskを重複実行する。
- `turn/steer`、`thread/resume`、auto-review、auto-fix、watch mode、CI triggerが無限ループし得る。
- `thread/tokenUsage/updated`やusage limit/errorを監視していない。

## 即NO-GO: Data handling / logs

- stdout/stderr、agent messages、tool arguments、diff、file contents、MCP results、auth headers、env varsを丸ごとproduction logsへ送っている。
- raw reasoning itemや内部推論、private tool outputをそのままend userやthird-party analyticsへ流している。
- thread transcriptsにPII/secrets/source code/customer codeを保存するのに、retention、encryption、access control、delete/export policyがない。
- approval画面やlogsにsecret値をredactしない。
- generated diffやcommand outputを別tenant/userに見せ得る。

## 確認手順

### 1. Architecture inventory

必ず次を表にする。

```text
component | runs where | user/tenant boundary | transport | auth | workspace root | credentials | tools/apps/MCP | logs | kill switch
```

対象例:

- frontend browser / desktop / IDE extension
- backend proxy / API route / SSE endpoint / WebSocket gateway
- app-server process
- workspace/container/VM
- auth store / CODEX_HOME
- MCP servers / app connectors / dynamic tools
- logs/analytics/tracing
- queue/worker if used

### 2. Transport review

- Defaultはstdioを優先する。
- WebSocketはloopback専用が基本。remote exposureは原則NO-GOから始める。
- 非loopback WebSocketには必ずcapability tokenまたはsigned bearer tokenを使う。
- tokenはfile/secret storeに置き、command line引数に生値を渡さない。
- browser-facing proxyはapp-server authとは別に、自アプリのsession/CSRF/origin/rate limitを持つ。
- SSE/WebSocketはthread/user/tenant ACLを毎接続・毎messageで確認する。

### 3. Protocol/version review

- `initialize` → `initialized` → `thread/start|resume` → `turn/start`のlifecycleを守る。
- request `id` correlationを厳密に扱う。
- `item/completed`をauthoritative stateとして扱う。deltaだけで最終状態を決めない。
- `turn/completed`の`completed/interrupted/failed`をUI/DB/queueへ反映する。
- `turn/interrupt`とprocess killの両方の停止手順を持つ。
- app-server versionをpinし、`generate-ts`または`generate-json-schema`の成果物をversion管理する。
- experimental APIはfeature flag付きで、production default off。

### 4. Approval UI review

承認UIは最低限これを表示する。

```text
threadId / turnId / itemId
operation type: command | file change | network | MCP tool | app connector | dynamic tool
requested action
cwd / affected files / diff / grantRoot
network host/protocol/port if any
tool server/name/arguments summary
risk label: read-only | writes workspace | network | destructive | credential access | production resource
available decisions
session scope if acceptForSession is offered
```

承認decisionはdefault deny。timeout時もdeny/cancel。`acceptForSession`は原則off、必要でもworkspace/thread/user/TTL限定。

### 5. Sandbox review

- Review-only / summarize-only: `readOnly`。
- Code edit in isolated worktree: `workspaceWrite` + network restricted。
- Production/devops/SRE task: separate sandbox/container with least secrets and explicit approvals。
- `dangerFullAccess`: 原則NO-GO。例外は単一開発者ローカルの明示承認のみ。
- `externalSandbox`: 外部sandboxの実体、network policy、mount、secrets、cleanupを証拠化。
- `cwd`はallowlisted workspace root配下のみ。
- envはallowlist方式。`process.env`全渡し禁止。
- command outputはcapし、secret redactionする。

### 6. Tool/app/MCP review

すべてのtoolを次の表で棚卸しする。

```text
tool/app/MCP | enabled? | default approval | destructive? | network? | production resource? | auth secret | schema validation | audit | owner
```

- destructive toolはdefault disabledまたはprompt必須。
- open-world toolはproduction default off。
- MCP serverの権限はread-onlyから開始。
- database/cloud/deploy/payment/email/storage系toolはhuman approval必須。
- tool resultはredactしてからmodel/UI/logへ渡す。
- config/write、skills/config/write、externalAgentConfig/importはadmin-onlyかつ明示承認。

### 7. Cost/usage review

最低限、normal / bot / bug / retry / reconnectを試算する。

- monthly active users
- parallel threads per user
- turns per thread
- average and p95 token usage
- model/tool retry count
- command runtime
- app-server process count
- external MCP/app tool calls
- logs/traces bytes
- storage retained per thread

必須guardrail:

- per-user and global concurrent thread limit
- per-user daily/weekly usage quota
- process TTL and idle timeout
- command timeout
- output/log cap
- exponential backoff with jitter
- duplicate turn idempotency
- usage alert and hard kill switch

### 8. Logs and retention review

- Logs should record metadata, not raw secrets/source by default.
- Redact env vars, tokens, cookies, auth headers, API keys, private URLs, DB URLs, SSH keys.
- Store transcript/code only when required.
- Retention is short by default; user/tenant deletion path exists.
- Analytics vendors do not receive sensitive code or PII unless contractually approved.
- Error reporting samples are scrubbed.

### 9. Incident / kill switch

必須の停止手順:

```text
1. Block browser/proxy route or disable feature flag.
2. Terminate app-server processes for affected user/workspace.
3. Set transport to off or loopback-only.
4. Revoke/rotate WebSocket token and app session tokens.
5. Disable MCP servers/apps/dynamic tools/destructive tools.
6. Force approvalPolicy prompt/manual and sandbox readOnly.
7. Revoke OpenAI/API/ChatGPT auth state if exposed.
8. Rotate cloud/DB/GitHub/MCP connector secrets if readable.
9. Preserve audit logs and affected thread IDs.
10. Re-run static scan and protocol smoke test before re-enable.
```

## GO条件

`DEPLOY: GO`にする前に、以下が揃っていること。

- Static scanでcriticalなし。highは全件mitigationあり。
- Transportがstdio/loopback、またはremote WebSocketに明示auth・TLS/proxy・rate limit・ACLがある。
- Credentials are isolated per user/service/workspace and not logged.
- Approval UI covers command/file/network/MCP/app/dynamic tool and default deny.
- Sandbox policy is least privilege; no untrusted `dangerFullAccess`.
- Tool/app/MCP capabilities are least privilege and audited.
- Process/thread/token/command/log quotas are enforced.
- Backpressure/retry/cancel/interrupt/cleanup are implemented.
- Schema/version is pinned and smoke-tested.
- Logs/transcripts have redaction, retention, and access control.
- Emergency kill switch is tested.

## 同梱ファイル

- `references/codex-safe-config-template.toml` — app-server/client統合レビュー用safe configテンプレートの正本。
- `scripts/codex-app-server-safe-config-template.toml` — legacy redirect stub。新規更新は `references/codex-safe-config-template.toml` に集約する。
- `references/codex-app-server-report-template.md` — run/deployレビュー用レポートテンプレート。
- `references/codex-app-server-deploy-report-template.md` — deployレビュー用レポートテンプレート。
- `references/source-links.md` — 公式Docsと参照先。
- `scripts/codex-app-server-static-risk-scan.py` — 静的リスクスキャン。
- `scripts/codex-app-server-launch-guard.py` — 起動コマンド確認。
- `scripts/codex-app-server-smoke-test.py` — stdio smoke test。
- `scripts/codex-app-server-cost-estimator.py` — usage/cost概算。
