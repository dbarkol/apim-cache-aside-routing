targetScope = 'resourceGroup'

@minLength(1)
param environmentName string

param location string

@minLength(3)
param resourceToken string

param gpt4oMiniModelVersion string

param openAiApiVersion string

param profileCacheTtlSeconds int

param profileLookupTimeoutSeconds int

param tokenLimitPolicyVariant string

param deploymentPrincipalId string

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
var storageTableDataReaderRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '76199698-9eea-4c19-bc75-cec21354c6b6'
)
var storageTableDataContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
)
var selectedChatPolicy = tokenLimitPolicyVariant == 'llm-token-limit'
  ? loadTextContent('../policies/chat/llm-token-limit.xml')
  : loadTextContent('../policies/chat/azure-openai-token-limit.xml')
var resolveProfileFragment = loadTextContent('../policies/shared/resolve-profile.xml')
var profileRefreshPolicy = loadTextContent('../policies/admin/profile-refresh.xml')

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
  tags: union(tags, {
    SecurityControl: 'Ignore'
  })
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
  identity: {
    type: 'SystemAssigned'
  }
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
  identity: {
    type: 'SystemAssigned'
  }
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

resource profileTableReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, apim.id, storageTableDataReaderRoleDefinitionId)
  scope: storageAccount
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageTableDataReaderRoleDefinitionId
  }
}

resource profileSeedContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, deploymentPrincipalId, storageTableDataContributorRoleDefinitionId)
  scope: storageAccount
  properties: {
    principalId: deploymentPrincipalId
    roleDefinitionId: storageTableDataContributorRoleDefinitionId
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

resource profileAdminApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: 'profile-admin'
  parent: apim
  properties: {
    apiType: 'http'
    description: 'Separately protected administrative operations for Gateway Routing Profiles'
    displayName: 'Gateway Profile Administration'
    path: 'internal/profiles'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
  }
}

resource profileRefreshOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'refresh-profile'
  parent: profileAdminApi
  properties: {
    description: 'Reload, validate, and asynchronously replace one cached Gateway Routing Profile.'
    displayName: 'Refresh profile'
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
        description: 'Refresh accepted for asynchronous cache replacement'
        statusCode: 202
      }
      {
        description: 'Invalid Profile Key'
        statusCode: 400
      }
      {
        description: 'Profile missing or invalid'
        statusCode: 500
      }
      {
        description: 'Profile source unavailable'
        statusCode: 503
      }
    ]
    templateParameters: [
      {
        description: 'Profile Key to reload'
        name: 'profileKey'
        required: true
        type: 'string'
        values: []
      }
    ]
    urlTemplate: '/{profileKey}/refresh'
  }
}

resource profileTableEndpointNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'ProfileTableEndpoint'
  parent: apim
  properties: {
    displayName: 'ProfileTableEndpoint'
    secret: false
    value: 'https://${storageAccount.name}.table.core.windows.net'
  }
}

resource profileTableNameNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'ProfileTableName'
  parent: apim
  properties: {
    displayName: 'ProfileTableName'
    secret: false
    value: profileTable.name
  }
}

resource profileCacheTtlNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'ProfileCacheTtlSeconds'
  parent: apim
  properties: {
    displayName: 'ProfileCacheTtlSeconds'
    secret: false
    value: string(profileCacheTtlSeconds)
  }
}

resource profileLookupTimeoutNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'ProfileLookupTimeoutSeconds'
  parent: apim
  properties: {
    displayName: 'ProfileLookupTimeoutSeconds'
    secret: false
    value: string(profileLookupTimeoutSeconds)
  }
}

resource gatewayDebugHeadersNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'EnableGatewayDebugHeaders'
  parent: apim
  properties: {
    displayName: 'EnableGatewayDebugHeaders'
    secret: false
    value: 'false'
  }
}

resource resolveProfilePolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  name: 'resolve-profile'
  parent: apim
  properties: {
    description: 'Authoritative Table read, validation, normalization, and cache submission for one Gateway Routing Profile.'
    format: 'rawxml'
    value: resolveProfileFragment
  }
  dependsOn: [
    profileTableReaderRole
    profileTableEndpointNamedValue
    profileTableNameNamedValue
    profileCacheTtlNamedValue
    profileLookupTimeoutNamedValue
  ]
}

resource chatPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: chatApi
  properties: {
    format: 'rawxml'
    value: replace(selectedChatPolicy, '__OPENAI_API_VERSION__', openAiApiVersion)
  }
  dependsOn: [
    chatOperation
    modelBackend
    profileTableReaderRole
    profileTableEndpointNamedValue
    profileTableNameNamedValue
    profileCacheTtlNamedValue
    profileLookupTimeoutNamedValue
    gatewayDebugHeadersNamedValue
    resolveProfilePolicyFragment
  ]
}

resource profileRefreshApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: profileAdminApi
  properties: {
    format: 'rawxml'
    value: profileRefreshPolicy
  }
  dependsOn: [
    profileRefreshOperation
    resolveProfilePolicyFragment
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

resource profileAdminProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  name: 'gateway-profile-admin'
  parent: apim
  properties: {
    approvalRequired: false
    description: 'Administrative access to Profile Refresh'
    displayName: 'Gateway Profile Administrator'
    state: 'published'
    subscriptionRequired: true
  }
}

resource profileAdminProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  name: profileAdminApi.name
  parent: profileAdminProduct
}

resource profileAdminSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  name: 'gateway-profile-admin-sub'
  parent: apim
  properties: {
    allowTracing: false
    displayName: 'Gateway Profile Administrator Sample'
    scope: profileAdminProduct.id
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
output storageAccountName string = storageAccount.name
output foundryAccountName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
output gpt4oMiniDeploymentName string = gpt4oMiniDeployment.name
