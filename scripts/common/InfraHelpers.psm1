#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the infrastructure scripts (validation + drift report).
.NOTES
    Nothing in here reads or prints secret values.
#>

Set-StrictMode -Version Latest

function Get-InfraConfig {
    <#
    .SYNOPSIS
        Loads infra/config/storage.json - the same file Bicep uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    try {
        return Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Configuration file '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-SafeErrorMessage {
    <#
    .SYNOPSIS
        Turns an Azure error into a short, readable message.
        Only the exception message is used (no request/response dumps,
        which could contain tokens or payloads).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message

    switch -Regex ($message) {
        'AuthorizationFailed|Forbidden|does not have authorization|\b403\b' {
            return 'insufficient permissions'
        }
        'ResourceGroupNotFound|could not be found|NotFound|\b404\b' {
            return 'not found'
        }
        'SubscriptionNotFound|InvalidSubscriptionId|subscription .* (not found|doesn''t exist)' {
            return 'subscription not found or not accessible'
        }
    }

    # Keep the first line only and cap the length so we never dump big payloads.
    $firstLine = ($message -split "`r?`n")[0]
    if ($firstLine.Length -gt 200) {
        $firstLine = $firstLine.Substring(0, 200) + '...'
    }
    return "unexpected error: $firstLine"
}

function Connect-InfraSubscription {
    <#
    .SYNOPSIS
        Selects the target subscription. Works locally (Connect-AzAccount first)
        and in Azure DevOps (AzurePowerShell task already signed in).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $guid = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref] $guid)) {
        throw "SubscriptionId '$SubscriptionId' is not a valid GUID."
    }

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount first (or use the AzurePowerShell task in the pipeline).'
    }

    try {
        $null = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch {
        throw "Cannot select subscription '$SubscriptionId': $(Get-SafeErrorMessage -ErrorRecord $_)"
    }
}

function Write-PipelineIssue {
    <#
    .SYNOPSIS
        Writes an Azure DevOps warning/error annotation when running in a pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [ValidateSet('error', 'warning')]
        [string] $Type = 'error'
    )

    if ($env:TF_BUILD) {
        Write-Host "##vso[task.logissue type=$Type]$Message"
    }
}

Export-ModuleMember -Function Get-InfraConfig, Get-SafeErrorMessage, Connect-InfraSubscription, Write-PipelineIssue