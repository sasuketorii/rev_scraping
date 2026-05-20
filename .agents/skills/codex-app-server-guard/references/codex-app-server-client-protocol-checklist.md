# Codex App Server Client Protocol Checklist

## Initialize

- [ ] connection直後に`initialize`を送り、`initialized`を送る
- [ ] `clientInfo.name/title/version`を正しく設定する
- [ ] `experimentalApi`は必要な接続だけに限定する
- [ ] `optOutNotificationMethods`で重要なsecurity/approval eventsを隠さない

## Threads / Turns

- [ ] threadIdはserver-sideでuser/orgに紐づける
- [ ] `thread/resume`で他userのthreadIdを指定できない
- [ ] `thread/fork`でtenant境界を越えない
- [ ] `turn/start`の`cwd`、`model`、`sandboxPolicy`をclient入力から直接渡さない
- [ ] active turnのcancellation/terminateができる
- [ ] max concurrent turnsとmax turn durationを持つ

## Events

- [ ] `turn/completed`のfailed/interruptedをUIとretry logicに反映する
- [ ] `thread/tokenUsage/updated`をbudget enforcementに使う
- [ ] `turn/diff/updated`とitem eventsをtenant別に保存する
- [ ] stdout/stderr/tool outputをredactしてから保存・表示する

## Approvals

- [ ] approval requestをthreadId/turnId/itemIdで照合する
- [ ] availableDecisionsをそのまま広く出さず、policyに合わせてUI制限する
- [ ] `acceptForSession`はsession scopeと内容を明示する
- [ ] network approvalはhost/protocolを明示して表示する
- [ ] declined/cancelledを正しくagentへ返す
- [ ] approval audit logを保存する

## command/exec

- [ ] direct public APIにしない
- [ ] argv/cwd/sandbox/network/timeoutをserver-side allowlistで生成する
- [ ] output streamにmax bytesを設定する
- [ ] PTY processはresize/write/terminate権限を制限する
- [ ] processIdをuser/sessionに紐づける

## Skills / Apps / MCP / Dynamic Tools

- [ ] `skills/list`のrootsを制限する
- [ ] `skills/config/write`はadmin-only
- [ ] app/MCP tool callのside effectをapprovalで止める
- [ ] dynamicToolsはexperimentalであることを明示し、schema/approval/least privilegeを持つ
- [ ] tool outputを未信頼データとして扱う
