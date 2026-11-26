// Entry point for the infrastructure deployment.
// Deployed at subscription scope so the Resource Group is part of the template
// and every environment (dev/test/prod) is created exactly the same way.
//
//   az deployment sub create --location <region> \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters/dev.bicepparam
//
// Deployment order (derived from module outputs):
//   Resource Group -> App Service (identity) -> Key Vault + Storage (role assignments)
//   -> App Settings (Key Vault reference resolves on first start)

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters (environment specific values live in ./parameters/*.bicepparam)
// ---------------------------------------------------------------------------

@description('Environment name. Drives naming, tags and SKU selection.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

@description('Short workload name, lowercase letters/digits only. Used in every resource name.')
@minLength(2)
@maxLength(8)
param workload string

@description('Azure region. Defaults to the location of the deployment itself (set by the pipeline).')
param location string = deployment().location

@description('Tags supplied by configuration. environment and managedBy are added automatically.')
param tags object

@description('App Service Plan SKU.')
param appServicePlanSku string = 'B1'

@description('Key Vault soft delete retention (days).')
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 90

@description('Enable Key Vault purge protection. Irreversible once enabled.')
param keyVaultPurgeProtection bool = false

@secure()
@minLength(1)
@description('Value for the external-api-key secret. Provided at deploy time - never commit it.')
param externalApiKey string

// ---------------------------------------------------------------------------
// Configuration & naming
// ---------------------------------------------------------------------------

var storageConfig = loadJsonContent('config/storage.json')

// Deterministic suffix -> same names on every run (idempotent), unique per subscription/env.
var suffix = take(uniqueString(subscription().id, workload, environmentName), 5)
var baseName = '${workload}-${environmentName}'

var resourceGroupName = 'rg-${baseName}'
var keyVaultName = 'kv-${baseName}-${suffix}'
var appServicePlanName = 'asp-${baseName}'
var webAppName = 'app-${baseName}-${suffix}'
var externalApiKeySecretName = 'external-api-key'

var commonTags = union(tags, {
  environment: environmentName
  managedBy: 'Bicep'
})

@description('Storage account names must be 3-24 lowercase alphanumeric chars and globally unique.')
func storageAccountName(workload string, environmentName string, role string, suffix string) string =>
  '${take(toLower('st${workload}${environmentName}${role}'), 19)}${suffix}'

var appStorageAccountName = storageAccountName(
  workload,
  environmentName,
  storageConfig.appStorageAccess.storageAccount,
  suffix
)

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

// 1. App Service first - it creates the system-assigned managed identity.
module appService 'modules/app-service.bicep' = {
  name: 'app-service'
  scope: rg
  params: {
    appServicePlanName: appServicePlanName
    webAppName: webAppName
    location: location
    tags: commonTags
    skuName: appServicePlanSku
  }
}

// 2a. Key Vault + secret. The app identity can read ONLY this secret.
module keyVault 'modules/key-vault.bicep' = {
  name: 'key-vault'
  scope: rg
  params: {
    name: keyVaultName
    location: location
    tags: commonTags
    secretName: externalApiKeySecretName
    secretValue: externalApiKey
    secretReaderPrincipalIds: [
      appService.outputs.principalId
    ]
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionDays
    enablePurgeProtection: keyVaultPurgeProtection
  }
}

// 2b. Storage accounts - one module call per entry in config/storage.json.
//     Only the designated container gets a role assignment for the app.
module storageAccounts 'modules/storage-account.bicep' = [
  for sa in storageConfig.storageAccounts: {
    name: 'storage-${sa.name}'
    scope: rg
    params: {
      name: storageAccountName(workload, environmentName, sa.name, suffix)
      role: sa.name
      location: location
      tags: commonTags
      skuName: storageConfig.skuByEnvironment[environmentName]
      kind: sa.kind
      accessTier: sa.accessTier
      isHnsEnabled: sa.isHnsEnabled
      containers: sa.containers
      containerAccess: sa.name == storageConfig.appStorageAccess.storageAccount
        ? {
            '${storageConfig.appStorageAccess.container}': [
              appService.outputs.principalId
            ]
          }
        : {}
    }
  }
]

// 3. App settings last - access already exists, so the Key Vault reference
//    resolves as soon as the app starts.
module appSettings 'modules/app-settings.bicep' = {
  name: 'app-settings'
  scope: rg
  params: {
    webAppName: appService.outputs.name
    externalApiKeySecretUri: keyVault.outputs.secretUri
    storageBlobEndpoint: 'https://${appStorageAccountName}.blob.${environment().suffixes.storage}/'
    storageContainerName: storageConfig.appStorageAccess.container
  }
  dependsOn: [
    storageAccounts
  ]
}

// ---------------------------------------------------------------------------
// Outputs (no secrets here - see bicepconfig.json linter rules)
// ---------------------------------------------------------------------------

output resourceGroupName string = rg.name
output keyVaultName string = keyVault.outputs.name
output webAppName string = appService.outputs.name
output webAppUrl string = 'https://${appService.outputs.defaultHostName}'
output storageAccountNames array = [for i in range(0, length(storageConfig.storageAccounts)): storageAccounts[i].outputs.name]
