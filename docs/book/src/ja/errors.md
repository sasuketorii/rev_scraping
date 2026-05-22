# エラー対処 (日本語サマリー)

26 個の `ErrorKind` の和訳一覧。詳細な再現コード / 修復手順は英語版の
[errors/](../en/errors/README.md) を参照してください。

| ErrorKind | 一言 |
|---|---|
| `Aup` | AUP (許容利用方針) 違反 — 対象 URL が deny-list |
| `Ssrf` | SSRF ガード作動 — private IP / loopback |
| `VpnLeak` | VPN リーク検知 — kill-switch 起動 |
| `RateLimit` | レート制限 — `retry_after_ms` 待機 |
| `Timeout` | タイムアウト |
| `Captcha` | CAPTCHA 検知 |
| `Auth` | 認証失敗 |
| `NotFound` | リソース未検出 |
| `Validation` | 入力検証エラー |
| `Network` | ネットワーク汎用エラー |
| `Internal` | 内部エラー |
| `RecipeNotFound` | レシピ未検出 |
| `RecipeInvalid` | レシピが不正 |
| `AuthSessionExpired` | 認証セッション期限切れ |
| `AuthSessionNotFound` | 認証セッション未検出 |
| `AuthSessionPending` | 認証セッション保留中 |
| `VpnNotConfigured` | VPN 未設定 |
| `VpnAllInstancesFailed` | VPN 全インスタンス失敗 |
| `VpnCountryMismatch` | VPN 国コード不一致 |
| `CdpProtocol` | CDP プロトコルエラー |
| `CdpDisconnected` | CDP 切断 |
| `CdpInjectionFailed` | CDP 注入失敗 |
| `BrowserCrashed` | ブラウザクラッシュ |
| `BrowserNotFound` | ブラウザバイナリ未検出 |
| `CookieDecryptFailed` | Cookie 復号失敗 |
| `Aborted` | キャンセル要求 |
