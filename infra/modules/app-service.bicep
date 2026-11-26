// Linux App Service Plan + Web App running the Hello World container.
// Thin wrapper around the Azure Verified Modules (AVM) for App Service.
// App settings (incl. the Key Vault reference) are applied separately in
// app-settings.bicep, AFTER the identity has been granted access.

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
