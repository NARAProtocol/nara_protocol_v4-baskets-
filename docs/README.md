# NARA Basket Documentation

Start with the [project README](../README.md), then use this index for contract,
app, deployment, and maintenance detail.

## Read in this order

1. [`NARA_INTEGRATION.md`](NARA_INTEGRATION.md) — NARA v4 interfaces, fee
   routes, deployment order, and the canonical hooked-pool dependency.
2. [`RECEIPT_BASKET_FLOW.md`](RECEIPT_BASKET_FLOW.md) — buy, receipt, sell,
   withdrawal, and exact-accounting behavior.
3. [`EXAMPLE_BASKETS.md`](EXAMPLE_BASKETS.md) — launch composition templates.
4. [`../app/README.md`](../app/README.md) — preview app setup and fail-closed
   production gates.

5. [`CLOUDFLARE_PAGES_RELEASES.md`](CLOUDFLARE_PAGES_RELEASES.md) - GitHub-only
   development, production promotion, deployment evidence, and rollback.

## Operations and evidence

| Document | Purpose |
|---|---|
| [`SECURITY_CHECKLIST.md`](SECURITY_CHECKLIST.md) | Pre-deployment contract, role, route, app, and evidence gate |
| [`DEPLOYMENT_MANIFEST.md`](DEPLOYMENT_MANIFEST.md) | Sanitized manifest schema and post-deployment verification |
| [`VALIDATION_STATUS.md`](VALIDATION_STATUS.md) | Dated test, fork, analyzer, app, and known-gap evidence |
| [`ROUND_FLOW_RELEASE_GATE.md`](ROUND_FLOW_RELEASE_GATE.md) | Complete quote-to-zero-liability acceptance matrix and current blockers |
| [`releases/NARA-20260729-baskets-v2-alignment.md`](releases/NARA-20260729-baskets-v2-alignment.md) | Current cross-repository release state and downstream handoff |
| [`REPOSITORY_MAINTENANCE.md`](REPOSITORY_MAINTENANCE.md) | Mandatory source/config/app/documentation synchronization |
| [`UI_UX_NEUTRAL_ACTION_HIERARCHY.md`](UI_UX_NEUTRAL_ACTION_HIERARCHY.md) | Neutral action and legal UX guardrails |
| [`CLOUDFLARE_PAGES_RELEASES.md`](CLOUDFLARE_PAGES_RELEASES.md) | Cloudflare development, production, smoke, evidence, and rollback runbook |

## App rules

- [`../app/AGENTS.md`](../app/AGENTS.md) — implementation and cold-AI rules
- [`../app/DESIGN.md`](../app/DESIGN.md) — approved visual and interaction system
- [`../app/src/shared/baskets.ts`](../app/src/shared/baskets.ts) — app basket
  configuration and transaction builders
- [`../config/launch-baskets.json`](../config/launch-baskets.json) — contract/app
  composition parity source

## Related NARA repositories

- [NARA public documentation](https://github.com/NARAProtocol/nara_protocol)
- [NARA v4 engineering](https://github.com/NARAProtocol/nara_protocol_v4)

Security disclosure follows [`../SECURITY.md`](../SECURITY.md). Contributions
follow [`../CONTRIBUTING.md`](../CONTRIBUTING.md). The repository is licensed
under [`../LICENSE`](../LICENSE).
