# NARA-20260808-v4-relaunch-remediation

Change-ID: `NARA-20260808-v4-relaunch-remediation`

Origin remote: `NARAProtocol/nara_protocol_v4_baskets`

Origin commit: pending protected-branch review; the clean release branch is
rebuilt from protected `main` base
`c2ea6b3ca855b4a9969d1252520d464b8dafe413`.

Upstream protocol release commit:
`ce71f4dfc9182ab12e12f9c25e91ec40fdb9cb60`.

Upstream activation evidence commit:
`ba5aaea730b92d8ce12a94926ec076f3fde85982`.

Upstream contract and generated-artifact source commit:
`027af3f06bbe6dea2c187dfd8062e50c228f1c35`.

Evidence state: implemented and locally tested only. This record does not claim
merged, deployed, configured, activated, or available.

Public identity is restored to root brand `NARA` and presentation ticker
`$NARA`. The raw contract symbol remains `NARA`, and contract names, ABIs,
environment keys, repository names, and basket names remain technical
identifiers rather than presentation copy. The app copy gate enforces the root
brand and rejects the retired `NARA Baskets` masthead.

## Scope and evidence

- Basket buy capacity uses the lower of configured and live USDC-side Hook
  depth and caps NARA allocation at 3%. Fresh same-block reads also bind the
  configured Hook, pool fee, and tick spacing to the immutable v4 adapter before
  quote construction and transaction submission.
- Deterministic app regressions cover CORE's 10% NARA allocation, the 15%
  allocation used by AI/FINANCE/CULTURE, exact boundaries, integer rounding,
  zero/unreadable depth, stale blocks, and Hook/address/binding mismatches.
- Allocation dust uses the same canonical remainder rule in quote and calldata.
  Buy and sell routes refresh immediately before submission; execution preserves
  the stricter reviewed/refreshed minimum and returns to review if the route or
  estimated same-block Hook fee changes.
- Buy and sell reviews disclose the estimated NARA Hook input-token amount and
  effective rate at the pinned quote block. The structurally non-executable
  whole-position NARA conversion option was removed; USDC exits and direct
  underlying-token withdrawals remain.
- `withdrawUnderlying` and `withdrawUnderlyingPartial` remain direct no-swap
  receipt-owner exits and are exposed in the portfolio flow. Partial selected-
  asset exits leave the receipt open until its final asset is removed.
- `NARAIndexFeeCollectorV2` exposes only typed USDC/WETH conversion and direct
  NARA/WETH/native reward forwarding. It preserves per-feed freshness, USDC
  depeg, Base sequencer, exact USDC-spend/WETH-delta, and exact NARA-pull checks.
  Role rotation cannot combine admin, swapper, and route-manager authorities;
  admin and route-manager assignments remain contract-only. Route changes keep
  the two-day proposal delay and either-role cancellation path.
- Launch managers and deployment/verifier gates require zero raw-withdraw,
  holding, and referral-share fees. The production deploy entrypoint continues
  to revert pending basket-specific authorization, exact-Base-fork round-flow,
  route/role review, and deployment-manifest readiness.
- The v4 adapter and verifier require the exact `0x2088` Hook permissions,
  Hook token/base identity, and registered PoolId recomputed from the immutable
  PoolKey. Operator-supplied expected values cannot substitute for those reads.
- The app's source accessibility gate now uses labelled, focus-contained
  dialogs with Escape/focus restoration, labelled numeric settings, named close
  controls, and AA muted/warning color tokens.
- Compatible app dependency updates moved Wrangler to 4.120.0 and Workers Types
  to 5.20260808.1. `npm audit --audit-level=high` reports zero High/Critical;
  nine MetaMask/Wagmi `uuid` Moderate advisories remain because npm's proposed
  remediation is a breaking Wagmi 3 migration.

## Interface and deployment impact

Changed contracts/interfaces: `NARAIndexFeeCollectorV2` constructor/runtime
behavior and immutable getters `maxUsdcOracleAge()` / `maxEthOracleAge()`;
deployment and verification inputs must provide both feed-specific ages. The
collector runtime hash will change and must be recorded from the reviewed build.

Generated basket artifact or ABI source: pending generation from the eventual
merged basket origin commit. Upstream protocol artifacts are pinned to
`027af3f06bbe6dea2c187dfd8062e50c228f1c35`; no ABI or address was copied from
a dirty protocol tree.

Deployment manifest: absent by design. Planned basket manifests remain blank.

Chain and verification block: Base (8453); transaction and block pending.

Depends-on: the protocol dependency is satisfied by protected release
`ce71f4dfc9182ab12e12f9c25e91ec40fdb9cb60`, activation evidence
`ba5aaea730b92d8ce12a94926ec076f3fde85982`, and contract/artifact source
`027af3f06bbe6dea2c187dfd8062e50c228f1c35`. Basket deployment still depends on
an immutable basket release, exact-fork round-flow, deployment authorization,
and one verified sanitized manifest per deployed manager.

Unblocks: exact Base-fork round-flow rehearsal and basket deployment review.
Monitor/publication deployment handoffs remain blocked until a protected basket
commit and verified basket manifests exist.

Downstream repositories reviewed: none modified. Monitor and public docs remain
downstream of a merged basket commit plus verified deployment evidence.

## Commands and results

- `npm run check` in `app/`: pass (builder, copy, launch parity, typecheck, Vite build).
- `npm audit --audit-level=high` in `app/`: pass; 0 High/Critical, 9 Moderate.
- `forge fmt --check`: pass.
- `forge test --match-path test/NARAIndexFeeCollectorV2.t.sol`: 31 passed.
- `forge test --match-path test/NARAImmutableBasketPositionManagerV1.t.sol`: 50 passed.
- `forge test --match-path test/UniswapV4BasketAdapterV1.t.sol`: 13 passed.
- `forge test --match-path test/VerifyDeployedBasket.t.sol`: 8 passed.
- `forge test --match-path test/DeployMainnetReady.t.sol`: 2 passed.
- CI-depth invariant run: three invariants at 256 runs × depth 64 (16,384 calls
  each) plus the fuzz test passed.
- Deterministic non-fork Foundry selection: 169 passed with one environment-only
  skip after the disabled legacy broadcaster regression was added.
- `node scripts/check-repository.mjs`: pass; 109 files inspected, including
  tracked-secret and GitHub Action pin checks.

## Skipped gates and unresolved risks

- An independent CI-depth invariant run passed. A separate local rerun reached
  the five-minute command-wrapper timeout without reporting a failed property;
  do not describe that timed rerun as another pass. Protected CI must rerun the
  canonical invariant command on the immutable release branch.
- No fresh deployment manifests, verified runtime hashes, exact Base-fork
  `ForkBuyProof`, live RPC depth evidence, or production environment parity exist.
- Current route-depth proof for BRETT, TOSHI, MORPHO, and cbETH remains pending.
- The app remains preview/exit-only and the production manifest/environment
  gates must keep failing until the missing evidence exists.

Onchain or production writes: none.

Secret scan: repository gate passed for tracked files; no secret values were
read, printed, or written during this remediation.
