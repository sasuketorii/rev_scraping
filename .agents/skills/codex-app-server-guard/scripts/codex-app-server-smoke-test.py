#!/usr/bin/env python3
"""Minimal local smoke test for codex app-server over stdio.

It starts `codex app-server`, sends initialize/initialized/thread/start/turn/start, and waits for a final turn.
Do not use against production workspaces or credentials without approval.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


def reader_thread(proc: subprocess.Popen[str], q: queue.Queue[dict[str, Any]]) -> None:
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            q.put(json.loads(line))
        except json.JSONDecodeError:
            q.put({"_decode_error": line[:500]})


def send(proc: subprocess.Popen[str], obj: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
    proc.stdin.flush()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["stdio"], default="stdio")
    p.add_argument("--message", default="Reply with OK only.")
    p.add_argument("--cwd", default=".", help="Workspace cwd for the thread. Use a non-production test workspace.")
    p.add_argument("--model", default=None, help="Optional model override; omit to use configured default")
    p.add_argument("--timeout", type=float, default=60.0)
    args = p.parse_args()

    codex = shutil.which("codex")
    if not codex:
        print("codex binary not found in PATH", file=sys.stderr)
        return 127

    cwd = str(Path(args.cwd).resolve())
    if not Path(cwd).exists():
        print(f"cwd does not exist: {cwd}", file=sys.stderr)
        return 2

    proc = subprocess.Popen(
        [codex, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=cwd,
        env={**os.environ, "RUST_LOG": os.environ.get("RUST_LOG", "warn")},
    )
    q: queue.Queue[dict[str, Any]] = queue.Queue()
    t = threading.Thread(target=reader_thread, args=(proc, q), daemon=True)
    t.start()

    try:
        send(proc, {"method": "initialize", "id": 1, "params": {"clientInfo": {"name": "codex-app-server-guard-smoke", "title": "Codex App Server Guard Smoke Test", "version": "0.1.0"}}})
        send(proc, {"method": "initialized", "params": {}})
        thread_params: dict[str, Any] = {"cwd": cwd, "approvalPolicy": "never", "sandbox": "readOnly", "serviceName": "codex-app-server-guard-smoke"}
        if args.model:
            thread_params["model"] = args.model
        send(proc, {"method": "thread/start", "id": 2, "params": thread_params})

        deadline = time.time() + args.timeout
        thread_id: str | None = None
        turn_started = False
        final_status = None
        messages: list[str] = []

        while time.time() < deadline:
            if proc.poll() is not None:
                break
            try:
                msg = q.get(timeout=0.5)
            except queue.Empty:
                continue

            if "_decode_error" in msg:
                print(f"decode_error: {msg['_decode_error']}")
                continue
            print(json.dumps(msg, ensure_ascii=False))

            if msg.get("id") == 2 and msg.get("result", {}).get("thread", {}).get("id"):
                thread_id = msg["result"]["thread"]["id"]
                send(proc, {"method": "turn/start", "id": 3, "params": {"threadId": thread_id, "input": [{"type": "text", "text": args.message}]}})
                turn_started = True
            if msg.get("method") == "item/agentMessage/delta":
                params = msg.get("params", {})
                delta = params.get("delta") or params.get("text") or ""
                if isinstance(delta, str):
                    messages.append(delta)
            if msg.get("method") == "turn/completed":
                turn = msg.get("params", {}).get("turn", {})
                final_status = turn.get("status")
                break

        if not turn_started:
            print("Smoke test failed: thread did not start or turn was not sent", file=sys.stderr)
            return 1
        if final_status not in {"completed", "interrupted"}:
            print(f"Smoke test failed: final status={final_status}", file=sys.stderr)
            return 1
        print(f"Smoke test finished with status={final_status}; streamed_text={''.join(messages)[:200]!r}")
        return 0
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        if proc.stderr:
            try:
                err = proc.stderr.read()
                if err.strip():
                    print("--- app-server stderr ---", file=sys.stderr)
                    print(err[-4000:], file=sys.stderr)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
