# Design Notes

## Repository layout

```text
infra/
  main.bicep                  subscription-scope entry point (creates the RG, wires the modules)
  bicepconfig.json            linter rules - security rules set to "error"
  config/storage.json         storage accounts + containers - read by Bicep AND by the scripts
  modules/                    thin wrappers around Azure Verified Modules (AVM)
    storage-account.bicep     AVM storage-account + containers + container-scoped role assignment
    key-vault.bicep           AVM key-vault + secret + secret-scoped role assignment
    app-service.bicep         AVM serverfarm + AVM web/site (system-assigned identity)
    app-settings.bicep        app settings incl. the Key Vault reference (applied last)
  parameters/{dev,test,prod}.bicepparam
pipelines/
  azure-pipelines.yml         CI/CD on main: Validate -> Dev -> Test -> Prod
  pr-validation.yml           PR checks only (build, lint, what-if) - never deploys
  templates/pipeline.yml      environment list, defined once
  templates/stages/           validate.yml, deploy.yml (reused for every environment)
  templates/steps/            build/lint, what-if, deploy, post-deployment validation
scripts/
  Test-AzureDeployment.ps1    post-deployment validation (README §3.1)
  Get-ConfigurationDrift.ps1  additional automation (README §3.8)
  common/InfraHelpers.psm1    shared helpers
```

## Naming convention

Pattern: `<type>-<workload>-<env>[-<suffix>]`, workload = `hwapp`.

| Resource | Example (dev) | Notes |
| --- | --- | --- |
| Resource Group | `rg-hwapp-dev` | |
| Key Vault | `kv-hwapp-dev-a1b2c` | globally unique, max 24 characters |
| App Service Plan | `asp-hwapp-dev` | |
| Web App | `app-hwapp-dev-a1b2c` | globally unique host name |
| Storage Account | `sthwappdevdatalakea1b2c` | see below |
| Service connection | `sc-hwapp` | one for all environments (single subscription) |
| Azure DevOps environment | `hwapp-dev` | approvals/checks are configured here |
| Variable group | `vg-hwapp-dev` | holds the secret `externalApiKey` |

- `suffix` = first 5 characters of `uniqueString(subscriptionId, workload, environment)`.
  It is deterministic, so every run produces the same names (re-deployments update
  instead of creating new resources), but names never clash across subscriptions or environments.
- Storage account names must be 3-24 lowercase alphanumeric characters. The name is built as
  `st` + workload + environment + logical name (`cold`, `standard`, `hot`, `datalake`),
  **truncated to 19 characters**, followed by the 5-character suffix. The result is always
  <= 24 characters and the suffix is never cut off. This is implemented once, as a Bicep
  user-defined function `storageAccountName()` in `main.bicep`.
- `workload` is limited to 8 characters (`@maxLength`) so Key Vault names stay valid.
- Every storage account gets a `storageRole` tag (`cold`, `hot`, ...). The PowerShell scripts
  find accounts by this tag, so they never need to know or rebuild the generated names.

## Resource group strategy

One resource group per environment: `rg-hwapp-dev`, `rg-hwapp-test`, `rg-hwapp-prod`,
created by the template itself (`targetScope = 'subscription'`).

- Clear blast radius and simple clean-up per environment.
- Access for people can be scoped per environment.
- Only one subscription (CoE-RnD) is available for this assignment, so all three resource
  groups live in it and are deployed through **one** Azure DevOps service connection,
  `sc-hwapp` (subscription scope, workload identity federation). The template does not
  depend on that: pointing an environment at a different subscription only means using a
  different service connection in `pipelines/templates/pipeline.yml`.

## Configuration-driven resource loops

`infra/config/storage.json` is the single source of truth for storage:

```json
{
  "skuByEnvironment": { "dev": "Standard_LRS", "test": "Standard_LRS", "prod": "Standard_LRS" },
  "storageAccounts": [
    { "name": "cold", "kind": "StorageV2", "accessTier": "Cool", "isHnsEnabled": false, "containers": [ "cold-data" ] },
    ...
  ],
  "appStorageAccess": { "storageAccount": "standard", "container": "standard-data" }
}
```

- `main.bicep` loads it with `loadJsonContent()` and **loops** over `storageAccounts`,
  calling `modules/storage-account.bicep` once per entry - no duplicated resource blocks.
- Containers are a list per account and are created with `map()` inside the module.
- **Adding a storage account = adding one JSON object.** No new Bicep code.
- `appStorageAccess` defines the one container the App Service may use; only that
  container gets a role assignment.
- `Test-AzureDeployment.ps1` and `Get-ConfigurationDrift.ps1` read the **same file**, so
  the "expected configuration" in the scripts cannot drift away from what Bicep deploys.

How the accounts differ:

| Name | Access tier | Hierarchical namespace | Container |
| --- | --- | --- | --- |
| cold | Cool | no | cold-data |
| standard | Hot (standard general purpose) | no | standard-data |
| hot | Hot | no | hot-data |
| datalake | Hot | **yes** (ADLS Gen2) | raw-data |

## Azure Verified Modules (AVM)

Storage, Key Vault, App Service Plan and Web App use AVM from the public Bicep registry
(`br/public:avm/res/...`), pinned to a specific version.

- AVM gives a tested, Microsoft-maintained implementation of each resource.
- Each AVM module is wrapped in a small local module. The wrapper enforces this
  project's defaults (no public blob access, no shared keys, TLS 1.2, RBAC on Key Vault,
  FTP/basic auth off) and keeps `main.bicep` independent of the AVM interface - upgrading
  an AVM version only touches one wrapper.
- `app-settings.bicep` is plain Bicep because it is a single small resource.

## Key Vault access model

Azure RBAC (`enableRbacAuthorization: true`), not access policies:

- Same permission model as the rest of Azure; assignments are visible and auditable in IAM.
- Access can be granted **below vault level**. Access policies would give "get" on every
  secret in the vault.

Role assignments for the App Service's system-assigned managed identity, created by the AVM
modules themselves:

| Need | Role | Scope |
| --- | --- | --- |
| Read the API key | Key Vault Secrets User | the `external-api-key` **secret** only |
| Use the designated storage | Storage Blob Data Contributor | the `standard-data` **container** only |

**Deployment order.** The identity must exist before it can be granted access, and the app
settings need the secret URI. To avoid a circular dependency the order is:

1. App Service (creates the managed identity)
2. Key Vault + secret and Storage accounts - role assignments for the identity
3. App settings (`app-settings.bicep`) - applied last, so the Key Vault reference
   resolves on the app's first start

## Environment differences

| | Dev | Test | Prod |
| --- | --- | --- | --- |
| Resource group | rg-hwapp-dev | rg-hwapp-test | rg-hwapp-prod |
| Service connection | sc-hwapp | sc-hwapp | sc-hwapp |
| Azure DevOps environment | hwapp-dev | hwapp-test | hwapp-prod |
| Variable group (secret) | vg-hwapp-dev | vg-hwapp-test | vg-hwapp-prod |
| Storage SKU | Standard_LRS | Standard_LRS | Standard_LRS (see assumptions) |
| App Service Plan | B1 | B1 | P0v3 |
| Key Vault soft delete retention | 7 days | 30 days | 90 days |
| Key Vault purge protection | off | off | **on** |
| Manual approval before deploy | no | no | **yes** (environment check) |
| External API key | own secret | own secret | own secret |

Where the values live:

- **Bicep values:** `infra/parameters/<env>.bicepparam` plus `skuByEnvironment` in `storage.json`.
- **Pipeline values** (service connection / subscription, region, Azure DevOps environment,
  variable group): the `environments` list in `pipelines/templates/pipeline.yml`, defined once.
  The region is passed as the deployment `--location` and picked up by `deployment().location`.
- **Secret:** one Azure DevOps variable group per environment (see SECURITY.md).

## Deployment safety (README §1.7)

- **Running the deployment again:** Incremental mode, deterministic names and deterministic
  role assignment names mean a second run changes nothing (except a new secret version, see
  limitations).
- **One storage account changes:** only that account's module deployment changes. What-if
  shows the exact property before every environment is deployed.
- **New storage account:** a new JSON entry creates a new module instance; existing
  accounts are untouched.
- **Existing resource changes:** shown by what-if in the Validate stage and again before
  each environment. Changes Azure cannot make in place (for example enabling hierarchical
  namespace on an existing account) fail the deployment instead of silently recreating it.
- **Removing an account from config** does not delete it (Incremental mode).
  `Get-ConfigurationDrift.ps1` reports it as orphaned so it can be removed deliberately.
- **Prod is gated:** it only runs after Dev and Test deployed and validated successfully,
  and after a manual approval.
- Soft delete on blobs and containers; purge protection on the Prod Key Vault.

## Assumptions

- One subscription (CoE-RnD) for all three environments; one resource group each and one
  service connection (`sc-hwapp`).
- Region `westeurope` for all environments (configurable per environment in `pipeline.yml`).
- Storage uses **Standard_LRS in every environment** to keep the cost of this assignment
  low. A real production setup would use ZRS or GRS for Prod - a one-word change in
  `storage.json`.
- Storage, Key Vault and App Service keep public endpoints; no VNet or private endpoints
  were requested. Storage and Key Vault still require Entra ID authentication.
- The Hello World image listens on port 80 (`WEBSITES_PORT=80`).
- The "designated" storage for the app is the `standard` account / `standard-data`
  container (configurable in `storage.json`).
- Storage Blob Data **Contributor** (read + write) is the minimum useful role for an app
  that uses a container. If the app only needs to read, Storage Blob Data Reader is enough.
- Shared key access is disabled on all storage accounts because nothing needs account keys.
- No lifecycle-management or retention policies on storage (not requested).
- Deployments only happen from `main`; feature branches and pull requests only run validation.

## Known limitations / what I'd do with more time

- Each deployment writes the secret again, so Key Vault gets a new secret version on every
  run. Better: only update the secret when the value changes, or manage rotation outside Bicep.
- One service connection deploys all three environments, so the same identity can change
  Dev and Prod. Prod is protected by the pipeline (approval, Dev/Test must pass); with
  separate subscriptions I would use one service connection per environment.
- No private endpoints, VNet integration, Application Insights or diagnostic settings.
- No resource lock on the Prod resource group.
- `app-settings.bicep` sets the complete app settings collection - any setting added
  manually in the portal is overwritten on the next deployment (intended, but worth knowing).
- AVM modules are pinned to a version; upgrades need to be done deliberately (could be
  automated with Dependabot/Renovate).
- What-if output can be noisy for some properties (known ARM behaviour).
- No Pester unit tests for the scripts yet - only PSScriptAnalyzer in the pipeline.