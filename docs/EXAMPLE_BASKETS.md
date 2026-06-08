# Example Basket Deployment Config

These examples are deployment templates, not address recommendations. Replace every placeholder with verified Base token addresses, liquidity checks, and seed amounts before creating vaults.

## Canonical receipt baskets

The user-facing one-click V1 product should create baskets in:

```text
NARAImmutableBasketPositionManagerV1
```

Receipt baskets do not need seed amounts. Deploy one immutable manager per
basket. Each manager buys assets for each user at execution time through its
constructor-fixed adapters.

Shared receipt settings:

```text
feeRecipient = NARAIndexFeeCollectorV2
paymentTokens = [USDC, WETH]
adapters = [
  UniswapV3BasketAdapterV1      0x2626664c2603336E57B271c5C0b26F421741e481
  AerodromeBasketAdapterV1      0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
  AerodromeSlipstreamBasketAdapterV1 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
  PancakeV3BasketAdapterV1      0x1b81D678ffb9C0263b24A97847620C99d213eB14
]
requiredAsset = NARA
minRequiredAssetWeightBps = deployment configured minimum
buyFeeBps = configured fee
sellFeeBps = configured fee
withdrawFeeBps = configured fee (defaults to sellFeeBps if not set; cap 100 = 1%)
maxWeightDeviationBps = set from route depth and quote precision
weightsBps total = 10000
```

Receipt basket example:

```text
categoryId = keccak256("CULTURE")
name = NARA CULTURE Basket
riskTier = 3 (neutral metadata; do not display as advice)
assets = [NARA, CULTURE_TOKEN_A, CULTURE_TOKEN_B, CULTURE_TOKEN_C]
weightsBps = [1000, 4000, 3000, 2000]
paymentTokens = [USDC, WETH]
buyFeeBps = 30
sellFeeBps = 30
withdrawFeeBps = 30
maxWeightDeviationBps = 50
feeRecipient = NARAIndexFeeCollectorV2
```

Buy quote builder must produce:

```text
inputAmount
directAmountsIn
per-asset minAmountsOut
exact-input swap instructions
deadline
```

Sell quote builder must produce:

```text
outputToken
whole-position swap instructions
minOutputAmount
deadline
```

## Static ERC20 vault examples

The following examples apply only to `CategoryIndexVaultV1`.

V1 vaults are verified pro-rata baskets. `weightsBps` are target/display
metadata and do not enforce live NAV weights. Seed amounts must be selected by
the vault creator from off-chain price and liquidity checks before deployment.

## Shared settings

```text
feeRecipient = NARAIndexFeeCollectorV2
initialShareReceiver = deployment reserve or operations wallet
mintFeeBps = configured fee
redeemFeeBps = configured fee
weightsBps total = 10000
```

## AI

```text
name = NARA AI Index
symbol = NAI
category = AI
categoryId = keccak256("AI")
riskTier = 2 (neutral metadata; do not display as advice)
mintFeeBps = 20
redeemFeeBps = 20
assets = [AI_TOKEN_A, AI_TOKEN_B, AI_TOKEN_C]
weightsBps = [4000, 3500, 2500]
seedAmounts = [AI_SEED_A, AI_SEED_B, AI_SEED_C]
```

## CORE

```text
name = NARA CORE Index
symbol = NCORE
category = CORE
categoryId = keccak256("CORE")
riskTier = 1 (neutral metadata; do not display as advice)
mintFeeBps = 10
redeemFeeBps = 10
assets = [CORE_TOKEN_A, CORE_TOKEN_B, CORE_TOKEN_C]
weightsBps = [5000, 3000, 2000]
seedAmounts = [CORE_SEED_A, CORE_SEED_B, CORE_SEED_C]
```

## FINANCE

```text
name = NARA FINANCE Index
symbol = NFIN
category = FINANCE
categoryId = keccak256("FINANCE")
riskTier = 2 (neutral metadata; do not display as advice)
mintFeeBps = 20
redeemFeeBps = 20
assets = [FINANCE_TOKEN_A, FINANCE_TOKEN_B, FINANCE_TOKEN_C]
weightsBps = [4500, 3500, 2000]
seedAmounts = [FINANCE_SEED_A, FINANCE_SEED_B, FINANCE_SEED_C]
```

## CULTURE

```text
name = NARA CULTURE Index
symbol = NCULT
category = CULTURE
categoryId = keccak256("CULTURE")
riskTier = 3 (neutral metadata; do not display as advice)
mintFeeBps = 30
redeemFeeBps = 30
assets = [CULTURE_TOKEN_A, CULTURE_TOKEN_B, CULTURE_TOKEN_C]
weightsBps = [5000, 3000, 2000]
seedAmounts = [CULTURE_SEED_A, CULTURE_SEED_B, CULTURE_SEED_C]
```

## RWA

```text
name = NARA RWA Index
symbol = NRWA
category = RWA
categoryId = keccak256("RWA")
riskTier = 2 (neutral metadata; do not display as advice)
mintFeeBps = 20
redeemFeeBps = 20
assets = [RWA_TOKEN_A, RWA_TOKEN_B, RWA_TOKEN_C]
weightsBps = [4000, 3000, 3000]
seedAmounts = [RWA_SEED_A, RWA_SEED_B, RWA_SEED_C]
```
