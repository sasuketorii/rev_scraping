#!/usr/bin/env python3
"""Static Codex app-server risk scanner.

Conservative scanner for dangerous app-server exposure, sandbox/approval bypass,
secret leakage, command/exec bridges, and multi-tenant risks. It redacts secrets.
"""
from __future__ import annotations
import argparse, json, os, re, sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Pattern, Sequence

EXCLUDE_DIRS = {
    ".git", "node_modules", ".next", "dist", "build", "coverage", ".turbo",
    ".cache", ".venv", "venv", "__pycache__", ".pnpm-store",
    ".agents", ".claude", ".cursor", ".windsurf",
    "codex-app-server-guard", "payload-cms-deploy-guard", "supabase-deploy-guard", "cloudflare-deploy-guard",
}
TEXT_EXTS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    ".py", ".go", ".rs", ".rb", ".php", ".java", ".kt", ".swift",
    ".sql", ".toml", ".json", ".jsonc", ".yaml", ".yml", ".env", ".md",
    ".sh", ".bash", ".zsh", ".dockerfile", ".txt", ".html", ".svelte", ".vue",
    ".service", ".conf",
}
SEVERITY_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
SECRETISH = re.compile(
    r"(Authorization:\s*Bearer\s+[A-Za-z0-9._\-]+|OPENAI_API_KEY\s*=\s*[^\s]+|"
    r"CODEX_[A-Z0-9_]*(TOKEN|KEY|SECRET)\s*=\s*[^\s]+|"
    r"--ws-token\s+[^\s]+|--ws-shared-secret\s+[^\s]+|"
    r"sk-[A-Za-z0-9_\-]{16,}|eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,})",
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
    Rule("app-server-command", "info", "app-server", rx(r"codex\s+app-server|['\"]app-server['\"]"), "codex app-server usage found. Review transport/auth/sandbox/approval/logging."),
    Rule("ws-listen-any", "critical", "transport-auth", rx(r"--listen\s+ws://(0\.0\.0\.0|\[::\]|::|\*)[:/]"), "App-server WebSocket listens on all interfaces. Require loopback only or strong auth/TLS/proxy/rate limit."),
    Rule("ws-listen-nonloopback", "high", "transport-auth", rx(r"--listen\s+ws://(?!127\.0\.0\.1|localhost)[^\s\"']+"), "Non-loopback WebSocket listener found. Verify auth, TLS/reverse proxy, IP allowlist, and audit logs."),
    Rule("ws-listen", "medium", "transport-auth", rx(r"--listen\s+ws://"), "WebSocket transport found. Treat as experimental; prefer stdio or loopback."),
    Rule("missing-ws-auth-context", "high", "transport-auth", rx(r"codex\s+app-server(?:(?!--ws-auth).){0,240}--listen\s+ws://"), "WebSocket app-server command appears without --ws-auth nearby. Confirm auth is configured elsewhere."),
    Rule("ws-auth-none", "critical", "transport-auth", rx(r"--ws-auth\s+(none|off|disabled)"), "WebSocket auth disabled. Do not expose app-server without authentication."),
    Rule("raw-bearer-token", "critical", "secrets", rx(r"Authorization\s*:\s*Bearer\s+[A-Za-z0-9._\-]{12,}|--ws-token\s+\S+|ws://[^\s]+token="), "Raw bearer/capability token appears inline. Use token files or secret storage and rotate if exposed."),
    Rule("token-file-good", "info", "transport-auth", rx(r"--ws-token-file\s+|--ws-shared-secret-file\s+|--ws-token-sha256\s+"), "WebSocket auth flag found. Verify file permissions and rotation."),
    Rule("openai-api-key", "critical", "secrets", rx(r"OPENAI_API_KEY\s*=|sk-[A-Za-z0-9_\-]{16,}"), "OpenAI API key reference/value found. Ensure server-only secret storage and redact logs."),
    Rule("codex-auth-json", "critical", "secrets", rx(r"\.codex/auth\.json|~/.codex/auth\.json|auth\.json"), "Codex auth.json reference found. Never copy into project/images/logs; isolate per user."),
    Rule("danger-full-access", "critical", "sandbox", rx(r"dangerously-bypass-approvals-and-sandbox|--yolo|danger[-_]?full[-_]?access|dangerFullAccess|sandbox_mode\s*=\s*['\"]danger"), "Danger full access disables/weakens sandbox. Do not use in production/shared/multi-tenant environments."),
    Rule("approval-never", "high", "approvals", rx(r"approval_policy\s*=\s*['\"]never['\"]|--ask-for-approval\s+never|-a\s+never"), "Approval prompts disabled. Only safe for read-only non-interactive contexts."),
    Rule("workspace-write", "medium", "sandbox", rx(r"workspace[-_]?write|workspaceWrite|sandbox_mode\s*=\s*['\"]workspace-write['\"]"), "Workspace-write sandbox found. Confirm writable roots exclude secrets and network remains controlled."),
    Rule("network-enabled", "high", "network", rx(r"network_access\s*=\s*true|networkAccess\s*[:=]\s*['\"]?enabled|web_search\s*=\s*['\"]live['\"]"), "Network access/live web search enabled. Require allowlist, approval, and prompt-injection controls."),
    Rule("external-sandbox", "high", "sandbox", rx(r"externalSandbox|external[-_]?sandbox"), "External sandbox found. Verify external isolation proof, network policy, and least privilege."),
    Rule("external-sandbox-network", "critical", "sandbox-network", rx(r"externalSandbox[\s\S]{0,400}networkAccess[\s\S]{0,80}enabled|networkAccess[\s\S]{0,80}enabled[\s\S]{0,400}externalSandbox"), "External sandbox with network enabled found. Require hard evidence of isolation and approval controls."),
    Rule("unix-sockets-all", "critical", "network", rx(r"dangerouslyAllowAllUnixSockets\s*=\s*true"), "All Unix sockets allowed. This can expose Docker/cloud agents/local services."),
    Rule("add-dir-home-root", "critical", "filesystem", rx(r"--add-dir\s+(/|~|\$HOME|/home|/Users)(\s|$)|writable_roots\s*=\s*\[[^\]]*(/|~|\$HOME|/home|/Users)"), "Broad writable/readable directory added. Restrict to project workspace only."),
    Rule("env-readable", "high", "filesystem-secrets", rx(r"\.env\*|\*\*/\*\.env|AWS_SHARED_CREDENTIALS_FILE|GOOGLE_APPLICATION_CREDENTIALS|SSH_AUTH_SOCK|id_rsa|id_ed25519"), "Sensitive file/env path referenced. Ensure permission profile denies reads and logs are redacted."),
    Rule("command-exec", "high", "command-exec", rx(r"command/exec|method\s*:\s*['\"]command/exec['\"]"), "command/exec used. Require argv/cwd/sandbox allowlist, timeout, output cap, and approvals."),
    Rule("user-controlled-command", "critical", "command-exec", rx(r"command\s*:\s*(req\.|request\.|body\.|params\.|input\.|userInput)|argv\s*[:=]\s*(req\.|body\.|params\.|input\.)"), "Command/argv appears user-controlled. Do not proxy arbitrary commands."),
    Rule("user-controlled-cwd", "critical", "filesystem", rx(r"cwd\s*:\s*(req\.|request\.|body\.|params\.|input\.|userInput)"), "cwd appears user-controlled. Normalize and enforce workspace allowlist."),
    Rule("user-controlled-sandbox", "critical", "sandbox", rx(r"sandboxPolicy\s*:\s*(req\.|request\.|body\.|params\.|input\.)|sandbox_mode\s*[:=]\s*(req\.|body\.|params\.)"), "Sandbox policy appears user-controlled. Server must enforce allowed policies."),
    Rule("additional-permissions", "high", "approvals", rx(r"additionalPermissions|acceptWithExecpolicyAmendment|execpolicy_amendment"), "Additional permissions/execpolicy amendment found. Require explicit user approval and policy validation."),
    Rule("accept-for-session", "high", "approvals", rx(r"acceptForSession|decision\s*:\s*['\"]accept['\"]|decision\s*:\s*['\"]acceptForSession['\"]"), "Approval decision automation found. Ensure correct user/session/thread/item and no blanket approval."),
    Rule("experimental-api", "high", "experimental", rx(r"experimentalApi\s*:\s*true|capabilities[\s\S]{0,200}experimentalApi"), "Experimental API enabled. Limit to required clients and review dynamic tool/surface risks."),
    Rule("dynamic-tools", "high", "dynamic-tools", rx(r"dynamicTools|dynamicToolCall|item/tool/call"), "Dynamic tools found. Require schema validation, approval, least privilege, and untrusted-output handling."),
    Rule("skills-config-write", "high", "skills", rx(r"skills/config/write|skills\.config\.write"), "Skill config write surface found. Restrict to admin and path allowlist."),
    Rule("skills-list", "medium", "skills", rx(r"skills/list|perCwdExtraUserRoots|extraUserRoots"), "Skill listing/custom roots found. Restrict roots and review untrusted skills."),
    Rule("app-mcp-tools", "high", "mcp-apps", rx(r"mcpToolCall|tool/requestUserInput|app/list|codex\s+mcp|\.mcp\.json|mcp_servers|mcpServers"), "MCP/App connector surface found. Review side effects, scopes, approvals, and prompt injection."),
    Rule("fs-watch", "medium", "filesystem", rx(r"fs/watch|fs/unwatch|fs/changed"), "Filesystem watch surface found. Ensure absolute paths are workspace-scoped and tenant-isolated."),
    Rule("thread-read-list", "medium", "multi-tenant", rx(r"thread/list|thread/read|thread/resume|thread/fork|thread/archive"), "Thread persistence/read/resume surface found. Enforce user/org ownership and retention."),
    Rule("review-start", "medium", "usage", rx(r"review/start|reviewThreadId"), "Review mode found. Estimate additional token usage and restrict targets/diff size."),
    Rule("token-usage", "info", "usage", rx(r"thread/tokenUsage/updated|UsageLimitExceeded|usageLimit"), "Usage tracking found. Ensure budgets and fail-closed behavior are implemented."),
    Rule("docker-socket", "critical", "container", rx(r"/var/run/docker\.sock|privileged\s*:\s*true|hostNetwork\s*:\s*true"), "Container has privileged/Docker socket/host networking. Do not combine with agent command execution."),
    Rule("docker-port", "high", "transport-auth", rx(r"ports\s*:\s*\[[^\]]*:\d+|EXPOSE\s+\d+|hostPort\s*:\s*\d+"), "Port exposure found. Verify app-server WebSocket is not publicly exposed."),
    Rule("systemd-service", "medium", "deployment", rx(r"\[Service\]|ExecStart=.*codex.*app-server"), "Systemd/service deployment found. Review user, working directory, environment, restart loop, and logs."),
]


def is_text_file(path: Path) -> bool:
    if path.name.startswith(".env"):
        return True
    if path.suffix.lower() in TEXT_EXTS:
        return True
    if path.name in {"Dockerfile", "docker-compose.yml", "docker-compose.yaml", "package.json", "config.toml", "requirements.toml", ".mcp.json"}:
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
    s = re.sub(r"(['\"])[A-Za-z0-9_./:+\-=]{32,}\1", r"\1<REDACTED>\1", s)
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
    print("# Codex App Server Static Risk Scan")
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
    p = argparse.ArgumentParser(description="Scan a repository for Codex app-server risks.")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--fail-on", choices=list(SEVERITY_RANK), default=None)
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
