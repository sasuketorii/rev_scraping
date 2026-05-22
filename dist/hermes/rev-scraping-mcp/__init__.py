# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.1 Hermes adapter)
"""Hermes plugin entrypoint for rev-scraping-mcp.

This package wraps the Rust ``stealth-mcp`` binary and exposes its 16
MCP tools (the count is enforced by the smoke tests, not hard-coded
here) as Hermes ctx callables.

Hermes loads the plugin by calling :func:`register` with a context
object. The exact shape of ``ctx`` varies between Hermes versions, so
the registration logic uses ``getattr`` with a small set of supported
method names and falls back to a generic ``register_tool`` call.
"""

from __future__ import annotations

import os
from typing import Any, Callable, Dict, List, Mapping, Optional

try:
    from .lifecycle import LifecycleError, SupervisedClient
    from .mcp_client import DEFAULT_PROTOCOL_VERSION, McpClient, McpProtocolError
    from .schema_bridge import mcp_tool_to_hermes, redact_response
    from .tool_proxy import ToolProxy, build_proxies
except ImportError:  # standalone load (no parent package)
    from lifecycle import LifecycleError, SupervisedClient  # type: ignore[no-redef]
    from mcp_client import (  # type: ignore[no-redef]
        DEFAULT_PROTOCOL_VERSION,
        McpClient,
        McpProtocolError,
    )
    from schema_bridge import mcp_tool_to_hermes, redact_response  # type: ignore[no-redef]
    from tool_proxy import ToolProxy, build_proxies  # type: ignore[no-redef]

# Environment variable that lets operators override the binary path.
# If unset, the plugin looks up ``stealth-mcp`` on ``PATH``.
BINARY_OVERRIDE_ENV = "REV_SCRAPING_MCP_BIN"


def _resolve_binary() -> str:
    return os.environ.get(BINARY_OVERRIDE_ENV, "stealth-mcp")


def _make_supervised_client(
    *,
    binary: Optional[str] = None,
    protocol_version: str = DEFAULT_PROTOCOL_VERSION,
    env: Optional[Mapping[str, str]] = None,
) -> SupervisedClient:
    resolved = binary or _resolve_binary()

    def factory() -> McpClient:
        return McpClient(resolved, protocol_version=protocol_version, env=env)

    return SupervisedClient(factory)


def _register_with_ctx(
    ctx: Any,
    proxies: Dict[str, ToolProxy],
) -> List[str]:
    """Register each proxy with the Hermes ctx object.

    Tries, in order, the following ctx APIs (Hermes 1.x has used all of
    these across versions):

    1. ``ctx.register_tool(name, fn, schema=..., description=...)``
    2. ``ctx.register(name, fn, schema=..., description=...)``
    3. ``ctx.tools[name] = fn`` (dict-style fallback)
    """
    register_method: Optional[Callable[..., Any]] = None
    for attr in ("register_tool", "register"):
        candidate = getattr(ctx, attr, None)
        if callable(candidate):
            register_method = candidate
            break

    registered: List[str] = []
    tools_dict = getattr(ctx, "tools", None)
    for name, proxy in proxies.items():
        bridged = mcp_tool_to_hermes(proxy.descriptor)
        if register_method is not None:
            register_method(
                name,
                proxy,
                schema=bridged.get("input_schema"),
                description=bridged.get("description", ""),
            )
            registered.append(name)
        elif isinstance(tools_dict, dict):
            tools_dict[name] = proxy
            registered.append(name)
        else:
            raise RuntimeError(
                "Hermes ctx has no register_tool / register / tools attribute"
            )
    return registered


def register(ctx: Any) -> Dict[str, Any]:
    """Hermes plugin entrypoint.

    Spawns the stealth-mcp child, runs the MCP handshake, lists its
    tools, and registers each as a Hermes ctx callable. The supervised
    client is stashed on ``ctx`` as ``_rev_scraping_mcp`` so the host can
    call :py:meth:`SupervisedClient.stop` on plugin teardown.

    Returns a small dict describing what was registered. The smoke tests
    use the return value to assert tool count and protocol version.
    """
    supervised = _make_supervised_client()
    supervised.start()

    def invoker(name: str, arguments: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        # Defense-in-depth: scrub cookie / secret-shaped fields out of
        # any response before it reaches the Hermes host. stealth-mcp
        # already redacts at the Rust layer; this is a second seam in
        # case a future tool author forgets to do so.
        raw = supervised.call_tool(name, arguments)
        scrubbed = redact_response(raw)
        if not isinstance(scrubbed, dict):
            # redact_response preserves shape, but be defensive in case
            # a future change widens the contract.
            return {"content": [], "structuredContent": scrubbed}
        return scrubbed

    descriptors = supervised.list_tools()
    proxies = build_proxies(descriptors, invoker)

    try:
        names = _register_with_ctx(ctx, proxies)
    except Exception:
        supervised.stop()
        raise

    # Stash for teardown; Hermes calls into this in its shutdown path.
    try:
        setattr(ctx, "_rev_scraping_mcp", supervised)
    except Exception:
        # ctx may be a frozen dataclass / dict in some Hermes builds;
        # losing the teardown handle is non-fatal.
        pass

    return {
        "tool_count": len(names),
        "tool_names": names,
        "protocol_version": DEFAULT_PROTOCOL_VERSION,
        "supervised": supervised,
    }


__all__ = [
    "BINARY_OVERRIDE_ENV",
    "LifecycleError",
    "McpProtocolError",
    "register",
]
