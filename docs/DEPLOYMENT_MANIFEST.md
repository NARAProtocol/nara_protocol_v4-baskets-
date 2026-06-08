# NARA Baskets Deployment Manifest

Last updated: 2026-06-03

This is the launch handoff checklist for a cold AI, deployer, or reviewer. A
deployment is not production-ready until every basket has a saved manifest and
passes the on-chain verifier.

## Canonical Scripts

Use only:

```powershell
& "$env:USERPROFILE\.foundry\bin\forge.exe" script `
  script/DeployMainnetReady.s.sol:DeployMainnetReady `
  --root nara-category-baskets-v1 `
  --rpc-url $env:BASE_MAINNET_RPC_URL `
  --broadcast

& "$env:USERPROFILE\.foundry\bin\forge.exe" script `
  script/VerifyDeployedBasket.s.sol:VerifyDeployedBasket `
  --root nara-category-baskets-v1 `
  --rpc-url $env:BASE_MAINNET_RPC_URL
```

Do not use `DeployBaseMainnet.s.sol` or `DeployBaseSepolia.s.sol`. They are
legacy paths and intentionally revert.

## Manifest Fields

Save one manifest per basket under:

```text
nara-category-baskets-v1/deployments/base-mainnet/base.json
nara-category-baskets-v1/deployments/base-mainnet/ai.json
nara-category-baskets-v1/deployments/base-mainnet/meme.json
nara-category-baskets-v1/deployments/base-mainnet/defi.json
```

Set `NARA_BASKET_MANIFEST_DIR` when using a different manifest directory.

Each manifest must contain:

```json
{
  "chainId": 8453,
  "basketKey": "core",
  "manager": "0x...",
  "nara": "0x...",
  "usdc": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  "weth": "0x4200000000000000000000000000000000000006",
  "feeCollector": "0x...",
  "adapters": {
    "uniswapV3": "0x...",
    "aerodrome": "0x...",
    "slipstream": "0x...",
    "pancakeV3": "0x...",
    "uniswapV4": "0x..."
  },
  "category": "CORE",
  "basketName": "CORE",
  "displayTier": 1,
  "assets": ["0x...", "0x...", "0x..."],
  "weightsBps": [1000, 3000, 3000, 2000, 1000],
  "paymentTokens": ["0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", "0x4200000000000000000000000000000000000006"],
  "buyFeeBps": 10,
  "sellFeeBps": 10,
  "withdrawFeeBps": 10,
  "holdingFeeBps": 0,
  "referralShareBps": 0,
  "maxWeightDeviationBps": 100,
  "minNaraWeightBps": 500,
  "minInputAmount": "25000000",
  "configHash": "0x..."
}
```

## Verifier Env

Set these values from the saved manifest before running
`VerifyDeployedBasket.s.sol`:

```text
EXPECTED_CHAIN_ID=8453
MANAGER=0x...
EXPECTED_NARA=0x...
EXPECTED_FEE_RECIPIENT=0x...
EXPECTED_CATEGORY=CORE
EXPECTED_BASKET_NAME=CORE
EXPECTED_DISPLAY_TIER=1
EXPECTED_ASSETS=0x...,0x...,0x...
EXPECTED_WEIGHTS=1000,3000,3000,2000,1000
EXPECTED_PAYMENT_TOKENS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,0x4200000000000000000000000000000000000006
EXPECTED_ADAPTERS=0x...,0x...,0x...,0x...,0x...
EXPECTED_BUY_FEE_BPS=10
EXPECTED_SELL_FEE_BPS=10
EXPECTED_WITHDRAW_FEE_BPS=10
EXPECTED_HOLDING_FEE_BPS=0
EXPECTED_REFERRAL_SHARE_BPS=0
EXPECTED_MAX_WEIGHT_DEV_BPS=100
EXPECTED_MIN_NARA_WEIGHT_BPS=500
EXPECTED_MIN_INPUT_AMOUNT=25000000
```

## Frontend Parity

The verified addresses must match `apps/nara-baskets` production env:

```text
VITE_BASKET_MANAGER_BASE
VITE_BASKET_MANAGER_AI
VITE_BASKET_MANAGER_MEME
VITE_BASKET_MANAGER_DEFI
VITE_BASKET_ADAPTER
VITE_BASKET_ADAPTER_AERO
VITE_BASKET_ADAPTER_SLIPSTREAM
VITE_BASKET_ADAPTER_PANCAKE
VITE_BASKET_ADAPTER_V4
VITE_NARA_FEE_COLLECTOR
VITE_NARA_TOKEN
VITE_NARA_V4_HOOK
VITE_NARA_V4_POOL_FEE
VITE_NARA_V4_TICK_SPACING
VITE_UNISWAP_V4_QUOTER
```

If the frontend env and verified on-chain manager disagree, buying must stay in
preview or disabled mode.

The frontend production deploy gate enforces this with:

```powershell
cd apps/nara-baskets
npm run check:manifest-env
```

`deploy:cf:prod` runs this after `check:prod-env`; production cannot ship unless
all four saved manifests match the frontend env and launch curation.

`minInputAmount` is a raw token-unit floor checked against the payment token.
`25000000` is a 25 USDC floor for the USDC path. It is not USD-normalized for
WETH; if WETH buys need a strict USD minimum, enforce that at the UI/operations
layer or deploy a payment-token-specific minimum design in a future manager.

For the first public Base launch, `check:manifest-env` enforces conservative
defaults:

- `withdrawFeeBps` must match the basket `sellFeeBps`.
- `holdingFeeBps` must be `0`.
- `referralShareBps` must be `0`.
- `minInputAmount` must be a positive integer.

Changing those values is a product/legal launch decision and must update the
launch curation, frontend copy, and this gate together.

## Required Launch Proof

Before mainnet UI is marked live:

1. `forge build --root nara-category-baskets-v1` passes.
2. Non-fork tests pass.
3. Aerodrome fork adapter tests pass against Base RPC.
4. `VerifyDeployedBasket.s.sol` passes for every basket.
5. The v4 NARA hook pool quote works through `VITE_UNISWAP_V4_QUOTER` or the
   default Base v4 quoter.
6. `apps/nara-baskets` typecheck, builder tests, and production build pass.
7. No UI copy recommends a basket, implies suitability, or says the product is
   safe, protected, guaranteed, optimized, or best.

Current setup baseline from 2026-06-03:

```text
forge test --root nara-category-baskets-v1
129 passed, 0 failed, 2 skipped

forge test --root nara-category-baskets-v1 --match-path test/AerodromeBasketAdapterV1.t.sol --fork-url <BASE_RPC_URL>
15 passed, 0 failed, 0 skipped
```

The skipped non-fork tests are fork-gated proofs. The v4 fork proof remains
post-NARA-pool work because it requires:

```text
V4_FORK_RPC
V4_UNIVERSAL_ROUTER
V4_PERMIT2
V4_TOKEN_IN
V4_TOKEN_OUT
V4_AMOUNT_IN
V4_FEE
V4_TICK_SPACING
V4_HOOK
V4_WHALE
```
