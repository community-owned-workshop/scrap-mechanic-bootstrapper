# ---------------------------------------------------------------------------------------------------------------------
# Generates README.md and workshop/workshop.txt using the generic steam-workshop-devops metadata generator.
# ---------------------------------------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot -Parent
$DevOpsRepository = "https://github.com/community-owned-workshop/steam-workshop-devops.git"

# Use the feature branch while testing. Change this to v1 (or the released version)
# once the generic metadata generator has been released.
$DevOpsVersion = "feature/scrap-mechanic"

$TemporaryDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("cow-steam-workshop-devops-" + [guid]::NewGuid())

$PreviousRollForward = $env:DOTNET_ROLL_FORWARD
$LocationPushed = $false

try {
    $env:DOTNET_ROLL_FORWARD = "Major"

    # Download exactly the DevOps version used to generate the repository metadata.
    git -c advice.detachedHead=false clone `
        --quiet `
        --depth 1 `
        --branch $DevOpsVersion `
        $DevOpsRepository `
        $TemporaryDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "Could not download steam-workshop-devops@$DevOpsVersion."
    }

    Push-Location $Root
    $LocationPushed = $true

    # Scrap Mechanic does not need a game-specific metadata step. The generic generator creates both files
    # from metadata.json, description.md and tools/templates/README.md.
    & "$TemporaryDirectory/metadata/generate-metadata.ps1"

    if ($LASTEXITCODE -ne 0) {
        throw "Metadata generation failed."
    }
}
finally {
    if ($LocationPushed) {
        Pop-Location
    }

    if ($null -eq $PreviousRollForward) {
        Remove-Item Env:DOTNET_ROLL_FORWARD -ErrorAction SilentlyContinue
    }
    else {
        $env:DOTNET_ROLL_FORWARD = $PreviousRollForward
    }

    Remove-Item $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}