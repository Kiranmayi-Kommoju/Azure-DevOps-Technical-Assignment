// Linux App Service Plan + Web App running the Hello World container.
// Thin wrapper around the Azure Verified Modules (AVM) for App Service.
// The app gets a system-assigned managed identity; role assignments are
// done in separate modules so they can be scoped as tightly as possible.

param appServicePlanName string
param webAppName string
param location string
param tags object

@description('App Service Plan SKU, e.g. B1 for dev/test, P0v3 for prod.')
param skuName string = 'B1'

@minValue(1)
param instanceCount int = 1

@description('Public Hello World container image.')
param containerImage string = 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'

@description('Unversioned Key Vault secret URI for the external API key.')
param externalApiKeySecretUri string

param externalApiBaseUrl string = 'https://api.example.com'

@description('Blob endpoint of the storage account the app is allowed to use.')
param storageBlobEndpoint string

param storageContainerName string

module appServicePlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'avm-${appServicePlanName}'
  params: {
    name: appServicePlanName
    location: location
    tags: tags
    kind: 'linux'
    reserved: true // required for a Linux plan
    skuName: skuName
    skuCapacity: instanceCount
    zoneRedundant: false // single instance is enough for this assignment
  }
}

module webApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'avm-${webAppName}'
  params: {
    name: webAppName
    location: location
    tags: tags
    kind: 'app,linux,container'
    serverFarmResourceId: appServicePlan.outputs.resourceId

    // System-assigned managed identity - used for Key Vault and Storage access
    managedIdentities: {
      systemAssigned: true
    }

    httpsOnly: true
    clientAffinityEnabled: false

    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerImage}'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/'
    }

    configs: [
      {
        name: 'appsettings'
        properties: {
          WEBSITES_PORT: '80'
          WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
          EXTERNAL_API_BASE_URL: externalApiBaseUrl
          // Key Vault reference - the secret value itself is never stored here
          EXTERNAL_API_KEY: '@Microsoft.KeyVault(SecretUri=${externalApiKeySecretUri})'
          STORAGE_BLOB_ENDPOINT: storageBlobEndpoint
          STORAGE_CONTAINER_NAME: storageContainerName
        }
      }
    ]

    // No FTP / SCM basic-auth publishing credentials
    basicPublishingCredentialsPolicies: [
      {
        name: 'ftp'
        allow: false
      }
      {
        name: 'scm'
        allow: false
      }
    ]
  }
}

output id string = webApp.outputs.resourceId
output name string = webApp.outputs.name
output defaultHostName string = webApp.outputs.defaultHostname
output principalId string = webApp.outputs.systemAssignedMIPrincipalId!
