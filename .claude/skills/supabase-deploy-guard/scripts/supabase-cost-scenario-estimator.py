#!/usr/bin/env python3
"""Supabase rough cost scenario estimator.

This is a planning helper, not a billing guarantee. Verify all quotas and unit
prices in the official Supabase pricing/usage docs before relying on numbers.
Defaults approximate Pro/Team public docs around 2026-05.
"""
from __future__ import annotations

import argparse
import math

COMPUTE_HOURLY = {
    "nano": 0.0,
    "micro": 0.01344,
    "small": 0.0206,
    "medium": 0.0822,
    "large": 0.1517,
    "xl": 0.2877,
    "2xl": 0.562,
    "4xl": 1.32,
    "8xl": 2.562,
}
QUOTAS = {
    "egress_gb": 250.0,
    "storage_gb": 100.0,
    "edge_invocations": 2_000_000.0,
    "mau": 100_000.0,
    "third_party_mau": 100_000.0,
    "sso_mau": 50.0,
    "realtime_messages": 5_000_000.0,
    "realtime_peak_connections": 500.0,
    "image_origin_images": 100.0,
}
RATES = {
    "egress_gb": 0.09,
    "storage_gb": 0.021,
    "edge_per_million": 2.0,
    "mau": 0.00325,
    "third_party_mau": 0.00325,
    "sso_mau": 0.015,
    "realtime_messages_per_million": 2.50,
    "realtime_connections_per_1000": 10.0,
    "image_per_1000": 5.0,
    "log_drain_hour": 0.0822,
    "log_drain_events_per_million": 0.20,
}


def over(value: float, quota: float) -> float:
    return max(0.0, value - quota)


def packages(value: float, size: float) -> int:
    return int(math.ceil(value / size)) if value > 0 else 0


def usd(value: float) -> str:
    return f"${value:,.2f}"


def main() -> int:
    p = argparse.ArgumentParser(description="Estimate Supabase usage-risk scenario costs.")
    p.add_argument("--hours", type=float, default=744)
    p.add_argument("--compute-size", choices=sorted(COMPUTE_HOURLY), default="micro")
    p.add_argument("--projects", type=int, default=1)
    p.add_argument("--branches", type=int, default=0)
    p.add_argument("--replicas", type=int, default=0)
    p.add_argument("--egress-gb", "--egress-uncached-gb", dest="egress_gb", type=float, default=0)
    p.add_argument("--storage-gb", type=float, default=0)
    p.add_argument("--edge-invocations", type=float, default=0)
    p.add_argument("--mau", type=float, default=0)
    p.add_argument("--third-party-mau", type=float, default=0)
    p.add_argument("--sso-mau", type=float, default=0)
    p.add_argument("--realtime-messages", type=float, default=0)
    p.add_argument("--realtime-peak-connections", type=float, default=0)
    p.add_argument("--image-origin-images", type=float, default=0)
    p.add_argument("--log-drains", type=int, default=0)
    p.add_argument("--log-drain-events", type=float, default=0)
    args = p.parse_args()

    active_compute = args.projects + args.branches + args.replicas
    rows: list[tuple[str, str, float, str]] = []
    rows.append(("Compute/Branch/Replica", f"{active_compute}×{args.compute_size}×{args.hours}h", active_compute * COMPUTE_HOURLY[args.compute_size] * args.hours, "Spend Cap対象外になり得る"))
    egress_over = over(args.egress_gb, QUOTAS["egress_gb"])
    rows.append(("Egress", f"over {egress_over:g} GB", egress_over * RATES["egress_gb"], "Bot・exports・Storage hotlink注意"))
    storage_over = over(args.storage_gb, QUOTAS["storage_gb"])
    rows.append(("Storage", f"over {storage_over:g} GB", storage_over * RATES["storage_gb"], "uploads/retention注意"))
    edge_over = over(args.edge_invocations, QUOTAS["edge_invocations"])
    rows.append(("Edge Functions", f"{packages(edge_over, 1_000_000)}×1M packages", packages(edge_over, 1_000_000) * RATES["edge_per_million"], "status code問わずinvocation課金"))
    mau_over = over(args.mau, QUOTAS["mau"])
    rows.append(("Auth MAU", f"over {mau_over:g}", mau_over * RATES["mau"], "signup/token refresh loop注意"))
    third_over = over(args.third_party_mau, QUOTAS["third_party_mau"])
    rows.append(("Third-party MAU", f"over {third_over:g}", third_over * RATES["third_party_mau"], "OAuth abuse注意"))
    sso_over = over(args.sso_mau, QUOTAS["sso_mau"])
    rows.append(("SSO MAU", f"over {sso_over:g}", sso_over * RATES["sso_mau"], "企業向けログイン注意"))
    rt_msg_over = over(args.realtime_messages, QUOTAS["realtime_messages"])
    rows.append(("Realtime messages", f"{packages(rt_msg_over, 1_000_000)}×1M packages", packages(rt_msg_over, 1_000_000) * RATES["realtime_messages_per_million"], "fanout/reconnect注意"))
    rt_conn_over = over(args.realtime_peak_connections, QUOTAS["realtime_peak_connections"])
    rows.append(("Realtime peak connections", f"{packages(rt_conn_over, 1000)}×1000 packages", packages(rt_conn_over, 1000) * RATES["realtime_connections_per_1000"], "tab増殖/reconnect storm注意"))
    img_over = over(args.image_origin_images, QUOTAS["image_origin_images"])
    rows.append(("Image transformations", f"{packages(img_over, 1000)}×1000 origin images", packages(img_over, 1000) * RATES["image_per_1000"], "origin image数・Bot注意"))
    log_cost = args.log_drains * args.hours * RATES["log_drain_hour"] + packages(args.log_drain_events, 1_000_000) * RATES["log_drain_events_per_million"]
    rows.append(("Log Drains", f"{args.log_drains} drains, {packages(args.log_drain_events, 1_000_000)}×1M events", log_cost, "Spend Cap対象外"))

    total = sum(row[2] for row in rows)
    print("# Supabase Cost Scenario Estimate")
    print("\n価格は概算です。公式Pricing/Usage docsで最新値を確認してください。\n")
    print("| item | basis | estimated cost | note |")
    print("|---|---:|---:|---|")
    for item, basis, cost, note in rows:
        print(f"| {item} | {basis} | {usd(cost)} | {note} |")
    print(f"| **Total scenario** |  | **{usd(total)}** | base plan/credits/external costs別 |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
