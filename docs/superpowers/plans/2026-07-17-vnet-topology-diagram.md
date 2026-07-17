# VNet Hub-Spoke Topology Diagram Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tenant-wide Virtual Network hub-spoke peering topology diagram (plus a fallback summary table), rendered once per tenant alongside the existing Management Group diagram, using the module's existing `AsBuiltReport.Diagram` tooling.

**Architecture:** Two new report functions (`Get-AbrAzNetworkTopology.ps1` orchestration + `Get-AbrDiagAzNetworkTopology.ps1` diagram builder) called directly from `Invoke-AsBuiltReport.Microsoft.Azure.ps1`, mirroring the existing Management Group diagram's placement and structure. A cross-subscription pre-pass collects VNets, peerings, and (InfoLevel-gated) Gateway/Firewall/NVA presence to flag hub VNets. A small shared helper (`Test-AbrAzNvaVm.ps1`) is extracted from the existing NVA reporter so hub detection and NVA reporting share one detection path.

**Tech Stack:** PowerShell, Az PowerShell module, PScribo, AsBuiltReport.Diagram (PSGraph/Graphviz wrapper), Pester.

## Global Constraints

- Full design rationale lives in `docs/superpowers/specs/2026-07-17-vnet-topology-diagram-design.md` — read it before starting if anything below is ambiguous.
- Follow `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzManagementGroup.ps1` and `Src/Private/Diagram/Get-AbrDiagAzManagementGroup.ps1` as the structural precedent for every new file in this plan.
- PascalCase everywhere; `[PSCustomObject]@{}` for all table data; `ColumnWidths` set on every table; collect all data before any PScribo output call within a function.
- New private functions matching `^Get-AbrAz` are swept by `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`'s "Language Files" context, which requires a matching `GetAbrAzXxx` localization section containing at minimum `InfoLevel`, `Collecting`, `Heading`, `Name`, `ResourceGroup`, `Location` keys, and requires every `$LocalizedData.Key` referenced in the function body to exist in that section. New utility functions that should NOT be swept into this (e.g. ID-parsing helpers) must be named to avoid the `^Get-AbrAz` pattern.
- `Tests/LocalizationData.Tests.ps1` requires all 5 language files (`en-US`, `en-GB`, `de-DE`, `es-ES`, `fr-FR`) to have byte-for-byte identical `Section.Key` sets — every new key must be added to all 5 files, no more, no less.
- `fr-FR` strings in this codebase are written without accented characters (see existing `GetAbrAzManagementGroup` entries) — match that convention exactly for new fr-FR strings.
- `ManagementGroup` (and now `NetworkTopology`) is called directly in `Invoke-AsBuiltReport.Microsoft.Azure.ps1`, outside the `Options.SectionOrder`/`ResourceTypeMap` dispatch loop — never add `NetworkTopology` to `SectionOrder`.
- `Get-AbrAzNetworkTopology` requires `InfoLevel.NetworkTopology -ge 1 -and InfoLevel.VirtualNetwork -ge 2` to run at all. **Revised during Task 5 based on user feedback:** its Gateway/Firewall/NVA cross-references are collected unconditionally, regardless of `InfoLevel.VirtualNetworkGateway`/`InfoLevel.Firewall`/`InfoLevel.NetworkVirtualAppliance` — gating them individually caused a VNet genuinely fronted by one of those components to be silently misclassified as a spoke whenever its source section was disabled, which is a correctness defect, not acceptable degradation. See the design spec's "InfoLevel dependencies on other sections" section for the full rationale.
- Diagrams are gated by `Options.EnableDiagrams`; diagram failures must never break the report (always wrap in try/catch with `Write-PScriboMessage -IsWarning`).
- **Two intentional simplifications versus the original spec wording**, both because the exact rendering can't be verified without a live Graphviz render in this environment and both reuse primitives already proven working in `Get-AbrDiagAzManagementGroup.ps1`:
  1. Subscription grouping is a text subtitle inside each VNet's own node (via `Add-HtmlNodeTable -AditionalInfo`), not a visual bounding box — see spec's "Diagram construction" section.
  2. Gateway/Firewall/NVA "badges" are rendered as a text subtitle line (e.g. `Role: Hub (Gateway, Firewall)`), not composited badge icon images — `Add-HtmlNodeTable`'s multi-icon support is designed for one-icon-per-list-element (e.g. a subscription list), not for compositing several small badge icons onto a single node alongside one primary icon, and no existing diagram in this module exercises that composition. The `Gateway`/`Firewall`/`NVA` icon keys are still wired into the `ImagesObj` hashtable so a future enhancement can add them without restructuring the diagram builder.

---

## Task 1: Extract shared NVA detection helper

**Files:**
- Create: `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Test-AbrAzNvaVm.ps1`
- Modify: `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkVirtualAppliance.ps1:74-84`
- Modify: `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1` (add existence check)

**Interfaces:**
- Produces: `Test-AbrAzNvaVm -VM <PSVirtualMachine> -NvaPublishers <string[]> -NvaTagKey <string|$null> -NvaTagValue <string|$null>` → `[PSCustomObject]@{ IsNva = [bool]; IsNvaByImg = [bool]; IsNvaByTag = [bool] }`. Task 4 (`Get-AbrAzNetworkTopology.ps1`) consumes this exact signature and return shape.

- [ ] **Step 1: Create the shared helper**

Create `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Test-AbrAzNvaVm.ps1`:

```powershell
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
```

- [ ] **Step 2: Refactor `Get-AbrAzNetworkVirtualAppliance.ps1` to call the helper**

In `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkVirtualAppliance.ps1`, replace lines 74-84:

```powershell
                foreach ($AzVm in $AzVms) {
                    $ImageRef   = $AzVm.StorageProfile.ImageReference
                    $IsNvaByImg = $ImageRef.Publisher -and ($NvaPublishers -contains $ImageRef.Publisher.ToLower())

                    $IsNvaByTag = $false
                    if ($NvaTagKey) {
                        $TagVal = $AzVm.Tags[$NvaTagKey]
                        $IsNvaByTag = if ($NvaTagValue) { $TagVal -eq $NvaTagValue } else { $null -ne $TagVal }
                    }

                    if (-not ($IsNvaByImg -or $IsNvaByTag)) { continue }
```

with:

```powershell
                foreach ($AzVm in $AzVms) {
                    $ImageRef = $AzVm.StorageProfile.ImageReference
                    $NvaCheck = Test-AbrAzNvaVm -VM $AzVm -NvaPublishers $NvaPublishers -NvaTagKey $NvaTagKey -NvaTagValue $NvaTagValue
                    $IsNvaByImg = $NvaCheck.IsNvaByImg
                    $IsNvaByTag = $NvaCheck.IsNvaByTag

                    if (-not $NvaCheck.IsNva) { continue }
```

No other lines in this file change — `$IsNvaByImg`/`$IsNvaByTag` keep the same names and are used identically later (lines 107-121 vendor display switch, lines 196-198 `DetectedBy` computation).

- [ ] **Step 3: Verify the module still imports and the NVA reporter parses correctly**

Run: `pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force; Get-Command Test-AbrAzNvaVm, Get-AbrAzNetworkVirtualAppliance -Module AsBuiltReport.Microsoft.Azure"`

Expected: both commands listed, no import errors.

- [ ] **Step 4: Add an existence check to the test suite**

In `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`, inside `Context 'Private Functions'` (after the `Get-AbrAzNetworkVirtualAppliance` block around line 490-492), add:

```powershell
        It 'Should have Test-AbrAzNvaVm function' {
            $PrivateFunctions.Name | Should -Contain 'Test-AbrAzNvaVm.ps1'
        }
```

- [ ] **Step 5: Run the test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS, no new failures (the NVA reporter's existing behavior is unchanged, so no existing test should break; `Test-AbrAzNvaVm` does not match `^Get-AbrAz` so it is not swept into the localization checks).

- [ ] **Step 6: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Private/Report/Test-AbrAzNvaVm.ps1 AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkVirtualAppliance.ps1 Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1
git commit -m "Extract shared NVA detection into Test-AbrAzNvaVm helper"
```

---

## Task 2: Add a subnet-to-VNet ID resolver utility

**Files:**
- Create: `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Resolve-AbrVNetIdFromSubnetId.ps1`
- Modify: `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1` (add existence check)

**Interfaces:**
- Produces: `Resolve-AbrVNetIdFromSubnetId -SubnetId <string|$null>` → `[string]` (parent VNet resource ID) or `$null`. Consumed by Task 4's Gateway/Firewall/NVA cross-reference loops.

- [ ] **Step 1: Create the utility**

Create `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Resolve-AbrVNetIdFromSubnetId.ps1`. Named `Resolve-Abr...` (not `Get-AbrAz...`) so it is not swept into the `^Get-AbrAz` localization requirements — it is a pure string utility with no PScribo/localization involvement, the same category as the existing `Get-CountryName.ps1` and `Convert-DataSize.ps1`:

```powershell
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
```

- [ ] **Step 2: Verify parsing manually**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force; Resolve-AbrVNetIdFromSubnetId -SubnetId '/subscriptions/aaaa/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/GatewaySubnet'"
```

Expected output: `/subscriptions/aaaa/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub`

Also verify the null case: `pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force; \$null -eq (Resolve-AbrVNetIdFromSubnetId -SubnetId \$null)"`
Expected: `True`

- [ ] **Step 3: Add an existence check**

In `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`, inside `Context 'Private Functions'`, add:

```powershell
        It 'Should have Resolve-AbrVNetIdFromSubnetId function' {
            $PrivateFunctions.Name | Should -Contain 'Resolve-AbrVNetIdFromSubnetId.ps1'
        }
```

- [ ] **Step 4: Run the test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Private/Report/Resolve-AbrVNetIdFromSubnetId.ps1 Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1
git commit -m "Add Resolve-AbrVNetIdFromSubnetId utility"
```

---

## Task 3: Config, README, and localization scaffolding

**Files:**
- Modify: `AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.json`
- Modify: `README.md`
- Modify: `AsBuiltReport.Microsoft.Azure/Language/en-US/MicrosoftAzure.psd1`
- Modify: `AsBuiltReport.Microsoft.Azure/Language/en-GB/MicrosoftAzure.psd1`
- Modify: `AsBuiltReport.Microsoft.Azure/Language/de-DE/MicrosoftAzure.psd1`
- Modify: `AsBuiltReport.Microsoft.Azure/Language/es-ES/MicrosoftAzure.psd1`
- Modify: `AsBuiltReport.Microsoft.Azure/Language/fr-FR/MicrosoftAzure.psd1`
- Modify: `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1` (InfoLevel existence check)

**Interfaces:**
- Produces: `InfoLevel.NetworkTopology` config key; `$reportTranslate.GetAbrAzNetworkTopology.*` localization keys consumed verbatim by Task 4 and Task 5's function bodies:
  `InfoLevel`, `Collecting`, `Heading`, `SectionInfo`, `DiagramHeading`, `DiagramAltText`, `DiagramError`, `ErrorMessage`, `SubscriptionError`, `NoPeeredVNets`, `TableHeading`, `Name`, `ResourceGroup`, `Subscription`, `Location`, `AddressSpace`, `Role`, `Hub`, `Spoke`, `PeerCount`, `Gateway`, `Firewall`, `Nva`.

- [ ] **Step 1: Add the InfoLevel key to the JSON config**

In `AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.json`, in the `InfoLevel` object, insert a new line between `"NetworkSecurityGroup": 1,` (line 89) and `"NetworkVirtualAppliance": 1,` (line 90):

```json
        "NetworkSecurityGroup": 1,
        "NetworkTopology": 1,
        "NetworkVirtualAppliance": 1,
```

- [ ] **Step 2: Add the InfoLevel row to README.md**

In `README.md`, in the InfoLevel table (around line 352), insert a new row between `NetworkSecurityGroup` and `NetworkVirtualAppliance`:

```
| NetworkSecurityGroup        |        1        |        2        |
| NetworkTopology             |        1        |        1        |
| NetworkVirtualAppliance     |        1        |        3        |
```

Also add a short explanatory note directly below the InfoLevel table (after line 369, before the `### Healthcheck` heading) documenting the cross-dependency, since it is not obvious from the table alone:

```markdown
> **Note:** `NetworkTopology` also requires `VirtualNetwork` to be set to `2` or higher — the topology diagram is built from Virtual Network peering detail, which is only collected at that level. Its Gateway/Firewall/NVA hub-detection badges additionally require `VirtualNetworkGateway`, `Firewall`, and `NetworkVirtualAppliance` respectively to be enabled (`1` or higher); a disabled section is simply skipped for hub detection, not treated as an error.
```

- [ ] **Step 3: Add the `GetAbrAzNetworkTopology` section to `en-US`**

In `AsBuiltReport.Microsoft.Azure/Language/en-US/MicrosoftAzure.psd1`, immediately after the `GetAbrAzManagementGroup` section closes (after the line `'@` that follows `ErrorMessage = Unable to collect Management Group information:` — i.e. right after line 1475 in the current file), insert:

```powershell
# Azure Network Topology (Get-AbrAzNetworkTopology)
GetAbrAzNetworkTopology = ConvertFrom-StringData @'
    InfoLevel             = NetworkTopology InfoLevel set at {0}.
    Collecting            = Collecting Azure Virtual Network hub-spoke topology information.
    SectionInfo           = This diagram shows Virtual Network peering topology across all subscriptions in the tenant. A Virtual Network is treated as a hub if it has 3 or more peering connections, or hosts a Virtual Network Gateway, Azure Firewall, or Network Virtual Appliance; hub badges reflect only the sections currently enabled in InfoLevel, so a hub may appear without a visible reason if the relevant section is disabled. Virtual Networks with no peering connections are not shown; they remain fully documented in each subscription's Virtual Network section.
    Heading               = Network Topology
    TableHeading          = Virtual Network Topology
    DiagramHeading        = Virtual Network Hub-Spoke Topology
    DiagramAltText        = Azure virtual network hub-and-spoke topology diagram
    DiagramError          = Unable to generate Network Topology diagram: {0}.
    SubscriptionError     = Unable to collect Network Topology information for subscription {0}: {1}.
    NoPeeredVNets         = No peered Virtual Networks found across any subscription; skipping Network Topology section.
    Name                  = Name
    ResourceGroup         = Resource Group
    Subscription          = Subscription
    Location              = Location
    AddressSpace          = Address Space
    Role                  = Role
    Hub                   = Hub
    Spoke                 = Spoke
    PeerCount             = Peering Count
    Gateway               = Gateway
    Firewall              = Firewall
    Nva                   = NVA
    ErrorMessage          = Unable to collect Network Topology information:
'@

```

- [ ] **Step 4: Add the identical section (translated) to `en-GB`**

In `AsBuiltReport.Microsoft.Azure/Language/en-GB/MicrosoftAzure.psd1`, in the same location relative to `GetAbrAzManagementGroup`, insert (en-GB mirrors en-US for this module, as seen in the existing `GetAbrAzManagementGroup` section — no wording differs):

```powershell
# Azure Network Topology (Get-AbrAzNetworkTopology)
GetAbrAzNetworkTopology = ConvertFrom-StringData @'
    InfoLevel             = NetworkTopology InfoLevel set at {0}.
    Collecting            = Collecting Azure Virtual Network hub-spoke topology information.
    SectionInfo           = This diagram shows Virtual Network peering topology across all subscriptions in the tenant. A Virtual Network is treated as a hub if it has 3 or more peering connections, or hosts a Virtual Network Gateway, Azure Firewall, or Network Virtual Appliance; hub badges reflect only the sections currently enabled in InfoLevel, so a hub may appear without a visible reason if the relevant section is disabled. Virtual Networks with no peering connections are not shown; they remain fully documented in each subscription's Virtual Network section.
    Heading               = Network Topology
    TableHeading          = Virtual Network Topology
    DiagramHeading        = Virtual Network Hub-Spoke Topology
    DiagramAltText        = Azure virtual network hub-and-spoke topology diagram
    DiagramError          = Unable to generate Network Topology diagram: {0}.
    SubscriptionError     = Unable to collect Network Topology information for subscription {0}: {1}.
    NoPeeredVNets         = No peered Virtual Networks found across any subscription; skipping Network Topology section.
    Name                  = Name
    ResourceGroup         = Resource Group
    Subscription          = Subscription
    Location              = Location
    AddressSpace          = Address Space
    Role                  = Role
    Hub                   = Hub
    Spoke                 = Spoke
    PeerCount             = Peering Count
    Gateway               = Gateway
    Firewall              = Firewall
    Nva                   = NVA
    ErrorMessage          = Unable to collect Network Topology information:
'@

```

- [ ] **Step 5: Add the translated section to `de-DE`**

In `AsBuiltReport.Microsoft.Azure/Language/de-DE/MicrosoftAzure.psd1`, in the same location, insert:

```powershell
# Azure Network Topology (Get-AbrAzNetworkTopology)
GetAbrAzNetworkTopology = ConvertFrom-StringData @'
    InfoLevel             = NetworkTopology InfoLevel auf {0} gesetzt.
    Collecting            = Sammlung von Informationen zur Hub-Spoke-Topologie des virtuellen Azure-Netzwerks.
    SectionInfo           = Dieses Diagramm zeigt die Peering-Topologie virtueller Netzwerke über alle Abonnements im Mandanten hinweg. Ein virtuelles Netzwerk wird als Hub betrachtet, wenn es 3 oder mehr Peering-Verbindungen hat oder ein Virtual Network Gateway, eine Azure Firewall oder eine Network Virtual Appliance hostet. Hub-Kennzeichnungen spiegeln nur die derzeit im InfoLevel aktivierten Abschnitte wider, sodass ein Hub ohne erkennbaren Grund angezeigt werden kann, wenn der entsprechende Abschnitt deaktiviert ist. Virtuelle Netzwerke ohne Peering-Verbindungen werden nicht angezeigt; sie werden weiterhin vollständig im Abschnitt "Virtuelles Netzwerk" des jeweiligen Abonnements dokumentiert.
    Heading               = Netzwerktopologie
    TableHeading          = Topologie des virtuellen Netzwerks
    DiagramHeading        = Hub-Spoke-Topologie des virtuellen Netzwerks
    DiagramAltText        = Diagramm der Hub-Spoke-Topologie des virtuellen Azure-Netzwerks
    DiagramError          = Kann Netzwerktopologie-Diagramm nicht generieren: {0}.
    SubscriptionError     = Netzwerktopologie-Informationen fuer Abonnement {0} koennen nicht gesammelt werden: {1}.
    NoPeeredVNets         = Keine gepeerten virtuellen Netzwerke in einem Abonnement gefunden; Abschnitt Netzwerktopologie wird uebersprungen.
    Name                  = Name
    ResourceGroup         = Ressourcengruppe
    Subscription          = Abonnement
    Location              = Standort
    AddressSpace          = Adressraum
    Role                  = Rolle
    Hub                   = Hub
    Spoke                 = Spoke
    PeerCount             = Anzahl Peerings
    Gateway               = Gateway
    Firewall              = Firewall
    Nva                   = NVA
    ErrorMessage          = Netzwerktopologie-Informationen koennen nicht gesammelt werden:
'@

```

- [ ] **Step 6: Add the translated section to `es-ES`**

In `AsBuiltReport.Microsoft.Azure/Language/es-ES/MicrosoftAzure.psd1`, in the same location, insert:

```powershell
# Azure Network Topology (Get-AbrAzNetworkTopology)
GetAbrAzNetworkTopology = ConvertFrom-StringData @'
    InfoLevel             = InfoLevel de topologia de red establecido en {0}.
    Collecting            = Recopilando informacion de topologia hub-spoke de red virtual de Azure.
    SectionInfo           = Este diagrama muestra la topologia de emparejamiento de redes virtuales en todas las suscripciones del inquilino. Una red virtual se considera un concentrador (hub) si tiene 3 o mas conexiones de emparejamiento, o si aloja una puerta de enlace de red virtual, un Azure Firewall o un dispositivo virtual de red. Las etiquetas de concentrador reflejan unicamente las secciones actualmente habilitadas en InfoLevel, por lo que un concentrador puede aparecer sin un motivo visible si la seccion correspondiente esta deshabilitada. Las redes virtuales sin conexiones de emparejamiento no se muestran; permanecen totalmente documentadas en la seccion de red virtual de cada suscripcion.
    Heading               = Topologia de red
    TableHeading          = Topologia de red virtual
    DiagramHeading        = Topologia hub-spoke de red virtual
    DiagramAltText        = Diagrama de topologia hub-spoke de red virtual de Azure
    DiagramError          = No se puede generar el diagrama de topologia de red: {0}.
    SubscriptionError     = No se puede recopilar informacion de topologia de red para la suscripcion {0}: {1}.
    NoPeeredVNets         = No se encontraron redes virtuales emparejadas en ninguna suscripcion; se omite la seccion de topologia de red.
    Name                  = Nombre
    ResourceGroup         = Grupo de recursos
    Subscription          = Suscripcion
    Location              = Ubicacion
    AddressSpace          = Espacio de direcciones
    Role                  = Rol
    Hub                   = Concentrador
    Spoke                 = Radial
    PeerCount             = Numero de emparejamientos
    Gateway               = Puerta de enlace
    Firewall              = Firewall
    Nva                   = NVA
    ErrorMessage          = No se puede recopilar informacion de topologia de red:
'@

```

- [ ] **Step 7: Add the translated section to `fr-FR`**

In `AsBuiltReport.Microsoft.Azure/Language/fr-FR/MicrosoftAzure.psd1`, in the same location, insert (no accented characters, matching this file's existing convention):

```powershell
# Azure Network Topology (Get-AbrAzNetworkTopology)
GetAbrAzNetworkTopology = ConvertFrom-StringData @'
    InfoLevel             = InfoLevel de la topologie reseau defini a {0}.
    Collecting            = Collecte des informations de topologie hub-spoke du reseau virtuel Azure.
    SectionInfo           = Ce diagramme montre la topologie d'appairage des reseaux virtuels dans tous les abonnements du locataire. Un reseau virtuel est considere comme un hub s'il possede 3 appairages ou plus, ou s'il heberge une passerelle de reseau virtuel, un Azure Firewall ou une appliance virtuelle reseau. Les indicateurs de hub refletent uniquement les sections actuellement activees dans InfoLevel ; un hub peut donc apparaitre sans raison visible si la section correspondante est desactivee. Les reseaux virtuels sans appairage ne sont pas affiches ; ils restent entierement documentes dans la section reseau virtuel de chaque abonnement.
    Heading               = Topologie reseau
    TableHeading          = Topologie du reseau virtuel
    DiagramHeading        = Topologie hub-spoke du reseau virtuel
    DiagramAltText        = Diagramme de topologie hub-spoke du reseau virtuel Azure
    DiagramError          = Impossible de generer le diagramme de topologie reseau : {0}.
    SubscriptionError     = Impossible de collecter les informations de topologie reseau pour l'abonnement {0} : {1}.
    NoPeeredVNets         = Aucun reseau virtuel apparie trouve dans un abonnement ; section topologie reseau ignoree.
    Name                  = Nom
    ResourceGroup         = Groupe de ressources
    Subscription          = Abonnement
    Location              = Emplacement
    AddressSpace          = Espace d'adressage
    Role                  = Role
    Hub                   = Hub
    Spoke                 = Spoke
    PeerCount             = Nombre d'appairages
    Gateway               = Passerelle
    Firewall              = Pare-feu
    Nva                   = NVA
    ErrorMessage          = Impossible de collecter les informations de topologie reseau :
'@

```

- [ ] **Step 8: Add an InfoLevel existence check**

In `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`, inside `Context 'JSON Configuration'`, add (near the `InfoLevel should include ManagementGroup` block around line 657-659):

```powershell
        It 'InfoLevel should include NetworkTopology' {
            $JsonConfig.InfoLevel.PSObject.Properties.Name | Should -Contain 'NetworkTopology'
        }
```

- [ ] **Step 9: Run the localization and config tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS. At this point `GetAbrAzNetworkTopology` exists in all 5 language files with identical keys, but no `.ps1` function references it yet — that is fine, the "should exist per Get-AbrAz* function" test only checks functions that exist, and the cross-language key-parity test only compares the 5 files against each other.

- [ ] **Step 10: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.json README.md AsBuiltReport.Microsoft.Azure/Language Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1
git commit -m "Add NetworkTopology InfoLevel config, README docs, and localization strings"
```

---

## Task 4: Diagram builder — `Get-AbrDiagAzNetworkTopology.ps1`

**Files:**
- Create: `AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1`
- Modify: `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1` (add existence check)

**Interfaces:**
- Consumes: `Add-HtmlNodeTable`, `Edge`, `New-AbrDiagram` from `AsBuiltReport.Diagram` (same functions `Get-AbrDiagAzManagementGroup.ps1` already uses). `$Options.DiagramTheme`, `$Options.DiagramDpi` (script-scope inherited, same as `Get-AbrDiagAzManagementGroup.ps1`).
- Produces: `Get-AbrDiagAzNetworkTopology -VNets <PSCustomObject[]> -PeeringEdges <PSCustomObject[]>`, called from Task 5. Renders the diagram via PScribo `Image` directly (matching `Get-AbrDiagAzManagementGroup.ps1`'s pattern — it does not return a value).
  - `$VNets` elements: `@{ Id; Name; ResourceGroup; Subscription; AddressSpace; IsHub; HasGateway; HasFirewall; HasNva; PeerCount }`
  - `$PeeringEdges` elements: `@{ SourceId; TargetId; Connected }`

- [ ] **Step 1: Create the diagram builder**

Create `AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1`:

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
            $DiagramTheme = if ($Options.DiagramTheme) { $Options.DiagramTheme } else { 'White' }
            $DiagramDpi = if ($Options.DiagramDpi) { $Options.DiagramDpi } else { 96 }
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
                        Edge $SourceSafeId $TargetSafeId @{ color = $EdgeColor; style = 'solid' }
                    } else {
                        Edge $SourceSafeId $TargetSafeId @{ color = $DisconnectedColor; style = 'dashed' }
                    }
                }
            }

            $DiagramResult = New-AbrDiagram `
                -InputObject $DiagramGraph `
                -Format base64 `
                -MainDiagramLabel $LocalizedData.DiagramHeading `
                -IconPath $IconPath `
                -ImagesObj $ImagesObj `
                -MainGraphSize '9,6.5' `
                -Dpi $DiagramDpi `
                -Direction 'left-to-right' `
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
```

Notes on this implementation versus `Get-AbrDiagAzManagementGroup.ps1`:
- `-Direction 'left-to-right'` and a wide `MainGraphSize` (`'9,6.5'` vs. MG's portrait `'6.5,9'`) because a peering graph is naturally wider than it is tall (a hub with several spokes reads better left-to-right), unlike MG's tree which reads better top-to-bottom.
- `$DisconnectedColor` (`#C0392B`, a red) is a literal here rather than reused from an existing shared constant — no shared HealthCheck-red constant currently exists outside PScribo's own `Set-Style -Style Critical`, which only applies to table cells, not Graphviz edge colors.

- [ ] **Step 2: Verify the file parses with no syntax errors**

Run: `pwsh -NoProfile -Command "\$Errors = \$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1), [ref]\$Errors); \$Errors.Count"`

Expected: `0`

- [ ] **Step 3: Verify the module imports the new function**

Run: `pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force; Get-Command Get-AbrDiagAzNetworkTopology -Module AsBuiltReport.Microsoft.Azure"`

Expected: command listed, no import errors.

- [ ] **Step 4: Add an existence check**

`Get-AbrDiagAzManagementGroup` has no explicit existence check in the test suite (Diagram-folder functions are not individually enumerated there), so this step is optional for strict parity — but add it anyway since it costs nothing and documents intent. In `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`, inside `Context 'Private Functions'`, add:

```powershell
        It 'Should have Get-AbrDiagAzNetworkTopology function' {
            $PrivateFunctions.Name | Should -Contain 'Get-AbrDiagAzNetworkTopology.ps1'
        }
```

- [ ] **Step 5: Run the test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS. `Get-AbrDiagAzNetworkTopology` does not match `^Get-AbrAz`, so it is exempt from the localization-key-usage scan — Task 5's function is the one that will be checked against the `GetAbrAzNetworkTopology` section added in Task 3.

- [ ] **Step 6: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1 Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1
git commit -m "Add Get-AbrDiagAzNetworkTopology diagram builder"
```

---

## Task 5: Orchestration function — `Get-AbrAzNetworkTopology.ps1`

**Files:**
- Create: `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkTopology.ps1`
- Modify: `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1` (add existence check)

**Interfaces:**
- Consumes: `Test-AbrAzNvaVm` (Task 1), `Resolve-AbrVNetIdFromSubnetId` (Task 2), `Get-AbrDiagAzNetworkTopology -VNets -PeeringEdges` (Task 4). Script-scope-inherited variables available at its call site (same as `Get-AbrAzManagementGroup.ps1`): `$AzSubscriptions`, `$TenantId`, `$AzLocationLookup`, `$InfoLevel`, `$Options`, `$Report`, `$reportTranslate`.
- Produces: no return value — renders PScribo `Section`/`Table`/diagram output directly, called from Task 6.

- [ ] **Step 1: Create the orchestration function**

Create `AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkTopology.ps1`:

```powershell
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
        if (($InfoLevel.NetworkTopology -ge 1) -and ($InfoLevel.VirtualNetwork -ge 2)) {
            try {
                Write-PScriboMessage $LocalizedData.Collecting

                #region --- NVA publisher list (mirrors Get-AbrAzNetworkVirtualAppliance.ps1) ---
                $DefaultNvaPublishers = @(
                    'paloaltonetworks', 'fortinet', 'cisco', 'checkpoint', 'f5-networks',
                    'barracudanetworks', 'sonicwall-inc', 'juniper-networks', 'viptela', 'riverbed'
                )
                $NvaPublishers = if ($Options.NvaPublishers -and $Options.NvaPublishers.Count -gt 0) {
                    $Options.NvaPublishers
                } else {
                    $DefaultNvaPublishers
                }
                $NvaTagKey = if ($Options.NvaTag) { ($Options.NvaTag -split '=')[0].Trim() } else { $null }
                $NvaTagValue = if ($Options.NvaTag -and $Options.NvaTag -contains '=') { ($Options.NvaTag -split '=', 2)[1].Trim() } else { $null }
                #endregion

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

                    if ($InfoLevel.VirtualNetworkGateway -ge 1) {
                        try {
                            $Gateways = Get-AzVirtualNetworkGateway -ErrorAction Stop
                        } catch {
                            $Gateways = @()
                        }
                        foreach ($Gateway in $Gateways) {
                            $GwVNetId = Resolve-AbrVNetIdFromSubnetId -SubnetId $Gateway.IpConfigurations[0].Subnet.Id
                            if ($GwVNetId) { [void]$VNetsWithGateway.Add($GwVNetId.ToLower()) }
                        }
                    }

                    if ($InfoLevel.Firewall -ge 1) {
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
                    }

                    if ($InfoLevel.NetworkVirtualAppliance -ge 1) {
                        try {
                            $SubVms = Get-AzVM -ErrorAction Stop
                        } catch {
                            $SubVms = @()
                        }
                        foreach ($SubVm in $SubVms) {
                            $NvaCheck = Test-AbrAzNvaVm -VM $SubVm -NvaPublishers $NvaPublishers -NvaTagKey $NvaTagKey -NvaTagValue $NvaTagValue
                            if (-not $NvaCheck.IsNva) { continue }

                            $PrimaryNicId = ($SubVm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary } | Select-Object -First 1).Id
                            if (-not $PrimaryNicId) { $PrimaryNicId = $SubVm.NetworkProfile.NetworkInterfaces[0].Id }
                            $PrimaryNic = Get-AzNetworkInterface -Name $PrimaryNicId.Split('/')[-1] -ResourceGroupName $PrimaryNicId.Split('/')[4] -ErrorAction SilentlyContinue
                            $NvaVNetId = Resolve-AbrVNetIdFromSubnetId -SubnetId $PrimaryNic.IpConfigurations[0].Subnet.Id
                            if ($NvaVNetId) { [void]$VNetsWithNva.Add($NvaVNetId.ToLower()) }
                        }
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

                        if ($Options.EnableDiagrams) {
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
```

- [ ] **Step 2: Verify the file parses with no syntax errors**

Run: `pwsh -NoProfile -Command "\$Errors = \$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkTopology.ps1), [ref]\$Errors); \$Errors.Count"`

Expected: `0`

- [ ] **Step 3: Verify the module imports the new function**

Run: `pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force; Get-Command Get-AbrAzNetworkTopology -Module AsBuiltReport.Microsoft.Azure"`

Expected: command listed, no import errors.

- [ ] **Step 4: Add an existence check**

In `Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1`, inside `Context 'Private Functions'`, add:

```powershell
        It 'Should have Get-AbrAzNetworkTopology function' {
            $PrivateFunctions.Name | Should -Contain 'Get-AbrAzNetworkTopology.ps1'
        }
```

- [ ] **Step 5: Run the full test suite — this is the critical localization-consistency check**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS. This is the first point where `Get-AbrAzNetworkTopology` (matching `^Get-AbrAz`) is scanned by the "Language Files" context's `$LocalizedData.*` reference/hashtable-key checks against the `GetAbrAzNetworkTopology` section added in Task 3. If any key mismatch exists (e.g. a typo in `$LocalizedData.SubscriptionId` vs. the localization file's key), this run will fail with a specific "missing localization property/hashtable key" message naming the exact key — fix any such mismatch by correcting either the code or the localization file (all 5 language files, per Task 3's identical-key-set requirement) before proceeding.

- [ ] **Step 6: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Private/Report/Get-AbrAzNetworkTopology.ps1 Tests/AsBuiltReport.Microsoft.Azure.Tests.ps1
git commit -m "Add Get-AbrAzNetworkTopology orchestration function"
```

---

## Task 6: Wire into the report entry point

**Files:**
- Modify: `AsBuiltReport.Microsoft.Azure/Src/Public/Invoke-AsBuiltReport.Microsoft.Azure.ps1:262-266`

**Interfaces:**
- Consumes: `Get-AbrAzNetworkTopology` (Task 5, no parameters).

- [ ] **Step 1: Add the call after `Get-AbrAzManagementGroup`**

In `AsBuiltReport.Microsoft.Azure/Src/Public/Invoke-AsBuiltReport.Microsoft.Azure.ps1`, find:

```powershell
                Section -Style Heading1 $($AzTenant.Name) {
                    Get-AbrAzTenant
                    Get-AbrAzManagementGroup
                    Section -Style Heading2 $LocalizedData.Subscriptions {
```

Replace with:

```powershell
                Section -Style Heading1 $($AzTenant.Name) {
                    Get-AbrAzTenant
                    Get-AbrAzManagementGroup
                    Get-AbrAzNetworkTopology
                    Section -Style Heading2 $LocalizedData.Subscriptions {
```

- [ ] **Step 2: Verify the module imports cleanly end-to-end**

Run: `pwsh -NoProfile -Command "Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force -ErrorAction Stop; Write-Output 'Import OK'"`

Expected: `Import OK`, no errors.

- [ ] **Step 3: Run the full test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS.

- [ ] **Step 4: Run PSScriptAnalyzer across all new/modified files**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./AsBuiltReport.Microsoft.Azure -Recurse -Settings .github/workflows/PSScriptAnalyzerSettings.psd1 -Severity Warning,Error"`

Expected: no findings in `Test-AbrAzNvaVm.ps1`, `Resolve-AbrVNetIdFromSubnetId.ps1`, `Get-AbrDiagAzNetworkTopology.ps1`, `Get-AbrAzNetworkTopology.ps1`, `Get-AbrAzNetworkVirtualAppliance.ps1`, or `Invoke-AsBuiltReport.Microsoft.Azure.ps1`. If findings appear, fix them before proceeding (do not suppress without cause).

- [ ] **Step 5: Manual end-to-end verification against a real or test tenant**

This feature cannot be fully verified by unit tests alone — it produces a rendered Graphviz diagram whose visual correctness (node layout, badge text readability, edge styling) can only be confirmed by actually generating a report. Per the module's own contribution checklist, generate a report against a tenant with at least one hub-spoke topology (or a tenant with `Options.EnableDiagrams: false` if none is available, to at least verify the fallback table path):

```powershell
Import-Module ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1 -Force
New-AsBuiltReportConfig -Report Microsoft.Azure -FolderPath . -Filename TestConfig
# Edit TestConfig.json: set InfoLevel.VirtualNetwork = 2, InfoLevel.NetworkTopology = 1, Options.EnableDiagrams = true
New-AsBuiltReport -Report Microsoft.Azure -Target '<tenant-id>' -UseInteractiveAuth -Format Html -OutputFolderPath . -ReportConfigFilePath .\TestConfig.json
```

Open the generated HTML report and confirm:
- A "Network Topology" section appears once, before the "Subscriptions" heading, after "Management Groups"
- Hub VNets render with a larger icon and a `Role: Hub (...)` subtitle listing the correct badges
- Spoke VNets render with a `Role: Spoke` subtitle
- Peering edges are solid for `Connected` peerings; if a `Disconnected` peering exists in the test tenant, confirm it renders dashed and red
- The fallback summary table below the diagram lists the same VNets with correct Role/PeerCount values
- Setting `InfoLevel.NetworkTopology = 0` in the config removes the whole section
- Setting `InfoLevel.VirtualNetwork = 1` (below the peering threshold) also removes the whole section, even with `NetworkTopology = 1`

If no suitable test tenant is available, at minimum verify the module loads and the fallback table path (`Options.EnableDiagrams: false`) renders without error against any tenant with 2+ peered VNets, and note in the PR description that live diagram rendering was not visually verified.

- [ ] **Step 6: Commit**

```bash
git add AsBuiltReport.Microsoft.Azure/Src/Public/Invoke-AsBuiltReport.Microsoft.Azure.ps1
git commit -m "Wire Get-AbrAzNetworkTopology into the report entry point"
```

---

## Task 7: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:** None — documentation only.

- [ ] **Step 1: Add an Unreleased section documenting the feature**

In `CHANGELOG.md`, insert a new section at the top, above `## [0.3.1] - 2026-07-17`:

```markdown
## [Unreleased]

### Added
* Add support for Virtual Network hub-spoke topology diagrams (`Get-AbrAzNetworkTopology`), rendered once per tenant alongside the Management Group diagram, identifying hub VNets by peering count, Virtual Network Gateway presence, Azure Firewall presence, or Network Virtual Appliance presence, with a fallback summary table when diagrams are disabled. Requires `InfoLevel.NetworkTopology` and `InfoLevel.VirtualNetwork` set to 2 or higher.

### Changed
* Extract NVA detection logic shared by `Get-AbrAzNetworkVirtualAppliance` and `Get-AbrAzNetworkTopology` into `Test-AbrAzNvaVm`

```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "Update CHANGELOG for VNet hub-spoke topology diagram"
```

---

## Task 8: Full verification pass

**Files:** None (verification only).

- [ ] **Step 1: Run the complete test suite one final time**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests -Output Detailed"`

Expected: PASS, 0 failures.

- [ ] **Step 2: Run PSScriptAnalyzer across the whole module**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Settings .github/workflows/PSScriptAnalyzerSettings.psd1 -Severity Warning,Error"`

Expected: no findings.

- [ ] **Step 3: Confirm the module manifest still validates**

Run: `pwsh -NoProfile -Command "Test-ModuleManifest -Path ./AsBuiltReport.Microsoft.Azure/AsBuiltReport.Microsoft.Azure.psd1"`

Expected: manifest object printed, no errors.

- [ ] **Step 4: Review the full diff against `dev` before handing off**

Run: `git diff dev...feature/vnet-topology-diagram --stat`

Expected: only the files touched across Tasks 1-7 appear — no unrelated changes.
