# Repository maintenance protocol

This procedure is mandatory for maintainers, contributors, and AI agents. It
keeps the contracts, deployment configuration, app, manifests, and public
documentation synchronized.

## Evidence priority

When sources disagree:

1. deployed bytecode and state at a named Base block;
2. verified, sanitized basket deployment manifests;
3. active source and generated artifacts at the release commit;
4. passing tests and reproducible scripts from that commit;
5. launch configuration and app parity gates;
6. current documentation;
7. plans, issues, chat history, screenshots, and archived material.

Stop when higher-ranked sources conflict. Do not resolve a conflict by changing
documentation around an assumption.

## Required reading

Before changing code-derived, deployment-derived, or user-facing facts:

1. [`../AGENTS.md`](../AGENTS.md)
2. [`VALIDATION_STATUS.md`](VALIDATION_STATUS.md)
3. [`NARA_INTEGRATION.md`](NARA_INTEGRATION.md)
4. [`RECEIPT_BASKET_FLOW.md`](RECEIPT_BASKET_FLOW.md)
5. the affected source, test, script, configuration, and documentation
6. [`../app/AGENTS.md`](../app/AGENTS.md) and
   [`../app/DESIGN.md`](../app/DESIGN.md) for app work

Do not infer current deployment or availability from a token name, an explorer
search result, an old address, a screenshot, or an earlier conversation.

## Synchronization matrix

| Changed fact | Files to review |
|---|---|
| Receipt-manager behavior or ABI | source, tests, `RECEIPT_BASKET_FLOW.md`, `README.md`, app ABI/builders |
| Fee-collector behavior, role, oracle, or route | source, tests, deploy/verify scripts, `NARA_INTEGRATION.md`, `SECURITY.md`, app disclosures |
| Adapter behavior or route encoding | adapter source/tests, deploy/verify scripts, `NARA_INTEGRATION.md`, app builders and route checks |
| Basket composition, weight, fee, or token | `config/launch-baskets.json`, deploy scripts, `EXAMPLE_BASKETS.md`, app basket configuration, parity test |
| Deployment address or state | sanitized manifest, `DEPLOYMENT_MANIFEST.md`, `VALIDATION_STATUS.md`, `README.md`, app environment parity |
| Compiler or dependency | `foundry.toml`, submodule pins, app package files, CI, contributor setup |
| Product availability | deployment manifests, app status environment, `README.md`, `VALIDATION_STATUS.md`, app copy |
| Security or legal wording | `SECURITY.md`, `UI_UX_NEUTRAL_ACTION_HIERARCHY.md`, app design rules, affected user documentation |
| Repository process | `AGENTS.md`, `CONTRIBUTING.md`, this protocol, pull-request template, CI |

For every affected row, update the file or record `reviewed — no change needed`
in the pull request.

## Change procedure

1. Synchronize protected `main` and create a focused branch.
2. Classify the change as contract, test, deployment, integration, app,
   documentation, dependency, or operations.
3. Record exact evidence before editing prose.
4. Make the smallest complete change.
5. Add or update tests for behavior changes.
6. Search for superseded names, addresses, statuses, limits, route assumptions,
   and test counts.
7. Run the applicable gates.
8. Inspect `git status`, `git diff --check`, and the complete diff.
9. Scan tracked content and history for secrets.
10. Open a pull request using the repository template.

## Required local gates

Run from the repository root:

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
npm run build:cf --prefix app
npm audit --prefix app --audit-level=high
git diff --check
git status --short
git diff
```

Run scoped static analysis and Base fork tests when the changed risk surface
requires them. Never print an RPC endpoint or credential.

## State language

- `implemented`: source exists;
- `tested`: named tests passed at a stated commit or working-tree state;
- `deployed`: bytecode exists at a verified address;
- `configured`: required bindings, roles, and route values are set;
- `activated`: intended public behavior is enabled;
- `available`: a user can complete the documented flow;
- `preview`: the app displays information but blocks value-bearing actions;
- `deferred`: deliberately outside current scope;
- `retired`: historical and unsupported.

Never collapse these states into `live`.

## Deployment and app rules

- Never change a deployment manifest without reproducible transaction evidence.
- Keep only sanitized manifests in Git.
- Never publish private keys, seed phrases, private RPC URLs, wallet files, or
  Cloudflare/WalletConnect credentials.
- Never enable a basket in the app without a verified manager manifest and
  passing production environment parity.
- Never substitute placeholder addresses to make a gate pass.
- Never route NARA through a hookless or non-canonical pool.
- Never add ETH or WETH payment to Basket V1 without a separately implemented,
  tested, and reviewed composite route.
- Never weaken review screens or neutral basket presentation to increase
  conversion.
- Publish the basket app only through the protected GitHub workflows documented
  in [`CLOUDFLARE_PAGES_RELEASES.md`](CLOUDFLARE_PAGES_RELEASES.md). Never label
  a local or unmerged checkout as Cloudflare `main`.

## Cross-repository order

When a change affects the NARA v4 core and baskets:

1. finalize and test the active v4 engineering change;
2. merge its immutable release commit through protected CI;
3. verify deployed or observed state and create the sanitized manifest when
   deployment is part of the change;
4. update the basket integration against that exact commit and evidence;
5. update basket contracts, app, configuration, and documentation together;
6. run basket repository gates and merge through a protected pull request;
7. update `nara-swarm-monitor` from the merged basket commit and verified
   deployment evidence when basket events or addresses must be indexed;
8. update `nara_protocol` public documentation only after the engineering,
   basket, and applicable monitor states agree.

Do not copy uncommitted v4 source into this repository or publish a planned
address as deployed. In the FIELD workspace, the complete registry, state gates,
change ID, and handoff format are in
`../docs/NARA_CROSS_REPOSITORY_RELEASE_PROTOCOL.md`.

## Stop conditions

Stop and request maintainer review when:

- source, artifact, constructor arguments, route configuration, or runtime
  bytecode disagree;
- a required address cannot be independently verified;
- a diff contains a secret, personal data, signing material, or private RPC URL;
- a change bypasses the canonical NARA pool, exact balance accounting, oracle
  bounds, or role separation;
- wording claims safety, guaranteed returns, legal approval, insurance, or
  investment suitability;
- analyzer output lacks a source location or reproducible attack sequence.

## Handoff

Every pull request records scope, evidence, threat-model impact, synchronized
files, commands and results, skipped gates, unresolved assumptions, recovery
considerations, and whether any onchain or production write occurred.
