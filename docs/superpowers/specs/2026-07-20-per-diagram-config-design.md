# Per-Diagram Configuration Design

## Problem

Diagram generation settings (`EnableDiagrams`, `DiagramTheme`, `DiagramDpi`, `DiagramColumnSize`) currently live as flat, global keys under `Options` in the report JSON. Both diagrams — the Management Group hierarchy diagram and the Network Topology diagram — share the same theme, DPI, and enabled/disabled state. There's no way to, for example, enable the Network Topology diagram at 600 DPI while disabling or differently configuring the Management Group diagram.

## Goal

Give each diagram its own independent configuration block in the report JSON, keyed by the same resource name already used under `InfoLevel`/`HealthCheck`, so diagrams can be individually enabled/disabled, themed, and sized without affecting one another.

## JSON Schema

A new top-level `Diagram` section, sibling to `Options`, `InfoLevel`, and `HealthCheck`:

```json
"Diagram": {
    "ManagementGroup": {
        "Enabled": true,
        "Theme": "White",
        "Dpi": 600
    },
    "NetworkTopology": {
        "Enabled": true,
        "Theme": "White",
        "Dpi": 600,
        "Columns": 4
    }
}
```

- Keys match the existing `InfoLevel` resource names (`ManagementGroup`, `NetworkTopology`) for consistency and easy extension when future diagrams are added.
- `ManagementGroup` has no `Columns` setting — that diagram doesn't use configurable column wrapping today (its subscription-collection nodes use a fixed `-ColumnSize 1`).
- This is a **breaking change**: `Options.EnableDiagrams`, `Options.DiagramTheme`, `Options.DiagramDpi`, and `Options.DiagramColumnSize` are removed entirely. No backward-compatibility fallback to the old flat keys is provided — the feature is unreleased (module is at `0.3.1-unreleased`), and the project's conventions favor changing the code over adding compatibility shims.

## Code Changes

Resolution stays **inline per file** (no new helper function), matching the existing style already used for `$Options.*` lookups.

1. **`Src/Public/Invoke-AsBuiltReport.Microsoft.Azure.ps1`** — add `$Diagram = $ReportConfig.Diagram` alongside the existing `$Options = $ReportConfig.Options` assignment, so `$Diagram` is visible to private functions the same way `$Options`/`$InfoLevel` already are.

2. **`Src/Private/Report/Get-AbrAzManagementGroup.ps1`** — change:
   ```powershell
   if ($Options.EnableDiagrams) {
   ```
   to:
   ```powershell
   if ($Diagram.ManagementGroup.Enabled) {
   ```

3. **`Src/Private/Report/Get-AbrAzNetworkTopology.ps1`** — change:
   ```powershell
   if ($Options.EnableDiagrams) {
   ```
   to:
   ```powershell
   if ($Diagram.NetworkTopology.Enabled) {
   ```

4. **`Src/Private/Diagram/Get-AbrDiagAzManagementGroup.ps1`** — change:
   ```powershell
   $DiagramTheme = if ($Options.DiagramTheme) { $Options.DiagramTheme } else { 'White' }
   $DiagramDpi = if ($Options.DiagramDpi) { $Options.DiagramDpi } else { 96 }
   ```
   to:
   ```powershell
   $DiagramTheme = if ($Diagram.ManagementGroup.Theme) { $Diagram.ManagementGroup.Theme } else { 'White' }
   $DiagramDpi = if ($Diagram.ManagementGroup.Dpi) { $Diagram.ManagementGroup.Dpi } else { 96 }
   ```

5. **`Src/Private/Diagram/Get-AbrDiagAzNetworkTopology.ps1`** — change:
   ```powershell
   $DiagramTheme = if ($Options.DiagramTheme) { $Options.DiagramTheme } else { 'White' }
   $DiagramDpi = if ($Options.DiagramDpi) { $Options.DiagramDpi } else { 96 }
   ...
   $ColumnSize = if ($Options.DiagramColumnSize -and [int]$Options.DiagramColumnSize -gt 0) { [int]$Options.DiagramColumnSize } else { 3 }
   ```
   to:
   ```powershell
   $DiagramTheme = if ($Diagram.NetworkTopology.Theme) { $Diagram.NetworkTopology.Theme } else { 'White' }
   $DiagramDpi = if ($Diagram.NetworkTopology.Dpi) { $Diagram.NetworkTopology.Dpi } else { 96 }
   ...
   $ColumnSize = if ($Diagram.NetworkTopology.Columns -and [int]$Diagram.NetworkTopology.Columns -gt 0) { [int]$Diagram.NetworkTopology.Columns } else { 3 }
   ```

No new guard code is needed for a missing `Diagram` section, missing diagram key, or missing individual setting: PowerShell property access on `$null` (e.g. `$Diagram.ManagementGroup.Enabled` when `$Diagram` is `$null`) safely returns `$null` rather than throwing, so the existing `if (...) {...} else {default}` fallback pattern already handles a JSON file that predates this change or omits a setting.

## Defaults

Unchanged from today's hardcoded fallbacks, just relocated from `Options.*` reads to `Diagram.<Name>.*` reads:

| Setting | Default | Notes |
|---|---|---|
| `Enabled` | `$false` | Diagrams stay opt-in, matching today's behavior when `EnableDiagrams` is unset |
| `Theme` | `'White'` | |
| `Dpi` | `96` | Graphviz's native default |
| `Columns` | `3` | NetworkTopology only |

## Repo Config & Documentation Updates

- **`AsBuiltReport.Microsoft.Azure.json`**: remove `EnableDiagrams`, `DiagramTheme`, `DiagramDpi`, `DiagramColumnSize` from `Options`; add the new `Diagram` section carrying forward today's effective values (`Enabled: true`, `Theme: "White"`, `Dpi: 600` for both diagrams; `Columns: 4` for `NetworkTopology`, matching the current `DiagramColumnSize` value).
- **`README.md`**: remove the four now-obsolete rows from the `### Options` table; add a new `### Diagram` subsection (positioned after `### InfoLevel`, before `### Healthcheck`) documenting the `Enabled`/`Theme`/`Dpi`/`Columns` settings per diagram key, in the same table style as the existing `### Options`/`### InfoLevel` sections.
- **`CHANGELOG.md`**: add an entry under `[0.3.1]` → `Changed` describing the schema change and calling out that it is breaking (old `Options.EnableDiagrams`/`DiagramTheme`/`DiagramDpi`/`DiagramColumnSize` no longer have any effect).

## Out of Scope

- The `Chart` JSON section mentioned alongside `Diagram` in the original request is illustrative of the target shape only — no `Chart` configuration currently exists in this module (no chart-producing code exists yet), so it is not part of this change.
- No new settings beyond `Enabled`/`Theme`/`Dpi`/`Columns` are introduced — this migrates existing global settings to be per-diagram, it does not add new diagram capabilities (e.g. per-diagram icon sizing, edge type, or graph size are out of scope).
