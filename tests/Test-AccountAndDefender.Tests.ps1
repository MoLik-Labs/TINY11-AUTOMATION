<#
.SYNOPSIS
    Unit tests for the local-account setup modes and the Defender removal switch
    added to the *-headless.ps1 builders.
    Author: kelexine (https://github.com/kelexine)
    Run: Invoke-Pester ./tests/Test-AccountAndDefender.Tests.ps1
#>

BeforeAll {
    # The builders run their whole build at load time, so their internals cannot be
    # dot-sourced for a direct unit test. Mirror the answer-file transform here the
    # same way Test-BuildNumberParsing.Tests.ps1 mirrors the build-number regex,
    # and keep the two in sync.
    function Invoke-AnswerFileTransform {
        param(
            [Parameter(Mandatory = $true)][string]$Content,
            [Parameter(Mandatory = $true)][int]$Index,
            [Parameter(Mandatory = $false)]
            [ValidateSet('auto-admin', 'classic')]
            [string]$AccountMode = 'classic',
            [Parameter(Mandatory = $false)]
            [bool]$Compact = $false
        )

        $imageIndexPattern = '(?s)<!--.*?-->|(?<imageIndex>(?<prefix><Key>/IMAGE/INDEX</Key>\s*<Value>)\d+(?<suffix>\s*</Value>))'
        $imageIndexMatches = @(
            [regex]::Matches($Content, $imageIndexPattern) |
                Where-Object { $_.Groups['imageIndex'].Success }
        )
        if ($imageIndexMatches.Count -ne 1) {
            throw 'Answer-file template must contain exactly one /IMAGE/INDEX placeholder.'
        }
        $imageIndexMatch = $imageIndexMatches[0]
        $imageIndexReplacement = $imageIndexMatch.Groups['prefix'].Value + $Index + $imageIndexMatch.Groups['suffix'].Value
        $c = $Content.Remove($imageIndexMatch.Index, $imageIndexMatch.Length).Insert($imageIndexMatch.Index, $imageIndexReplacement)

        $compactText = $Compact.ToString().ToLowerInvariant()
        $compactPattern = '(?s)<!--.*?-->|(?<compact>(?<prefix><Compact>\s*)(?:true|false)(?<suffix>\s*</Compact>))'
        $compactMatches = @(
            [regex]::Matches($c, $compactPattern) |
                Where-Object { $_.Groups['compact'].Success }
        )
        if ($compactMatches.Count -ne 1) {
            throw 'Answer-file template must contain exactly one Compact element.'
        }
        $compactMatch = $compactMatches[0]
        $compactReplacement = $compactMatch.Groups['prefix'].Value + $compactText + $compactMatch.Groups['suffix'].Value
        $c = $c.Remove($compactMatch.Index, $compactMatch.Length).Insert($compactMatch.Index, $compactReplacement)

        if ($AccountMode -eq 'classic') {
            $c = [regex]::Replace($c, '(?s)\s*<UserAccounts>.*?</UserAccounts>', '')
            $c = [regex]::Replace($c, '(?s)\s*<AutoLogon>.*?</AutoLogon>', '')
            $c = [regex]::Replace($c, '(?s)\s*<FirstLogonCommands>.*?</FirstLogonCommands>', '')
        }

        return $c
    }

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Template   = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'autounattend.xml') -Raw
    $script:CorePath   = Join-Path $script:RepoRoot 'scripts\tiny11coremaker-headless.ps1'
    $script:CoreFlow   = Join-Path $script:RepoRoot '.github\workflows\build-tiny11-core.yml'
    $script:StdFlow    = Join-Path $script:RepoRoot '.github\workflows\build-tiny11.yml'
}

Describe "Answer file: classic local-account OOBE is the safe default" {

    BeforeAll {
        $script:Classic = Invoke-AnswerFileTransform -Content $script:Template -Index 6
    }

    It "drops the pre-created account" {
        $script:Classic | Should -Not -Match '<UserAccounts>'
        $script:Classic | Should -Not -Match '<LocalAccounts>'
    }

    It "drops auto-logon" {
        $script:Classic | Should -Not -Match '<AutoLogon>'
    }

    It "drops the first-logon cleanup command" {
        $script:Classic | Should -Not -Match '<FirstLogonCommands>'
    }

    It "keeps OOBE so the user can create their own account" {
        $script:Classic | Should -Match '<OOBE>'
        $script:Classic | Should -Match 'HideOnlineAccountScreens'
    }

    It "keeps the install offline (no Microsoft account path)" {
        $script:Classic | Should -Match '<Enable>false</Enable>'
        $script:Classic | Should -Match 'BypassNRO'
        $script:Classic | Should -Match 'DisableOnline'
    }

    It "still rewrites /IMAGE/INDEX" {
        $script:Classic | Should -Match '<Key>/IMAGE/INDEX</Key>\s*<Value>6</Value>'
    }

    It "forces Compact OS deployment off for the safe Standard default" {
        $classicDoc = [xml]$script:Classic
        $classicCompact = $classicDoc.SelectSingleNode("//*[local-name()='Compact']")
        $classicCompact.InnerText | Should -Be 'false'
    }

    It "remains well-formed XML with the Shell-Setup component intact" {
        { [xml]$script:Classic } | Should -Not -Throw
        $doc = [xml]$script:Classic
        $ns = New-Object System.Xml.XmlNamespaceManager -ArgumentList $doc.NameTable
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $doc.SelectSingleNode("//u:component[@name='Microsoft-Windows-Shell-Setup']", $ns) | Should -Not -BeNullOrEmpty
        $doc.SelectSingleNode("//u:component[@name='Microsoft-Windows-Shell-Setup']/u:UserAccounts", $ns) | Should -BeNullOrEmpty
    }
}

Describe "Answer file: auto-admin is an explicit lab-only opt-in" {

    BeforeAll {
        $script:AutoAdmin = Invoke-AnswerFileTransform -Content $script:Template -Index 6 -AccountMode 'auto-admin' -Compact $true
    }

    It "keeps the pre-created local Admin and one-time auto-logon" {
        $script:AutoAdmin | Should -Match '<Name>Admin</Name>'
        $script:AutoAdmin | Should -Match '<Group>Administrators</Group>'
        $script:AutoAdmin | Should -Match '<AutoLogon>'
        $script:AutoAdmin | Should -Match '<LogonCount>1</LogonCount>'
    }

    It "uses a blank password only in the explicit auto-admin template" {
        $doc = [xml]$script:AutoAdmin
        $ns = New-Object System.Xml.XmlNamespaceManager -ArgumentList $doc.NameTable
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $account = $doc.SelectSingleNode("//u:component[@name='Microsoft-Windows-Shell-Setup']/u:UserAccounts/u:LocalAccounts/u:LocalAccount", $ns)
        $autoLogon = $doc.SelectSingleNode("//u:component[@name='Microsoft-Windows-Shell-Setup']/u:AutoLogon", $ns)
        $account | Should -Not -BeNullOrEmpty
        $autoLogon | Should -Not -BeNullOrEmpty
        $account.SelectSingleNode('u:Password/u:Value', $ns).InnerText | Should -Be ''
        $account.SelectSingleNode('u:Password/u:PlainText', $ns).InnerText | Should -Be 'true'
        $autoLogon.SelectSingleNode('u:Password/u:Value', $ns).InnerText | Should -Be ''
        $autoLogon.SelectSingleNode('u:Password/u:PlainText', $ns).InnerText | Should -Be 'true'
    }

    It "keeps the explicitly requested Compact template value" {
        $autoAdminDoc = [xml]$script:AutoAdmin
        $autoAdminDoc.SelectSingleNode("//*[local-name()='Compact']").InnerText | Should -Be 'true'
    }

    It "remains well-formed XML" {
        { [xml]$script:AutoAdmin } | Should -Not -Throw
    }
}

Describe "Builders expose the account-setup switch" {

    It "tiny11maker-headless.ps1 declares -AccountSetup and wires it into every answer-file write" {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'scripts\tiny11maker-headless.ps1') -Raw

        $content | Should -Match ([regex]::Escape('[string]$AccountSetup'))
        $content | Should -Match ([regex]::Escape("[ValidateSet('auto-admin', 'classic')]"))
        $content | Should -Match ([regex]::Escape("[string]`$AccountSetup = 'classic'"))

        $calls = ([regex]::Matches($content, 'Write-IsoAnswerFile -Destination')).Count
        $wired = ([regex]::Matches($content, '-AccountMode \$AccountSetup')).Count
        $calls | Should -BeGreaterThan 0
        $wired | Should -Be $calls
    }

    It "tiny11coremaker-headless.ps1 declares -AccountSetup and wires it into every answer-file write" {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'scripts\tiny11coremaker-headless.ps1') -Raw

        $content | Should -Match ([regex]::Escape('[string]$AccountSetup'))
        $content | Should -Match ([regex]::Escape("[ValidateSet('auto-admin', 'classic')]"))
        $content | Should -Match ([regex]::Escape("[string]`$AccountSetup = 'classic'"))

        $calls = ([regex]::Matches($content, 'Write-IsoAnswerFile -Destination')).Count
        $wired = ([regex]::Matches($content, '-AccountMode \$AccountSetup')).Count
        $calls | Should -BeGreaterThan 0
        $wired | Should -Be $calls
    }

    It "forces Compact OS off at both Standard answer-file write sites" {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'scripts\tiny11maker-headless.ps1') -Raw
        $calls = [regex]::Matches($content, '(?m)^\s*Write-IsoAnswerFile -Destination .+$')
        $calls.Count | Should -Be 2
        foreach ($call in $calls) {
            $call.Value | Should -Match ([regex]::Escape('-Compact $false'))
        }
    }

    It "fails closed if either required answer-file template value is missing or duplicated" {
        foreach ($relativePath in @('scripts\tiny11maker-headless.ps1', 'scripts\tiny11coremaker-headless.ps1')) {
            $content = Get-Content -Path (Join-Path $script:RepoRoot $relativePath) -Raw
            $content | Should -Match 'exactly one /IMAGE/INDEX placeholder'
            $content | Should -Match 'exactly one Compact element'
        }
    }

    It "pins both builders' answer files to the final single-image index" {
        foreach ($relativePath in @('scripts\tiny11maker-headless.ps1', 'scripts\tiny11coremaker-headless.ps1')) {
            $content = Get-Content -Path (Join-Path $script:RepoRoot $relativePath) -Raw
            $content | Should -Match ([regex]::Escape('[int]$ImageIndex = 1'))

            $calls = [regex]::Matches($content, '(?m)^\s*Write-IsoAnswerFile -Destination .+$')
            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $call.Value | Should -Match ([regex]::Escape('-ImageIndex 1'))
            }
        }
    }
}

Describe "Core builder exposes the Defender removal switch" {

    BeforeAll {
        $script:Core = Get-Content -Path $script:CorePath -Raw
    }

    It "declares a -RemoveDefender switch" {
        $script:Core | Should -Match ([regex]::Escape('[switch]$RemoveDefender'))
    }

    It "defines the payload and registry removal functions" {
        $script:Core | Should -Match 'function Remove-DefenderPayload'
        $script:Core | Should -Match 'function Remove-DefenderRegistry'
    }

    It "targets the Defender antimalware service and the Security app" {
        $script:Core | Should -Match ([regex]::Escape("'WinDefend'"))
        $script:Core | Should -Match 'SecHealthUI'
    }

    It "deletes the service keys instead of only setting Start=4" {
        $script:Core | Should -Match ([regex]::Escape('Remove-Item -Path $serviceKey -Recurse -Force'))
    }

    It "gates both halves behind -RemoveDefender in the main execution" {
        # The gate widened when Core-Gaming landed: a -GamingProfile build always
        # removes Defender, so the condition is now
        # 'if ($RemoveDefender -or $GamingProfile)'. Accept any condition that
        # starts with -RemoveDefender rather than pinning the old single-flag form.
        $script:Core | Should -Match '(?s)if\s*\(\s*\$RemoveDefender\b[^)]*\)\s*\{\s*Remove-DefenderPayload'
        $script:Core | Should -Match '(?s)if\s*\(\s*\$RemoveDefender\b[^)]*\)\s*\{\s*Remove-DefenderRegistry'
    }

    It "runs the payload half before the registry hives are loaded" {
        $mainStart = $script:Core.IndexOf('#---------[ Main Execution ]---------')
        $mainStart | Should -BeGreaterThan 0

        # Drop comment lines first: the explanatory comment above the call also
        # names Load-RegistryHives, and would otherwise be found before the real
        # call site.
        $main = ($script:Core.Substring($mainStart) -split "`r?`n" |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $payloadAt = $main.IndexOf('Remove-DefenderPayload')
        $loadAt = $main.IndexOf('Load-RegistryHives')
        $payloadAt | Should -BeGreaterThan 0
        $loadAt | Should -BeGreaterThan 0
        $payloadAt | Should -BeLessThan $loadAt
    }
}

Describe "Workflows expose the new toggles" {

    It "build-tiny11-core.yml declares remove_defender and account_setup" {
        $content = Get-Content -Path $script:CoreFlow -Raw
        $content | Should -Match 'remove_defender:'
        $content | Should -Match 'account_setup:'
        $content | Should -Match ([regex]::Escape('-RemoveDefender:$removeDefender'))
        $content | Should -Match ([regex]::Escape('-AccountSetup $accountSetup'))
    }

    It "build-tiny11.yml defaults to a safe classic account setup" {
        $content = Get-Content -Path $script:StdFlow -Raw
        $content | Should -Match 'account_setup:'
        $content | Should -Match ([regex]::Escape('-AccountSetup $accountSetup'))
        $content | Should -Match "default: 'classic'"
        $content | Should -Match ([regex]::Escape('ACCOUNT_SETUP: ${{ github.event_name == ''workflow_dispatch'' && github.event.inputs.account_setup || ''classic'' }}'))
    }

    It "build-tiny11-core.yml defaults to a safe classic account setup" {
        $content = Get-Content -Path $script:CoreFlow -Raw
        $content | Should -Match 'account_setup:'
        $content | Should -Match ([regex]::Escape('-AccountSetup $accountSetup'))
        $content | Should -Match "default: 'classic'"
        $content | Should -Match ([regex]::Escape('ACCOUNT_SETUP: ${{ inputs.account_setup || ''classic'' }}'))
    }
}

Describe "Builder scripts encoding (Windows PowerShell 5.1 compatibility)" {

    It "preserves UTF-8 BOM on builder scripts containing non-ASCII characters" {
        $builderFiles = @(
            'tiny11coremaker-headless.ps1',
            'nano11builder-headless.ps1',
            'tiny11maker-headless.ps1'
        )
        foreach ($file in $builderFiles) {
            $path = Join-Path $script:RepoRoot "scripts\$file"
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because "$file must have UTF-8 BOM for PowerShell 5.1 compatibility"
        }
    }
}
