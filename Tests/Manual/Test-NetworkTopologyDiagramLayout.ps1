# Tests/Manual/Test-NetworkTopologyDiagramLayout.ps1
# Manual dev tool: renders Get-AbrDiagAzNetworkTopology against synthetic data to a
# Graphviz DOT text file, without needing Azure or Graphviz installed. Not part of CI.
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'NetworkTopologySmokeTest.dot')
)

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$DiagramFunctionPath = Join-Path $RepoRoot 'AsBuiltReport.Microsoft.Azure\Src\Private\Diagram\Get-AbrDiagAzNetworkTopology.ps1'
$IconPath = Join-Path $RepoRoot 'AsBuiltReport.Microsoft.Azure\Icons'

# Load AsBuiltReport.Diagram 1.0.9 - use explicit module path to ensure correct version is loaded
$DiagramModulePath = (Get-Module AsBuiltReport.Diagram -ListAvailable | Where-Object { $_.Version -eq '1.0.9' } | Select-Object -First 1).Path
if (-not $DiagramModulePath) {
    throw "AsBuiltReport.Diagram version 1.0.9 not found"
}
Import-Module $DiagramModulePath -Force -ErrorAction Stop

# Capture the real New-AbrDiagram command before we shadow it
$RealNewAbrDiagram = Get-Command New-AbrDiagram -Module AsBuiltReport.Diagram

# Stub PScribo output cmdlets so the function can run without an active PScribo Document context.
# Parameter names match exactly what Get-AbrDiagAzNetworkTopology.ps1 calls today
# (Write-PScriboMessage -IsWarning <string>; Image -Base64 <string> -Text <string> -Percent <int>;
# BlankLine with no args) - ValueFromRemainingArguments does NOT catch unknown *named* arguments,
# only excess positional ones, so the stubs must declare these parameters explicitly.
function global:Write-PScriboMessage { param($IsWarning) }
function global:Image { param($Base64, $Text, $Percent) }
function global:BlankLine { param() }

# Shadow New-AbrDiagram to force 'dot' output (no Graphviz binary required) regardless of the
# '-Format base64' the production function passes.
function global:New-AbrDiagram {
    param(
        $InputObject,
        [Array] $Format,
        [string] $MainDiagramLabel,
        $IconPath,
        [hashtable] $ImagesObj,
        [string] $MainGraphSize,
        [int] $Dpi,
        [string] $EdgeType,
        [string] $LogoName
    )
    & $RealNewAbrDiagram -InputObject $InputObject -Format 'dot' -MainDiagramLabel $MainDiagramLabel `
        -IconPath $IconPath -ImagesObj $ImagesObj -MainGraphSize $MainGraphSize -Dpi $Dpi `
        -EdgeType $EdgeType -LogoName $LogoName -OutputFolderPath ([System.IO.Path]::GetTempPath()) `
        -Filename 'NetworkTopologySmokeTest'
}

$reportTranslate = [PSCustomObject]@{
    GetAbrAzNetworkTopology = [PSCustomObject]@{
        DiagramHeading = 'Virtual Network Hub-Spoke Topology'
        DiagramAltText = 'Azure virtual network hub-and-spoke topology diagram'
        UnknownRegion  = 'Unknown Region'
        AddressSpace   = 'Address Space'
        Role           = 'Role'
        Hub            = 'Hub'
        Spoke          = 'Spoke'
        Gateway        = 'Gateway'
        Firewall       = 'Firewall'
        Nva            = 'NVA'
        Connected      = 'Connected'
        Initiated      = 'Initiated'
        Disconnected   = 'Disconnected'
    }
}
$Diagram = [PSCustomObject]@{
    NetworkTopology = [PSCustomObject]@{ Enabled = $true; Theme = 'White'; Dpi = 96; Columns = 3 }
}
$Global:Orientation = 'Portrait'

function New-TestVNet {
    param($Id, $Name, $Location, $Subscription, $AddressSpace, $IsHub, $HasGateway = $false, $HasFirewall = $false, $HasNva = $false)
    [PSCustomObject]@{
        Id           = $Id
        Name         = $Name
        Location     = $Location
        Subscription = $Subscription
        AddressSpace = $AddressSpace
        IsHub        = $IsHub
        HasGateway   = $HasGateway
        HasFirewall  = $HasFirewall
        HasNva       = $HasNva
    }
}

$VNets = @(
    New-TestVNet -Id '/sub/hub-sub/hub-vnet-01' -Name 'hub-vnet-01' -Location 'Australia East' -Subscription 'Hub-Sub' -AddressSpace '10.0.0.0/16' -IsHub $true -HasGateway $true -HasFirewall $true
    New-TestVNet -Id '/sub/spoke-sub-a/spoke-vnet-01' -Name 'spoke-vnet-01' -Location 'Australia East' -Subscription 'Spoke-Sub-A' -AddressSpace '10.1.0.0/24' -IsHub $false
    New-TestVNet -Id '/sub/spoke-sub-a/spoke-vnet-02' -Name 'spoke-vnet-02' -Location 'Australia East' -Subscription 'Spoke-Sub-A' -AddressSpace '10.2.0.0/24' -IsHub $false
    New-TestVNet -Id '/sub/spoke-sub-b/spoke-vnet-03' -Name 'spoke-vnet-03' -Location 'Australia East' -Subscription 'Spoke-Sub-B' -AddressSpace '10.3.0.0/24' -IsHub $false
    New-TestVNet -Id '/sub/spoke-sub-c/spoke-vnet-04' -Name 'spoke-vnet-04' -Location 'Australia East' -Subscription 'Spoke-Sub-C' -AddressSpace '10.4.0.0/24' -IsHub $false
    New-TestVNet -Id '/sub/spoke-sub-d/spoke-vnet-05' -Name 'spoke-vnet-05' -Location 'Australia East' -Subscription 'Spoke-Sub-D' -AddressSpace '10.5.0.0/24' -IsHub $false
    New-TestVNet -Id '/sub/multi-hub-sub/hub-vnet-02' -Name 'hub-vnet-02' -Location 'Australia Southeast' -Subscription 'Multi-Hub-Sub' -AddressSpace '10.10.0.0/16' -IsHub $true -HasNva $true
    New-TestVNet -Id '/sub/multi-hub-sub/hub-vnet-03' -Name 'hub-vnet-03' -Location 'Australia Southeast' -Subscription 'Multi-Hub-Sub' -AddressSpace '10.11.0.0/16' -IsHub $true -HasNva $true
    New-TestVNet -Id '/sub/spoke-sub-e/spoke-vnet-06' -Name 'spoke-vnet-06' -Location 'Australia Southeast' -Subscription 'Spoke-Sub-E' -AddressSpace '10.20.0.0/24' -IsHub $false
)

$PeeringEdges = @(
    [PSCustomObject]@{ SourceId = '/sub/hub-sub/hub-vnet-01'; TargetId = '/sub/spoke-sub-a/spoke-vnet-01'; State = 'Connected' }
    [PSCustomObject]@{ SourceId = '/sub/hub-sub/hub-vnet-01'; TargetId = '/sub/spoke-sub-a/spoke-vnet-02'; State = 'Connected' }
    [PSCustomObject]@{ SourceId = '/sub/hub-sub/hub-vnet-01'; TargetId = '/sub/spoke-sub-b/spoke-vnet-03'; State = 'Initiated' }
    [PSCustomObject]@{ SourceId = '/sub/hub-sub/hub-vnet-01'; TargetId = '/sub/spoke-sub-c/spoke-vnet-04'; State = 'Disconnected' }
    [PSCustomObject]@{ SourceId = '/sub/hub-sub/hub-vnet-01'; TargetId = '/sub/spoke-sub-d/spoke-vnet-05'; State = 'Connected' }
    [PSCustomObject]@{ SourceId = '/sub/multi-hub-sub/hub-vnet-02'; TargetId = '/sub/spoke-sub-e/spoke-vnet-06'; State = 'Connected' }
)

. $DiagramFunctionPath
try {
    Get-AbrDiagAzNetworkTopology -VNets $VNets -PeeringEdges $PeeringEdges -ErrorAction Stop
} catch {
    Write-Host "Error from Get-AbrDiagAzNetworkTopology: $_"
    Write-Host "Exception details: $($_.Exception | Format-List -Force | Out-String)"
    throw
}

$GeneratedDot = Join-Path ([System.IO.Path]::GetTempPath()) 'NetworkTopologySmokeTest.dot'
if (Test-Path $GeneratedDot) {
    Copy-Item -Path $GeneratedDot -Destination $OutputPath -Force
    Write-Host "DOT output written to: $OutputPath"
} else {
    throw 'No .dot file was produced - the diagram function likely threw before calling New-AbrDiagram.'
}
