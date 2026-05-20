# Leptos / WASM Builder Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates/tools**: `leptos`, `leptos_router`, `wasm-bindgen`, `web-sys`, `gloo-net`, `tailwind_fuse`, `talc`, `smallvec`, `bytemuck`, `wasm-opt`

## Use Cases

- RustSkills Web UI, Web Builder, CRM dashboards, and agent orchestration consoles.
- SSR / hydration / route-level data loading with thin client bundles.
- Fine-grained UI state where Rust type boundaries improve correctness.

## Architecture

```text
SSR shell
  -> route-level data loading
  -> small reactive islands
  -> server functions for heavy logic
  -> gloo-net only for client API
  -> wasm-bindgen/web-sys minimal feature surface
```

## Engineering Rules

- Keep heavy logic, DB access, and most crypto on the server side.
- Hydrate only dynamic islands where possible.
- Keep signal granularity small; avoid global state that invalidates whole screens.
- Minimize JS/WASM boundary calls and prefer bulk transfer.
- Enable only required `web-sys` features.
- Use `tailwind_fuse` for safe Tailwind class composition.
- Treat `talc` as an A/B-tested allocator candidate, not a default assumption.

## Forbidden Patterns

- Shipping DB clients or heavy cryptographic workflows into the WASM bundle without explicit design review.
- Large global reactive state that causes wide invalidations.
- Many small JS/WASM crossings in hot interaction paths.
- Enabling broad browser API features without need.

## SLO / Review Metrics

- compressed WASM size.
- hydration time and first interaction time.
- route transition latency.
- signal invalidation count.
- JS/WASM boundary call count.
- runtime memory and allocator behavior.

## Update Checks

- Check Leptos, `wasm-bindgen`, `web-sys`, and browser API compatibility together.
- For allocator changes, compare bundle size, allocation behavior, runtime memory, and stability.
