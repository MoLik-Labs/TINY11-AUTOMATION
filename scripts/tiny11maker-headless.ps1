<#
.SYNOPSIS
    Headless script to build a trimmed-down Windows 11 image for CI/CD automation.

.DESCRIPTION
    Automated build of a streamlined Windows 11 image (tiny11) without user interaction.
    Designed for GitHub Actions workflows and other CI/CD pipelines.
    Uses only Microsoft utilities like DISM, with oscdimg.exe from Windows ADK.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 ISO (required, e.g., E)

.PARAMETER INDEX
    Windows image index to process. 0 auto-selects the requested edition by its actual image name (default Pro).

.PARAMETER SCRATCH
    Drive letter for scratch disk operations (optional, defaults to script root)

.PARAMETER SkipCleanup
    Skip cleanup of temporary files after ISO creation (optional, for debugging)

.EXAMPLE
    .\tiny11maker-headless.ps1 -ISO E
    .\tiny11maker-headless.ps1 -ISO E -INDEX 0 -Edition Pro
    .\tiny11maker-headless.ps1 -ISO E -INDEX 0 -Edition Home -SCRATCH D

.NOTES
    Original Author: ntdevlabs
    Automation by: kelexine (https://github.com/kelexine)
    Fork maintainer: NggKhaiz (https://github.com/NggKhaiz/TINY11-AUTOMATION)
    Original project: https://github.com/ntdevlabs/tiny11builder
    Date: 2025-12-08

    License status is documented in the repository README; no license is asserted here.
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

    [Parameter(Mandatory=$false, HelpMessage="Allow Windows Setup requirement bypasses (testing only; disabled by default)")]
    [switch]$BypassHardwareRequirements,

    [Parameter(Mandatory=$false, HelpMessage="Scratch disk drive letter (defaults to script directory)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$SCRATCH,

    [Parameter(Mandatory=$false, HelpMessage="Skip cleanup of temporary files")]
    [switch]$SkipCleanup
)

#---------[ Error Handling ]---------#
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'tiny11_image_metadata.psm1') -Force -ErrorAction Stop

#---------[ Configuration ]---------#
if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

$DriveLetter = $ISO + ":"
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
$scratchDir = "$ScratchDisk\scratchdir"
$tiny11Dir = "$ScratchDisk\tiny11"
$outputISO = "$PSScriptRoot\tiny11.iso"
$logFile = "$PSScriptRoot\tiny11_$(Get-Date -Format yyyyMMdd_HHmmss).log"
$script:DownloadedOscdimg = $false

#---------[ Functions ]---------#
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
}

$script:LoadedRegistryHives = @()

function Invoke-NativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Quiet
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $SuccessExitCodes) {
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

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )

    if ($name) {
        $arguments = @('add', $path, '/v', $name, '/t', $type, '/d', $value, '/f')
    } else {
        $arguments = @('add', $path, '/ve', '/t', $type, '/d', $value, '/f')
    }

    Invoke-NativeCommand -FilePath 'reg.exe' -Arguments $arguments -Quiet
    Write-Log "Set registry: $path\$name = $value"
}

function Remove-RegistryKey {
    param([string]$path)
    try {
        Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $path, '/f') -Quiet
        Write-Log "Removed registry key: $path"
    } catch {
        Write-Log "Registry key not found or could not be removed: $path ($_)" "WARN"
    }
}

function Remove-RegistryValue {
    # Removes a single value from the "key\valueName" form.
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
        Write-Log "Registry value not found or could not be removed: $path ($_)" "WARN"
    }
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."

    # Check admin rights
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
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

    # Check disk space (minimum 15GB recommended)
    $disk = Get-PSDrive -Name $ScratchDisk[0] -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [math]::Round($disk.Free / 1GB, 2)
        Write-Log "Available space on ${ScratchDisk}: ${freeGB}GB"
        if ($freeGB -lt 15) {
            Write-Log "Low disk space warning: ${freeGB}GB (15GB+ recommended)" "WARN"
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

    if ($requestedIndex -eq 0) {
        Write-Log "Auto-selected Windows 11 $Edition at actual image index $script:INDEX"
    }
    Write-Log "Selected: Index $script:INDEX - $($selectedImage.ImageName)"

    $script:DetectedImageName = $selectedImage.ImageName
    $script:DetectedEdition = $selectedImage.ImageName -replace '^Windows 11\s+', ''
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

    # Take ownership and set permissions
    Invoke-NativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $wimFilePath, '/A') -Quiet
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    Invoke-NativeCommand -FilePath 'icacls.exe' -Arguments @($wimFilePath, '/grant', "$($adminGroup.Value):(F)") -Quiet

    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    Mount-WindowsImage -ImagePath $wimFilePath -Index $INDEX -Path $scratchDir
    Write-Log "Image mounted at $scratchDir"
}

function Get-ImageMetadata {
    Write-Log "Extracting image metadata..."

    # Get language
    $imageIntl = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/English', '/Get-Intl', "/Image:$scratchDir")
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $languageCode = $Matches[1]
        Write-Log "Language: $languageCode"
    }

    # Get architecture
    $imageInfo = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/English', '/Get-WimInfo', "/wimFile:$wimFilePath", "/index:$INDEX")
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
}

function Remove-BloatwareApps {
    Write-Log "Removing only optional provisioned consumer apps; core apps and Windows infrastructure are retained..."

    $packages = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/English', "/image:$scratchDir", '/Get-ProvisionedAppxPackages') |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') {
                $Matches[1]
            }
        }

    # Keep the allow-list intentionally narrow for the physical-machine profile.
    # Do not remove Store, Photos, Paint, Camera, Terminal, WebExperience, Xbox,
    # OEM audio/driver apps, or system/servicing packages here.
    $packagePrefixes = @(
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.Windows.Copilot',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal',
        'Microsoft.OutlookForWindows',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.Todos',
        'Microsoft.Wallet',
        'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Teams',
        'MSTeams',
        'MicrosoftTeams'
    )

    $packagesToRemove = @($packages | Where-Object {
        $packageName = $_
        @($packagePrefixes | Where-Object { $packageName -like "*$_*" }).Count -gt 0
    })

    $removeCount = 0
    foreach ($package in $packagesToRemove) {
        Write-Log "Removing optional app: $package"
        Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/English', "/image:$scratchDir", '/Remove-ProvisionedAppxPackage', "/PackageName:$package") -Quiet
        $removeCount++
    }

    Write-Log "Removed $removeCount optional provisioned app packages"
}

function Confirm-StandardComponents {
    Write-Log "Standard/SafeLite profile preserves Edge and WebView2, OneDrive, Microsoft Store, device drivers, Defender, Windows Update, WinRE, and printing components."
}

function Apply-RegistryTweaks {
    Write-Log "Loading registry hives..."

    Load-RegistryHive 'HKLM\zCOMPONENTS' "$scratchDir\Windows\System32\config\COMPONENTS"
    Load-RegistryHive 'HKLM\zDEFAULT' "$scratchDir\Windows\System32\config\default"
    Load-RegistryHive 'HKLM\zNTUSER' "$scratchDir\Users\Default\ntuser.dat"
    Load-RegistryHive 'HKLM\zSOFTWARE' "$scratchDir\Windows\System32\config\SOFTWARE"
    Load-RegistryHive 'HKLM\zSYSTEM' "$scratchDir\Windows\System32\config\SYSTEM"

    Write-Log "Applying registry tweaks..."

    if ($BypassHardwareRequirements) {
        Write-Log "WARNING: Enabling Windows Setup hardware-requirement bypasses by explicit request." "WARN"
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
        Write-Log "Hardware requirement bypasses are disabled for the Standard profile."
    }

    # Disable sponsored apps
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
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

    Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'

    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

    # Leave Windows OOBE and account setup behavior at its default for stability.

    # Copy autounattend.xml if exists
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml"
    }

    # Keep reserved storage and device encryption defaults for reliable servicing and security.
    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    # Edge, WebView2 and OneDrive remain available in the Standard profile.

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
    # Keep Windows services at their Microsoft defaults; privacy settings above do not disable services.

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

    # Fork branding and attribution: this fork maintains the automation; original credits remain in the documentation.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticecaption' 'REG_SZ' 'TINY11-AUTOMATION'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticetext' 'REG_SZ' 'Built by NggKhaiz from the tiny11 builder by ntdevlabs and kelexine automation.'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'MUIVerb' 'REG_SZ' 'TINY11-AUTOMATION Info'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Icon' 'REG_SZ' 'shell32.dll,22'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Position' 'REG_SZ' 'Bottom'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info\command' '' 'REG_SZ' 'explorer.exe "https://github.com/NggKhaiz/TINY11-AUTOMATION"'

    Write-Log "Registry tweaks applied"
}

function Remove-ScheduledTasks {
    # Scheduled tasks are left intact in the physical-machine profile. This keeps
    # Windows servicing, diagnostics, recovery and maintenance behavior at defaults.
    Write-Log "Preserving scheduled tasks for servicing, diagnostics, recovery and maintenance."
}

function Remove-NonEssentialServices {
    # Do not disable services in the Standard profile. In particular, preserve
    # Windows Update, Defender, Print Spooler, SysMain and compatibility services.
    Write-Log "Preserving Windows services at Microsoft defaults (including Update, Defender, printing and SysMain)."
}

function Apply-PerformanceTweaks {
    # No unverified scheduler, network, GPU/TDR, NTFS or BCD tweaks are forced.
    # Hardware-dependent defaults are safer for low-end physical machines.
    Write-Log "Keeping Windows defaults for memory, CPU scheduling, TCP, NTFS, GPU scheduling and boot configuration."
}

function Unload-RegistryHives {
    Write-Log "Unloading registry hives..."
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
    Write-Log "Cleaning up superseded components without ResetBase (servicing rollback remains available)..."
    Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @("/Image:$scratchDir", '/Cleanup-Image', '/StartComponentCleanup') -Quiet
    Write-Log "Image cleanup complete"
}

function Dismount-AndExport {
    Write-Log "Dismounting install.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save

    Write-Log "Exporting image with maximum compression (this may take 15-20 minutes)..."
    $tempWim = "$tiny11Dir\sources\install2.wim"
    Invoke-NativeCommand -FilePath 'Dism.exe' -Arguments @(
        '/Export-Image', "/SourceImageFile:$wimFilePath", "/SourceIndex:$INDEX",
        "/DestinationImageFile:$tempWim", '/Compress:recovery'
    ) -Quiet
    if (-not (Test-Path $tempWim)) {
        throw "DISM reported success but the exported image was not created: $tempWim"
    }

    Remove-Item -Path $wimFilePath -Force
    Rename-Item -Path $tempWim -NewName "install.wim"

    Write-Log "Install.wim export complete"
}

function Process-BootImage {
    Write-Log "Processing boot.wim..."

    $bootWimPath = "$tiny11Dir\sources\boot.wim"

    # Take ownership
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    Invoke-NativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $bootWimPath, '/A') -Quiet
    Invoke-NativeCommand -FilePath 'icacls.exe' -Arguments @($bootWimPath, '/grant', "$($adminGroup.Value):(F)") -Quiet
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    Write-Log "Mounting boot.wim (Index 2)..."
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir

    Write-Log "Loading boot image registry..."
    Load-RegistryHive 'HKLM\zCOMPONENTS' "$scratchDir\Windows\System32\config\COMPONENTS"
    Load-RegistryHive 'HKLM\zDEFAULT' "$scratchDir\Windows\System32\config\default"
    Load-RegistryHive 'HKLM\zNTUSER' "$scratchDir\Users\Default\ntuser.dat"
    Load-RegistryHive 'HKLM\zSOFTWARE' "$scratchDir\Windows\System32\config\SOFTWARE"
    Load-RegistryHive 'HKLM\zSYSTEM' "$scratchDir\Windows\System32\config\SYSTEM"

    if ($BypassHardwareRequirements) {
        Write-Log "Applying explicitly requested Windows Setup hardware-requirement bypasses to boot image." "WARN"
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
        Write-Log "No TPM/CPU/Secure Boot/storage bypasses are added to the Standard boot image."
    }

    Unload-RegistryHives

    Write-Log "Dismounting boot.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save

    Write-Log "Boot image processing complete"
}

function Create-TinyISO {
    Write-Log "Creating ISO image..."

    # Copy autounattend.xml to ISO root for OOBE bypass
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$tiny11Dir\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml to ISO root"
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

    Write-Log "Building bootable ISO (this may take 5-10 minutes)..."
    if (Test-Path $outputISO) {
        Remove-Item -Path $outputISO -Force
    }
    Invoke-NativeCommand -FilePath $OSCDIMG -Arguments @(
        '-m', '-o', '-u2', '-udfver102',
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
            profile       = 'Standard/SafeLite'
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
    # Never delete caller/repository-provided unattended configuration during cleanup.

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

#---------[ Main Execution ]---------#
try {
    Write-Log "=== Tiny11 Headless Builder Started ===" "INFO"
    Write-Log "Maintainer: NggKhaiz; automation credit: kelexine; original builder: ntdevlabs"
    Write-Log "Profile: Standard/SafeLite (physical machines); Edition=$Edition; hardware bypass=$([bool]$BypassHardwareRequirements)"
    Write-Log "Parameters: ISO=$ISO, INDEX=$INDEX (0 means auto-select by edition), SCRATCH=$ScratchDisk"

    Test-Prerequisites

    Resolve-ImageIndex

    # Handle install.esd conversion if needed
    if (Test-Path "$DriveLetter\sources\install.esd") {
        Write-Log "Found install.esd, conversion required"
        Initialize-Directories
        Convert-ESDToWIM
        Copy-WindowsFiles
        Write-Log "Resetting INDEX to 1 since ESD was exported to a new WIM"
        $script:INDEX = 1
    } else {
        Write-Log "Found install.wim, no conversion needed"
        Initialize-Directories
        Copy-WindowsFiles
    }

    Mount-WindowsImageFile
    Get-ImageMetadata

    # Customization phase
    Remove-BloatwareApps
    Confirm-StandardComponents
    Apply-RegistryTweaks
    Apply-PerformanceTweaks
    Remove-ScheduledTasks
    Remove-NonEssentialServices
    Unload-RegistryHives

    # Finalization phase
    Optimize-WindowsImage
    Dismount-AndExport
    Process-BootImage
    Create-TinyISO
    Write-BuildInfo -OutputPath "$PSScriptRoot\tiny11-buildinfo.json"

    # Cleanup
    Invoke-Cleanup

    Write-Log "=== Tiny11 Build Completed Successfully ===" "INFO"
    Write-Log "Output: $outputISO"

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

        Unload-RegistryHives -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Emergency cleanup failed: $_" "ERROR"
    }

    exit 1
}
