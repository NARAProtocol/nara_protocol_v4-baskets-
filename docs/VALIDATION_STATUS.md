# Validation Status

Last validated: 2026-07-30.

No independent audit is claimed. Current assurance is repository tests, fork
verification, and documented internal multi-agent review.

## Local Tooling

Forge is installed locally, but it is not on `PATH` by default in this
workspace shell.

Use:

```powershell
& "$env:USERPROFILE\.foundry\bin\forge.exe" --version
& "$env:USERPROFILE\.foundry\bin\forge.exe" build --root nara-category-baskets-v1
```

Always pass `--root nara-category-baskets-v1` when running from the workspace
root.

Base fork RPC values live in `nara-protocol-hardhat\.env`. Use
`BASE_MAINNET_RPC_URL` first, then `BASE_RPC_URL` as fallback. Do not print the
RPC value or any `.env` secret in chat, logs, reports, or audit artifacts.

## Commands Used

```powershell
# Build
& "$env:USERPROFILE\.foundry\bin\forge.exe" build --root nara-category-baskets-v1

# Deterministic non-fork suite
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --root nara-category-baskets-v1 `
  --no-match-path "test/*Fork*.t.sol" `
  --no-match-contract NARAImmutableBasketPositionManagerV1InvariantTest

# Bounded CI invariant suite
$env:FOUNDRY_PROFILE = "ci"
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --root nara-category-baskets-v1 `
  --match-contract NARAImmutableBasketPositionManagerV1InvariantTest
Remove-Item Env:FOUNDRY_PROFILE

# Base adapter fork suites
$envFile = Get-Content "nara-protocol-hardhat\.env"
$rpcLine = $envFile | Where-Object { $_ -match '^(BASE_MAINNET_RPC_URL|BASE_RPC_URL)=' } | Select-Object -First 1
if (-not $rpcLine) { throw "BASE_MAINNET_RPC_URL or BASE_RPC_URL is required" }
$rpc = ($rpcLine -split '=', 2)[1].Trim().Trim('"').Trim("'")
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --root nara-category-baskets-v1 `
  --match-path "test/*Fork.t.sol" --fork-url $rpc
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --root nara-category-baskets-v1 `
  --match-path "test/AerodromeBasketAdapterV1.t.sol" --fork-url $rpc

# Formatting check
& "$env:USERPROFILE\.foundry\bin\forge.exe" fmt --check --root nara-category-baskets-v1

# Coverage attempt
& "$env:USERPROFILE\.foundry\bin\forge.exe" coverage --root nara-category-baskets-v1 `
  --no-match-contract "AerodromeBasketAdapterV1Test|ForkBuyProof" --ir-minimum
```

## Result

```text
Forge version: 1.4.3-stable, called by absolute path.
Build: pass.
Deterministic non-fork suite: 148 passed, 0 failed, 1 environment-dependent
skip (149 total). Fork-named suites were excluded from this command.
CI invariant suite: 4 passed, 0 failed, 0 skipped. Each of the three stateful
invariants ran 256 campaigns and 16,384 calls; the rescue fuzz property ran
1,000 cases.
```

Covered non-fork suites:

```text
NARAImmutableBasketPositionManagerV1Test    - 49 tests
CategoryIndexSuiteV1Test                    - 19 tests
NARAIndexFeeCollectorV1Test                 - 14 tests
NARAIndexFeeCollectorV2Test                 - 23 tests
AerodromeSlipstreamBasketAdapterV1Test      - 9 tests
PancakeV3BasketAdapterV1Test                - 10 tests
UniswapV3BasketAdapterV1Test                - 9 tests
UniswapV4BasketAdapterV1Test                - 8 tests
DeployMainnetReadyTest                      - 1 test
DisabledLegacyDeploymentTest                - 3 tests
VerifyDeployedBasketTest                    - 3 tests
```

Fork-dependent suites skipped without their required context:

```text
UniswapV3BasketAdapterV1ForkTest
AerodromeBasketAdapterV1Test
ForkBuyProof
PancakeV3BasketAdapterV1ForkTest
AerodromeSlipstreamBasketAdapterV1ForkTest
```

`ForkBuyProof` is not a direct Base RPC test. It expects the local Anvil fork to
already contain contracts deployed by `script/DeployForkLocal.s.sol`, and now
requires `FORK_MANAGER_CORE`, `FORK_V3_ADAPTER`, `FORK_AERO_ADAPTER`, and
`FORK_NARA_TOKEN`. Missing env or missing deployed code skips the proof instead
of relying on stale hardcoded local addresses.

## Known Tooling Gaps

```text
forge fmt --check:
  Passes after applying canonical forge formatting to the working tree.

forge coverage:
  Fails without IR due stack-too-deep.
  Also fails with --ir-minimum in CategoryIndexFactoryV1 stack layout.
  Normal build and tests still pass.

slither:
  Slither 0.11.5 was run over the canonical source set through the pinned
  Python environment. It completed analysis of 50 contracts and emitted 115
  raw detector results. The nonzero exit reflects detector output, not a
  compilation failure. Reentrancy-balance reports cover functions protected by
  nonReentrant and deliberate before/after balance accounting; weak-PRNG is a
  fee-remainder modulo operation, not randomness; default-zero locals,
  timestamp deadlines, bounded external-call loops, and style/gas detectors
  remain analyzer review items. CI reruns Slither as an explicitly advisory
  check. This is not an independent audit or proof that every raw result is a
  false positive.

mythril:
  Not installed on PATH in the local shell.

aderyn:
  The Windows PATH entry is a stale npm shim whose target package is absent, so
  no local Aderyn result is claimed. CI installs Aderyn on Linux from the
  installer at the immutable commit recorded in ci.yml and runs it as an
  advisory check.
```

## Notes

The project uses `via_ir = true` in `foundry.toml` under Solidity 0.8.34.

The receipt manager is tested with mock exact-input adapters plus production
adapter unit/fork tests. Coverage includes buy, sell-to-USDC, sell-to-NARA,
partial raw withdrawal, selected-asset partial exit, receiver guards, immutable
constructor config, holding fee accrual/sweep, referral splits, adapter
accounting lies, allocation/slippage checks, and solvency views.

Frontend validation for `app/` on 2026-07-29:

```powershell
npm run test:builders   # pass
npm run check:copy      # pass
npm run check:launch-config # pass
npm run build           # pass
npm run check           # pass
```

`npm run build` emits third-party Rolldown pure-annotation warnings from wallet
dependencies plus a chunk-size warning, but exits successfully.

Frontend dependency audit on 2026-07-29:

```text
npm audit --audit-level=high: 0 critical, 0 high, 9 moderate.
```

The remaining moderate advisory is `uuid < 11.1.1` inside MetaMask connector
dependencies. npm proposes Wagmi 3 as the automatic fix, but RainbowKit 2.2.11
requires Wagmi 2. The compatible stack therefore remains on Wagmi 2.19.5 with
Viem 2.55.10, Vite 8.1.5, Wrangler 4.115.0, and patched Axios/`ws` overrides.
Do not claim zero advisories; do not use `npm audit fix --force` without a
reviewed RainbowKit/Wagmi migration and wallet regression plan.

The Base adapter fork suites were rerun on 2026-07-30: 31 passed, 0 failed,
0 skipped across Uniswap V3, Aerodrome AMM, Aerodrome Slipstream, and
PancakeSwap V3. The manual GitHub Actions gate runs both the three
`*Fork.t.sol` suites and the separately named 16-test
`AerodromeBasketAdapterV1.t.sol` suite so neither group is silently omitted.
`ForkBuyProof` was not run because it requires the candidate manager and
adapters to be deployed on the local fork first; that rehearsal remains
required before deployment. Independent review has not been performed and is
not represented as complete.

The frontend production gates currently fail closed, as intended:

- fork mode and a LINK stand-in are still configured;
- the replacement fee collector, v4 adapter, hook, pool fee, and tick spacing
  are not populated with verified production values;
- basket status values are not explicitly live/exit-only; and
- `deployments/base-mainnet/{base,ai,meme,defi}.json` do not exist.

These are deployment-state failures, not source-test failures. Never replace
them with guessed addresses or bypass the checks.
