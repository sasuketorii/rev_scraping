---
name: revc-shadcn-frontend-workflow
description: Use when building, redesigning, experimenting with, or reviewing REV-C frontend UI/UX with shadcn/ui, the official shadcn skill, shadcn CLI/MCP, React, or Next.js. Enforces shadcn-first implementation and official React/Next security freshness checks before production UI work.
allowed-tools: Read, Bash, Grep, Glob
---

# REV-C Shadcn Frontend Workflow

Use this as the default REV-C frontend workflow for dashboards, portals,
admin screens, product pages, and componentized frontend work.

## Contract

- Start with the official shadcn skill and shadcn CLI/MCP before hand-writing
  custom components.
- Prefer official shadcn components, blocks, sidebar, forms, data table, cards,
  charts, dialogs, sheets, empty states, skeletons, alerts, badges, tabs, and
  navigation primitives.
- `DESIGN.md`, existing component conventions, and product-specific shell rules
  remain authoritative when the target repo defines them.
- Do not import `rev-ui-prebuild-mockup` for this workflow unless the user
  explicitly asks for pre-build mockup artifacts.
- Do not claim LGTM for React/Next UI work until the official freshness and
  security checks below are recorded.

## Required Freshness Gate

For any project using `next`, `react`, `react-dom`, React Server Components,
Server Actions, or framework-provided server functions:

1. Read `package.json`, lockfiles, framework config, `components.json`, and the
   existing app shell before choosing components or versions.
2. Check current official docs before production-impacting changes:
   - shadcn skills, CLI, and MCP docs
   - Next.js upgrading, security updates, and data-security docs
   - React security posts for React Server Components and React Server
     Functions
   - React `'use server'` security considerations when server functions exist
3. Compare installed `next`, `react`, `react-dom`, and RSC-related packages
   against the current official patched guidance or package registry output.
4. Run the target repo's package-manager audit when dependencies or server
   surfaces are in scope. Use the repo's package manager; do not mix package
   managers.
5. Treat Server Function arguments and form submissions as untrusted input.
   Require authentication, authorization, validation, escaping, and side-effect
   review for every mutation path.
6. Do not auto-upgrade dependencies outside the user-approved scope. If an
   upgrade is required for safety, report it as a blocker or include it in the
   reviewed implementation slice.

## Shadcn Setup

1. If the target project should use the official shadcn skill, install it in
   that project:

   ```bash
   pnpm dlx skills add shadcn/ui
   ```

   Use the project's package manager. If the install is unavailable, continue
   with the shadcn CLI/MCP workflow and record the fallback.

2. Inspect project context:

   ```bash
   pnpm dlx shadcn@latest info --json
   ```

3. Discover before building:

   ```bash
   pnpm dlx shadcn@latest search @shadcn -q "<need>"
   pnpm dlx shadcn@latest docs <component-or-block>
   pnpm dlx shadcn@latest view <item>
   pnpm dlx shadcn@latest add <items> --dry-run
   ```

4. Add only after the affected files and imports are understood:

   ```bash
   pnpm dlx shadcn@latest add <items>
   ```

5. If shadcn MCP is configured, use it for registry browse/search/install.
   Configure MCP only when the project or user asks for it; otherwise use the
   CLI fallback.

## Implementation Rules

- Use existing installed components first. Do not re-add components that already
  exist.
- Compose shadcn primitives instead of building custom `div` dashboards.
- Use semantic tokens and component variants before raw Tailwind color classes.
- Preserve actual aliases, icon library, Tailwind version, base library
  (`radix` or `base`), and resolved paths from `shadcn info --json`.
- Use demo data first when validating UX. Wire backend reads/writes only after
  the UI states, permissions, and data contracts are clear.
- Never invent backend mutations, destructive actions, privilege escalation
  paths, billing actions, exports, impersonation, or admin controls just because
  a UI block includes them.
- For destructive actions, require an AlertDialog-style confirmation and a
  server-side authorization note.
- Verify desktop and mobile screenshots, and light/dark mode when supported.
- Check Japanese, English, Chinese, and Korean label length and wrapping risks
  for nav, tabs, tables, buttons, cards, dialogs, badges, forms, and empty
  states.

## Output Checklist

Before handoff or reviewer request, record:

- shadcn skill install status or fallback
- shadcn context from `info --json`
- official React/Next/shadcn docs checked for this task
- installed vs current/patched package version notes
- preset, components, blocks, and sidebar items selected
- component map and state coverage
- demo data and backend boundary status
- audit/security findings or explicit not-in-scope reason
- screenshot coverage and remaining gaps
- multilingual length risks
- reviewer LGTM status before production merge
