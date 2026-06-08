# Security Checklist

## Canonical one-click product

```text
NARAImmutableBasketPositionManagerV1 is the canonical V1 one-click product.
CategoryIndexVaultV1 is a static pro-rata ERC20 vault module.
Do not confuse the two models.
```

## Receipt basket invariants

```text
Every live ERC721 receipt maps to one basket category.
Every live receipt has stored amounts for every configured basket asset.
Every receipt basket must include requiredAsset, intended to be NARA.
requiredAsset weight must be at least minRequiredAssetWeightBps.
Receipt owner or approved ERC721 operator can sell.
Normal exit sells the whole position only.
Incident exit can sell selected assets and leave the receipt live.
Raw underlying withdrawal is callable by the receipt owner or approved operator.
Raw underlying withdrawal still requires every underlying token transfer to succeed.
Partial raw withdrawal can withdraw selected assets and leave the receipt live.
Buy fees are charged in the input token.
Sell fees are charged in the output token.
Withdraw fees are charged in-kind per underlying asset before transfer to receiver.
withdrawFeeBps is immutable and set at deploy time; cap is MAX_FEE_BPS (100 = 1%).
Holding fees are an annual in-kind streaming fee accrued per asset over time; immutable; cap is MAX_HOLDING_FEE_BPS (200 = 2%/yr).
Holding-fee accrual is pure accounting (no token transfer); it can never be blocked by a frozen asset and never bricks an exit or partial rescue.
Accrued holding fees move into protocolFeeAccrued and leave only via permissionless sweepAccruedFee to the immutable feeRecipient.
Holding fee is settled on every sell, partial sell, withdraw, and partial withdraw; also via permissionless accrueHoldingFee.
Referrer is bound to a position at buy (referrerOf) and earns an immutable share (referralShareBps, cap MAX_REFERRAL_SHARE_BPS = 5000) of every buy and sell fee.
Referral rewards use PULL accounting: credited into referralRewards[referrer][token] — never transferred during buy/sell. A referrer that cannot receive a token cannot block user exits.
Referrer claims via claimReferralReward(token, to). Only the referrer can initiate; they may direct to any non-zero, non-manager address.
Self-referral (referrer == buyer) and referrer == manager are ignored. Referral split applies to buy/sell cash fees only; withdraw and holding fees are 100% protocol.
Solvency invariant: per asset, balance >= totalAccountedAsset + protocolFeeAccrued + sum(referralRewards[*][asset]).
accrueHoldingFee batch is capped at MAX_ACCRUAL_BATCH (100) to bound gas.
lastHoldingAccrualAt and referrerOf are deleted when a position closes (full sell, full withdraw, or partial exit to zero).
Solvency invariant: per asset, balance >= totalAccountedAsset + protocolFeeAccrued.
Fees go directly to feeRecipient.
receiver must not equal the manager contract address on sell, sellPartial, withdraw, or withdrawPartial.
totalAccountedAsset must equal the sum of open receipt claims per asset.
manager token balance must be >= totalAccountedAsset for every receipt asset.
Position accounting is cleared before/with receipt burn on sell and underlying withdrawal.
Partial exit accounting decrements only selected asset amounts and burns only when empty.
Closed positions cannot be sold or withdrawn again.
No owner.
No roles.
No pause.
No admin sweep.
No mutable basket config.
```

## Receipt buy checks

```text
configured basket must include NARA at or above the manager minimum.
payment token must be immutable-allowed for that basket.
deadline enforced.
inputAmount must be nonzero.
manager pulls exactly inputAmount.
buy fee is sent before allocation.
all net input must be allocated.
directAmountsIn are allowed only when payment token is itself a basket asset.
each swap must be payment token -> basket asset.
adapter must be immutable-allowed.
adapter must consume exactly amountIn.
adapter reported amounts must match balance deltas.
budget allocation must match basket weights within maxWeightDeviationBps.
each bought asset must satisfy minAmountsOut.
each stored asset amount must be nonzero.
```

## Receipt sell checks

```text
caller must own tokenId or be approved for tokenId.
position must be live.
output token must be an immutable-allowed payment token or requiredAsset/NARA.
deadline enforced.
each swap must be basket asset -> output token.
adapter must be immutable-allowed.
adapter must consume exactly amountIn.
adapter reported amounts must match balance deltas.
all non-output basket assets must be fully sold.
net output must satisfy minOutputAmount.
sell fee is charged from gross output.
receipt is burned.
totalAccountedAsset is decremented by the stored receipt amounts.
normal user exits can be all-to-USDC/payment token or all-to-NARA.
partial user exits can sell selected assets to USDC/payment token or NARA.
```

## Receipt pooled-accounting checks

```text
Buy increments totalAccountedAsset by the exact bought amount per asset.
Sell decrements totalAccountedAsset by the exact stored amount per asset.
withdrawUnderlying decrements totalAccountedAsset by the exact stored amount per asset.
sellBasketPartial decrements totalAccountedAsset only for sold or direct-output asset amounts.
withdrawUnderlyingPartial decrements totalAccountedAsset only for selected asset amounts.
There is no sweep function.
There is no payment-token manager.
There is no adapter manager.
```

## Swap adapter policy

```text
Use narrow adapters implementing INARABasketSwapAdapterV1.
Adapters are immutable: the full adapter set is locked at deploy. No adapter can be added or removed post-deploy.
V1 deploy includes five adapters: UniswapV3, AerodromeAMM, AerodromeSlipstream, PancakeSwapV3, UniswapV4.
Do not allow generic multicall selectors directly in the manager.
Do not allow unknown v4 hook pools without explicit review.
Do not leave persistent token approvals to adapters.
Adapter must send output token back to manager.
Adapter must return actual amountInUsed and amountOut.
Adapter must not custody user position assets after the call.
```

## Vault invariants

```text
Every share is a proportional claim on basket assets.
Mint requires proportional basket assets.
Redeem returns proportional basket assets.
Redeem transfers are all-or-nothing.
Vault does not price assets.
Vault does not use DEX spot price.
Vault does not use oracle NAV.
Vault does not rebalance.
Vault has no owner.
Vault has no pause.
Vault has no upgrade path.
```

## Router checks

```text
These apply to the legacy/static ERC20 vault router, not the canonical receipt manager.

factory.isVaultActive(vault) must be true.
deposit tokenIn must be USDC.
deposit tokenOut must be one of vault assets.
redeem tokenIn must be one of vault assets.
redeem tokenOut must be USDC.
executor must be allowed.
executor selector must be allowed.
redeem swaps can spend only assets received in the current redeem.
swap minAmountOut must be nonzero.
SwapExecuted actual input/output deltas must be monitored.
minSharesOut enforced.
minUSDCOut enforced.
deadline enforced.
ReentrancyGuard enabled.
dust refunded by balance delta.
unexpected stuck tokens can be swept only by admin.
```

## Fee collector checks

```text
No user deposits.
Only protocol-earned fee shares or receipt-manager fee tokens.
Only REDEEMER_ROLE can redeem fee shares.
Fee vault must be allowed before fee share redemption.
Only SWAPPER_ROLE can execute fee swaps.
Only SWAPPER_ROLE can push NARA/WETH/native ETH rewards into the engine.
Executor manager can revoke unsafe fee executors.
Fee executor selector must be allowed.
Fee swaps must output NARA or WETH.
Fee swaps must set nonzero minAmountOut.
Swap minAmountOut enforced.
SwapExecuted actual input/output deltas must be monitored.
NARA rewards route uses engine.depositRewards.
ETH rewards route uses engine.notifyEthRewards.
Random basket tokens not routed to notifyTokenRewards by default.
Unexpected non-reward tokens or ETH can be swept only by admin.
NARA and WETH reward assets cannot be swept through sweepToken.
```

## Assets allowed in baskets

Reject unless explicitly classified as degenerate:

```text
fee-on-transfer tokens
rebasing tokens
honeypots
blacklistable tokens
paused-transfer tokens
very thin liquidity tokens
tokens without reliable market data
wrapped assets with unknown bridge risk
```

## Test requirements before mainnet

```text
~/.foundry/bin/forge test --root nara-category-baskets-v1
~/.foundry/bin/forge test --root nara-category-baskets-v1 --fuzz-runs 1000
slither .
manual audit
external audit
Base Sepolia deployment
small capped mainnet pilot
```

Note: forge binary is at ~/.foundry/bin/forge and is NOT on PATH by default.
Always pass --root nara-category-baskets-v1 when running from workspace root.
Expected clean run: 96 pass, 1 fork-env skip (AerodromeBasketAdapterV1 fork test).

## Known V1 limitations

```text
No rebalance.
Receipt baskets are not fungible ERC20 index shares.
Each receipt owns the exact assets bought for that position.
Every receipt basket has direct NARA exposure.
Receipt basket budget weights are enforced in payment-token allocation terms, not oracle NAV terms.
Receipt users can exit the whole basket to NARA or to an immutable allowed payment token.
The quote builder must still choose real market routes and minOut values.
Normal sell is whole-position. Incident exits can sell selected assets, but V1 has no percentage-based partial sell UX.
weightsBps are target/display metadata, not enforced NAV weights.
Basket composition follows actual vault balances.
VaultSeedAsset events expose initial seed amounts for indexers and frontends.
Bad asset can make exits involving that asset revert if token transfer reverts.
Partial sell and partial withdrawal can rescue the other selected assets.
Router execution depends on external DEX liquidity.
Cross-chain assets require wrapped tokens or V2 cross-chain routing.
Fee swaps depend on SWAPPER_ROLE operational security and executor allowlisting.
V1 has no oracle fair-value check for fee swaps.
```
