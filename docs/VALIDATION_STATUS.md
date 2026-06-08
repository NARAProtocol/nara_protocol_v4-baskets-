# Validation Status

Last validated: 2026-06-03

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

# Clean non-fork suite
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --root nara-category-baskets-v1 `
  --no-match-contract "AerodromeBasketAdapterV1Test|ForkBuyProof"

# Aerodrome Base fork suite
$rpc = <load BASE_MAINNET_RPC_URL or BASE_RPC_URL from nara-protocol-hardhat\.env>
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
Non-fork tests: 122 passed, 0 failed.
Aerodrome Base fork tests: 15 passed, 0 failed.
Plain full test without fork context: 122 passed, 2 failed because fork-only
suites need the right fork/deployment context.
```

Covered non-fork suites:

```text
NARAImmutableBasketPositionManagerV1Test    - 47 tests
CategoryIndexSuiteV1Test                    - 19 tests
NARAIndexFeeCollectorV1Test                 - 14 tests
NARAIndexFeeCollectorV2Test                 - 14 tests
AerodromeSlipstreamBasketAdapterV1Test      - 9 tests
PancakeV3BasketAdapterV1Test                - 10 tests
UniswapV3BasketAdapterV1Test                - 9 tests
```

Fork-only suites:

```text
AerodromeBasketAdapterV1Test                - 15 tests, passed with Base RPC.
ForkBuyProof.testForkBuyCore                - local Anvil proof only; env-driven.
```

`ForkBuyProof` is not a direct Base RPC test. It expects the local Anvil fork to
already contain contracts deployed by `script/DeployForkLocal.s.sol`, and now
requires `FORK_MANAGER_CORE`, `FORK_V3_ADAPTER`, `FORK_AERO_ADAPTER`, and
`FORK_NARA_TOKEN`. Missing env or missing deployed code skips the proof instead
of relying on stale hardcoded local addresses.

## Known Tooling Gaps

```text
forge fmt --check:
  Fails with existing formatting diffs. Do not assume this means the latest
  audit changed source formatting.

forge coverage:
  Fails without IR due stack-too-deep.
  Also fails with --ir-minimum in CategoryIndexFactoryV1 stack layout.
  Normal build and tests still pass.

slither:
  Not installed on PATH in the local shell.

mythril:
  Not installed on PATH in the local shell.

aderyn:
  Command exists globally, but the npm global install is broken because
  @cyfrin/aderyn/run-aderyn.js is missing.
```

## Notes

The project uses `via_ir = true` in `foundry.toml` under Solidity 0.8.34.

The receipt manager is tested with mock exact-input adapters plus production
adapter unit/fork tests. Coverage includes buy, sell-to-USDC, sell-to-NARA,
partial raw withdrawal, selected-asset partial exit, receiver guards, immutable
constructor config, holding fee accrual/sweep, referral splits, adapter
accounting lies, allocation/slippage checks, and solvency views.

Frontend validation for `apps/nara-baskets` on 2026-06-03:

```powershell
npm run typecheck       # pass
npm run test:builders   # pass
npm run build           # pass
```

`npm run build` emits third-party Rolldown pure-annotation warnings from wallet
dependencies plus a chunk-size warning, but exits successfully.

External audit remains pending.
