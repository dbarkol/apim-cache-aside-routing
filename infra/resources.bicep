targetScope = 'resourceGroup'

@minLength(1)
param environmentName string

param location string

@minLength(3)
param resourceToken string

param gpt4oMiniModelVersion string

param openAiApiVersion string

var tags = {
  'azd-env-name': environmentName
  project: 'apim-cache-aside-routing'
}
var apimName = 'apim-${environmentName}-${resourceToken}'
var storageAccountName = take('st${resourceToken}', 24)
var foundryAccountName = take('foundry-${environmentName}-${resourceToken}', 64)
var foundryProjectName = take('gateway-${environmentName}', 64)
var logAnalyticsName = 'log-${environmentName}-${resourceToken}'
var applicationInsightsName = 'appi-${environmentName}-${resourceToken}'
var gpt4oMiniDeploymentName = 'gpt-4o-mini'
var cognitiveServicesOpenAiUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: tags
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource profileTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  name: 'gatewayprofiles'
  parent: tableService
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  tags: tags
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryAccountName
    disableLocalAuth: true
    dynamicThrottlingEnabled: false
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: false
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  name: foundryProjectName
  parent: foundryAccount
  location: location
  tags: tags
  properties: {
    description: 'APIM cache-aside Gateway Routing Profile reference project'
    displayName: 'APIM gateway routing'
  }
}

resource gpt4oMiniDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  name: gpt4oMiniDeploymentName
  parent: foundryAccount
  sku: {
    name: 'GlobalStandard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: gpt4oMiniModelVersion
    }
    raiPolicyName: 'Microsoft.Default'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  tags: tags
  properties: {
    publisherEmail: 'gateway@example.com'
    publisherName: 'Gateway Reference'
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'None'
  }
}

resource foundryInferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, apim.id, cognitiveServicesOpenAiUserRoleDefinitionId)
  scope: foundryAccount
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAiUserRoleDefinitionId
  }
}

resource modelBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  name: 'gpt-4o-mini'
  parent: apim
  properties: {
    description: 'Managed-identity-authenticated gpt-4o-mini deployment'
    protocol: 'http'
    title: 'gpt-4o-mini'
    url: 'https://${foundryAccountName}.openai.azure.com/openai/deployments/${gpt4oMiniDeploymentName}'
  }
  dependsOn: [
    gpt4oMiniDeployment
    foundryInferenceRole
  ]
}

resource chatApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: 'gateway-chat'
  parent: apim
  properties: {
    apiType: 'http'
    description: 'Subscription-protected direct model tracer bullet'
    displayName: 'Gateway Chat'
    path: 'openai'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
  }
}

resource chatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'chat-completions'
  parent: chatApi
  properties: {
    description: 'Send one chat completion request to the configured model deployment.'
    displayName: 'Chat completions'
    method: 'POST'
    request: {
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        description: 'Model response'
        statusCode: 200
      }
    ]
    templateParameters: []
    urlTemplate: '/chat/completions'
  }
}

resource chatPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: chatApi
  properties: {
    format: 'rawxml'
    value: replace(
      loadTextContent('../policies/chat/direct.xml'),
      '__OPENAI_API_VERSION__',
      openAiApiVersion
    )
  }
  dependsOn: [
    chatOperation
    modelBackend
  ]
}

resource consumerProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  name: 'gateway-consumer'
  parent: apim
  properties: {
    approvalRequired: false
    description: 'Consumer access to the sample chat API'
    displayName: 'Gateway Consumer'
    state: 'published'
    subscriptionRequired: true
  }
}

resource consumerProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  name: chatApi.name
  parent: consumerProduct
}

resource consumerSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  name: 'gateway-consumer-sub'
  parent: apim
  properties: {
    allowTracing: false
    displayName: 'Gateway Consumer Sample'
    scope: consumerProduct.id
    state: 'active'
  }
}

resource applicationInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  name: 'application-insights'
  parent: apim
  properties: {
    credentials: {
      connectionString: applicationInsights.properties.ConnectionString
    }
    description: 'Application Insights telemetry'
    isBuffered: true
    loggerType: 'applicationInsights'
    resourceId: applicationInsights.id
  }
}

resource chatDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  name: 'applicationinsights'
  parent: chatApi
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    loggerId: applicationInsightsLogger.id
    sampling: {
      percentage: 100
      samplingType: 'fixed'
    }
    verbosity: 'information'
  }
}

resource apimDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'gateway-logs'
  scope: apim
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalytics.id
  }
}

output apimName string = apim.name
output apimGatewayUrl string = 'https://${apim.name}.azure-api.net'
output foundryAccountName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
output gpt4oMiniDeploymentName string = gpt4oMiniDeployment.name
