## 0. Global Operating Rules

### 0.1 安全・合法性・運用前提

- 高負荷クローラー、フォーム送信、秘匿通信、AIエージェントは、**許可済み業務、同意済みデータ処理、正当な負荷試験、自社管理対象** に限定する。
- 外部サービスへ負荷をかける処理は、必ずレート制限、監査ログ、バックプレッシャー、停止スイッチ、失敗分類を持つ。
- PII、secret、token、鍵素材、音声データ、心理推定データはログへ出さない。
- 匿名性・暗号化は、プライバシー、機密性、耐障害性、検閲耐性、内部統制のために使う。

### 0.2 実装原則

- 標準レーンと限界突破レーンを分ける。まず標準レーンで堅く作り、プロファイル後に hot path だけを `hyper` / `bytes` / `simd-json` / `rkyv` / `tokio-uring` 等で焼く。
- 無制限 `spawn`、unbounded channel、requestごとの `Client` 作成、callback内alloc、lock保持中await、巨大JSON一括deserializeを禁止する。
- 速さは「雰囲気」ではなく、p50/p95/p99、RSS、allocations/op、WASM size、callback duration、handshake latency、vector search latencyで判断する。
- ライブラリ更新は、versionだけでなく、MSRV、feature、依存差分、C/FFI依存、advisory、license、benchmark差分を見る。

### 0.3 Core / Adopt / R&D の扱い

- **Core**: RustSkillsの標準基盤。デフォルトで採用する。
- **Adopt**: すぐ導入候補。設計・計測・feature確認後に標準化する。
- **Adopt/Measure**: 効果がワークロード依存。ベンチマークで勝った場合に採用する。
- **R&D**: 世界トップ1%を狙う研究候補。本番採用にはfallback、監査、長期運用性、更新追従が必要。
- **Conditional**: 条件付き採用。C/FFI依存、暗号監査、サプライチェーン要件と照合する。

---
