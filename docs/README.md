# NARA Baskets — Documentation

Navigation for the `nara-category-baskets-v1` docs. Start with the [project README](../README.md) for
the overview, then dive in here.

## Read in this order

1. **[NARA_INTEGRATION.md](NARA_INTEGRATION.md)** — how baskets wire into the NARA v4 engine: fee
   routes, deploy order, and the **launch dependency** (the taxed Uniswap v4 pool). Read first before
   deploying anything.
2. **[RECEIPT_BASKET_FLOW.md](RECEIPT_BASKET_FLOW.md)** — the canonical one-click flow: buy → receipt
   → sell/withdraw, with every execution and accounting check.
3. **[EXAMPLE_BASKETS.md](EXAMPLE_BASKETS.md)** — basket configuration templates.

## Reference

| Doc | Purpose |
|-----|---------|
| [SECURITY_CHECKLIST.md](SECURITY_CHECKLIST.md) | Pre-deploy security gate — must pass before mainnet value |
| [DEPLOYMENT_MANIFEST.md](DEPLOYMENT_MANIFEST.md) | Recorded and verified after every deployment |
| [VALIDATION_STATUS.md](VALIDATION_STATUS.md) | Current validation / test state |

## Related (NARA protocol repo)

- `NARA_V4_BASKETS_LAUNCH_STRATEGY.md` — why baskets are the v4 crown launch / front door
- `NARA_V4_ECONOMIC_LAUNCH_ROADMAP.md` — where baskets sit in the overall launch order

> Security disclosure: see [`../SECURITY.md`](../SECURITY.md). License: [`../LICENSE`](../LICENSE) (MIT).
