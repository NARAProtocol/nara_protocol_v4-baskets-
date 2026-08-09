# NARA-20260729-baskets-v2-alignment

Last updated: 2026-07-29.

## Release state

```text
Change-ID: NARA-20260729-baskets-v2-alignment
Origin remote: NARAProtocol/nara_protocol_v4_baskets
Origin branch: adapter-fork-tests-2026-06-18
Working-tree base commit: 612adde6d0c05adf1bc2f1078fcd6430d08a10fa
Origin release commit: not created
Evidence state: tested working tree
Deployment state: not deployed
Configuration state: not configured
Activation state: preview only
Onchain or production writes: none
```

The working tree is not an immutable integration source. Downstream ABI,
address, monitoring, verification-package, and availability updates remain
blocked until this work is reviewed and merged and the full default-branch
release commit is recorded here.

## Scope

This release candidate contains:

- the immutable receipt manager and its current solvency, selected-asset exit,
  fee, referral, and adapter accounting behavior;
- the typed, oracle-bounded `NARAIndexFeeCollectorV2`;
- the canonical-pool-bound Uniswap v4 adapter;
- deployment, verification, Base-fork, and launch-parity changes;
- the preview-first app under `app/`;
- repository CI, CodeQL, security, contribution, and maintenance controls; and
- synchronized public technical documentation for the pre-launch state.

## Upstream protocol dependency

`NARAProtocol/nara_protocol_v4` remains authoritative for NARA token, engine,
hook, vault, compounder, pool, generated artifacts, and verified deployment
state.

Production basket deployment remains blocked until the corrected replacement
liquidity stack has a merged engineering release, verified sanitized manifest,
canonical hook and pool values, and completed pre-seed gates. Basket
configuration deliberately leaves production hook, feed, role, manager, and
manifest values absent rather than guessing them.

## Current verification evidence

Verified locally on 2026-07-29:

```text
Forge format: pass
Forge build and bytecode-size gate: pass
Deterministic contract suite: 138 passed, 0 failed, 1 environment-only skip
CI-profile invariant suite: 4 passed, 0 failed
Base adapter fork suites: 31 passed, 0 failed
App clean dependency install: pass
App builder, copy, launch-parity, type and production-build checks: pass
Repository integrity and Git-history secret checks: pass
npm High/Critical audit gate: pass
Moderate transitive wallet advisories: 9
Independent audit: not performed
Candidate-stack ForkBuyProof: not run
Local Aderyn: not available
```

Slither completed over the canonical source set and produced raw advisory
results recorded in `../VALIDATION_STATUS.md`. The result is not represented as
an independent audit or a proof that every detector result is false.

## Downstream monitor handoff

Repository: `NARAProtocol/nara-swarm-monitor`.

Current incompatibility is known and intentionally not patched from this dirty
working tree. The monitor still models legacy basket fee-collector events:

```text
AllowedExecutorSet
AllowedSelectorSet
AllowlistFrozenSet
SwapExecuted
```

`NARAIndexFeeCollectorV2` instead exposes the typed route and reward events:

```text
RouteProposed
RouteExecuted
RouteCancelled
UsdcConvertedAndNotified
NaraRewardsDeposited
EthRewardsNotified
```

After this basket release is merged, the monitor pull request must:

1. record this repository's full merged commit;
2. regenerate or vendor the collector ABI from that commit;
3. update required surface coverage and event handlers;
4. update schema or alert rules if event semantics require it;
5. run the pinned cross-repository drift gate;
6. run the complete monitor verification suite;
7. record the verified basket deployment manifest and start block only after
   deployment; and
8. keep the basket profile disconnected while those production values are
   absent.

## Public documentation handoff

Repository: `NARAProtocol/nara_protocol`.

Public documentation may describe the basket implementation after the merged
release commit is available. It must continue to say preview-only and not
deployed until Base runtime code, constructor data, roles, pool bindings,
manifests, consumer configuration, and smoke evidence are verified.

The public verification package must be regenerated from immutable release
artifacts. It must not copy source, ABIs, addresses, or status prose from this
working tree.

## Required merge order

1. Merge any required upstream v4 interface or liquidity-stack release and
   record its full commit.
2. Review and merge this basket release through protected CI.
3. Replace `Origin release commit: not created` above with the full merged
   basket commit in a follow-up evidence update.
4. Update and merge the monitor from the pinned basket and protocol commits.
5. Deploy only under a separately authorized runbook after every deployment
   gate passes.
6. Record verified manifests, blocks, roles, bindings, backfill, and smoke
   results.
7. Regenerate and merge public documentation last.
8. Change the app from preview only after deployment, configuration,
   integration, and exit-path evidence converge.

## Safety record

- No private key, seed phrase, `.env` value, private RPC URL, signing material,
  or production credential belongs in this handoff.
- No transaction or deployment is authorized by this document.
- No default-branch protection, signature, required check, secret scan, or
  review requirement may be bypassed to accelerate the sequence.
- A new AI must continue from the recorded commits and evidence, not from chat
  history.
