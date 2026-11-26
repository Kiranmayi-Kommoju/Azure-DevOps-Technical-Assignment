// One Storage Account plus its blob containers.
// Thin wrapper around the Azure Verified Module (AVM) for storage accounts.
// It applies this project's security defaults and is called in a loop
// from main.bicep - one call per entry in config/storage.json.

@description('Globally unique storage account name (3-24 lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param name string

@description('Logical role of the account (cold, standard, hot, datalake...). Stored as a tag so scripts can find it.')
param role string

param location string
param tags object

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_RAGRS'
])
param skuName string

param kind string = 'StorageV2'

@allowed([
  'Hot'
  'Cool'
])
param accessTier string

@description('Enables hierarchical namespace (ADLS Gen2).')
param isHnsEnabled bool = false

@description('Blob containers to create in this account.')
param containers string[] = []

@description('Who gets Storage Blob Data Contributor on which container. Shape: { "<container-name>": [ "<principalId>" ] }')
param containerAccess object = {}

@description('Days to keep deleted blobs/containers recoverable.')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 7

// Built-in role: Storage Blob Data Contributor (read/write blobs, no key or RBAC management)
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

module storageAccount 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'avm-${name}'
  params: {
    name: name
    location: location
    tags: union(tags, { storageRole: role })
    skuName: skuName
    kind: kind
    accessTier: accessTier
    enableHierarchicalNamespace: isHnsEnabled

    // Security defaults for this project
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // managed identity / Entra ID only, no account keys
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }

    blobServices: {
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: softDeleteRetentionDays
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: softDeleteRetentionDays
      // Containers are driven by configuration; access is granted per container
      containers: map(containers, containerName => {
        name: containerName
        publicAccess: 'None'
        roleAssignments: map(containerAccess[?containerName] ?? [], principalId => {
          principalId: principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
        })
      })
    }
  }
}

output id string = storageAccount.outputs.resourceId
output name string = storageAccount.outputs.name
output blobEndpoint string = storageAccount.outputs.primaryBlobEndpoint
