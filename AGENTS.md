# NARA Category Baskets Agent Rules

This repository contains the separate Foundry contract package and the
preview-first basket app under `app/`. It is not part of the Hardhat
`contracts/v4/` compile path.

## Cross-Repository Role

This repository is the authority for basket contracts, adapters, basket
configuration, basket deployment manifests, and the publishable app under
`app/`.

`NARAProtocol/nara_protocol_v4` is upstream for protocol ABIs, addresses, pool
bindings, engine behavior, and deployment state. Do not integrate from its
dirty working tree or a planned address. Require a full merged origin commit
for code behavior and a verified sanitized manifest for deployed state.

After a basket release or deployment, update `nara-swarm-monitor` when basket
events or addresses must be indexed, then update `nara_protocol` public
documentation when the user-visible state changes. The local
`../apps/nara-baskets/` folder is not the publishable Git target.

In the FIELD workspace, the complete order and handoff schema are in
`../docs/NARA_CROSS_REPOSITORY_RELEASE_PROTOCOL.md`.

## Required Maintenance Protocol

Before changing code-derived, deployment-derived, or user-facing facts, read and
follow [`docs/REPOSITORY_MAINTENANCE.md`](docs/REPOSITORY_MAINTENANCE.md).
Code, verified manifests, app configuration, and documentation must remain
synchronized in the same pull request.

## Status

- Basket contracts are active v4-adjacent product code, but deployment status
  must be verified before making live claims.
- The app is implemented but must remain in preview until verified Base
  deployment manifests and production environment parity pass.
- This package integrates with active NARA v4 only through deployed addresses
  and fee routes documented in this repo.
- If a folder or deployment status is unclear, mark it unknown and verify before
  use.

## Basket Design Boundaries

- Baskets are user-selected category exposures with ERC-721 receipts.
- Do not connect baskets to mining.
- Do not connect baskets to jackpot/lotto logic.
- Do not assume basket yield unless active code and deployment docs prove it.
- Do not make baskets custodial unless explicitly designed, documented, and
  audited.
- Do not imply managed-investment or recommendation behavior.
- Follow the workspace neutral action hierarchy for any UI or user-facing docs.
- Read `app/AGENTS.md` and `app/DESIGN.md` before changing the app.

## Integration Rules

- Do not edit NARA v4 core contracts from this package.
- Do not import retired v3 contracts or ABIs.
- Use fresh active v4 addresses from environment/config.
- Keep `NARAIndexFeeCollectorV2` bound to an engine whose `NARA()` getter
  matches the collector's immutable NARA token, and preserve exact USDC route
  spend plus exact NARA engine-pull checks.
- Launch managers must use zero holding and raw-withdraw fees so the narrow
  collector receives only USDC or NARA from normal basket flows.
- Never print private keys, RPC keys, or deployment secrets.
- Do not deploy or send transactions without explicit human approval.
- Prefer docs or read-only verification when uncertain.

## Change Control

- Work on a focused branch and merge through a pull request.
- Require repository, contract, app, and analyzer checks before merge.
- Never push directly to protected `main`.
- Keep GitHub Actions pinned to full commit SHAs.
- Run `node scripts/check-repository.mjs`, contract gates, app gates,
  `git diff --check`, and a secret scan before handoff.
- Record every skipped RPC-dependent or deployment-dependent gate.
