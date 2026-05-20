# Observability / Governance Reference

## Observability

- Structured logs: pino.
- Tracing: OpenTelemetry.
- Metrics: prom-client.
- Errors: Sentry.
- Frontend UX metrics: web-vitals.

## Supply chain governance

- Lockfile: `pnpm-lock.yaml` committed.
- Advisory checks: `pnpm audit`, `npm audit`, OSV-Scanner, GitHub Advisory.
- Dependency automation: Renovate PRs, never silent auto-merge for major/security-sensitive updates.
- Update planning: npm-check-updates for planning only.
- Package quality: publint, @arethetypeswrong/cli, tsd.
- Dead code/deps: knip.
- Import boundaries: dependency-cruiser.
- Provenance: npm trusted publishing/provenance for packages.

## Update command set

```bash
pnpm outdated --recursive
pnpm dlx npm-check-updates --target latest --format group
pnpm audit --audit-level high
pnpm dlx osv-scanner scan --lockfile pnpm-lock.yaml
pnpm exec knip
pnpm exec publint
pnpm exec attw --pack .
```

## Review checklist

- Does the package require a newer Node version?
- Is the version stable, or rc/canary/beta?
- Did package name/scope change?
- Are transitive advisories introduced?
- Does the update change ESM/CJS/package exports?
- Does the update affect bundle size or edge compatibility?
- Is rollback easy from lockfile?
