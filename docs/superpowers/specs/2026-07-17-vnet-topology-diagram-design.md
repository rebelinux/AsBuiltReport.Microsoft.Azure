# VNet Hub-Spoke Topology Diagram — Design

## Summary

Add a tenant-wide Virtual Network peering topology diagram, rendered once per tenant (alongside the existing Management Group diagram), showing hub and spoke VNets across all subscriptions with their peering relationships. Uses the existing `AsBuiltReport.Diagram` module and follows the conventions already established by `Get-AbrDiagAzManagementGroup.ps1`.

## Motivation

Only one dynamic, data-driven topology diagram exists in the module today (Management Group hierarchy). VNet peering data is already collected (`Get-AbrAzVirtualNetworkPeering.ps1`) but only presented as a flat table, which does not communicate hub-spoke topology — the single most common diagram requested in Azure network as-built documentation. Real hub-spoke deployments span multiple subscriptions (hub in a connectivity subscription, spokes in landing zone subscriptions), which the current per-subscription report loop cannot represent in one place.

## Architecture

Three new functions, following the existing MG diagram split between orchestration (`Src/Private/Report/`) and diagram builder (`Src/Private/Diagram/`):

- `Src/Private/Report/Get-AbrAzNetworkTopology.ps1` — orchestration/section function, mirrors `Get-AbrAzManagementGroup.ps1`
- `Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1` — diagram builder, mirrors `Get-AbrDiagAzManagementGroup.ps1`
- `Src/Private/Report/Test-AbrAzNvaVm.ps1` — new shared helper extracted from `Get-AbrAzNetworkVirtualAppliance.ps1`'s existing inline NVA detection (see "Refactor: shared NVA detection" below)

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

**Important:** `ManagementGroup` is called directly here — it is *not* a member of `Options.SectionOrder` and is not routed through the `ResourceTypeMap`/`SectionOrder` dispatch loop that governs per-subscription sections (that dispatch only exists inside the `foreach ($AzSubscription in $AzSubscriptions)` loop). `Get-AbrAzNetworkTopology` follows the same tenant-level, directly-called pattern as `Get-AbrAzManagementGroup` — it must **not** be added to `SectionOrder`, since that array has no effect at this point in the report flow.

The existing per-subscription `Get-AbrAzVirtualNetwork` / `Get-AbrAzVirtualNetworkPeering` sections are unchanged — they keep rendering their tables inside each subscription's section. This diagram is additive, not a replacement.

## InfoLevel dependencies on other sections

Because `Get-AbrAzNetworkTopology` runs once, outside the per-subscription loop, it cannot reuse data already fetched by other private functions (those run later, per-subscription, in a different Az context). Its pre-pass makes its own direct Azure API calls — which means it can easily end up making calls a user has deliberately disabled elsewhere. This must be avoided:

| Data needed | Only collected if | Rationale |
|---|---|---|
| VNets + peerings (core diagram data) | `InfoLevel.VirtualNetwork -ge 2` | `Get-AbrAzVirtualNetwork.ps1:102-119` only calls `Get-AbrAzVirtualNetworkPeering` at level 2+ — peering detail is not considered "enabled" below that threshold today, and the diagram *is* peering detail. |
| Gateway hub badge | `InfoLevel.VirtualNetworkGateway -ge 1` | Matches `Get-AbrAzVirtualNetworkGateway.ps1:28`'s own gate. |
| Azure Firewall hub badge | `InfoLevel.Firewall -ge 1` | Matches `Get-AbrAzFirewall.ps1`'s own gate. |
| NVA hub badge | `InfoLevel.NetworkVirtualAppliance -ge 1` | Matches `Get-AbrAzNetworkVirtualAppliance.ps1`'s own gate. |

Overall section gate: `InfoLevel.NetworkTopology -ge 1 -and InfoLevel.VirtualNetwork -ge 2` (both required — an independent `NetworkTopology` toggle lets a user disable just the diagram while keeping per-subscription VNet tables, but the diagram cannot render with no underlying VNet/peering data, so it cannot be enabled independently of `VirtualNetwork`).

Each of the three badge cross-references (`Get-AzVirtualNetworkGateway`, `Get-AzFirewall`, `Get-AzVirtualMachine`+`Test-AbrAzNvaVm`) is skipped entirely — no API call made — when its corresponding `InfoLevel` is below threshold. If a VNet would only have qualified as a hub via a skipped criterion (and doesn't meet the 3+ peering threshold or any other enabled criterion), it renders as a spoke instead, with no error or warning — this is expected degradation, not a failure. The diagram's `SectionInfo` paragraph should note that hub badges reflect only currently-enabled sections, so a reader isn't confused by a hub with no visible reason for being one.

## Data collection

`Get-AbrAzNetworkTopology.ps1` performs a cross-subscription pre-pass, following the same pattern already used by `Get-AbrAzNetworkVirtualAppliance.ps1` for its UDR/load-balancer cross-referencing:

For each subscription in `$AzSubscriptions` (respecting `Filter.Subscription`), only entered at all if the overall section gate (`InfoLevel.NetworkTopology -ge 1 -and InfoLevel.VirtualNetwork -ge 2`) passes:
1. `Set-AzContext` to that subscription
2. `Get-AzVirtualNetwork` — collect `Id`, `Name`, `ResourceGroupName`, `AddressSpace.AddressPrefixes`, subscription name
3. `Get-AzVirtualNetworkPeering` (per VNet) — collect `RemoteVirtualNetwork.Id`, `PeeringState`
4. **Only if `InfoLevel.VirtualNetworkGateway -ge 1`:** `Get-AzVirtualNetworkGateway` — collect `IpConfigurations[0].Subnet.Id`, parsed the same way `Get-AbrAzVirtualNetworkGateway.ps1` already does, to determine which VNet hosts a gateway
5. **Only if `InfoLevel.Firewall -ge 1`:** `Get-AzFirewall` — collect `IpConfigurations[0].Subnet.Id` similarly, to determine which VNet hosts a firewall
6. **Only if `InfoLevel.NetworkVirtualAppliance -ge 1`:** `Get-AzVirtualMachine` — for each VM, resolve its primary NIC's `Subnet.Id` (same parsing `Get-AbrAzNetworkVirtualAppliance.ps1:97-99` already does) and pass the VM through the new `Test-AbrAzNvaVm` helper to determine which VNet hosts an NVA

See "InfoLevel dependencies on other sections" above for the full rationale. All data is collected into an in-memory list before any PScribo output, consistent with the module's coding standards.

## Refactor: shared NVA detection

`Get-AbrAzNetworkVirtualAppliance.ps1` currently determines "is this VM an NVA" inline (lines 33-81): a `$DefaultNvaPublishers` list, resolution of `Options.NvaPublishers`/`Options.NvaTag`, and `$IsNvaByImg`/`$IsNvaByTag` matching against `$AzVm.StorageProfile.ImageReference.Publisher` and `$AzVm.Tags`. The new Network Topology diagram needs the identical check to flag NVA-fronted hubs. Rather than duplicate this logic (which would silently drift if a user sets `Options.NvaPublishers`/`NvaTag` and only one of the two call sites honored it), extract it into:

```
Src/Private/Report/Test-AbrAzNvaVm.ps1
```

Signature: `Test-AbrAzNvaVm -VM <PSVirtualMachine> -NvaPublishers <string[]> -NvaTagKey <string> -NvaTagValue <string>` → returns `$true`/`$false` (or an object with `IsNva`/`DetectionMethod` if `Get-AbrAzNetworkVirtualAppliance.ps1`'s existing `DetectedByPublisher`/tag-identified messaging needs to keep working — to be confirmed during implementation against the exact return shape the existing caller needs).

`Get-AbrAzNetworkVirtualAppliance.ps1` is updated to call this helper instead of its inline logic (pure refactor, no behavior change). `Get-AbrAzNetworkTopology.ps1` calls the same helper during its pre-pass.

## Filtering & hub detection

1. Build a peering adjacency map keyed by VNet resource ID.
2. **Exclude any VNet with zero peerings.** Isolated/standalone VNets add no topology value and remain fully documented in the existing per-subscription VirtualNetwork table.
3. A VNet is flagged as a **hub** if any of the following is true:
   - It has 3 or more peering connections, OR
   - It hosts a Virtual Network Gateway, OR
   - It hosts an Azure Firewall, OR
   - It hosts a VM identified as an NVA by `Test-AbrAzNvaVm` (per `Options.NvaPublishers` / `Options.NvaTag`)
   Everything else is a **spoke**. This is a rendering/emphasis decision only — it does not alter the underlying peering edges, so a topology that is not truly hub-spoke (e.g. a mesh, or an isolated pair) simply renders with no node emphasized differently.

## Diagram construction

Built using `Add-HtmlNodeTable` from `AsBuiltReport.Diagram`, following the exact pattern `Get-AbrDiagAzManagementGroup.ps1` already uses:

- **Hub nodes**: larger icon size (`IconWidth`/`IconHeight` increased relative to spokes), VNet name, address space, subscription name as a subtitle row. Badge icons (`Gateway`, `Firewall`, `NVA`) added to the node table when applicable — a hub can show more than one badge (e.g. an NVA behind a Gateway-connected hub).
- **Spoke nodes**: standard icon size, VNet name, address space, subscription name as a subtitle row.
- **Subscription grouping**: unlike the MG diagram's subscription list (a leaf collection with no further edges, safely collapsed into one shared node table via `Add-HtmlNodeTable -Subgraph`), every VNet needs its own independent node so individual peering edges can connect specific VNet pairs — VNets cannot be collapsed into a shared multi-row table the way MG's subscriptions were. Each VNet is therefore its own separate node (one `Add-HtmlNodeTable -NodeObject` call per VNet, mirroring how each management group itself got its own node), with the subscription name shown as a text subtitle row inside the node (via `Add-HtmlNodeTable`'s existing `AditionalInfo` parameter) rather than a visual bounding box. This avoids introducing untested Graphviz cluster syntax (nested `SubGraph` clusters with cross-cluster edges is a known rough edge in Graphviz rendering, and no existing diagram in this module exercises that pattern).
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
| `Firewall` | `firewalls.png` | badge on hub nodes with an Azure Firewall |
| `NVA` | *(to be sourced — no third-party NVA vendor icon exists in the module today; a generic "network virtual appliance" icon from the Azure Architecture Icons set is expected, not a vendor-specific logo, since `Options.NvaPublishers` can match several vendors)* | badge on hub nodes with an NVA (Palo Alto, Fortinet, Cisco, etc. — detected via `Test-AbrAzNvaVm`) |

`virtual-wan-hub.png` has already been sourced and may be added to the module's `Icons/` folder now, but **Virtual WAN Hub topology is explicitly out of scope for this feature**. See "Future considerations" below.

## Integration

- New `InfoLevel.NetworkTopology` key added to `AsBuiltReport.Microsoft.Azure.json`, `README.md`, and all 5 language files. Default value matches the existing `VirtualNetwork` InfoLevel default. Effective only in combination with `InfoLevel.VirtualNetwork -ge 2` (see "InfoLevel dependencies on other sections" above) — this combination should be documented explicitly in `README.md`, not left implicit.
- **Not** added to `Options.SectionOrder` — called directly alongside `Get-AbrAzManagementGroup`, matching that function's placement outside the `SectionOrder`/`ResourceTypeMap` dispatch (see "Report flow placement" above).
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
- Mock `Get-AzVirtualNetwork`, `Get-AzVirtualNetworkPeering`, `Get-AzVirtualNetworkGateway`, `Get-AzFirewall`, `Get-AzVirtualMachine` across two or three fake subscriptions
- Verify hub detection logic (peering-count threshold, gateway presence, Azure Firewall presence, NVA presence via publisher match and via `NvaTag` fallback)
- Verify connected vs. disconnected edge styling
- Verify isolated (zero-peering) VNets are excluded
- Verify graceful no-op when `Options.EnableDiagrams` is `$false`
- Verify graceful no-op when no VNet anywhere has a peering
- `Test-AbrAzNvaVm` gets its own dedicated unit tests (publisher match, tag-key-only match, tag-key+value match, no match)
- Regression test confirming `Get-AbrAzNetworkVirtualAppliance.ps1`'s existing NVA-detection test coverage still passes unchanged after the refactor to call `Test-AbrAzNvaVm`
- Verify `Get-AzVirtualNetworkGateway`/`Get-AzFirewall`/`Get-AzVirtualMachine` are **not called** when their respective `InfoLevel` is 0 (asserting `Should -Invoke ... -Times 0`), and that hub detection degrades to spoke (or another still-enabled criterion) in that case
- Verify the whole section is skipped when `InfoLevel.VirtualNetwork -lt 2`, even if `InfoLevel.NetworkTopology -ge 1`

## Out of scope / Future considerations

- **Virtual WAN Hub topology.** Virtual WAN uses a fundamentally different connectivity model (hub-and-spoke via Microsoft-managed virtual hubs, hub-to-hub connections, and VPN/ExpressRoute/User VPN gateways attached to the hub rather than peering). Representing it correctly is a separate diagram/data-collection effort, not a variant of VNet peering. The `virtual-wan-hub.png` icon may be added to the `Icons/` folder as prep, but no Virtual WAN data collection or rendering logic is part of this feature. A follow-up design should scope this separately once this diagram has shipped.
- Nested subnet detail per VNet node (deferred in favor of name + address space only, to keep the diagram readable).
- ExpressRoute/VPN on-premises connectivity shown on the same diagram (flagged separately in the original sections analysis as its own candidate).
