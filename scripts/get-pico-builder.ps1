<#
.SYNOPSIS
    Download NTDEV's Tiny11 Builder and its extreme CD700 recipe for an isolated Pico-style experiment.
.DESCRIPTION
    Downloads the official v0.2.0 archive for Windows x64 or ARM64, verifies its
    SHA-256 against the GitHub release digest pinned below, and extracts it to a
    new folder. It does not build an ISO, modify Windows, run a downloaded
    executable, or accept the upstream destructive-operation acknowledgements.
    Review the upstream recipe and warnings in PICO.md before proceeding.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$assets = @{
    x64 = @{ Name = 'Tiny11Builder-0.2.0-win-x64.zip'; Sha256 = '88f4b958d45b87601b3dbc97c089712a3cedc7820744f980379055de604b5766' }
    arm64 = @{ Name = 'Tiny11Builder-0.2.0-win-arm64.zip'; Sha256 = '44e7458b2227eb181af3cb6a55e0d103f836a2f0af85178065b235e9f028055f' }
}
$asset = $assets[$Architecture]
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
    throw "Destination already exists: $destinationPath. Choose a new empty path; existing files will not be overwritten."
}
$parent = Split-Path -Parent $destinationPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Destination parent does not exist: $parent"
}
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('tiny11-pico-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -ErrorAction Stop | Out-Null
try {
    $archive = Join-Path $tempDir $asset.Name
    $uri = 'https://github.com/ntdevlabs/tiny11builder/releases/download/winui-v0.2.0/' + $asset.Name
    Write-Host "Downloading official NTDEV Tiny11 Builder v0.2.0 ($Architecture)..."
    Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $asset.Sha256) {
        throw 'SHA-256 mismatch. The downloaded archive will not be extracted.'
    }
    $extract = Join-Path $tempDir 'extracted'
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -ErrorAction Stop
    # Publish by directory move only after verification/extraction; refuse races too.
    if (Test-Path -LiteralPath $destinationPath) { throw 'Destination appeared during download; refusing to overwrite.' }
    [IO.Directory]::Move($extract, $destinationPath)
    Write-Host "Verified archive extracted to $destinationPath"
    Write-Host 'Open Tiny11Builder.exe in the versioned subfolder, choose Custom, and load recipes/cd700-custom.json.'
    Write-Host 'Review every removal and use only in a disposable isolated VM. See PICO.md.'
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
