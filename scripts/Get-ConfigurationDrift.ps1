#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
<#
.SYNOPSIS
    Reports configuration drift between infra/config/storage.json and what is
    actually deployed in an environment.

.DESCRIPTION
    Bicep deploys in Incremental mode, so it never deletes or reports things
    that exist in Azure but are no longer (or never were) in the
    configuration. This script fills that gap:

      * Orphaned        - storage account deployed, but not in the config any more
      * Missing         - storage account in the config, but not deployed
      * Property drift  - sku / access tier / HNS / kind / public access changed manually
      * Container drift - extra or missing blob containers
      * Unmanaged       - resources without the managedBy=Bicep tag (created by hand)

    The script is READ-ONLY: it never changes anything and never reads secrets.
    Expected values come from infra/config/storage.json, the same file Bicep
    uses, so nothing environment specific is hardcoded here.

    In Azure DevOps it runs after Test-AzureDeployment.ps1 in every
    environment. Findings are shown as warnings and the Markdown report is
    attached to the run summary page.

.PARAMETER SubscriptionId
    Subscription that contains the environment (GUID).

.PARAMETER ResourceGroupName
    Resource group of the environment, e.g. rg-hwapp-dev.

.PARAMETER Environment
    Environment name as used in storage.json: dev, test or prod.

.PARAMETER ConfigPath
    Path to storage.json. Defaults to ../infra/config/storage.json.

.PARAMETER OutputPath
    Optional. Writes the findings as a Markdown report to this file.

.PARAMETER FailOnDrift
    Optional. Return exit code 1 when drift is found (e.g. for a nightly check).

.NOTES
    Prerequisites (local run):
      - PowerShell 7+
      - Az modules:      Install-Module Az -Scope CurrentUser -Repository PSGallery
      - Signed in:       Connect-AzAccount
      - Reader access on the resource group is enough.

    Exit codes:
      0 - no drift found (or drift found without -FailOnDrift)
      1 - drift found and -FailOnDrift was used
      2 - could not run (invalid subscription, not signed in, missing config, RG not found)

    Quick self-test (no Azure resources needed) - must print an
    "is not a valid GUID" error and exit code 2:

      ./scripts/Get-ConfigurationDrift.ps1 -SubscriptionId "not-a-guid" `
          -ResourceGroupName "rg-hwapp-dev" -Environment "dev"
      $LASTEXITCODE

    Show this help:
      Get-Help ./scripts/Get-ConfigurationDrift.ps1 -Full

.EXAMPLE
    # Report drift for Dev on screen
    Connect-AzAccount
    ./scripts/Get-ConfigurationDrift.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroupName "rg-hwapp-dev" `
        -Environment "dev"

.EXAMPLE
    # Write a Markdown report for Prod and fail if anything drifted
    ./scripts/Get-ConfigurationDrift.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroupName "rg-hwapp-prod" `
        -Environment "prod" `
        -OutputPath ./drift-prod.md `
        -FailOnDrift
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string] $Environment,

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'infra' 'config' 'storage.json'),

    [string] $OutputPath,

    # Return exit code 1 when drift is found (useful for a scheduled check).
    [switch] $FailOnDrift
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'common' 'InfraHelpers.psm1') -Force

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string] $Category, [string] $Resource, [string] $Detail)
    $findings.Add([pscustomobject]@{ Category = $Category; Resource = $Resource; Detail = $Detail })
}

try {
    $config = Get-InfraConfig -ConfigPath $ConfigPath
    if ($config.skuByEnvironment.Keys -notcontains $Environment) {
        throw "Environment '$Environment' is not defined in $ConfigPath."
    }
    $expectedSku = $config.skuByEnvironment[$Environment]

    Connect-InfraSubscription -SubscriptionId $SubscriptionId
    $null = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
}
catch {
    $msg = if ($_.Exception.Message -match '^(Configuration|Environment|SubscriptionId|No Azure|Cannot select)') { $_.Exception.Message } else { Get-SafeErrorMessage $_ }
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-PipelineIssue -Message $msg
    exit 2
}

# --- Storage accounts --------------------------------------------------------
$expectedByRole = @{}
foreach ($sa in $config.storageAccounts) { $expectedByRole[$sa.name] = $sa }

$deployed = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName)
$seenRoles = @{}

foreach ($sa in $deployed) {
    $role = if ($sa.Tags -and $sa.Tags.ContainsKey('storageRole')) { $sa.Tags['storageRole'] } else { $null }

    if (-not $role) {
        Add-Finding 'Orphaned' $sa.StorageAccountName 'storage account has no storageRole tag (not created by this template?)'
        continue
    }
    if (-not $expectedByRole.ContainsKey($role)) {
        Add-Finding 'Orphaned' $sa.StorageAccountName "role '$role' is no longer in the configuration - remove it or add it back to storage.json"
        continue
    }

    $seenRoles[$role] = $true
    $exp = $expectedByRole[$role]

    if ($sa.Sku.Name -ne $expectedSku) { Add-Finding 'Property drift' $sa.StorageAccountName "sku: actual $($sa.Sku.Name), expected $expectedSku" }
    if ("$($sa.AccessTier)" -ne $exp.accessTier) { Add-Finding 'Property drift' $sa.StorageAccountName "accessTier: actual $($sa.AccessTier), expected $($exp.accessTier)" }
    if ($sa.Kind -ne $exp.kind) { Add-Finding 'Property drift' $sa.StorageAccountName "kind: actual $($sa.Kind), expected $($exp.kind)" }
    if ([bool]$sa.EnableHierarchicalNamespace -ne [bool]$exp.isHnsEnabled) { Add-Finding 'Property drift' $sa.StorageAccountName "isHnsEnabled: actual $([bool]$sa.EnableHierarchicalNamespace), expected $($exp.isHnsEnabled)" }
    if ($sa.AllowBlobPublicAccess) { Add-Finding 'Property drift' $sa.StorageAccountName 'public blob access has been enabled' }
    if ($sa.AllowSharedKeyAccess -ne $false) { Add-Finding 'Property drift' $sa.StorageAccountName 'shared key access has been enabled' }

    try {
        $actualContainers = @(Get-AzRmStorageContainer -ResourceGroupName $ResourceGroupName -StorageAccountName $sa.StorageAccountName |
                Select-Object -ExpandProperty Name)
        foreach ($c in $exp.containers | Where-Object { $_ -notin $actualContainers }) {
            Add-Finding 'Container drift' "$($sa.StorageAccountName)/$c" 'container is missing'
        }
        foreach ($c in $actualContainers | Where-Object { $_ -notin $exp.containers }) {
            Add-Finding 'Container drift' "$($sa.StorageAccountName)/$c" 'container is not in the configuration'
        }
    }
    catch {
        Add-Finding 'Error' $sa.StorageAccountName "could not list containers: $(Get-SafeErrorMessage $_)"
    }
}

foreach ($role in $expectedByRole.Keys | Where-Object { -not $seenRoles.ContainsKey($_) }) {
    Add-Finding 'Missing' $role 'configured storage account is not deployed'
}

# --- Resources not managed by Bicep -----------------------------------------
foreach ($res in Get-AzResource -ResourceGroupName $ResourceGroupName) {
    if (-not $res.Tags -or $res.Tags['managedBy'] -ne 'Bicep') {
        Add-Finding 'Unmanaged' $res.Name "$($res.ResourceType) has no managedBy=Bicep tag (created outside the pipeline?)"
    }
}

# --- Report -----------------------------------------------------------------
Write-Host ''
Write-Host "Configuration drift report - $Environment ($ResourceGroupName)"
Write-Host ('=' * 60)

if ($findings.Count -eq 0) {
    Write-Host 'No drift detected. Deployed state matches the configuration.' -ForegroundColor Green
}
else {
    $findings | Sort-Object Category, Resource | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    Write-Host "$($findings.Count) drift finding(s)." -ForegroundColor Yellow
    foreach ($f in $findings) {
        Write-PipelineIssue -Type warning -Message "Drift [$($f.Category)] $($f.Resource): $($f.Detail)"
    }
}

if ($OutputPath) {
    $md = [System.Text.StringBuilder]::new()
    $null = $md.AppendLine("## Configuration drift - $Environment")
    $null = $md.AppendLine()
    $null = $md.AppendLine("Resource group: ``$ResourceGroupName`` - generated $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC")
    $null = $md.AppendLine()
    if ($findings.Count -eq 0) {
        $null = $md.AppendLine(':white_check_mark: No drift detected.')
    }
    else {
        $null = $md.AppendLine('| Category | Resource | Detail |')
        $null = $md.AppendLine('| --- | --- | --- |')
        foreach ($f in $findings | Sort-Object Category, Resource) {
            $null = $md.AppendLine("| $($f.Category) | $($f.Resource) | $($f.Detail) |")
        }
    }
    Set-Content -Path $OutputPath -Value $md.ToString() -Encoding utf8
    Write-Host "Report written to $OutputPath"

    if ($env:TF_BUILD) {
        $fullPath = (Resolve-Path $OutputPath).Path
        Write-Host "##vso[task.uploadsummary]$fullPath"
    }
}

if ($FailOnDrift -and $findings.Count -gt 0) { exit 1 }
exit 0