# Security Considerations

## Secret handling

### Where the `external-api-key` value lives

| Environment | Stored in | Variable |
| --- | --- | --- |
| Dev | Azure DevOps variable group `vg-hwapp-dev` | `externalApiKey` (marked secret) |
| Test | Azure DevOps variable group `vg-hwapp-test` | `externalApiKey` (marked secret) |
| Prod | Azure DevOps variable group `vg-hwapp-prod` | `externalApiKey` (marked secret) |

The values are entered once in **Pipelines > Library > Variable groups** and marked as
secret (lock icon). They never appear in the repository, in YAML, or in a parameter file.
Each variable group can optionally be linked to an existing Key Vault instead of holding
the value itself - the pipeline does not change.

A variable group was chosen over **Secure files** on purpose: secure files are meant for
whole files (certificates, keystores) and are downloaded to the agent's disk as plain
files. A secret variable is encrypted, masked in logs and never written to disk.

### How the value reaches Key Vault

```text
vg-hwapp-<env> (secret)
  -> deploy job only                (variable group linked to the deployment job, not the stage)
  -> EXTERNAL_API_KEY env variable  (mapped explicitly into ONE step: bicep-deploy.yml)
  -> readEnvironmentVariable()      (infra/parameters/<env>.bicepparam)
  -> @secure() param externalApiKey (main.bicep)
  -> @secure() param secretValue    (modules/key-vault.bicep -> AVM key-vault)
  -> Key Vault secret external-api-key
```

The App Service never receives the value. Its app setting contains only a reference:

```text
EXTERNAL_API_KEY = @Microsoft.KeyVault(SecretUri=https://kv-hwapp-<env>-xxxxx.vault.azure.net/secrets/external-api-key)
```

App Service resolves the reference at runtime with its system-assigned managed identity.

### How the pipeline avoids exposing the secret

- **Masking:** Azure DevOps replaces secret variable values with `***` in all logs.
- **Not mapped automatically:** secret variables are not available to scripts unless
  mapped explicitly. It is mapped into exactly one step (`bicep-deploy.yml`) via `env:`.
- **Never on a command line:** the value is passed as an environment variable, not as an
  argument, so it cannot appear in command echo or process lists.
- **`@secure()` parameters:** ARM does not store secure parameter values in deployment
  history, does not show them in what-if, and does not return them from
  `az deployment ... show`.
- **No output:** `az deployment sub create --output none`; no Bicep output contains the
  secret. The linter rules `outputs-should-not-contain-secrets`, `secure-secrets-in-params`,
  `secure-parameter-default` and `use-secure-value-for-secure-inputs` are set to **error**
  in `infra/bicepconfig.json`, so the pipeline fails if a change would leak it.
- **No debug logging:** no `set -x`, `--debug` or `system.debug` in the YAML.
- **Real key only where needed:** the Validate stage, what-if jobs and PR validation use a
  dummy value (`placeholder-not-a-secret`). The real key is only loaded in the deployment job.
- **Fail fast:** if the variable group is missing or empty, the deploy step stops with a
  clear error before anything is deployed, instead of storing an empty secret.
- **Validation script:** `Test-AzureDeployment.ps1` checks that the secret exists through
  the Azure management API (`GET .../vaults/<kv>/secrets/external-api-key`), which returns
  metadata only. The value is never retrieved, so it cannot be printed or logged. Errors are
  shortened to a safe message without request/response details.

### Local deployments

For a local test the key is set only for the current terminal session and removed
afterwards - it is never written to a file:

```powershell
$env:EXTERNAL_API_KEY = Read-Host -Prompt 'API key' -MaskInput
# az deployment sub create ...
Remove-Item Env:EXTERNAL_API_KEY
```

`.gitignore` additionally excludes `.env` and `*.secret` files as a safety net.

## Identity & access

### App Service

- Uses a **system-assigned managed identity**. No connection strings, storage account
  keys, client secrets or SAS tokens are used anywhere.
- Minimum permissions, created by the AVM modules and scoped as narrowly as Azure allows:

| Need | Role | Scope |
| --- | --- | --- |
| Read the API key | Key Vault Secrets User | the `external-api-key` **secret** only |
| Use the designated storage | Storage Blob Data Contributor | the `standard-data` **container** only |

- The identity has **no** access to the other secrets, the other containers, the other
  three storage accounts, or the resource group itself.
- Management roles (Key Vault Reader, Storage Account Contributor) are deliberately not
  used: they allow changing resource settings but are not needed to read secrets or blobs.
- `allowSharedKeyAccess: false` on every storage account: account keys cannot be used even
  if someone obtains them. Entra ID (managed identity + RBAC) replaces them.
- `Test-AzureDeployment.ps1` verifies both role assignments **and** that the identity has
  nothing assigned at resource group scope or higher.

### Pipeline (service connection `sc-hwapp`)

- One Azure Resource Manager service connection, `sc-hwapp`, scoped to the CoE-RnD
  subscription and using **workload identity federation** - no client secret is stored
  in Azure DevOps and nothing expires or needs rotating.
- Subscription scope is required because the template creates the resource groups itself.
- Roles for the service connection's identity:
  - **Contributor** - create the resource groups and resources;
  - **Role Based Access Control Administrator**, with a condition that only allows
    assigning *Key Vault Secrets User* and *Storage Blob Data Contributor* - needed for the
    App Service's role assignments. Full User Access Administrator or Owner is not needed
    and not requested.
- Only one subscription is available for the assignment, so the same identity deploys
  Dev, Test and Prod. Prod is protected by the pipeline instead (see below). With separate
  subscriptions I would use one service connection per environment.

## Key Vault

- **Azure RBAC**, not access policies: access is granted per secret, and assignments are
  visible and auditable in IAM like any other Azure permission.
- **Soft delete** always on: 7 / 30 / 90 days for Dev / Test / Prod.
- **Purge protection on in Prod only.** It cannot be disabled once enabled. In Dev and Test
  vaults must be easy to remove and recreate with the same name.
- `enabledForDeployment`, `enabledForTemplateDeployment` and `enabledForDiskEncryption`
  are off - VMs, ARM templates and disk encryption cannot pull secrets from this vault.
- Standard SKU - no HSM-backed keys are needed for a single API key.

## Network exposure

| Resource | Exposure | Controls |
| --- | --- | --- |
| Storage accounts | Public endpoint | HTTPS only, TLS 1.2, **no anonymous blob access**, **no shared keys** - Entra ID authentication required |
| Key Vault | Public endpoint | RBAC - only identities with a role can read the secret |
| App Service | Public (it is the web app) | HTTPS only, TLS 1.2, FTP/FTPS disabled, basic-auth publishing credentials (FTP + SCM) disabled |

Public endpoints are an accepted assumption for this assignment (no networking was
requested). For production see the last section.

## Pipeline security

- **No secrets in YAML:** credentials come from the service connection, the API key from
  secret variable groups.
- **Variable groups are linked to the deployment job only**, not to the stage or pipeline,
  so the Validate stage and what-if jobs never receive the key.
- **Production approval:** the deployment job targets the Azure DevOps environment
  `hwapp-prod`, which has an **Approvals** check. The job waits for approval before it
  starts - no agent runs and no secret is loaded until someone approves.
- **Prod only after Test succeeded:** each stage depends on the previous one with
  `succeeded()`, including the post-deployment validation. A failed Dev or Test deployment
  or validation means Prod never starts.
- **Deploy from `main` only:** feature branches and pull requests run validation only.
- **`extends` templates:** both pipelines extend one shared template, which limits what a
  pipeline definition can do.
- **Authorisation:** the service connection and the `vg-hwapp-*` variable groups are
  authorised for these pipelines only (no "grant access permission to all pipelines").
- **Pull requests from forks:** Azure Pipelines does not make secrets available to fork
  builds by default, and PR validation does not need any secrets.

## Things I'd do differently for production

- **Private endpoints** for Storage and Key Vault, VNet integration for the App Service,
  and `publicNetworkAccess: 'Disabled'` on Storage and Key Vault.
- **Separate subscriptions** and service connections per environment, so the Dev identity
  cannot touch Prod.
- **Diagnostic settings** to Log Analytics for Key Vault (audit secret reads) and Storage.
- **Secret rotation** through Key Vault (rotation policy / Event Grid) instead of a
  pipeline variable, and no rewrite of the secret on every deployment.
- Pin the container image to a **digest** instead of `:latest`.
- A **`CanNotDelete` resource lock** on the Prod resource group.
- **Azure Policy** to enforce required tags and deny public blob access across the subscription.
- Zone-redundant or geo-redundant storage (ZRS/GRS) for Prod.