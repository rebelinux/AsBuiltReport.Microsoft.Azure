# VNet Hub-Spoke Topology Diagram — Design

## Summary

Add a tenant-wide Virtual Network peering topology diagram, rendered once per tenant (alongside the existing Management Group diagram), showing hub and spoke VNets across all subscriptions with their peering relationships. Uses the existing `AsBuiltReport.Diagram` module and follows the conventions already established by `Get-AbrDiagAzManagementGroup.ps1`.

## Motivation

Only one dynamic, data-driven topology diagram exists in the module today (Management Group hierarchy). VNet peering data is already collected (`Get-AbrAzVirtualNetworkPeering.ps1`) but only presented as a flat table, which does not communicate hub-spoke topology — the single most common diagram requested in Azure network as-built documentation. Real hub-spoke deployments span multiple subscriptions (hub in a connectivity subscription, spokes in landing zone subscriptions), which the current per-subscription report loop cannot represent in one place.

## Architecture

Two new functions, following the existing MG diagram split between orchestration (`Src/Private/Report/`) and diagram builder (`Src/Private/Diagram/`):

- `Src/Private/Report/Get-AbrAzNetworkTopology.ps1` — orchestration/section function, mirrors `Get-AbrAzManagementGroup.ps1`
- `Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1` — diagram builder, mirrors `Get-AbrDiagAzManagementGroup.ps1`

### Report flow placement

Called once per tenant, immediately after `Get-AbrAzManagementGroup` and before the `Subscriptions` section, in `Invoke-AsBuiltReport.Microsoft.Azure.ps1`:

```
Section -Style Heading1 $($AzTenant.Name) {
    Get-AbrAzTenant
    Get-AbrAzManagementGroup
    Get-AbrAzNetworkTopology        # NEW
    Section -Style Heading2 $LocalizedData.Subscriptions {
        ...
    }
}
```

The existing per-subscription `Get-AbrAzVirtualNetwork` / `Get-AbrAzVirtualNetworkPeering` sections are unchanged — they keep rendering their tables inside each subscription's section. This diagram is additive, not a replacement.

## Data collection

`Get-AbrAzNetworkTopology.ps1` performs a cross-subscription pre-pass, following the same pattern already used by `Get-AbrAzNetworkVirtualAppliance.ps1` for its UDR/load-balancer cross-referencing:

For each subscription in `$AzSubscriptions` (respecting `Filter.Subscription`):
1. `Set-AzContext` to that subscription
2. `Get-AzVirtualNetwork` — collect `Id`, `Name`, `ResourceGroupName`, `AddressSpace.AddressPrefixes`, subscription name
3. `Get-AzVirtualNetworkPeering` (per VNet) — collect `RemoteVirtualNetwork.Id`, `PeeringState`
4. `Get-AzVirtualNetworkGateway` — collect `IpConfigurations[0].Subnet.Id`, parsed the same way `Get-AbrAzVirtualNetworkGateway.ps1` already does, to determine which VNet hosts a gateway
5. `Get-AzFirewall` — collect `IpConfigurations[0].Subnet.Id` similarly, to determine which VNet hosts a firewall

All data is collected into an in-memory list before any PScribo output, consistent with the module's coding standards.

## Filtering & hub detection

1. Build a peering adjacency map keyed by VNet resource ID.
2. **Exclude any VNet with zero peerings.** Isolated/standalone VNets add no topology value and remain fully documented in the existing per-subscription VirtualNetwork table.
3. A VNet is flagged as a **hub** if any of the following is true:
   - It has 3 or more peering connections, OR
   - It hosts a Virtual Network Gateway, OR
   - It hosts an Azure Firewall
   Everything else is a **spoke**. This is a rendering/emphasis decision only — it does not alter the underlying peering edges, so a topology that is not truly hub-spoke (e.g. a mesh, or an isolated pair) simply renders with no node emphasized differently.

## Diagram construction

Built using `Add-HtmlNodeTable` from `AsBuiltReport.Diagram`, following the exact pattern `Get-AbrDiagAzManagementGroup.ps1` already uses:

- **Hub nodes**: larger icon size (`IconWidth`/`IconHeight` increased relative to spokes), VNet name, address space, subscription name as a subtitle row. Badge icons (`Gateway`, `Firewall`) added to the node table when applicable.
- **Spoke nodes**: standard icon size, VNet name, address space, subscription name as a subtitle row.
- **Subscription grouping**: spokes belonging to the same subscription are grouped using `Add-HtmlNodeTable -Subgraph`, the same mechanism the MG diagram uses to cluster subscriptions under a management group.
- **Edges**: one `Edge` per peering.
  - `PeeringState -eq 'Connected'` → solid line, default edge color (theme-driven, matching existing `$EdgeColor` logic)
  - Any other state (e.g. `Disconnected`) → dashed line, red (reusing the module's existing HealthCheck failure red)
- Theme (`Options.DiagramTheme`), DPI (`Options.DiagramDpi`), and percent-scaling logic reused verbatim from `Get-AbrDiagAzManagementGroup.ps1`.

### Icons

Sourced by the user from the official Azure Architecture Icons set (same approach as the existing `management-groups.png` / `subscriptions.png`), placed in `AsBuiltReport.Microsoft.Azure/Icons/`:

| Key | Filename | Used for |
|---|---|---|
| `VNet` | `virtual-networks.png` | standard VNet/spoke node, and hub node (rendered larger) |
| `Gateway` | `virtual-network-gateways.png` | badge on hub nodes with a gateway |
| `Firewall` | `firewalls.png` | badge on hub nodes with a firewall |

`virtual-wan-hub.png` has already been sourced and may be added to the module's `Icons/` folder now, but **Virtual WAN Hub topology is explicitly out of scope for this feature**. See "Future considerations" below.

## Integration

- New `InfoLevel.NetworkTopology` key added to `AsBuiltReport.Microsoft.Azure.json`, `README.md`, and all 5 language files. Default value matches the existing `VirtualNetwork` InfoLevel default.
- New `SectionOrder` entry `"NetworkTopology"`, placed immediately after `"ManagementGroup"`.
- Gated by the existing `Options.EnableDiagrams` switch — no new Options key introduced.
- Reuses existing `Options.DiagramTheme` and `Options.DiagramDpi`.
- Wrapped in try/catch with `Write-PScriboMessage -IsWarning`, matching every other diagram/report call — a diagram failure never breaks the report.
- New localized strings added to all 5 language files: `Heading`, `SectionInfo`, `DiagramHeading`, `DiagramAltText`, `DiagramError`, plus any hub/spoke labels used in node text.

## Error handling

- If `Get-AzVirtualNetwork` or `Get-AzVirtualNetworkPeering` fails for a given subscription during the pre-pass, that subscription's VNets are skipped with a `Write-PScriboMessage -IsWarning`, not a hard failure — consistent with the module's graceful-degradation convention.
- If zero VNets have any peerings tenant-wide, the section (and diagram) is skipped entirely — no empty heading rendered, matching the pattern already used elsewhere in the module for empty sections.
- If diagram rendering itself fails (e.g. Graphviz error), the surrounding try/catch logs a warning and the report continues without the diagram, exactly as `Get-AbrAzManagementGroup.ps1` already handles `Get-AbrDiagAzManagementGroup` failures.

## Testing

New Pester tests, following the pattern used for the v0.3.0 section backfill (`7f63ba6`):
- Mock `Get-AzVirtualNetwork`, `Get-AzVirtualNetworkPeering`, `Get-AzVirtualNetworkGateway`, `Get-AzFirewall` across two or three fake subscriptions
- Verify hub detection logic (peering-count threshold, gateway presence, firewall presence)
- Verify connected vs. disconnected edge styling
- Verify isolated (zero-peering) VNets are excluded
- Verify graceful no-op when `Options.EnableDiagrams` is `$false`
- Verify graceful no-op when no VNet anywhere has a peering

## Out of scope / Future considerations

- **Virtual WAN Hub topology.** Virtual WAN uses a fundamentally different connectivity model (hub-and-spoke via Microsoft-managed virtual hubs, hub-to-hub connections, and VPN/ExpressRoute/User VPN gateways attached to the hub rather than peering). Representing it correctly is a separate diagram/data-collection effort, not a variant of VNet peering. The `virtual-wan-hub.png` icon may be added to the `Icons/` folder as prep, but no Virtual WAN data collection or rendering logic is part of this feature. A follow-up design should scope this separately once this diagram has shipped.
- Nested subnet detail per VNet node (deferred in favor of name + address space only, to keep the diagram readable).
- ExpressRoute/VPN on-premises connectivity shown on the same diagram (flagged separately in the original sections analysis as its own candidate).
