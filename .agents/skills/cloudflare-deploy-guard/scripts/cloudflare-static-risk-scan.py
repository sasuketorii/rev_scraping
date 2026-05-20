#!/usr/bin/env python3
"""Static risk scan for Cloudflare deployments.

This script intentionally does not print secret values. It reports file paths,
line numbers, and pattern names only. It is a pre-deploy aid, not a substitute
for Cloudflare MCP/API inspection or billing review.
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
    ".git", "node_modules", ".next", ".open-next", ".wrangler", "dist", "build",
    "coverage", ".turbo", ".cache", ".venv", "venv", "__pycache__", ".pnpm-store",
}
TEXT_EXTS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    ".toml", ".json", ".jsonc", ".yaml", ".yml", ".md", ".txt", ".tf",
    ".sh", ".bash", ".env", ".vars", ".service", ".socket", ".timer", ".conf",
}
TEXT_FILE_NAMES = {
    ".envrc", ".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile", ".zshenv",
}
TEXT_FILE_PREFIXES = ("dockerfile", "containerfile")
MAX_FILE_BYTES = 1_000_000

@dataclass
class Rule:
    id: str
    severity: str
    title: str
    regex: str
    recommendation: str
    flags: int = re.IGNORECASE

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
    Rule("CF-IMG-001", "high", "next/image import", r"from\s+['\"]next/image['\"]|require\(['\"]next/image['\"]\)", "R2/Cloudflare Images利用時は images.unoptimized=true か custom loader + variant/origin allowlist + rate limit を確認する。"),
    Rule("CF-IMG-002", "high", "Next image optimizer endpoint", r"/_next/image", "このpathはcrawler対策とRate Limitを必須にする。"),
    Rule("CF-IMG-003", "high", "Cloudflare Images binding or transform", r"\bimages\s*[:=]\s*\{|binding\s*=\s*['\"]?IMAGES|cf\s*:\s*\{[^\n]*image|/cdn-cgi/image", "Cloudflare Images pricing、ユニーク変換、origin allowlist、width/quality allowlistを確認する。"),
    Rule("CF-IMG-004", "medium", "Wildcard image remote origin", r"remotePatterns[\s\S]{0,300}(hostname\s*:\s*['\"]\*\*?['\"]|protocol\s*:\s*['\"]\*['\"])|domains\s*:\s*\[[^\]]*['\"]\*['\"]", "remotePatterns/domainsのwildcardを避け、R2/custom domainなど必要originだけに限定する。"),
    Rule("CF-IMG-005", "info", "Image optimization disabled", r"unoptimized\s*:\s*true", "画像最適化を意図的に無効化している可能性。R2配信・LCP・OGPの設計と整合するか確認する。"),

    Rule("CF-R2-001", "medium", "R2 binding or API usage", r"r2_buckets|R2Bucket|\.get\s*\([^\n]*\)|\.put\s*\([^\n]*\)", "R2 Class A/B operations、cache、ListObjects回避、public/CORS/lifecycleを確認する。"),
    Rule("CF-R2-002", "high", "Possible public R2 exposure", r"r2\.dev|public_access|custom_domain|cors|allowed_origins", "R2のpublic access、r2.dev、custom domain、CORSをCloudflare側で確認する。"),

    Rule("CF-WORKER-001", "medium", "Broad Worker route", r"routes?\s*=\s*\[[\s\S]{0,300}\*|route\s*=\s*['\"][^'\"]*\*", "Worker routeを最小化し、静的asset/画像を不必要にWorker経由にしない。"),
    Rule("CF-WORKER-002", "medium", "workers.dev enabled", r"workers_dev\s*=\s*true|workers_dev\s*:\s*true", "workers.dev/preview URLから高コスト処理へ到達できないか確認する。"),
    Rule("CF-WORKER-003", "medium", "Cron trigger", r"cron_triggers|triggers\s*[:=][\s\S]{0,200}crons", "Cronの頻度、失敗時再試行、外部API/DB/queueへの負荷を試算する。"),
    Rule("CF-WORKER-004", "high", "Unbounded loop", r"while\s*\(\s*true\s*\)|for\s*\(\s*;\s*;\s*\)", "無限loopはqueue/CPU/外部API課金を爆発させる。明示的な上限、break、timeoutを入れる。"),
    Rule("CF-WORKER-005", "medium", "waitUntil/background work", r"waitUntil\s*\(", "background処理の増殖、例外、retry、queue投入の有無を確認する。"),

    Rule("CF-KV-001", "critical", "KV list usage", r"\b\w+\.list\s*\(", "hot pathでのKV listは禁止。prefix/hash index、manifest、migration flag、cacheに置き換える。"),
    Rule("CF-KV-002", "high", "Possible KV write/delete usage", r"\b\w+\.(put|delete)\s*\(", "KV write/delete/listは高頻度経路で使わない。TTL・batch・cache・冪等性を確認する。"),

    Rule("CF-DO-001", "high", "Durable Object storage write", r"storage\.put\s*\(|ctx\.storage\.put\s*\(|state\.storage\.put\s*\(", "1リクエストあたりのDO write数を計測し、batch化・TTL・ephemeral stateを検討する。"),
    Rule("CF-DO-002", "medium", "Durable Object SQL/index", r"sql\.exec\s*\(|CREATE\s+INDEX|ALTER\s+TABLE", "rows read/written、index更新、migration/rollbackを確認する。"),

    Rule("CF-QUEUE-001", "high", "Queue send usage", r"\.sendBatch\s*\(|\.send\s*\(", "consumerが同じqueueへ再投入していないか、idempotency/DLQ/max_retriesを確認する。"),
    Rule("CF-QUEUE-002", "critical", "write_mode propagation", r"write_mode|writeMode", "user-facingなasync/write_modeを内部APIやqueue consumerに伝播させない。"),
    Rule("CF-QUEUE-003", "medium", "Queue retry/DLQ config", r"max_retries|dead_letter_queue|retry\s*\(", "max retries、DLQ、poison message処理、pause/purge手順を確認する。"),

    Rule("CF-D1-001", "medium", "D1 database binding or SQL", r"d1_databases|prepare\s*\(|SELECT\s+.+\s+FROM", "D1 rows read/written、LIMIT、index、pagination、EXPLAINを確認する。"),

    Rule("CF-SEC-001", "critical", "Secret-looking key in config/source", r"(api[_-]?key|secret|token|password)\s*[:=]", "秘密値はwrangler varsやsourceに置かず、Cloudflare Secrets/Secrets Store/CI secretsを使う。値は出力しない。"),
    Rule("CF-SEC-002", "high", "Cloudflare credential variable", r"CLOUDFLARE_API_KEY|CF_API_KEY|CLOUDFLARE_API_TOKEN|CF_API_TOKEN", "Global API Keyではなく最小権限API tokenを使い、CI/MCP/staging/prodで分離する。"),
    Rule("CF-SEC-003", "medium", "CORS wildcard", r"Access-Control-Allow-Origin['\"]?\s*[:,=]\s*['\"]\*|allowedOrigins?\s*[:=]\s*\[[^\]]*['\"]\*['\"]", "CORSは必要originだけに限定し、credentialsとの組み合わせを確認する。"),

    Rule("CF-TUNNEL-001", "critical", "Cloudflare Tunnel token inline", r"(?:cloudflared|cloudflare/cloudflared(?::[\w.\-]+)?)\b[^\n]*(?:service\s+install\s+[\"\']?(?!<|\$)[A-Za-z0-9._\-]{20,}[\"\']?|--token(?!-file)(?:\s+|=)\s*[\"\']?(?!<|\$)[A-Za-z0-9._\-]{20,}[\"\']?)|command\s*:\s*(?:\[[^\n\]]*|[^\n]*)\btunnel\b[^\n]*--token(?!-file)[\"'\s,:=]+[\"']?(?!<|\$)[A-Za-z0-9._\-]{20,}|TUNNEL_TOKEN\s*[:=]\s*[\"\']?(?!<|\$)[A-Za-z0-9._\-]{20,}[\"\']?", "Tunnel tokenはsecret扱い。repo、shell history、systemd unit、Docker commandへ平文で残さず、漏洩時はrotateする。"),
    Rule("CF-TUNNEL-002", "high", "Tunnel origin TLS verification disabled", r"noTLSVerify\s*[:=]\s*true|no-tls-verify\s*:\s*true", "Tunnel originのTLS検証無効化は例外扱い。Full(strict)、正しいorigin証明書、限定networkで代替できないか確認する。"),
]

SECRET_FILE_NAMES = {
    ".env", ".env.local", ".env.production", ".env.development", ".dev.vars",
    "service-account.json", "credentials.json",
}

SEVERITY_ORDER = {"info": 0, "medium": 1, "high": 2, "critical": 3}


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for name in filenames:
            path = Path(dirpath) / name
            lower_name = path.name.lower()
            if (
                path.name in SECRET_FILE_NAMES
                or path.name in TEXT_FILE_NAMES
                or lower_name.startswith(TEXT_FILE_PREFIXES)
                or lower_name.startswith(".env.")
                or lower_name.startswith(".dev.vars")
                or path.suffix.lower() in TEXT_EXTS
            ):
                yield path


def safe_excerpt(line: str) -> str:
    line = re.sub(r"(--token(?!-file)[\"'\s,:=]+)([\"']?)(?!<|\$)[A-Za-z0-9._\-]{20,}", r"\1\2<redacted>", line, flags=re.I)
    line = re.sub(r"((?:cloudflared|cloudflare/cloudflared(?::[\w.\-]+)?)\b[^\n]*?--token\s+)\S+", r"\1<redacted>", line, flags=re.I)
    line = re.sub(r"(cloudflared\s+service\s+install\s+)(?!--token\b)\S+", r"\1<redacted>", line, flags=re.I)
    # Avoid leaking values after separators for secret-looking lines.
    if re.search(r"api[_-]?key|secret|token|password", line, re.I):
        line = re.sub(r"([:=]\s*)(['\"]?)[^'\"\s]+", r"\1<redacted>", line)
    return line.strip()[:180]


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_files(root):
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
            rel = str(path.relative_to(root))
            if path.name in SECRET_FILE_NAMES:
                findings.append(Finding(
                    id="CF-SEC-004",
                    severity="high",
                    title="Secret/env file present",
                    path=rel,
                    line=1,
                    recommendation=".env/.dev.vars/credential filesがgit管理外であることを確認する。中身は表示しない。",
                    excerpt="<file exists>",
                ))
                # Do not scan secret files further.
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
                findings.append(Finding(
                    id=rule.id,
                    severity=rule.severity,
                    title=rule.title,
                    path=rel,
                    line=line_no,
                    recommendation=rule.recommendation,
                    excerpt=safe_excerpt(line),
                ))
        for idx, line in enumerate(lines):
            command_match = re.match(r"^(\s*)command\s*:\s*([>|][+-]?)?\s*$", line)
            if not command_match:
                continue
            base_indent = len(command_match.group(1))
            block: list[tuple[int, str]] = []
            for j in range(idx + 1, min(len(lines), idx + 42)):
                child = lines[j]
                if child.strip() and len(child) - len(child.lstrip(" ")) <= base_indent:
                    break
                block.append((j, child))
            block_text = "\n".join(child for _, child in block)
            if not re.search(r"\btunnel\b", block_text, re.I) or not re.search(r"--token(?!-file)\b", block_text, re.I):
                continue
            token_line = None
            for n, (j, child) in enumerate(block):
                if re.search(r"--token(?!-file)[\"'\s,:=]+[\"']?(?!<|\$)[A-Za-z0-9._\-]{20,}", child, re.I):
                    token_line = j
                    break
                if re.search(r"--token(?!-file)\b", child, re.I):
                    for k, following in block[n + 1:n + 4]:
                        if re.search(r"^\s*-\s*[\"\']?(?!<|\$)[A-Za-z0-9._\-]{20,}[\"\']?\s*$", following):
                            token_line = k
                            break
                    if token_line is not None:
                        break
            if token_line is None:
                continue
            findings.append(Finding(
                id="CF-TUNNEL-001",
                severity="critical",
                title="Cloudflare Tunnel token inline",
                path=rel,
                line=token_line + 1,
                recommendation="Tunnel tokenはsecret扱い。repo、shell history、systemd unit、Docker commandへ平文で残さず、漏洩時はrotateする。",
                excerpt="<redacted tunnel token>",
            ))
    return findings


def print_markdown(findings: list[Finding]) -> None:
    counts: dict[str, int] = {"critical": 0, "high": 0, "medium": 0, "info": 0}
    for f in findings:
        counts[f.severity] = counts.get(f.severity, 0) + 1
    print("# Cloudflare static risk scan")
    print()
    print(f"Findings: critical={counts.get('critical', 0)}, high={counts.get('high', 0)}, medium={counts.get('medium', 0)}, info={counts.get('info', 0)}")
    print()
    if not findings:
        print("No static findings. Continue with Cloudflare MCP/API billing and security checks.")
        return
    print("| Severity | Rule | File:line | Finding | Recommendation | Excerpt |")
    print("|---|---|---|---|---|---|")
    for f in sorted(findings, key=lambda x: (-SEVERITY_ORDER.get(x.severity, 0), x.id, x.path, x.line)):
        excerpt = f.excerpt.replace("|", "\\|")
        rec = f.recommendation.replace("|", "\\|")
        print(f"| {f.severity} | {f.id} | `{f.path}:{f.line}` | {f.title} | {rec} | `{excerpt}` |")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan a repo for Cloudflare cost/security risk patterns.")
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
