targetScope = 'subscription'

@minLength(1)
@description('Name of the Azure Developer CLI environment.')
param environmentName string

@description('Single Azure region used for every regional resource.')
param location string = 'swedencentral'

@description('Supported gpt-4o-mini model version available in the selected region.')
param gpt4oMiniModelVersion string = '2024-07-18'

@description('Azure OpenAI data-plane API version used by the APIM policy.')
param openAiApiVersion string = '2024-10-21'

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
    openAiApiVersion: openAiApiVersion
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output APIM_NAME string = solution.outputs.apimName
output APIM_GATEWAY_URL string = solution.outputs.apimGatewayUrl
output FOUNDRY_ACCOUNT_NAME string = solution.outputs.foundryAccountName
output FOUNDRY_PROJECT_NAME string = solution.outputs.foundryProjectName
output GPT4O_MINI_DEPLOYMENT_NAME string = solution.outputs.gpt4oMiniDeploymentName
