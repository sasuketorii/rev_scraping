# P13 — Prompt Injection Defense (synthesis of Plan A + Plan B)

Status: GO (user approved synthesis)
Owner: Lane F (P13.1 → P13.5 sequential)
Coder: Opus 4.7-high / Reviewer: Codex gpt-5.5 reviewer

## 判断
- **v1.2.0 ブロッカー** (Codex Plan B 採用): noop での GA は untrusted-content 16 tool surface に対し無責任
- **scope は Plan A 寄りに絞る**: L1 ammonia / L6 URL filter / 多言語 / Hermes mirror は v1.2.1 へ後送 (false-positive 制御のため telemetry 蓄積)

## v1.2.0 で入れる layer
| Layer | 内容 | mode |
|-------|------|------|
| L2 | envelope wrap `<<<UNTRUSTED_CONTENT origin=... sanitize_id=NONCE>>>...<<<END_UNTRUSTED_CONTENT sanitize_id=NONCE>>>` | always |
| L3 | canary 20 個 / Critical/High/Suspicious 3 tier | Warn default + critical のみ fail-closed |
| L4 | unicode strip: zero-width (U+200B-D/2060/FEFF), tag chars (U+E0000-E007F), bidi override (U+202D/E + U+2066-9) | always |
| L5 | length clamp: per-field 256 KiB / total 512 KiB / head-tail keep | always |
| L7 | `_meta.sanitize` field on all 16 output schemas | always |

## v1.2.1 後送 (P14)
- L1 ammonia full (hidden text / JSON-LD relocate / SVG drop)
- L6 URL filter (scheme allowlist)
- 多言語 canary (JP/ZH/KR/RU)
- Hermes Python mirror sanitizer
- Enforce mode default flip
- site-specific policy

## P13.x slice 分割 (各 ≤ 1.0d、3-4 dev-days 合計)
| Slice | scope | deps |
|-------|-------|------|
| P13.1 | `stealth-sanitize` crate skeleton / `SanitizePolicy{Off,Warn,Enforce}` / `SanitizedEnvelope` / per-tool policy table / 公開 API | - |
| P13.2 | L4 unicode strip + L5 length clamp (low-risk layers, false-positive ゼロ目標) | P13.1 |
| P13.3 | L2 envelope wrap (nonce forgery defense) + L3 canary 20 個 / 3 tier / Warn + critical fail-closed | P13.2 |
| P13.4 | 中央 wiring in `stealth-mcp::server` + per-tool policy table + 16 output schema に `_meta.sanitize` 追加 | P13.3 |
| P13.5 | golden corpus (20+ malicious / 20+ benign FP) + 16 tool regression test + idempotence prop test | P13.4 |

## canary 20 個 (Plan A 由来 + Plan B 補強)
重大度:
- **Critical** (Enforce で必ず置換, fail-closed トリガー): #6, #9, #10, #11, #12, #19
- **High** (Enforce で置換): #1, #2, #3, #4, #5, #16, #17, #18
- **Suspicious** (telemetry のみ): #7, #8, #13, #14, #15, #20

```
1.  (?i)\bignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompts?|directions?)\b
2.  (?i)\bdisregard\s+(the\s+)?(system|previous|above|developer)\b
3.  (?i)\bforget\s+(everything|all)\s+(previous|above)\b
4.  (?i)\byou\s+are\s+now\s+(an?\s+)?(different|new|chatgpt|claude|codex)\b
5.  (?i)\bnew\s+(system\s+)?(instructions?|prompt|role)\b
6.  \bSYSTEM\s*[:>]                                          # case-sensitive
7.  \bASSISTANT\s*[:>]
8.  \bUSER\s*[:>]
9.  <\|im_start\|>|<\|im_end\|>|<\|endoftext\|>|<\|system\|>|<\|user\|>|<\|assistant\|>
10. \[INST\]|\[/INST\]|<<SYS>>|<</SYS>>
11. (?i)###\s+(instruction|response|system)[:\s]
12. <\|fim_(prefix|middle|suffix)\|>
13. (?i)tool_call\s*:\s*\{|function_call\s*:\s*\{
14. (?i)(execute|run|invoke)\s+(the\s+)?(following|this)\s+(command|tool|function)
15. base64[,:]\s*[A-Za-z0-9+/]{40,}
16. (?i)curl\s+[^\s]+\s+(--data|-d|-X\s+POST)
17. (?i)\bcookie\s*[:=].{0,50}\b(send|post|fetch)\b                    # proximity
18. data:text/html
19. <{3,}\s*(END_)?UNTRUSTED_CONTENT                                    # envelope forgery
20. (?i)\b(you\s+are\s+claude|you\s+are\s+chatgpt|as\s+an\s+ai\s+language\s+model)\b
```

## 公開 API (確定)
```rust
pub enum Mode { Off, Warn, Enforce }
pub struct SanitizePolicy { mode: Mode, limits: LimitPolicy, canary: CanaryPolicy, unicode: UnicodePolicy }
pub struct SanitizedEnvelope { payload: serde_json::Value, report: SanitizationReport }
pub struct SanitizationReport {
    schema_version: u32, policy_name: &'static str, mode: Mode,
    bytes_in: usize, bytes_out: usize, truncated: bool, aborted: bool,
    layers_applied: Vec<&'static str>,
    canary_hits: Vec<CanaryHit>,           // NEVER includes matched_bytes
    sanitize_id: String,                    // 64-bit hex nonce
}
pub fn sanitize_for_agent(payload: serde_json::Value, policy: &SanitizePolicy) -> SanitizedEnvelope;
pub fn sanitize_error_envelope(env: ErrorEnvelope, policy: &SanitizePolicy) -> ErrorEnvelope;
```

## 中央 wiring 場所
`crates/stealth-mcp/src/server.rs` の `dispatch_tool()` → `JsonRpcResponse::ok(...)` 直前。
`policy_for_tool(name: &str) -> SanitizePolicy` 30 行の match。

## test 目標
- detection rate ≥ 95% (Critical), ≥ 90% (High)
- false positive ≤ 1 Suspicious / benign fixture, 0 Critical/High
- idempotence: `sanitize(sanitize(x)) == sanitize(x)`
- p95 latency &lt; 12 ms (no L1 で軽量)
- workspace 680 → ~700 PASS 予定

## 受入条件
1. `cargo test -p stealth-sanitize` 全 PASS
2. `cargo test --workspace --no-fail-fast` 695+ PASS / 0 fail
3. clippy `-D warnings` clean
4. raw injection string が LLM-visible MCP response に残らない (golden corpus 20 件で確認)
5. critical canary hit で `_meta.sanitize.aborted = true` + payload 空 (Enforce path)
6. 既存 16 tool の output schema 互換 (`_meta.sanitize` 追加のみ)
7. Codex reviewer LGTM × 5 slice

## evidence
- prompts: `.agent/active/prompts/p13_{1..5}_review[_round{2,3}].md`
- reviews: `.agent/active/reviews/p13_*.out`
- METRIC: 各 round で `REV_HARNESS_DELEGATION_METRIC` 行
