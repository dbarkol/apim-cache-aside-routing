targetScope = 'subscription'

@minLength(1)
@description('Name of the Azure Developer CLI environment.')
param environmentName string

@description('Single Azure region used for every regional resource.')
param location string = 'swedencentral'

@description('Supported gpt-4o-mini model version available in the selected region.')
param gpt4oMiniModelVersion string = '2024-07-18'

@description('Model name used by both equivalent round-robin deployments.')
param roundRobinModelName string = 'gpt-4o-mini'

@description('Model version used by both equivalent round-robin deployments.')
param roundRobinModelVersion string = '2024-07-18'

@description('Model version used by both gpt-4.1-mini priority deployments.')
param priorityModelVersion string = '2025-04-14'

@minValue(1)
@description('Failure count that trips the priority-1 mini backend circuit breaker.')
param miniPrimaryCircuitBreakerFailureCount int = 3

@description('ISO 8601 interval during which priority-1 mini backend failures are counted.')
param miniPrimaryCircuitBreakerSamplingInterval string = 'PT1M'

@description('ISO 8601 duration that the priority-1 mini backend circuit remains open.')
param miniPrimaryCircuitBreakerTripDuration string = 'PT30S'

@description('Azure OpenAI data-plane API version used by the APIM policy.')
param openAiApiVersion string = '2024-10-21'

@minValue(1)
@description('Built-in APIM cache duration for normalized Gateway Routing Profiles.')
param profileCacheTtlSeconds int = 300

@minValue(1)
@description('Timeout for Table Storage profile point reads.')
param profileLookupTimeoutSeconds int = 3

@allowed([
  'azure-openai-token-limit'
  'llm-token-limit'
])
@description('Token-limit policy deployed with the stable Gateway Routing Profile schema.')
param tokenLimitPolicyVariant string = 'azure-openai-token-limit'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var resourceGroupName = 'rg-${environmentName}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: {
    'azd-env-name': environmentName
    project: 'apim-cache-aside-routing'
  }
}

module solution './resources.bicep' = {
  name: 'solution'
  scope: resourceGroup
  params: {
    environmentName: environmentName
    location: location
    resourceToken: resourceToken
    gpt4oMiniModelVersion: gpt4oMiniModelVersion
    roundRobinModelName: roundRobinModelName
    roundRobinModelVersion: roundRobinModelVersion
    priorityModelVersion: priorityModelVersion
    miniPrimaryCircuitBreakerFailureCount: miniPrimaryCircuitBreakerFailureCount
    miniPrimaryCircuitBreakerSamplingInterval: miniPrimaryCircuitBreakerSamplingInterval
    miniPrimaryCircuitBreakerTripDuration: miniPrimaryCircuitBreakerTripDuration
    openAiApiVersion: openAiApiVersion
    profileCacheTtlSeconds: profileCacheTtlSeconds
    profileLookupTimeoutSeconds: profileLookupTimeoutSeconds
    tokenLimitPolicyVariant: tokenLimitPolicyVariant
    deploymentPrincipalId: deployer().objectId
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output APIM_NAME string = solution.outputs.apimName
output APIM_GATEWAY_URL string = solution.outputs.apimGatewayUrl
output LOG_ANALYTICS_NAME string = solution.outputs.logAnalyticsName
output STORAGE_ACCOUNT_NAME string = solution.outputs.storageAccountName
output FOUNDRY_ACCOUNT_NAME string = solution.outputs.foundryAccountName
output FOUNDRY_PROJECT_NAME string = solution.outputs.foundryProjectName
output GPT4O_MINI_DEPLOYMENT_NAME string = solution.outputs.gpt4oMiniDeploymentName
output ROUND_ROBIN_DEPLOYMENT_1_NAME string = solution.outputs.roundRobinDeployment1Name
output ROUND_ROBIN_DEPLOYMENT_2_NAME string = solution.outputs.roundRobinDeployment2Name
output NANO_POOL_BACKEND_ID string = solution.outputs.nanoPoolBackendId
output MINI_PRIMARY_DEPLOYMENT_NAME string = solution.outputs.miniPrimaryDeploymentName
output MINI_OVERFLOW_DEPLOYMENT_NAME string = solution.outputs.miniOverflowDeploymentName
output MINI_PRIMARY_BACKEND_ID string = solution.outputs.miniPrimaryBackendId
output MINI_POOL_BACKEND_ID string = solution.outputs.miniPoolBackendId
