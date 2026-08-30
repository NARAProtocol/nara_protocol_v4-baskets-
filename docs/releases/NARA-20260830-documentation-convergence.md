# NARA-20260830 basket documentation convergence

Status: `DOCUMENTATION_PREVIEW_COPY_AND_FAIL_CLOSED_CONFIG_CANDIDATE`

Change ID: `NARA-20260830-documentation-convergence`

This candidate propagates the protected protocol documentation handoff into
the basket repository. It changes documentation, preview-app copy, metadata,
source comments, and one fail-closed frontend Graduation configuration gate
with focused regression tests. It changes no Solidity behavior, ABI, basket
composition, deployment manifest, production environment, contract address,
transaction, or onchain state.

## Immutable origin

- Upstream repository: `NARAProtocol/nara_protocol_v4`
- Protected upstream merge:
  `dae88079dd336e22bdefde6f45e3b01389d554cb`
- Deployed-contract source recorded upstream:
  `027af3f06bbe6dea2c187dfd8062e50c228f1c35`
- Basket branch base:
  `bacc890004f4ca4fddb49854a7f5670312055a16`

## State language

- The canonical NARA v4 contracts and NARA/USDC pool use real assets in
  technical live testing. That upstream state does not activate baskets.
- The active Base NARA token is
  `0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1`.
- Basket managers, the V2 fee collector, the five-adapter production set, and
  basket manifests remain undeployed or unavailable. The app is preview-only
  and value-bearing basket actions remain disabled.
- The Position NFT Phase-2 baseline is deployed, tested under its recorded
  release gates, source-verified, and Safe-finalized. Its canonical manifest
  remains `integrationReady: false`, so Graduation and other basket consumer
  integrations remain disabled.
- The current deployed Engine generic ERC-20 reward notifier remains
  prohibited. This package uses only its separately tested NARA and native-ETH
  fee routes.

## Legal and presentation boundary

Broad `non-custodial` claims were replaced with factual receipt, recorded-
amount, and contract-control descriptions without making a legal ownership or
custody characterization. USDC position displays are labeled as estimated
gross exit quotes and gross changes based on executable route quotes, not
account statements or promised execution amounts. The preview labels them as
before basket sell fees and gas and discloses the legacy WETH cost-conversion
fallback. The preview does not recommend a basket or activate a transaction
path.

Graduation now requires a separate default-false readiness flag and full
immutable origin commit in addition to its three contract addresses. Addresses
alone cannot expose the `Lock $NARA` action while the upstream manifest remains
`integrationReady: false`.

This repository contains no evidence of completed jurisdiction-specific
qualified legal review. Technical review, deployment, source verification, or
preview controls are not legal approval. Consumer activation or marketing
requires written qualified-counsel review for the relevant entity,
jurisdictions, audience, distribution route, disclosures, and complete user
journey.

## Verification

- Repository verification: passed across 105 files.
- `forge fmt --check`: passed.
- `forge build --sizes`: passed.
- Deterministic non-fork tests: 169 passed, 0 failed, 1 environment-dependent
  skip.
- CI-profile invariant/fuzz tests: 4 passed, including three 256-campaign /
  16,384-call invariants and one 1,000-case rescue property.
- `npm run check --prefix app`: passed builder, copy, launch parity,
  TypeScript, and production build gates.
- `npm audit --prefix app --audit-level=high`: no High or Critical findings;
  nine known Moderate `uuid` findings remain in the compatible wallet stack.
  The available automatic fix requires a breaking Wagmi migration and was not
  applied.
- Independent technical and legal/comms reviews: clean after corrections.
- `git diff --check`: passed.

No RPC-dependent Base fork suite was rerun because this change does not alter a
contract, route, address, manifest, or transaction builder. Existing dated fork
evidence remains recorded in `docs/VALIDATION_STATUS.md`; deployment-day exact-
fork proof is still required before any basket activation.

## Downstream handoff

After protected merge, `NARAProtocol/nara-swarm-monitor` may pin the full basket
merge commit for documentation parity. `NARAProtocol/nara_protocol` public
documentation must be updated last, after protocol, baskets, and monitor agree
on state and availability wording.
