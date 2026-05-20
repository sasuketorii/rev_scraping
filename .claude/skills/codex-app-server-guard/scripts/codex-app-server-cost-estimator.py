#!/usr/bin/env python3
"""Codex app-server usage and cost scenario estimator.

Two modes:
  1. JSON scenario mode:
     python codex-app-server-cost-estimator.py --template > scenario.json
     python codex-app-server-cost-estimator.py scenario.json --markdown

  2. Quick CLI mode:
     python codex-app-server-cost-estimator.py --turns-per-day 100 --avg-input-tokens 50000 \
       --avg-output-tokens 5000 --parallel-agents 2 --retry-multiplier 1.2 --days 30 \
       --input-price-per-1m 1.75 --output-price-per-1m 14.00

Prices and tool charges change. Always verify official pricing and your account limits.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict

TEMPLATE: Dict[str, Any] = {
    "monthly_active_users": 25,
    "threads_per_user_month": 20,
    "turns_per_thread": 6,
    "avg_input_tokens_per_turn": 6000,
    "avg_output_tokens_per_turn": 1500,
    "review_starts_per_thread": 1,
    "avg_review_input_tokens": 12000,
    "avg_review_output_tokens": 1500,
    "automatic_approval_review_rate": 0.2,
    "avg_auto_review_input_tokens": 2500,
    "avg_auto_review_output_tokens": 500,
    "command_execs_per_turn": 1.5,
    "avg_command_runtime_seconds": 4,
    "avg_stdout_stderr_kb": 20,
    "mcp_or_app_tool_calls_per_turn": 0.5,
    "websocket_reconnects_per_user_month": 20,
    "bot_multiplier": 10,
    "retry_loop_multiplier": 30,
    "prices_optional": {
        "input_per_million_tokens": None,
        "output_per_million_tokens": None,
        "log_storage_per_gb_month": None,
    },
}


def estimate_json_scenario(c: Dict[str, Any], multiplier: float = 1.0) -> Dict[str, Any]:
    users = c["monthly_active_users"] * multiplier
    threads = users * c["threads_per_user_month"]
    turns = threads * c["turns_per_thread"]
    input_tokens = turns * c["avg_input_tokens_per_turn"]
    output_tokens = turns * c["avg_output_tokens_per_turn"]
    reviews = threads * c["review_starts_per_thread"]
    review_input = reviews * c["avg_review_input_tokens"]
    review_output = reviews * c["avg_review_output_tokens"]
    auto_reviews = turns * c["automatic_approval_review_rate"]
    auto_review_input = auto_reviews * c["avg_auto_review_input_tokens"]
    auto_review_output = auto_reviews * c["avg_auto_review_output_tokens"]
    commands = turns * c["command_execs_per_turn"]
    command_seconds = commands * c["avg_command_runtime_seconds"]
    output_gb = commands * c["avg_stdout_stderr_kb"] / 1024 / 1024
    tool_calls = turns * c["mcp_or_app_tool_calls_per_turn"]
    reconnects = users * c["websocket_reconnects_per_user_month"]
    total_input = input_tokens + review_input + auto_review_input
    total_output = output_tokens + review_output + auto_review_output
    return {
        "users": round(users),
        "threads": round(threads),
        "turns": round(turns),
        "review_starts": round(reviews),
        "automatic_approval_reviews": round(auto_reviews),
        "input_tokens_total": round(total_input),
        "output_tokens_total": round(total_output),
        "command_execs": round(commands),
        "command_runtime_seconds": round(command_seconds, 1),
        "stdout_stderr_log_gb_minimum": round(output_gb, 4),
        "mcp_or_app_tool_calls": round(tool_calls),
        "websocket_reconnects": round(reconnects),
    }


def estimate_quick(args: argparse.Namespace, multiplier: float = 1.0) -> Dict[str, Any]:
    turns = args.turns_per_day * args.days * args.parallel_agents * multiplier
    input_tokens = turns * args.avg_input_tokens
    output_tokens = turns * args.avg_output_tokens
    return {
        "days": args.days,
        "turns_total": round(turns),
        "parallel_agents": args.parallel_agents,
        "input_tokens_total": round(input_tokens),
        "output_tokens_total": round(output_tokens),
        "estimated_input_cost": round(input_tokens / 1_000_000 * args.input_price_per_1m, 4),
        "estimated_output_cost": round(output_tokens / 1_000_000 * args.output_price_per_1m, 4),
        "estimated_total_cost": round((input_tokens / 1_000_000 * args.input_price_per_1m) + (output_tokens / 1_000_000 * args.output_price_per_1m), 4),
    }


def optional_cost(units: Dict[str, Any], prices: Dict[str, Any]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    def add(name: str, val: float | None) -> None:
        if val is not None:
            out[name] = round(val, 4)
    add("input_tokens", units["input_tokens_total"] / 1_000_000 * prices["input_per_million_tokens"] if prices.get("input_per_million_tokens") is not None else None)
    add("output_tokens", units["output_tokens_total"] / 1_000_000 * prices["output_per_million_tokens"] if prices.get("output_per_million_tokens") is not None else None)
    add("log_storage", units.get("stdout_stderr_log_gb_minimum", 0) * prices["log_storage_per_gb_month"] if prices.get("log_storage_per_gb_month") is not None else None)
    if out:
        out["total_optional"] = round(sum(out.values()), 4)
    return out


def print_markdown(scenarios: Dict[str, Dict[str, Any]]) -> None:
    print("# Codex App Server Usage/Cost Scenario Estimate")
    print("\nPrices are optional estimates. Verify current OpenAI pricing, rate limits, and project policy.\n")
    for name, data in scenarios.items():
        units = data.get("units", data)
        cost = data.get("optional_cost", {})
        print(f"## {name}")
        print("| Unit | Estimate |")
        print("|---|---:|")
        for k, v in units.items():
            print(f"| {k} | {v} |")
        if cost:
            print("\n| Cost component | Estimate |")
            print("|---|---:|")
            for k, v in cost.items():
                print(f"| {k} | {v} |")
        print()


def main() -> int:
    ap = argparse.ArgumentParser(description="Estimate Codex app-server runaway/cost scenarios.")
    ap.add_argument("scenario", nargs="?", help="JSON scenario file")
    ap.add_argument("--template", action="store_true", help="print JSON scenario template")
    ap.add_argument("--markdown", action="store_true", help="print markdown output")
    ap.add_argument("--turns-per-day", type=float, default=None)
    ap.add_argument("--avg-input-tokens", type=float, default=0)
    ap.add_argument("--avg-output-tokens", type=float, default=0)
    ap.add_argument("--parallel-agents", type=float, default=1)
    ap.add_argument("--retry-multiplier", type=float, default=1)
    ap.add_argument("--days", type=float, default=30)
    ap.add_argument("--input-price-per-1m", type=float, default=0)
    ap.add_argument("--output-price-per-1m", type=float, default=0)
    args = ap.parse_args()

    if args.template:
        print(json.dumps(TEMPLATE, ensure_ascii=False, indent=2))
        return 0

    if args.turns_per_day is not None:
        scenarios: Dict[str, Dict[str, Any]] = {
            "normal": estimate_quick(args, 1),
            f"retry_x{args.retry_multiplier}": estimate_quick(args, args.retry_multiplier),
            "bot_or_loop_x10": estimate_quick(args, 10),
        }
        if args.markdown:
            print_markdown(scenarios)
        else:
            print(json.dumps(scenarios, ensure_ascii=False, indent=2))
        return 0

    if not args.scenario:
        print("Provide scenario JSON, --template, or quick CLI arguments such as --turns-per-day.", file=sys.stderr)
        return 1

    c = json.loads(Path(args.scenario).read_text())
    prices = c.get("prices_optional", {})
    raw = {
        "normal": estimate_json_scenario(c, 1),
        f"bot_x{c.get('bot_multiplier', 10)}": estimate_json_scenario(c, c.get("bot_multiplier", 10)),
        f"retry_loop_x{c.get('retry_loop_multiplier', 30)}": estimate_json_scenario(c, c.get("retry_loop_multiplier", 30)),
    }
    scenarios = {k: {"units": v, "optional_cost": optional_cost(v, prices)} for k, v in raw.items()}
    if args.markdown:
        print_markdown(scenarios)
    else:
        print(json.dumps(scenarios, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
