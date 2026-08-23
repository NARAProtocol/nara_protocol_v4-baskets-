# NARA-20260823-basket-ui-delivery

Change-ID: `NARA-20260823-basket-ui-delivery`

Origin remote: `https://github.com/NARAProtocol/nara_protocol_v4_baskets`

Evidence state: implemented and locally tested on an unmerged working tree.

## Scope

- Replace local/manual basket UI production uploads with GitHub-controlled
  development, production, smoke, and rollback workflows.
- Make the Cloudflare build entry point fail closed between `preview` and
  `activated` release modes.
- Compile Pages Functions in the canonical app gate.
- Embed exact commit, branch, and release-mode evidence in every artifact.
- Add post-deploy revision, asset, header, indexability, and Function checks.
- Add static security headers, immutable asset caching, and a valid favicon.
- Keep the basket app preview-only until verified manifests permit activation.

## Observed starting state

- `app.naraprotocol.com` returned an empty Cloudflare HTTP 404 on 2026-08-23.
- `nara-baskets.pages.dev` did not resolve. A later authenticated read-only
  account audit identified the actual project as `nara-v4-console-preview`.
- `app.naraprotocol.com` was already attached to that project, but its Git
  source was the obsolete `NARAProtocol/nara_protocol_v4` repository. Its latest
  production deployment reported success while its latest preview build had
  failed.
- GitHub had no deployment workflow, deployment records, environments, Actions
  variables, or Actions secrets for this repository.
- The only deploy entry was a manual local Wrangler command capable of labeling
  an arbitrary checkout as Cloudflare `main`.
- The current local feature branch was clean but divergent from `origin/main`;
  it was not deployed.

## Commands and results

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-nara-repository-routing.ps1
passed

npm run build:cf
passed: builders, copy, launch parity, TypeScript, Vite, Pages Functions,
distribution evidence, headers, and bundle ceilings

npx wrangler pages dev dist --port 4175 --ip 127.0.0.1
passed: Worker compiled and five header rules parsed

node scripts/check-deployment.mjs http://127.0.0.1:4175 --mode=preview
passed: HTTP 200, 14 local assets, release mode preview, Pages Function HTTP 400 boundary
```

## Deployment and security state

- Onchain or production writes: none.
- Cloudflare account write on 2026-08-23: disabled automatic production and
  preview Git deployments on `nara-v4-console-preview` and verified both flags
  as `false`. No deployment, domain, DNS record, binding, secret, or production
  artifact changed.
- GitHub configuration writes: created `cloudflare-development` and
  `cloudflare-production`; restricted production to protected branches; set the
  non-secret project and stable URL variables; bound required status checks to
  the GitHub Actions app.
- GitHub configuration still missing: Cloudflare account ID, least-privilege
  environment tokens, reviewed `VITE_*` values, and an optional production
  reviewer rule.
- Secrets printed: no.
- Contract source changes: none.
- Activated basket state: blocked as designed.
- Real-wallet and mobile-browser rows: not run in this change.

## Required downstream/account handoff

Follow [`../CLOUDFLARE_PAGES_RELEASES.md`](../CLOUDFLARE_PAGES_RELEASES.md) to
disable automatic builds from the obsolete Git source on
`nara-v4-console-preview`, finish the two GitHub environments, perform the first
guarded development deployment, and record its immutable evidence. Keep
`app.naraprotocol.com` attached to the existing project. Public documentation
must not claim the basket product is available until deployment, activation,
user-flow, and exit evidence all exist.
