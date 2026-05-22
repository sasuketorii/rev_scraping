# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.2 schema bridge + redaction)
"""MCP -> Hermes schema bridge and response redaction helpers.

The MCP ``tools/list`` payload uses JSON Schema directly under
``inputSchema`` / ``outputSchema``. Hermes plugin contexts also accept
JSON Schema, so the bridge is a near-passthrough today; we keep it as a
distinct module so future Hermes-side schema dialect changes have a
single seam to patch.

The redaction helper scrubs raw ``Cookie:`` / ``Set-Cookie:`` values and
common secret-shaped fields from a JSON response before Hermes echoes it
back to the host model. We do this defensively even though stealth-mcp
already redacts at its layer: defense in depth across the host/plugin
boundary is cheap.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Mapping, Optional

# Sentinel string returned in place of redacted values. Keep in sync
# with the Rust side's stealth_mcp redaction sentinel so operators see a
# consistent marker. Tests pin this string.
REDACTED_SENTINEL: str = "<redacted>"

# Field-name patterns to scrub (case-insensitive substring match).
_SECRET_FIELD_PATTERNS: tuple[str, ...] = (
    "cookie",
    "set-cookie",
    "authorization",
    "auth_token",
    "access_token",
    "refresh_token",
    "session_token",
    "api_key",
    "apikey",
    "password",
    "passwd",
    "secret",
    "bearer",
)

# Regex for "Cookie: name=value; name2=value2" style headers embedded in
# free-text response content. We replace each value segment.
_COOKIE_HEADER_RE = re.compile(
    r"(?im)^(?P<prefix>(?:set-)?cookie\s*:\s*)(?P<body>.+)$"
)


def mcp_tool_to_hermes(descriptor: Mapping[str, Any]) -> Dict[str, Any]:
    """Translate an MCP tool descriptor into a Hermes-friendly form.

    Current behaviour is passthrough (with key renames) because both
    sides speak JSON Schema. The function is intentionally pure so
    callers can call it without spinning up a real MCP child.
    """
    out: Dict[str, Any] = {
        "name": descriptor.get("name"),
        "description": descriptor.get("description", ""),
    }
    if "inputSchema" in descriptor and isinstance(descriptor["inputSchema"], dict):
        out["input_schema"] = dict(descriptor["inputSchema"])
    else:
        out["input_schema"] = {"type": "object"}
    if "outputSchema" in descriptor and isinstance(descriptor["outputSchema"], dict):
        out["output_schema"] = dict(descriptor["outputSchema"])
    return out


def _looks_secret(field_name: str) -> bool:
    lower = field_name.lower()
    return any(pat in lower for pat in _SECRET_FIELD_PATTERNS)


def _redact_cookie_header_text(text: str) -> str:
    def repl(match: re.Match[str]) -> str:
        body = match.group("body")
        # Replace each `name=value` pair's value with the sentinel.
        parts = []
        for raw in body.split(";"):
            chunk = raw.strip()
            if not chunk:
                continue
            if "=" in chunk:
                name, _ = chunk.split("=", 1)
                parts.append(f"{name.strip()}={REDACTED_SENTINEL}")
            else:
                parts.append(chunk)
        return f"{match.group('prefix')}{'; '.join(parts)}"

    return _COOKIE_HEADER_RE.sub(repl, text)


def redact_response(value: Any) -> Any:
    """Return a deep-copied ``value`` with secret-shaped fields scrubbed.

    * Dict keys matched by :data:`_SECRET_FIELD_PATTERNS` have their
      values replaced with :data:`REDACTED_SENTINEL`.
    * Strings that match a ``Cookie:`` / ``Set-Cookie:`` header are
      rewritten so each cookie value is the sentinel.
    * Other scalars and structures are passed through unchanged.
    """
    if isinstance(value, dict):
        result: Dict[str, Any] = {}
        for key, sub in value.items():
            if isinstance(key, str) and _looks_secret(key):
                result[key] = REDACTED_SENTINEL
            else:
                result[key] = redact_response(sub)
        return result
    if isinstance(value, list):
        return [redact_response(item) for item in value]
    if isinstance(value, str):
        return _redact_cookie_header_text(value)
    return value


__all__ = [
    "REDACTED_SENTINEL",
    "mcp_tool_to_hermes",
    "redact_response",
]
