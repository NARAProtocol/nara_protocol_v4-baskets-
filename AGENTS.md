# NARA Category Baskets Agent Rules

This is the separate Foundry contract package for NARA category baskets. It is
not part of the Hardhat `contracts/v4/` compile path.

## Status

- Basket contracts are active v4-adjacent product code, but deployment status
  must be verified before making live claims.
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

## Integration Rules

- Do not edit NARA v4 core contracts from this package.
- Do not import retired v3 contracts or ABIs.
- Use fresh active v4 addresses from environment/config.
- Never print private keys, RPC keys, or deployment secrets.
- Do not deploy or send transactions without explicit human approval.
- Prefer docs or read-only verification when uncertain.
