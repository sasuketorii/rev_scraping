#!/usr/bin/env python3
"""PayloadCMS cost scenario estimator.

Outputs billable unit estimates, not authoritative prices. Fill provider rates if
needed. Always verify latest pricing with your hosting/database/storage/email/AI
providers before production.
"""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path

TEMPLATE = {
  "monthly_page_views": 100000,
  "api_requests_per_page": 2,
  "graphql_requests_per_month": 0,
  "avg_db_rows_read_per_api_request": 40,
  "avg_db_rows_written_per_mutation": 3,
  "monthly_mutations": 2000,
  "uploads_per_month": 1000,
  "avg_upload_mb": 2.0,
  "image_sizes_per_upload": 4,
  "avg_generated_image_mb": 0.35,
  "monthly_downloads": 100000,
  "avg_download_mb": 0.25,
  "jobs_per_month": 5000,
  "avg_job_runtime_seconds": 3.0,
  "external_email_per_job": 0.2,
  "ai_embedding_tokens_per_job": 0,
  "bot_multiplier": 20,
  "bug_retry_multiplier": 50,
  "prices_optional": {
    "hosting_per_million_requests": None,
    "hosting_per_gb_hour": None,
    "object_storage_per_gb_month": None,
    "object_storage_per_1000_put": None,
    "object_storage_per_1000_get": None,
    "egress_per_gb": None,
    "email_per_1000": None,
    "ai_per_million_tokens": None
  }
}

def estimate(cfg, multiplier=1):
    pv = cfg["monthly_page_views"] * multiplier
    api = pv * cfg["api_requests_per_page"] + cfg["graphql_requests_per_month"] * multiplier
    mutations = cfg["monthly_mutations"] * multiplier
    uploads = cfg["uploads_per_month"] * multiplier
    downloads = cfg["monthly_downloads"] * multiplier
    jobs = cfg["jobs_per_month"] * multiplier
    storage_upload_gb = uploads * cfg["avg_upload_mb"] / 1024
    storage_generated_gb = uploads * cfg["image_sizes_per_upload"] * cfg["avg_generated_image_mb"] / 1024
    egress_gb = downloads * cfg["avg_download_mb"] / 1024
    db_rows_read = api * cfg["avg_db_rows_read_per_api_request"]
    db_rows_written = mutations * cfg["avg_db_rows_written_per_mutation"]
    job_seconds = jobs * cfg["avg_job_runtime_seconds"]
    emails = jobs * cfg["external_email_per_job"]
    ai_tokens = jobs * cfg["ai_embedding_tokens_per_job"]
    return {
        "page_views": round(pv),
        "api_or_graphql_requests": round(api),
        "db_rows_read_estimate": round(db_rows_read),
        "db_rows_written_estimate": round(db_rows_written),
        "uploads": round(uploads),
        "object_puts_minimum": round(uploads * (1 + cfg["image_sizes_per_upload"])),
        "object_gets_downloads": round(downloads),
        "new_upload_storage_gb": round(storage_upload_gb, 3),
        "new_generated_image_storage_gb": round(storage_generated_gb, 3),
        "download_egress_gb": round(egress_gb, 3),
        "jobs": round(jobs),
        "job_runtime_seconds": round(job_seconds, 1),
        "emails": round(emails),
        "ai_tokens": round(ai_tokens),
    }

def optional_cost(units, prices):
    cost = {}
    def add(name, value):
        if value is not None:
            cost[name] = round(value, 4)
    add("hosting_requests", (units["api_or_graphql_requests"] / 1_000_000) * prices["hosting_per_million_requests"] if prices.get("hosting_per_million_requests") is not None else None)
    add("object_storage_month", (units["new_upload_storage_gb"] + units["new_generated_image_storage_gb"]) * prices["object_storage_per_gb_month"] if prices.get("object_storage_per_gb_month") is not None else None)
    add("object_puts", (units["object_puts_minimum"] / 1000) * prices["object_storage_per_1000_put"] if prices.get("object_storage_per_1000_put") is not None else None)
    add("object_gets", (units["object_gets_downloads"] / 1000) * prices["object_storage_per_1000_get"] if prices.get("object_storage_per_1000_get") is not None else None)
    add("egress", units["download_egress_gb"] * prices["egress_per_gb"] if prices.get("egress_per_gb") is not None else None)
    add("email", (units["emails"] / 1000) * prices["email_per_1000"] if prices.get("email_per_1000") is not None else None)
    add("ai", (units["ai_tokens"] / 1_000_000) * prices["ai_per_million_tokens"] if prices.get("ai_per_million_tokens") is not None else None)
    if cost:
        cost["total_optional"] = round(sum(cost.values()), 4)
    return cost

def md_table(name, units, cost):
    print(f"## {name}")
    print("| Unit | Estimate |")
    print("|---|---:|")
    for k, v in units.items():
        print(f"| {k} | {v} |")
    if cost:
        print("\n| Optional cost component | Estimate |")
        print("|---|---:|")
        for k, v in cost.items():
            print(f"| {k} | {v} |")
    print()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", nargs="?", help="JSON scenario file")
    ap.add_argument("--template", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()
    if args.template:
        print(json.dumps(TEMPLATE, ensure_ascii=False, indent=2))
        return 0
    if not args.scenario:
        print("Provide scenario JSON or --template", file=sys.stderr)
        return 1
    cfg = json.loads(Path(args.scenario).read_text())
    prices = cfg.get("prices_optional", {})
    scenarios = {
        "normal": estimate(cfg, 1),
        f"bot_x{cfg.get('bot_multiplier', 20)}": estimate(cfg, cfg.get("bot_multiplier", 20)),
        f"bug_retry_x{cfg.get('bug_retry_multiplier', 50)}": estimate(cfg, cfg.get("bug_retry_multiplier", 50)),
    }
    if args.markdown:
        print("# PayloadCMS Cost Scenario Estimate")
        print("\nProvider prices are optional and must be verified against official current pricing.\n")
        for name, units in scenarios.items():
            md_table(name, units, optional_cost(units, prices))
    else:
        print(json.dumps({k: {"units": v, "optional_cost": optional_cost(v, prices)} for k, v in scenarios.items()}, ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
