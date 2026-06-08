# CLAUDE.md — NARA Category Baskets V1 (contract package)

Cold-start context for any AI working in `nara-category-baskets-v1/`.
This is the **Foundry contract package** for NARA Baskets. The frontend app is separate
(`../apps/nara-baskets/`, which has its own `CLAUDE.md` design system).

Read order: this file → `README.md` → `docs/NARA_INTEGRATION.md` → `docs/RECEIPT_BASKET_FLOW.md`.

---

## What this package is

The NARA flagship retail product:

```
USDC in → category basket exposure out → sell back to USDC or NARA → fees route to NARA rewards
```

User picks a narrative (CORE / AI / FINANCE / CULTURE), pays USDC, and gets a **whole-basket
ERC-721 receipt** for the exact tokens bought. Every basket **must** include NARA (the moat: every
basket buy is a NARA buy).

Separate Foundry package by design — **not** in the Hardhat repo's compile path. Integrates with v4
only by passing deployed NARA addresses through env vars and calling
`engine.depositRewards()` / `engine.notifyEthRewards()`. Do not modify v4 engine contracts here.

---

## ⚠️ Launch dependency (read before deploying anything)

NARA's designed liquidity home is a **taxed Uniswap v4 pool** (`NARALiquidityGrowthHook`). A basket
buy must route its NARA slice through that pool, so production baskets **must** include
`UniswapV4BasketAdapterV1` in the immutable adapter set. Full detail + the immutability trap:
`docs/NARA_INTEGRATION.md` → "LAUNCH DEPENDENCY" at the top. Frontend buys stay disabled until the v4
adapter + NARA hook pool env values are configured.

---

## Contracts — what's canonical vs not

### Canonical (use these)

| Contract | Role |
|---|---|
| `src/NARAImmutableBasketPositionManagerV1.sol` | **THE product.** One immutable manager per basket. ERC-721 receipt per position. No owner, no roles, no pause, no admin sweep, no rebalance, no mutable config. |
| `src/NARAIndexFeeCollectorV2.sol` | **Canonical fee collector.** Routes basket fees → `engine.depositRewards`/`notifyEthRewards`. Role-gated keeper (REDEEMER/SWAPPER/EXECUTOR_MANAGER) with allowlisted executor + 4-byte selector. |

### Adapters (all 5 are canonical; production set includes the v4 one)

```
src/adapters/UniswapV3BasketAdapterV1.sol
src/adapters/AerodromeBasketAdapterV1.sol
src/adapters/AerodromeSlipstreamBasketAdapterV1.sol
src/adapters/PancakeV3BasketAdapterV1.sol
src/adapters/UniswapV4BasketAdapterV1.sol   ← required for NARA's taxed v4 pool
```

Each adapter: pulls exactly `amountIn`, returns `(amountInUsed, amountOut)` matching real balance
deltas, no admin, no upgrade, immutable per deployment.

### NOT canonical — do not use for launch

| Contract | Why it exists |
|---|---|
| `src/NARABasketPositionManagerV1.sol` | Older **mutable** manager variant. Superseded by the Immutable manager. Do not deploy for production; kept for reference only. |
| `src/NARAIndexFeeCollectorV1.sol` | V1 fee collector. Superseded by V2. Use V2. |
| `src/CategoryIndexSuiteV1.sol` | Separate **static pro-rata ERC-20 vault** module. NOT the one-click receipt product. Only deploy if explicitly presenting a static pro-rata vault. |

---

## The 5 fee surfaces (all immutable, constructor-fixed)

buy fee · sell fee · withdraw fee · holding fee · referral split. Hard cap 100 bps (1%) on
buy/sell. Referral is pull-based, 30% lifetime split. All route to the fee collector → engine.
Basket NARA allocation is idle by design (held in the receipt, not auto-locked).

## What is intentionally NOT in V1

staking · lockups · auto-sell · stop losses · governance · multisig custody · upgradeable vaults ·
lending · leverage · rebalance · oracle-based mint/redeem · partial % basket sells · fungible ERC-20
basket shares · NAV oracle · TWAP. V2 only after separate design + audit.

---

## Build / test / deploy (Foundry — NOT Hardhat)

Forge is **not on PATH**; use the full binary path. Always pass `--root`.

```bash
# Build
~/.foundry/bin/forge build --root nara-category-baskets-v1

# All non-fork tests (fast, no RPC)
~/.foundry/bin/forge test --root nara-category-baskets-v1 --no-match-path "test/AerodromeBasketAdapterV1.t.sol"

# Manager suite only
~/.foundry/bin/forge test --root nara-category-baskets-v1 --match-contract NARAImmutableBasketPositionManagerV1Test

# New adapter unit tests (mock-based, no fork)
~/.foundry/bin/forge test --root nara-category-baskets-v1 --match-contract "PancakeV3BasketAdapterV1Test|AerodromeSlipstreamBasketAdapterV1Test|UniswapV4BasketAdapterV1Test"

# Fork tests (need Base RPC — load from ../nara-protocol-hardhat/.env, never print it)
~/.foundry/bin/forge test --root nara-category-baskets-v1 --match-path "test/AerodromeBasketAdapterV1.t.sol" --fork-url <BASE_RPC>
```

PowerShell: `& "$env:USERPROFILE\.foundry\bin\forge.exe" build --root nara-category-baskets-v1`

Deploy: `script/DeployMainnetReady.s.sol` (deploys manager + V2 fee collector + all 5 adapters incl.
v4). `DeployBaseMainnet.s.sol` / `DeployBaseSepolia.s.sol` are legacy and intentionally revert.

---

## Hard rules

1. Every receipt basket includes NARA at or above `MIN_NARA_WEIGHT_BPS`.
2. Production adapter set includes `UniswapV4BasketAdapterV1`.
3. `feeRecipient` points to `NARAIndexFeeCollectorV2`.
4. Fee collector executor selectors: explicit 4-byte allowlist only, never multicall/batch.
5. The immutable manager has **no post-deploy admin** — get the config right before deploy; it's permanent.
6. Frontend/UI work follows `../apps/nara-baskets/CLAUDE.md` (Satoshi/Inter/Mono, Base Blue `#0000FF`,
   CORE/AI/FINANCE/CULTURE) and the neutral-choice rules in the workspace-root `../CLAUDE.md`.

## Related docs

- `docs/NARA_INTEGRATION.md` — engine wiring, fee routes, deploy order, launch dependency
- `docs/RECEIPT_BASKET_FLOW.md` — canonical buy/sell/withdraw flow + execution checks
- `docs/EXAMPLE_BASKETS.md` — basket config templates
- `docs/SECURITY_CHECKLIST.md` — pre-deploy gate
- `docs/DEPLOYMENT_MANIFEST.md` — record after every deploy
- `../nara-protocol-hardhat/docs/NARA_V4_BASKETS_LAUNCH_STRATEGY.md` — crown-launch strategy
- `../nara-protocol-hardhat/docs/NARA_V4_ECONOMIC_LAUNCH_ROADMAP.md` — where baskets sit in the launch order
