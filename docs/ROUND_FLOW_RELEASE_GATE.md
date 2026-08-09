# Complete V4 Round-Flow Release Gate

Last updated: 2026-08-09.

## Current verdict

**Blocked for production. Keep every basket in `preview` or `exit_only`.**

The basket-local source is v4-only. The corrected protocol release and activation
evidence are immutable at `ce71f4dfc9182ab12e12f9c25e91ec40fdb9cb60`
and `ba5aaea730b92d8ce12a94926ec076f3fde85982`. Production basket buying remains
blocked by the missing basket-specific exact-fork round-flow, deployment
authorization, route/role review, and verified manager manifests. The
quarantined incident Hook remains forbidden.

This gate covers the complete value path:

```text
quote -> review -> buy -> immutable custody -> fee/reward accounting
      -> partial exit -> full swap exit or underlying escape
      -> referral claims -> protocol sweeps -> zero residual liabilities
```

## Non-negotiable acceptance matrix

| Surface | Required property | Evidence required | Current state |
|---|---|---|---|
| Quote | Every non-direct leg has a positive quote bound to the exact token pair, input amount, venue, and Hook route | Builder regressions and exact-fork quote sweep | Local guards implemented; production-pool basket fork sweep pending |
| Market depth | Full-size output loses no more than 100 bps versus a 1%-size same-route probe | Buy and both sell directions at minimum, normal, and maximum supported sizes | Runtime guard implemented; deployment-day route proof remains required |
| User limits | Slippage is 0-500 bps and deadline is 1-3,600 seconds | Builder boundary tests and UI bounds | Implemented and locally tested |
| Allocation math | Positive integer weights sum to 10,000 bps; all net input is allocated; every asset receives a positive amount | Unit, fuzz, invariant, and exact-fork buy tests | Local tests implemented; basket exact-fork buy pending |
| Hook binding | NARA uses the exact v4 Hook, fee, tick spacing, Universal Router, Permit2, adapter code hash, and empty `hookData` required by the Hook | Adapter unit test, deployment verifier, manifest parity, exact-fork buy/sell | Immutable protocol handoff recorded; basket adapter deployment and exact-fork proof pending |
| Custody | Token balances always cover position claims, protocol fees, and referral liabilities | Invariant suite and sequential lifecycle test | Locally tested |
| Fee math | Buy/sell/withdraw/holding/referral rounding cannot over-credit or make liabilities insolvent | Boundary, fuzz, invariant, and lifecycle tests | Locally tested; launch withdraw/holding/referral share remain zero |
| Rewards | NARA calls `engine.depositRewards`; WETH is unwrapped and calls `notifyEthRewards`; basket code never calls `notifyTokenRewards` | Collector unit tests and exact-fork collector proof | Interface path is v4-compatible; exact deployed-state proof blocked |
| Full exit | Every live position can sell all assets to the exposed production output (USDC) or withdraw raw underlying | Exact-fork USDC sell plus direct-withdraw tests at supported sizes | Contract path tested; final basket routes pending |
| Partial exit | Selected assets can exit while an unavailable component remains | Unit and invariant tests | Locally tested |
| Underlying escape | The owner can bypass DEXs, withdraw all or selected underlying, and close when empty | Unit, invariant, and sequential lifecycle tests | Locally tested |
| Settlement | Referral claims and permissionless fee sweeps leave no manager residue or liability after final close | Sequential lifecycle test | Locally tested |
| Oracle | Sequencer recovery, positive/complete rounds, USDC depeg bounds, and feed-specific freshness are enforced | Boundary, stale, future, incomplete, depeg, and sequencer tests | Locally tested; deployment feed/runtime proof blocked |
| Deployment identity | One immutable v4 origin and verified receipt supply exact addresses, config hash, runtime hashes, roles, PoolKey, and handoff | Saved manifest plus verifier output | Protocol identity recorded; basket managers and basket manifests do not exist |
| App release | Preview, review, confirmation, and exit paths have no dead ends; `live` requires every row green | Browser flow test and production environment gates | Fail-closed; `live` is intentionally rejected |

## Oracle decision

The collector uses independent immutable limits:

- `maxUsdcOracleAge = 93,600 seconds`, matching the reviewed daily USDC/USD
  heartbeat with delivery margin while retaining the 0.9-1.1 depeg bound;
- `maxEthOracleAge = 3,600 seconds`; and
- tests prove each feed expires independently and accepts its exact boundary.

A single shared 93,600-second limit does not pass this gate.

## Exact v4 handoff requirements

Before any basket address or app environment is made production-active:

1. Use protected protocol release
   `ce71f4dfc9182ab12e12f9c25e91ec40fdb9cb60`, activation evidence
   `ba5aaea730b92d8ce12a94926ec076f3fde85982`, and contract/artifact source
   `027af3f06bbe6dea2c187dfd8062e50c228f1c35`.
2. Keep the quarantined Hook and every retired Stage A address out of basket
   configuration and manifests.
3. Build the basket adapter and manager candidate from that handoff, run the
   exact-fork proof, and prove buy, sell-to-USDC, partial exit, and underlying
   withdrawal. Do not claim an all-assets-to-NARA route.
4. Obtain explicit basket deployment authorization after route, role, oracle,
   and recovery review.
5. Save one basket manifest per manager and run `VerifyDeployedBasket` plus
   `check:manifest-env` before changing a basket status to `live`.

## Local executable gates

Run from the basket repository root:

```powershell
node scripts/check-repository.mjs
& "$env:USERPROFILE\.foundry\bin\forge.exe" fmt --check
& "$env:USERPROFILE\.foundry\bin\forge.exe" build --sizes
& "$env:USERPROFILE\.foundry\bin\forge.exe" test `
  --no-match-path "test/*Fork*.t.sol" `
  --no-match-contract NARAImmutableBasketPositionManagerV1InvariantTest
$env:FOUNDRY_PROFILE = "ci"
& "$env:USERPROFILE\.foundry\bin\forge.exe" test `
  --match-contract NARAImmutableBasketPositionManagerV1InvariantTest
Remove-Item Env:FOUNDRY_PROFILE
npm ci --prefix app
npm run check --prefix app
npm audit --prefix app --audit-level=high
```

Then run the Base adapter fork suite and an exact `ForkBuyProof` using the
corrected Hook and the same immutable manifest intended for release.

## Release rule

No row may be waived silently. A blocked row requires a code/test fix or an
explicit, recorded release decision. The production deployment entrypoint and
app `live` state remain deliberately fail-closed until every row is green.
