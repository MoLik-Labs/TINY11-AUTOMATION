BeforeAll {
    $script:Installer = Join-Path $PSScriptRoot '..\scripts\get-pico-builder.ps1'
}

Describe 'Pico upstream builder preparation' {
    BeforeEach {
        Mock Invoke-WebRequest { }
        Mock Expand-Archive {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $DestinationPath 'fixture.txt') -Value 'verified'
        }
    }

    It 'refuses to overwrite an existing directory before downloading' {
        $destination = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $destination | Out-Null
        { & $script:Installer -Architecture x64 -Destination $destination } | Should -Throw '*already exists*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects a bad digest before extraction or publication' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'bad' } }
        $destination = Join-Path $TestDrive 'bad-digest'
        { & $script:Installer -Architecture x64 -Destination $destination } | Should -Throw '*SHA-256 mismatch*'
        Test-Path -LiteralPath $destination | Should -BeFalse
        Should -Invoke Expand-Archive -Times 0 -Exactly
    }

    It 'publishes the verified x64 archive into a new directory' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = '88f4b958d45b87601b3dbc97c089712a3cedc7820744f980379055de604b5766' } }
        $destination = Join-Path $TestDrive 'valid-x64'
        & $script:Installer -Architecture x64 -Destination $destination
        Test-Path -LiteralPath (Join-Path $destination 'fixture.txt') | Should -BeTrue
        Should -Invoke Expand-Archive -Times 1 -Exactly
    }
}
