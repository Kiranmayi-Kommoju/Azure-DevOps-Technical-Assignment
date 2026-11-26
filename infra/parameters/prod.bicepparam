using '../main.bicep'

// PROD environment.
// Region is not set here: it comes from the --location of the subscription
// deployment (pipeline environment config), see main.bicep.

param environmentName = 'prod'
param workload = 'hwapp'

param tags = {
  application: 'hello-world-app'
  owner: 'kiranmayi.kommoju@itineris.net'
  costCenter: 'ets'
}

param appServicePlanSku = 'P0v3'
param keyVaultSoftDeleteRetentionDays = 90
param keyVaultPurgeProtection = true

// Secret is read from an environment variable at deploy time.
// The pipeline maps it from a secret variable group. It is never stored in this file.
param externalApiKey = readEnvironmentVariable('EXTERNAL_API_KEY', '')
