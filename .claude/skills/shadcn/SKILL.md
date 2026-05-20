---
name: shadcn
description: Use when working with shadcn/ui components, registries, presets, components.json, shadcn CLI, shadcn MCP, or installing the official shadcn skill in a target frontend project.
---

# shadcn/ui

This is the lightweight RevHarness bootstrap for shadcn/ui. Current official
shadcn docs and the target project's `components.json` outrank this file.

## Workflow

1. Prefer installing the official shadcn skill in the target frontend project:

   ```bash
   pnpm dlx skills add shadcn/ui
   ```

   Use the target project's package manager. Record the fallback if the install
   is unavailable.

2. Use the shadcn CLI instead of guessing component APIs or copying raw files:

   ```bash
   pnpm dlx shadcn@latest info --json
   pnpm dlx shadcn@latest search @shadcn -q "<need>"
   pnpm dlx shadcn@latest docs <component-or-block>
   pnpm dlx shadcn@latest view <item>
   pnpm dlx shadcn@latest add <items> --dry-run
   pnpm dlx shadcn@latest add <items>
   ```

3. Preserve project facts from `info --json`: framework, package manager,
   aliases, base library, Tailwind version, icon library, installed components,
   and resolved paths.

4. Use existing components first. Compose shadcn primitives before writing
   custom markup.

5. For REV-C frontend UI/UX, also load
   `revc-shadcn-frontend-workflow`; it adds the React/Next security freshness
   gate and REV-C handoff checklist.

## Official Sources

- https://ui.shadcn.com/docs/skills
- https://ui.shadcn.com/docs/cli
- https://ui.shadcn.com/docs/mcp
- https://github.com/shadcn-ui/ui/tree/main/skills/shadcn
