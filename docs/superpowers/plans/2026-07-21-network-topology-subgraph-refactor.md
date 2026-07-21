# Network Topology Diagram Subgraph Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix misaligned VNet information inside each Subscription box in the Network Topology diagram by replacing the per-Subscription real Graphviz cluster with a single `Add-HtmlNodeTable -Subgraph` node, per the design in `docs/superpowers/specs/2026-07-21-network-topology-subgraph-refactor-design.md`.

**Architecture:** `Get-AbrDiagAzNetworkTopology.ps1` currently wraps each Subscription's VNet grid in a real `SubGraph` cluster labeled with the subscription name — two independent layout systems (Graphviz cluster box model + HTML table) fighting over alignment. This plan folds the subscription label/icon into the same HTML table as the VNet rows (one atomic node per Subscription, hub or spoke), removes the now-unnecessary `ltail`/`lhead` cluster-clipping on peering edges in favor of direct per-VNet port targeting, and unifies hub rendering with the existing spoke grouping pattern. Region-level clustering (a real multi-node group) is unchanged.

**Tech Stack:** PowerShell, PSGraph (via `AsBuiltReport.Diagram`'s `SubGraph`/`Edge`/`Add-HtmlNodeTable`/`New-AbrDiagram` wrappers), Graphviz DOT output.

## Global Constraints

- Only `AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1` is modified for the diagram logic itself — no other diagram, report, or config file changes (per spec's Out of Scope section).
- Region stays a real `SubGraph` cluster; each Subscription (hub or spoke) becomes one `Add-HtmlNodeTable -Subgraph` node — no per-Subscription real cluster.
- `-Subgraph -SubgraphLabel <Subscription Name> -SubgraphIconType 'Sub' -SubgraphIconWidth 60 -SubgraphIconHeight 60 -SubgraphLabelPos 'top' -SubgraphLabelFontColor $FontColor` on every Subscription node, matching `Get-AbrDiagAzManagementGroup.ps1`'s existing usage of the same feature.
- `$ImagesObj` gains `'Sub' = 'subscriptions.png'` (icon already exists at `AsBuiltReport.Microsoft.Azure/Icons/subscriptions.png`).
- Hubs are unified with the spoke pattern: one node per hub-Subscription, `-MultiIcon` only when that subscription has 2+ hub VNets (matching the existing spoke rule that `-MultiIcon` + array-valued `AditionalInfo` mis-renders on a single element).
- `$ClusterRef` and `ltail`/`lhead` are removed entirely. `$NodeRef` points at the specific VNet's own port: `"<SubId>":"Icon_<VNetName>":s` (hub, `-MultiIcon`) / `"<SubId>":"<VNetName>":s` (hub, single) / `"<SubId>":"Icon_<VNetName>":n` (spoke, `-MultiIcon`) / `"<SubId>":"<VNetName>":n` (spoke, single) — the `:s`/`:n` compass suffix preserves the existing bottom-of-hub / top-of-spoke edge-exit direction now that the port lands on a specific interior cell rather than a whole-node compass point.
- `$HubNodeForCentering` (dead code, never read) is deleted.
- No `Options.*` reads — this file already reads `$Diagram.NetworkTopology.*` (see spec `2026-07-20-per-diagram-config-design.md`); that plumbing is untouched.

---

### Task 1: Dropped — Graphviz-free smoke-test harness abandoned

**Status: abandoned 2026-07-21, not attempted again.** The plan originally called for a synthetic-fixture harness that ran `Get-AbrDiagAzNetworkTopology` with `New-AbrDiagram` shadowed to force `-Format dot`, on the premise that dot-format output needs no Graphviz install. That premise held for the recursion problem (fixed: invoking the real cmdlet via `& (Get-Module AsBuiltReport.Diagram) { New-AbrDiagram @args } @params` — module-scope invocation — avoids the name-based re-dispatch that a global-shadow-plus-`Get-Command`-delegate, or even invoking `.ScriptBlock` directly, both recurse into infinitely) but not for Graphviz itself: this installed PSGraph version (2.1.38.27) `Export-PSGraph` unconditionally shells out to a real `dot.exe` and throws `Could not find GraphViz installed on this system...` even when `-OutputFormat 'dot'` is requested — confirmed by direct reproduction. Since Graphviz isn't installed in this environment, no dot-format harness can run end-to-end here regardless of the recursion fix.

Given that, the user chose to drop the automated harness entirely rather than install Graphviz system-wide (PSGraph's own `Install-GraphViz` helper registers a Chocolatey provider and installs a package — a real system-level change) or hunt for a portable Graphviz binary. Task 2 proceeds directly from the plan's already-fully-specified replacement file (it never depended on the harness to exist — the harness was verification tooling, not an implementation dependency). Task 3 drops the harness-based structural assertions (Steps 1-4 in the original plan) in favor of PSScriptAnalyzer + Pester syntax checks plus the manual visual pass already documented under "Manual Follow-Up" below.

---

### Task 2: Refactor Get-AbrDiagAzNetworkTopology.ps1 to use Add-HtmlNodeTable -Subgraph

**Files:**
- Modify: `AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1` (full-file replacement — the change touches every section of the hub/spoke rendering and edge-construction logic)

**Interfaces:**
- Consumes: `$VNets` (`Id`, `Name`, `Location`, `Subscription`, `AddressSpace`, `IsHub`, `HasGateway`, `HasFirewall`, `HasNva` — per `Get-AbrAzNetworkTopology.ps1`'s `$TopologyVNets` shape), `$PeeringEdges` (`SourceId`, `TargetId`, `State`), the module-scope `$Diagram`, `$reportTranslate`, `$Global:Orientation`, `$IconPath` globals (unchanged from today).
- Produces: same public contract as today — `Get-AbrDiagAzNetworkTopology -VNets <object[]> -PeeringEdges <object[]>` emits a PScribo `Image` (or nothing, on error/empty result). No caller-visible signature change.

- [ ] **Step 1: Replace the full file contents**

```powershell
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
                'Sub'      = 'subscriptions.png'
                'Blank'    = 'blank.png'
            }
            $ColumnSize = if ($Diagram.NetworkTopology.Columns -and [int]$Diagram.NetworkTopology.Columns -gt 0) { [int]$Diagram.NetworkTopology.Columns } else { 3 }

            $DiagramGraph = & {
                # Wrapping in a SubGraph lets us attach $HTMLLegend as a caption (labelloc='b') below the hub/spoke content, explaining the peering-state edge colors now that edges no longer carry an inline text label.
                SubGraph NetworkTopologyLegend -Attributes @{ Label = $HTMLLegend; fontsize = 14; penwidth = 0; labelloc = 'b'; labeljust = 'c' } {
                    $Hubs = @($VNets | Where-Object { $_.IsHub })
                    $Spokes = @($VNets | Where-Object { -not $_.IsHub })

                    # Maps each VNet's resource ID to a port-specific reference into its Subscription's shared HTML table node (Graphviz's "<node>":"<port>":<compass> syntax): a single-VNet Subscription box references the VNet's name-cell port ("<SubId>":"<VNetName>"), a grouped (-MultiIcon) box references that VNet's own icon-cell port ("<SubId>":"Icon_<VNetName>") - each emitted by Add-HtmlNodeTable per element, giving every peering edge a distinct landing point even within a grouped box instead of a generic whole-node compass point. The trailing :s (hub) / :n (spoke) compass keeps edges exiting the bottom of hub boxes and entering the top of spoke boxes, matching the diagram's hub-above/spoke-below layout.
                    $NodeRef = @{}
                    # IDs of VNets whose subscription box sits in row 2+ of its region (position already fully determined by the column-chain invisible edges below). A real hub-to-spoke edge that skips straight to one of these deep boxes gets constraint=false when drawn (below), so it still renders as a visible line but is excluded from dot's rank/order decisions - without this, that edge competes with the column-chain for influence over layout and visibly distorts both the hub's horizontal centering and the edge's own routing.
                    $DeepRowNodeIds = [System.Collections.Generic.HashSet[string]]::new()

                    # Every VNet - hub or spoke - is grouped into a labeled cluster per Region, and further grouped by Subscription within that region. Region clustering stays a real Graphviz SubGraph (it legitimately groups several sibling Subscription nodes); each Subscription is a single Add-HtmlNodeTable -Subgraph node (its own HTML table, not a nested real cluster) - the subscription name and icon become that table's header row via -Subgraph, so Graphviz lays out the whole box (header + VNet grid) as one atomic node instead of a cluster fighting an inner node over alignment.
                    # SubGraph -Attributes Label values are only treated as HTML by PSGraph's Format-Value when they start with "<table" (case-insensitive) - a bare "<b>...</b>" fragment is passed through as a literal, unrendered string - so region labels are wrapped in a minimal single-cell table to qualify.
                    $RegionKey = { if ($_.Location) { $_.Location } else { $LocalizedData.UnknownRegion } }
                    $HubsByRegion = $Hubs | Group-Object -Property $RegionKey
                    $SpokesByRegion = $Spokes | Group-Object -Property $RegionKey
                    $AllRegionNames = @(@($HubsByRegion.Name) + @($SpokesByRegion.Name) | Select-Object -Unique | Sort-Object)

                    foreach ($RegionName in $AllRegionNames) {
                        $SafeRegionId = 'Region_' + ($RegionName -replace '[^a-zA-Z0-9]', '_')
                        $RegionLabel = '<table border="0" cellborder="0"><tr><td><b>{0}</b></td></tr></table>' -f $RegionName
                        SubGraph $SafeRegionId -Attributes @{ Label = $RegionLabel; fontsize = 16; fontcolor = $FontColor; penwidth = 1; labelloc = 't'; labeljust = 'c'; style = 'dashed,rounded'; color = $TableBorderColor } {
                            # Hubs are grouped by Subscription the same way spokes are below: one combined node per hub-Subscription, using -MultiIcon when that subscription has more than one hub VNet.
                            $HubGroup = $HubsByRegion | Where-Object { $_.Name -eq $RegionName }
                            if ($HubGroup) {
                                $HubsBySubscription = @($HubGroup.Group | Group-Object -Property Subscription)
                                foreach ($HubSubscriptionGroup in $HubsBySubscription) {
                                    $SafeHubSubscriptionId = $SafeRegionId + '_Sub_' + ($HubSubscriptionGroup.Name -replace '[^a-zA-Z0-9]', '_') + '_Hub'

                                    if ($HubSubscriptionGroup.Group.Count -eq 1) {
                                        # Add-HtmlNodeTable's -MultiIcon + -AditionalInfo (array-valued) combination mis-renders when there is only a single element - each array is stringified as its .NET type name (e.g. "System.Object[]") instead of its value. A subscription with a single hub is rendered as a simple non-MultiIcon node instead, the same proven way a single spoke is handled below.
                                        $VNet = $HubSubscriptionGroup.Group[0]
                                        $HubLabel = ($VNet.Name -replace '"', '')
                                        $NodeRef[$VNet.Id.ToLower()] = '"{0}":"{1}":s' -f $SafeHubSubscriptionId, $HubLabel

                                        $RoleBadges = [System.Collections.Generic.List[string]]::new()
                                        if ($VNet.HasGateway) { [void]$RoleBadges.Add($LocalizedData.Gateway) }
                                        if ($VNet.HasFirewall) { [void]$RoleBadges.Add($LocalizedData.Firewall) }
                                        if ($VNet.HasNva) { [void]$RoleBadges.Add($LocalizedData.Nva) }
                                        $RoleText = if ($RoleBadges.Count -gt 0) {
                                            "$($LocalizedData.Hub) ($($RoleBadges -join ', '))"
                                        } else {
                                            $LocalizedData.Hub
                                        }

                                        # Subscription is already shown by the node's own -Subgraph header row, so it's not repeated here.
                                        $NodeInfo = [Ordered]@{
                                            $LocalizedData.AddressSpace = $VNet.AddressSpace
                                            $LocalizedData.Role         = $RoleText
                                        }

                                        Add-HtmlNodeTable `
                                            -Name $SafeHubSubscriptionId `
                                            -ImagesObj $ImagesObj `
                                            -inputObject @($HubLabel) `
                                            -iconType 'VNet' `
                                            -IconWidth 70 `
                                            -IconHeight 70 `
                                            -AditionalInfo $NodeInfo `
                                            -FontColor $FontColor `
                                            -CellBackgroundColor $CellBgColor `
                                            -TableBorderColor $TableBorderColor `
                                            -Subgraph `
                                            -SubgraphLabel $HubSubscriptionGroup.Name `
                                            -SubgraphIconType 'Sub' `
                                            -SubgraphIconWidth 60 `
                                            -SubgraphIconHeight 60 `
                                            -SubgraphLabelPos 'top' `
                                            -SubgraphLabelFontColor $FontColor `
                                            -NodeObject
                                    } else {
                                        $HubLabels = [System.Collections.Generic.List[string]]::new()
                                        $HubAddressSpaces = [System.Collections.Generic.List[string]]::new()
                                        $HubRoles = [System.Collections.Generic.List[string]]::new()
                                        foreach ($VNet in $HubSubscriptionGroup.Group) {
                                            $HubLabel = ($VNet.Name -replace '"', '')
                                            [void]$HubLabels.Add($HubLabel)
                                            [void]$HubAddressSpaces.Add($VNet.AddressSpace)

                                            $RoleBadges = [System.Collections.Generic.List[string]]::new()
                                            if ($VNet.HasGateway) { [void]$RoleBadges.Add($LocalizedData.Gateway) }
                                            if ($VNet.HasFirewall) { [void]$RoleBadges.Add($LocalizedData.Firewall) }
                                            if ($VNet.HasNva) { [void]$RoleBadges.Add($LocalizedData.Nva) }
                                            $RoleText = if ($RoleBadges.Count -gt 0) {
                                                "$($LocalizedData.Hub) ($($RoleBadges -join ', '))"
                                            } else {
                                                $LocalizedData.Hub
                                            }
                                            [void]$HubRoles.Add($RoleText)

                                            $NodeRef[$VNet.Id.ToLower()] = '"{0}":"Icon_{1}":s' -f $SafeHubSubscriptionId, $HubLabel
                                        }

                                        $HubInfo = [Ordered]@{
                                            $LocalizedData.AddressSpace = $HubAddressSpaces.ToArray()
                                            $LocalizedData.Role         = $HubRoles.ToArray()
                                        }

                                        Add-HtmlNodeTable `
                                            -Name $SafeHubSubscriptionId `
                                            -ImagesObj $ImagesObj `
                                            -inputObject $HubLabels.ToArray() `
                                            -iconType 'VNet' `
                                            -MultiIcon `
                                            -IconWidth 70 `
                                            -IconHeight 70 `
                                            -ColumnSize $ColumnSize `
                                            -AditionalInfo $HubInfo `
                                            -FontColor $FontColor `
                                            -CellBackgroundColor $CellBgColor `
                                            -TableBorderColor $TableBorderColor `
                                            -Subgraph `
                                            -SubgraphLabel $HubSubscriptionGroup.Name `
                                            -SubgraphIconType 'Sub' `
                                            -SubgraphIconWidth 60 `
                                            -SubgraphIconHeight 60 `
                                            -SubgraphLabelPos 'top' `
                                            -SubgraphLabelFontColor $FontColor `
                                            -NodeObject
                                    }
                                }
                            }

                            $SpokeGroup = $SpokesByRegion | Where-Object { $_.Name -eq $RegionName }
                            if ($SpokeGroup) {
                                $SpokesBySubscription = @($SpokeGroup.Group | Group-Object -Property Subscription)
                                # $ColumnSize also caps how many subscription boxes appear per row within a region. Graphviz has no built-in "wrap N boxes per row" primitive, so this is forced with invisible edges, added after the loop below: every box at array index i is chained to the box at index i+$ColumnSize (its counterpart in the same column position, one row down) with an invisible, minlen=2 edge - not just the first box of each row, which left every other box in that row unconstrained and free to drift back onto the row above. Chaining same-column boxes both pushes each row at least 2 ranks below the previous one (more breathing room than a single rank) and pulls same-column boxes into vertical alignment, since Graphviz's layout keeps directly-connected nodes as close to a straight line as the rest of the graph allows. $SubscriptionRepresentativeNodes is populated inside the loop below (mutating an existing hashtable's contents works via closure regardless of scriptblock scoping, whereas reassigning a plain variable from inside would not).
                                $SubscriptionRepresentativeNodes = @{}
                                for ($SubIndex = 0; $SubIndex -lt $SpokesBySubscription.Count; $SubIndex++) {
                                    $SubscriptionGroup = $SpokesBySubscription[$SubIndex]
                                    $SafeSubscriptionId = $SafeRegionId + '_Sub_' + ($SubscriptionGroup.Name -replace '[^a-zA-Z0-9]', '_')
                                    $SubscriptionRepresentativeNodes[$SubIndex] = '"{0}"' -f $SafeSubscriptionId

                                    if ($SubscriptionGroup.Group.Count -eq 1) {
                                        # Add-HtmlNodeTable's -MultiIcon + -AditionalInfo (array-valued) combination mis-renders when there is only a single element - each array is stringified as its .NET type name (e.g. "System.Object[]") instead of its value. A lone spoke is rendered as a simple non-MultiIcon node instead.
                                        $VNet = $SubscriptionGroup.Group[0]
                                        $SpokeLabel = ($VNet.Name -replace '"', '')
                                        $NodeRef[$VNet.Id.ToLower()] = '"{0}":"{1}":n' -f $SafeSubscriptionId, $SpokeLabel
                                        if ($SubIndex -ge $ColumnSize) { [void]$DeepRowNodeIds.Add($VNet.Id.ToLower()) }
                                        $SpokeNodeInfo = [Ordered]@{
                                            $LocalizedData.AddressSpace = $VNet.AddressSpace
                                            $LocalizedData.Role         = $LocalizedData.Spoke
                                        }
                                        Add-HtmlNodeTable `
                                            -Name $SafeSubscriptionId `
                                            -ImagesObj $ImagesObj `
                                            -inputObject @($SpokeLabel) `
                                            -iconType 'VNet' `
                                            -IconWidth 50 `
                                            -IconHeight 50 `
                                            -AditionalInfo $SpokeNodeInfo `
                                            -FontColor $FontColor `
                                            -CellBackgroundColor $CellBgColor `
                                            -TableBorderColor $TableBorderColor `
                                            -Subgraph `
                                            -SubgraphLabel $SubscriptionGroup.Name `
                                            -SubgraphIconType 'Sub' `
                                            -SubgraphIconWidth 60 `
                                            -SubgraphIconHeight 60 `
                                            -SubgraphLabelPos 'top' `
                                            -SubgraphLabelFontColor $FontColor `
                                            -NodeObject
                                    } else {
                                        $SpokeLabels = [System.Collections.Generic.List[string]]::new()
                                        $SpokeAddressSpaces = [System.Collections.Generic.List[string]]::new()
                                        $SpokeRoles = [System.Collections.Generic.List[string]]::new()
                                        foreach ($VNet in $SubscriptionGroup.Group) {
                                            $SpokeLabel = ($VNet.Name -replace '"', '')
                                            [void]$SpokeLabels.Add($SpokeLabel)
                                            [void]$SpokeAddressSpaces.Add($VNet.AddressSpace)
                                            [void]$SpokeRoles.Add($LocalizedData.Spoke)
                                            $NodeRef[$VNet.Id.ToLower()] = '"{0}":"Icon_{1}":n' -f $SafeSubscriptionId, $SpokeLabel
                                            if ($SubIndex -ge $ColumnSize) { [void]$DeepRowNodeIds.Add($VNet.Id.ToLower()) }
                                        }

                                        # Subscription is already shown by the node's own -Subgraph header row, so it's not repeated per spoke here.
                                        $SpokeInfo = [Ordered]@{
                                            $LocalizedData.AddressSpace = $SpokeAddressSpaces.ToArray()
                                            $LocalizedData.Role         = $SpokeRoles.ToArray()
                                        }

                                        Add-HtmlNodeTable `
                                            -Name $SafeSubscriptionId `
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
                                            -Subgraph `
                                            -SubgraphLabel $SubscriptionGroup.Name `
                                            -SubgraphIconType 'Sub' `
                                            -SubgraphIconWidth 60 `
                                            -SubgraphIconHeight 60 `
                                            -SubgraphLabelPos 'top' `
                                            -SubgraphLabelFontColor $FontColor `
                                            -NodeObject
                                    }
                                }

                                # weight=100 makes Graphviz prioritize straightening this edge far above the real (weight=1, default) hub-to-spoke edges also touching these nodes - without it, minlen alone only constrains rank (vertical) placement, and horizontal (x) position still gets pulled off-column by those competing real edges.
                                for ($SubIndex = 0; $SubIndex + $ColumnSize -lt $SpokesBySubscription.Count; $SubIndex++) {
                                    Edge $SubscriptionRepresentativeNodes[$SubIndex] $SubscriptionRepresentativeNodes[$SubIndex + $ColumnSize] @{ style = 'invis'; minlen = 2; weight = 100 }
                                }
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

                        # A real edge that skips straight to a row 2+ box (whose position is already fully pinned by the column-chain invisible edges) competes with that chain for influence over dot's rank/order decisions, visibly distorting both hub centering and its own routing. constraint=false keeps the line itself but excludes it from those decisions.
                        $Constraint = -not ($DeepRowNodeIds.Contains($PeeringEdge.SourceId.ToLower()) -or $DeepRowNodeIds.Contains($PeeringEdge.TargetId.ToLower()))

                        # Connected: arrow both ends. Initiated: dot (tail) + arrow (head), one side has not yet accepted the peering. Disconnected: dot both ends. Colors follow the standard AsBuiltReport status palette (green/yellow/pink). minlen=2 forces an extra rank of vertical separation between the hub's and spoke's subscription boxes.
                        switch ($PeeringEdge.State) {
                            'Connected' {
                                Edge $SourceRef $TargetRef @{ color = $ConnectedColor; style = 'solid'; dir = 'both'; arrowtail = 'normal'; minlen = 2; constraint = $Constraint }
                            }
                            'Initiated' {
                                Edge $SourceRef $TargetRef @{ color = $InitiatedColor; style = 'dashed'; dir = 'both'; arrowtail = 'dot'; minlen = 2; constraint = $Constraint }
                            }
                            default {
                                Edge $SourceRef $TargetRef @{ color = $DisconnectedColor; style = 'dashed'; dir = 'both'; arrowhead = 'dot'; arrowtail = 'dot'; minlen = 2; constraint = $Constraint }
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
```

- [ ] **Step 2: Verify PowerShell syntax**

```powershell
$Errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Path AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1 -Raw), [ref]$Errors)
$Errors.Count
```

Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1
git commit -m "Refactor Network Topology diagram to use Add-HtmlNodeTable -Subgraph per-Subscription nodes"
```

---

### Task 3: Verify the refactor via lint/syntax checks, and update the changelog

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- None — the Task 1 harness was dropped (see above), so this task relies only on static checks (PSScriptAnalyzer, Pester syntax validation) and the separately-tracked manual visual pass.

- [ ] **Step 1: Run PSScriptAnalyzer**

```powershell
Invoke-ScriptAnalyzer -Path AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1 -Settings .github/workflows/PSScriptAnalyzerSettings.psd1
```

Expected: no output (no findings). If findings appear, fix them before proceeding.

- [ ] **Step 2: Run the existing Pester suite**

```powershell
Invoke-Pester -Path Tests/ -Output Detailed
```

Expected: all tests pass, including `Should have valid PowerShell syntax in all script files` (covers this file generically).

- [ ] **Step 3: Update CHANGELOG.md**

In `CHANGELOG.md`, under `## [0.3.1] - 2026-07-??` → `### Fixed`, add a new bullet after the existing `Get-AbrDiagAzManagementGroup` / `Get-AbrDiagAzNetworkTopology` logo bullet:

```markdown
* Fix `Get-AbrDiagAzNetworkTopology` - Misaligned VNet information within each Subscription box, caused by wrapping a real Graphviz cluster around a separate HTML-table node; each Subscription is now a single `Add-HtmlNodeTable -Subgraph` node (matching `Get-AbrDiagAzManagementGroup`'s existing pattern), and peering edges now attach to each VNet's own port instead of the removed cluster boundary
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "Verify Network Topology diagram Subgraph refactor and document the fix"
```

---

## Manual Follow-Up (not part of this plan's automated steps)

Per the design spec's Testing section, do one real visual pass before merging: run `New-AsBuiltReport` against a tenant with multiple regions, multiple Subscriptions per region, and at least one Subscription with 2+ spokes and one with 2+ hubs, and visually confirm Subscription box alignment and correct peering-edge endpoints in the rendered HTML/Word output. This requires Azure credentials and a Graphviz installation, neither of which are assumed to be available in every environment that executes this plan.
