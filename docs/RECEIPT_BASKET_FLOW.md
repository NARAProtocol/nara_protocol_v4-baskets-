# NARA Receipt Basket Flow

This is the canonical V1 flow for the one-click basket product.

## Canonical V1 decision

Use:

```text
NARAImmutableBasketPositionManagerV1
```

for the user-facing one-click product.

Do not use:

```text
CategoryIndexVaultV1
```

as the main one-click product. `CategoryIndexVaultV1` is a static pro-rata
ERC20-share vault. It is useful as a separate module, but it does not buy target
weights from the market for each user.

## Product goal

```text
User picks a basket.
User pays USDC. Basket V1 does not allow ETH or WETH payment.
Protocol buys the configured basket assets at current market execution.
Protocol stores the exact bought amounts under one position id.
User receives one ERC721 receipt.
User can later sell the whole receipt back to USDC or withdraw the raw underlying assets.
User can partially sell or partially withdraw selected assets if one component breaks.
Protocol earns a buy fee on purchase, a sell fee on sell, and a withdraw fee on raw underlying withdrawal.
Every official receipt basket includes NARA as a required core asset.
```

## Why V1 uses receipts instead of fungible shares

Fungible ERC20 basket shares require fair NAV pricing:

```text
sharesOut = depositValue * totalSupply / vaultNAV
```

For volatile or thin-liquidity assets, NAV pricing is hard because many
assets do not have robust oracles. Spot DEX prices can be manipulated. A
rebalance system also needs keepers, liquidity checks, price-impact limits, and
MEV controls.

V1 avoids those risks by giving each user a receipt for the exact assets bought
for that user.

## Contracts

```text
NARAImmutableBasketPositionManagerV1
  one immutable basket per deployed manager
  ERC721 position receipt
  per-position asset accounting
  per-asset global accounted balance
  buy and sell fee collection
  whole-position sell enforcement
  full and partial underlying withdrawal
  full and partial sell paths
  no owner, no roles, no pause, no sweep, no config mutation

INARABasketSwapAdapterV1
  narrow exact-input adapter interface
  hides DEX-specific calldata from the manager
```

The manager does not use arbitrary router calldata directly. It only calls
approved adapters that implement:

```solidity
function swapExactInput(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    bytes calldata data
) external returns (uint256 amountInUsed, uint256 amountOut);
```

## Basket configuration

Each basket has:

```text
categoryId
name
riskTier
assets
weightsBps
approved payment tokens (USDC only at Basket V1 launch)
approved adapters (UniswapV3, AerodromeAMM, AerodromeSlipstream,
PancakeSwapV3, and canonical hooked UniswapV4 — immutable)
buyFeeBps
sellFeeBps
withdrawFeeBps
maxWeightDeviationBps
feeRecipient
```

Weights sum to `10000`.

The manager constructor sets:

```text
requiredAsset
minRequiredAssetWeightBps
all basket configuration
```

For production, `requiredAsset` must be the canonical NARA token. The constructor
reverts unless the basket includes NARA with at least the configured minimum
weight. This makes every one-click basket create direct NARA demand on buy and
routes the held NARA back through the canonical NARA/USDC adapter during a USDC
sell. Raw withdrawal transfers the held NARA directly to the receipt owner.

The contract-level sell-output allowlist is intentionally narrow:

```text
immutable allowed payment token: USDC
requiredAsset, which is NARA in production (not an exposed production route)
```

The production adapter set does not turn arbitrary basket components directly
into NARA, so the app must not expose a whole-position NARA conversion. The
supported user exits are:

```text
sell whole basket -> USDC
withdraw whole basket -> raw underlying assets
sell selected assets -> USDC
withdraw selected assets -> raw underlying assets
```

`maxWeightDeviationBps` checks the payment-token budget allocation. It is not an
oracle NAV check. The off-chain quote builder must still use live market quotes
and user slippage settings.

## Buy flow

User or frontend builds `BuyParams`:

```text
paymentToken
inputAmount
directAmountsIn
minAmountsOut
swaps
receiver
deadline
```

Execution:

```text
1. Manager verifies deadline.
2. Manager verifies payment token is immutable-allowed for the basket.
3. Manager pulls exactly inputAmount from user.
4. Manager sends buy fee to feeRecipient.
5. Remaining net input must be fully allocated.
6. Direct amounts are allowed only when paymentToken is itself a basket asset.
7. Every swap must be paymentToken -> basket asset.
8. Every swap adapter must be immutable-approved.
9. Adapter must consume exactly amountIn.
10. Adapter return values must match manager balance deltas.
11. Per-asset bought amounts must satisfy minAmountsOut.
12. Budget allocation must be within target weight tolerance.
13. Manager stores tokenId -> asset amounts.
14. Manager increases totalAccountedAsset for each bought asset.
15. Manager mints ERC721 receipt to receiver.
```

Buy fee:

```text
feeAmount = inputAmount * buyFeeBps / 10000
```

The fee is charged in the input payment token.

## Sell flow

User or frontend builds `SellParams`:

```text
tokenId
outputToken
minOutputAmount
swaps
receiver
deadline
```

Execution:

```text
1. Manager verifies deadline.
2. Manager verifies caller owns tokenId.
3. Manager verifies outputToken is contract-level allowlisted. The publishable
   app supplies USDC because no complete production route to NARA exists.
4. Any basket asset equal to outputToken is counted as direct output.
5. Every other basket asset must be sold through approved adapters.
6. Every swap must be basket asset -> outputToken.
7. Adapter must consume exactly amountIn.
8. Adapter return values must match manager balance deltas.
9. Manager rejects any unsold non-output basket asset.
10. Manager computes grossOutput.
11. Manager charges sell fee.
12. Net output must satisfy minOutputAmount.
13. Manager clears position accounting and decrements totalAccountedAsset.
14. Manager burns the ERC721 receipt.
15. Manager sends fee to feeRecipient.
16. Manager sends net output to receiver.
```

Sell fee:

```text
feeAmount = grossOutput * sellFeeBps / 10000
```

The fee is charged in the output token.

## Underlying withdrawal

Adapter sell path:

```text
Users sell the whole basket through sellBasket.
```

Fallback path:

```text
Only the literal receipt owner can call withdrawUnderlying (the manager disables approvals and requires msg.sender == ownerOf — no approved-operator path) when all underlying token contracts transfer normally.
Manager clears accounting, decrements totalAccountedAsset, and burns the receipt.
Launch config requires withdrawFeeBps = 0.
Manager sends the full recorded asset amount to receiver.
receiver must not be the manager contract address.
```

This replaces admin emergency pause. No admin permission is needed if adapters,
DEX liquidity, or routing break.

Partial fallback path:

```text
Only the literal receipt owner can call withdrawUnderlyingPartial for selected assets (no approved-operator path).
Only the literal receipt owner can call sellBasketPartial for selected assets (no approved-operator path).
The receipt stays live while any asset amount remains.
The receipt burns only when all stored asset amounts reach zero.
```

Important limitation:

```text
Any exit that includes a broken ERC20 still depends on that ERC20 transferring normally.
If a basket asset later becomes paused, blacklisted, fee-on-transfer, or revert-on-transfer,
the exact-transfer checks can make exits involving that asset revert. Partial exits let users
recover the other assets that still transfer or route.
```

## Fee route into NARA

Set:

```text
feeRecipient = NARAIndexFeeCollectorV2
```

Then:

```text
buy fee token -> fee collector
sell fee token -> fee collector
withdraw and holding fees -> disabled at launch
SWAPPER_ROLE converts USDC through typed oracle-bounded USDC/WETH routing with
independent immutable freshness limits for the USDC/USD and ETH/USD feeds
held NARA -> direct engine deposit
NARA -> engine.depositRewards
WETH -> unwrap -> engine.notifyEthRewards
```

Do not route any basket asset into `engine.notifyTokenRewards` on the current
deployed Engine. Its generic ERC-20 notifier is prohibited. A future
non-native reward-asset path requires a separate reviewed architecture and
deployment.

## Slippage and execution controls

Buy-side controls:

```text
deadline
payment token allowlist
immutable adapter allowlist
tokenOut must be a basket asset
all net input must be allocated
budget allocation must match target weights within tolerance
per-asset minAmountsOut
exact transfer checks
exact adapter accounting checks
```

Sell-side controls:

```text
deadline
caller must own receipt
output token allowlist
NARA is contract-level allowlisted through requiredAsset, but the production app exposes USDC sells only
tokenIn must be a basket asset
tokenOut must be outputToken
sellBasket closes the whole position; sellBasketPartial leaves the receipt live
minOutputAmount
exact transfer checks
exact adapter accounting checks
```

Accounting controls:

```text
totalAccountedAsset tracks the pooled asset amount backing all live receipts.
manager balance for each asset must stay >= totalAccountedAsset[asset].
partial sell and partial withdrawal decrement only the selected asset amounts.
no sweep function exists.
accidental extra token transfers are intentionally unrecoverable by admin.
```

## Asset policy

Approved basket assets must be curated. Do not approve by default:

```text
fee-on-transfer tokens
rebasing tokens
honeypots
blacklistable tokens
paused-transfer tokens
tokens with very thin liquidity
tokens with unknown proxy or owner risk
tokens that require transfer hooks or callbacks
unverified wrapped assets
```

## V1 non-goals

Do not add these to the receipt product in V1:

```text
fungible ERC20 index shares
NAV oracle minting
automatic rebalance
percentage-based partial basket sells
transferable fractional basket shares
dividend-bearing basket fractions
leverage
lending
staking
governance
cross-chain routing
auto sell orders
stop losses
```

## Fraction policy

Do not fractionalize basket receipts in V1.

If users need smaller exits later, the next separate design task is:

```text
partial exit by percentage
```

That means the position owner sells 10%, 25%, or 50% of every underlying asset
inside the same receipt. It does not create transferable fractions and does not
create a second market for basket shares.

Avoid:

```text
ERC20 fractions of one receipt
ERC1155 tradeable fractions of one receipt
dividend-bearing fractional claims
protocol-promised profit distributions
```

Those designs add share-pricing, liquidity, custody, and securities-analysis
risk. They belong outside V1.

## V2 boundary

Move these to V2 only after separate design and testing:

```text
fungible weighted ERC20 shares
oracle NAV
TWAP checks
keeper rebalancing
per-asset rebalance bands
MEV-protected rebalance execution
percentage-based partial exits
position merging/splitting
```
