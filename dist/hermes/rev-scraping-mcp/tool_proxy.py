# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.1 Hermes adapter)
"""Bridge a single MCP tool descriptor to a Hermes ctx callable.

Hermes plugins expose tools via ``ctx.register_tool(name, fn, schema=...)``
(or a similar signature; the registration adapter calls whatever method
is present on the context object). To keep this scaffold framework-
agnostic, :class:`ToolProxy` only exposes a Python callable plus a name
and an inputSchema. The :mod:`__init__` module is responsible for
wiring the proxy into whichever ctx API is supplied at runtime.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, Mapping, Optional


class ToolProxy:
    """Callable bridge from a Hermes invocation to ``tools/call`` on the MCP child."""

    def __init__(
        self,
        descriptor: Mapping[str, Any],
        invoker: Callable[[str, Optional[Dict[str, Any]]], Dict[str, Any]],
    ) -> None:
        if "name" not in descriptor:
            raise ValueError("MCP tool descriptor missing 'name'")
        self._descriptor: Dict[str, Any] = dict(descriptor)
        self._invoker = invoker

    @property
    def name(self) -> str:
        return str(self._descriptor["name"])

    @property
    def description(self) -> str:
        return str(self._descriptor.get("description", ""))

    @property
    def input_schema(self) -> Dict[str, Any]:
        schema = self._descriptor.get("inputSchema")
        if isinstance(schema, dict):
            return dict(schema)
        return {"type": "object"}

    @property
    def output_schema(self) -> Optional[Dict[str, Any]]:
        schema = self._descriptor.get("outputSchema")
        if isinstance(schema, dict):
            return dict(schema)
        return None

    @property
    def descriptor(self) -> Dict[str, Any]:
        return dict(self._descriptor)

    def __call__(self, arguments: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
        args: Optional[Dict[str, Any]] = dict(arguments) if arguments is not None else None
        return self._invoker(self.name, args)


def build_proxies(
    descriptors: list[Mapping[str, Any]],
    invoker: Callable[[str, Optional[Dict[str, Any]]], Dict[str, Any]],
) -> Dict[str, ToolProxy]:
    """Build a name->ToolProxy mapping from a tools/list response."""
    proxies: Dict[str, ToolProxy] = {}
    for desc in descriptors:
        proxy = ToolProxy(desc, invoker)
        proxies[proxy.name] = proxy
    return proxies


__all__ = ["ToolProxy", "build_proxies"]
