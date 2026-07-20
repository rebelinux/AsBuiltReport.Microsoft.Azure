function Get-AbrAzNetworkTopology {
    <#
    .SYNOPSIS
        Used by As Built Report to retrieve Azure Virtual Network hub-spoke topology information
    .DESCRIPTION
        Documents Virtual Network peering topology across all subscriptions in the tenant,
        identifying hub VNets by peering count, Virtual Network Gateway presence, Azure Firewall
        presence, or Network Virtual Appliance presence, and rendering a hub-spoke diagram plus
        a summary table.
    .NOTES
        Version:        0.1.0
        Author:         Tim Carman
        Twitter:        @tpcarman
        Github:         tpcarman
    .EXAMPLE

    .LINK

    #>
    [CmdletBinding()]
    param ()

    begin {
        $LocalizedData = $reportTranslate.GetAbrAzNetworkTopology
        Write-PScriboMessage ($LocalizedData.InfoLevel -f $InfoLevel.NetworkTopology)
    }

    process {
        if ($InfoLevel.NetworkTopology -ge 1) {
            try {
                Write-PScriboMessage $LocalizedData.Collecting

                #region --- Cross-subscription pre-pass ---
                $AllVNets = [System.Collections.Generic.List[object]]::new()
                $VNetsWithGateway = [System.Collections.Generic.HashSet[string]]::new()
                $VNetsWithFirewall = [System.Collections.Generic.HashSet[string]]::new()
                $VNetsWithNva = [System.Collections.Generic.HashSet[string]]::new()
                $PeeringEdgeMap = [System.Collections.Generic.Dictionary[string, object]]::new()

                foreach ($TopologySubscription in $AzSubscriptions) {
                    try {
                        $null = Set-AzContext -Subscription $TopologySubscription.Id -Tenant $TenantId -ErrorAction Stop
                        $SubVNets = Get-AzVirtualNetwork -ErrorAction Stop
                    } catch {
                        Write-PScriboMessage -IsWarning ($LocalizedData.SubscriptionError -f $TopologySubscription.Name, $_.Exception.Message)
                        continue
                    }

                    foreach ($VNet in $SubVNets) {
                        try {
                            $Peerings = Get-AzVirtualNetworkPeering -VirtualNetworkName $VNet.Name -ResourceGroupName $VNet.ResourceGroupName -ErrorAction Stop
                        } catch {
                            $Peerings = @()
                        }

                        foreach ($Peering in $Peerings) {
                            if (-not $Peering.RemoteVirtualNetwork.Id) { continue }
                            $EdgeKey = (@($VNet.Id.ToLower(), $Peering.RemoteVirtualNetwork.Id.ToLower()) | Sort-Object) -join '|'
                            $IsConnected = $Peering.PeeringState -eq 'Connected'
                            if ($PeeringEdgeMap.ContainsKey($EdgeKey)) {
                                # If either side reports a non-Connected state, treat the whole edge as disconnected.
                                $PeeringEdgeMap[$EdgeKey].Connected = ($PeeringEdgeMap[$EdgeKey].Connected -and $IsConnected)
                            } else {
                                $PeeringEdgeMap[$EdgeKey] = [PSCustomObject]@{
                                    SourceId  = $VNet.Id
                                    TargetId  = $Peering.RemoteVirtualNetwork.Id
                                    Connected = $IsConnected
                                }
                            }
                        }

                        $AllVNets.Add([PSCustomObject]@{
                                Id             = $VNet.Id
                                Name           = $VNet.Name
                                ResourceGroup  = $VNet.ResourceGroupName
                                Location       = $AzLocationLookup."$($VNet.Location)"
                                Subscription   = $TopologySubscription.Name
                                SubscriptionId = $TopologySubscription.Id
                                AddressSpace   = ($VNet.AddressSpace.AddressPrefixes -join ', ')
                            })
                    }

                    try {
                        # Get-AzVirtualNetworkGateway requires -ResourceGroupName in every parameter
                        # set (no subscription-wide listing), so enumerate via Get-AzResource first,
                        # same pattern used in Get-AbrAzVirtualNetworkGateway.ps1.
                        $Gateways = Get-AzResource -ResourceType 'Microsoft.Network/virtualNetworkGateways' -ErrorAction Stop |
                            ForEach-Object { Get-AzVirtualNetworkGateway -Name $_.Name -ResourceGroupName $_.ResourceGroupName -ErrorAction Stop }
                    } catch {
                        $Gateways = @()
                    }
                    foreach ($Gateway in $Gateways) {
                        $GwVNetId = Resolve-AbrVNetIdFromSubnetId -SubnetId $Gateway.IpConfigurations[0].Subnet.Id
                        if ($GwVNetId) { [void]$VNetsWithGateway.Add($GwVNetId.ToLower()) }
                    }

                    try {
                        $Firewalls = Get-AzFirewall -ErrorAction Stop
                    } catch {
                        $Firewalls = @()
                    }
                    foreach ($Fw in $Firewalls) {
                        $FwIpConfig = $Fw.IpConfigurations | Where-Object { $null -ne $_.PrivateIPAddress } | Select-Object -First 1
                        $FwVNetId = Resolve-AbrVNetIdFromSubnetId -SubnetId $FwIpConfig.Subnet.Id
                        if ($FwVNetId) { [void]$VNetsWithFirewall.Add($FwVNetId.ToLower()) }
                    }

                    try {
                        $SubVms = Get-AzVM -ErrorAction Stop
                    } catch {
                        $SubVms = @()
                    }
                    foreach ($SubVm in $SubVms) {
                        $NvaCheck = Test-AbrAzNvaVm -VM $SubVm -NvaPublishers $Options.NvaPublishers -NvaTag $Options.NvaTag
                        if (-not $NvaCheck.IsNva) { continue }

                        $PrimaryNicId = ($SubVm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary } | Select-Object -First 1).Id
                        if (-not $PrimaryNicId) { $PrimaryNicId = $SubVm.NetworkProfile.NetworkInterfaces[0].Id }
                        $PrimaryNic = Get-AzNetworkInterface -Name $PrimaryNicId.Split('/')[-1] -ResourceGroupName $PrimaryNicId.Split('/')[4] -ErrorAction SilentlyContinue
                        $NvaVNetId = Resolve-AbrVNetIdFromSubnetId -SubnetId $PrimaryNic.IpConfigurations[0].Subnet.Id
                        if ($NvaVNetId) { [void]$VNetsWithNva.Add($NvaVNetId.ToLower()) }
                    }
                }
                #endregion

                #region --- Build peer counts, filter isolated VNets, flag hubs ---
                $VNetById = @{}
                foreach ($VNet in $AllVNets) { $VNetById[$VNet.Id.ToLower()] = $VNet }

                $PeerCountById = @{}
                $IncludedEdges = [System.Collections.Generic.List[object]]::new()
                foreach ($PeeringEdge in $PeeringEdgeMap.Values) {
                    $SourceKey = $PeeringEdge.SourceId.ToLower()
                    $TargetKey = $PeeringEdge.TargetId.ToLower()
                    # Only draw/count edges where both ends were actually collected (in scope of
                    # Filter.Subscription); an edge to an out-of-scope VNet is silently dropped.
                    if (-not ($VNetById.ContainsKey($SourceKey) -and $VNetById.ContainsKey($TargetKey))) { continue }

                    $PeerCountById[$SourceKey] = 1 + [int]($PeerCountById[$SourceKey])
                    $PeerCountById[$TargetKey] = 1 + [int]($PeerCountById[$TargetKey])
                    $IncludedEdges.Add($PeeringEdge)
                }

                $TopologyVNets = [System.Collections.Generic.List[object]]::new()
                foreach ($VNet in $AllVNets) {
                    $VNetKey = $VNet.Id.ToLower()
                    $PeerCount = [int]$PeerCountById[$VNetKey]
                    if ($PeerCount -eq 0) { continue }

                    $HasGateway = $VNetsWithGateway.Contains($VNetKey)
                    $HasFirewall = $VNetsWithFirewall.Contains($VNetKey)
                    $HasNva = $VNetsWithNva.Contains($VNetKey)
                    $IsHub = ($PeerCount -ge 3) -or $HasGateway -or $HasFirewall -or $HasNva

                    $TopologyVNets.Add([PSCustomObject]@{
                            Id             = $VNet.Id
                            Name           = $VNet.Name
                            ResourceGroup  = $VNet.ResourceGroup
                            Location       = $VNet.Location
                            Subscription   = $VNet.Subscription
                            SubscriptionId = $VNet.SubscriptionId
                            AddressSpace   = $VNet.AddressSpace
                            IsHub          = $IsHub
                            HasGateway     = $HasGateway
                            HasFirewall    = $HasFirewall
                            HasNva         = $HasNva
                            PeerCount      = $PeerCount
                        })
                }
                #endregion

                if ($TopologyVNets.Count -eq 0) {
                    Write-PScriboMessage $LocalizedData.NoPeeredVNets
                } else {
                    Section -Style Heading2 $LocalizedData.Heading {
                        if ($Options.ShowSectionInfo) {
                            Paragraph $LocalizedData.SectionInfo
                            BlankLine
                        }

                        if ($Diagram.NetworkTopology.Enabled) {
                            try {
                                Get-AbrDiagAzNetworkTopology -VNets $TopologyVNets -PeeringEdges $IncludedEdges
                            } catch {
                                Write-PScriboMessage -IsWarning ($LocalizedData.DiagramError -f $_.Exception.Message)
                            }
                        }

                        $OutObj = foreach ($VNet in ($TopologyVNets | Sort-Object Subscription, Name)) {
                            [PSCustomObject][Ordered]@{
                                $LocalizedData.Name          = $VNet.Name
                                $LocalizedData.ResourceGroup = $VNet.ResourceGroup
                                $LocalizedData.Subscription  = $VNet.Subscription
                                $LocalizedData.Location      = $VNet.Location
                                $LocalizedData.AddressSpace  = $VNet.AddressSpace
                                $LocalizedData.Role          = if ($VNet.IsHub) { $LocalizedData.Hub } else { $LocalizedData.Spoke }
                                $LocalizedData.PeerCount     = $VNet.PeerCount
                            }
                        }
                        $TableParams = @{
                            Name         = $LocalizedData.TableHeading
                            List         = $false
                            ColumnWidths = 18, 15, 15, 12, 20, 10, 10
                        }
                        if ($Report.ShowTableCaptions) {
                            $TableParams['Caption'] = "- $($TableParams.Name)"
                        }
                        $OutObj | Table @TableParams
                    }
                }
            } catch {
                Write-PScriboMessage -IsWarning "$($LocalizedData.ErrorMessage) $($_.Exception.Message)"
            }
        }
    }

    end {}
}
