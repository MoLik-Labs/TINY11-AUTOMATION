<#
.SYNOPSIS
    Pester tests for the production image-selection and build-number helpers.
    Maintainer: NggKhaiz | automation credit: kelexine | original builder: ntdevlabs
    Run: Invoke-Pester ./tests/Test-BuildNumberParsing.Tests.ps1
#>

$modulePath = Join-Path $PSScriptRoot '..\scripts\tiny11_image_metadata.psm1'
Import-Module $modulePath -Force

Describe "Production Windows build-number parser" {
    It "extracts build and UBR from a standard four-part Windows version" {
        Get-Tiny11BuildNumber -FullVersion "10.0.26200.8655" | Should -Be "26200.8655"
    }

    It "extracts a build with a single-digit UBR" {
        Get-Tiny11BuildNumber -FullVersion "10.0.26100.1" | Should -Be "26100.1"
    }

    It "accepts a three-part Windows version without inventing a UBR" {
        Get-Tiny11BuildNumber -FullVersion "10.0.26100" | Should -Be "26100"
    }

    It "accepts a verified build label already in build-number form" {
        Get-Tiny11BuildNumber -FullVersion "26200.8655" | Should -Be "26200.8655"
    }

    It "returns an empty string for an empty version" {
        Get-Tiny11BuildNumber -FullVersion "" | Should -Be ""
    }

    It "returns an empty string for a null version" {
        Get-Tiny11BuildNumber -FullVersion $null | Should -Be ""
    }

    It "rejects malformed versions instead of mislabeling their last two components" {
        Get-Tiny11BuildNumber -FullVersion "10.0.26200.8655.1" | Should -Be ""
        Get-Tiny11BuildNumber -FullVersion "not-a-version" | Should -Be ""
        Get-Tiny11BuildNumber -FullVersion "10.0" | Should -Be ""
    }
}

Describe "Production source-image selection" {
    $images = @(
        [pscustomobject]@{ ImageIndex = 1; ImageName = "Windows 11 Home" },
        [pscustomobject]@{ ImageIndex = 4; ImageName = "Windows 11 Education" },
        [pscustomobject]@{ ImageIndex = 6; ImageName = "Windows 11 Pro" }
    )

    It "selects Pro by exact image name when the source index is automatic" {
        $selection = Select-Tiny11SourceImage -Images $images -RequestedIndex 0 -Edition Pro -ImagePath "fixture.wim"
        $selection.ImageIndex | Should -Be 6
        $selection.Image.ImageName | Should -Be "Windows 11 Pro"
    }

    It "selects Home by actual image name even when its source index is not assumed" {
        $selection = Select-Tiny11SourceImage -Images $images -RequestedIndex 0 -Edition Home -ImagePath "fixture.wim"
        $selection.ImageIndex | Should -Be 1
        $selection.Image.ImageName | Should -Be "Windows 11 Home"
    }

    It "uses an explicitly verified index and returns the actual image metadata" {
        $selection = Select-Tiny11SourceImage -Images $images -RequestedIndex 4 -Edition Pro -ImagePath "fixture.wim"
        $selection.ImageIndex | Should -Be 4
        $selection.Image.ImageName | Should -Be "Windows 11 Education"
    }

    It "fails clearly when the requested edition is absent" {
        $message = ""
        try {
            Select-Tiny11SourceImage -Images $images -RequestedIndex 0 -Edition Enterprise -ImagePath "fixture.wim"
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should -Match "Could not uniquely select 'Windows 11 Enterprise'"
        $message | Should -Match "Index 6: Windows 11 Pro"
    }

    It "fails clearly when an explicit index is absent" {
        $message = ""
        try {
            Select-Tiny11SourceImage -Images $images -RequestedIndex 99 -Edition Pro -ImagePath "fixture.wim"
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should -Match "Image index 99 did not resolve"
        $message | Should -Match "Index 4: Windows 11 Education"
    }

    It "fails rather than choosing ambiguously when the same edition name appears twice" {
        $duplicateImages = $images + [pscustomobject]@{ ImageIndex = 10; ImageName = "Windows 11 Pro" }
        $message = ""
        try {
            Select-Tiny11SourceImage -Images $duplicateImages -RequestedIndex 0 -Edition Pro -ImagePath "fixture.wim"
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should -Match "Could not uniquely select 'Windows 11 Pro'"
    }
}

Describe "All builders use the production metadata module" {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scripts = @(
        "$repoRoot\scripts\tiny11maker-headless.ps1",
        "$repoRoot\scripts\tiny11coremaker-headless.ps1",
        "$repoRoot\scripts\nano11builder-headless.ps1"
    )

    foreach ($scriptPath in $scripts) {
        $scriptName = Split-Path -Leaf $scriptPath

        It "$scriptName imports and calls the shared production helpers" {
            $content = Get-Content -Path $scriptPath -Raw
            $content | Should -Match ([regex]::Escape("Import-Module (Join-Path `$PSScriptRoot 'tiny11_image_metadata.psm1')"))
            $content | Should -Match "Select-Tiny11SourceImage"
            $content | Should -Match "Get-Tiny11BuildNumber"
            $content | Should -Match "function Write-BuildInfo"
        }

        It "$scriptName queries detailed metadata by the selected index" {
            $content = Get-Content -Path $scriptPath -Raw
            $content | Should -Match ([regex]::Escape('Get-WindowsImage -ImagePath $sourceImagePath -Index $script:INDEX'))
            $content | Should -Match ([regex]::Escape("PSObject.Properties.Match('Version')"))
        }
    }
}
