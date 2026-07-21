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
            # PScribo's Image -Percent scales off raw pixel count assuming a fixed 96 DPI baseline, so a higher render DPI must be offset by a proportionally lower Percent to keep the printed size on the page the same while still gaining pixel density.
            $DiagramPercent = [Math]::Max(1, [Math]::Round(9600 / $DiagramDpi))
            $FontColor = if ($DiagramTheme -eq 'Black') { '#FFFFFF' } else { '#000000' }
            $CellBgColor = if ($DiagramTheme -eq 'Black') { '#2D2D2D' } else { '#FFFFFF' }
            $TableBorderColor = if ($DiagramTheme -eq 'Black') { '#AAAAAA' } else { '#333333' }
            # $Global:Orientation is set by New-AsBuiltReport (Core); swap the graph's max bounding box to match the page's own portrait/landscape flip.
            $MainGraphSize = if ($Global:Orientation -eq 'Landscape') { '9,6.5' } else { '6.5,9' }
            # Standard AsBuiltReport status palette (green/yellow/pink) used for peering state.
            $ConnectedColor = '#DFF0D0'
            $InitiatedColor = '#FFF3C4'
            $DisconnectedColor = '#FECDD1'

            # Legend explaining what each peering-state edge color means, since the edges themselves no longer carry an inline text label.
            $LegendStates = @(
                @{ Color = $ConnectedColor; Text = $LocalizedData.Connected }
                @{ Color = $InitiatedColor; Text = $LocalizedData.Initiated }
                @{ Color = $DisconnectedColor; Text = $LocalizedData.Disconnected }
            )
            $LegendCells = ($LegendStates | ForEach-Object {
                    '<td><font color="{0}">&#9632;</font> <font color="{1}"><b>{2}</b></font></td>' -f $_.Color, $FontColor, $_.Text
                }) -join ''
            $HTMLLegend = '<table border="0" cellborder="0" cellspacing="16"><tr>{0}</tr></table>' -f $LegendCells

            # $IconPath is computed once in Invoke-AsBuiltReport.Microsoft.Azure.ps1 and inherited here
            $ImagesObj = @{
                'VNet'     = 'virtual-networks.png'
                'Gateway'  = 'virtual-network-gateways.png'
                'Firewall' = 'firewalls.png'
                'Blank'    = 'blank.png'
            }
            $ColumnSize = if ($Diagram.NetworkTopology.Columns -and [int]$Diagram.NetworkTopology.Columns -gt 0) { [int]$Diagram.NetworkTopology.Columns } else { 3 }

            $DiagramGraph = & {
                # Wrapping in a SubGraph lets us attach $HTMLLegend as a caption (labelloc='b') below the hub/spoke content, explaining the peering-state edge colors now that edges no longer carry an inline text label.
                SubGraph NetworkTopologyLegend -Attributes @{ Label = $HTMLLegend; fontsize = 14; penwidth = 0; labelloc = 'b'; labeljust = 'c' } {
                    $Hubs = @($VNets | Where-Object { $_.IsHub })
                    $Spokes = @($VNets | Where-Object { -not $_.IsHub })

                    # Maps each VNet's resource ID to how it should be referenced from an Edge call, using Graphviz's <node>:<compass> syntax: hubs are referenced via "<SafeId>":s (bottom of the hub node) and spokes via "<GridId>":n / "<SafeId>":n (top-center of the whole node - the grid node as a whole for grouped spokes, not a specific spoke's icon within it, so every spoke sharing a grid converges on the same top-center point rather than landing above its own icon's column). The reference is pre-quoted on both sides so PSGraph's Format-Value passes it through unchanged rather than trying to re-quote it.
                    $NodeRef = @{}
                    # Maps each VNet's resource ID to its enclosing Subscription cluster's DOT identifier (PSGraph's SubGraph prefixes every name with "cluster"). Combined with $MainGraphAttributes.compound=true (set by New-AbrDiagram), an edge's ltail/lhead can reference these to clip the rendered line to the cluster's box boundary - the bottom of the hub's box, the top of the spoke's box - instead of drawing all the way to the inner node.
                    $ClusterRef = @{}
                    # IDs of VNets whose subscription box sits in row 2+ of its region (position already fully determined by the column-chain invisible edges below). A real hub-to-spoke edge that skips straight to one of these deep boxes gets constraint=false when drawn (below), so it still renders as a visible line but is excluded from dot's rank/order decisions - without this, that edge competes with the column-chain for influence over layout and visibly distorts both the hub's horizontal centering and the edge's own routing.
                    $DeepRowNodeIds = [System.Collections.Generic.HashSet[string]]::new()

                    # Every VNet - hub or spoke - is grouped into a labeled cluster per Region, and spokes get a further labeled cluster per Subscription within that region (mirroring how Diagrammer.Microsoft.AD's replication diagram clusters DCs by Site). This keeps a hub visually inside its own region's outline alongside any spokes that share that region, instead of the hub floating outside all region clusters. Each (Region, Subscription) pair still gets its own compact $ColumnSize-wide icon grid rather than one full-detail node per spoke.
                    # SubGraph -Attributes Label values are only treated as HTML by PSGraph's Format-Value when they start with "<table" (case-insensitive) - a bare "<b>...</b>" fragment is passed through as a literal, unrendered string - so region/subscription labels are wrapped in a minimal single-cell table to qualify.
                    $RegionKey = { if ($_.Location) { $_.Location } else { $LocalizedData.UnknownRegion } }
                    $HubsByRegion = $Hubs | Group-Object -Property $RegionKey
                    $SpokesByRegion = $Spokes | Group-Object -Property $RegionKey
                    $AllRegionNames = @(@($HubsByRegion.Name) + @($SpokesByRegion.Name) | Select-Object -Unique | Sort-Object)

                    foreach ($RegionName in $AllRegionNames) {
                        $SafeRegionId = 'Region_' + ($RegionName -replace '[^a-zA-Z0-9]', '_')
                        $RegionLabel = '<table border="0" cellborder="0"><tr><td><b>{0}</b></td></tr></table>' -f $RegionName
                        SubGraph $SafeRegionId -Attributes @{ Label = $RegionLabel; fontsize = 16; fontcolor = $FontColor; penwidth = 1; labelloc = 't'; labeljust = 'c'; style = 'dashed,rounded'; color = $TableBorderColor } {
                            # Hubs get their own Subscription-labeled cluster too, the same way spokes do, instead of sitting directly in the region box unlabeled by subscription.
                            $HubGroup = $HubsByRegion | Where-Object { $_.Name -eq $RegionName }
                            $HubNodeForCentering = @{}
                            foreach ($VNet in $HubGroup.Group) {
                                $SafeHubSubscriptionId = $SafeRegionId + '_Sub_' + ($VNet.Subscription -replace '[^a-zA-Z0-9]', '_') + '_Hub'
                                $HubSubscriptionLabel = '<table border="0" cellborder="0"><tr><td><b>{0}</b></td></tr></table>' -f $VNet.Subscription
                                SubGraph $SafeHubSubscriptionId -Attributes @{ Label = $HubSubscriptionLabel; fontsize = 14; fontcolor = $FontColor; penwidth = 1; labelloc = 't'; labeljust = 'c'; style = 'dashed,rounded'; color = $TableBorderColor } {
                                    $SafeId = 'VNet_' + ($VNet.Id -replace '[^a-zA-Z0-9]', '_')
                                    $NodeRef[$VNet.Id.ToLower()] = '"{0}":s' -f $SafeId
                                    $ClusterRef[$VNet.Id.ToLower()] = 'cluster' + $SafeHubSubscriptionId
                                    $HubNodeForCentering[0] = '"{0}"' -f $SafeId

                                    $RoleBadges = [System.Collections.Generic.List[string]]::new()
                                    if ($VNet.HasGateway) { [void]$RoleBadges.Add($LocalizedData.Gateway) }
                                    if ($VNet.HasFirewall) { [void]$RoleBadges.Add($LocalizedData.Firewall) }
                                    if ($VNet.HasNva) { [void]$RoleBadges.Add($LocalizedData.Nva) }
                                    $RoleText = if ($RoleBadges.Count -gt 0) {
                                        "$($LocalizedData.Hub) ($($RoleBadges -join ', '))"
                                    } else {
                                        $LocalizedData.Hub
                                    }

                                    # Subscription is already shown by the enclosing cluster's label, so it's not repeated here (matching the spoke convention below).
                                    $NodeInfo = [Ordered]@{
                                        $LocalizedData.AddressSpace = $VNet.AddressSpace
                                        $LocalizedData.Role         = $RoleText
                                    }

                                    Add-HtmlNodeTable `
                                        -Name $SafeId `
                                        -ImagesObj $ImagesObj `
                                        -inputObject @($VNet.Name) `
                                        -iconType 'VNet' `
                                        -IconWidth 70 `
                                        -IconHeight 70 `
                                        -AditionalInfo $NodeInfo `
                                        -FontColor $FontColor `
                                        -CellBackgroundColor $CellBgColor `
                                        -TableBorderColor $TableBorderColor `
                                        -NodeObject
                                }
                            }

                            $SpokeGroup = $SpokesByRegion | Where-Object { $_.Name -eq $RegionName }
                            if ($SpokeGroup) {
                                $SpokesBySubscription = @($SpokeGroup.Group | Group-Object -Property Subscription)
                                # $ColumnSize also caps how many subscription boxes appear per row within a region. Graphviz has no built-in "wrap N boxes per row" primitive for clusters, so this is forced with invisible edges, added after the loop below: every box at array index i is chained to the box at index i+$ColumnSize (its counterpart in the same column position, one row down) with an invisible, minlen=2 edge - not just the first box of each row, which left every other box in that row unconstrained and free to drift back onto the row above. Chaining same-column boxes both pushes each row at least 2 ranks below the previous one (more breathing room than a single rank) and pulls same-column boxes into vertical alignment, since Graphviz's layout keeps directly-connected nodes as close to a straight line as the rest of the graph allows. $SubscriptionRepresentativeNodes is populated inside the SubGraph scriptblock below (the same proven pattern as $NodeRef/$ClusterRef - mutating an existing hashtable's contents works via closure regardless of scriptblock scoping, whereas reassigning a plain variable from inside would not).
                                $SubscriptionRepresentativeNodes = @{}
                                for ($SubIndex = 0; $SubIndex -lt $SpokesBySubscription.Count; $SubIndex++) {
                                    $SubscriptionGroup = $SpokesBySubscription[$SubIndex]
                                    $SafeSubscriptionId = $SafeRegionId + '_Sub_' + ($SubscriptionGroup.Name -replace '[^a-zA-Z0-9]', '_')
                                    $SubscriptionLabel = '<table border="0" cellborder="0"><tr><td><b>{0}</b></td></tr></table>' -f $SubscriptionGroup.Name
                                    SubGraph $SafeSubscriptionId -Attributes @{ Label = $SubscriptionLabel; fontsize = 14; fontcolor = $FontColor; penwidth = 1; labelloc = 't'; labeljust = 'c'; style = 'dashed,rounded'; color = $TableBorderColor } {
                                        if ($SubscriptionGroup.Group.Count -eq 1) {
                                            # Add-HtmlNodeTable's -MultiIcon + -AditionalInfo (array-valued) combination mis-renders when there is only a single element - each array is stringified as its .NET type name (e.g. "System.Object[]") instead of its value. A lone spoke is rendered as a simple non-MultiIcon node instead, the same proven way hub nodes already are, sidestepping that bug entirely.
                                            $VNet = $SubscriptionGroup.Group[0]
                                            $SafeSpokeId = $SafeSubscriptionId + '_' + ($VNet.Id -replace '[^a-zA-Z0-9]', '_')
                                            $NodeRef[$VNet.Id.ToLower()] = '"{0}":n' -f $SafeSpokeId
                                            $ClusterRef[$VNet.Id.ToLower()] = 'cluster' + $SafeSubscriptionId
                                            $SubscriptionRepresentativeNodes[$SubIndex] = '"{0}"' -f $SafeSpokeId
                                            if ($SubIndex -ge $ColumnSize) { [void]$DeepRowNodeIds.Add($VNet.Id.ToLower()) }
                                            $SpokeNodeInfo = [Ordered]@{
                                                $LocalizedData.AddressSpace = $VNet.AddressSpace
                                                $LocalizedData.Role         = $LocalizedData.Spoke
                                            }
                                            Add-HtmlNodeTable `
                                                -Name $SafeSpokeId `
                                                -ImagesObj $ImagesObj `
                                                -inputObject @(($VNet.Name -replace '"', '')) `
                                                -iconType 'VNet' `
                                                -IconWidth 50 `
                                                -IconHeight 50 `
                                                -AditionalInfo $SpokeNodeInfo `
                                                -FontColor $FontColor `
                                                -CellBackgroundColor $CellBgColor `
                                                -TableBorderColor $TableBorderColor `
                                                -NodeObject
                                        } else {
                                            $SpokeGridId = $SafeSubscriptionId + '_Grid'
                                            $SubscriptionRepresentativeNodes[$SubIndex] = '"{0}"' -f $SpokeGridId

                                            $SpokeLabels = [System.Collections.Generic.List[string]]::new()
                                            $SpokeAddressSpaces = [System.Collections.Generic.List[string]]::new()
                                            $SpokeRoles = [System.Collections.Generic.List[string]]::new()
                                            foreach ($VNet in $SubscriptionGroup.Group) {
                                                $SpokeLabel = ($VNet.Name -replace '"', '')
                                                [void]$SpokeLabels.Add($SpokeLabel)
                                                [void]$SpokeAddressSpaces.Add($VNet.AddressSpace)
                                                [void]$SpokeRoles.Add($LocalizedData.Spoke)
                                                # Referencing the grid node's own north point (rather than a specific spoke's "Icon_<label>" port) means every spoke in this group's edges converge on the grid's true top-center, instead of landing above whichever column that spoke's icon happens to sit in.
                                                $NodeRef[$VNet.Id.ToLower()] = '"{0}":n' -f $SpokeGridId
                                                $ClusterRef[$VNet.Id.ToLower()] = 'cluster' + $SafeSubscriptionId
                                                if ($SubIndex -ge $ColumnSize) { [void]$DeepRowNodeIds.Add($VNet.Id.ToLower()) }
                                            }

                                            # Subscription is already shown by the enclosing cluster's label, so it's not repeated per spoke here.
                                            $SpokeInfo = [Ordered]@{
                                                $LocalizedData.AddressSpace = $SpokeAddressSpaces.ToArray()
                                                $LocalizedData.Role         = $SpokeRoles.ToArray()
                                            }

                                            Add-HtmlNodeTable `
                                                -Name $SpokeGridId `
                                                -ImagesObj $ImagesObj `
                                                -inputObject $SpokeLabels.ToArray() `
                                                -iconType 'VNet' `
                                                -MultiIcon `
                                                -IconWidth 50 `
                                                -IconHeight 50 `
                                                -ColumnSize $ColumnSize `
                                                -AditionalInfo $SpokeInfo `
                                                -FontColor $FontColor `
                                                -CellBackgroundColor $CellBgColor `
                                                -TableBorderColor $TableBorderColor `
                                                -NodeObject
                                        }
                                    }
                                }

                                # weight=100 makes Graphviz prioritize straightening this edge far above the real (weight=1, default) hub-to-spoke edges also touching these nodes - without it, minlen alone only constrains rank (vertical) placement, and horizontal (x) position still gets pulled off-column by those competing real edges. (Note: {rank=same} via PSGraph's Rank cmdlet was tried here to force rows together as a hard constraint, but Graphviz's cluster layout algorithm does not support rank=same across nodes in different clusters - it corrupts the render ("was already in a rankset, deleted from cluster") - so row alignment is achieved via minlen/weight tuning alone instead.)
                                for ($SubIndex = 0; $SubIndex + $ColumnSize -lt $SpokesBySubscription.Count; $SubIndex++) {
                                    Edge $SubscriptionRepresentativeNodes[$SubIndex] $SubscriptionRepresentativeNodes[$SubIndex + $ColumnSize] @{ style = 'invis'; minlen = 2; weight = 100 }
                                }

                                # (Experiment: explicit hub-centering edges removed - testing whether the natural, equal-weight real hub-to-spoke edges already center it once the column-chain skew is accounted for.)
                            }
                        }
                    }

                    $DrawnPairs = [System.Collections.Generic.HashSet[string]]::new()
                    foreach ($PeeringEdge in $PeeringEdges) {
                        $SourceRef = $NodeRef[$PeeringEdge.SourceId.ToLower()]
                        $TargetRef = $NodeRef[$PeeringEdge.TargetId.ToLower()]
                        if (-not $SourceRef -or -not $TargetRef) { continue }
                        $PairKey = (@($SourceRef, $TargetRef) | Sort-Object) -join '|'
                        if (-not $DrawnPairs.Add($PairKey)) { continue }

                        $SourceCluster = $ClusterRef[$PeeringEdge.SourceId.ToLower()]
                        $TargetCluster = $ClusterRef[$PeeringEdge.TargetId.ToLower()]
                        # A real edge that skips straight to a row 2+ box (whose position is already fully pinned by the column-chain invisible edges) competes with that chain for influence over dot's rank/order decisions, visibly distorting both hub centering and its own routing. constraint=false keeps the line itself but excludes it from those decisions.
                        $Constraint = -not ($DeepRowNodeIds.Contains($PeeringEdge.SourceId.ToLower()) -or $DeepRowNodeIds.Contains($PeeringEdge.TargetId.ToLower()))

                        # Connected: arrow both ends. Initiated: dot (tail) + arrow (head), one side has not yet accepted the peering. Disconnected: dot both ends. Colors follow the standard AsBuiltReport status palette (green/yellow/pink). minlen=2 forces an extra rank of vertical separation between the hub's and spoke's subscription boxes, so the ltail/lhead cluster-clipped lines above have room to be visible instead of the boxes sitting flush against each other.
                        switch ($PeeringEdge.State) {
                            'Connected' {
                                Edge $SourceRef $TargetRef @{ color = $ConnectedColor; style = 'solid'; dir = 'both'; arrowtail = 'normal'; ltail = $SourceCluster; lhead = $TargetCluster; minlen = 2; constraint = $Constraint }
                            }
                            'Initiated' {
                                Edge $SourceRef $TargetRef @{ color = $InitiatedColor; style = 'dashed'; dir = 'both'; arrowtail = 'dot'; ltail = $SourceCluster; lhead = $TargetCluster; minlen = 2; constraint = $Constraint }
                            }
                            default {
                                Edge $SourceRef $TargetRef @{ color = $DisconnectedColor; style = 'dashed'; dir = 'both'; arrowhead = 'dot'; arrowtail = 'dot'; ltail = $SourceCluster; lhead = $TargetCluster; minlen = 2; constraint = $Constraint }
                            }
                        }
                    }
                }
            }

            $DiagramResult = New-AbrDiagram `
                -InputObject $DiagramGraph `
                -Format base64 `
                -MainDiagramLabel $LocalizedData.DiagramHeading `
                -IconPath $IconPath `
                -ImagesObj $ImagesObj `
                -MainGraphSize $MainGraphSize `
                -Dpi $DiagramDpi `
                -EdgeType 'line' `
                -LogoName 'NoIcon'
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
