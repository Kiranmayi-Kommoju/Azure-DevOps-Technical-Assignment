using '../main.bicep'

// DEV environment.
// Region is not set here: it comes from the --location of the subscription
// deployment (pipeline environment config), see main.bicep.

param environmentName = 'dev'
param workload = 'hwapp'

param tags = {
  application: 'hello-world-app'
  owner: 'kiranmayi.kommoju@itineris.net'
  costCenter: 'ets'
}

param appServicePlanSku = 'B1'
param keyVaultSoftDeleteRetentionDays = 7
param keyVaultPurgeProtection = false

// Secret is read from an environment variable at deploy time.
// The pipeline maps it from a secret variable group. It is never stored in this file.
param externalApiKey = readEnvironmentVariable('EXTERNAL_API_KEY', '')
