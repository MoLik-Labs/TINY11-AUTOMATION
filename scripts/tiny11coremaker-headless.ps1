<#
.SYNOPSIS
    Headless script to build a minimized Windows 11 Core image for CI/CD automation.

.DESCRIPTION
    Automated build of an extremely streamlined Windows 11 Core image without user interaction.
    This script generates a significantly reduced Windows 11 image by removing WinSxS components,
    Windows Recovery Environment, and additional system packages.

    WARNING: tiny11 Core is not suitable for regular use due to its lack of serviceability -
    you cannot add languages, updates, or features post-creation. It's designed for rapid
    testing or development in VM environments.

    Designed for GitHub Actions workflows and other CI/CD pipelines.
    Uses only Microsoft utilities like DISM, with oscdimg.exe from Windows ADK.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 ISO (required, e.g., E)

.PARAMETER INDEX
    Windows image index to process; 0 selects the requested edition by exact image name (default Pro). Pass an explicit index only after reviewing Get-WindowsImage output.

.PARAMETER Edition
    Edition to select by actual image name when INDEX is 0 (default Pro).

.PARAMETER BypassHardwareRequirements
    Add Windows Setup hardware-check bypasses and hide unsupported-hardware notifications. Disabled unless explicitly requested; testing only.

.PARAMETER SCRATCH
    Drive letter for scratch disk operations (optional, defaults to script root)

.PARAMETER SkipCleanup
    Skip cleanup of temporary files after ISO creation (optional, for debugging)

.PARAMETER RemoveDefender
    Completely remove Windows Defender / Security so that no antimalware service
    is present in the finished image (optional). Off by default - the standard
    Core build only disables the Defender services.

    A Core-Gaming build (-GamingProfile) always removes Defender / Security, so
    this switch is redundant there; it stays meaningful for a plain Core build.

.PARAMETER AccountSetup
    How the local account is set up on first boot (optional, default 'classic'):
      classic    - default; run offline local-account OOBE so you create your own
                   account with your chosen name. No pre-created blank-password admin.
      auto-admin - explicitly opt in to a local 'Admin' with a blank password and
                   one auto-logon. Use only in disposable, isolated lab VMs.

.PARAMETER GamingProfile
    Apply the experimental Tiny11 Core-Gaming VM/Lab profile (optional). It changes
    power, device, security, service, feature and application settings. The results
    are hardware/workload-dependent and are not benchmark-validated; do not use this
    profile for a daily-use machine. See GAMING.md for scope and irreversible risks.

    Gaming groups are defined in config/gaming_profile.json and can be toggled with
    -GamingGroups. The separate essentials layer is always applied to a Core-Gaming
    build.

    A Core-Gaming build also removes Windows Defender / Security and Windows Update
    components. These changes are not group-controlled and can break security and
    servicing; build plain Core if those components must be retained. This is a
    destructive VM/Lab configuration, not a supported way to manage a daily-use PC.

    A Core-Gaming build also ALWAYS applies the essentials pass defined in
    config/essentials_profile.json - the post-install debloat list (activity
    history, BitLocker auto-encryption, delivery optimization, location, telemetry,
    WPBT, OneDrive, Windows AI, the right-click/Start menu layouts, and a long list
    of services moved to manual or disabled). Like the Defender and Windows Update
    removals it has no group flag and no workflow input: it is part of what
    Core-Gaming means. See the Essentials section of GAMING.md.

.PARAMETER GamingProfileFile
    Path to the gaming profile JSON (optional). Defaults to
    config/gaming_profile.json in the repository root.

.PARAMETER GamingGroups
    Hashtable of per-group on/off overrides (optional), e.g.
    @{ disable_mpo = $false; disable_fso = $false }.
    Groups not listed keep the defaults from the profile JSON.

.PARAMETER HagsMode
    Hardware Accelerated GPU Scheduling: 'on' (default) forces it on, 'off' forces
    it off, 'leave' keeps the Core default untouched. AtlasOS treats HAGS as
    system-dependent, so it is a toggle here rather than a fixed choice.

.EXAMPLE
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Home -SCRATCH D -SkipCleanup
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -RemoveDefender
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -AccountSetup classic

.EXAMPLE
    # Experimental Core-Gaming build (VM/Lab only; see GAMING.md for risks)
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -GamingProfile -PreserveWinRE

.EXAMPLE
    # Core-Gaming with selected groups disabled
    .\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -GamingProfile -HagsMode off `
        -GamingGroups @{ disable_security_mitigations = $false; disable_mpo = $false }

.NOTES
    Original builder: ntdevlabs (https://github.com/ntdevlabs/tiny11builder)
    Headless automation credit: kelexine (https://github.com/kelexine)
    Current fork maintainer: NggKhaiz (https://github.com/NggKhaiz/TINY11-AUTOMATION)
    This is a headless automation-ready version designed for CI/CD pipelines.
#>

#---------[ Parameters ]---------#
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="Drive letter of mounted Windows 11 ISO (e.g., E)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$ISO,

    [Parameter(Mandatory=$false, HelpMessage="Windows image index; use 0 to select the requested edition by its actual image name")]
    [ValidateRange(0, 2147483647)]
    [int]$INDEX = 0,

    [Parameter(Mandatory=$false, HelpMessage="Edition to select when INDEX is 0")]
    [ValidateSet('Home', 'Pro', 'Education', 'Enterprise')]
    [string]$Edition = 'Pro',

    [Parameter(Mandatory=$false, HelpMessage="Add Windows Setup hardware-check bypasses for testing only; disabled by default")]
    [switch]$BypassHardwareRequirements,

    [Parameter(Mandatory=$false, HelpMessage="Scratch disk drive letter (defaults to script directory)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$SCRATCH,

    [Parameter(Mandatory=$false, HelpMessage="Skip cleanup of temporary files")]
    [switch]$SkipCleanup,

    [Parameter(Mandatory=$false, HelpMessage="Enable .NET Framework 3.5")]
    [switch]$ENABLE_DOTNET35,

    [Parameter(Mandatory=$false, HelpMessage="Preserve the source WinRE image for physical hardware and EFI/UEFI installs; disabled by default for VM/Lab builds.")]
    [switch]$PreserveWinRE,

    [Parameter(Mandatory=$false, HelpMessage="Completely remove Windows Defender / Security so no antimalware service is present in the finished image. Off by default - the standard Core build only disables the Defender services. A Core-Gaming build always does this, so the switch is redundant there.")]
    [switch]$RemoveDefender,

    [Parameter(Mandatory=$false, HelpMessage="Local account setup. 'classic' (default) runs offline OOBE so you create your own local account. 'auto-admin' explicitly creates a blank-password Admin account with one auto-logon; use only in a disposable isolated VM.")]
    [ValidateSet('auto-admin', 'classic')]
    [string]$AccountSetup = 'classic',

    [Parameter(Mandatory=$false, HelpMessage="Apply the experimental Tiny11 Core-Gaming VM/Lab profile. Removes security and servicing components and changes hardware-dependent settings; no performance gain is claimed. See GAMING.md.")]
    [switch]$GamingProfile,

    [Parameter(Mandatory=$false, HelpMessage="Path to the gaming profile JSON. Defaults to config/gaming_profile.json in the repository root.")]
    [string]$GamingProfileFile,

    [Parameter(Mandatory=$false, HelpMessage="Hashtable of per-group on/off overrides, e.g. @{ disable_mpo = `$false }. Groups not listed use the profile defaults.")]
    [hashtable]$GamingGroups,

    [Parameter(Mandatory=$false, HelpMessage="Hardware Accelerated GPU Scheduling: 'on' forces it on, 'off' forces it off, 'leave' keeps the Core default.")]
    [ValidateSet('on', 'off', 'leave')]
    [string]$HagsMode = 'on'
)

#---------[ Error Handling ]---------
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'tiny11_image_metadata.psm1') -Force -ErrorAction Stop

#---------[ Configuration ]---------
if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

$DriveLetter = $ISO + ":"
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
$scratchDir = "$ScratchDisk\scratchdir"
$tiny11Dir = "$ScratchDisk\tiny11"
$outputISO = "$PSScriptRoot\tiny11-core.iso"
$logFile = "$PSScriptRoot\tiny11-core_$(Get-Date -Format yyyyMMdd_HHmmss).log"
$script:DownloadedOscdimg = $false
$script:LoadedRegistryHives = @()

#---------[ Gaming profile (optional) ]---------
# The profile engine is data-driven from config/gaming_profile.json and is dot-sourced
# only when -GamingProfile is set, so a plain Core build is completely unaffected.
$gamingProfileData = $null
$gamingGroupFlags = $null
$essentialsProfileData = $null
$gamingConfigDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'config'

if ($GamingProfile) {
    $gamingModule = Join-Path $PSScriptRoot 'gaming-profile.ps1'
    if (-not (Test-Path -LiteralPath $gamingModule)) {
        throw "Gaming profile requested but the engine was not found at $gamingModule"
    }
    . $gamingModule

    # The essentials layer is Core-Gaming only and is not toggleable: no group flag, no
    # workflow input. It reproduces the post-install debloat pass that would otherwise be
    # run by hand on every fresh install.
    $essentialsModule = Join-Path $PSScriptRoot 'essentials-profile.ps1'
    if (-not (Test-Path -LiteralPath $essentialsModule)) {
        throw "Gaming profile requested but the essentials engine was not found at $essentialsModule"
    }
    . $essentialsModule
}

# Initialize admin identifiers for permission operations
try {
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
} catch {
    Write-Warning "Failed to resolve Administrator group SID. Defaulting to 'Administrators'."
    $adminGroup = [PSCustomObject]@{ Value = "Administrators" }
}

#---------[ Functions ]---------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Invoke-NativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Quiet
    )

    # Windows PowerShell 5.1 may promote redirected native stderr to a terminating
    # error under $ErrorActionPreference = Stop. Scope it to Continue and make the
    # native exit code authoritative, preserving captured output for diagnostics.
    $previousEap = $ErrorActionPreference
    $output = @()
    $exitCode = $null
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }

    if ($null -eq $exitCode -or $exitCode -notin $SuccessExitCodes) {
        $details = (@($output) | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Native command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')`n$details"
    }

    if (-not $Quiet -and $null -ne $output) {
        return $output
    }
}

function Load-RegistryHive {
    param(
        [Parameter(Mandatory=$true)][string]$HiveName,
        [Parameter(Mandatory=$true)][string]$HivePath
    )

    Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('load', $HiveName, $HivePath) -Quiet
    if ($HiveName -notin $script:LoadedRegistryHives) {
        $script:LoadedRegistryHives += $HiveName
    }
}

function Get-TakeownYesAnswer {
    # takeown /R needs /D, otherwise it asks "Do you want to replace the directory permissions...? [Y/N]"
    # on the console for every folder the administrator cannot list (e.g. ProgramData\Microsoft\Windows
    # Defender Advanced Threat Protection, present only in Pro/Enterprise) and the build waits forever.
    # /D accepts only the "yes" letter of the system language: Y in English, T in Polish, J in German,
    # O in French... - "/D Y" is rejected on those systems. Probe once on an empty folder and cache it.
    $cached = Get-Variable -Name takeownYesAnswer -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($cached) { return $cached }

    $answer = 'Y'
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('takeown-probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probe -Force | Out-Null
    try {
        foreach ($candidate in @('Y', 'T', 'J', 'O', 'S', 'A', 'I', 'E', [string][char]0x414)) {
            & { $ErrorActionPreference = 'Continue'; & takeown.exe /F $probe /R /D $candidate 2>&1 | Out-Null }
            if ($LASTEXITCODE -eq 0) { $answer = $candidate; break }
        }
    } finally {
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
    Set-Variable -Name takeownYesAnswer -Scope Script -Value $answer
    return $answer
}

function Write-IsoAnswerFile {
    # Copies the unattend template to $Destination, pinning /IMAGE/INDEX to the
    # target media's final image index. The builder exports one selected image, so
    # the generated ISO uses index 1 even when the source image had another index.
    #
    # The content is parsed as XML before it is written: Windows Setup hard-fails on
    # a malformed answer file, and a rejected answer file is exactly how the OOBE /
    # local-account automation silently stops working.
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$false)][string]$Template,
        [Parameter(Mandatory=$false)]
        [ValidateSet('auto-admin', 'classic')]
        [string]$AccountMode = 'classic',
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 2147483647)]
        [int]$ImageIndex = 1,
        [Parameter(Mandatory=$false)]
        [bool]$Compact = $true
    )

    if (-not $Template) {
        $Template = @(
            (Join-Path $PSScriptRoot "autounattend.xml"),
            (Join-Path (Split-Path $PSScriptRoot -Parent) "autounattend.xml")
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $Template -or -not (Test-Path $Template)) {
        Write-Log "No unattend template found - OOBE will not be automated" "WARN"
        return
    }

    try {
        $content = Get-Content -LiteralPath $Template -Raw
        $imageIndexPattern = '(<Key>/IMAGE/INDEX</Key>\s*<Value>)\d+(</Value>)'
        if ([regex]::Matches($content, $imageIndexPattern).Count -ne 1) {
            throw "Answer-file template must contain exactly one /IMAGE/INDEX placeholder."
        }
        $content = [regex]::Replace(
            $content,
            $imageIndexPattern,
            ('${1}' + $ImageIndex + '${2}')
        )

        $compactText = $Compact.ToString().ToLowerInvariant()
        $compactPattern = '(<Compact>\s*)(?:true|false)(\s*</Compact>)'
        if ([regex]::Matches($content, $compactPattern).Count -ne 1) {
            throw "Answer-file template must contain exactly one Compact element."
        }
        $content = [regex]::Replace(
            $content,
            $compactPattern,
            ('${1}' + $compactText + '${2}')
        )

        # Account mode 'classic': drop the pre-created account, the auto-logon and
        # the first-logon cleanup so Windows Setup runs OOBE and the person
        # installing creates their own local account with their own name.
        #
        # Everything else in the template is kept, so the install stays fully
        # offline: DynamicUpdate stays off, the online-account screens stay hidden
        # and BypassNRO / DisableOnline stay set. The result is the classic
        # "create a local account" OOBE with no Microsoft account and no network.
        #
        # These three elements never nest inside an element of the same name in
        # the template, so a non-greedy block match is unambiguous. The result is
        # re-parsed as XML below, so a bad edit here fails the build loudly.
        if ($AccountMode -eq 'classic') {
            $content = [regex]::Replace($content, '(?s)\s*<UserAccounts>.*?</UserAccounts>', '')
            $content = [regex]::Replace($content, '(?s)\s*<AutoLogon>.*?</AutoLogon>', '')
            $content = [regex]::Replace($content, '(?s)\s*<FirstLogonCommands>.*?</FirstLogonCommands>', '')
        }

        # Throws if the template is not well-formed XML - we want that to be loud.
        $null = [xml]$content

        $destDir = Split-Path -Parent $Destination
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }

        # UTF-8 without BOM - Setup is happier without a BOM on the answer file.
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Destination, $content, $utf8NoBom)

        Write-Log "Wrote unattended answer file to $Destination (IMAGE/INDEX = $ImageIndex, account mode = $AccountMode, Compact = $compactText)"
    } catch {
        Write-Log "Failed to write answer file to ${Destination}: $_" "ERROR"
        throw
    }
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."

    # Check admin rights
    $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
        Write-Log "Script must run as Administrator!" "ERROR"
        throw "Administrative privileges required"
    }

    # Check ISO mount
    if (-not (Test-Path "$DriveLetter\sources\boot.wim")) {
        Write-Log "boot.wim not found at $DriveLetter\sources\" "ERROR"
        throw "Invalid Windows 11 ISO mount point"
    }

    # Check for install.wim or install.esd
    if (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd")) {
        Write-Log "No install.wim or install.esd found" "ERROR"
        throw "Windows installation files not found"
    }

    # Check disk space (minimum 20GB recommended for Core build)
    $disk = Get-PSDrive -Name $ScratchDisk[0] -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [math]::Round($disk.Free / 1GB, 2)
        Write-Log "Available space on ${ScratchDisk}: ${freeGB}GB"
        if ($freeGB -lt 20) {
            Write-Log "Low disk space warning: ${freeGB}GB (20GB+ recommended for Core build)" "WARN"
        }
    }

    Write-Log "Prerequisites check passed"
}

function Initialize-Directories {
    Write-Log "Initializing directories..."
    New-Item -ItemType Directory -Force -Path "$tiny11Dir\sources" | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    Write-Log "Directories created"
}

function Convert-ESDToWIM {
    Write-Log "Converting install.esd to install.wim..."

    $esdPath = "$DriveLetter\sources\install.esd"
    $tempWimPath = "$tiny11Dir\sources\install.wim"

    # Validate index exists in ESD
    $images = Get-WindowsImage -ImagePath $esdPath
    $validIndices = $images.ImageIndex

    if ($INDEX -notin $validIndices) {
        Write-Log "Invalid index $INDEX. Available: $($validIndices -join ', ')" "ERROR"
        throw "Image index $INDEX not found in install.esd"
    }

    Write-Log "Exporting image index $INDEX from ESD (this may take 10-20 minutes)..."
    Export-WindowsImage -SourceImagePath $esdPath -SourceIndex $INDEX `
        -DestinationImagePath $tempWimPath -CompressionType Maximum -CheckIntegrity

    Write-Log "ESD conversion complete"
}

function Copy-WindowsFiles {
    Write-Log "Copying Windows installation files from $DriveLetter..."
    Copy-Item -Path "$DriveLetter\*" -Destination $tiny11Dir -Recurse -Force -ErrorAction Stop

    # Remove read-only attribute and delete install.esd if present
    if (Test-Path "$tiny11Dir\sources\install.esd") {
        Set-ItemProperty -Path "$tiny11Dir\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Remove-Item "$tiny11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
    }

    Write-Log "File copy complete"
}

function Resolve-ImageIndex {
    $sourceImagePath = if (Test-Path "$DriveLetter\sources\install.wim") {
        "$DriveLetter\sources\install.wim"
    } elseif (Test-Path "$DriveLetter\sources\install.esd") {
        "$DriveLetter\sources\install.esd"
    } else {
        throw "Windows installation files not found on ISO"
    }

    $images = @(Get-WindowsImage -ImagePath $sourceImagePath)
    if ($images.Count -eq 0) {
        throw "No Windows images were found in $sourceImagePath"
    }

    $requestedIndex = [int]$INDEX
    $selection = Select-Tiny11SourceImage -Images $images -RequestedIndex $requestedIndex -Edition $Edition -ImagePath $sourceImagePath
    $script:INDEX = [int]$selection.ImageIndex
    $selectedImage = $selection.Image
    $script:SourceImageIndex = $script:INDEX
    $script:DetectedImageName = $selectedImage.ImageName
    $script:DetectedEdition = $selectedImage.ImageName -replace '^Windows 11\s+', ''

    if ($requestedIndex -eq 0) {
        Write-Log "Auto-selected Windows 11 $Edition at actual image index $script:INDEX"
    }
    Write-Log "Selected: Index $script:INDEX - $($selectedImage.ImageName)"

    # DISM's image-list result does not expose Version. Query the selected index directly.
    $script:DetectedFullVersion = ""
    try {
        $detailedImage = Get-WindowsImage -ImagePath $sourceImagePath -Index $script:INDEX
        if ($detailedImage -and ($detailedImage.PSObject.Properties.Match('Version').Count -gt 0)) {
            $script:DetectedFullVersion = $detailedImage.Version
        } else {
            Write-Log "Detailed image query for index $script:INDEX returned no 'Version' property." "WARN"
        }
    } catch {
        Write-Log "Failed to query detailed image info for build number detection: $_" "WARN"
    }

    $script:DetectedBuildNumber = Get-Tiny11BuildNumber -FullVersion $script:DetectedFullVersion
    if (-not [string]::IsNullOrWhiteSpace($script:DetectedBuildNumber)) {
        Write-Log "Detected Windows build number: $script:DetectedBuildNumber (full version: $script:DetectedFullVersion)"
    } else {
        Write-Log "Could not parse a build number from image version '$script:DetectedFullVersion'" "WARN"
    }
}

function Mount-WindowsImageFile {
    Write-Log "Mounting Windows image (Index: $INDEX)..."

    # Take ownership and set permissions; do not continue if native calls fail.
    Invoke-NativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $wimFilePath, '/A') -Quiet
    Invoke-NativeCommand -FilePath 'icacls.exe' -Arguments @($wimFilePath, '/grant', "$($adminGroup.Value):(F)") -Quiet

    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    Mount-WindowsImage -ImagePath $wimFilePath -Index $INDEX -Path $scratchDir
    Write-Log "Image mounted at $scratchDir"
}

function Get-ImageMetadata {
    Write-Log "Extracting image metadata..."

    # Get language
    $imageIntl = & dism /English /Get-Intl "/Image:$scratchDir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $script:languageCode = $Matches[1]
        Write-Log "Language: $script:languageCode"
    } else {
        Write-Log "Language code not found, using default patterns" "WARN"
        $script:languageCode = "en-US"
    }

    # Get architecture
    $imageInfo = & dism /English /Get-WimInfo "/wimFile:$wimFilePath" "/index:$INDEX"
    $lines = $imageInfo -split '\r?\n'

    foreach ($line in $lines) {
        if ($line -like '*Architecture : *') {
            $script:architecture = $line -replace 'Architecture : ', ''
            if ($script:architecture -eq 'x64') {
                $script:architecture = 'amd64'
            }
            Write-Log "Architecture: $script:architecture"
            break
        }
    }

    if (-not $script:architecture) {
        Write-Log "Architecture not found, defaulting to amd64" "WARN"
        $script:architecture = 'amd64'
    }
}

function Remove-BloatwareApps {
    Write-Log "Removing provisioned appx packages..."

    $packages = & dism /English "/image:$scratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') {
                $matches[1]
            }
        }

    $packagePrefixes = @(
        'Clipchamp.Clipchamp_',
        'Microsoft.BingNews_',
        'Microsoft.BingWeather_',
        'Microsoft.GamingApp_',
        'Microsoft.GetHelp_',
        'Microsoft.Getstarted_',
        'Microsoft.MicrosoftOfficeHub_',
        'Microsoft.MicrosoftSolitaireCollection_',
        'Microsoft.People_',
        'Microsoft.PowerAutomateDesktop_',
        'Microsoft.Todos_',
        'Microsoft.WindowsAlarms_',
        'microsoft.windowscommunicationsapps_',
        'Microsoft.WindowsFeedbackHub_',
        'Microsoft.WindowsMaps_',
        'Microsoft.WindowsSoundRecorder_',
        'Microsoft.Xbox.TCUI_',
        'Microsoft.XboxGamingOverlay_',
        'Microsoft.XboxGameOverlay_',
        'Microsoft.XboxSpeechToTextOverlay_',
        'Microsoft.YourPhone_',
        'Microsoft.ZuneMusic_',
        'Microsoft.ZuneVideo_',
        'MicrosoftCorporationII.MicrosoftFamily_',
        'MicrosoftCorporationII.QuickAssist_',
        'MicrosoftTeams_',
        'Microsoft.549981C3F5F10_',
        'Microsoft.Windows.Copilot',
        'MSTeams_',
        'Microsoft.OutlookForWindows_',
        'Microsoft.Windows.Teams_',
        'Microsoft.Windows.Photos_',
        'Microsoft.ScreenSketch_',
        'Microsoft.StorePurchaseApp_',
        'Microsoft.MPEG2VideoExtension_',
        'Microsoft.WebMediaExtensions_',
        'MicrosoftWindows.Client.WebExperience_',
        'Microsoft.Copilot_',
        'Microsoft.Windows.AI',
        'Microsoft.Windows.AIFabric',
        'Microsoft.Windows.Recall',
        'Microsoft.Windows.CoreAI',
        'Microsoft.Recall'
    )

    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes | Where-Object { $packageName -like "$_*" }
    }

    $removeCount = 0
    foreach ($package in $packagesToRemove) {
        Write-Log "Removing: $package"
        & dism /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$package" | Out-Null
        $removeCount++
    }

    Write-Log "Removed $removeCount appx packages"
}

function Remove-SystemPackages {
    Write-Log "Removing system packages..."

    $packagePatterns = @(
        "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35",
        "Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64",
        "Microsoft-Windows-LanguageFeatures-Handwriting-$($script:languageCode)-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-OCR-$($script:languageCode)-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-Speech-$($script:languageCode)-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$($script:languageCode)-Package~31bf3856ad364e35",
        "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35",
        "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35",
        "Windows-Defender-Client-Package~31bf3856ad364e35~",
        "Microsoft-Windows-WordPad-FoD-Package~",
        "Microsoft-Windows-TabletPCMath-Package~",
        "Microsoft-Windows-StepsRecorder-Package~",
        "UserExperience-Recall-Package~",
        "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
        "Microsoft-Windows-AppManagement-AppV-Package~",
        "Microsoft-Edge-WebView-FOD-Package~"
    )

    # Get all packages
    $allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
    $allPackages = $allPackages -split "`n" | Select-Object -Skip 1

    $removeCount = 0
    foreach ($packagePattern in $packagePatterns) {
        # Filter the packages to remove
        $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }

        foreach ($package in $packagesToRemove) {
            # Extract the package identity
            $packageIdentity = ($package -split "\s+")[0]

            Write-Log "Removing $packageIdentity..."
            try {
                & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity /Quiet /NoRestart | Out-Null
                $removeCount++
            } catch {
                Write-Log "Failed to remove $packageIdentity : $_" "WARN"
            }
        }
    }

    Write-Log "Removed $removeCount system packages"
}

function Remove-DefenderPayload {
    # -RemoveDefender only. Strips the Defender / Security payload out of the
    # mounted image: the Defender feature package, the Windows Security app, the
    # on-disk Defender program + definition store and the Security Health
    # binaries.
    #
    # This runs while the image is mounted but BEFORE its registry hives are
    # loaded: DISM /Remove-Package needs exclusive access to the component store,
    # which 'reg load' would otherwise lock.
    #
    # Every step is best-effort and logged. A partial removal still yields a
    # working image - it just leaves a Defender component behind - so a failure
    # here must not abort the whole build.
    Write-Log "Removing Windows Defender / Security payload (RemoveDefender)..." "INFO"

    # 1) Defender feature package(s).
    $allPackages = & dism /English /image:$scratchDir /Get-Packages
    $defenderPackages = $allPackages |
        ForEach-Object { if ($_ -match 'Package Identity\s*:\s*(.+?)\s*$') { $Matches[1] } } |
        Where-Object { $_ -match 'Windows-Defender-Client-Package|Windows-Defender-Client-WOW64-Package|Windows-Defender-Client-En-US-Package|Microsoft-Windows-SenseClient' } |
        Select-Object -Unique

    if ($defenderPackages) {
        foreach ($identity in $defenderPackages) {
            Write-Log "Removing Defender package: $identity"
            & dism /English /image:$scratchDir /Remove-Package /PackageName:$identity /Quiet /NoRestart | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "DISM could not remove $identity (exit $LASTEXITCODE) - continuing" "WARN"
            }
        }
    } else {
        Write-Log "No Defender feature package found in the image" "WARN"
    }

    # 2) The Windows Security app (SecHealthUI).
    $securityApps = & dism /English /image:$scratchDir /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $Matches[1] } } |
        Where-Object { $_ -like '*SecHealthUI*' }
    foreach ($app in $securityApps) {
        Write-Log "Removing Windows Security app: $app"
        & dism /English /image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$app" | Out-Null
    }

    # 3) On-disk Defender program + definition store.
    $defenderPaths = @(
        "$scratchDir\Program Files\Windows Defender",
        "$scratchDir\Program Files (x86)\Windows Defender",
        "$scratchDir\ProgramData\Microsoft\Windows Defender",
        "$scratchDir\ProgramData\Microsoft\Windows Defender Advanced Threat Protection"
    )
    foreach ($path in $defenderPaths) {
        if (Test-Path $path) {
            Write-Log "Deleting Defender data: $path"
            & takeown /f $path /r /d $(Get-TakeownYesAnswer) /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 4) Security Health binaries (the tray agent behind the "Windows Security"
    #    shield in the notification area).
    $securityHealthBinaries = Get-ChildItem -Path "$scratchDir\Windows\System32" -Filter "SecurityHealth*" -File -ErrorAction SilentlyContinue
    foreach ($binary in $securityHealthBinaries) {
        Write-Log "Deleting Security Health binary: $($binary.Name)"
        & takeown /f $binary.FullName /a | Out-Null
        & icacls $binary.FullName /grant "$($adminGroup.Value):(F)" /C | Out-Null
        Remove-Item -Path $binary.FullName -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Defender / Security payload removal finished"
}

function Remove-WindowsUpdatePayload {
    # -GamingProfile only. Payload half of the complete Windows Update removal, so
    # it runs while the image is mounted but BEFORE its registry hives are loaded.
    #
    # The always-on Core pass removes selected update-related files. This Gaming-only
    # step also removes selected orchestrator task folders; update/servicing behavior
    # after these changes is Windows-build-dependent and not validated here.
    Write-Log "Removing the Windows Update payload (GamingProfile)..." "INFO"

    # Remove selected Update Orchestrator task folders as part of this experimental
    # image profile. This can break servicing and does not guarantee that later Windows
    # servicing cannot restore or recreate components.
    foreach ($taskFolder in @(
        'Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
        'Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate'
    )) {
        $taskPath = Join-Path $scratchDir $taskFolder
        if (Test-Path $taskPath) {
            Remove-Item -Path $taskPath -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $taskPath) {
                Write-Log "Could not delete scheduled task folder: $taskFolder" "WARN"
            } else {
                Write-Log "Deleted scheduled task folder: $taskFolder"
            }
        }
    }

    # Remove selected Windows Update client executables. Keep wuaueng.dll and
    # wuapi.dll because other inbox components may reference them. The effect of
    # deleting selected clients/services/tasks on future servicing is not guaranteed.
    foreach ($relative in @(
        'Windows\System32\wuauclt.exe',
        'Windows\System32\wuapihost.exe'
    )) {
        $binary = Join-Path $scratchDir $relative
        if (Test-Path $binary) {
            Remove-Item -Path $binary -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted Windows Update executable: $relative"
        }
    }

    Write-Log "Windows Update payload removal finished"
}

function Remove-DefenderRegistry {
    # -RemoveDefender only. Registry half of the removal, so it must run AFTER
    # Load-RegistryHives.
    #
    # The Defender service keys are deleted outright rather than set to Start=4.
    # Merely disabling WinDefend leaves the service defined, so the "Antimalware
    # Service Executable" (MsMpEng.exe) can still be re-armed; deleting the key is
    # what makes the antimalware service genuinely absent from the finished image.
    Write-Log "Removing Defender / Security registry keys (RemoveDefender)..." "INFO"

    # Services that make up Defender and the Windows Security platform.
    $defenderServices = @(
        'WinDefend',             # Microsoft Defender Antivirus Service (MsMpEng.exe)
        'WdNisSvc',              # Network Inspection Service
        'WdNisDrv',              # Network Inspection driver
        'WdFilter',              # Defender file-system mini-filter
        'WdDevFlt',              # Defender device filter
        'WdBoot',                # Defender boot driver
        'Sense',                 # Defender for Endpoint / EDR
        'SecurityHealthService'  # Windows Security Center host
    )
    foreach ($service in $defenderServices) {
        $serviceKey = "HKLM:\zSYSTEM\ControlSet001\Services\$service"
        if (Test-Path $serviceKey) {
            Remove-Item -Path $serviceKey -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $serviceKey) {
                Write-Log "Could not delete Defender service key (locked or access denied): $service" "WARN"
            } else {
                Write-Log "Deleted Defender service key: $service"
            }
        } else {
            Write-Log "Defender service key not present: $service"
        }
    }

    # Security Center and System Guard Runtime Monitor are shared Windows
    # components rather than Defender itself, so they are disabled rather than
    # deleted - removing their keys outright risks breaking unrelated plumbing.
    foreach ($service in @('wscsvc', 'SgrmAgent', 'SgrmBroker', 'MsSecFlt')) {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$service" 'Start' 'REG_DWORD' '4'
    }

    # Defender configuration + policy hives.
    foreach ($key in @('HKLM:\zSOFTWARE\Microsoft\Windows Defender', 'HKLM:\zSOFTWARE\Policies\Microsoft\Windows Defender')) {
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $key) {
                Write-Log "Could not delete Defender registry key (locked or access denied): $key" "WARN"
            } else {
                Write-Log "Deleted Defender registry key: $key"
            }
        }
    }

    Write-Log "Defender / Security registry removal finished"
}

function Remove-WindowsUpdateStack {
    # -GamingProfile only. Registry half of the complete Windows Update removal, so
    # it must run AFTER Load-RegistryHives.
    #
    # The always-on Core tweak sets wuauserv to Start=4 and redirects Windows Update
    # to localhost. That is NOT sufficient on modern Windows, and it is why a Core
    # image can still show "Updates are underway, do not turn off your PC":
    #
    #   * WaaSMedicSvc (Windows Update Medic) exists specifically to detect a
    #     disabled or broken Windows Update and put it back.
    #   * UsoSvc (Update Orchestrator) runs the servicing pass at boot.
    #
    # Leave either in place and Windows Update re-arms itself a restart or two
    # later. The keys are deleted outright rather than set to Start=4, matching how
    # Remove-DefenderRegistry treats the Defender services.
    #
    # DoSvc (Delivery Optimization) is deliberately NOT touched here - it is owned
    # by the profile's strip_background_noise group, so deleting it unconditionally
    # would ignore that group's toggle.
    Write-Log "Removing the Windows Update stack (GamingProfile)..." "INFO"

    foreach ($service in @(
        'WaaSMedicSvc',   # Windows Update Medic - repairs and re-enables Windows Update
        'UsoSvc',         # Update Orchestrator - the servicing pass at boot
        'wuauserv'        # Windows Update
    )) {
        $serviceKey = "HKLM:\zSYSTEM\ControlSet001\Services\$service"
        if (Test-Path $serviceKey) {
            Remove-Item -Path $serviceKey -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $serviceKey) {
                Write-Log "Could not delete Windows Update service key (locked or access denied): $service" "WARN"
            } else {
                Write-Log "Deleted Windows Update service key: $service"
            }
        } else {
            Write-Log "Windows Update service key not present: $service"
        }
    }

    # Policy side, belt and braces alongside the always-on localhost redirect.
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'

    # The Settings page visibility value is deliberately NOT written here.
    # Apply-RegistryTweaks owns it and already hides both pages with valid page
    # ids, so a second write site would only reintroduce a call-order dependency
    # between the two paths.

    Write-Log "Windows Update stack removal finished"
}

function Remove-EdgeAndOneDrive {
    Write-Log "Removing Microsoft Edge and Edge WebView..."

    $edgePaths = @(
        "$scratchDir\Program Files (x86)\Microsoft\Edge",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeCore",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeWebView",
        "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
    )

    foreach ($path in $edgePaths) {
        if (Test-Path $path) {
            Write-Log "Deleting Edge component: $path"
            & takeown /f $path /r /d $(Get-TakeownYesAnswer) /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove Edge WebView directories inside WinSxS (covers amd64 and arm64)
    Write-Log "Removing Edge WebView assemblies from WinSxS..."
    $winSxSPaths = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    foreach ($winSxSPath in $winSxSPaths) {
        if (Test-Path $winSxSPath) {
            Write-Log "Taking ownership and removing WinSxS WebView folder: $winSxSPath"
            & takeown /f $winSxSPath /r /d $(Get-TakeownYesAnswer) /a | Out-Null
            & icacls $winSxSPath /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $winSxSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Removing OneDrive..."
    $oneDrivePaths = @(
        "$scratchDir\Windows\System32\OneDriveSetup.exe",
        "$scratchDir\Windows\SysWOW64\OneDriveSetup.exe"
    )
    foreach ($path in $oneDrivePaths) {
        if (Test-Path $path) {
            Write-Log "Deleting OneDrive setup: $path"
            & takeown /f $path /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
    }

    # Windows Update binaries (NON-SERVICEABLE BUILD)
    Write-Log "Removing Windows Update binaries (this is a non-serviceable build)..."
    Remove-Item -Path "$scratchDir\Windows\System32\usoclient.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UsoApiAll.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UsoApi.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UpdatePolicy.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\drivers\umbus.sys" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\SoftwareDistribution" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Edge and OneDrive removal complete"
    
    # Clean up other remnants
    Write-Log "Cleaning up other remnants (GameBar, Copilot)..."
    $otherRemnants = @(
        "$scratchDir\Windows\GameBarPresenceWriter",
        "$scratchDir\Windows\System32\SettingsHandlers_Copilot.dll"
    )
    foreach ($path in $otherRemnants) {
        if (Test-Path $path) {
            Write-Log "Deleting remnant: $path"
            & takeown /f $path /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-BitLockerComponents {
    Write-Log "Removing BitLocker components and binaries..."

    $bitlockerPaths = @(
        "$scratchDir\Windows\BitLockerDiscoveryVolumeContents",
        "$scratchDir\Windows\System32\BitLockerWizard.exe",
        "$scratchDir\Windows\System32\BitLockerWizardElev.exe",
        "$scratchDir\Windows\System32\BitLockerDeviceEncryption.exe",
        "$scratchDir\Windows\System32\BitLockerCsp.dll",
        "$scratchDir\Windows\SysWOW64\BitLockerCsp.dll"
    )

    foreach ($path in $bitlockerPaths) {
        if (Test-Path $path) {
            Write-Log "Deleting: $path"
            & takeown /f $path /r /d $(Get-TakeownYesAnswer) /a 2>&1 | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C 2>&1 | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Delete BitLocker MUI localization files
    Get-ChildItem -Path "$scratchDir\Windows\System32" -Filter "BitLocker*.mui" -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            & takeown /f $_.FullName /a 2>&1 | Out-Null
            & icacls $_.FullName /grant "$($adminGroup.Value):(F)" /C 2>&1 | Out-Null
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }

    Write-Log "BitLocker components removed"
}

function Remove-WinRE {
    Write-Log "Removing Windows Recovery Environment (winre.wim)..."

    $recoveryDir = "$scratchDir\Windows\System32\Recovery"
    & takeown /f $recoveryDir /r /d $(Get-TakeownYesAnswer) /a 2>&1 | Out-Null
    & icacls $recoveryDir /grant "$($adminGroup.Value):(F)" /T /C 2>&1 | Out-Null

    $winRE = "$recoveryDir\winre.wim"
    if (Test-Path $winRE) {
        Remove-Item -Path $winRE -Force -ErrorAction SilentlyContinue
        Write-Log "winre.wim deleted. Windows Setup will skip WinRE config gracefully."
    } else {
        Write-Log "winre.wim not found — already absent, nothing to do." "WARN"
    }

    Write-Log "WinRE removed"
}

function Patch-ReAgentXml {
    Write-Log "Patching ReAgent.xml to clear stale WinRE staging state..."

    $reagentXmlPath = "$scratchDir\Windows\System32\Recovery\ReAgent.xml"

    $cleanXml = @'
<?xml version='1.0' encoding='utf-8'?>
<WindowsRE version="2.0">
  <WinreBCD id="{00000000-0000-0000-0000-000000000000}"/>
  <WinreLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <ImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <PBRImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <PBRCustomImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <InstallState state="0"/>
  <OsInstallAvailable state="0"/>
  <CustomImageAvailable state="0"/>
  <IsAutoRepairOn state="0"/>
  <WinREStaged state="0"/>
  <OperationParam path=""/>
  <OemTool path=""/>
</WindowsRE>
'@

    # Only ever patch a ReAgent.xml that is already there. Creating the file (and
    # its parent directory) inside boot.wim adds entries the stock image does not
    # have, which is a gratuitous deviation from Microsoft's boot media - and the
    # boot media is precisely what third-party boot managers such as Ventoy
    # inspect and patch. The registry values set alongside this
    # (SkipInstallingWinRE / DisableRecovery / WinREEnabled) already suppress WinRE.
    if (-not (Test-Path -LiteralPath $reagentXmlPath)) {
        Write-Log "No ReAgent.xml at $reagentXmlPath - nothing to patch"
        return
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($reagentXmlPath, $cleanXml.TrimStart(), $utf8NoBom)
        Write-Log "ReAgent.xml patched: all WinRE state/staging fields zeroed."
    } catch {
        Write-Log "Failed to patch ReAgent.xml: $_" "WARN"
    }
}

function Remove-TreeForcefully {
    # Deletes a directory tree that Windows has made hostile to a plain
    # `Remove-Item -Recurse -Force`. Returns $true once the path is gone.
    #
    # Why this exists: DISM servicing of the offline image materialises newer
    # component versions into WinSxS.
    # Those arrive owned by TrustedInstaller, carrying the ReadOnly attribute,
    # and their folder names are long enough to push member files to *exactly*
    # 260 characters. Each of those defeats a different part of a naive delete:
    #
    #   * DeleteFile returns ACCESS_DENIED for a ReadOnly file even when the ACL
    #     grants delete, and Remove-Item's -Force cannot always clear the
    #     attribute first.
    #   * takeown/icacls use the legacy path APIs, so they silently skip anything
    #     at or over MAX_PATH (icacls /C just keeps going) - which is why the
    #     takeown+icacls pass earlier in Optimize-WinSxS did not save the delete.
    #   * Files still held by the servicing stack need a retry.
    #
    # So: operate on a \\?\ extended-length path, take ownership using the
    # locale-independent Administrators SID, clear the attributes, then delete
    # through several mechanisms with backoff.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxAttempts = 3
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $long     = if ($Path.StartsWith('\\?\')) { $Path } else { "\\?\$Path" }
    $adminSid = '*S-1-5-32-544'   # BUILTIN\Administrators, locale independent

    # Cheap attempt first - this is all a healthy tree ever needs.
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    # Every native tool below reports trouble on stderr. Under the script-level
    # $ErrorActionPreference = 'Stop', PowerShell 5.1 promotes redirected native
    # stderr into a *terminating* error, which would abort the cleanup instead of
    # letting the next strategy try. Scope it down for the duration.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            Write-Log "Force-deleting tree (attempt $attempt/$MaxAttempts): $Path" "WARN"

            & takeown.exe /F $long /R /A /D $(Get-TakeownYesAnswer) 2>&1 | Out-Null
            & icacls.exe  $long /grant "${adminSid}:(F)" /T /C /Q 2>&1 | Out-Null

            # attrib.exe handles the bulk quickly; the .NET pass afterwards
            # covers whatever attrib could not reach (it cannot take a \\?\).
            & cmd.exe /c "attrib -R -S -H `"$long\*`" /S /D" 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { } }

            try { Remove-Item -LiteralPath $long -Recurse -Force -ErrorAction Stop } catch { }
            if (-not (Test-Path -LiteralPath $Path)) { return $true }

            # cmd's rd walks the tree through a different code path and copes
            # with some leftovers the .NET provider will not.
            & cmd.exe /c "rd /s /q `"$long`"" 2>&1 | Out-Null
            if (-not (Test-Path -LiteralPath $Path)) { return $true }

            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (5 * $attempt) }
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }

    return (-not (Test-Path -LiteralPath $Path))
}

function Optimize-WinSxS {
    Write-Log "Optimizing WinSxS folder (this is a CORE feature)..."

    $sourceDirectory = "$scratchDir\Windows\WinSxS"
    $destinationDirectory = "$scratchDir\Windows\WinSxS_edit"

    # Create destination directory
    New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

    # Take ownership
    Write-Log "Taking ownership of WinSxS..."
    & takeown /f $sourceDirectory /r /d $(Get-TakeownYesAnswer) /a | Out-Null
    & icacls $sourceDirectory /grant "$($adminGroup.Value):(F)" /T /C | Out-Null

    $dirsToCopy = @()

    if ($script:architecture -eq "amd64") {
        $dirsToCopy = @(
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
            "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack-inetsrv_*",
            "x86_microsoft-windows-servicingstack-onecore_*",
            "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs",
            "FileMaps",
            "Fusion",
            "InstallTemp",
            "Manifests",
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        )
    } elseif ($script:architecture -eq "arm64") {
        $dirsToCopy = @(
            "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs",
            "FileMaps",
            "Fusion",
            "InstallTemp",
            "Manifests",
            "SettingsManifests",
            "Temp",
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "arm_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*",
            "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*",
            "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*",
            "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
            "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
        )
    }

    # Copy each directory
    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Log "Copying $($sourceDir.FullName) to $destDir"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }

    Write-Log "Replacing WinSxS with minimal version..."
    if (Remove-TreeForcefully -Path $sourceDirectory) {
        Rename-Item -Path $destinationDirectory -NewName "WinSxS"
        Write-Log "WinSxS optimization complete"
    } else {
        # Do not throw away a ~25 minute build over one stubborn file. Drop the
        # staging copy and keep the original WinSxS, which still yields a valid
        # image - just a much larger one. Warned loudly so it can never be
        # mistaken for a normal Core build.
        Write-Log "Could not remove the original WinSxS tree - SKIPPING WinSxS optimization. The resulting ISO will be much larger than a normal Core build." "WARN"
        if (-not (Remove-TreeForcefully -Path $destinationDirectory)) {
            Write-Log "Could not remove the WinSxS_edit staging tree either; the ISO will be larger still." "WARN"
        }
    }
}

function Load-RegistryHives {
    Write-Log "Loading registry hives..."

    Load-RegistryHive 'HKLM\zCOMPONENTS' "$scratchDir\Windows\System32\config\COMPONENTS"
    Load-RegistryHive 'HKLM\zDEFAULT' "$scratchDir\Windows\System32\config\default"
    Load-RegistryHive 'HKLM\zNTUSER' "$scratchDir\Users\Default\ntuser.dat"
    Load-RegistryHive 'HKLM\zSOFTWARE' "$scratchDir\Windows\System32\config\SOFTWARE"
    Load-RegistryHive 'HKLM\zSYSTEM' "$scratchDir\Windows\System32\config\SYSTEM"

    Write-Log "Registry hives loaded"
}

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        if ($name) {
            $arguments = @('add', $path, '/v', $name, '/t', $type, '/d', $value, '/f')
        } else {
            $arguments = @('add', $path, '/ve', '/t', $type, '/d', $value, '/f')
        }
        Invoke-NativeCommand -FilePath 'reg.exe' -Arguments $arguments -Quiet
        Write-Log "Set registry: $path\$name = $value"
    } catch {
        Write-Log "Error setting registry $path\$name : $_" "ERROR"
        throw
    }
}

function Remove-RegistryValue {
    # Removes a single value from a registry key. $path is the full
    # "key\valueName" form (e.g. '...\Run\OneDriveSetup'), where everything
    # after the last backslash is the value name and the rest is the key.
    param([string]$path)
    $lastSlash = $path.LastIndexOf('\')
    if ($lastSlash -lt 0) {
        Write-Log "Invalid registry value path (missing key\value separator): $path" "WARN"
        return
    }
    $keyPath = $path.Substring(0, $lastSlash)
    $valueName = $path.Substring($lastSlash + 1)
    try {
        Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $keyPath, '/v', $valueName, '/f') -Quiet
        Write-Log "Removed registry value: $path"
    } catch {
        Write-Log "Registry value not found or error: $path" "WARN"
    }
}

function Apply-RegistryTweaks {
    Write-Log "Applying registry tweaks..."

    # Helper function to ensure key exists is no longer needed with reg add

    if ($BypassHardwareRequirements) {
        Write-Log "Explicitly adding Windows Setup hardware-check bypasses to the VM/Lab image." "WARN"
        Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    } else {
        Write-Log "No Windows Setup hardware-check bypasses are added by default."
    }

    # Disable sponsored apps
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
    
    $startPins = '{"pinnedList": [{}]}'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' $startPins
    
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'

    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    
    Remove-Item -Path "HKLM:\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" -Recurse -Force -ErrorAction SilentlyContinue

    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

    # Out-of-the-box offline local account.
    # BypassNRO re-enables the "I don't have internet" path Microsoft removed from
    # the OOBE UI in 24H2+, and DisableOnline stops OOBE demanding a network
    # connection before it will continue. These are belt-and-braces - the real
    # guarantee is the pre-created local account in autounattend.xml.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'

    # Bake the answer file into the image too, so a later sysprep /generalize keeps
    # the same OOBE behaviour.
    Write-IsoAnswerFile -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -AccountMode $AccountSetup -ImageIndex 1

    # Disable reserved storage
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

    # Disable BitLocker and automatic device encryption
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitlockerStatus' 'BootStatus' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\BDESVC' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\BitLocker' 'IsBdeDriverPresent' 'REG_DWORD' '0'

    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    # Remove Edge registries
    Remove-Item -Path "HKLM:\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" -Recurse -Force -ErrorAction SilentlyContinue

    # Disable OneDrive folder backup
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'

    # Remove OneDrive from Run keys (prevent auto-install on first login)
    Remove-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"
    Remove-RegistryValue "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"

    # Disable telemetry
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'

    Remove-Item -Path "HKLM:\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" -Recurse -Force -ErrorAction SilentlyContinue

    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

    # Out-of-the-box offline local account.
    # BypassNRO re-enables the "I don't have internet" path Microsoft removed from
    # the OOBE UI in 24H2+, and DisableOnline stops OOBE demanding a network
    # connection before it will continue. These are belt-and-braces - the real
    # guarantee is the pre-created local account in autounattend.xml.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'

    # Bake the answer file into the image too, so a later sysprep /generalize keeps
    # the same OOBE behaviour.

    # Disable reserved storage
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

    # Disable BitLocker and automatic device encryption
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitlockerStatus' 'BootStatus' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\BDESVC' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\BitLocker' 'IsBdeDriverPresent' 'REG_DWORD' '0'

    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    # Remove Edge registries
    Remove-Item -Path "HKLM:\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" -Recurse -Force -ErrorAction SilentlyContinue

    # Disable OneDrive folder backup
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'

    # Remove OneDrive from Run keys (prevent auto-install on first login)
    Remove-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"
    Remove-RegistryValue "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"

    # Disable telemetry
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

    # Prevent DevHome and Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'

    Remove-Item -Path "HKLM:\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" -Recurse -Force -ErrorAction SilentlyContinue

    # Disable Copilot
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

    # Disable AI features (Recall, AI Fabric, Windows AI)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffWindowsAI' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    
    # Enhanced telemetry removal
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' 'ShowedToastAtLevel' 'REG_DWORD' '1'
    
    # Gaming optimization: Increase VRAM allocation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\DirectDraw' 'EmulationOnly' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Direct3D' 'DisableVidMemVBs' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'DpiMapIommuContiguous' 'REG_DWORD' '1'

    # Prevent Teams installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

    # Prevent new Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

    # Disable Windows Update services
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE1' 'REG_SZ' 'net stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE2' 'REG_SZ' 'sc stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE3' 'REG_SZ' 'sc config wuauserv start= disabled'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisbaleWUPostOOBE1' 'REG_SZ' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisbaleWUPostOOBE2' 'REG_SZ' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'UpdateServiceUrlAlternate' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' 'Start' 'REG_DWORD' '4'

    # Disable Windows Defender
    Write-Log "Disabling Windows Defender services..."
    $servicePaths = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
    foreach ($path in $servicePaths) {
        $servicePath = "HKLM:\zSYSTEM\ControlSet001\Services\$path"
        if (Test-Path $servicePath) {
            Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$path" "Start" "REG_DWORD" "4"
        }
    }

    # Disable WinRE — prevents reagentc from trying to reconfigure the recovery
    # environment on first boot after winre.wim has been removed.
    if (-not $PreserveWinRE) {
        # The OS image intentionally omits WinRE; keep reagentc from staging a missing image.
        Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\WinRE' 'WinREEnabled' 'REG_DWORD' '0'
    } else {
        Write-Log "PreserveWinRE set; leaving the OS WinRE configuration enabled." "INFO"
    }

    # Hide both Settings pages. This is the ONLY write site for
    # SettingsPageVisibility in this script: a Core-Gaming build inherits it
    # rather than writing its own copy, so the shipped value cannot depend on
    # the order the two code paths happen to run in.
    #
    # Page ids are the ms-settings URI minus the 'ms-settings:' prefix. The
    # Windows Security page is 'windowsdefender'. The value here used to read
    # 'hide:virus;windowsupdate' - 'virus' is not a Windows 11 page id at all,
    # so it hid nothing.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:windowsupdate;windowsdefender'

    # Easter Egg / Branding
    Write-Log "Adding Easter Egg branding..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticecaption' 'REG_SZ' 'TINY11-AUTOMATION'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticetext' 'REG_SZ' 'Built by NggKhaiz from the tiny11 builder by ntdevlabs and kelexine automation.'
    
    # Desktop Context Menu Link
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'MUIVerb' 'REG_SZ' 'TINY11-AUTOMATION Info'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Icon' 'REG_SZ' 'shell32.dll,22'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Position' 'REG_SZ' 'Bottom'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info\command' '' 'REG_SZ' 'explorer.exe "https://github.com/NggKhaiz/TINY11-AUTOMATION"'

    Write-Log "Registry tweaks applied"
}

function Remove-ScheduledTasks {
    Write-Log "Removing telemetry scheduled tasks..."

    $tasksPath = "$scratchDir\Windows\System32\Tasks"
    $tasksToRemove = @(
        "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
        "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
        "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
    )

    foreach ($task in $tasksToRemove) {
        if (Test-Path $task) {
            Remove-Item -Path $task -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed task: $([System.IO.Path]::GetFileName($task))"
        }
    }

    Write-Log "Scheduled tasks removed"
}

function Remove-NonEssentialServices {
    Write-Log "Removing non-essential services (aggressive for core build)..."
    
    # Core build: Aggressive service removal for non-serviceable VM builds
    $servicesToRemove = @(
        'DiagTrack',           # Connected User Experiences and Telemetry
        'WerSvc',              # Windows Error Reporting
        'PcaSvc',              # Program Compatibility Assistant
        'SysMain',             # Superfetch
        'Spooler',             # Print Spooler
        'PrintNotify',         # Printer Notifications
        'Fax',                 # Fax Service
        'RemoteRegistry',      # Remote Registry
        'diagsvc',             # Diagnostic Execution Service
        'MapsBroker',          # Downloaded Maps Manager
        'WalletService',       # Wallet Service
        'BthAvctpSvc',         # Bluetooth Audio
        'BluetoothUserService' # Bluetooth User Support
    )
    
    foreach ($service in $servicesToRemove) {
        Write-Log "Disabling service: $service"
        try {
            Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$service" 'Start' 'REG_DWORD' '4'
        } catch {
            Write-Log "Could not disable service $service : Service may not exist" "WARN"
        }
    }
    
    Write-Log "Aggressive service removal complete"
}

function Apply-PerformanceTweaks {
    # Prior automation credit: kelexine
    # Applies legacy experimental Core/VM registry values. Effects and safety depend
    # on the Windows build and hardware; these settings are not performance-tested.
    Write-Log "Applying configured Core/VM registry settings (experimental profile)..."

    # ── Memory Management ──────────────────────────────────────────────────
    # Requests pageable kernel code remain resident; this can increase RAM use and
    # has no benchmark-validated latency benefit in this project.
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'DisablePagingExecutive'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'LargeSystemCache'        'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 'REG_DWORD' '0'

    # ── CPU / Thread Scheduler ─────────────────────────────────────────────
    # Legacy scheduler value from the Core profile; workload effects are unverified.
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\PriorityControl' 'Win32PrioritySeparation' 'REG_DWORD' '38'

    # ── MMCSS (Multimedia Class Scheduler) ────────────────────────────────
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 'REG_DWORD' '0xffffffff'
    # Legacy MMCSS value from the Core profile; Windows-version and workload effects
    # are not benchmarked here.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness'   'REG_DWORD' '0'
    # MMCSS Games task values are configured below; actual scheduler treatment is
    # controlled by Windows and is not verified by this static build.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority'        'REG_DWORD' '8'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'            'REG_DWORD' '6'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'REG_SZ'    'High'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority'       'REG_SZ'    'High'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Latency Sensitive'   'REG_SZ'    'True'

    # ── Storage / NTFS ────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisableLastAccessUpdate'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsMemoryUsage'              'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'DisableDeleteNotification'    'REG_DWORD' '0'

    # ── Network / TCP ─────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 'REG_DWORD' '30'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'MaxUserPort'       'REG_DWORD' '65534'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'Tcp1323Opts'       'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'DefaultTTL'        'REG_DWORD' '64'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'EnableWsd'         'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneNagle' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces | ForEach-Object { Set-ItemProperty $_.PSPath TCPNoDelay 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TcpAckFrequency 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TCPDelAckTicks 0 -Type DWord -ErrorAction SilentlyContinue }"'

    # ── Gaming ────────────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'HwSchMode'   'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDelay'    'REG_DWORD' '10'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDdiDelay' 'REG_DWORD' '10'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_Enabled'                        'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_FSEBehaviorMode'                'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode'       'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_EFSEBehaviorMode'               'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode'   'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 'REG_DWORD' '1'

    # ── Boot Time ─────────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager' 'AutoChkTimeOut' 'REG_DWORD' '0'
    # Fast Startup is disabled in this Core/VM profile; boot and hibernation behavior
    # changes, but no startup-time improvement is claimed.
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power' 'HiberbootEnabled' 'REG_DWORD' '0'
    # Keep crash dump on BSOD instead of silent auto-reboot — preserves minidump for analysis
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\CrashControl' 'AutoReboot' 'REG_DWORD' '0'
    # BCD values below are experimental configuration requests. Older builds set
    # useplatformtick explicitly; clear that override rather than asserting a
    # universal timer source or performance benefit. Platform behavior is untested.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneBCD' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "& bcdedit /set timeout 5 2>&1 | Out-Null; & bcdedit /set disabledynamictick yes 2>&1 | Out-Null; & bcdedit /deletevalue useplatformtick 2>&1 | Out-Null"'

    Write-Log "Configured Core/VM registry settings written (experimental profile)"
}

function Unload-RegistryHives {
    Write-Log "Unloading registry hives..."

    # Release managed handles before asking reg.exe to unload each hive.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3

    $failures = @()
    foreach ($hive in @($script:LoadedRegistryHives)) {
        try {
            Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('unload', $hive) -Quiet
            $script:LoadedRegistryHives = @($script:LoadedRegistryHives | Where-Object { $_ -ne $hive })
        } catch {
            $failures += "${hive}: $_"
            Write-Log "Failed to unload registry hive $hive : $_" "ERROR"
        }
    }

    if ($failures.Count -gt 0) {
        throw "One or more offline registry hives could not be unloaded: $($failures -join '; ')"
    }
    Write-Log "Registry hives unloaded"
}

function Optimize-WindowsImage {
    Write-Log "Cleaning up Windows image (this may take 10-15 minutes)..."
    Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
        "/Image:$scratchDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'
    ) -Quiet
    Write-Log "Image cleanup complete"
}

function Dismount-AndExport {
    Write-Log "Dismounting install.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save

    Write-Log "Exporting image with maximum compression (this may take 15-20 minutes)..."
    $tempWim = "$tiny11Dir\sources\install2.wim"
    & Dism.exe /Export-Image /SourceImageFile:$wimFilePath /SourceIndex:$INDEX `
        /DestinationImageFile:$tempWim /Compress:max | Out-Null

    # Never delete the source image if the export above failed. A failed export that
    # still deletes install.wim leaves the ISO with no install image at all, and
    # Windows Setup reports that as "A media driver your computer needs is missing"
    # - which looks like a USB or driver fault and hides the real cause.
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tempWim)) {
        throw "DISM /Export-Image failed (exit code $LASTEXITCODE). Refusing to delete $wimFilePath."
    }

    Remove-Item -Path $wimFilePath -Force
    Rename-Item -Path $tempWim -NewName "install.wim"

    Write-Log "Install.wim export complete"
}

function Process-BootImage {
    Write-Log "Processing boot.wim..."

    $bootWimPath = "$tiny11Dir\sources\boot.wim"

    # Take ownership and set permissions before mounting the boot image.
    Invoke-NativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $bootWimPath, '/A') -Quiet
    Invoke-NativeCommand -FilePath 'icacls.exe' -Arguments @($bootWimPath, '/grant', "$($adminGroup.Value):(F)") -Quiet
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    Write-Log "Mounting boot.wim (Index 2)..."
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir

    # Load registry and apply tweaks
    Load-RegistryHive 'HKLM\zCOMPONENTS' "$scratchDir\Windows\System32\config\COMPONENTS"
    Load-RegistryHive 'HKLM\zDEFAULT' "$scratchDir\Windows\System32\config\default"
    Load-RegistryHive 'HKLM\zNTUSER' "$scratchDir\Users\Default\ntuser.dat"
    Load-RegistryHive 'HKLM\zSOFTWARE' "$scratchDir\Windows\System32\config\SOFTWARE"
    Load-RegistryHive 'HKLM\zSYSTEM' "$scratchDir\Windows\System32\config\SYSTEM"

    Write-Log "Applying VM/Lab recovery settings to the boot image. Hardware-check bypass=$([bool]$BypassHardwareRequirements)."
    if ($BypassHardwareRequirements) {
        Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    }
    if (-not $PreserveWinRE) {
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'DisableRecovery' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'SkipInstallingWinRE' 'REG_DWORD' '1'
        Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\WinRE' 'WinREEnabled' 'REG_DWORD' '0'
        Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Setup\Recovery' 'DisableRecovery' 'REG_DWORD' '1'
        Write-Log "WinRE is omitted for this VM/Lab build; Setup recovery is disabled." "INFO"
    } else {
        Write-Log "PreserveWinRE set; leaving Setup recovery settings unchanged." "INFO"
    }
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    # Keep Microsoft's stock WinPE Setup command line. Rewriting HKLM\SYSTEM\Setup\CmdLine
    # can prevent third-party boot managers such as Ventoy from mounting the ISO.
    # The stock boot.wim already launches Setup; no override is needed.

    # If winre.wim was removed from the OS image, patch ReAgent.xml in boot.wim as well
    # so SetupHost does not attempt to stage SafeOS from Install.esd during WinPE setup (bypasses error 0x80070003 at 11%)
    if (-not $PreserveWinRE) {
        Write-Log "Patching ReAgent.xml in boot.wim to suppress WinRE SafeOS extraction..."
        Patch-ReAgentXml
    }

    # Unload the boot-image registry hives before saving the mount.
    Unload-RegistryHives

    Write-Log "Dismounting boot.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save

    Write-Log "Boot image processing complete"
}

function Convert-ToESD {
    Write-Log "Converting to ESD format for maximum compression (this may take 20-30 minutes)..."

    $esdPath = "$tiny11Dir\sources\install.esd"
    & dism /Export-Image /SourceImageFile:$wimFilePath /SourceIndex:1 /DestinationImageFile:$esdPath /Compress:recovery

    # Same guard as Dismount-AndExport: never delete the source WIM unless the ESD
    # export actually succeeded.
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $esdPath)) {
        throw "DISM /Export-Image to install.esd failed (exit code $LASTEXITCODE). Refusing to delete $wimFilePath."
    }

    # Remove the WIM file
    Remove-Item $wimFilePath -Force

    Write-Log "ESD conversion complete"
}

function Create-TinyISO {
    Write-Log "Creating ISO image..."

    # The answer file at the ISO root is the one Windows Setup auto-detects when
    # booting the media. Write-IsoAnswerFile also pins the edition index into it.
    Write-IsoAnswerFile -Destination "$tiny11Dir\autounattend.xml" -AccountMode $AccountSetup -ImageIndex 1

    # Guard: an ISO with no usable install image produces exactly the symptom
    # "A media driver your computer needs is missing" when Setup looks for its media,
    # which is easy to misread as a USB or driver fault. Fail the build here rather
    # than shipping it.
    $installImages = @("$tiny11Dir\sources\install.wim", "$tiny11Dir\sources\install.esd") |
        Where-Object { Test-Path $_ }

    if (-not $installImages) {
        throw "No install.wim or install.esd in $tiny11Dir\sources - the image export step failed. Refusing to build an ISO that Setup cannot install from."
    }

    foreach ($img in $installImages) {
        $imgMB = [math]::Round((Get-Item $img).Length / 1MB, 1)
        Write-Log "Install image $([System.IO.Path]::GetFileName($img)): ${imgMB}MB"
        if ($imgMB -lt 500) {
            throw "Install image $img is only ${imgMB}MB - it looks truncated. Refusing to build the ISO."
        }
    }

    # A leftover export would confuse Setup's media detection.
    foreach ($stray in @('install2.wim', 'install2.esd')) {
        $strayPath = Join-Path "$tiny11Dir\sources" $stray
        if (Test-Path $strayPath) {
            Write-Log "Removing leftover $stray from sources\" "WARN"
            Remove-Item -Path $strayPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Verify boot files exist before creating ISO
    $bootFiles = @(
        "$tiny11Dir\boot\etfsboot.com",
        "$tiny11Dir\efi\microsoft\boot\efisys.bin"
    )

    foreach ($bootFile in $bootFiles) {
        if (-not (Test-Path $bootFile)) {
            throw "Required boot file not found: $bootFile"
        }
        Write-Log "Boot file verified: $bootFile"
    }

    # Determine oscdimg.exe location
    $hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

    if (Test-Path "$ADKDepTools\oscdimg.exe") {
        Write-Log "Using oscdimg.exe from Windows ADK"
        $OSCDIMG = "$ADKDepTools\oscdimg.exe"
    } else {
        Write-Log "ADK not found, downloading oscdimg.exe..."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

        if (-not (Test-Path $localOSCDIMGPath)) {
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath -UseBasicParsing
            $script:DownloadedOscdimg = $true
            Write-Log "Downloaded oscdimg.exe"
        }

        $OSCDIMG = $localOSCDIMGPath
    }

    # ---- ISO container --------------------------------------------------------
    # -u2        ISO9660 + Joliet + UDF, the layout Microsoft's own retail media
    #            uses. ISO9660 alone cannot hold a >4 GB file, so the UDF layer is
    #            what carries install.wim.
    # -udfver150 UDF 1.50 rather than 1.02. UDF 1.02 cannot describe a single file
    #            larger than 4 GB and a Standard install.wim can exceed that. This
    #            is a robustness fix only - it is NOT what made Ventoy fail. See
    #            "Booting a Tiny11 ISO from Ventoy" in README.md for that.
    # Build the ISO and check the native exit code. Removing a previous artifact
    # first prevents a failed oscdimg invocation from being mistaken for success.
    Write-Log "Building bootable ISO (this may take 5-10 minutes)..."
    if (Test-Path -LiteralPath $outputISO) {
        Remove-Item -LiteralPath $outputISO -Force
    }
    Invoke-NativeCommand -FilePath $OSCDIMG -Arguments @(
        '-m', '-o', '-u2', '-udfver150',
        "-bootdata:2#p0,e,b$tiny11Dir\boot\etfsboot.com#pEF,e,b$tiny11Dir\efi\microsoft\boot\efisys.bin",
        $tiny11Dir, $outputISO
    ) -Quiet

    if (Test-Path $outputISO) {
        $isoSize = [math]::Round((Get-Item $outputISO).Length / 1GB, 2)
        Write-Log "ISO created successfully: $outputISO (${isoSize}GB)"
    } else {
        throw "ISO creation failed"
    }
}

function Write-BuildInfo {
    # kelexine: emits build metadata JSON so CI can read the real Windows build number
    param(
        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )
    try {
        $buildInfo = @{
            profile       = 'VM/LabCore'
            account_setup = $AccountSetup
            hardware_requirement_bypass = [bool]$BypassHardwareRequirements
            windows_build = $script:DetectedBuildNumber
            full_version  = $script:DetectedFullVersion
            image_name    = $script:DetectedImageName
            source_index  = $script:SourceImageIndex
            working_index = $INDEX
            edition       = $script:DetectedEdition
            final_image_index = 1
            generated_at  = (Get-Date -Format 'o')
        }
        $buildInfo | ConvertTo-Json | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-Log "Build info written to $OutputPath"
    } catch {
        Write-Log "Failed to write build info to $OutputPath : $_" "WARN"
    }
}

function Invoke-Cleanup {
    if ($SkipCleanup) {
        Write-Log "Skipping cleanup (SkipCleanup flag set)" "WARN"
        return
    }

    Write-Log "Performing cleanup..."

    # Remove temporary directories
    Remove-Item -Path $tiny11Dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

    # Remove only the oscdimg copy this invocation downloaded. Never delete a
    # caller-provided utility or answer-file configuration during cleanup.
    if ($script:DownloadedOscdimg) {
        Remove-Item -LiteralPath "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    }

    # Verify cleanup
    $remainingItems = @()
    if (Test-Path $tiny11Dir) { $remainingItems += "tiny11 folder" }
    if (Test-Path $scratchDir) { $remainingItems += "scratchdir folder" }

    if ($remainingItems.Count -gt 0) {
        Write-Log "Cleanup incomplete: $($remainingItems -join ', ') still exist" "WARN"
    } else {
        Write-Log "Cleanup complete"
    }
}


#---------[ Main Execution ]---------
try {
    Write-Log "=== Tiny11 Core Headless Builder Started ===" "INFO"
    Write-Log "Maintainer: NggKhaiz; automation credit: kelexine; original builder: ntdevlabs"
    Write-Log "Profile: VM/LabCore (experimental; not a primary OS); Edition=$Edition; hardware bypass=$([bool]$BypassHardwareRequirements)"
    Write-Log "Parameters: ISO=$ISO, INDEX=$INDEX (0 means auto-select by edition), SCRATCH=$ScratchDisk, AccountSetup=$AccountSetup, RemoveDefender=$RemoveDefender"
    if ($GamingProfile) { Write-Log "Gaming profile: ENABLED (HagsMode=$HagsMode)" }
    Write-Log "WARNING: This creates a minimal Windows 11 Core image - NOT for daily use!"

    if ($GamingProfile) {
        Initialize-GamingModule -LogFile $logFile -ProfileDirectory $gamingConfigDir
        $gamingProfileData = Import-GamingProfile -Path $GamingProfileFile
        $gamingGroupFlags = Resolve-GamingGroups -Profile $gamingProfileData -Overrides $GamingGroups

        $onGroups = @()
        $offGroups = @()
        foreach ($name in ($gamingGroupFlags.Keys | Sort-Object)) {
            if ($gamingGroupFlags[$name]) { $onGroups += $name } else { $offGroups += $name }
        }
        Write-Log "Gaming groups ON : $($onGroups -join ', ')"
        if ($offGroups.Count -gt 0) {
            Write-Log "Gaming groups OFF: $($offGroups -join ', ')"
        } else {
            Write-Log "Gaming groups OFF: (none)"
        }

        # Essentials pass. The workflow validates this file before it downloads the
        # ISO; the builder re-validates because it is the authority and may be run
        # directly. Either way a bad edit fails here, not 40 minutes into DISM.
        # There is no toggle: this always runs on a Core-Gaming build.
        Initialize-EssentialsModule -LogFile $logFile -ProfileDirectory $gamingConfigDir
        $essentialsConfig = Join-Path $gamingConfigDir 'essentials_profile.json'
        $essentialsProfileData = Import-EssentialsProfile -Path $essentialsConfig
        Write-Log "Essentials pass: ENABLED (always on for Core-Gaming, $(@($essentialsProfileData.registry).Count) registry value(s), $(@($essentialsProfileData.services).Count) service(s))"
    }

    Test-Prerequisites
    Initialize-Directories

    Resolve-ImageIndex

    # Handle install.esd conversion if needed
    if (Test-Path "$DriveLetter\sources\install.esd") {
        Write-Log "Found install.esd, conversion required"
        Convert-ESDToWIM
        Copy-WindowsFiles
        Write-Log "Resetting working INDEX to 1 since ESD was exported to a one-image WIM"
        $script:INDEX = 1
    } else {
        Write-Log "Found install.wim, no conversion needed"
        Copy-WindowsFiles
    }

    Mount-WindowsImageFile
    Get-ImageMetadata

    # Customization phase
    Remove-BloatwareApps
    Remove-SystemPackages

    # Gaming profile: image-level removals. These run while the image hives are still
    # unloaded, because DISM package/feature operations must not race with a mounted hive.
    if ($GamingProfile) {
        Invoke-GamingAppxRemoval            -Profile $gamingProfileData -Groups $gamingGroupFlags -ScratchDir $scratchDir
        Invoke-GamingSystemPackageRemoval   -Profile $gamingProfileData -Groups $gamingGroupFlags -ScratchDir $scratchDir
        Invoke-GamingOptionalFeatureRemoval -Profile $gamingProfileData -Groups $gamingGroupFlags -ScratchDir $scratchDir
    }

    # Defender / Security removal. Opt-in via -RemoveDefender on a plain Core
    # build; a Core-Gaming build always gets it. This is destructive and is not a
    # supported substitute for antivirus on a daily-use Windows installation.
    # The payload half runs here, while the image hives are still unloaded; the
    # registry half runs later, right after Load-RegistryHives.
    if ($RemoveDefender -or $GamingProfile) {
        Remove-DefenderPayload
    }

    # Gaming profile: complete Windows Update removal. Payload half, so it runs
    # while the hives are still unloaded.
    if ($GamingProfile) {
        Remove-WindowsUpdatePayload
    }

    # .NET 3.5 installation (optional, Core-only)
    if ($ENABLE_DOTNET35) {
        Write-Log "Enabling .NET 3.5..." "INFO"
        & dism /English /image:$scratchDir /enable-feature /featurename:NetFX3 /All /source:$tiny11Dir\sources\sxs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log ".NET 3.5 has been enabled" "SUCCESS"
        } else {
            Write-Log ".NET 3.5 installation failed (exit code: $LASTEXITCODE)" "WARN"
        }
    } else {
        Write-Log ".NET 3.5 will not be enabled (ENABLE_DOTNET35: $ENABLE_DOTNET35)" "INFO"
    }

    Remove-EdgeAndOneDrive
    Remove-BitLockerComponents
    if ($PreserveWinRE) {
        Write-Log "Skipping WinRE removal (PreserveWinRE flag set)" "INFO"
    } else {
        Remove-WinRE
    }

    Load-RegistryHives
    Apply-RegistryTweaks
    if ($RemoveDefender -or $GamingProfile) {
        Remove-DefenderRegistry
    }

    # Essentials pass, registry half. Deliberately placed between the Core registry
    # pass and the performance/gaming passes: performance settings outrank privacy and
    # cosmetic defaults, so anything that ever collides is resolved in that direction.
    if ($GamingProfile -and $essentialsProfileData) {
        Invoke-EssentialsRegistryTweaks -Profile $essentialsProfileData
    }

    # Gaming profile: complete Windows Update removal. Registry half. Runs after
    # Apply-RegistryTweaks so it wins over the always-on Core WU policies.
    if ($GamingProfile) {
        Remove-WindowsUpdateStack
    }

    Apply-PerformanceTweaks

    # Gaming profile must run AFTER Apply-PerformanceTweaks so it can deliberately
    # override the Core defaults (Game Mode on -> off, SystemResponsiveness 0 -> 10).
    if ($GamingProfile) {
        Invoke-GamingRegistryTweaks -Profile $gamingProfileData -Groups $gamingGroupFlags
        Set-GamingHagsMode -Profile $gamingProfileData -HagsMode $HagsMode
    }

    Remove-ScheduledTasks
    Remove-NonEssentialServices

    if ($GamingProfile -and $essentialsProfileData) {
        Invoke-EssentialsServiceTweaks -Profile $essentialsProfileData
    }

    if ($GamingProfile) {
        Invoke-GamingServiceTweaks -Profile $gamingProfileData -Groups $gamingGroupFlags
    }

    Unload-RegistryHives

    # WinSxS optimization (CORE-specific)
    Optimize-WinSxS

    # Gaming profile: stage the first-boot payload into the mounted image. This MUST
    # happen before Dismount-AndExport so the files land inside install.wim.
    # Only install.wim is touched - never boot.wim, which Ventoy inspects and patches.
    if ($GamingProfile) {
        New-GamingFirstBootPayload -Profile $gamingProfileData -Groups $gamingGroupFlags `
            -ScratchDir $scratchDir -ScriptRoot $PSScriptRoot -HagsMode $HagsMode

        # Essentials: stage its data next to the gaming payload, write the audit
        # manifest, and add the report script. gaming-firstboot.ps1 picks the JSON up
        # from the same directory and runs the first-boot half of the layer.
        if ($essentialsProfileData) {
            $gamingPayloadDir = Join-Path $scratchDir 'Windows\Tiny11Gaming'
            Copy-Item -LiteralPath (Join-Path $gamingConfigDir 'essentials_profile.json') `
                -Destination (Join-Path $gamingPayloadDir 'essentials_profile.json') -Force
            New-EssentialsManifest -Profile $essentialsProfileData `
                -Destination (Join-Path $gamingPayloadDir 'ESSENTIALS_PROFILE.md')

            $reportSource = Join-Path $PSScriptRoot 'Tiny11-Report.ps1'
            if (Test-Path -LiteralPath $reportSource) {
                Copy-Item -LiteralPath $reportSource -Destination (Join-Path $gamingPayloadDir 'Tiny11-Report.ps1') -Force
            } else {
                Write-Log "Report script missing at $reportSource" "WARN"
            }
            Write-Log "Essentials payload staged into Windows\Tiny11Gaming"
        }
    }

    # Finalization phase
    Optimize-WindowsImage
    Dismount-AndExport
    Process-BootImage

    # Convert to ESD (CORE-specific: maximum compression)
    Convert-ToESD

    Create-TinyISO
    Write-BuildInfo -OutputPath "$PSScriptRoot\tiny11core-buildinfo.json"

    if ($GamingProfile) {
        Write-GamingBuildInfo -Profile $gamingProfileData -Groups $gamingGroupFlags `
            -OutputPath "$PSScriptRoot\tiny11core-gaming-buildinfo.json" `
            -HagsMode $HagsMode -WindowsBuild $script:DetectedBuildNumber
    }

    # Cleanup
    Invoke-Cleanup

    Write-Log "=== Tiny11 Core Build Completed Successfully ===" "INFO"
    Write-Log "Output: $outputISO"
    Write-Log "WARNING: This is a minimal Core build with reduced serviceability!"

    exit 0

} catch {
    Write-Log "FATAL ERROR: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"

    # Emergency cleanup
    try {
        Get-WindowsImage -Mounted | ForEach-Object {
            Write-Log "Emergency dismount: $($_.Path)" "WARN"
            Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue
        }

        # Unload any remaining registry hives
        @("zCOMPONENTS", "zDEFAULT", "zNTUSER", "zSOFTWARE", "zSYSTEM") | ForEach-Object {
            reg unload "HKLM\$_" 2>$null
        }
    } catch {
        Write-Log "Emergency cleanup failed: $_" "ERROR"
    }

    exit 1
}
