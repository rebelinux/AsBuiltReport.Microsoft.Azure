# Network Topology Diagram — Subscription Box Subgraph Refactor Design

## Problem

The Network Topology diagram (`Get-AbrDiagAzNetworkTopology.ps1`) still has misaligned VNet
information within each Subscription box. Each Subscription is currently rendered as a *real*
Graphviz cluster (the `SubGraph` cmdlet) whose label is the subscription name, wrapping a
*separate* `Add-HtmlNodeTable` HTML-table node for the VNet icon/name/info grid inside it. That's
two independent layout systems — Graphviz's cluster box model and the HTML table's own row/column
sizing — trying to agree on padding and alignment, and they don't always agree cleanly.

After discussing this with the developer of AsBuiltReport.Diagram (formerly Diagrammer.Code), the
suggested fix is to stop wrapping a real cluster around each Subscription box and instead use
`Add-HtmlNodeTable`'s own `-Subgraph` parameter set to fold the subscription label (and an icon)
into the *same* HTML table as the VNet rows, so the whole box renders as one atomic Graphviz node.
`Get-AbrDiagAzManagementGroup.ps1` already uses this pattern for its per-management-group
subscription-count node and is the reference for how this module should use it — Diagrammer.Code's
own docs example (`example15`, `Add-DiaHTMLNodeTable -Subgraph -SubgraphLabel ...`) confirms it's
the same underlying feature just under this project's function name, `Add-HtmlNodeTable`.

## Goal

Refactor `Get-AbrDiagAzNetworkTopology.ps1` so each Subscription box (hub or spoke) is a single
`Add-HtmlNodeTable -Subgraph` node instead of a real cluster wrapping a child node, eliminating the
alignment fight, while keeping Region-level grouping (which legitimately contains multiple sibling
Subscription nodes) as a real Graphviz cluster. The rendered diagram's content and general layout
(regions, hub/spoke roles, peering edges, column wrapping) should not otherwise change.

## Current Architecture (for reference)

- Region → real `SubGraph` cluster, labeled with the region name.
  - Per hub VNet → its own real `SubGraph` cluster labeled with the subscription name, wrapping a
    single-VNet `Add-HtmlNodeTable` node. Multiple hubs in one subscription each get their own
    cluster (not combined).
  - Per spoke Subscription → real `SubGraph` cluster labeled with the subscription name, wrapping
    either a single-VNet `Add-HtmlNodeTable` node (1 spoke) or a `-MultiIcon` grid node (2+ spokes).
- `$NodeRef`: VNet ID → a compass-point reference on the wrapping node (`:s` for hubs, `:n` for
  spokes/grids) used as `Edge` source/target.
- `$ClusterRef`: VNet ID → the enclosing Subscription cluster's DOT id, used for `ltail`/`lhead` so
  peering edges visually clip to the Subscription box boundary instead of the inner node.
- `$DeepRowNodeIds` / column-wrap invisible-edge chain (`$SubscriptionRepresentativeNodes`,
  `minlen=2; weight=100`): forces Subscription boxes within a region to wrap at `$ColumnSize` per
  row. Applies only to spoke subscriptions today.
- `$HubNodeForCentering`: written at hub-node creation time, never read anywhere — dead code left
  over from a removed centering experiment (see the code comment above it).

## New Architecture

### 1. Region stays a real cluster; Subscription becomes one HTML-table node

Region-level `SubGraph` clustering is unchanged — a region legitimately groups multiple sibling
Subscription nodes, and there's no single-HTML-table way to lay out unrelated boxes side by side.

Each Subscription (hub or spoke) becomes a single `Add-HtmlNodeTable -Subgraph` node, a direct
child of the Region cluster (one nesting level shallower than today, since the per-subscription
real cluster is removed). The subscription name and a subscription icon become the header row of
that node's own HTML table via `-Subgraph -SubgraphLabel <name> -SubgraphIconType 'Sub'
-SubgraphLabelPos 'top'`, matching `Get-AbrDiagAzManagementGroup.ps1`'s existing usage. `$ImagesObj`
gains a `'Sub' = 'subscriptions.png'` entry (the icon already exists in `Icons/` and is already used
by the Management Group diagram).

### 2. Hub handling is unified with the spoke pattern

Today, every hub VNet gets its own real cluster + node even when multiple hubs share a subscription.
This is unified to match spokes: one `Add-HtmlNodeTable -Subgraph` call per hub-subscription,
using `-MultiIcon` (with array-valued `AditionalInfo` for `AddressSpace`/`Role`) when that
subscription has more than one hub VNet, and the existing non-`-MultiIcon` single-node path when it
has exactly one — the same rule the spoke path already follows, since `-MultiIcon` combined with
array-valued `AditionalInfo` mis-renders on a single element.

`$HubNodeForCentering` is removed as part of this rewrite (dead code, never read).

### 3. Node naming and port-level edge targeting

Each Subscription's underlying node keeps one ID: `$SafeHubSubscriptionId` for hub subscriptions
(unchanged name, now used directly as the node rather than a cluster id) and `$SafeSubscriptionId`
for spoke subscriptions. The spoke grid's `_Grid` suffix is dropped — there's no longer a
wrapping cluster to distinguish the node from, so the subscription id itself is the node.

Peering edges no longer use `ltail`/`lhead` cluster clipping (that requires a real cluster, which
Subscriptions no longer are). Instead, `$NodeRef` points at the **specific VNet's own port** inside
the shared table, using the ports `Add-HtmlNodeTable` already emits per element:

- Grouped nodes (`-MultiIcon`, 2+ VNets in the subscription): `"<SubId>":"Icon_<VNetName>"` — the
  per-element icon cell.
- Single-VNet nodes: `"<SubId>":"<VNetName>"` — the per-element name cell (no `Icon_` prefix, since
  the non-`-MultiIcon` icon cell is shared and unported).

`$ClusterRef` is removed entirely (it existed only to support `ltail`/`lhead`). `Edge` calls drop
the `ltail`/`lhead` attributes; `color`, `style`, `dir`/`arrowtail`/`arrowhead`, `minlen`, and
`constraint` are unchanged.

This is also a behavior improvement, not just a refactor to fix alignment: today, an edge into a
multi-VNet grid always lands on the grid's top-center compass point regardless of which spoke is
actually peered. Port-level targeting makes each peering edge visually land on the specific VNet
it connects, even within a grouped box.

### 4. Unchanged

- The column-wrap invisible-edge chain (`$SubscriptionRepresentativeNodes`, `minlen=2; weight=100`)
  and `$DeepRowNodeIds` / `constraint=false` handling — both operate on Subscription *boxes* as a
  unit and don't depend on what's inside the box. Still scoped to spoke subscriptions only, matching
  today.
- The legend `SubGraph` wrapper, theme/DPI/orientation handling, `New-AbrDiagram` call, and overall
  diagram structure (hubs vs. spokes, region grouping, peering-state colors).

## Testing

No existing Pester/unit tests cover diagram generation in this module (diagram functions are
exercised via `New-AsBuiltReport` against live Azure data). Verification is manual: generate a
report against a tenant with multiple regions, multiple subscriptions per region, and at least one
subscription with 2+ spokes and one with 2+ hubs, and visually confirm Subscription box alignment
and correct peering-edge endpoints (including into a grouped grid) in the rendered HTML/Word output.

## Out of Scope

- No change to Region-level clustering, theme/DPI/orientation resolution, the legend, or the
  Management Group diagram (`Get-AbrDiagAzManagementGroup.ps1`), which already uses this pattern
  correctly.
- No change to `AsBuiltReport.Diagram`/`Add-HtmlNodeTable` itself — this is a consumer-side refactor
  using parameters that already exist in the installed module.
