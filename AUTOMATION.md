# Additional Automation

## What it does

`scripts/Get-ConfigurationDrift.ps1` compares what is **actually deployed** in an
environment with what is **defined** in `infra/config/storage.json`, and reports the
differences. It is read-only: it never changes anything and never reads secrets.

| Category | Meaning |
| --- | --- |
| Orphaned | Storage account exists in Azure but is no longer in the configuration (or has no `storageRole` tag) |
| Missing | In the configuration, but not deployed |
| Property drift | SKU, access tier, kind, hierarchical namespace, public blob access or shared key access changed (e.g. manually in the portal) |
| Container drift | A configured container is missing, or an extra container exists that is not in the configuration |
| Unmanaged | A resource in the resource group without `managedBy=Bicep` - probably created by hand |

## Why it's useful

The pipeline deploys in **Incremental** mode. That is the safe choice - nothing is
deleted by accident - but it has two blind spots:

- removing a storage account from `storage.json` leaves the old account running (and costing money);
- a setting changed manually in the portal is only noticed at the next deployment, if at all.

`Test-AzureDeployment.ps1` answers *"is everything that should be there, there and correct?"*.
`Get-ConfigurationDrift.ps1` answers the opposite: *"is there anything that shouldn't be there,
or that has changed since it was deployed?"*

Both scripts read the same `storage.json` as Bicep, so there is one definition of
"expected" for deployment, validation and drift detection.

**In the pipeline** it runs after `Test-AzureDeployment.ps1` in every environment
(`pipelines/templates/steps/validate-deployment.yml`):

- findings are reported as **warnings** on the run - drift does not block a release;
- a Markdown report is attached to the run's summary page.

**As a scheduled check**, `-FailOnDrift` returns exit code 1 when drift is found, so a
nightly pipeline (or a manual run) can fail and notify the team.

## How to run it

Prerequisites: PowerShell 7, the Az modules (`Install-Module Az -Scope CurrentUser`),
`Connect-AzAccount`, and Reader access on the resource group.

```powershell
# Report drift for Dev on screen
./scripts/Get-ConfigurationDrift.ps1 `
    -SubscriptionId "<subscription-id>" `
    -ResourceGroupName "rg-hwapp-dev" `
    -Environment "dev"

# Write a Markdown report and return exit code 1 if anything drifted
./scripts/Get-ConfigurationDrift.ps1 `
    -SubscriptionId "<subscription-id>" `
    -ResourceGroupName "rg-hwapp-prod" `
    -Environment "prod" `
    -OutputPath ./drift-prod.md `
    -FailOnDrift
```

Full help: `Get-Help ./scripts/Get-ConfigurationDrift.ps1 -Full`

| Exit code | Meaning |
| --- | --- |
| 0 | No drift (or drift found without `-FailOnDrift`) |
| 1 | Drift found and `-FailOnDrift` was used |
| 2 | Could not run - invalid subscription, not signed in, missing configuration or resource group |

Quick self-test without any Azure resources - prints an "is not a valid GUID" error and returns 2:

```powershell
./scripts/Get-ConfigurationDrift.ps1 -SubscriptionId "not-a-guid" -ResourceGroupName "rg-hwapp-dev" -Environment "dev"
$LASTEXITCODE
```

## Sample output

```text
Configuration drift report - dev (rg-hwapp-dev)
============================================================

Category        Resource                        Detail
--------        --------                        ------
Container drift sthwappdevhota1b2c/temp-upload  container is not in the configuration
Orphaned        sthwappdevarchivea1b2c          role 'archive' is no longer in the configuration - remove it or add it back to storage.json
Property drift  sthwappdevcolda1b2c             accessTier: actual Hot, expected Cool

3 drift finding(s).
```

No drift:

```text
Configuration drift report - dev (rg-hwapp-dev)
============================================================
No drift detected. Deployed state matches the configuration.
```

## Validation script - quick reference

`scripts/Test-AzureDeployment.ps1` (README §3.1) runs automatically after every
environment deployment. A failure fails the stage, so later environments never run.

```powershell
./scripts/Test-AzureDeployment.ps1 `
    -SubscriptionId "<subscription-id>" `
    -ResourceGroupName "rg-hwapp-dev" `
    -Environment "dev"
```

Example output with one failure:

```text
Resource Group
--------------
rg-hwapp-dev           OK

Storage Accounts
----------------
cold                   OK
standard               OK
hot                    OK
datalake               FAIL - hierarchical namespace is disabled

Blob Containers
---------------
cold-data              OK
standard-data          OK
hot-data               OK
raw-data               OK

Key Vault
---------
exists                 OK - kv-hwapp-dev-a1b2c
rbac authorization     OK
soft delete            OK
secret                 OK - external-api-key

App Service
-----------
exists                 OK - app-hwapp-dev-a1b2c
managed identity       OK
container image        OK
key vault reference    OK
secret access          OK
storage access         OK
least privilege        OK

Tags
----
environment            OK
application            OK
owner                  OK
managedBy              OK

Validation failed: 1 of 24 checks failed.
```

| Exit code | Meaning |
| --- | --- |
| 0 | All checks passed |
| 1 | One or more checks failed |
| 2 | Could not run - invalid subscription, not signed in, missing configuration |