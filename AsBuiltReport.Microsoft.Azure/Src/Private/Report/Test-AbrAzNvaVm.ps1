function Test-AbrAzNvaVm {
    <#
    .SYNOPSIS
        Determines whether an Azure VM is a Network Virtual Appliance (NVA) by Marketplace
        image publisher or resource tag.
    .DESCRIPTION
        Shared by Get-AbrAzNetworkVirtualAppliance and Get-AbrAzNetworkTopology so both honour
        Options.NvaPublishers / Options.NvaTag identically.
    .NOTES
        Version:        0.1.0
        Author:         Tim Carman
        Twitter:        @tpcarman
        Github:         tpcarman
    .EXAMPLE

    .LINK

    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [object] $VM,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $NvaPublishers,

        [Parameter()]
        [AllowNull()]
        [string] $NvaTagKey,

        [Parameter()]
        [AllowNull()]
        [string] $NvaTagValue
    )

    $ImageRef = $VM.StorageProfile.ImageReference
    $IsNvaByImg = [bool]($ImageRef.Publisher -and ($NvaPublishers -contains $ImageRef.Publisher.ToLower()))

    $IsNvaByTag = $false
    if ($NvaTagKey) {
        $TagVal = $VM.Tags[$NvaTagKey]
        $IsNvaByTag = if ($NvaTagValue) { $TagVal -eq $NvaTagValue } else { $null -ne $TagVal }
    }

    [PSCustomObject]@{
        IsNva      = ($IsNvaByImg -or $IsNvaByTag)
        IsNvaByImg = $IsNvaByImg
        IsNvaByTag = $IsNvaByTag
    }
}
