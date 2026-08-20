[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$forge = Join-Path $env:USERPROFILE ".foundry\bin\forge.exe"

if (-not (Test-Path -LiteralPath $forge)) {
    throw "Forge was not found at $forge"
}

Push-Location $repositoryRoot
try {
    node scripts/check-repository.mjs
    if ($LASTEXITCODE -ne 0) { throw "Repository integrity check failed." }

    & $forge fmt --check
    if ($LASTEXITCODE -ne 0) { throw "Forge formatting check failed." }

    & $forge build --sizes
    if ($LASTEXITCODE -ne 0) { throw "Forge build or size check failed." }

    & $forge test `
        --no-match-path "test/*Fork*.t.sol" `
        --no-match-contract NARAImmutableBasketPositionManagerV1InvariantTest
    if ($LASTEXITCODE -ne 0) { throw "Deterministic contract tests failed." }

    $previousProfile = $env:FOUNDRY_PROFILE
    try {
        $env:FOUNDRY_PROFILE = "ci"
        & $forge test --match-contract NARAImmutableBasketPositionManagerV1InvariantTest
        if ($LASTEXITCODE -ne 0) { throw "CI-profile invariant tests failed." }
    }
    finally {
        if ($null -eq $previousProfile) {
            Remove-Item Env:FOUNDRY_PROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:FOUNDRY_PROFILE = $previousProfile
        }
    }

    npm ci --prefix app
    if ($LASTEXITCODE -ne 0) { throw "Locked app dependency installation failed." }

    npm run check --prefix app
    if ($LASTEXITCODE -ne 0) { throw "App verification failed." }

    npm audit --prefix app --audit-level=high
    if ($LASTEXITCODE -ne 0) { throw "App dependency audit found a High or Critical advisory." }

    Write-Output "NARA basket repository verification passed."
}
finally {
    Pop-Location
}
