# ---------------------------------------------------------------------------------------------------------------------
# Generates README.md, workshop/workshop.txt and source/description.json from metadata.json.
# Game-specific metadata generation lives in the Scrap Mechanic profile of steam-workshop-devops.
# ---------------------------------------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot -Parent
$DevOpsRepository = "https://github.com/community-owned-workshop/steam-workshop-devops.git"

# Use the feature branch while testing. Change this to the released version once
# Scrap Mechanic support has been merged and released.
$DevOpsVersion = "v1.2"

$TemporaryDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("cow-steam-workshop-devops-" + [guid]::NewGuid())

$PreviousRollForward = $env:DOTNET_ROLL_FORWARD
$LocationPushed = $false

try {
    $env:DOTNET_ROLL_FORWARD = "Major"

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

    # The profile first invokes the generic metadata generator and then creates
    # Scrap Mechanic's source/description.json from the same metadata.json.
    & "$TemporaryDirectory/metadata/generate-metadata.ps1"
    if ($LASTEXITCODE -ne 0) {
        throw "Generic metadata generation failed."
    }

    & "$TemporaryDirectory/profiles/scrap-mechanic/metadata/generate-description.ps1" `
        -MetadataPath "metadata.json" `
        -OutputPath "source/description.json"
    if ($LASTEXITCODE -ne 0) {
        throw "Scrap Mechanic metadata generation failed."
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
