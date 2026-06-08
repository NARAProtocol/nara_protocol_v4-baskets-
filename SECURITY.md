# Security Policy

## Status

**Pre-launch — no contracts are deployed to mainnet.** Once deployed, verified addresses will be
published in [`docs/DEPLOYMENT_MANIFEST.md`](docs/DEPLOYMENT_MANIFEST.md).

## Security model

NARA Baskets is designed to **remove trust surfaces** rather than add them:

- **Immutable by construction** — the receipt manager and adapters have no owner, no pause, no
  upgradeability, and no admin sweep. Basket config (assets, weights, fees, adapters, `feeRecipient`)
  is fixed in the constructor and can never change.
- **Always-available exit** — holders can withdraw their exact underlying tokens unconditionally,
  independent of any keeper or DEX availability.
- **Constrained fee collector** — the only role-gated component routes fees to the NARA engine through
  an allowlisted executor and an explicit 4-byte selector. It cannot touch user positions, and
  multicall/batch selectors are not permitted.
- **Exact-accounting adapters** — each adapter moves exactly the accounted balance delta; no admin,
  no upgrade.

## Verification performed

- **136 tests passing** — unit, fuzz, and invariant suites (`forge test`).
- **Static analysis** — Slither, clean of new issues on the basket contracts.
- **Pre-deploy gate** — [`docs/SECURITY_CHECKLIST.md`](docs/SECURITY_CHECKLIST.md) must pass before
  any mainnet value.

Automated analysis is necessary but not sufficient. An independent human / competitive review is
planned before mainnet deployment; automated tooling cannot catch economic or logic flaws that were
never encoded as a property.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for an exploitable bug.

- Email: **security@naraprotocol.io** *(replace with the project's monitored security contact)*
- Include: affected contract + line, a description, and a reproducing transaction sequence if possible.

We aim to acknowledge reports within 72 hours. A formal bug-bounty program will be announced ahead of
mainnet launch.

## Scope

In scope: every contract under [`src/`](src/) marked **canonical** in the
[README](README.md#-contracts). Reference-only contracts (the mutable manager, V1 fee collector, and
the static vault suite) are **not** intended for production deployment.
