# Edge Runtime / Workers Reference

## Purpose

Use this lane for Cloudflare Workers and other edge-runtime services where Web APIs, low cold start, and global distribution matter.

## Core packages

| Package | Version | Role |
|---|---:|---|
| wrangler | v4.86.0 | Cloudflare Workers CLI |
| miniflare | v4.20260430.0 | local Workers simulator |
| hono | v4.12.17 | edge-compatible API framework |

## Rules

- Keep Node-specific APIs out of edge code unless runtime supports them.
- Test with Miniflare and real preview deploy.
- Do not assume Node crypto, fs, net, or process availability.
- Put secret/config access behind runtime abstraction.
- Measure cold start and tail latency separately from Node services.
