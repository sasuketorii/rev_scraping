# Cloudflare Tunnel / Origin Lockdown

Cloudflare Tunnelは、VPSやorigin serverをpublic Internetへ直接公開しないための第一候補にする。`cloudflared` がorigin側からCloudflareへアウトバウンド接続を張り、public hostnameへのtrafficをTunnel経由でoriginへ届ける。

公式Docs上の重要前提:

- `cloudflared` はCloudflareへoutbound-only connectionを作る。
- public application用途では、hostnameをlocal serviceへmapできる。
- firewallでTunnel connector用のoutbound `7844` TCP/UDPを許可する必要がある。更新、API操作、Access JWT検証、診断が必要な場合は関連するHTTPS egressも用途別に許可する。
- `cloudflared` はLinux system serviceとして運用できる。
- Tunnelはorigin公開面を減らすが、Access、WAF、Rate Limiting、token管理、origin firewallの代替ではない。

## GO条件

- [ ] Originのpublic inbound 80/443/admin portを閉じる。例外は明文化し、Cloudflare IP allowlistだけに頼らない。
- [ ] 管理アクセスはTailscale、Cloudflare Access、限定SSH、break-glass手順に分ける。
- [ ] Tunnel routeは公開hostnameごとに明示する。catch-allは `http_status:404` などdeny側に倒す。
- [ ] Service URLは原則 `http://localhost:<port>`、`https://localhost:<port>`、またはprivate IPにする。
- [ ] Origin appは可能ならloopback/private interfaceだけでlistenする。
- [ ] `cloudflared` tokenはsecretとして扱い、repo、docs、logs、shell history、Docker command、world-readable systemd unitへ残さない。
- [ ] Token漏洩時はrotateだけで終わらせない。既存connectorは再起動まで旧token由来の接続が残り得るため、token rotate後にTunnel connectionsをforce-disconnectし、全replicaを新tokenで再install/restartする。
- [ ] Dockerで `cloudflare/cloudflared ... --token <token>` のように起動する場合も、tokenはenv/secret manager等で渡し、compose fileやrunbookへ平文保存しない。
- [ ] `cloudflared` はsystemd等で自動起動し、再起動loop、connector health、connector数、ログを監視する。
- [ ] 単一VPSがSPOFになるサービスはreplica、fallback、maintenance page、DNS/route rollbackを用意する。
- [ ] Public admin、CMS、DB UI、metrics、debug endpointはTunnel公開だけではGOにしない。Access/MFA/IP posture/rate limitを必須にする。
- [ ] 緊急時にpublic hostname route削除、Access必須化、`cloudflared`停止、origin firewall denyを実行できる。

## NO-GO条件

- Origin IPへ直接アクセスできる状態で「Cloudflare配下だから安全」と判断している。
- Tunnel tokenが平文でcommitされている、または漏洩時のrotate手順がない。
- Tunnel ingressのcatch-allが内部serviceへ流れる。
- Admin/CMS/SSH/RDP/DB UIをAccessなしで公開している。
- `cloudflared` のhealth監視がなく、落ちたときの検知・復旧・切り戻しがない。
- Firewall変更後に、Cloudflare経由、Tailscale/管理経路、外部直叩き失敗の3点を実測していない。

## Verification

```text
Cloudflare path:
  curl -I https://<hostname>

Direct public origin path:
  curl -I http://<origin-ip>
  curl -I https://<origin-ip>
  expected: timeout / rejected / 403 by firewall

Management path:
  tailscale status
  ssh <server-private-or-tailnet-ip>

cloudflared:
  systemctl status cloudflared
  journalctl -u cloudflared --since "1 hour ago"
```

## Notes for agents

- Tunnel導入を提案するときは、Cloudflare dashboard/API設定だけで終わらせない。VPS firewall、origin listen address、admin path、token storage、monitoring、rollbackまで同じ変更単位で扱う。
- Cloudflare Tunnelはoriginへのinboundを閉じるための手段であり、アプリケーション認可、WAF、Bot対策、cost guardの代替ではない。
