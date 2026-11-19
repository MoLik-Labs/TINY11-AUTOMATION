Set-StrictMode -Version Latest

function Select-Tiny11SourceImage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Images,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 2147483647)]
        [int]$RequestedIndex,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Home', 'Pro', 'Education', 'Enterprise')]
        [string]$Edition,

        [Parameter(Mandatory = $false)]
        [string]$ImagePath = 'Windows image'
    )

    $availableImages = @($Images | Where-Object { $null -ne $_ })
    if ($availableImages.Count -eq 0) {
        throw "No Windows images were found in $ImagePath"
    }

    $available = @($availableImages | ForEach-Object {
        "Index $($_.ImageIndex): $($_.ImageName)"
    })

    if ($RequestedIndex -eq 0) {
        $targetName = "Windows 11 $Edition"
        $matches = @($availableImages | Where-Object {
            $null -ne $_.ImageName -and ([string]$_.ImageName).Trim() -ieq $targetName
        })
        if ($matches.Count -ne 1) {
            throw "Could not uniquely select '$targetName' from this ISO. Available images: $($available -join '; '). Pass an explicit -INDEX after checking the image list."
        }
    } else {
        $matches = @($availableImages | Where-Object {
            $null -ne $_.ImageIndex -and [int]$_.ImageIndex -eq $RequestedIndex
        })
        if ($matches.Count -ne 1) {
            throw "Image index $RequestedIndex did not resolve to exactly one image in $ImagePath. Available images: $($available -join '; ')"
        }
    }

    $selectedImage = $matches[0]
    if ([string]::IsNullOrWhiteSpace([string]$selectedImage.ImageName)) {
        throw "Selected image index $($selectedImage.ImageIndex) has no image name in $ImagePath"
    }

    return [PSCustomObject]@{
        ImageIndex = [int]$selectedImage.ImageIndex
        Image = $selectedImage
    }
}

function Get-Tiny11BuildNumber {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FullVersion
    )

    if ([string]::IsNullOrWhiteSpace($FullVersion)) {
        return ''
    }

    $versionMatch = [regex]::Match($FullVersion, '^\d+\.\d+\.(\d{5})(?:\.(\d+))?$')
    if ($versionMatch.Success) {
        $build = $versionMatch.Groups[1].Value
        $ubr = $versionMatch.Groups[2].Value
        if ($ubr) {
            return "$build.$ubr"
        }
        return $build
    }

    if ([regex]::IsMatch($FullVersion, '^\d{5}(?:\.\d+)?$')) {
        return $FullVersion
    }

    return ''
}

Export-ModuleMember -Function Select-Tiny11SourceImage, Get-Tiny11BuildNumber
