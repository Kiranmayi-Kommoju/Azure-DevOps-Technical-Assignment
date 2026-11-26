// App settings for the Web App.
// Applied AFTER the Key Vault and Storage role assignments exist, so the
// Key Vault reference resolves on the first start of the app.
// Note: this sets the complete appsettings collection - every setting the
// app needs must be listed here.

param webAppName string

@description('Unversioned Key Vault secret URI for the external API key.')
param externalApiKeySecretUri string

param externalApiBaseUrl string = 'https://api.example.com'

@description('Blob endpoint of the storage account the app is allowed to use.')
param storageBlobEndpoint string

param storageContainerName string

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
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
