# NARA-20260730-audit-remediation

Status: implemented and locally verified; not deployed.

Origin: `nara-protocol-hardhat` remediation working tree under the same change
ID. No downstream address or deployment-state update is authorized by this
record.

## Basket changes

- The V2 collector enforces the Base sequencer recovery grace period, keeps
  USDC depeg protection, accepts honest positive ETH/USD prices outside the old
  permanent absolute band, and requires independent admin execution of delayed
  route proposals.
- Holding-fee accounting uses a cumulative per-asset checkpoint so
  permissionless accrual cadence cannot change the fee.
- Launch deployment requires zero withdrawal, holding, and referral-share fees.
- Post-deployment verification checks the exact collector runtime code hash,
  immutable bindings, route, oracle parameters, roles, and zero launch fees.
- Legacy static-suite deployment entry points are disabled, and repository
  validation rejects future deployment-script references to noncanonical V1
  suite or collector contracts.

## Verification

- Forge formatting: pass.
- Forge build and bytecode sizes: pass.
- Deterministic non-fork suites: 148 pass, 0 fail, 1 environment-dependent
  skip.
- CI invariant profile: pass.
- Base adapter fork suites: 31 pass, 0 fail, 0 skip.
- Candidate-specific `ForkBuyProof`: still required after candidate addresses
  exist.

No production transaction, manifest, or application status was changed.
