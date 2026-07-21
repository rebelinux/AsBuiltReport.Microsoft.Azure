# Debug version with extensive logging
[CmdletBinding()]
param(
    [string] $LogPath = "$env:TEMP\NetworkTopology-Debug.log"
)

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] $Message"
    Write-Host $logEntry
    Add-Content -Path $LogPath -Value $logEntry
}

Write-Log "Starting debug script"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$DiagramFunctionPath = Join-Path $RepoRoot 'AsBuiltReport.Microsoft.Azure\Src\Private\Diagram\Get-AbrDiagAzNetworkTopology.ps1'
$IconPath = Join-Path $RepoRoot 'AsBuiltReport.Microsoft.Azure\Icons'

Write-Log "RepoRoot: $RepoRoot"
Write-Log "DiagramFunctionPath: $DiagramFunctionPath"
Write-Log "IconPath: $IconPath"

Write-Log "Step 1: Importing AsBuiltReport.Diagram 1.0.9..."
$DiagramModulePath = (Get-Module AsBuiltReport.Diagram -ListAvailable | Where-Object { $_.Version -eq '1.0.9' } | Select-Object -First 1).Path
if (-not $DiagramModulePath) {
    Write-Log "ERROR: AsBuiltReport.Diagram version 1.0.9 not found"
    throw "AsBuiltReport.Diagram version 1.0.9 not found"
}
Write-Log "Using module path: $DiagramModulePath"
Import-Module $DiagramModulePath -Force -ErrorAction Stop
Write-Log "Module imported successfully"

Write-Log "Step 2: Capturing real New-AbrDiagram..."
$RealNewAbrDiagram = Get-Command New-AbrDiagram -Module AsBuiltReport.Diagram
Write-Log "Real command: $($RealNewAbrDiagram.Source)"

Write-Log "Step 3: Defining stubs..."
function global:Write-PScriboMessage { param($IsWarning) }
function global:Image { param($Base64, $Text, $Percent) }
function global:BlankLine { param() }
Write-Log "Stubs defined"

Write-Log "Step 4: Defining proxy function..."
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
    Write-Host "Proxy New-AbrDiagram called"
    & $RealNewAbrDiagram -InputObject $InputObject -Format 'dot' -MainDiagramLabel $MainDiagramLabel `
        -IconPath $IconPath -ImagesObj $ImagesObj -MainGraphSize $MainGraphSize -Dpi $Dpi `
        -EdgeType $EdgeType -LogoName $LogoName -OutputFolderPath ([System.IO.Path]::GetTempPath()) `
        -Filename 'NetworkTopologySmokeTest'
    Write-Host "Proxy call completed"
}
Write-Log "Proxy defined"

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

Write-Log "Step 5: Setting up test data..."
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

Write-Log "Test data created: $($VNets.Count) VNets, $($PeeringEdges.Count) peering edges"

Write-Log "Step 6: Dot-sourcing diagram function..."
try {
    . $DiagramFunctionPath
    Write-Log "Function dot-sourced successfully"
} catch {
    Write-Log "ERROR dot-sourcing: $_"
    throw
}

Write-Log "Step 7: Calling Get-AbrDiagAzNetworkTopology..."
try {
    Get-AbrDiagAzNetworkTopology -VNets $VNets -PeeringEdges $PeeringEdges -ErrorAction Stop
    Write-Log "Get-AbrDiagAzNetworkTopology completed successfully"
} catch {
    Write-Log "ERROR in Get-AbrDiagAzNetworkTopology: $_"
    Write-Log "Exception: $($_.Exception | Format-List -Force | Out-String)"
    throw
}

Write-Log "Step 8: Checking for generated DOT file..."
$GeneratedDot = Join-Path ([System.IO.Path]::GetTempPath()) 'NetworkTopologySmokeTest.dot'
if (Test-Path $GeneratedDot) {
    Write-Log "DOT file found at: $GeneratedDot"
    $fileSize = (Get-Item $GeneratedDot).Length
    Write-Log "File size: $fileSize bytes"
    Copy-Item -Path $GeneratedDot -Destination "$env:TEMP\NetworkTopology-before.dot" -Force
    Write-Log "DOT output written to: $env:TEMP\NetworkTopology-before.dot"
} else {
    Write-Log "ERROR: No .dot file was produced at: $GeneratedDot"
    throw 'No .dot file was produced - the diagram function likely threw before calling New-AbrDiagram.'
}

Write-Log "Script completed successfully"
