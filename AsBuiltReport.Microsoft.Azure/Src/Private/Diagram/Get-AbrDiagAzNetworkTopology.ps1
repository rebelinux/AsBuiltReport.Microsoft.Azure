function Get-AbrDiagAzNetworkTopology {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $VNets,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $PeeringEdges
    )
    begin {
        $LocalizedData = $reportTranslate.GetAbrAzNetworkTopology
    }
    process {
        try {
            $DiagramTheme = if ($Diagram.NetworkTopology.Theme) { $Diagram.NetworkTopology.Theme } else { 'White' }
            $DiagramDpi = if ($Diagram.NetworkTopology.Dpi) { $Diagram.NetworkTopology.Dpi } else { 96 }
            # PScribo's Image -Percent scales off raw pixel count assuming a fixed 96 DPI baseline,
            # so a higher render DPI must be offset by a proportionally lower Percent to keep the
            # printed size on the page the same while still gaining pixel density.
            $DiagramPercent = [Math]::Max(1, [Math]::Round(9600 / $DiagramDpi))
            $FontColor = if ($DiagramTheme -eq 'Black') { '#FFFFFF' } else { '#000000' }
            $EdgeColor = if ($DiagramTheme -eq 'Black') { '#AAAAAA' } else { '#333333' }
            $CellBgColor = if ($DiagramTheme -eq 'Black') { '#2D2D2D' } else { '#FFFFFF' }
            $TableBorderColor = if ($DiagramTheme -eq 'Black') { '#AAAAAA' } else { '#333333' }
            $DisconnectedColor = '#C0392B'

            $ModuleBase = (Get-Module -Name 'AsBuiltReport.Microsoft.Azure').ModuleBase
            $IconPath = [System.IO.FileInfo](Join-Path $ModuleBase 'Icons')
            $ImagesObj = @{
                'VNet'     = 'virtual-networks.png'
                'Gateway'  = 'virtual-network-gateways.png'
                'Firewall' = 'firewalls.png'
                'Blank'    = 'blank.png'
            }

            $DiagramGraph = & {
                foreach ($VNet in $VNets) {
                    $SafeId = 'VNet_' + ($VNet.Id -replace '[^a-zA-Z0-9]', '_')

                    $RoleBadges = [System.Collections.Generic.List[string]]::new()
                    if ($VNet.HasGateway) { [void]$RoleBadges.Add($LocalizedData.Gateway) }
                    if ($VNet.HasFirewall) { [void]$RoleBadges.Add($LocalizedData.Firewall) }
                    if ($VNet.HasNva) { [void]$RoleBadges.Add($LocalizedData.Nva) }

                    $RoleText = if ($VNet.IsHub -and $RoleBadges.Count -gt 0) {
                        "$($LocalizedData.Hub) ($($RoleBadges -join ', '))"
                    } elseif ($VNet.IsHub) {
                        $LocalizedData.Hub
                    } else {
                        $LocalizedData.Spoke
                    }

                    $NodeInfo = [Ordered]@{
                        $LocalizedData.AddressSpace  = $VNet.AddressSpace
                        $LocalizedData.Subscription  = $VNet.Subscription
                        $LocalizedData.Role          = $RoleText
                    }

                    $IconSize = if ($VNet.IsHub) { 70 } else { 50 }

                    Add-HtmlNodeTable `
                        -Name $SafeId `
                        -ImagesObj $ImagesObj `
                        -inputObject @($VNet.Name) `
                        -iconType 'VNet' `
                        -IconWidth $IconSize `
                        -IconHeight $IconSize `
                        -AditionalInfo $NodeInfo `
                        -FontColor $FontColor `
                        -CellBackgroundColor $CellBgColor `
                        -TableBorderColor $TableBorderColor `
                        -NodeObject
                }

                $DrawnPairs = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($PeeringEdge in $PeeringEdges) {
                    $SourceSafeId = 'VNet_' + ($PeeringEdge.SourceId -replace '[^a-zA-Z0-9]', '_')
                    $TargetSafeId = 'VNet_' + ($PeeringEdge.TargetId -replace '[^a-zA-Z0-9]', '_')
                    $PairKey = (@($SourceSafeId, $TargetSafeId) | Sort-Object) -join '|'
                    if (-not $DrawnPairs.Add($PairKey)) { continue }

                    if ($PeeringEdge.Connected) {
                        Edge $SourceSafeId $TargetSafeId @{ color = $EdgeColor; style = 'solid'; dir = 'both'; label = $LocalizedData.Connected }
                    } else {
                        Edge $SourceSafeId $TargetSafeId @{ color = $DisconnectedColor; style = 'dashed'; dir = 'both'; label = $LocalizedData.Disconnected }
                    }
                }
            }

            $DiagramResult = New-AbrDiagram `
                -InputObject $DiagramGraph `
                -Format base64 `
                -MainDiagramLabel $LocalizedData.DiagramHeading `
                -IconPath $IconPath `
                -ImagesObj $ImagesObj `
                -MainGraphSize '6.5,9' `
                -Dpi $DiagramDpi `
                -DisableMainDiagramLogo
            if ($DiagramResult) {
                Image -Base64 $DiagramResult -Text $LocalizedData.DiagramAltText -Percent $DiagramPercent
                BlankLine
            }
        } catch {
            Write-PScriboMessage -IsWarning $_.Exception.Message
        }
    }
    end {}
}
