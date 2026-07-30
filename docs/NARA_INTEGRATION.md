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
USDC (the only Basket V1 payment token)
NARA through requiredAsset when every selected asset has a direct/configured route to NARA
raw underlying assets through withdrawUnderlying
```

Basket V1 must not allow WETH as a payment token. Its required NARA allocation
uses a single-hop NARA/USDC v4 adapter; a WETH-funded buy would otherwise attempt
the nonexistent canonical WETH/NARA PoolKey and revert. ETH/WETH entry requires a
separately implemented and reviewed composite route.

The receipt manager requires each sell swap to output the final selected token.
It does not chain `asset -> USDC -> NARA` across separate swap instructions. A
broad "all assets to NARA" exit therefore requires direct NARA pools, configured
Aerodrome-style multi-hop routes ending in NARA, or a separately audited composite
adapter included before basket deployment.

## Deployment order

```text
1. Run the entire `DeployMainnetReady.s.sol` sequence on an exact Base-mainnet fork.
2. Verify all five adapters and the collector's typed router, oracle feeds,
   pool fee, oracle-age bound, and slippage bound before broadcast.
3. Review the single production sequence as one unit: adapters,
   oracle-bounded V2 collector, immutable receipt manager, and separated role
   assignments.
4. Broadcast only after the fork evidence and manifests are approved.
5. Verify each immutable receipt-manager constructor config, collector route,
   and collector role on-chain.
6. No post-deploy receipt-manager role handoff exists because the manager has no roles.
7. Static vaults are not part of this launch. `NARAIndexFeeCollectorV2` does not implement
   `setAllowedVault`, `redeemIndexFeeShares`, `REDEEMER_ROLE`, or `VAULT_MANAGER_ROLE`.
   Do not use the superseded V1 static-vault instructions with V2.
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

`UniswapV4BasketAdapterV1` stores the fee, tick spacing, and hook as constructor
immutables. Every call must pass empty adapter data (`0x`). The frontend must pin
NARA to this configured v4 route and must not substitute a discovered hookless
pool. The NARA leg is exact-input only because the hook rejects exact-output
swaps.

The growth-hook fee applies only to the registered canonical pool. NARA is an
unrestricted ERC20, so other parties can create pools that do not use the hook.
Those venues do not contribute hook fees. The official basket app deliberately
pins its NARA leg to the canonical pool; it does not claim that all NARA trading
uses that venue.

After the canonical pool is initialized and funded, but before public launch:

1. Execute a Base-fork manager buy and sell using parameters generated by the
   production frontend.
2. Confirm the frontend's exact-input v4 quote includes the hook result and that
   bounded minimum output protection succeeds.
3. Test discovery and execution in the current Uniswap interface.
4. Submit the hook for any Uniswap registry or custom-accounting allowlist that
   the current interface requires.
5. Test each named aggregator directly. Do not advertise support based only on
   generic Uniswap v4 compatibility.

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
6. Launch managers set withdrawFeeBps, holdingFeeBps, and referralShareBps to
   zero, so underlying exits do not send long-tail assets to the collector and
   permissionless self-controlled referral rebates are disabled.
7. SWAPPER_ROLE converts held USDC through the typed oracle-bounded USDC/WETH
   route after the Base sequencer recovery grace period, or deposits held NARA
   directly.
8. NARA route calls engine.depositRewards(amount).
9. WETH is unwrapped and atomically calls engine.notifyEthRewards{value: amount}().
```

The receipt manager does not mint fee shares. It sends real fee tokens directly
to the fee collector.

The route manager can propose a replacement router and feed pair, but only the
independent default admin can execute the proposal after the two-day delay.
Launch verification must compare the collector's exact runtime code hash,
immutable bindings, route, oracle parameters, and role holders before a manager
address is published.

## Static-vault fee path — not supported by the canonical V2 collector

The old static-vault flow depended on V1-only vault allowlisting and redemption
methods. Those methods do not exist in `NARAIndexFeeCollectorV2`. Static vaults
are outside the current launch and must not be wired to V2. Supporting them
later requires a separately designed, reviewed, and tested collector path.
