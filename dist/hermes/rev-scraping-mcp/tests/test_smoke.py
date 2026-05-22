# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.2 Hermes smoke tests)
"""Stdlib-only smoke tests for the rev-scraping-mcp Hermes plugin.

These tests run with `python3 -m unittest discover tests -v` from the
plugin root. They mock the `stealth-mcp` subprocess so a real Rust build
is not required.

Coverage:
    * env scrubbing (allowlist + denylist + secret stripping)
    * initialize -> tools/list -> tools/call roundtrip
    * cookie value redaction across the schema bridge
    * schema_bridge passthrough of inputSchema / outputSchema
    * restart-with-backoff schedule
    * `register(ctx)` end-to-end with a fake Hermes ctx
"""

from __future__ import annotations

import io
import json
import os
import pathlib
import sys
import threading
import time
import unittest
from typing import Any, Callable, Dict, List, Optional
from unittest import mock

# Make the parent directory importable as the `rev_scraping_mcp` package.
_PLUGIN_DIR = pathlib.Path(__file__).resolve().parent.parent
_PACKAGE_PARENT = _PLUGIN_DIR.parent
if str(_PACKAGE_PARENT) not in sys.path:
    sys.path.insert(0, str(_PACKAGE_PARENT))

# Hermes installs the plugin under a dash-named directory but Python
# imports require the underscore form. We load the modules via
# importlib so the test does not depend on the install layout.
import importlib.util


def _load(short_name: str, relative_path: str) -> Any:
    """Load a sibling module under both a short name and a namespaced
    alias so the modules' own ``from mcp_client import ...`` fallbacks
    resolve via :data:`sys.modules` lookup.
    """
    spec = importlib.util.spec_from_file_location(
        short_name, _PLUGIN_DIR / relative_path
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[short_name] = mod
    sys.modules[f"rev_scraping_mcp_{short_name}"] = mod
    spec.loader.exec_module(mod)
    return mod


# Ensure the plugin dir is on sys.path so the fallback ``from
# mcp_client import ...`` inside lifecycle.py / __init__.py works during
# standalone test loading (no parent package present).
if str(_PLUGIN_DIR) not in sys.path:
    sys.path.insert(0, str(_PLUGIN_DIR))

# Order matters: schema_bridge -> mcp_client -> tool_proxy -> lifecycle.
schema_bridge = _load("schema_bridge", "schema_bridge.py")
mcp_client = _load("mcp_client", "mcp_client.py")
tool_proxy = _load("tool_proxy", "tool_proxy.py")
lifecycle = _load("lifecycle", "lifecycle.py")
plugin_init = _load("rev_scraping_mcp_init", "__init__.py")

# __init__.py imports siblings via "from .lifecycle import ..." which
# requires the parent to be a real package. Rather than fight the
# loader, we re-implement the tiny bit of `register` we need to smoke
# test in the test itself, using the modules we loaded above.


# ---------------------------------------------------------------- fake child


class FakePopen:
    """Mimic the subset of subprocess.Popen used by McpClient.

    Responds to MCP `initialize`, `tools/list`, and `tools/call` with
    canned payloads. Records `env=` so tests can assert env scrubbing.
    """

    last_instance: "Optional[FakePopen]" = None

    def __init__(
        self,
        argv: List[str],
        *,
        stdin: Any,
        stdout: Any,
        stderr: Any,
        env: Dict[str, str],
        text: bool,
        bufsize: int,
    ) -> None:
        self.argv = argv
        self.env = dict(env)
        self.text = text
        self._closed = False
        self._exit_code: Optional[int] = None
        # In-memory pipes.
        self._stdin_buf = io.StringIO()
        self.stdout = _PipeReader()
        self.stdin = _PipeWriter(self._on_line)
        self.stderr = io.StringIO()
        # Tool catalogue used in canned responses.
        self._tools = [
            {
                "name": "spider",
                "description": "Browse a URL under AUP.",
                "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}},
                "outputSchema": {"type": "object"},
            },
            {
                "name": "auth_login_start",
                "description": "Start auth.",
                "inputSchema": {"type": "object"},
            },
        ]
        self._call_log: List[Dict[str, Any]] = []
        FakePopen.last_instance = self

    @property
    def call_log(self) -> List[Dict[str, Any]]:
        return list(self._call_log)

    def _on_line(self, line: str) -> None:
        if not line.strip():
            return
        msg = json.loads(line)
        method = msg.get("method")
        rpc_id = msg.get("id")
        if method == "initialize":
            self._reply(rpc_id, {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "stealth-mcp", "version": "1.2.0"},
                "capabilities": {},
            })
        elif method == "tools/list":
            self._reply(rpc_id, {"tools": self._tools})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            arguments = params.get("arguments")
            self._call_log.append({"name": name, "arguments": arguments})
            # Echo a payload that contains a Cookie header so redaction
            # tests can assert the value is stripped.
            self._reply(rpc_id, {
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Set-Cookie: session_id=abc123secret; Path=/\n"
                            "ok"
                        ),
                    }
                ],
                "structuredContent": {
                    "tool": name,
                    "echo": arguments,
                    "cookie": "session_id=abc123secret",
                },
            })
        else:
            self._reply(rpc_id, None, error={"code": -32601, "message": f"method {method!r} not found"})

    def _reply(
        self,
        rpc_id: Any,
        result: Any,
        *,
        error: Optional[Dict[str, Any]] = None,
    ) -> None:
        frame: Dict[str, Any] = {"jsonrpc": "2.0", "id": rpc_id}
        if error is not None:
            frame["error"] = error
        else:
            frame["result"] = result
        self.stdout.feed(json.dumps(frame) + "\n")

    def poll(self) -> Optional[int]:
        return self._exit_code

    def wait(self, timeout: float = 0.0) -> int:
        self._exit_code = 0
        return 0

    def terminate(self) -> None:
        self._exit_code = -15

    def kill(self) -> None:
        self._exit_code = -9


class _PipeReader:
    def __init__(self) -> None:
        self._buf: List[str] = []
        self._cond = threading.Condition()

    def feed(self, line: str) -> None:
        with self._cond:
            self._buf.append(line)
            self._cond.notify_all()

    def readline(self) -> str:
        with self._cond:
            while not self._buf:
                # Non-blocking poll for the test path; FakePopen always
                # replies synchronously inside `_on_line`, so the buffer
                # is populated by the time readline() is invoked.
                return ""
            return self._buf.pop(0)

    def readable(self) -> bool:
        return True


class _PipeWriter:
    def __init__(self, on_line: Callable[[str], None]) -> None:
        self._on_line = on_line
        self._closed = False
        self._partial = ""

    def write(self, data: str) -> int:
        if self._closed:
            raise ValueError("write on closed pipe")
        self._partial += data
        while "\n" in self._partial:
            line, self._partial = self._partial.split("\n", 1)
            self._on_line(line)
        return len(data)

    def flush(self) -> None:
        return None

    def close(self) -> None:
        self._closed = True


# ---------------------------------------------------------------- tests


class EnvScrubbingTests(unittest.TestCase):
    def test_allowlist_passthrough(self) -> None:
        src = {
            "REV_SCRAPING_HOME": "/tmp/x",
            "VPN_INSTANCES": "vpn0",
            "PATH": "/usr/bin",
        }
        out = mcp_client.filter_env(src)
        self.assertEqual(out["REV_SCRAPING_HOME"], "/tmp/x")
        self.assertEqual(out["VPN_INSTANCES"], "vpn0")
        self.assertEqual(out["PATH"], "/usr/bin")

    def test_secrets_dropped(self) -> None:
        src = {
            "ANTHROPIC_API_KEY": "sk-leak",
            "OPENAI_API_KEY": "sk-leak2",
            "GITHUB_TOKEN": "ghp_leak",
            "AWS_SECRET_ACCESS_KEY": "leak",
            "REV_SCRAPING_HOME": "/tmp/x",
        }
        out = mcp_client.filter_env(src)
        for forbidden in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY"):
            self.assertNotIn(forbidden, out)
        self.assertIn("REV_SCRAPING_HOME", out)

    def test_unknown_keys_dropped(self) -> None:
        src = {"SOMETHING_ELSE": "v", "REV_SCRAPING_HOME": "/h"}
        out = mcp_client.filter_env(src)
        self.assertNotIn("SOMETHING_ELSE", out)


class JsonRpcRoundtripTests(unittest.TestCase):
    def _client(self) -> Any:
        return mcp_client.McpClient(
            binary="stealth-mcp",
            env={"PATH": "/usr/bin"},
            popen_factory=FakePopen,
        )

    def test_initialize_and_list_tools(self) -> None:
        c = self._client()
        c.start()
        tools = c.list_tools()
        self.assertEqual([t["name"] for t in tools], ["spider", "auth_login_start"])

    def test_tools_call_roundtrip(self) -> None:
        c = self._client()
        c.start()
        result = c.call_tool("spider", {"url": "https://example.org"})
        self.assertIn("content", result)
        self.assertEqual(result["structuredContent"]["tool"], "spider")

    def test_spawn_env_only_has_allowlisted_keys(self) -> None:
        c = self._client()
        c.start()
        env_seen = FakePopen.last_instance.env  # type: ignore[union-attr]
        self.assertEqual(env_seen, {"PATH": "/usr/bin"})


class RedactionTests(unittest.TestCase):
    def test_cookie_value_redacted_in_strings(self) -> None:
        s = "Set-Cookie: session_id=abc123secret; Path=/"
        out = schema_bridge.redact_response(s)
        self.assertNotIn("abc123secret", out)
        self.assertIn(schema_bridge.REDACTED_SENTINEL, out)
        self.assertIn("session_id", out)

    def test_cookie_field_redacted_in_dicts(self) -> None:
        payload = {"cookie": "session_id=abc123secret", "ok": True}
        out = schema_bridge.redact_response(payload)
        self.assertEqual(out["cookie"], schema_bridge.REDACTED_SENTINEL)
        self.assertTrue(out["ok"])

    def test_nested_secret_fields(self) -> None:
        payload = {
            "outer": {
                "Authorization": "Bearer abc123",
                "api_key": "k1",
                "data": [{"password": "p1"}, {"safe": "ok"}],
            }
        }
        out = schema_bridge.redact_response(payload)
        self.assertEqual(out["outer"]["Authorization"], schema_bridge.REDACTED_SENTINEL)
        self.assertEqual(out["outer"]["api_key"], schema_bridge.REDACTED_SENTINEL)
        self.assertEqual(out["outer"]["data"][0]["password"], schema_bridge.REDACTED_SENTINEL)
        self.assertEqual(out["outer"]["data"][1]["safe"], "ok")

    def test_raw_cookie_value_not_in_redacted_full_response(self) -> None:
        c = mcp_client.McpClient(
            binary="stealth-mcp",
            env={"PATH": "/usr/bin"},
            popen_factory=FakePopen,
        )
        c.start()
        raw = c.call_tool("spider", {"url": "https://example.org"})
        redacted = schema_bridge.redact_response(raw)
        as_text = json.dumps(redacted)
        self.assertNotIn("abc123secret", as_text)


class SchemaBridgeTests(unittest.TestCase):
    def test_passthrough_renames_keys(self) -> None:
        desc = {
            "name": "spider",
            "description": "Browse.",
            "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}},
            "outputSchema": {"type": "object"},
        }
        out = schema_bridge.mcp_tool_to_hermes(desc)
        self.assertEqual(out["name"], "spider")
        self.assertEqual(out["description"], "Browse.")
        self.assertEqual(out["input_schema"]["properties"]["url"]["type"], "string")
        self.assertEqual(out["output_schema"], {"type": "object"})

    def test_missing_input_schema_defaults_to_object(self) -> None:
        out = schema_bridge.mcp_tool_to_hermes({"name": "x"})
        self.assertEqual(out["input_schema"], {"type": "object"})
        self.assertNotIn("output_schema", out)


class BackoffTests(unittest.TestCase):
    def test_schedule_is_1_2_4_8_16_cap(self) -> None:
        sup = lifecycle.SupervisedClient(lambda: None)  # type: ignore[arg-type]
        self.assertEqual(sup.backoff_seconds(0), 1.0)
        self.assertEqual(sup.backoff_seconds(1), 2.0)
        self.assertEqual(sup.backoff_seconds(2), 4.0)
        self.assertEqual(sup.backoff_seconds(3), 8.0)
        self.assertEqual(sup.backoff_seconds(4), 16.0)
        self.assertEqual(sup.backoff_seconds(5), 16.0)
        self.assertEqual(sup.backoff_seconds(20), 16.0)


class ToolProxyTests(unittest.TestCase):
    def test_proxy_dispatches_through_invoker(self) -> None:
        seen: List[Any] = []

        def invoker(name: str, args: Optional[Dict[str, Any]]) -> Dict[str, Any]:
            seen.append((name, args))
            return {"ok": True, "name": name}

        p = tool_proxy.ToolProxy(
            {"name": "spider", "description": "d", "inputSchema": {"type": "object"}},
            invoker,
        )
        out = p({"url": "x"})
        self.assertEqual(out, {"ok": True, "name": "spider"})
        self.assertEqual(seen, [("spider", {"url": "x"})])
        self.assertEqual(p.name, "spider")
        self.assertEqual(p.input_schema, {"type": "object"})


class RegisterEntrypointTests(unittest.TestCase):
    """Smoke test the `register(ctx)` flow end-to-end with FakePopen."""

    def test_register_with_fake_ctx(self) -> None:
        # Build a minimal ctx that records register_tool calls.
        class Ctx:
            def __init__(self) -> None:
                self.calls: List[Dict[str, Any]] = []

            def register_tool(self, name: str, fn: Any, *, schema: Any, description: str) -> None:
                self.calls.append({"name": name, "fn": fn, "schema": schema, "description": description})

        ctx = Ctx()

        # Build the supervised client manually with FakePopen.
        def factory() -> Any:
            return mcp_client.McpClient(
                binary="stealth-mcp",
                env={"PATH": "/usr/bin"},
                popen_factory=FakePopen,
            )

        supervised = lifecycle.SupervisedClient(factory)
        supervised.start()
        descriptors = supervised.list_tools()

        def invoker(name: str, arguments: Optional[Dict[str, Any]]) -> Dict[str, Any]:
            return supervised.call_tool(name, arguments)

        proxies = tool_proxy.build_proxies(descriptors, invoker)
        for name, p in proxies.items():
            bridged = schema_bridge.mcp_tool_to_hermes(p.descriptor)
            ctx.register_tool(
                name,
                p,
                schema=bridged["input_schema"],
                description=bridged.get("description", ""),
            )

        self.assertEqual({c["name"] for c in ctx.calls}, {"spider", "auth_login_start"})

        # Invoke through the registered proxy and confirm we got a real
        # response back through the supervised client.
        spider_call = next(c for c in ctx.calls if c["name"] == "spider")
        result = spider_call["fn"]({"url": "https://example.org"})
        self.assertIn("content", result)
        supervised.stop()


class RealSubprocessTimeoutTests(unittest.TestCase):
    """Exercise the production select+os.read deadline path with a real subprocess.

    The probe spawns a tiny `python3 -c '...'` child that writes a
    partial JSON-RPC frame (no terminating newline) and then sleeps
    well past the timeout. The client must surface
    :class:`McpProtocolError` rather than wedging in ``readline()``.
    """

    def test_partial_frame_does_not_wedge_past_deadline(self) -> None:
        import shutil
        py = shutil.which("python3") or sys.executable
        self.assertTrue(py, "python3 must be on PATH for this test")
        # Child: emit `{` (no newline), flush, then sleep 30s.
        script = (
            "import sys, time;"
            "sys.stdout.buffer.write(b'{');"
            "sys.stdout.buffer.flush();"
            "time.sleep(30)"
        )
        # Inject argv via popen_factory wrapper so we can append `-c <script>`,
        # while forcing the production binary-I/O code path so the test
        # actually exercises select+os.read deadline handling rather than
        # the in-memory text fallback.
        original_popen = mcp_client.subprocess.Popen

        def factory(argv: List[str], **kwargs: Any) -> Any:
            return original_popen([argv[0], "-c", script], **kwargs)

        c = mcp_client.McpClient(binary=py, popen_factory=factory, binary_io=True)
        with mock.patch.object(mcp_client, "INITIALIZE_TIMEOUT", 0.3):
            start_t = time.monotonic()
            with self.assertRaises(mcp_client.McpProtocolError):
                c.start()
            raise_elapsed = time.monotonic() - start_t
            total_elapsed = time.monotonic() - start_t
        # Raise must happen near the configured deadline, well before
        # the child's 30s sleep. Allow a generous bound for subprocess
        # spawn + child-cleanup overhead on slow CI runners.
        self.assertLess(
            raise_elapsed,
            10.0,
            f"timeout did not fire in time: raise={raise_elapsed:.2f}s total={total_elapsed:.2f}s",
        )
        c.stop()

    def test_dead_child_no_fd_leak_after_start_failure(self) -> None:
        """If the child writes a partial frame and *exits*, start()'s
        stop(timeout=0.5) path must still close stdin/stdout/stderr.
        """
        import shutil
        py = shutil.which("python3") or sys.executable
        script = (
            "import sys;"
            "sys.stdout.buffer.write(b'{');"
            "sys.stdout.buffer.flush();"
            "sys.exit(0)"
        )
        original_popen = mcp_client.subprocess.Popen
        captured: List[Any] = []

        def factory(argv: List[str], **kwargs: Any) -> Any:
            p = original_popen([argv[0], "-c", script], **kwargs)
            captured.append(p)
            return p

        c = mcp_client.McpClient(binary=py, popen_factory=factory, binary_io=True)
        with self.assertRaises(mcp_client.McpProtocolError):
            c.start()
        self.assertTrue(captured)
        proc = captured[0]
        # All three parent-side pipes must be closed after start()'s
        # failure path runs stop(). The child has already exited
        # (sys.exit(0)) so the dead-child branch in stop() is what closes
        # stdin here.
        for stream_name in ("stdin", "stdout", "stderr"):
            stream = getattr(proc, stream_name, None)
            if stream is None:
                continue
            self.assertTrue(
                getattr(stream, "closed", False),
                f"{stream_name} still open after start() failure",
            )


class TimeoutTests(unittest.TestCase):
    """A silent child must fail with a timeout instead of wedging forever."""

    def test_silent_child_times_out(self) -> None:
        class SilentPopen(FakePopen):
            def _on_line(self, line: str) -> None:
                # Swallow the request; never reply.
                return None

        c = mcp_client.McpClient(
            binary="stealth-mcp",
            env={"PATH": "/usr/bin"},
            popen_factory=SilentPopen,
        )
        # start() runs initialize, which must time out via the deadline path.
        # Monkey-patch INITIALIZE_TIMEOUT down to keep the test fast.
        with mock.patch.object(mcp_client, "INITIALIZE_TIMEOUT", 0.1):
            with self.assertRaises(mcp_client.McpProtocolError):
                c.start()


class EnvOverrideFilteringTests(unittest.TestCase):
    """A caller-supplied `env=` is also filtered through filter_env()."""

    def test_explicit_env_override_is_filtered(self) -> None:
        c = mcp_client.McpClient(
            binary="stealth-mcp",
            env={
                "PATH": "/usr/bin",
                "ANTHROPIC_API_KEY": "sk-should-be-stripped",
                "OPENAI_API_KEY": "sk-also-stripped",
                "REV_SCRAPING_HOME": "/tmp/x",
            },
            popen_factory=FakePopen,
        )
        c.start()
        env_seen = FakePopen.last_instance.env  # type: ignore[union-attr]
        self.assertNotIn("ANTHROPIC_API_KEY", env_seen)
        self.assertNotIn("OPENAI_API_KEY", env_seen)
        self.assertIn("PATH", env_seen)
        self.assertIn("REV_SCRAPING_HOME", env_seen)


class RegisterRedactionTests(unittest.TestCase):
    """End-to-end test that `register()` wires redaction into the invoker."""

    def test_register_invoker_redacts_cookie_values(self) -> None:
        class Ctx:
            def __init__(self) -> None:
                self.calls: List[Dict[str, Any]] = []

            def register_tool(self, name: str, fn: Any, *, schema: Any, description: str) -> None:
                self.calls.append({"name": name, "fn": fn})

        ctx = Ctx()

        # Patch McpClient constructor inside the plugin_init module so
        # the SupervisedClient factory yields a FakePopen-backed client.
        real_McpClient = plugin_init.McpClient

        def fake_McpClient(binary: str, *, protocol_version: str = mcp_client.DEFAULT_PROTOCOL_VERSION, env: Any = None) -> Any:
            return real_McpClient(
                binary=binary,
                protocol_version=protocol_version,
                env={"PATH": "/usr/bin"},
                popen_factory=FakePopen,
            )

        with mock.patch.object(plugin_init, "McpClient", fake_McpClient):
            summary = plugin_init.register(ctx)

        self.assertGreaterEqual(summary["tool_count"], 1)
        spider_call = next(c for c in ctx.calls if c["name"] == "spider")
        result = spider_call["fn"]({"url": "https://example.org"})
        as_text = json.dumps(result)
        # The FakePopen response embeds the literal `abc123secret`; after
        # redaction it must not appear anywhere in the proxied response.
        self.assertNotIn("abc123secret", as_text)
        self.assertIn(schema_bridge.REDACTED_SENTINEL, as_text)
        summary["supervised"].stop()


if __name__ == "__main__":
    unittest.main()
