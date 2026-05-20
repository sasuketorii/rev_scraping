#!/usr/bin/env python3
"""Static PayloadCMS risk scanner.

Conservative scanner for billing/security risks before PayloadCMS deploys.
It never prints secret values; it redacts evidence and reports file, line,
rule id, severity, and recommendation.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Pattern, Sequence

EXCLUDE_DIRS = {
    ".git", "node_modules", ".next", "dist", "build", "coverage", ".turbo",
    ".cache", ".venv", "venv", "__pycache__", ".pnpm-store", ".payload",
    ".agents", ".codex", ".claude", ".cursor", ".windsurf",
    "payload-cms-deploy-guard", "supabase-deploy-guard", "cloudflare-deploy-guard",
}
TEXT_EXTS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    ".py", ".go", ".rs", ".rb", ".php", ".java", ".kt", ".swift",
    ".sql", ".toml", ".json", ".jsonc", ".yaml", ".yml", ".env", ".md",
    ".sh", ".bash", ".zsh", ".dockerfile", ".txt", ".html", ".svelte", ".vue",
}
SEVERITY_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
SECRETISH = re.compile(
    r"("
    r"PAYLOAD_SECRET\s*=\s*[^\s]+|"
    r"DATABASE_URL\s*=\s*[^\s]+|MONGODB_URI\s*=\s*[^\s]+|POSTGRES_URL\s*=\s*[^\s]+|"
    r"(AWS|S3|R2|GCS|AZURE|SMTP|RESEND|SENDGRID|OPENAI|ANTHROPIC|STRIPE)[A-Z0-9_]*(KEY|SECRET|TOKEN|PASSWORD)\s*=\s*[^\s]+|"
    r"postgres(?:ql)?://[^\s'\"`]+|mongodb(?:\+srv)?://[^\s'\"`]+"
    r")",
    re.IGNORECASE,
)

@dataclass(frozen=True)
class Rule:
    id: str
    severity: str
    category: str
    pattern: Pattern[str]
    recommendation: str

@dataclass
class Finding:
    rule_id: str
    severity: str
    category: str
    path: str
    line: int
    evidence: str
    recommendation: str


def rx(p: str) -> Pattern[str]:
    return re.compile(p, re.IGNORECASE | re.MULTILINE)

RULES: Sequence[Rule] = [
    Rule("payload-secret-hardcoded", "critical", "secrets", rx(r"secret\s*:\s*['\"][^'\"]{12,}['\"]"), "Payload secret appears hardcoded. Use process.env.PAYLOAD_SECRET and rotate if exposed."),
    Rule("payload-secret-env-file", "high", "secrets", rx(r"PAYLOAD_SECRET\s*="), "PAYLOAD_SECRET reference found. Ensure this file is not committed or logged and value is environment-specific."),
    Rule("database-url-secret", "high", "secrets", rx(r"(DATABASE_URL|MONGODB_URI|POSTGRES_URL|POSTGRES_PASSWORD)\s*="), "Database credential reference found. Ensure it is server-only and not committed/public."),
    Rule("public-env-secret", "critical", "secrets", rx(r"(NEXT_PUBLIC|VITE|EXPO_PUBLIC|PUBLIC)[A-Z0-9_]*.*(PAYLOAD_SECRET|DATABASE|MONGODB|POSTGRES|SECRET|PASSWORD|PRIVATE|TOKEN|KEY)"), "Public environment variable appears to contain a secret. Move to server-only env."),
    Rule("storage-email-ai-secret", "high", "secrets", rx(r"(AWS|S3|R2|GCS|AZURE|SMTP|RESEND|SENDGRID|MAILGUN|OPENAI|ANTHROPIC|STRIPE)[A-Z0-9_]*(KEY|SECRET|TOKEN|PASSWORD)"), "Provider credential reference found. Verify least privilege, server-only use, and rotation."),
    Rule("cors-wildcard", "high", "cors-csrf", rx(r"cors\s*:\s*(true|['\"]\*['\"]|\[\s*['\"]\*['\"]\s*\])|Access-Control-Allow-Origin['\"`\s:]*\*"), "Wildcard CORS with APIs/cookies can be dangerous. Use exact production origins."),
    Rule("csrf-empty-or-wildcard", "high", "cors-csrf", rx(r"csrf\s*:\s*(false|\[\s*\]|\[\s*['\"]\*['\"]\s*\])"), "CSRF allowlist appears disabled/empty/wildcard. Confirm cookie auth cannot be abused cross-site."),
    Rule("graphql-enabled", "medium", "api-abuse", rx(r"graphQL\s*:\s*\{|/api/graphql|graphql"), "GraphQL usage found. Disable if unused or enforce maxComplexity, low maxDepth, and rate limits."),
    Rule("graphql-disabled-false", "high", "api-abuse", rx(r"graphQL\s*:\s*\{[\s\S]{0,240}disable\s*:\s*false"), "GraphQL explicitly enabled. Require maxComplexity, rate limits, and abuse tests."),
    Rule("missing-or-high-complexity-context", "medium", "api-abuse", rx(r"maxComplexity\s*:\s*(?:[1-9][0-9]{4,}|[1-9][0-9]{5,})"), "GraphQL maxComplexity appears high. Confirm it cannot exhaust DB/CPU."),
    Rule("high-depth", "high", "api-abuse", rx(r"\bdepth\s*:\s*(?:[4-9]|[1-9][0-9]+)|\bmaxDepth\s*:\s*(?:[4-9]|[1-9][0-9]+)"), "High depth/maxDepth found. Relationship population can multiply DB reads and egress."),
    Rule("unbounded-limit", "high", "api-abuse", rx(r"\blimit\s*:\s*(?:0|-1|[1-9][0-9]{3,})|pagination\s*:\s*false"), "Unbounded or very high limit/pagination disabled. Enforce bounded pagination."),
    Rule("access-public-read", "high", "access-control", rx(r"read\s*:\s*(?:true|\(\s*\)\s*=>\s*true|async\s*\(\s*\)\s*=>\s*true)"), "Public read access found. Confirm only published/public data and field-level secrets are hidden."),
    Rule("access-public-write", "critical", "access-control", rx(r"(create|update|delete)\s*:\s*(?:true|\(\s*\)\s*=>\s*true|async\s*\(\s*\)\s*=>\s*true)"), "Public create/update/delete found. Require spam/abuse controls, ownership checks, and rate limits."),
    Rule("override-access-true", "high", "local-api", rx(r"overrideAccess\s*:\s*true"), "Local API access override found. Ensure this is server-only and not user-driven."),
    Rule("override-access-false", "info", "local-api", rx(r"overrideAccess\s*:\s*false"), "Local API explicitly respects access control here."),
    Rule("payload-local-api", "medium", "local-api", rx(r"\bpayload\.(find|findByID|create|update|delete|count|login|forgotPassword|resetPassword|jobs\.queue)\s*\("), "Payload Local API call found. Review auth, user context, overrideAccess, tenant filter, limit, depth, and idempotency."),
    Rule("route-handler-local-api", "high", "local-api", rx(r"export\s+async\s+function\s+(GET|POST|PUT|PATCH|DELETE)[\s\S]{0,1200}\bpayload\.(find|create|update|delete|jobs\.queue)\s*\("), "Public/route handler uses Payload Local API. Require req.user/session, overrideAccess:false where applicable, and input validation."),
    Rule("custom-endpoints", "high", "custom-endpoints", rx(r"endpoints\s*:\s*\[|handler\s*:\s*async\s*\([^)]*req"), "Custom endpoint found. Review method/auth/role/tenant/body-size/rate-limit/CSRF/CORS."),
    Rule("upload-enabled", "medium", "uploads", rx(r"upload\s*:\s*(true|\{)"), "Upload collection/config found. Review MIME allowlist, file size, quota, storage provider, access, scanning, and egress."),
    Rule("image-sizes", "high", "uploads-images", rx(r"imageSizes\s*:\s*\[|adminThumbnail|focalPoint|resizeOptions|sharp"), "Image processing/imageSizes found. Estimate CPU/storage growth and bot upload scenario."),
    Rule("local-storage-on-ephemeral-risk", "high", "uploads-storage", rx(r"disableLocalStorage\s*:\s*false|staticDir\s*:|staticURL\s*:"), "Local file storage/staticDir found. Ensure production filesystem is persistent or use cloud storage."),
    Rule("cloud-storage-plugin", "info", "uploads-storage", rx(r"@payloadcms/(storage-s3|storage-vercel-blob|storage-gcs|storage-azure)|s3Storage|vercelBlobStorage|gcsStorage|azureStorage|uploadthing"), "Cloud storage plugin found. Review bucket policy, path ownership, signed URL TTL, ops, and egress."),
    Rule("dangerous-mime-context", "high", "uploads", rx(r"mimeTypes\s*:\s*\[[\s\S]{0,300}(svg|html|javascript|text/html|application/pdf)"), "Potentially dangerous MIME type allowed. Require sanitization/scanning and safe serving headers."),
    Rule("jobs-queue", "high", "jobs", rx(r"payload\.jobs\.queue\s*\(|jobs\s*:\s*\{|autoRun\s*:|schedule\s*:\s*\{|cron\.|payload\.jobs\.run\s*\("), "Jobs Queue/cron found. Review idempotency, retry, dedupe, pause/purge, and external API costs."),
    Rule("hook-with-side-effect", "high", "hooks", rx(r"(afterChange|afterDelete|afterRead|beforeChange)[\s\S]{0,1600}(payload\.(update|create|delete|jobs\.queue)|fetch\s*\(|revalidate(Path|Tag)|sendMail|resend|openai|embedding|algolia|meilisearch|webhook)"), "Hook side effect found. Check recursion, idempotency, burst control, retry, and external costs."),
    Rule("revalidation-storm", "high", "next-cache", rx(r"revalidate(Path|Tag)\s*\(|router\.refresh\s*\(|unstable_cache|cacheTag"), "Next.js revalidation/cache logic found. Ensure edits cannot trigger global rebuild/cache purge storms."),
    Rule("no-store-dynamic", "medium", "next-cache", rx(r"dynamic\s*=\s*['\"]force-dynamic['\"]|revalidate\s*=\s*0|unstable_noStore\s*\("), "Force-dynamic/no-store found. Estimate hosting/function duration under bot traffic."),
    Rule("auth-config", "medium", "auth", rx(r"auth\s*:\s*(true|\{)|maxLoginAttempts|lockTime|verify\s*:\s*"), "Auth collection/config found. Review login attempt limits, verification, bot protection, admin roles."),
    Rule("auth-weak-attempts", "high", "auth", rx(r"maxLoginAttempts\s*:\s*(?:0|false|[1-9][0-9]+)|lockTime\s*:\s*0"), "Login lockout appears disabled or high. Set reasonable maxLoginAttempts and lockTime."),
    Rule("draft-preview", "high", "draft-preview", rx(r"drafts\s*:\s*(true|\{)|draftMode\s*\(|preview|livePreview"), "Draft/preview/livePreview found. Ensure preview secret, private cache, and no public draft leakage."),
    Rule("destructive-sql", "critical", "migration", rx(r"\b(drop\s+table|drop\s+schema|truncate\s+table|delete\s+from\s+\S+\s*;|alter\s+table[\s\S]{0,120}drop\s+column)"), "Destructive migration detected. Require backup, staging rehearsal, lock analysis, and rollback/down."),
    Rule("payload-migrate", "medium", "migration", rx(r"payload\s+migrate|migrate:create|migrationDir|src/migrations"), "Payload migration usage found. Review production migration workflow and rollback plan."),
    Rule("postgres-push", "high", "migration", rx(r"push\s*:\s*true"), "Postgres push mode/config found. Confirm it is dev-only and not used for production schema changes."),
    Rule("multi-tenant-context", "medium", "multi-tenant", rx(r"tenant|organization|orgId|workspaceId|accountId"), "Tenant-like fields found. Verify all access controls and queries enforce tenant boundaries."),
]


def is_text_file(path: Path) -> bool:
    if path.name.startswith(".env"):
        return True
    if path.suffix.lower() in TEXT_EXTS:
        return True
    if path.name in {"Dockerfile", "docker-compose.yml", "docker-compose.yaml", "package.json", "payload.config.ts", "next.config.js", "next.config.ts"}:
        return True
    return False


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for fn in filenames:
            path = Path(dirpath) / fn
            if is_text_file(path):
                yield path


def read_text(path: Path) -> str | None:
    try:
        if path.stat().st_size > 2_000_000:
            return None
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return None


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def redact(s: str) -> str:
    s = SECRETISH.sub("<REDACTED_SECRET>", s)
    s = re.sub(r"(['\"])[^'\"]{24,}\1", r"\1<REDACTED>\1", s)
    s = re.sub(r"\s+", " ", s.strip())
    return s[:240]


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_files(root):
        text = read_text(path)
        if text is None:
            continue
        rel = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
        for rule in RULES:
            for m in rule.pattern.finditer(text):
                snippet_start = max(0, m.start() - 80)
                snippet_end = min(len(text), m.end() + 120)
                findings.append(Finding(
                    rule_id=rule.id,
                    severity=rule.severity,
                    category=rule.category,
                    path=rel,
                    line=line_number(text, m.start()),
                    evidence=redact(text[snippet_start:snippet_end]),
                    recommendation=rule.recommendation,
                ))
    return findings


def summarize(findings: list[Finding]) -> dict[str, int]:
    out = {k: 0 for k in SEVERITY_RANK}
    for f in findings:
        out[f.severity] += 1
    return out


def print_markdown(findings: list[Finding]) -> None:
    summary = summarize(findings)
    print("# PayloadCMS Static Risk Scan")
    print()
    print("| Severity | Count |")
    print("|---|---:|")
    for sev in ["critical", "high", "medium", "low", "info"]:
        print(f"| {sev} | {summary.get(sev, 0)} |")
    print()
    if not findings:
        print("No findings.")
        return
    print("| Severity | Rule | Category | Location | Evidence | Recommendation |")
    print("|---|---|---|---|---|---|")
    for f in sorted(findings, key=lambda x: (-SEVERITY_RANK[x.severity], x.path, x.line, x.rule_id)):
        ev = f.evidence.replace("|", "\\|")
        rec = f.recommendation.replace("|", "\\|")
        print(f"| {f.severity} | {f.rule_id} | {f.category} | `{f.path}:{f.line}` | `{ev}` | {rec} |")


def main() -> int:
    p = argparse.ArgumentParser(description="Scan a repository for PayloadCMS cost/security risks.")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--markdown", action="store_true", help="print markdown table")
    p.add_argument("--json", action="store_true", help="print JSON")
    p.add_argument("--fail-on", choices=list(SEVERITY_RANK), default=None, help="exit non-zero if findings at or above severity")
    args = p.parse_args()
    root = Path(args.root).resolve()
    findings = scan(root)
    if args.json:
        print(json.dumps([asdict(f) for f in findings], ensure_ascii=False, indent=2))
    else:
        print_markdown(findings)
    if args.fail_on:
        threshold = SEVERITY_RANK[args.fail_on]
        if any(SEVERITY_RANK[f.severity] >= threshold for f in findings):
            return 2
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
