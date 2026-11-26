#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-deployment check: runs an Azure what-if for one environment and shows
    what is going to be deployed, with the key settings of each resource.

.DESCRIPTION
    Wraps `az deployment sub what-if` for infra/main.bicep so it can be run the
    same way for dev, test and prod without remembering the full command.

      * Checks that Azure CLI is installed, you are signed in and the
        subscription is valid.
      * Uses a placeholder value for the external API key (unless
        EXTERNAL_API_KEY is already set) - what-if never shows secure values,
        so the real key is not needed. The placeholder is removed afterwards.
      * Shows every resource what-if can preview, with its change type and key
        settings (SKU, tier, hierarchical namespace, location, soft delete...).
      * Lists the modules what-if cannot preview (they depend on values that
        only exist during a real deployment, e.g. the App Service identity)
        and describes what they will deploy, based on infra/config/storage.json.
      * With -FailOnDelete it returns exit code 1 when what-if reports that a
        resource would be deleted.

    Nothing is deployed. The script never prints the API key.

.PARAMETER Environment
    dev, test or prod. Selects infra/parameters/<environment>.bicepparam.

.PARAMETER SubscriptionId
    Target subscription (GUID).

.PARAMETER Location
    Region for the subscription-scope deployment. Defaults to westeurope.

.PARAMETER TemplateFile
    Path to main.bicep. Defaults to ../infra/main.bicep.

.PARAMETER ParameterFile
    Path to the .bicepparam file. Defaults to ../infra/parameters/<environment>.bicepparam.

.PARAMETER ConfigPath
    Path to storage.json. Defaults to ../infra/config/storage.json.

.PARAMETER FailOnDelete
    Return exit code 1 if any resource would be deleted.

.NOTES
    Prerequisites:
      - PowerShell 7+
      - Azure CLI with Bicep (az bicep install)
      - Signed in:   az login
      - Reader access on the subscription is enough for what-if.

    Exit codes:
      0 - what-if completed (no deletes, or deletes without -FailOnDelete)
      1 - what-if reported an error, or deletes were found with -FailOnDelete
      2 - could not run (Azure CLI missing, not signed in, invalid subscription, missing files)

    Quick self-test (no Azure call needed) - prints an "is not a valid GUID"
    error and returns exit code 2:

      ./scripts/Invoke-DeploymentWhatIf.ps1 -Environment dev -SubscriptionId "not-a-guid"
      $LASTEXITCODE

    Show this help:
      Get-Help ./scripts/Invoke-DeploymentWhatIf.ps1 -Full

.EXAMPLE
    # What is going to be deployed in Dev?
    az login
    ./scripts/Invoke-DeploymentWhatIf.ps1 -Environment dev -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    # Check Prod before a release and fail if anything would be deleted
    ./scripts/Invoke-DeploymentWhatIf.ps1 -Environment prod `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" -FailOnDelete
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $Location = 'westeurope',

    [string] $TemplateFile = (Join-Path $PSScriptRoot '..' 'infra' 'main.bicep'),

    [string] $ParameterFile,

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'infra' 'config' 'storage.json'),

    [switch] $FailOnDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'common' 'InfraHelpers.psm1') -Force

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $PSScriptRoot '..' 'infra' 'parameters' "$Environment.bicepparam"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Runs az and keeps normal output and error output apart.
function Invoke-Az {
    param([string[]] $Arguments)
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
        StdErr   = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n")
    }
}

# Safely reads a nested property such as 'properties.accessTier' (returns $null if missing).
function Get-Value {
    param($Object, [string] $Path)
    $current = $Object
    foreach ($segment in $Path -split '\.') {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $current = $property.Value
    }
    return $current
}

# Turns a resource ID into a readable type and name.
function Get-ResourceInfo {
    param([string] $ResourceId)
    $parts = $ResourceId.Trim('/') -split '/'
    $providerIndex = [Array]::LastIndexOf($parts, 'providers')
    if ($providerIndex -ge 0 -and $providerIndex + 2 -lt $parts.Count) {
        $types = for ($i = $providerIndex + 2; $i -lt $parts.Count; $i += 2) { $parts[$i] }
        $type = "$($parts[$providerIndex + 1])/$($types -join '/')"
    }
    elseif ($parts -contains 'resourceGroups') {
        $type = 'Microsoft.Resources/resourceGroups'
    }
    else {
        $type = 'unknown'
    }
    [pscustomobject]@{
        Type = ($type -replace '^Microsoft\.', '')
        Name = $parts[-1]
    }
}

# Builds a short description of the key settings of a resource from what-if's "after" state.
function Get-ChangeDetail {
    param($After)
    if ($null -eq $After) { return '' }
    $details = [System.Collections.Generic.List[string]]::new()

    $sku = Get-Value $After 'sku.name'
    if ($sku) { $details.Add("sku $sku") }

    $capacity = Get-Value $After 'sku.capacity'
    if ($capacity) { $details.Add("instances $capacity") }

    $kind = Get-Value $After 'kind'
    if ($kind) { $details.Add($kind) }

    $tier = Get-Value $After 'properties.accessTier'
    if ($tier) { $details.Add("tier $tier") }

    if ((Get-Value $After 'properties.isHnsEnabled') -eq $true) { $details.Add('hierarchical namespace ON') }

    if ((Get-Value $After 'properties.allowSharedKeyAccess') -eq $false) { $details.Add('no shared keys') }

    $softDelete = Get-Value $After 'properties.deleteRetentionPolicy.days'
    if ($softDelete) { $details.Add("soft delete $softDelete days") }

    $publicAccess = Get-Value $After 'properties.publicAccess'
    if ($publicAccess) { $details.Add("public access $publicAccess") }

    $environmentTag = Get-Value $After 'tags.environment'
    if ($environmentTag) { $details.Add("env=$environmentTag") }

    $location = Get-Value $After 'location'
    if ($location) { $details.Add($location) }

    return ($details -join ', ')
}

# Describes a module that what-if could not preview, using storage.json for storage modules.
function Get-ModuleDescription {
    param([string] $DeploymentName)
    switch -Regex ($DeploymentName) {
        '^key-vault$' {
            return 'Key Vault (RBAC, soft delete) + secret external-api-key + Key Vault Secrets User for the app on that secret only'
        }
        '^app-settings$' {
            return 'Web App settings incl. EXTERNAL_API_KEY as a Key Vault reference (applied last)'
        }
        '^avm-app-' {
            return "Web App $($DeploymentName -replace '^avm-', '') - Hello World container, system-assigned managed identity, HTTPS only"
        }
        '^storage-(.+)$' {
            $role = $Matches[1]
            $account = $script:config.storageAccounts | Where-Object { $_.name -eq $role }
            if (-not $account) { return "Storage account '$role'" }
            $hns = if ($account.isHnsEnabled) { ', hierarchical namespace ON' } else { '' }
            $text = "Storage account '$role' (sku $($script:config.skuByEnvironment[$Environment]), tier $($account.accessTier)$hns) + container(s): $($account.containers -join ', ')"
            if ($script:config.appStorageAccess.storageAccount -eq $role) {
                $text += " + Storage Blob Data Contributor for the app on '$($script:config.appStorageAccess.container)' only"
            }
            return $text
        }
        default {
            return 'module could not be previewed'
        }
    }
}

function Get-ShortText {
    param([string] $Text, [int] $MaxLength = 500)
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength) + '...'
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
try {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref] $guid)) {
        throw "SubscriptionId '$SubscriptionId' is not a valid GUID."
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is not installed or not on the PATH.'
    }
    foreach ($file in @($TemplateFile, $ParameterFile)) {
        if (-not (Test-Path -Path $file -PathType Leaf)) {
            throw "File not found: $file"
        }
    }
    $script:config = Get-InfraConfig -ConfigPath $ConfigPath

    $account = Invoke-Az -Arguments @('account', 'show', '--output', 'none')
    if ($account.ExitCode -ne 0) {
        throw 'Not signed in to Azure CLI. Run az login first.'
    }

    $select = Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId)
    if ($select.ExitCode -ne 0) {
        throw "Cannot select subscription '$SubscriptionId' - check that it exists and that you have access."
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-PipelineIssue -Message $_.Exception.Message
    exit 2
}

# ---------------------------------------------------------------------------
# What-if (placeholder key unless a real one is already set)
# ---------------------------------------------------------------------------
$hadKey = Test-Path Env:EXTERNAL_API_KEY
if (-not $hadKey) {
    $env:EXTERNAL_API_KEY = 'placeholder-not-a-secret'
}

try {
    Write-Host "Running what-if for '$Environment' in $Location (this can take a minute)..."

    $whatIf = Invoke-Az -Arguments @(
        'deployment', 'sub', 'what-if',
        '--name', "whatif-$Environment-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))",
        '--location', $Location,
        '--template-file', $TemplateFile,
        '--parameters', $ParameterFile,
        '--no-pretty-print',
        '--only-show-errors',
        '--output', 'json'
    )
}
finally {
    if (-not $hadKey) {
        Remove-Item Env:EXTERNAL_API_KEY -ErrorAction SilentlyContinue
    }
}

if ($whatIf.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($whatIf.StdOut)) {
    $message = "What-if failed: $(Get-ShortText $whatIf.StdErr)"
    Write-Host $message -ForegroundColor Red
    Write-PipelineIssue -Message $message
    exit 1
}

$result = $whatIf.StdOut | ConvertFrom-Json -Depth 100

if ((Get-Value $result 'status') -eq 'Failed') {
    $errorText = Get-Value $result 'error.message'
    if (-not $errorText) { $errorText = 'unknown error' }
    $message = "What-if failed: $(Get-ShortText $errorText)"
    Write-Host $message -ForegroundColor Red
    Write-PipelineIssue -Message $message
    exit 1
}

# ---------------------------------------------------------------------------
# What will be deployed
# ---------------------------------------------------------------------------
$changes = @()
$rawChanges = Get-Value $result 'changes'
if ($rawChanges) {
    $changes = @($rawChanges | ForEach-Object {
            $info = Get-ResourceInfo -ResourceId $_.resourceId
            [pscustomobject]@{
                Change  = $_.changeType
                Type    = $info.Type
                Name    = $info.Name
                Details = Get-ChangeDetail -After (Get-Value $_ 'after')
            }
        })
}

$notPreviewed = @()
$rawDiagnostics = Get-Value $result 'diagnostics'
if ($rawDiagnostics) {
    $notPreviewed = @($rawDiagnostics |
            Where-Object { $_.code -eq 'NestedDeploymentShortCircuited' } |
            ForEach-Object {
                $deploymentName = ((Get-Value $_ 'target') -split '/')[-1]
                [pscustomobject]@{
                    Module = $deploymentName
                    Deploys = Get-ModuleDescription -DeploymentName $deploymentName
                }
            })
}

Write-Host ''
Write-Host "What will be deployed - $Environment ($Location)"
Write-Host ('=' * 70)

Write-Host ''
Write-Host 'Previewed by what-if'
Write-Host '--------------------'
$visible = @($changes | Where-Object { $_.Change -notin @('NoChange', 'Ignore') })
if ($visible.Count -eq 0) {
    Write-Host 'No changes.' -ForegroundColor Green
}
else {
    $visible | Sort-Object Change, Type, Name |
        Format-Table -AutoSize -Wrap Change, Type, Name, Details |
        Out-String -Width 250 | Write-Host
}

if ($notPreviewed.Count -gt 0) {
    Write-Host 'Also deployed - not previewable by what-if'
    Write-Host '------------------------------------------'
    Write-Host '(these modules use values that only exist during the real deployment, e.g. the App Service identity)' -ForegroundColor DarkGray
    $notPreviewed | Sort-Object Module |
        Format-Table -AutoSize -Wrap Module, Deploys |
        Out-String -Width 250 | Write-Host
}

$otherDiagnostics = @()
if ($rawDiagnostics) {
    $otherDiagnostics = @($rawDiagnostics | Where-Object { $_.code -ne 'NestedDeploymentShortCircuited' })
}
if ($otherDiagnostics.Count -gt 0) {
    Write-Host 'Other diagnostics'
    Write-Host '-----------------'
    foreach ($d in $otherDiagnostics) {
        Write-Host ('{0,-35} {1}' -f $d.code, (Get-ShortText -Text "$(Get-Value $d 'message')" -MaxLength 200)) -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Totals
# ---------------------------------------------------------------------------
Write-Host 'Totals'
Write-Host '------'
foreach ($group in $changes | Group-Object Change | Sort-Object Name) {
    Write-Host ('{0,-12} {1}' -f $group.Name, $group.Count)
}
if ($notPreviewed.Count -gt 0) {
    Write-Host ('{0,-12} {1} module(s), see above' -f 'Not previewed', $notPreviewed.Count)
}
Write-Host ''

$deletes = @($changes | Where-Object Change -eq 'Delete')
if ($deletes.Count -gt 0) {
    $message = "$($deletes.Count) resource(s) would be DELETED: $(($deletes.Name | Select-Object -First 5) -join ', ')"
    Write-Host $message -ForegroundColor Yellow
    Write-PipelineIssue -Type warning -Message $message
    if ($FailOnDelete) { exit 1 }
}

Write-Host 'What-if completed. Nothing was deployed.' -ForegroundColor Green
exit 0