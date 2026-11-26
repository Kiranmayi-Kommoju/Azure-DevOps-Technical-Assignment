// Key Vault (RBAC model) and the external-api-key secret.
// Thin wrapper around the Azure Verified Module (AVM) for Key Vault.
// The secret value is passed in as a secure parameter at deployment time

@description('Key Vault name (3-24 chars, globally unique).')
@minLength(3)
@maxLength(24)
param name string

param location string
param tags object

@description('Name of the secret that holds the external API key.')
param secretName string = 'external-api-key'

@secure()
@description('External API key value. Supplied by the pipeline from a secret variable.')
param secretValue string

@description('Principal IDs that may read the secret. They get Key Vault Secrets User on this ONE secret only.')
param secretReaderPrincipalIds string[] = []

@description('Soft delete retention in days.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Purge protection cannot be turned off once enabled - only switch on where we really want it (prod).')
param enablePurgeProtection bool = false

// Built-in role: Key Vault Secrets User (read secret contents)
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

module keyVault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'avm-${name}'
  params: {
    name: name
    location: location
    tags: tags
    sku: 'standard'

    // Azure RBAC instead of access policies
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection

    // Nothing needs to pull secrets from this vault except the app
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false

    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }

    secrets: [
      {
        name: secretName
        value: secretValue
        contentType: 'text/plain'
        // Least privilege: role assigned on the secret, not on the vault
        roleAssignments: map(secretReaderPrincipalIds, principalId => {
          principalId: principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
        })
      }
    ]
  }
}

output id string = keyVault.outputs.resourceId
output name string = keyVault.outputs.name
output vaultUri string = keyVault.outputs.uri
output secretName string = secretName
// Unversioned URI so the App Service always resolves the latest version.
output secretUri string = '${keyVault.outputs.uri}secrets/${secretName}'
