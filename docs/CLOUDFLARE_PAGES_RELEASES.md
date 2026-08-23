# Cloudflare Pages release system

Change-ID: `NARA-20260823-basket-ui-delivery`

This is the operating procedure for the publishable basket app in `app/`.
GitHub is the only release entry point. Local Wrangler production uploads are
not part of the supported flow.

## Release lanes

| Lane | Source | Cloudflare branch | Stable URL | Release behavior |
|---|---|---|---|---|
| Development | Latest protected `main` commit whose `Baskets CI` push run passed | `development` | `https://development.nara-v4-console-preview.pages.dev` or the configured development domain | Automatic, preview-only, no buys or exits, `noindex` |
| Production | A full signed commit SHA already merged into protected `main` | `main` | `https://app.naraprotocol.com` | Manual GitHub workflow plus `cloudflare-production` environment approval |
| Ad hoc check | Any deployed URL | n/a | Workflow input | Read-only smoke verification only |

The development lane uses a Cloudflare branch alias, not a second source
branch. This avoids `develop`/`main` merge drift while preserving a stable place
to review the newest green version.

## Safety modes

`NARA_RELEASE_MODE` is fail closed:

- `preview` is the default. Every `VITE_BASKET_STATUS_*` value must be empty or
  `preview`. The built page is marked `noindex, nofollow, noarchive`.
- `activated` is restricted to Cloudflare branch `main`. It must pass
  `check:prod-env` and `check:manifest-env` before the build starts.

The current production gate deliberately rejects `live` basket statuses. Do
not weaken that lock until verified basket deployment manifests, the exact Base
round-flow evidence, roles, routes, and environment parity are committed and
reviewed. Serving a preview UI at the production hostname is allowed; enabling
value-bearing actions is not.

## One-time Cloudflare setup

These steps require a human Cloudflare account owner. They are account changes,
not contract deployments.

The read-only Cloudflare account audit on 2026-08-23 proved that the existing
project is `nara-v4-console-preview`, its production branch is `main`, and
`app.naraprotocol.com` is already attached. The project is still Git-connected
to the obsolete `NARAProtocol/nara_protocol_v4` source rather than the
authoritative `NARAProtocol/nara_protocol_v4_baskets` repository. Cloudflare
supports Wrangler uploads to an existing Git-integrated Pages project after its
automatic builds are disabled, so preserve the project and domain instead of
creating a second project.

1. Automatic production and preview deployments from the obsolete Git source
   were disabled through the authenticated Cloudflare API on 2026-08-23 and
   verified as `false`. Keep both controls disabled so obsolete Git builds and
   GitHub Actions uploads cannot race each other.
2. Run one development deployment from the guarded GitHub workflow. Confirm
   that `development.nara-v4-console-preview.pages.dev` resolves and passes
   `Deployment smoke`.
3. Keep `app.naraprotocol.com` attached to `nara-v4-console-preview`. Do not
   create another project or move the domain unless a separately reviewed
   migration requires it.
4. Optionally attach `dev.app.naraprotocol.com` to the `development` branch
   alias. Put the development/preview URLs behind Cloudflare Access when they
   should be team-only.
5. Configure runtime variables and secrets separately for Preview and
   Production. A changed binding or secret requires a new deployment before it
   can be verified.

Use a least-privilege API token limited to Pages writes for only the intended
Cloudflare account. Never use a Global API Key.

Official references:

- [Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)
- [Preview deployments and branch aliases](https://developers.cloudflare.com/pages/configuration/preview-deployments/)
- [Pages rollbacks](https://developers.cloudflare.com/pages/configuration/rollbacks/)
- [Pages Functions bindings and secrets](https://developers.cloudflare.com/pages/functions/bindings/)

## One-time GitHub setup

Create these GitHub environments:

### `cloudflare-development`

- No production approval requirement.
- Secret: `CLOUDFLARE_API_TOKEN`.
- Variables: `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_PAGES_PROJECT`, and
  `CLOUDFLARE_DEVELOPMENT_URL`.
- Use environment variables for the public `VITE_*` values listed below.
- Basket status values are ignored by the workflow and forced to `preview`.

### `cloudflare-production`

- Restrict deployment branches to protected `main`.
- Require the `NARAProtocol` maintainer reviewer. Self-review remains permitted
  for the solo maintainer, but administrator bypass is disabled.
- Secret: a separate least-privilege `CLOUDFLARE_API_TOKEN`.
- Variables: `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_PAGES_PROJECT`,
  `CLOUDFLARE_PRODUCTION_URL`, and the reviewed public `VITE_*` configuration.

Set `CLOUDFLARE_PAGES_PROJECT=nara-v4-console-preview`,
`CLOUDFLARE_DEVELOPMENT_URL=https://development.nara-v4-console-preview.pages.dev`, and
`CLOUDFLARE_PRODUCTION_URL=https://app.naraprotocol.com` unless the Cloudflare
project evidence proves different values.

As verified on 2026-08-23, both environments exist, production is limited to
protected branches, the `NARAProtocol` production reviewer is required, and
administrator bypass is disabled. The project and stable URL variables are set;
the account ID and environment secrets remain intentionally unset until fresh
credentials replace the exposed credentials.

The Actions workflows accept these public build variables:

```text
VITE_RAINBOW_PROJECT_ID
VITE_WALLETCONNECT_PROJECT_ID
VITE_BASKET_MANAGER_BASE
VITE_BASKET_MANAGER_AI
VITE_BASKET_MANAGER_MEME
VITE_BASKET_MANAGER_DEFI
VITE_BASKET_STATUS_BASE
VITE_BASKET_STATUS_AI
VITE_BASKET_STATUS_MEME
VITE_BASKET_STATUS_DEFI
VITE_BASKET_ADAPTER
VITE_BASKET_ADAPTER_AERO
VITE_BASKET_ADAPTER_SLIPSTREAM
VITE_BASKET_ADAPTER_PANCAKE
VITE_BASKET_ADAPTER_V4
VITE_NARA_V4_HOOK
VITE_NARA_V4_POOL_FEE
VITE_NARA_V4_TICK_SPACING
VITE_UNISWAP_V4_QUOTER
VITE_NARA_TOKEN
VITE_NARA_FEE_COLLECTOR
VITE_CDP_PAYMASTER_URL
```

Every `VITE_*` value is public in the browser bundle. Never put credentials or
private RPC keys in one. The Cloudflare Pages runtime must separately receive
the Function bindings it uses, including `CG_API_PLAN` and `VITE_NARA_TOKEN`.
Keep `CG_API_KEY`, `CDP_API_KEY_ID`, and `CDP_API_KEY_SECRET` as encrypted
Cloudflare secrets.

Do not provision the CDP secrets until all of these are true:

- `ONRAMP_ALLOWED_ORIGINS` contains the exact production origin;
- a Cloudflare WAF rate-limit rule covers `POST /api/onramp-token`;
- the upstream key is restricted and has an explicit budget; and
- the 503, 403, 400, and successful session-token paths have been tested.

## Everyday workflow

1. Create a focused feature branch from current `origin/main`.
2. Open a pull request. Required repository, contract, app, analyzer, and CodeQL
   checks must pass.
3. Merge through protected `main`. Never deploy the pull-request working tree.
4. `Pages development` waits for the successful `Baskets CI` push run, checks
   out that exact SHA, rebuilds it in preview mode, deploys the Cloudflare
   `development` branch, and verifies both immutable and stable URLs.
5. Review the stable development URL, including 375px and 390x844 mobile views,
   wallet connection, bounded errors, and the expected preview-only controls.
6. When satisfied, open Actions > `Pages production` > Run workflow. Paste the
   full signed `main` SHA and Change-ID. Use `preview` until activation evidence
   exists.
7. Approve the `cloudflare-production` environment. The workflow verifies the
   SHA is on `main` and GitHub-verified, builds the exact checkout, deploys it,
   records deployment evidence, and proves the custom domain serves that SHA.

Each built HTML file contains:

- `nara-build-commit`;
- `nara-build-branch`; and
- `nara-release-mode`.

The verifier rejects a stable alias that has not yet moved to the expected
commit, so a successful workflow is evidence of the deployed revision rather
than only evidence that an upload command exited successfully.

## Rollback

1. Identify a prior successful production deployment ID and its full commit SHA
   in the `Pages production` job summary or Cloudflare deployment history.
2. Open Actions > `Pages rollback`.
3. Enter the deployment UUID, expected SHA, release mode, and incident reason.
4. Approve the `cloudflare-production` environment.
5. The workflow verifies the target is a successful production deployment,
   calls the Cloudflare rollback endpoint, and checks the user-facing domain for
   the restored SHA.

Never roll production back to a preview deployment; Cloudflare does not support
that boundary. If the previous production artifact is unsuitable, fix forward
from a new protected commit.

## Required verification

Local release check:

```powershell
npm ci --prefix app
npm run build:cf --prefix app
npm audit --prefix app --audit-level=high
```

Local Pages runtime check:

```powershell
Set-Location app
npx wrangler pages dev dist --port 4175 --ip 127.0.0.1
node scripts/check-deployment.mjs http://127.0.0.1:4175 --mode=preview
```

Deployed check:

```powershell
npm run check:deployment --prefix app -- https://development.nara-v4-console-preview.pages.dev --mode=preview --sha=<full-commit>
```

The check requires the application shell, local assets, baseline security
headers, release metadata, correct indexability, and the `/api/pairs` Pages
Function boundary.

## Recovery and troubleshooting

- Empty 404 at `app.naraprotocol.com`: verify the Pages custom-domain
  association and remove the obsolete Worker route/origin. A DNS record alone
  is insufficient.
- Development deployment does not start: confirm `Baskets CI` was a successful
  `push` run on `main`; pull-request runs intentionally do not deploy.
- Wrangler authentication error: verify the environment-scoped token and
  account ID. Do not move the token to repository variables.
- Stable URL serves the wrong commit: wait for the smoke retries, then inspect
  the immutable deployment URL and branch alias. Do not promote.
- Function is missing: run `npm run build:functions --prefix app` and confirm
  the `functions/` directory is present in the exact release commit.
- Preview deploy attempts a transaction: treat this as a release blocker. The
  `check:preview-env` gate and UI status normalization must both remain intact.

## Account-state evidence

The 2026-08-23 OAuth audit recorded the project name, production branch,
obsolete Git source, custom-domain association, configuration names, and latest
deployment states without recording account IDs, deployment UUIDs, or secret
values. The latest production deployment reported success; the latest preview
deployment reported a build failure. The same authenticated session disabled
automatic production and preview Git deployments and verified both flags as
`false`; it did not change a deployment, domain, DNS record, binding, secret, or
production artifact. Before the first guarded release, record the
least-privilege token scope, development deployment ID, and production rollback
target without recording any secret values.
