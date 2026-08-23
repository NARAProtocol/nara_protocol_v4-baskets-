# NARA basket app

This directory contains the preview-first basket web application. The contract
package remains at the repository root.

## Status

The app is implemented but not activated for production basket purchases.
Value-bearing actions remain disabled until verified Base deployment manifests,
fresh addresses, explicit basket status values, and production environment
parity all pass.

## Required reading

1. [`AGENTS.md`](AGENTS.md)
2. [`DESIGN.md`](DESIGN.md)
3. [`../docs/UI_UX_NEUTRAL_ACTION_HIERARCHY.md`](../docs/UI_UX_NEUTRAL_ACTION_HIERARCHY.md)
4. [`../docs/NARA_INTEGRATION.md`](../docs/NARA_INTEGRATION.md)

## Local development

```powershell
npm ci
Copy-Item .env.example .env
npm run dev
```

Keep `.env` and `.dev.vars` local. Do not commit wallet identifiers, API keys,
private RPC URLs, deployment secrets, or production credentials.

## Verification

```powershell
npm run check
npm audit --audit-level=high
```

`npm run check:prod-env` and `npm run check:manifest-env` are intentionally
separate production gates. They must fail while verified production values and
manifests are absent.

## Deployment

GitHub is the only supported deployment entry point. A successful protected
`main` CI run automatically refreshes the fail-closed Cloudflare development
preview. Production promotion requires the `Pages production` workflow, an
exact signed commit already merged into `main`, a Change-ID, and the protected
GitHub production environment.

Read [`../docs/CLOUDFLARE_PAGES_RELEASES.md`](../docs/CLOUDFLARE_PAGES_RELEASES.md)
for one-time setup, environment variables, daily promotion, evidence, and
rollback. Do not use a local Wrangler command to publish production.

Production activation is not a routine contributor action. It remains blocked
until contract deployment, manifest verification, environment parity, required
CI, and the final review screen have all been verified.
