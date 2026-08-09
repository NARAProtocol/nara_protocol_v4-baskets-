# Contributing to the NARA basket project

Contributions are welcome when they improve correctness, verification,
integrator usability, accessibility, or technical clarity.

## Before starting

1. Read [`AGENTS.md`](AGENTS.md), even when you are not using an AI agent.
2. Read [`docs/VALIDATION_STATUS.md`](docs/VALIDATION_STATUS.md).
3. Follow [`docs/REPOSITORY_MAINTENANCE.md`](docs/REPOSITORY_MAINTENANCE.md).
4. Read [`app/AGENTS.md`](app/AGENTS.md) and [`app/DESIGN.md`](app/DESIGN.md)
   before changing the basket app.
5. Open an issue before implementing a material new product or contract surface.
6. Report suspected vulnerabilities privately through [`SECURITY.md`](SECURITY.md).

## Development setup

```powershell
git submodule update --init --recursive
& "$env:USERPROFILE\.foundry\bin\forge.exe" build
& "$env:USERPROFILE\.foundry\bin\forge.exe" test
npm ci --prefix app
npm run check --prefix app
```

Default contract tests require no wallet or RPC endpoint. Base fork tests require
an RPC endpoint and must never print it. The app remains in preview mode until
verified Base deployment manifests and production environment values pass its
fail-closed gates.

## Change requirements

- Keep the immutable receipt manager and its deployment configuration synchronized.
- Bind required NARA flow to the canonical immutable v4 adapter.
- Preserve typed, oracle-bounded fee conversion and separated collector roles.
- Add or update tests for every behavior change.
- Document the worst-case authority of every privileged operation.
- Keep launch payment tokens USDC-only unless a separately reviewed composite
  route is implemented.
- Keep holding and raw-withdraw fees at zero for the first launch configuration.
- Maintain neutral basket presentation and explicit review before value-bearing actions.
- Update all affected documentation, app configuration, and deployment checks in
  the same pull request.

## Pull requests

Use a focused branch and a small, reviewable pull request. Complete the pull
request template with the change class, evidence, threat-model impact,
synchronized files, exact verification, and confirmation that no credentials or
production writes are included.

Pull requests must pass required CI checks. Analyzer output and skipped
environment-dependent gates must still be reviewed and recorded.

## Commit style

Use Conventional Commits with an imperative subject:

```text
fix(adapter): bind NARA swaps to the canonical pool
test(collector): cover exact engine reward pull
docs(baskets): synchronize pre-launch status
chore(ci): pin repository verification actions
```

Do not mix unrelated formatting, generated output, deployment operations, and
contract behavior in one commit.

## Legal

By contributing, you agree that your contribution is licensed under the
repository's MIT License. Do not submit third-party code or content unless its
license is compatible and attribution requirements are satisfied.
