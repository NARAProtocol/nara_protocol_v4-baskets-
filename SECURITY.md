# Security policy

## Status

NARA Baskets is pre-launch. No basket manager, adapter set, or fee collector is
published as a Base mainnet deployment. The app is preview-only until verified
deployment manifests and production environment parity pass.

No independent audit is claimed. Automated analysis and internal review cannot
guarantee the absence of defects.

## Supported scope

Security fixes are accepted for the current default branch and the latest
maintainer-designated release candidate.

In scope:

- `src/NARAImmutableBasketPositionManagerV1.sol`
- `src/NARAIndexFeeCollectorV2.sol`
- every adapter under `src/adapters/`
- `script/DeployMainnetReady.s.sol`
- `script/VerifyDeployedBasket.s.sol`
- app transaction builders, manifest gates, and value-bearing flows under `app/`

Reference-only contracts such as `NARAIndexFeeCollectorV1` and
`CategoryIndexSuiteV1` are not part of the receipt-basket launch deployment.

## Security model

- **Immutable receipt manager.** It has no owner, pause, upgrade path, admin
  sweep, or mutable basket configuration.
- **Owner-only receipt actions.** Approval-based operators are disabled. The
  literal receipt owner controls sell and withdrawal actions.
- **Exact accounting.** The manager and adapters compare real balance deltas,
  reject non-exact inputs, and enforce minimum output.
- **Canonical NARA pool.** The required v4 adapter pins the fee, tick spacing,
  and hook in constructor immutables and rejects dynamic route data.
- **DEX-independent withdrawal.** Recorded assets can be requested without a
  swap or keeper. A component token that blocks its own transfer can still block
  that token; selected-asset withdrawal keeps unaffected assets recoverable.
- **Constrained fee collector.** USDC conversion uses one typed route with a
  Base sequencer recovery grace period, fresh positive price rounds, a USDC
  depeg bound, oracle-derived minimum output, exact spend/output checks, and
  atomic engine notification. NARA reward deposits verify the engine binding
  and exact token pull.
- **Separated authority.** Admin, swapper, and route manager are distinct. Route
  replacement is delayed for two days and can be cancelled by the independent
  admin guardian.
- **Fail-closed app.** Missing or mismatched deployment state, NARA pool
  configuration, depth, status, or manifests must keep buying disabled.

## Verification evidence

The dated, reproducible evidence ledger is
[`docs/VALIDATION_STATUS.md`](docs/VALIDATION_STATUS.md). The repository CI
includes:

- repository integrity, local-link, JSON, submodule, secret-pattern, and Action
  SHA checks;
- formatting, bytecode-size, deterministic, fuzz, and invariant contract gates;
- app builder, copy, parity, type, build, and High/Critical dependency gates;
- Slither and Aderyn advisory analysis;
- CodeQL for the JavaScript/TypeScript app;
- a manual Base adapter fork gate that fails when its RPC secret is absent.

`ForkBuyProof` remains a required pre-deployment rehearsal against a candidate
stack on a local Base fork.

## Known trust and availability limits

- Basket composition and routes are permanent after manager deployment.
- The fee collector depends on its configured router, price feeds, WETH, and
  NARA engine.
- A compromised swapper cannot change the route but can choose when to execute
  an allowed conversion.
- A compromised route manager can queue a route change, but cannot bypass the
  delay or the independent admin's affirmative execution.
- Third-party token, oracle, router, pool, and RPC behavior is outside NARA's
  control.
- Thin liquidity, stale quotes, MEV, token transfer restrictions, or venue
  downtime can cause transactions to revert or produce poor execution within
  the user's stated limits.
- Immutability removes recovery powers as well as administrative risk.

## Reporting a vulnerability

Report suspected vulnerabilities privately. Do not open a public issue, pull
request, discussion, or social-media thread for an unresolved exploit.

- Email: **security@naraprotocol.pro**
- Include the affected commit and contract or app file.
- Include exact file and line references.
- Include prerequisites, impact, and a reproducing transaction or test sequence
  when possible.
- Do not include private keys, seed phrases, wallet files, private RPC URLs, or
  unnecessary personal information.

The maintainers will validate the report, coordinate remediation, and agree on
disclosure timing before public discussion. No bounty, payment, or response-time
guarantee is offered unless a separate published program explicitly states it.

## Safe-harbor intent

Good-faith research should avoid privacy violations, service disruption,
unnecessary extraction of value, and access beyond what is required to
demonstrate the issue. Use local tests or a fork whenever possible.

## Contact

- Website: [naraprotocol.pro](https://naraprotocol.pro)
- Security email: [security@naraprotocol.pro](mailto:security@naraprotocol.pro)
