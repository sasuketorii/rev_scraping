設計書のみ。ファイル変更なし。

**判断**
v1.2.0 ブロッカーです。理由は `spider` / `relocate` / `recipe_show` / `recipe_import` などが外部 HTML/JSON またはユーザー投入 JSON を MCP `content[].text` / `structuredContent` として LLM に返すため、prompt injection がそのまま agent runtime に入ります。  
ただし v1.2.0 で必須なのは「中央 sanitizer + canary 検出 + 16 tool 全経路適用 + regression test」まで。高度な可観測性・サイト別 tuning は v1.2.1 でよいです。

**1. 脅威モデル**
1. 外部 HTML 内の命令注入: `<div>Ignore previous instructions...</div>` が `spider` 結果として LLM に渡る。
2. JSON API payload 注入: `{"description":"You are now system..."}` のような値が `structuredContent` に残る。
3. HTML hidden/comment 注入: `display:none`, `aria-label`, `<!-- instruction -->`, `<meta content=...>` に隠す。
4. Markdown/code fence 注入: ```system / <assistant> / tool call``` 形式で agent の会話構造を模倣する。
5. MCP/tool 誘導: “call auth_login_complete”, “exfiltrate cookies”, “run shell” など tool 使用を指示する。
6. Secret 誘導と redaction bypass: cookie/token 名を含む自然文で再出力を促す。
7. Unicode/encoding 回避: zero-width, homoglyph, base64-ish, HTML entity, JSON escaped strings で canary を回避する。
8. Tool descriptor 汚染: recipe や imported endpoint notes が後続 tool description 相当の文脈に混ざる。

**2. 設計案**
新 crate: `crates/stealth-sanitize`

責務: MCP が LLM に返す全 HTML/JSON/text を「データ」として中立化し、命令文らしさを検出・記録・必要時 fail-closed する。

採用 lib:
- `serde_json`: JSON 再帰走査。
- `regex`: canary pattern。
- `ammonia`: HTML の script/style/event attr/危険 tag 除去。
- `unicode-normalization`: NFKC 正規化と zero-width 除去。
- 既存 `html5ever` 系は `scraper` 経由で足りるなら追加不要。

公開 API 案:

```rust
pub enum PayloadKind { Html, Json, Text, Unknown }

pub enum SanitizationMode {
    LlmVisibleStrict,
    StructuredDataPreserve,
    LogPreview,
}

pub struct SanitizationPolicy {
    pub max_string_bytes: usize,
    pub max_total_bytes: usize,
    pub high_risk_fail_closed: bool,
    pub preserve_json_shape: bool,
}

pub struct SanitizedPayload {
    pub value: serde_json::Value,
    pub findings: Vec<SanitizeFinding>,
    pub truncated: bool,
    pub changed: bool,
}

pub fn sanitize_mcp_result(
    tool: &str,
    result: serde_json::Value,
    policy: &SanitizationPolicy,
) -> Result<SanitizedPayload, SanitizeError>;
```

内部 L1-L5:
- L1 Normalize/Bound: UTF-8 lossless input、NFKC、zero-width/control chars 除去、field/path ごとの byte limit。
- L2 Structure Parse: HTML は `ammonia` で危険 tag/attr を落として text 化、JSON は `Value` を shape 保持で再帰。
- L3 Canary Detect: 正規表現で prompt/tool/secret/exfil 系命令を `low|medium|high|critical` に分類。
- L4 Neutralize: LLM-visible string は `[[SANITIZED_PROMPT_INJECTION:pattern_id]]` へ span 置換。JSON key は保持、値だけ置換。
- L5 MCP Egress Gate: `content[].text` と `structuredContent` の両方を最終走査。critical なら `isError:true` + redacted finding summary。raw payload は返さない。

適用点:
- Rust 側主境界: `crates/stealth-mcp/src/server.rs` の全 `JsonRpcResponse::ok(... tools/call ...)` 直前。
- 対象 16 tool: `spider`, `relocate`, `cf_evaluate`, `doctor`, `vpn_rotate`, `recipe_list`, `recipe_show`, `recipe_remove`, `recipe_propose_endpoint`, `recipe_export`, `recipe_import`, `auth_login_start`, `auth_login_complete`, `auth_list`, `auth_status`, `session_show`。
- Hermes 側二次境界: `dist/hermes/rev-scraping-mcp/schema_bridge.py` の `redact_response` 後に同等の lightweight canary を追加。ただし source of truth は Rust crate。
- CLI subprocess tool は現状 `content` に stdout text を入れているため、stdout が JSON でも text として必ず sanitizer に通す。可能なら JSON parse 成功時に `structuredContent` も生成して同じ sanitizer を適用。

**3. Canary 正規表現 15 個**
Rust `regex` 互換、case-insensitive 前提。

```text
(?i)\bignore\s+(all\s+)?(previous|prior|above)\s+instructions?\b
(?i)\bdisregard\s+(the\s+)?(system|developer|previous)\s+(message|instructions?)\b
(?i)\byou\s+are\s+now\s+(chatgpt|claude|codex|system|developer)\b
(?i)\bact\s+as\s+(a\s+)?(system|developer|admin|root)\b
(?i)\b(system|developer|assistant)\s*:\s*
(?i)<\s*/?\s*(system|developer|assistant|tool)\s*>
(?i)```[a-z0-9_-]{0,20}\s*(system|developer|assistant|tool)
(?i)\b(call|invoke|use)\s+(the\s+)?(tool|mcp|function)\b
(?i)\b(auth_login_complete|auth_login_start|session_show|recipe_export|spider|relocate)\b.*\b(call|invoke|run)\b
(?i)\b(exfiltrate|leak|dump|print|reveal|send)\s+(secrets?|cookies?|tokens?|credentials?)\b
(?i)\b(cookie|set-cookie|authorization|bearer|api[_-]?key|session[_-]?token)\b\s*[:=]
(?i)\bdo\s+not\s+(tell|mention|disclose)\s+(the\s+)?(user|operator)\b
(?i)\bhidden\s+(instruction|prompt|policy)\b
(?i)\bbase64\s+decode\b|\bdecode\s+this\s+base64\b
(?i)\bBEGIN\s+(SYSTEM|DEVELOPER|TOOL)\s+PROMPT\b
```

扱い:
- `system/developer/assistant:` は false positive があり得るので medium。
- secret/token 系は既存 redaction と連携し high。
- “ignore previous instructions” と tool invocation 誘導は high。
- secret exfil + tool 誘導が同一 payload に出たら critical。

**4. P13.x sub-phase**
P13.1 Central Sanitizer Gate
- `stealth-sanitize` 追加。
- `sanitize_mcp_result()` 実装。
- 16 tool の全 success/error envelope に適用。
- `content[].text` と `structuredContent` の差分漏れを禁止。

P13.2 Canary Corpus + Regression
- 15 regex の fixture。
- HTML hidden/comment/script/style/entity/Unicode 回避 fixture。
- JSON nested array/object fixture。
- 16 tool smoke test で raw canary が response に残らないことを確認。

P13.3 Hermes Defense-In-Depth
- Python adapter に lightweight mirror sanitizer。
- Rust sanitizer 済み marker を尊重し二重破壊しない。
- 既存 cookie redaction test を prompt-injection fixture まで拡張。

P13.4 Release Gate + Policy Tuning
- output schema と sanitizer 後 shape の整合 test。
- false positive allowlist は tool/path 単位のみ許可。
- 詳細 telemetry、site-specific policy、operator tuning は v1.2.1 に送る。

**5. v1.2.0 / v1.2.1**
v1.2.0 ブロッカー:
- 中央 sanitizer crate。
- 16 MCP tool 全経路適用。
- canary 15 件以上。
- raw injection string が LLM-visible output に残らない regression。
- critical finding の fail-closed。

v1.2.1 送り:
- 管理 UI/詳細レポート。
- サイト別 allowlist/tuning。
- ML/heuristic classifier。
- 大規模 corpus fuzzing。
- sanitizer performance benchmark の細分化。

**6. 受け入れ条件**
- `cargo test -p stealth-sanitize`
- `cargo test -p stealth-mcp`
- Hermes smoke test で canary payload が `<redacted>` または `[[SANITIZED_PROMPT_INJECTION:*]]` へ置換される。
- 16 tool の正常 schema shape が sanitizer 後も壊れない。
- raw cookie/token と raw prompt-injection canary が MCP response に残らない。

変更禁止条件に従い、今回は設計のみでファイルは変更していません。
