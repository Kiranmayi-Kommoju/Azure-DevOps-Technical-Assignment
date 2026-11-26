#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage, Az.KeyVault, Az.Websites
<#
.SYNOPSIS
    Validates the infrastructure deployed by infra/main.bicep.

.DESCRIPTION
    Checks the Resource Group, Storage Accounts (and their configuration),
    Blob Containers, Key Vault, the external-api-key secret, the App Service
    identity / Key Vault reference, role assignments and required tags.

    All checks are run and reported - the script does not stop at the first
    failure. Expected values come from infra/config/storage.json (the same
    file Bicep uses), so nothing environment specific is hardcoded here.

    The secret VALUE is never read. Existence is checked through the ARM
    control plane, which does not return secret values.

    Exit codes:
      0 - all checks passed
      1 - one or more checks failed
      2 - could not run (bad subscription, no Azure context, missing config)

.EXAMPLE
    Connect-AzAccount
    ./scripts/Test-AzureDeployment.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroupName "rg-hwapp-dev" `
        -Environment "dev"
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

    [string[]] $RequiredTags = @('environment', 'application', 'owner', 'managedBy'),

    [string] $SecretName = 'external-api-key'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Never let -Debug turn on HTTP body logging in this script.
$DebugPreference = 'SilentlyContinue'

Import-Module (Join-Path $PSScriptRoot 'common' 'InfraHelpers.psm1') -Force

# Role definition ids (built-in roles)
$KeyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
$StorageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string] $Section,
        [string] $Item,
        [bool]   $Passed,
        [string] $Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
            Section = $Section
            Item    = $Item
            Passed  = $Passed
            Detail  = $Detail
        })
}

function Write-Summary {
    $sections = $script:Results | Select-Object -ExpandProperty Section -Unique
    foreach ($section in $sections) {
        Write-Host ''
        Write-Host $section
        Write-Host ('-' * $section.Length)
        foreach ($r in $script:Results | Where-Object Section -eq $section) {
            $status = if ($r.Passed) { 'OK' } else { 'FAIL' }
            $line = '{0,-22} {1}' -f $r.Item, $status
            if ($r.Detail) { $line += " - $($r.Detail)" }

            if ($r.Passed) {
                Write-Host $line -ForegroundColor Green
            }
            else {
                Write-Host $line -ForegroundColor Red
                Write-PipelineIssue -Message "[$section] $($r.Item): $($r.Detail)"
            }
        }
    }

    $failed = @($script:Results | Where-Object { -not $_.Passed }).Count
    $total = $script:Results.Count
    Write-Host ''
    if ($failed -eq 0) {
        Write-Host "Validation passed: $total checks OK." -ForegroundColor Green
    }
    else {
        Write-Host "Validation failed: $failed of $total checks failed." -ForegroundColor Red
    }
    return $failed
}

Write-Host "Validating environment '$Environment' in resource group '$ResourceGroupName'"

# ---------------------------------------------------------------------------
# Pre-checks: config + subscription. If these fail there is nothing to validate.
# ---------------------------------------------------------------------------
try {
    $config = Get-InfraConfig -ConfigPath $ConfigPath
    if ($config.skuByEnvironment.Keys -notcontains $Environment) {
        throw "Environment '$Environment' is not defined in skuByEnvironment of $ConfigPath."
    }
    $expectedSku = $config.skuByEnvironment[$Environment]

    Connect-InfraSubscription -SubscriptionId $SubscriptionId
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-PipelineIssue -Message $_.Exception.Message
    exit 2
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
$resourceGroup = $null
try {
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
    Add-Result 'Resource Group' $ResourceGroupName $true
}
catch {
    Add-Result 'Resource Group' $ResourceGroupName $false (Get-SafeErrorMessage $_)
    # Without the RG every other check would just repeat "not found".
    $null = Write-Summary
    exit 1
}

# ---------------------------------------------------------------------------
# Storage Accounts + configuration
# Accounts are matched by their 'storageRole' tag, so the script does not
# need to know the generated (globally unique) names.
# ---------------------------------------------------------------------------
$deployedAccounts = @{}
try {
    foreach ($sa in Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop) {
        if ($sa.Tags -and $sa.Tags.ContainsKey('storageRole')) {
            $deployedAccounts[$sa.Tags['storageRole']] = $sa
        }
    }
}
catch {
    Add-Result 'Storage Accounts' 'list' $false (Get-SafeErrorMessage $_)
}

foreach ($expected in $config.storageAccounts) {
    $role = $expected.name
    if (-not $deployedAccounts.ContainsKey($role)) {
        Add-Result 'Storage Accounts' $role $false 'storage account not found'
        continue
    }

    $sa = $deployedAccounts[$role]
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($sa.Kind -ne $expected.kind) { $problems.Add("kind is $($sa.Kind), expected $($expected.kind)") }
    if ($sa.Sku.Name -ne $expectedSku) { $problems.Add("sku is $($sa.Sku.Name), expected $expectedSku") }
    if ("$($sa.AccessTier)" -ne $expected.accessTier) { $problems.Add("access tier is $($sa.AccessTier), expected $($expected.accessTier)") }
    if ([bool]$sa.EnableHierarchicalNamespace -ne [bool]$expected.isHnsEnabled) {
        $state = if ($sa.EnableHierarchicalNamespace) { 'enabled' } else { 'disabled' }
        $problems.Add("hierarchical namespace is $state")
    }
    if (-not $sa.EnableHttpsTrafficOnly) { $problems.Add('https-only is disabled') }
    if ($sa.AllowBlobPublicAccess) { $problems.Add('public blob access is allowed') }
    if ($sa.MinimumTlsVersion -ne 'TLS1_2') { $problems.Add("min TLS is $($sa.MinimumTlsVersion)") }
    if ($sa.AllowSharedKeyAccess -ne $false) { $problems.Add('shared key access is enabled') }

    Add-Result 'Storage Accounts' $role ($problems.Count -eq 0) ($problems -join '; ')
}

# ---------------------------------------------------------------------------
# Blob Containers (control plane - no account keys needed)
# ---------------------------------------------------------------------------
foreach ($expected in $config.storageAccounts) {
    foreach ($containerName in $expected.containers) {
        if (-not $deployedAccounts.ContainsKey($expected.name)) {
            Add-Result 'Blob Containers' $containerName $false "storage account '$($expected.name)' not found"
            continue
        }
        try {
            $null = Get-AzRmStorageContainer -ResourceGroupName $ResourceGroupName `
                -StorageAccountName $deployedAccounts[$expected.name].StorageAccountName `
                -Name $containerName -ErrorAction Stop
            Add-Result 'Blob Containers' $containerName $true
        }
        catch {
            Add-Result 'Blob Containers' $containerName $false (Get-SafeErrorMessage $_)
        }
    }
}

# ---------------------------------------------------------------------------
# Key Vault + secret
# ---------------------------------------------------------------------------
$vault = $null
try {
    $vaults = @(Get-AzKeyVault -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    if ($vaults.Count -eq 0) {
        Add-Result 'Key Vault' 'exists' $false 'no key vault in resource group'
    }
    elseif ($vaults.Count -gt 1) {
        Add-Result 'Key Vault' 'exists' $false "expected 1 key vault, found $($vaults.Count)"
    }
    else {
        $vault = Get-AzKeyVault -VaultName $vaults[0].VaultName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        Add-Result 'Key Vault' 'exists' $true $vault.VaultName
        Add-Result 'Key Vault' 'rbac authorization' ([bool]$vault.EnableRbacAuthorization) $(if (-not $vault.EnableRbacAuthorization) { 'vault uses access policies' })
        Add-Result 'Key Vault' 'soft delete' ([bool]$vault.EnableSoftDelete) $(if (-not $vault.EnableSoftDelete) { 'soft delete disabled' })
    }
}
catch {
    Add-Result 'Key Vault' 'exists' $false (Get-SafeErrorMessage $_)
}

if ($vault) {
    # ARM GET on the secret returns metadata only - the value is never part of the response.
    # The response body is not printed anywhere.
    try {
        $response = Invoke-AzRestMethod -Method GET -Path "$($vault.ResourceId)/secrets/$($SecretName)?api-version=2023-07-01" -ErrorAction Stop
        switch ($response.StatusCode) {
            200 { Add-Result 'Key Vault' 'secret' $true $SecretName }
            404 { Add-Result 'Key Vault' 'secret' $false "$SecretName not found" }
            403 { Add-Result 'Key Vault' 'secret' $false 'insufficient permissions' }
            default { Add-Result 'Key Vault' 'secret' $false "unexpected status $($response.StatusCode)" }
        }
    }
    catch {
        Add-Result 'Key Vault' 'secret' $false (Get-SafeErrorMessage $_)
    }
    finally {
        Remove-Variable -Name response -ErrorAction SilentlyContinue
    }
}
else {
    Add-Result 'Key Vault' 'secret' $false 'key vault not available'
}

# ---------------------------------------------------------------------------
# App Service: identity, Key Vault reference, least-privilege role assignments
# ---------------------------------------------------------------------------
try {
    $apps = @(Get-AzWebApp -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    if ($apps.Count -ne 1) {
        Add-Result 'App Service' 'exists' $false "expected 1 web app, found $($apps.Count)"
    }
    else {
        $app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $apps[0].Name -ErrorAction Stop
        Add-Result 'App Service' 'exists' $true $app.Name

        $hasMsi = $app.Identity -and "$($app.Identity.Type)" -match 'SystemAssigned'
        Add-Result 'App Service' 'managed identity' $hasMsi $(if (-not $hasMsi) { 'system-assigned identity not enabled' })

        $image = $app.SiteConfig.LinuxFxVersion
        Add-Result 'App Service' 'container image' ($image -match 'aci-helloworld') $(if ($image -notmatch 'aci-helloworld') { 'hello world image not configured' })

        # Only check the FORMAT of the setting - it must be a Key Vault reference.
        $setting = $app.SiteConfig.AppSettings | Where-Object Name -eq 'EXTERNAL_API_KEY'
        $isKvRef = $setting -and $setting.Value -match '^@Microsoft\.KeyVault\('
        Add-Result 'App Service' 'key vault reference' ([bool]$isKvRef) $(if (-not $isKvRef) { 'EXTERNAL_API_KEY is missing or not a Key Vault reference' })
        Remove-Variable -Name setting -ErrorAction SilentlyContinue

        if ($hasMsi) {
            $principalId = $app.Identity.PrincipalId
            $path = "$($resourceGroup.ResourceId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$principalId'"
            $raResponse = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
            if ($raResponse.StatusCode -ne 200) {
                Add-Result 'App Service' 'role assignments' $false "could not read role assignments (status $($raResponse.StatusCode))"
            }
            else {
                $assignments = @(($raResponse.Content | ConvertFrom-Json).value)

                $kvAssignment = $assignments | Where-Object {
                    $_.properties.roleDefinitionId -like "*$KeyVaultSecretsUserRoleId" -and
                    $_.properties.scope -like "*/secrets/$SecretName"
                }
                Add-Result 'App Service' 'secret access' ([bool]$kvAssignment) $(if (-not $kvAssignment) { 'Key Vault Secrets User on the secret is missing' })

                $container = $config.appStorageAccess.container
                $storageAssignment = $assignments | Where-Object {
                    $_.properties.roleDefinitionId -like "*$StorageBlobDataContributorRoleId" -and
                    $_.properties.scope -like "*/containers/$container"
                }
                Add-Result 'App Service' 'storage access' ([bool]$storageAssignment) $(if (-not $storageAssignment) { "Storage Blob Data Contributor on '$container' is missing" })

                # Anything assigned at RG level or above is broader than we want.
                $rgScope = $resourceGroup.ResourceId.ToLowerInvariant()
                $broad = $assignments | Where-Object { $rgScope.StartsWith($_.properties.scope.ToLowerInvariant()) }
                Add-Result 'App Service' 'least privilege' (-not $broad) $(if ($broad) { 'identity has role assignments at resource group scope or higher' })
            }
        }
    }
}
catch {
    Add-Result 'App Service' 'exists' $false (Get-SafeErrorMessage $_)
}

# ---------------------------------------------------------------------------
# Tags - resource group + every resource in it
# ---------------------------------------------------------------------------
try {
    $taggable = @([pscustomobject]@{ Name = $resourceGroup.ResourceGroupName; Tags = $resourceGroup.Tags })
    $taggable += @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
            Select-Object Name, Tags)

    foreach ($tag in $RequiredTags) {
        $missing = @($taggable | Where-Object { -not $_.Tags -or -not $_.Tags.ContainsKey($tag) -or [string]::IsNullOrWhiteSpace($_.Tags[$tag]) })
        $detail = ''
        if ($missing.Count -gt 0) {
            $detail = "missing on $($missing.Count) resource(s): $(($missing.Name | Select-Object -First 5) -join ', ')"
        }
        elseif ($tag -eq 'environment') {
            $wrong = @($taggable | Where-Object { $_.Tags[$tag] -ne $Environment })
            if ($wrong.Count -gt 0) {
                $detail = "value is not '$Environment' on: $(($wrong.Name | Select-Object -First 5) -join ', ')"
            }
        }
        Add-Result 'Tags' $tag (-not $detail) $detail
    }
}
catch {
    Add-Result 'Tags' 'read tags' $false (Get-SafeErrorMessage $_)
}

# ---------------------------------------------------------------------------
$failedCount = Write-Summary
exit ([int]($failedCount -gt 0))