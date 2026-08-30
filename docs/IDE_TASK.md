# Cold IDE AI Task

> **Current scope (2026-08-30):** use an exact Base-mainnet fork, not Base
> Sepolia. Start from protected protocol handoff
> `dae88079dd336e22bdefde6f45e3b01389d554cb`; never rediscover addresses from
> chat or old branches. The upstream core and canonical pool are in technical
> live testing with real assets, while basket contracts remain undeployed and
> the app remains preview-only. Do not deploy lockboard, Graduation/periphery,
> Lotto, Arena, or another v4 core stack.

> The Position NFT Phase-2 baseline is deployed, tested, source-verified, and
> Safe-finalized, but its canonical manifest remains `integrationReady: false`.
> Do not treat that deployment as authorization to enable Graduation.

## Objective

Make this package compile, test, and integrate with NARA.

## Repository relationship

This package is intentionally separate from the main NARA protocol repo.

```text
nara-protocol-hardhat/contracts/v4/
```

contains the main V4 NARA contracts and remains the protocol brain.

This package:

```text
nara-category-baskets-v1/
```

is a V1 utility layer for category basket exposure. It deploys separate basket contracts and integrates with the already deployed V4 NARA engine by address.

Do not move these contracts into the V4 folder unless explicitly requested. Do not modify V4 engine logic for this task.

## Canonical files

Use these as canonical V1:

```text
src/NARAImmutableBasketPositionManagerV1.sol
src/CategoryIndexSuiteV1.sol
src/NARAIndexFeeCollectorV2.sol
src/adapters/UniswapV3BasketAdapterV1.sol
src/adapters/AerodromeBasketAdapterV1.sol
src/adapters/AerodromeSlipstreamBasketAdapterV1.sol
src/adapters/PancakeV3BasketAdapterV1.sol
test/NARAImmutableBasketPositionManagerV1.t.sol
test/CategoryIndexSuiteV1.t.sol
test/AerodromeSlipstreamBasketAdapterV1.t.sol
test/PancakeV3BasketAdapterV1.t.sol
docs/RECEIPT_BASKET_FLOW.md
```

Ignore older chat prototypes.

## Canonical product model

The canonical one-click product is:

```text
NARAImmutableBasketPositionManagerV1
```

It is immutable, receipt-based, and not fungible-share based:

```text
One deployed manager represents one basket.
Constructor fixes assets, weights, payment tokens, adapters, fees, and feeRecipient.
No owner, roles, pause, admin sweep, or mutable config.
User pays approved payment token.
Manager charges buy fee.
Approved adapters buy the basket assets.
Basket must include requiredAsset, which is NARA in production.
Manager stores exact bought asset amounts per tokenId.
Manager mints ERC721 receipt to user.
User later sells the whole receipt.
Manager sells all non-output assets through approved adapters.
The publishable route sells to USDC; direct underlying withdrawal is the
DEX-independent alternative. NARA remains contract-level allowlisted but has no
complete production route for every basket component.
Manager charges sell fee.
Manager burns receipt.
User can instead call withdrawUnderlying when all underlying token contracts transfer normally.
If one component breaks, user can call sellBasketPartial or withdrawUnderlyingPartial for selected assets.
```

The static ERC20 vault module is:

```text
CategoryIndexVaultV1
```

It is not the canonical one-click market-buy product. It is a separate static
pro-rata vault where mint and redeem follow existing vault balances.

## Required output

```text
1. Passing Foundry compile.
2. Passing Foundry test suite.
3. Exact Base-mainnet fork rehearsal using the separately authorized deployment
   candidate; the checked-in `DeployMainnetReady.s.sol` remains fail-closed.
4. Base-mainnet deployment script that fails closed on address or admin errors.
5. Deployment config for CORE, AI, FINANCE, and CULTURE.
6. Security notes that state test, fork, and review evidence accurately.
```

## Hard constraints

Do not add:

```text
owner controls in vault
upgrade proxy
governance
staking
lockups
rebalancing
lending
leverage
oracle based minting
oracle based redemption
fractional receipt sales
dividend-bearing basket fractions
```

Pause is not allowed in the immutable receipt manager. The user fallback is
`withdrawUnderlying` for full raw exit, plus `withdrawUnderlyingPartial` and
`sellBasketPartial` for selected-asset incident exits. Any exit that includes a
broken ERC20 still depends on that ERC20 transfer succeeding.

## Product flow

```text
User selects basket categoryId.
Frontend/quote service builds exact-input swap plan.
User calls buyBasket.
Manager pulls payment token.
Manager sends buy fee to NARAIndexFeeCollectorV2.
Manager buys basket assets through approved adapters.
Manager checks budget weights, per-asset minOut, and adapter accounting.
Manager enforces required NARA allocation at basket creation.
Manager stores exact bought assets under tokenId.
Manager mints ERC721 receipt to user.
User calls sellBasket for whole position.
Manager sells all assets to USDC. A raw underlying withdrawal is available
without DEX conversion.
Manager checks whole-position sale and minOutputAmount.
Manager sends sell fee to NARAIndexFeeCollectorV2.
Manager sends net output to user and burns receipt.
Alternatively user calls withdrawUnderlying; manager charges withdrawFeeBps in-kind per asset,
sends fee to NARAIndexFeeCollectorV2, sends net underlying to user.
If one route or token breaks, user can call sellBasketPartial or withdrawUnderlyingPartial
for selected working assets while the receipt stays live for anything remaining.
FeeCollector routes collected fees into NARAEngine through depositRewards or notifyEthRewards.
```

## NARA integration

Use uploaded NARA engine functions:

```solidity
engine.notifyEthRewards{value: amount}();
engine.depositRewards(amount);
```

Do not route any basket token to the current deployed Engine through:

```solidity
engine.notifyTokenRewards(token, amount);
```

Reason:

```text
The deployed Engine's generic ERC-20 notifier is intentionally prohibited.
Preferred V1 fee routes are the separately tested ETH and NARA paths. A future
non-native reward-asset path requires a separate reviewed architecture.
```

## Fix priority

```text
1. Compile errors.
2. Test failures.
3. Router safety.
4. Fee collector integration.
5. Deployment scripts.
6. Analytics events.
7. Documentation.
```
