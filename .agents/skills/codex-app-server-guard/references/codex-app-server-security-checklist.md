# Codex App Server Security Checklist

確認時点: 2026-05-05。Codex App Serverは進化が速いため、本番前に必ずOpenAI公式ドキュメントと利用中のCLI/app-server versionで再確認する。

## 1. 用途判定

- [ ] App Serverが必要な理由を説明した
- [ ] CI/batchならCodex SDKまたは`codex exec`の方が適切でないか確認した
- [ ] local stdio / loopback ws / remote ws / hosted custom client / multi-tenantを分類した
- [ ] remote wsまたはmulti-tenantなら初期NO-GOにした

## 2. Transport/Auth

- [ ] stdioの場合、parent processだけがstdin/stdoutを保持する
- [ ] WebSocketはlocalhost/127.0.0.1またはSSH port-forwardingに限定した
- [ ] non-loopbackの場合、TLS、reverse proxy auth、IP allowlist/VPN/mTLS、rate limit、audit logを設定した
- [ ] `--ws-auth capability-token --ws-token-file /absolute/path`またはsigned bearer tokenを使う
- [ ] raw tokenをURL、CLI args、browser localStorage、logs、crash dumpに出していない
- [ ] token rotation/revoke手順がある
- [ ] `/readyz`、`/healthz`が内部情報を漏らさない
- [ ] `-32001 Server overloaded`などにexponential backoff + jitterで対応する

## 3. Sandbox / Approvals

- [ ] `sandbox_mode`はread-onlyまたはworkspace-write
- [ ] `approval_policy`はon-requestまたはuntrusted
- [ ] `approval_policy=never`はread-only非対話以外で使っていない
- [ ] `danger-full-access`、`dangerFullAccess`、`--yolo`を使っていない
- [ ] workspace-writeのnetwork accessは原則false
- [ ] networkが必要な場合、domain allowlist、approval、audit logを持つ
- [ ] `.env*`、cloud credentials、SSH keys、`~/.codex/auth.json`をpermission profileで読ませない
- [ ] requirements.tomlでallowedApprovalPolicies/allowedSandboxModes/networkを制限している
- [ ] client UIがapproval requestを正しいuser/sessionに出す
- [ ] auto approval/acceptForSessionを広すぎる範囲で使わない

## 4. command/exec

- [ ] user inputをそのままargvにしない
- [ ] shell文字列ではなくargv arrayをallowlist化する
- [ ] cwdはworkspace allowlist内に正規化する
- [ ] symlink/path traversalでworkspace外へ出ない
- [ ] timeoutMs、max output bytes、process terminateを設定する
- [ ] sandboxPolicyはserver-sideで固定またはallowlist化する
- [ ] networkAccessはserver-sideで固定し、userが有効化できない
- [ ] stdout/stderrをredactし、secretをログに保存しない

## 5. Protocol/API Surface

- [ ] `initialize.clientInfo.name`を自社integration名にしている
- [ ] `experimentalApi`は必要な時だけtrueにする
- [ ] `dynamicTools`を使う場合、schema、approval、least privilege、監査ログがある
- [ ] `skills/list`はallowed rootsだけを見る
- [ ] `skills/config/write`はadmin-onlyにする
- [ ] `fs/watch`はworkspace内pathだけ許可する
- [ ] `review/start`はtarget allowlistとtoken budgetを持つ
- [ ] MCP/App connectorはside effect/destructive actionにapprovalを必須にする

## 6. Multi-tenant

- [ ] user/orgごとにApp Server processまたは強いsession isolationがある
- [ ] user/orgごとに`CODEX_HOME`、`.codex`、auth、config、MCP configを分離している
- [ ] workspace/worktree/tmp/log/thread storageをuser/orgごとに分離している
- [ ] `thread/list/read/resume/fork/archive`でtenant境界を越えない
- [ ] approval routingがuser/session/thread/turn/itemで照合される
- [ ] reconnectやcrash後に別user threadへattachしない
- [ ] user/org quotaとkill switchがある

## 7. Logs / Data Retention

- [ ] thread historyの保存場所、暗号化、retentionを定義した
- [ ] prompts、diff、stdout/stderr、tool outputs、MCP outputs、review text、token usageをredactする
- [ ] logsはtenant境界で分離される
- [ ] support/debug exportは最小化・期限付き・監査付き
- [ ] deleted/archived threadのデータ保持ポリシーを定義した

## 8. Usage / Cost

- [ ] per-user/per-org token budgetがある
- [ ] max concurrent threads/turnsがある
- [ ] max turn durationとcancellationがある
- [ ] automatic approval reviewsの追加model callを試算した
- [ ] `review/start`の回数とdiff sizeを制限した
- [ ] reconnect/retry/backoffでloopしない
- [ ] MCP/App/dynamic toolの外部課金を試算した
- [ ] UsageLimitExceeded/429/5xxでfail-closedまたはbackoffする

## 9. Emergency Stop

- [ ] listener停止手順
- [ ] reverse proxy deny手順
- [ ] token revoke/rotate手順
- [ ] process kill/quarantine手順
- [ ] command/exec disable手順
- [ ] MCP/App connector disable手順
- [ ] network access disable手順
- [ ] secret rotation手順
- [ ] audit log保全手順
