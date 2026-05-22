# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.1 Hermes adapter)
"""JSON-RPC 2.0 stdio client for the stealth-mcp Rust subprocess.

This module is intentionally dependency-free (stdlib only) so the Hermes
plugin can be installed into any Python 3.10+ environment without pulling
extra wheels.

Design invariants:
    * The MCP child is spawned with a *whitelisted* environment. Host env
      that is not in :data:`ENV_ALLOWLIST` is dropped before
      :func:`subprocess.Popen` runs. The whitelist mirrors
      ``plugin.yaml``'s ``env_allowlist`` entry.
    * Protocol frames are line-delimited JSON on stdout. Logs (tracing)
      from the child go to stderr and are *never* parsed.
    * Request IDs are integer-monotonic. Responses are matched by id.
    * Timeouts are explicit per-call (default :data:`DEFAULT_CALL_TIMEOUT`).

The client itself does NOT implement restart-with-backoff. That belongs
to :mod:`lifecycle` so the two concerns stay independent.
"""

from __future__ import annotations

import json
import os
import select
import subprocess
import threading
import time
from typing import Any, Dict, Iterable, List, Mapping, Optional

# Mirrors plugin.yaml::env_allowlist. Keep in sync with that file; the
# Cargo / Rust side never reads this list (the Rust binary trusts the
# parent process to scrub env). Anything *not* in this set is dropped.
ENV_ALLOWLIST: frozenset[str] = frozenset(
    [
        "REV_SCRAPING_HOME",
        "REV_SCRAPING_REQUIRE_VPN",
        "REV_SCRAPING_CONFIG_LENIENT",
        "REV_SCRAPING_PROFILE",
        "VPN_INSTANCES",
        "VPN_PROFILE_FILE",
        "VPN_CREDENTIALS_FILE",
        "VPN_AUTH_FILE",
        "PATH",
        "HOME",
        "LANG",
        "LC_ALL",
    ]
)

# Explicit deny-list of secret-shaped names. Even if a future maintainer
# adds one of these to ENV_ALLOWLIST by mistake, the spawn path strips
# them defensively.
ENV_DENYLIST: frozenset[str] = frozenset(
    [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "OPENAI_KEY",
        "CLAUDE_API_KEY",
        "GITHUB_TOKEN",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
    ]
)

DEFAULT_PROTOCOL_VERSION = "2024-11-05"
DEFAULT_CALL_TIMEOUT = 60.0
INITIALIZE_TIMEOUT = 10.0


def filter_env(source: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Return a sanitized env mapping for the MCP child.

    Only keys in :data:`ENV_ALLOWLIST` are passed through, and keys in
    :data:`ENV_DENYLIST` are unconditionally removed even if a caller
    added them upstream. ``source`` defaults to :data:`os.environ` so the
    function can be unit-tested with a custom mapping.
    """

    src: Mapping[str, str] = source if source is not None else os.environ
    out: Dict[str, str] = {}
    for key in ENV_ALLOWLIST:
        if key in ENV_DENYLIST:
            continue
        value = src.get(key)
        if value is not None:
            out[key] = value
    return out


class McpProtocolError(RuntimeError):
    """Raised when the MCP child returns a JSON-RPC error or malformed frame."""


class McpClient:
    """Minimal JSON-RPC 2.0 client over the stealth-mcp stdio transport.

    Not thread-safe for concurrent calls; serialize :meth:`call_tool`
    through a single owner (Hermes plugin context).
    """

    def __init__(
        self,
        binary: str = "stealth-mcp",
        *,
        protocol_version: str = DEFAULT_PROTOCOL_VERSION,
        env: Optional[Mapping[str, str]] = None,
        popen_factory: Any = subprocess.Popen,
        binary_io: Optional[bool] = None,
    ) -> None:
        self._binary = binary
        self._protocol_version = protocol_version
        self._env_override = dict(env) if env is not None else None
        self._popen_factory = popen_factory
        # Default: binary, unbuffered I/O when the factory is the real
        # subprocess.Popen (production); text-mode for in-memory fakes.
        # ``binary_io`` lets a real-subprocess test exercise the binary
        # path through a wrapped factory.
        if binary_io is None:
            self._binary_io = popen_factory is subprocess.Popen
        else:
            self._binary_io = bool(binary_io)
        self._proc: Any = None
        self._lock = threading.Lock()
        self._next_id = 1
        self._initialized = False
        self._tools_cache: Optional[List[Dict[str, Any]]] = None
        # Byte carry-over for deadline-aware partial-frame reads (only
        # used on the real-fd path; in-memory fakes return whole lines).
        self._byte_carry: bytes = b""

    # ------------------------------------------------------------------ lifecycle
    def start(self) -> None:
        """Spawn the child and run the MCP initialize handshake.

        The spawn env is *always* re-filtered through :func:`filter_env`,
        even when the caller passed an explicit ``env=`` override. This
        prevents a future caller from accidentally smuggling secret
        env vars (``ANTHROPIC_API_KEY`` et al) into the child by
        constructing the client with ``env=os.environ``.
        """
        if self._proc is not None and self._proc.poll() is None:
            return
        spawn_env = filter_env(self._env_override) if self._env_override is not None else filter_env()
        # Production path uses binary, unbuffered stdio so the deadline-
        # aware reader in :meth:`_readline_with_deadline` can use
        # :func:`os.read` directly without fighting Python's text-mode
        # buffer. Test fakes (FakePopen) ignore these kwargs and run in
        # in-memory text mode; the client detects that via
        # ``hasattr(stream, 'fileno')`` at recv time.
        popen_kwargs: Dict[str, Any] = dict(
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=spawn_env,
        )
        if self._binary_io:
            popen_kwargs.update(text=False, bufsize=0)
        else:
            popen_kwargs.update(text=True, bufsize=1)
        self._proc = self._popen_factory([self._binary], **popen_kwargs)
        self._next_id = 1
        self._initialized = False
        self._tools_cache = None
        self._byte_carry = b""
        try:
            self._initialize()
        except Exception:
            # Ensure the half-spawned child does not leak fds when the
            # handshake fails (e.g. deadline expiry on a wedged peer).
            # Use a short cleanup timeout so a wedged peer is escalated
            # quickly to terminate/kill rather than blocking start().
            self.stop(timeout=0.5)
            raise

    def stop(self, *, timeout: float = 5.0) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.poll() is None:
                # Live child: close stdin to signal EOF, then wait /
                # escalate. stdout/stderr are closed unconditionally
                # below.
                try:
                    s = getattr(self._proc, "stdin", None)
                    if s is not None:
                        s.close()
                except Exception:
                    pass
                try:
                    self._proc.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    self._proc.terminate()
                    try:
                        self._proc.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:
                        self._proc.kill()
            # Unconditionally close all three parent-side pipes,
            # including the dead-child case where ``poll()`` is already
            # non-None. Without this stdin can leak when the child
            # writes a partial frame and exits before we tear down.
            for stream_name in ("stdin", "stdout", "stderr"):
                try:
                    s = getattr(self._proc, stream_name, None)
                    if s is not None and not getattr(s, "closed", True):
                        s.close()
                except Exception:
                    pass
        finally:
            self._proc = None
            self._initialized = False
            self._tools_cache = None
            self._byte_carry = b""

    def is_running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    # ------------------------------------------------------------------ rpc
    def _send(self, frame: Dict[str, Any]) -> None:
        if self._proc is None or self._proc.stdin is None:
            raise McpProtocolError("MCP child stdin is not open")
        line = json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n"
        # Detect text-mode pipes (test fakes) vs binary-mode (production).
        # We cannot rely on isinstance(self._proc.stdin, io.BufferedWriter)
        # because FakePopen uses a custom writer. Probe by attempting a
        # text write first; on TypeError fall back to bytes.
        try:
            self._proc.stdin.write(line)
        except TypeError:
            self._proc.stdin.write(line.encode("utf-8"))
        self._proc.stdin.flush()

    def _readline_with_deadline(self, stream: Any, deadline: float) -> str:
        """Best-effort line-read that honours a wall-clock deadline.

        On real :class:`subprocess.PIPE` streams we read raw bytes
        directly from the underlying fd via :func:`os.read`, blocking
        only on :func:`select.select` slices bounded by the remaining
        deadline. This guarantees a malformed child that writes a
        partial line (no terminating ``\\n``) and stays alive still
        trips the deadline rather than wedging inside
        :py:meth:`readline`.

        Streams without a usable :py:meth:`fileno` (e.g. in-memory
        fakes used by the unit tests) fall back to a poll loop on
        ``readline``; those fakes reply synchronously and never produce
        partial frames.
        """
        try:
            fd = stream.fileno()
        except (AttributeError, OSError, ValueError):
            fd = None
        if fd is not None:
            buf = bytearray(self._byte_carry)
            self._byte_carry = b""
            while True:
                # If a complete line is already buffered, return it.
                nl = buf.find(b"\n")
                if nl != -1:
                    line_bytes = bytes(buf[: nl + 1])
                    self._byte_carry = bytes(buf[nl + 1 :])
                    return line_bytes.decode("utf-8", errors="replace")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    # Save partial bytes so a follow-up _recv can pick up
                    # where we left off (the next call gets a fresh
                    # deadline; we do not silently truncate).
                    self._byte_carry = bytes(buf)
                    return ""
                rlist, _, _ = select.select([fd], [], [], min(remaining, 1.0))
                if not rlist:
                    continue
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    # EOF — surface what we have so the caller can
                    # detect a dead child.
                    self._byte_carry = b""
                    if buf:
                        return buf.decode("utf-8", errors="replace")
                    return ""
                buf.extend(chunk)
        # In-memory fallback (tests).
        while True:
            line = stream.readline()
            if line:
                return line
            if time.monotonic() > deadline:
                return ""
            time.sleep(0.01)

    def _recv(self, *, timeout: float) -> Dict[str, Any]:
        if self._proc is None or self._proc.stdout is None:
            raise McpProtocolError("MCP child stdout is not open")
        deadline = time.monotonic() + timeout
        # Detect a child that exited before we even started reading.
        if self._proc.poll() is not None:
            raise McpProtocolError("MCP child exited before responding")
        line = self._readline_with_deadline(self._proc.stdout, deadline)
        if not line:
            # Either a hard deadline expiry or EOF from a dead child.
            if self._proc.poll() is not None:
                raise McpProtocolError("MCP child exited before responding")
            raise McpProtocolError("MCP child response timed out")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise McpProtocolError(f"malformed JSON-RPC frame: {line!r}") from exc

    def _rpc(self, method: str, params: Optional[Dict[str, Any]] = None, *, timeout: float) -> Any:
        with self._lock:
            rpc_id = self._next_id
            self._next_id += 1
            frame: Dict[str, Any] = {"jsonrpc": "2.0", "id": rpc_id, "method": method}
            if params is not None:
                frame["params"] = params
            self._send(frame)
            resp = self._recv(timeout=timeout)
        if resp.get("id") != rpc_id:
            raise McpProtocolError(
                f"id mismatch: sent {rpc_id}, got {resp.get('id')!r}"
            )
        if "error" in resp:
            err = resp["error"]
            raise McpProtocolError(
                f"MCP error {err.get('code')}: {err.get('message')}"
            )
        return resp.get("result")

    def _initialize(self) -> None:
        result = self._rpc(
            "initialize",
            {
                "protocolVersion": self._protocol_version,
                "capabilities": {},
                "clientInfo": {"name": "hermes-rev-scraping-mcp", "version": "1.2.0"},
            },
            timeout=INITIALIZE_TIMEOUT,
        )
        if not isinstance(result, dict) or "protocolVersion" not in result:
            raise McpProtocolError("initialize result missing protocolVersion")
        self._initialized = True

    # ------------------------------------------------------------------ surface
    def list_tools(self, *, force_refresh: bool = False) -> List[Dict[str, Any]]:
        if self._tools_cache is not None and not force_refresh:
            return list(self._tools_cache)
        if not self._initialized:
            raise McpProtocolError("client not initialized; call start() first")
        result = self._rpc("tools/list", {}, timeout=INITIALIZE_TIMEOUT)
        if not isinstance(result, dict) or "tools" not in result:
            raise McpProtocolError("tools/list result missing 'tools'")
        tools = result["tools"]
        if not isinstance(tools, list):
            raise McpProtocolError("tools/list returned non-list 'tools'")
        self._tools_cache = list(tools)
        return list(tools)

    def call_tool(
        self,
        name: str,
        arguments: Optional[Mapping[str, Any]] = None,
        *,
        timeout: float = DEFAULT_CALL_TIMEOUT,
    ) -> Dict[str, Any]:
        if not self._initialized:
            raise McpProtocolError("client not initialized; call start() first")
        params: Dict[str, Any] = {"name": name}
        if arguments is not None:
            params["arguments"] = dict(arguments)
        result = self._rpc("tools/call", params, timeout=timeout)
        if not isinstance(result, dict):
            raise McpProtocolError("tools/call result was not an object")
        return result


__all__ = [
    "ENV_ALLOWLIST",
    "ENV_DENYLIST",
    "DEFAULT_PROTOCOL_VERSION",
    "DEFAULT_CALL_TIMEOUT",
    "McpClient",
    "McpProtocolError",
    "filter_env",
]
