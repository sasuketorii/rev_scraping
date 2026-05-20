# Frontend / Fullstack / Web Builder Reference

## Core stack

- React 19 / React DOM 19
- Next.js 16 for fullstack SaaS/dashboard
- Vite 8 for fast SPA/library/Web Builder dev
- TanStack Query/Router for cache and route typing
- Tailwind v4 + clsx + tailwind-merge for design system

## Web Builder lane

Use only when the product needs actual builder/editor behavior.

- CRDT collaboration: Yjs
- Managed realtime collaboration: Liveblocks
- Canvas/editor: tldraw
- Rich text: Lexical
- Drag/drop: dnd-kit
- Positioning: Floating UI
- A11y primitives: Radix UI
- Local state: Zustand/Jotai/XState depending on complexity

## Performance rules

- Measure Core Web Vitals using `web-vitals`.
- Avoid shipping heavy editor/canvas dependencies to routes that do not need them.
- Split by route and interaction island.
- Use Playwright visual/E2E tests for builder behavior.
- Track bundle budget per route, not only total app size.
