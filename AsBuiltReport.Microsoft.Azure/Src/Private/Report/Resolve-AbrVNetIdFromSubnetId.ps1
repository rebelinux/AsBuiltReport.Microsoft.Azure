function Resolve-AbrVNetIdFromSubnetId {
    <#
    .SYNOPSIS
        Resolves the parent Virtual Network resource ID from a subnet resource ID.
    .DESCRIPTION
        Given a subnet resource ID of the form
        /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet},
        returns the VNet resource ID
        /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}.
        Returns $null if SubnetId is empty or does not contain a virtualNetworks segment.
    .NOTES
        Version:        0.1.0
        Author:         Tim Carman
        Twitter:        @tpcarman
        Github:         tpcarman
    .EXAMPLE

    .LINK

    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $SubnetId
    )

    if ([string]::IsNullOrEmpty($SubnetId)) { return $null }

    $Parts = $SubnetId.Split('/')
    $VNetIndex = [array]::IndexOf($Parts, 'virtualNetworks')
    if ($VNetIndex -lt 0 -or ($VNetIndex + 1) -ge $Parts.Count) { return $null }

    return ($Parts[0..($VNetIndex + 1)] -join '/')
}
