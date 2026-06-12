# Conditional Frontend Rules

This module is not incorporated into the default binding core. Read it only
when the active slice touches web frontend product code.

- [RS-FE-01] Frontend product work follows the active design system and local
  component patterns before introducing new UI primitives.
- [RS-FE-02] Use feature-complete controls, states, and views that a target
  user would naturally expect from the application.
- [RS-FE-03] Do not ship decorative landing-page structure when the request is
  for an actual app, tool, dashboard, game, or working product surface.
- [RS-FE-04] Use icons for common tool actions when an established icon library
  is already present.
- [RS-FE-05] Verify responsive layouts so text does not overflow or overlap on
  mobile and desktop viewports.
- [RS-FE-06] Accessibility, keyboard navigation, and contrast checks are part
  of frontend verification when user-facing UI changes are in scope. Frontend
  product work targets WCAG 2.2 AA unless the active slice explicitly narrows
  the target.
- [RS-FE-07] Frontend acceptance still comes from the active slice contract and
  `docs/manual/verification-truth-matrix.md`; this module does not create a
  separate acceptance path.
- [RS-FE-08] Conditional shadcn/ui work uses Next.js latest stable, App Router,
  Server Components by default, TypeScript, Tailwind, and ESLint unless the
  active project already has a stronger local stack contract.
- [RS-FE-09] Server state is fetched through Server Components or Route
  Handlers; use Client Components and TanStack Query only when client-side
  interactivity requires them.
- [RS-FE-10] Client Components are used only for hooks, event handlers, browser
  APIs, or isolated client-side interaction islands.
- [RS-FE-11] For shadcn/ui projects, prefer existing templates, official
  shadcn/ui components, and existing blocks; do not create bespoke component
  systems or custom CSS/style surfaces unless the active slice requires it.
- [RS-FE-12] For Japanese-facing UI, use natural Japanese, avoid translationese
  and unnecessary katakana, and follow Japanese form ordering conventions.
- [RS-FE-13] Use semantic HTML elements such as `<button>`, `<nav>`, `<main>`,
  and `<article>` for their intended roles.
- [RS-FE-14] All interactive elements must be keyboard-accessible and must show
  a visible focus state, using `focus-visible` where appropriate.
- [RS-FE-15] Icon-only buttons require `aria-label`.
- [RS-FE-16] Text contrast must meet at least 4.5:1 for normal text and 3:1
  for large text.
- [RS-FE-17] Important state changes should be announced with `aria-live` when
  the change is not otherwise exposed to assistive technology.
- [RS-FE-18] Drag-required interactions must provide a click or tap
  alternative, and touch targets must be at least 24x24px with 44x44px
  preferred.
- [RS-FE-19] Modals and dialogs require a focus trap, close on ESC when safe,
  and return focus to the opener after close.
- [RS-FE-20] Page transitions should move focus to the start of the new main
  content, and dynamic content should move focus appropriately or announce the
  change with `aria-live`.
- [RS-FE-21] Respect `prefers-reduced-motion: reduce`, provide stop controls
  for autoplaying content, and do not flash content more than three times per
  second.
- [RS-FE-22] Responsive implementation is mobile-first, uses min-width
  breakpoints, keeps touch targets at least 44x44px where practical, and avoids
  horizontal scrolling unless a table-like exception is explicit.
- [RS-FE-23] Frontend performance targets Core Web Vitals: LCP at or under
  2.5s, INP at or under 200ms, and CLS at or under 0.1.
- [RS-FE-24] Use `next/image`, WebP or AVIF where practical, `next/font`, code
  splitting, and static generation for pages that can be statically generated.
- [RS-FE-25] React/Next accessibility work must keep route changes announced,
  `aria-busy="true"` on loading states, and appropriate labels for skeleton UI.
- [RS-FE-26] When the active frontend stack uses Turbopack by default, do not
  add an explicit `--turbo` flag unless the local project contract requires it.
