# Cold IDE AI Task

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
Sell output can be USDC/payment token or requiredAsset/NARA.
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
3. Deployment script for Base Sepolia.
4. Deployment script for Base mainnet.
5. Example deployment config for CORE, AI, FINANCE, CULTURE, and optional RWA baskets.
6. Security notes for audit.
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
Manager sells all assets to USDC/payment token or NARA.
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

Avoid routing random basket tokens to:

```solidity
engine.notifyTokenRewards(token, amount);
```

Reason:

```text
notifyTokenRewards sets token reward state and may affect active position extension behavior.
Preferred V1 fee route is ETH or NARA.
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
