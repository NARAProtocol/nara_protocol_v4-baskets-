# Basket Deployment Manifests

Last updated: 2026-07-30.

Status: no production basket manifest exists. No basket manager, V2 fee
collector, or production adapter set is represented as deployed.

Production remains blocked until every launch basket has a saved manifest and
the verifier and frontend parity checks pass.

## Canonical locations

Save one JSON file per basket:

```text
deployments/base-mainnet/base.json
deployments/base-mainnet/ai.json
deployments/base-mainnet/meme.json
deployments/base-mainnet/defi.json
```

Legacy storage/env keys map to public names as follows:

| Storage key | Public name |
|---|---|
| `base` | `CORE` |
| `ai` | `AI` |
| `meme` | `CULTURE` |
| `defi` | `FINANCE` |

The key is an implementation identifier, not a suitability or risk label.

## Required manifest fields

Each saved JSON object must contain:

| Field | Type | Required value |
|---|---|---|
| `chainId` | integer | `8453` |
| `basketKey` | string | One storage key from the table above |
| `manager` | EVM address string | Deployed immutable manager |
| `nara` | EVM address string | `0x65E247AA3aa9C0131b2984b894c3D24c41341D7A` |
| `usdc` | EVM address string | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `weth` | EVM address string | `0x4200000000000000000000000000000000000006` |
| `feeCollector` | EVM address string | Deployed canonical V2 collector |
| `feeCollectorCodeHash` | 32-byte hex string | Exact reviewed runtime code hash for that immutable deployment |
| `adapters` | object | All five deployed adapter addresses |
| `category` | string | Public name |
| `basketName` | string | Public name |
| `displayTier` | integer | Exact immutable constructor value; UI must not present it as suitability |
| `assets` | EVM address array | Exact immutable asset order |
| `weightsBps` | integer array | Exact immutable weights; total must equal `10_000` |
| `paymentTokens` | EVM address array | Must equal `[Base USDC]` for Basket V1 |
| `buyFeeBps` | integer | Exact immutable value |
| `sellFeeBps` | integer | Exact immutable value |
| `withdrawFeeBps` | integer | Exact immutable value |
| `holdingFeeBps` | integer | `0` for the first public launch |
| `referralShareBps` | integer | `0` for the first public launch |
| `maxWeightDeviationBps` | integer | Exact immutable value |
| `minNaraWeightBps` | integer | Exact immutable value |
| `minInputAmount` | decimal string | Positive raw payment-token-unit floor |
| `configHash` | 32-byte hex string | On-chain manager `configHash()` |
| `collectorAdmin` | EVM address string | Contract Safe/guardian; distinct from swapper and route manager |
| `collectorSwapper` | EVM address string | Separate operational signer |
| `collectorRouteManager` | EVM address string | Contract timelock; distinct from admin and swapper |
| `collectorRouter` | EVM address string | Typed SwapRouter02 route |
| `collectorUsdcUsdFeed` | EVM address string | Reviewed USDC/USD feed |
| `collectorEthUsdFeed` | EVM address string | Reviewed ETH/USD feed |
| `collectorPoolFee` | integer | Direct USDC/WETH pool fee |
| `collectorMaxOracleAge` | integer | Immutable seconds |
| `collectorMaxSlippageBps` | integer | Immutable basis points, at most 500 |

Do not create a manifest before deployment. Do not insert guessed addresses,
zero addresses, example hashes, or copied values from another basket.

## Deployment evidence

For every manifest, record separately:

- deployment transaction hash;
- deployment block;
- Basescan manager URL;
- Basescan collector URL;
- Basescan adapter URLs;
- role-handoff transaction evidence;
- exact-fork rehearsal evidence;
- verifier output;
- buy, sell, and `withdrawUnderlying` smoke evidence.

## Verification

Load verifier environment values directly from the saved manifest. Do not type
or copy shortened addresses.

Run from this repository root:

```powershell
& "$env:USERPROFILE\.foundry\bin\forge.exe" script `
  script/VerifyDeployedBasket.s.sol:VerifyDeployedBasket `
  --rpc-url "$env:BASE_MAINNET_RPC_URL"
```

The verifier environment must describe the same basket as the selected
manifest. `VerifyDeployedBasket.s.sol` checks chain ID, manager configuration,
assets, weights, payment tokens, adapters, zero launch fees, required NARA
weight, minimum input, configuration hash, exact collector runtime code hash,
collector immutable bindings, typed route, oracle parameters, and separated
role holders.

## Frontend parity

The production frontend reads these storage-key variables:

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

Run:

```powershell
npm run check:manifest-env --prefix app
```

If a manifest, on-chain manager, launch curation, or frontend variable
disagrees, the basket must remain in preview.

## Current launch constraints

- `withdrawFeeBps` must be `0`.
- `holdingFeeBps` must be `0`.
- `referralShareBps` must be `0`.
- `minInputAmount` must be a positive integer.
- `ADMIN`, `SWAPPER`, and `ROUTE_MANAGER` must be distinct.
- `ADMIN` and `ROUTE_MANAGER` must be contracts; the deploy script rejects
  EOAs for those roles.
- Collector route, feeds, pool fee, age bound, and slippage bound must match
  the reviewed deployment evidence.
- Static vaults are not part of the launch and cannot use the V2 collector's
  nonexistent V1 vault-redemption methods.
