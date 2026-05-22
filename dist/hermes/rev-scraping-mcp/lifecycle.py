# SPDX-License-Identifier: MIT
# Source: new file for rev_scraping v1.2.0 (P7.1 Hermes adapter)
"""Lifecycle management for the stealth-mcp child process.

Provides restart-with-backoff (exponential 1/2/4/8/16s, cap at 16s) and
isolates the supervision logic from the JSON-RPC client in
:mod:`mcp_client`.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Callable, Optional

try:
    from .mcp_client import McpClient, McpProtocolError
except ImportError:  # standalone test load (no parent package)
    from mcp_client import McpClient, McpProtocolError  # type: ignore[no-redef]

# Exponential backoff schedule, cap at 16s. The final entry repeats
# indefinitely. Keeping this as an explicit tuple makes the schedule
# trivially testable.
BACKOFF_SCHEDULE_S: tuple[float, ...] = (1.0, 2.0, 4.0, 8.0, 16.0)
BACKOFF_CAP_S: float = 16.0
MAX_RESTART_ATTEMPTS: int = 32  # hard cap to surface persistent failure


class LifecycleError(RuntimeError):
    """Raised when the supervised child cannot be brought back to a healthy state."""


class SupervisedClient:
    """Wrap an :class:`McpClient` with restart-with-backoff semantics.

    Callers invoke :meth:`call_tool` / :meth:`list_tools` and the
    supervisor transparently recovers from one or more child crashes,
    sleeping per :data:`BACKOFF_SCHEDULE_S` between attempts. The retry
    loop terminates after :attr:`max_attempts` consecutive failures so a
    runaway crash does not block Hermes forever.
    """

    def __init__(
        self,
        client_factory: Callable[[], McpClient],
        *,
        max_attempts: int = MAX_RESTART_ATTEMPTS,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._factory = client_factory
        self._client: Optional[McpClient] = None
        self._lock = threading.Lock()
        self._restart_count = 0
        self._max_attempts = max_attempts
        self._sleep = sleep

    # ------------------------------------------------------------------ helpers
    @staticmethod
    def backoff_seconds(attempt: int) -> float:
        """Return backoff delay for ``attempt`` (0-indexed).

        Schedule: 1s, 2s, 4s, 8s, 16s, then 16s forever.
        """
        if attempt < 0:
            return 0.0
        if attempt < len(BACKOFF_SCHEDULE_S):
            return BACKOFF_SCHEDULE_S[attempt]
        return BACKOFF_CAP_S

    @property
    def restart_count(self) -> int:
        return self._restart_count

    def is_running(self) -> bool:
        return self._client is not None and self._client.is_running()

    # ------------------------------------------------------------------ lifecycle
    def start(self) -> None:
        with self._lock:
            self._ensure_started_locked()

    def stop(self) -> None:
        with self._lock:
            if self._client is not None:
                try:
                    self._client.stop()
                finally:
                    self._client = None

    def _ensure_started_locked(self) -> None:
        if self._client is not None and self._client.is_running():
            return
        # Discard a dead client before respawning.
        if self._client is not None:
            try:
                self._client.stop()
            except Exception:
                pass
            self._client = None
        last_exc: Optional[Exception] = None
        for attempt in range(self._max_attempts):
            if attempt > 0:
                self._sleep(self.backoff_seconds(attempt - 1))
                self._restart_count += 1
            client = self._factory()
            try:
                client.start()
            except Exception as exc:  # pragma: no cover - exercised via tests
                last_exc = exc
                try:
                    client.stop()
                except Exception:
                    pass
                continue
            self._client = client
            return
        raise LifecycleError(
            f"failed to start stealth-mcp after {self._max_attempts} attempts: {last_exc!r}"
        )

    # ------------------------------------------------------------------ surface
    def list_tools(self, *, force_refresh: bool = False) -> list[dict[str, Any]]:
        with self._lock:
            self._ensure_started_locked()
            assert self._client is not None
            try:
                return self._client.list_tools(force_refresh=force_refresh)
            except McpProtocolError:
                # Drop the dead client and surface; the next call will respawn.
                try:
                    self._client.stop()
                finally:
                    self._client = None
                raise

    def call_tool(
        self,
        name: str,
        arguments: Optional[dict[str, Any]] = None,
        *,
        timeout: Optional[float] = None,
    ) -> dict[str, Any]:
        with self._lock:
            self._ensure_started_locked()
            assert self._client is not None
            try:
                if timeout is None:
                    return self._client.call_tool(name, arguments)
                return self._client.call_tool(name, arguments, timeout=timeout)
            except McpProtocolError:
                try:
                    self._client.stop()
                finally:
                    self._client = None
                raise


__all__ = [
    "BACKOFF_SCHEDULE_S",
    "BACKOFF_CAP_S",
    "MAX_RESTART_ATTEMPTS",
    "LifecycleError",
    "SupervisedClient",
]
