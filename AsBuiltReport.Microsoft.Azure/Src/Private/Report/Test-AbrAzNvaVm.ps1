function Test-AbrAzNvaVm {
    <#
    .SYNOPSIS
        Determines whether an Azure VM is a Network Virtual Appliance (NVA) by Marketplace
        image publisher or resource tag.
    .DESCRIPTION
        Shared by Get-AbrAzNetworkVirtualAppliance and Get-AbrAzNetworkTopology so both honour
        Options.NvaPublishers / Options.NvaTag identically. Owns the default publisher list and
        the NvaTag key=value parsing so both callers share one source of truth and cannot drift.
    .PARAMETER NvaPublishers
        Raw Options.NvaPublishers value. When null or empty, the built-in default publisher list
        is used.
    .PARAMETER NvaTag
        Raw Options.NvaTag value (e.g. 'Role' or 'Role=NVA'). Parsed internally into a tag key
        and optional required value.
    .NOTES
        Version:        0.2.0
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

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $NvaPublishers,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $NvaTag
    )

    # Default well-known NVA publishers. Overridden by Options.NvaPublishers when set.
    $DefaultNvaPublishers = @(
        'paloaltonetworks',
        'fortinet',
        'cisco',
        'checkpoint',
        'f5-networks',
        'barracudanetworks',
        'sonicwall-inc',
        'juniper-networks',
        'viptela',
        'riverbed'
    )

    $EffectivePublishers = if ($NvaPublishers -and $NvaPublishers.Count -gt 0) { $NvaPublishers } else { $DefaultNvaPublishers }

    $NvaTagKey = if ($NvaTag) { ($NvaTag -split '=')[0].Trim() } else { $null }
    $NvaTagValue = if ($NvaTag -and $NvaTag -like '*=*') { ($NvaTag -split '=', 2)[1].Trim() } else { $null }

    $ImageRef = $VM.StorageProfile.ImageReference
    $IsNvaByImg = [bool]($ImageRef.Publisher -and ($EffectivePublishers -contains $ImageRef.Publisher.ToLower()))

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
