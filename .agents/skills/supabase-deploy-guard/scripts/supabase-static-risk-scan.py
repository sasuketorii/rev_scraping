#!/usr/bin/env python3
"""Static risk scan for Supabase deployments.

This script intentionally does not print secret values. It reports file paths,
line numbers, and pattern names only. It is a pre-deploy aid, not a substitute
for Supabase MCP/CLI inspection, Security Advisor, Performance Advisor, billing
review, or RLS tests with anon/authenticated roles.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable

EXCLUDE_DIRS = {
    ".git", "node_modules", ".next", "dist", "build", "coverage", ".turbo",
    ".cache", ".venv", "venv", "__pycache__", ".pnpm-store", ".supabase",
    ".agents", ".codex", ".claude", ".cursor", ".windsurf",
    "agent-skills", "skills", "supabase-deploy-guard", "cloudflare-deploy-guard",
    "supabase/.branches",
    ".agents", ".agent",
}
TEXT_EXTS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    ".sql", ".toml", ".json", ".jsonc", ".yaml", ".yml", ".md", ".txt",
    ".env", ".example", ".sh", ".bash", ".py", ".rb", ".go", ".rs",
    ".dart", ".swift", ".kt", ".java", ".php",
}
MAX_FILE_BYTES = 1_500_000

@dataclass
class Rule:
    id: str
    severity: str
    title: str
    regex: str
    recommendation: str
    flags: int = re.IGNORECASE | re.MULTILINE

@dataclass
class Finding:
    id: str
    severity: str
    title: str
    path: str
    line: int
    recommendation: str
    excerpt: str

RULES: list[Rule] = [
    Rule("SB-SEC-001", "critical", "service_role/secret key reference", r"SUPABASE_(SERVICE_ROLE_KEY|SECRET_KEY|SECRET_KEYS)|sb_secret_[A-Za-z0-9_\-]+|[\'\"]service[_-]?role[\'\"]", "service_role/secret keyはブラウザ・モバイル・NEXT_PUBLIC・公開ログに出さない。Edge/backendのsecretとしてのみ使い、露出時は即ローテーションする。"),
    Rule("SB-SEC-002", "critical", "Supabase secret marked public", r"(NEXT_PUBLIC|VITE|PUBLIC|EXPO_PUBLIC|NUXT_PUBLIC|REACT_APP|GATSBY|SVELTE_PUBLIC)_[A-Z0-9_]*(SUPABASE|SERVICE_ROLE|SECRET|JWT|DB|DATABASE|TOKEN|PASSWORD)[A-Z0-9_]*", "公開prefix付き環境変数はクライアントへ出る前提。service_role、secret、JWT secret、DB URLを絶対に置かない。"),
    Rule("SB-SEC-003", "high", "Direct Postgres connection string", r"postgres(ql)?://[^\s'\"]+|SUPABASE_DB_URL|DATABASE_URL", "直接DB接続文字列はsecret扱い。CI/サーバー限定、Network Restrictions/SSL/pooler/ロール分離を確認する。値は出力しない。"),
    Rule("SB-SEC-004", "high", "createClient may use server secret", r"createClient\s*\([\s\S]{0,500}(SERVICE_ROLE|SECRET_KEY|SECRET_KEYS|process\.env\.[A-Z0-9_]*(SECRET|SERVICE|DB|DATABASE))", "Supabase clientをどこで初期化しているか確認。frontend bundleやSSRで秘密鍵が混入していないかビルド成果物も確認する。"),

    Rule("SB-MCP-001", "high", "Supabase MCP not project scoped", r"mcp\.supabase\.com/mcp(?![^\s'\"]*project_ref=)", "Supabase MCPは project_ref=<対象> を指定し、全projectアクセスを避ける。"),
    Rule("SB-MCP-002", "high", "Supabase MCP not read-only", r"mcp\.supabase\.com/mcp(?![^\s'\"]*read_only=true)", "調査用MCPは read_only=true から開始。変更系はGO判定後に分離する。"),
    Rule("SB-MCP-003", "critical", "Literal MCP bearer token", r"Authorization[\s\S]{0,80}Bearer\s+(?!\$\{)[A-Za-z0-9_.\-]{16,}", "MCP/PAT/OAuth tokenを設定ファイルへ直書きしない。secret manager/env参照にし、漏洩時はrotateする。"),

    Rule("SB-RLS-001", "critical", "RLS disabled explicitly", r"alter\s+table\s+(if\s+exists\s+)?[^;]+\s+disable\s+row\s+level\s+security", "公開/露出schemaのRLS disableは禁止。例外が必要ならprivate schemaに移し、Data APIから到達不能にする。"),
    Rule("SB-RLS-002", "high", "create table in public schema", r"create\s+table\s+(if\s+not\s+exists\s+)?(public\.)?[a-zA-Z_][\w$]*(\s|\()", "public schemaの新規テーブルは同一migrationまたは直後のmigrationでRLS有効化・GRANT最小化・policy作成・RLSテストを行う。"),
    Rule("SB-RLS-003", "critical", "Permissive RLS policy always true", r"create\s+policy[\s\S]{0,600}(using|with\s+check)\s*\(\s*true\s*\)", "USING/WITH CHECK trueは原則禁止。公開read-onlyなどの明確な例外以外は所有者/tenant/role条件へ置き換える。"),
    Rule("SB-RLS-004", "high", "Policy to public/anon broad access", r"create\s+policy[\s\S]{0,500}\bto\s+(public|anon)\b", "anon/public向けpolicyは公開データかを再確認。select/insert/update/deleteを分け、WITH CHECKを必ず確認する。"),
    Rule("SB-RLS-005", "high", "Broad grants to anon/authenticated", r"grant\s+(all|insert|update|delete|truncate|references|trigger|execute|usage|select)\b[\s\S]{0,400}\bto\s+(anon|authenticated|public)\b", "Data API到達可否はGRANTとRLSの両方で決まる。anon/authenticatedへのGRANTは必要最小限にし、RLSとテストを確認する。"),
    Rule("SB-RLS-006", "high", "User-editable metadata used for authz", r"raw_user_meta_data|user_metadata|auth\.jwt\s*\(\s*\)\s*(->|#>)\s*['\"](user_metadata|raw_user_meta_data)", "user_metadata/raw_user_meta_dataはユーザー編集可能な値を含み得るため認可判断に使わない。app_metadata/raw_app_meta_dataやDB上の権限表を使う。"),

    Rule("SB-FUNC-001", "critical", "SECURITY DEFINER function/view", r"security\s+definer", "SECURITY DEFINERはprivate schemaに置き、search_pathを固定し、anon/authenticatedへのEXECUTEを最小化する。viewsはsecurity_invokerを検討。"),
    Rule("SB-FUNC-002", "high", "Function without search_path hardening", r"create\s+(or\s+replace\s+)?function[\s\S]{0,1600}\$\$[\s\S]{0,1600}\$\$\s*(language|;)", "関数はSECURITY DEFINERでなくてもsearch_path、権限、SQL injection、EXECUTE grantsを確認。SECURITY DEFINERなら必ずsearch_path固定。"),
    Rule("SB-FUNC-003", "high", "Potential network-capable extension/function", r"\b(http_get|http_post|http_request|net\.http|pg_net|pg_http|wrappers|postgres_fdw|dblink|cron\.schedule|pg_cron)\b", "DB内から外部HTTP/FDW/Cronを呼ぶ機能はSSRF・外部課金・ループのリスク。private schema、EXECUTE権限、頻度、timeoutを確認する。"),
    Rule("SB-FUNC-004", "medium", "View creation", r"create\s+(or\s+replace\s+)?(materialized\s+)?view\b", "viewはRLSを期待通り通すか確認。Postgres 15+なら WITH (security_invoker = true) を検討し、anon/authenticated grantsを確認する。"),

    Rule("SB-STO-001", "high", "Public storage bucket or public URL", r"public\s*[:=]\s*true|insert\s+into\s+storage\.buckets[\s\S]{0,300}true|getPublicUrl\s*\(|/storage/v1/object/public/", "public bucket/public URLはhotlinking・crawler・egress増の前提で扱う。RLS、CDN/cache、ファイル種別、WAF/rate limit、非公開化手順を確認する。"),
    Rule("SB-STO-002", "high", "Storage signed URL", r"createSignedUrl\s*\(|createSignedUrls\s*\(|createSignedUploadUrl\s*\(", "signed URLのTTL、権限、再利用、ログ露出、path ownershipを確認。長すぎるTTLや一覧可能なパスを避ける。"),
    Rule("SB-STO-003", "high", "Storage image transformation", r"/render/image/|transform\s*:\s*\{|width\s*:\s*[^,}\n]+|height\s*:\s*[^,}\n]+|resize\s*:\s*['\"]", "Storage Image Transformationsのorigin image課金、変換対象、サイズ/quality allowlist、crawler対策、事前サムネ生成案を確認する。"),
    Rule("SB-STO-004", "medium", "Storage list/download/upload path", r"\.storage\.from\s*\([^\)]*\)\.(list|download|upload|update|remove|move|copy)\s*\(", "Storage操作はRLS、path設計、ページネーション、ファイルサイズ/MIME制限、egress/storage増、rate limitを確認する。"),

    Rule("SB-FN-001", "high", "Public Edge Function JWT verification disabled", r"verify_jwt\s*=\s*false|jwt_verify\s*=\s*false|--no-verify-jwt|--no-jwt-verify", "verify_jwt=falseの関数はwebhook等の明確な理由、署名検証、rate limit、bot対策、ログ/secret redactionが必須。"),
    Rule("SB-FN-002", "medium", "Edge Function handler", r"Deno\.serve\s*\(|serve\s*\(\s*async\s*\(", "Edge Functionは短時間・冪等・timeout・CORS・JWT/署名検証・DB接続・外部API課金・invocation数を確認する。"),
    Rule("SB-FN-003", "high", "Webhook or signature-related endpoint", r"webhook|stripe\.webhooks|constructEvent|x-signature|svix|verifySignature|x-hub-signature|X-Signature", "webhookは署名検証・replay防止・idempotency・rate limit・DLQ/再試行方針を確認する。"),
    Rule("SB-FN-004", "medium", "CORS wildcard", r"Access-Control-Allow-Origin['\"]?\s*[:,=]\s*['\"]\*|allowedOrigins?\s*[:=]\s*\[[^\]]*['\"]\*['\"]|corsHeaders[\s\S]{0,200}['\"]\*['\"]", "CORSは必要originだけに限定。credentialsやAuthorizationヘッダと組み合わせる場合は特に確認する。"),
    Rule("SB-FN-005", "medium", "External API/LLM call from function/server", r"fetch\s*\(\s*['\"]https?://|openai|anthropic|stripe|sendgrid|resend|twilio|slack|discord|github\.com", "外部API/LLM/メール/SMS/webhook先の従量課金・timeout・retry・idempotency・budgetをSupabase外コストとして試算する。"),

    Rule("SB-AUTH-001", "high", "Anonymous sign-ins enabled", r"enable_anonymous_sign_ins\s*=\s*true|anonymous_sign_ins\s*=\s*true|signInAnonymously\s*\(", "anonymous usersはMAU・abuse・データ所有権・昇格/マージを確認。Botでユーザー作成されないようCAPTCHA/rate limitを検討する。"),
    Rule("SB-AUTH-002", "high", "Wildcard or broad redirect URL", r"additional_redirect_urls[\s\S]{0,400}(\*|localhost|127\.0\.0\.1)|redirectTo\s*:\s*[^,}\n]+", "Auth redirect URLは本番ドメインに限定。preview/localhost/wildcard/ユーザー入力redirectのopen redirectを確認する。"),
    Rule("SB-AUTH-003", "medium", "OTP/Magic link/password reset", r"signInWithOtp|resetPasswordForEmail|verifyOtp|otp|magic\s+link", "Authメール/SMS乱用、custom SMTP、redirect allowlist、rate limit、user enumeration、MFA要否を確認する。"),


    Rule("SB-DB-001", "medium", "Supabase select star", r"\.select\s*\(\s*['\"]\*['\"]\s*\)", "select('*')はegress増・不要列露出・RLS性能劣化の温床。必要列だけ選び、limit/range/cursor paginationを入れる。"),
    Rule("SB-DB-002", "high", "Potential broad update/delete", r"\.from\s*\([^\)]*\)\s*\.\s*(update|delete)\s*\(", "update/deleteは同一chainにeq/match/filter等があるか確認。RLSに頼り切らず、where条件・影響件数・rollbackを明示する。"),
    Rule("SB-DB-003", "medium", "RPC call", r"\.rpc\s*\(", "RPC/function呼び出しはEXECUTE grant、SECURITY DEFINER、search_path、RLS、rate limit、戻り値egressを確認する。"),
    Rule("SB-RT-001", "high", "Realtime/Postgres changes subscription", r"postgres_changes|supabase_realtime|\.channel\s*\(|realtime\.channel|alter\s+publication\s+supabase_realtime", "Realtimeはpeak connections/messages/egress、publication対象、RLS、不要subscribe、presence/broadcast乱用を試算・テストする。"),

    Rule("SB-MIG-001", "critical", "Destructive migration", r"drop\s+(table|schema|column|type|function|policy|extension)|truncate\s+table|delete\s+from\s+[a-zA-Z_][\w.]*\s*;|alter\s+table[\s\S]{0,200}drop\s+column", "破壊的migrationはbackup/restore確認、影響行数、lock_timeout、down/rollback、maintenance window、staging検証が必須。"),
    Rule("SB-MIG-002", "high", "Large table rewrite risk", r"alter\s+table[\s\S]{0,400}(add\s+column[\s\S]{0,120}default\s+[^;]+not\s+null|alter\s+column[\s\S]{0,120}type|set\s+not\s+null|create\s+index\s+(?!concurrently))", "大規模テーブルでlock/rewriteの可能性。CONCURRENTLY、分割migration、lock_timeout、statement_timeout、EXPLAINを確認する。"),
    Rule("SB-MIG-003", "medium", "Supabase db reset", r"supabase\s+db\s+reset|db\s+reset", "db resetは本番で絶対禁止。対象環境を確認し、CI/ローカル限定にする。"),
    Rule("SB-MIG-004", "medium", "Migration push/apply command", r"supabase\s+db\s+push|apply_migration|supabase\s+migration\s+up|supabase\s+functions\s+deploy", "本番変更前にbranch/staging、advisors、db lint、pgTAP/RLS tests、backup/rollback、差分レビューを必須にする。"),
]

SECRET_FILE_NAMES = {
    ".env", ".env.local", ".env.production", ".env.development", ".env.test",
    "supabase/.env", ".envrc", "credentials.json", "service-account.json",
}

SEVERITY_ORDER = {"info": 0, "medium": 1, "high": 2, "critical": 3}


def should_skip_dir(root: Path, dirpath: Path, dirname: str) -> bool:
    rel = (dirpath / dirname).relative_to(root).as_posix()
    base = dirname.lower()
    rel_l = rel.lower()
    if base in EXCLUDE_DIRS or rel_l in EXCLUDE_DIRS:
        return True
    # Skills directories contain this scanner and reference material.  They are
    # intentionally excluded so installing the skill into a repository does not
    # make the scanner report its own examples and guardrails.
    if rel_l.startswith((".agents/skills", ".codex/skills", "agent-skills/")):
        return True
    return False


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath_s, dirnames, filenames in os.walk(root):
        dirpath = Path(dirpath_s)
        dirnames[:] = [d for d in dirnames if not should_skip_dir(root, dirpath, d)]
        for name in filenames:
            path = dirpath / name
            rel = str(path.relative_to(root).as_posix())
            if path.name in SECRET_FILE_NAMES or rel in SECRET_FILE_NAMES or path.suffix.lower() in TEXT_EXTS:
                yield path


def safe_excerpt(line: str) -> str:
    if re.search(r"service[_-]?role|secret|token|password|database_url|db_url|postgres(ql)?://|sb_secret|jwt", line, re.I):
        line = re.sub(r"([:=]\s*)(['\"]?)[^'\"\s,}]+", r"\1<redacted>", line)
        line = re.sub(r"postgres(ql)?://[^\s'\"]+", "postgres://<redacted>", line, flags=re.I)
        line = re.sub(r"sb_secret_[A-Za-z0-9_\-]+", "sb_secret_<redacted>", line, flags=re.I)
    return line.strip()[:220]


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_files(root):
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
            rel = str(path.relative_to(root).as_posix())
            if path.name in SECRET_FILE_NAMES or rel in SECRET_FILE_NAMES:
                findings.append(Finding("SB-SEC-000", "high", "Secret/env file present", rel, 1, ".env/credential filesがgit管理外であることを確認する。中身は表示しない。", "<file exists>"))
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        lines = text.splitlines()
        for rule in RULES:
            regex = re.compile(rule.regex, rule.flags)
            for match in regex.finditer(text):
                line_no = text.count("\n", 0, match.start()) + 1
                line = lines[line_no - 1] if 0 <= line_no - 1 < len(lines) else ""
                findings.append(Finding(rule.id, rule.severity, rule.title, rel, line_no, rule.recommendation, safe_excerpt(line)))
    return findings


def print_markdown(findings: list[Finding]) -> None:
    counts: dict[str, int] = {"critical": 0, "high": 0, "medium": 0, "info": 0}
    for f in findings:
        counts[f.severity] = counts.get(f.severity, 0) + 1
    print("# Supabase static risk scan")
    print()
    print(f"Findings: critical={counts.get('critical', 0)}, high={counts.get('high', 0)}, medium={counts.get('medium', 0)}, info={counts.get('info', 0)}")
    print()
    if not findings:
        print("No static findings. Continue with Supabase MCP/CLI/Dashboard billing, advisors, and RLS checks.")
        return
    print("| Severity | Rule | File:line | Finding | Recommendation | Excerpt |")
    print("|---|---|---|---|---|---|")
    for f in sorted(findings, key=lambda x: (-SEVERITY_ORDER.get(x.severity, 0), x.id, x.path, x.line)):
        excerpt = f.excerpt.replace("|", "\\|")
        rec = f.recommendation.replace("|", "\\|")
        print(f"| {f.severity} | {f.id} | `{f.path}:{f.line}` | {f.title} | {rec} | `{excerpt}` |")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan a repo for Supabase cost/security risk patterns.")
    parser.add_argument("root", nargs="?", default=".", help="Repository root")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    parser.add_argument("--markdown", action="store_true", help="Emit Markdown, default")
    parser.add_argument("--fail-on", choices=["info", "medium", "high", "critical"], help="Exit non-zero if this severity or higher is present")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    findings = scan(root)

    if args.json:
        print(json.dumps([asdict(f) for f in findings], ensure_ascii=False, indent=2))
    else:
        print_markdown(findings)

    if args.fail_on:
        threshold = SEVERITY_ORDER[args.fail_on]
        if any(SEVERITY_ORDER.get(f.severity, 0) >= threshold for f in findings):
            return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
