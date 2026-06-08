# NARA Integration

> ⚠️ **LAUNCH DEPENDENCY — READ FIRST. Decide before deploying any basket.**
>
> **NARA's designed liquidity home is a taxed Uniswap v4 pool, not a plain pool.**
> The v4 core stack ships `NARALiquidityGrowthHook` + `NARALiquidityGrowthVault`
> (`nara-protocol-hardhat/contracts/v4/`). The hook taxes every NARA swap
> (default **5% buy / 5% sell**, up to 25%/20% under pressure) and routes the tax to
> the vault, whose **default `routeMode = Liquidity`** compounds it back into the LP.
> The tax was deliberately designed to **build/deepen liquidity** from trading volume.
>
> **Current decision:** taxed Uniswap v4 is NARA's basket route. `UniswapV4BasketAdapterV1`
> exists and must be included in every production basket's immutable `adapters[]`.
> Do not deploy a basket with only the older four-adapter set. Adapters are locked at
> basket deploy and cannot be added later.
>
> **Practical notes regardless of option:**
> - `Liquidity` route mode needs a **compounder contract wired to the vault**
>   (`ILiquidityCompounder.compound`); otherwise the tax sits idle in the vault.
> - Basket fees (buy/sell/withdraw/holding/referral) route to the engine **independently**
>   of the pool tax — value capture from baskets does not depend on the v4 pool.
> - Source of truth for the hook/vault: `nara-protocol-hardhat/contracts/v4/NARALiquidityGrowthHook.sol`
>   and `NARALiquidityGrowthVault.sol`.

## Integration target

Connect category basket fees to the existing NARA reward engine.

## Existing NARA engine functions

From uploaded `NARAEngine.sol`:

```solidity
function notifyEthRewards() external payable;
function depositRewards(uint256 amount) external;
function notifyTokenRewards(address token, uint256 amount) external;
```

## V1 integration decision

Use:

```solidity
notifyEthRewards()
depositRewards()
```

Avoid default use of:

```solidity
notifyTokenRewards()
```

Reason:

```text
notifyTokenRewards sets _tokenRewardsNotified = true in NARAEngine.
That state affects active position extension behavior.
Random basket fee tokens should not enter the engine directly.
```

## Basket semantics

`NARAImmutableBasketPositionManagerV1` is the canonical one-click V1 product.
`CategoryIndexVaultV1` is a verified pro-rata basket vault. `weightsBps` in the
static vault are creation-time target/display metadata, while mint and redeem
accounting uses actual vault balances. A true fungible weighted index requires
oracle-normalized NAV, seed validation, deviation limits, and a rebalance
mechanism outside this V1.

The receipt manager has a required asset:

```text
requiredAsset = NARA
minRequiredAssetWeightBps = deployment configured minimum
```

Every receipt basket must include NARA at or above the minimum. This creates
NARA buy demand on each basket purchase and includes NARA in each whole-basket
sale.

Each receipt sell can exit the whole basket into:

```text
USDC or another allowed payment token
NARA through requiredAsset when every selected asset has a direct/configured route to NARA
raw underlying assets through withdrawUnderlying
```

The receipt manager requires each sell swap to output the final selected token.
It does not chain `asset -> USDC -> NARA` across separate swap instructions. A
broad "all assets to NARA" exit therefore requires direct NARA pools, configured
Aerodrome-style multi-hop routes ending in NARA, or a separately audited composite
adapter included before basket deployment.

## Deployment order

```text
1. Deploy NARAIndexFeeCollectorV2 with engine, NARA token, WETH, admin, and allowed executors.
2. Allow the exact fee-collector executor selector with feeCollector.setAllowedSelector.
3. Deploy one NARAImmutableBasketPositionManagerV1 per receipt basket with name, symbol, NARA required asset, minimum NARA weight, assets, weights, payment tokens (USDC + WETH), adapters (all five: UniswapV3, AerodromeAMM, AerodromeSlipstream, PancakeSwapV3, UniswapV4), buyFeeBps, sellFeeBps, withdrawFeeBps, maxWeightDeviationBps, and fee recipient.
4. Verify each immutable receipt manager constructor config.
5. No post-deploy receipt-manager role handoff exists because the manager has no roles.
6. Optional static vault path: deploy CategoryIndexFactoryV1, IndexZapRouterV1, and IndexLensV1 separately.
7. Optional static vault path: allowlist exact-transfer basket assets with factory.setAssetAllowed.
8. Optional static vault path: use factory.createSeededVault for each static vault with feeRecipient = FeeCollector.
9. Optional static vault path: allow each created vault in the fee collector with feeCollector.setAllowedVault.
10. Frontend reads receipt baskets from immutable manager addresses and static vaults from factory/lens only if static vaults are enabled.
```

## Allowed adapters on Base (V1 locked set)

The V1 adapter set is immutable — locked at deploy, cannot be changed post-deploy.

```text
UniswapV3BasketAdapterV1      — SwapRouter02  0x2626664c2603336E57B271c5C0b26F421741e481
AerodromeBasketAdapterV1      — AMM Router    0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
AerodromeSlipstreamBasketAdapterV1 — CL Router  0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
PancakeV3BasketAdapterV1      — V3 Router     0x1b81D678ffb9C0263b24A97847620C99d213eB14
UniswapV4BasketAdapterV1      — UniversalRouter 0x6ff5693b99212da76ad316178a184ab56d299b43 + Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

Addresses must be confirmed live on Base at deploy time. DeployMainnetReady.s.sol
runs _requireCode() on all five before deploy. Override via AERODROME_ROUTER,
AERODROME_SLIPSTREAM_ROUTER, PANCAKE_V3_ROUTER, V4_UNIVERSAL_ROUTER, and
V4_PERMIT2 env vars if routers redeploy.

Frontend NARA routing requires VITE_BASKET_ADAPTER_V4, VITE_NARA_V4_HOOK,
VITE_NARA_V4_POOL_FEE, and VITE_NARA_V4_TICK_SPACING. If any are missing,
the app must keep buys disabled.

Do not allow broad multicall-style adapter behavior in production.

## Engine reward routing options

### Option A: ETH rewards

```text
receipt fees or static-vault fee shares -> WETH -> unwrap -> notifyEthRewards
```

Benefit:

```text
ETH rewards are simple and do not trigger multi-token reward extension edge cases.
```

### Option B: NARA rewards

```text
receipt fees or static-vault fee shares -> NARA -> depositRewards
```

Benefit:

```text
Directly strengthens NARA reward reserve.
```

## V1 selection

Use both:

```text
Primary route: WETH -> ETH -> notifyEthRewards
Secondary route: NARA -> depositRewards
```

Do not route USDC directly into NARAEngine unless the engine reward-token behavior is intentionally changed.

## Canonical basket product

The user-facing one-click V1 basket product is:

```text
NARAImmutableBasketPositionManagerV1
```

It is receipt-based:

```text
user payment token in
approved adapters buy basket assets
every basket includes NARA
manager stores exact bought amounts
manager mints ERC721 receipt
user sells whole receipt later to USDC/payment token or NARA
manager charges buy and sell fees
```

The old static vault module remains:

```text
CategoryIndexVaultV1
```

but it is not the canonical one-click market-buy product.

## Receipt-manager fee path

Set:

```text
NARAImmutableBasketPositionManagerV1.feeRecipient = NARAIndexFeeCollectorV2
```

Then:

```text
1. User buys basket.
2. Manager sends buy fee in input token to FeeCollector.
3. User later sells whole basket to USDC/payment token or NARA.
4. Manager sends sell fee in output token to FeeCollector.
5. OR user withdraws underlying tokens directly.
6. Manager charges withdrawFeeBps in-kind per asset before transfer; sends fee to FeeCollector.
7. SWAPPER_ROLE swaps fee tokens into NARA or WETH.
8. NARA route calls engine.depositRewards(amount).
9. WETH route unwraps and calls engine.notifyEthRewards{value: amount}().
```

The receipt manager does not mint fee shares. It sends real fee tokens directly
to the fee collector.

## Static-vault fee path

This applies only to `CategoryIndexVaultV1`:

```text
1. Every static basket vault sets feeRecipient = NARAIndexFeeCollectorV2.
2. Mint and redeem fees are paid as newly minted basket shares.
3. FeeCollector holds basket shares.
4. A REDEEMER_ROLE keeper calls redeemIndexFeeShares(vault, shares, minAmountsOut) for an allowed vault.
5. FeeCollector receives underlying basket assets.
6. A SWAPPER_ROLE keeper calls executeFeeSwap() through an allowed executor and selector to convert assets to WETH or NARA.
7. If WETH: a SWAPPER_ROLE keeper calls unwrapWethAndNotifyEth(amount).
8. If NARA: a SWAPPER_ROLE keeper calls depositNaraRewards(amount).
```
