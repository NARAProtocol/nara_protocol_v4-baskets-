## Summary

Describe the smallest complete change and why it is needed.

## Change class

Choose one: contract, test, deployment, integration, app, documentation,
dependency, or operations.

## Cross-repository routing

For a repository-local change, write `not applicable` with a reason.

```text
Change-ID:
Origin remote:
Origin commit:
Evidence state:
Depends-on:
Unblocks:
Downstream repositories reviewed:
```

- [ ] Protocol inputs came from a full merged origin commit.
- [ ] Deployed inputs came from a verified sanitized manifest and named block.
- [ ] Monitor and public-documentation impact was reviewed.
- [ ] No uncommitted tree, secondary checkout, or planned address was used.

## Evidence

Link exact source, tests, sanitized deployment evidence, or a named Base block.

## Threat-model impact

Describe changed trust, custody, authorization, external calls, accounting,
rounding, liveness, routing, and app-to-contract assumptions. Write `none` only
with a short reason.

## Synchronization

List every affected file from `docs/REPOSITORY_MAINTENANCE.md` and mark it
`updated` or `reviewed — no change needed`.

## Verification

- [ ] `node scripts/check-repository.mjs`
- [ ] `forge fmt --check`
- [ ] `forge build --sizes`
- [ ] Deterministic contract tests
- [ ] CI-profile invariant tests
- [ ] `npm ci --prefix app`
- [ ] `npm run check --prefix app`
- [ ] `npm run build:cf --prefix app`
- [ ] `npm audit --prefix app --audit-level=high`
- [ ] Applicable static analysis or Base fork tests
- [ ] `git diff --check`
- [ ] Complete diff reviewed
- [ ] Deployment workflow/config impact reviewed; deployed smoke recorded when applicable

Record command results and every skipped environment-dependent gate.

## Safety

- [ ] Active v4 sources and fresh addresses only
- [ ] No private keys, seed phrases, `.env` content, credentials, or private RPC URLs
- [ ] No production transaction or production write
- [ ] Deployment, configuration, activation, and availability states are separate
- [ ] No safety, return, price, legal-approval, or investment-suitability claim
- [ ] Basket choices retain equal visual weight and neutral action copy
- [ ] Security-sensitive details are being disclosed privately when required

## Handoff

State unresolved assumptions, remaining risks, recovery considerations, and the
next authorized step.
