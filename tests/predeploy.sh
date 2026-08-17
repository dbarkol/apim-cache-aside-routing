#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_file="$(mktemp)"
trap 'rm -f "$template_file"' EXIT

"$repo_root/scripts/validate.sh" --template-out "$template_file"

jq -e '
  .parameters.location.defaultValue == "swedencentral"
  and .parameters.gpt4oMiniModelVersion.type == "string"
  and .parameters.roundRobinModelName.type == "string"
  and .parameters.roundRobinModelName.defaultValue == "gpt-4o-mini"
  and .parameters.roundRobinModelVersion.type == "string"
  and .parameters.priorityModelVersion.type == "string"
  and .parameters.priorityModelVersion.defaultValue == "2025-04-14"
  and .parameters.miniPrimaryCircuitBreakerFailureCount.type == "int"
  and .parameters.miniPrimaryCircuitBreakerFailureCount.defaultValue == 3
  and .parameters.miniPrimaryCircuitBreakerSamplingInterval.type == "string"
  and .parameters.miniPrimaryCircuitBreakerTripDuration.type == "string"
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].sku.name == "BasicV2")
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.Storage/storageAccounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.OperationalInsights/workspaces")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.Insights/components")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "[parameters(\u0027roundRobinModelName\u0027)]"
    and .sku.name? == "GlobalStandard"
    and .sku.capacity? == 1
  )] | length == 2)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "gpt-4o-mini"
    and .sku.name? == "GlobalStandard"
    and .sku.capacity? == 1
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "[parameters(\u0027roundRobinModelName\u0027)]"
    and ((.dependsOn // []) | any(test("gpt4oMiniDeploymentName")))
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "[parameters(\u0027roundRobinModelName\u0027)]"
    and ((.dependsOn // []) | any(test("roundRobinDeployment1Name")))
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "gpt-4.1-mini"
    and .properties.model.version? == "[parameters(\u0027priorityModelVersion\u0027)]"
    and .sku.name? == "GlobalStandard"
    and .sku.capacity? == 1
  )] | length == 2)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "gpt-4.1-mini"
    and ((.dependsOn // []) | any(test("roundRobinDeployment2Name")))
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.CognitiveServices/accounts/deployments"
    and .properties.model.name? == "gpt-4.1-mini"
    and ((.dependsOn // []) | any(test("miniPrimaryDeploymentName")))
  )] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")] | length >= 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/namedValues")] | length >= 5)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis")] | length == 3)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis/operations")] | length == 3)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis/policies")] | length == 3)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/policyFragments")] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.ApiManagement/service/backends"
    and .properties.type? == "Pool"
    and (.name? | test("nano-pool"))
    and ([.properties.pool.services[] | select(.priority == 1 and .weight == 1)] | length == 2)
    and ([.properties.pool.services[].id] | unique | length == 2)
    and ([.properties.pool.services[].id | select(test("roundRobinDeployment[12]Name"))] | length == 2)
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.ApiManagement/service/backends"
    and (.name? | test("miniPrimaryDeploymentName"))
    and (.properties.circuitBreaker.rules | length == 1)
    and .properties.circuitBreaker.rules[0].acceptRetryAfter == true
    and .properties.circuitBreaker.rules[0].failureCondition.count == "[parameters(\u0027miniPrimaryCircuitBreakerFailureCount\u0027)]"
    and .properties.circuitBreaker.rules[0].failureCondition.interval == "[parameters(\u0027miniPrimaryCircuitBreakerSamplingInterval\u0027)]"
    and .properties.circuitBreaker.rules[0].tripDuration == "[parameters(\u0027miniPrimaryCircuitBreakerTripDuration\u0027)]"
    and any(.properties.circuitBreaker.rules[0].failureCondition.statusCodeRanges[]; .min == 429 and .max == 429)
    and any(.properties.circuitBreaker.rules[0].failureCondition.statusCodeRanges[]; .min == 500 and .max == 599)
  )] | length == 1)
  and ([.. | objects | select(
    .type? == "Microsoft.ApiManagement/service/backends"
    and .properties.type? == "Pool"
    and (.name? | test("mini-pool"))
    and ([.properties.pool.services[] | select(.priority == 1 and .weight == 1 and (.id | test("miniPrimaryDeploymentName")))] | length == 1)
    and ([.properties.pool.services[] | select(.priority == 2 and .weight == 1 and (.id | test("miniOverflowDeploymentName")))] | length == 1)
  )] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/products")] | length == 2)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/products/apis")] | length == 2)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/subscriptions")] | length == 2)
  and ([.. | objects | select(
    .type? == "Microsoft.Insights/diagnosticSettings"
    and .properties.logAnalyticsDestinationType? == "Dedicated"
  )] | length == 1)
  and (.outputs.NANO_POOL_BACKEND_ID.value | type == "string")
  and (.outputs.LOG_ANALYTICS_NAME.value | type == "string")
  and (.outputs.ROUND_ROBIN_DEPLOYMENT_1_NAME.value | type == "string")
  and (.outputs.ROUND_ROBIN_DEPLOYMENT_2_NAME.value | type == "string")
  and (.outputs.MINI_PRIMARY_DEPLOYMENT_NAME.value | type == "string")
  and (.outputs.MINI_OVERFLOW_DEPLOYMENT_NAME.value | type == "string")
  and (.outputs.MINI_PRIMARY_BACKEND_ID.value | type == "string")
  and (.outputs.MINI_POOL_BACKEND_ID.value | type == "string")
  and ([.outputs | to_entries[] | .key | ascii_downcase | test("key|secret|token")] | any | not)
' "$template_file" >/dev/null

grep -q '<fragment>' "$repo_root/policies/shared/resolve-profile.xml"
grep -q '<cache-store-value' "$repo_root/policies/shared/resolve-profile.xml"
grep -q 'https://storage.azure.com/' "$repo_root/policies/shared/resolve-profile.xml"
grep -q "PartitionKey='profiles-v1'" "$repo_root/policies/shared/resolve-profile.xml"
grep -q 'schemaVersion' "$repo_root/policies/shared/resolve-profile.xml"
grep -q 'backendId' "$repo_root/policies/shared/resolve-profile.xml"
grep -q 'maxTpm' "$repo_root/policies/shared/resolve-profile.xml"
if grep -q '<retry' "$repo_root/policies/shared/resolve-profile.xml"; then
  echo "Table profile reads must not retry: $repo_root/policies/shared/resolve-profile.xml" >&2
  exit 1
fi
grep -q 'include-fragment fragment-id="resolve-profile"' \
  "$repo_root/policies/chat/azure-openai-token-limit.xml"
grep -q 'include-fragment fragment-id="resolve-profile"' \
  "$repo_root/policies/chat/llm-token-limit.xml"
grep -q 'context.Request.MatchedParameters.GetValueOrDefault("profileKey", "")' \
  "$repo_root/policies/admin/profile-refresh.xml"
grep -q 'context.LastError.Reason == "SubscriptionKeyInvalid"' \
  "$repo_root/policies/admin/profile-refresh.xml"
grep -q '<set-status code="202" reason="Accepted" />' \
  "$repo_root/policies/admin/profile-refresh.xml"
grep -q 'include-fragment fragment-id="resolve-profile"' \
  "$repo_root/policies/admin/profile-refresh.xml"

grep -q 'resource="https://cognitiveservices.azure.com"' \
  "$repo_root/policies/chat/azure-openai-token-limit.xml"

for policy_file in \
  "$repo_root/policies/chat/azure-openai-token-limit.xml" \
  "$repo_root/policies/chat/llm-token-limit.xml"; do
  grep -q 'x-profile-key' "$policy_file"
  grep -q 'cache-lookup-value' "$policy_file"
  grep -q '<rate-limit-by-key calls="10" renewal-period="60"' "$policy_file"
  grep -q 'id="profile-miss-rate-limit"' "$policy_file"
  grep -q 'include-fragment fragment-id="resolve-profile"' "$policy_file"
  grep -q 'backendId' "$policy_file"
  grep -q 'maxTpm' "$policy_file"
  grep -q 'tokens-per-minute='"'"'@((int)context.Variables\["maxTpm"\])'"'"'' "$policy_file"
  if grep -Eq 'tokens-per-minute="[0-9]+"' "$policy_file"; then
    echo "Token limits must come from the validated profile row: $policy_file" >&2
    exit 1
  fi
  grep -q 'backend-id='"'"'@((string)context.Variables\["backendId"\])'"'"'' "$policy_file"
  grep -q 'id="apply-profile-backend"' "$policy_file"
  grep -q 'context.LastError.PolicyId == "profile-miss-rate-limit"' "$policy_file"
  grep -q '<set-status code="429" reason="Too Many Requests" />' "$policy_file"
  grep -q 'RoutingConfigurationUnavailable' "$policy_file"
  if grep -Eq 'ProfileNotFound|InvalidProfile' "$policy_file"; then
    echo "Stored profile failures must use the generic client error contract: $policy_file" >&2
    exit 1
  fi
done

grep -q '<azure-openai-token-limit' \
  "$repo_root/policies/chat/azure-openai-token-limit.xml"
grep -q '<llm-token-limit' \
  "$repo_root/policies/chat/llm-token-limit.xml"
grep -q '<set-status code="503" reason="Service Unavailable" />' \
  "$repo_root/policies/test/priority-fault.xml"
grep -q '<set-header name="Retry-After" exists-action="override">' \
  "$repo_root/policies/test/priority-fault.xml"
grep -q '<value>120</value>' "$repo_root/policies/test/priority-fault.xml"

grep -q '"PartitionKey":"profiles-v1"' "$repo_root/scripts/seed-profile.sh"
grep -q '"RowKey":"lob1-gpt4o-mini"' "$repo_root/scripts/seed-profile.sh"
grep -q '"RowKey":"test-nano"' "$repo_root/scripts/seed-profile.sh"
grep -q '"BackendId":"nano-pool"' "$repo_root/scripts/seed-profile.sh"
grep -q '"MaxTpm":500' "$repo_root/scripts/seed-profile.sh"
grep -q '"RowKey":"lob1-gpt4-1"' "$repo_root/scripts/seed-profile.sh"
grep -q '"BackendId":"mini-pool"' "$repo_root/scripts/seed-profile.sh"
grep -q '"MaxTpm":4000' "$repo_root/scripts/seed-profile.sh"
grep -q '"SchemaVersion@odata.type":"Edm.Int32"' "$repo_root/scripts/seed-profile.sh"
grep -q '"MaxTpm@odata.type":"Edm.Int32"' "$repo_root/scripts/seed-profile.sh"
grep -q 'get-access-token' "$repo_root/scripts/seed-profile.sh"
grep -q 'ROUND_ROBIN_MODEL_NAME' "$repo_root/scripts/preflight.sh"
grep -q 'ROUND_ROBIN_MODEL_VERSION' "$repo_root/scripts/preflight.sh"
grep -q 'PRIORITY_MODEL_VERSION' "$repo_root/scripts/preflight.sh"
grep -q 'round_robin_required_capacity=2' "$repo_root/scripts/preflight.sh"
grep -q 'check_model_quota "$round_robin_model_name" "$round_robin_required_capacity"' \
  "$repo_root/scripts/preflight.sh"
grep -q 'priority_required_capacity=2' "$repo_root/scripts/preflight.sh"
grep -q 'check_model_quota gpt-4.1-mini "$priority_required_capacity"' \
  "$repo_root/scripts/preflight.sh"
grep -q 'quota_model_name="${quota_model_name/gpt-4.1/gpt4.1}"' \
  "$repo_root/scripts/preflight.sh"
grep -q 'will not move the model to another region' "$repo_root/scripts/preflight.sh"
grep -q 'deployer().objectId' "$repo_root/infra/main.bicep"
grep -q "SecurityControl: 'Ignore'" "$repo_root/infra/resources.bicep"
grep -q "tokenLimitPolicyVariant string = 'azure-openai-token-limit'" \
  "$repo_root/infra/main.bicep"
grep -q 'smoke_profile_key=' "$repo_root/scripts/smoke.sh"
grep -q 'assert_profile_headers miss' "$repo_root/scripts/smoke.sh"
grep -q 'assert_profile_headers hit' "$repo_root/scripts/smoke.sh"
grep -q 'x-profile-cache:' "$repo_root/scripts/smoke.sh"
grep -q 'x-backend-id: gpt-4o-mini' "$repo_root/scripts/smoke.sh"
grep -q 'x-token-limit-tpm: 8000' "$repo_root/scripts/smoke.sh"
grep -q 'assert_error_response 400 InvalidRequest' "$repo_root/tests/api-contract.sh"
grep -q 'assert_error_response 429 TooManyRequests' "$repo_root/tests/api-contract.sh"
grep -q 'assert_error_response 500 RoutingConfigurationUnavailable' "$repo_root/tests/api-contract.sh"
grep -q 'assert_error_response 503 RoutingDependencyUnavailable' "$repo_root/tests/faults.sh"
grep -q 'send_refresh_request "$consumer_subscription_key"' "$repo_root/tests/refresh.sh"
grep -q 'send_refresh_request "$admin_subscription_key"' "$repo_root/tests/refresh.sh"
grep -q 'assert_error_response 400 InvalidRequest' "$repo_root/tests/refresh.sh"
grep -q 'assert_error_response 500 RoutingConfigurationUnavailable' "$repo_root/tests/refresh.sh"
grep -q 'wait_for_cached_profile_tpm 9000' "$repo_root/tests/refresh.sh"
grep -q 'send_refresh_request "$admin_subscription_key"' "$repo_root/tests/faults.sh"
grep -q 'newly created profiles are immediately eligible' "$repo_root/tests/api-contract.sh"
grep -q 'corrected profiles are immediately eligible' "$repo_root/tests/api-contract.sh"
grep -q './scripts/smoke.sh' "$repo_root/scripts/test.sh"
grep -q './tests/api-contract.sh' "$repo_root/scripts/test.sh"
grep -q './tests/refresh.sh' "$repo_root/scripts/test.sh"
grep -q './tests/round-robin.sh' "$repo_root/scripts/test.sh"
grep -q './tests/priority-routing.sh' "$repo_root/scripts/test.sh"
grep -q './tests/priority-overflow.sh' "$repo_root/scripts/test.sh"
grep -q 'ApiManagementGatewayLogs' "$repo_root/tests/round-robin.sh"
grep -q 'BackendUrl' "$repo_root/tests/round-robin.sh"
grep -q 'ROUND_ROBIN_DEPLOYMENT_1_NAME' "$repo_root/tests/round-robin.sh"
grep -q 'ROUND_ROBIN_DEPLOYMENT_2_NAME' "$repo_root/tests/round-robin.sh"
if grep -Eq '50%|exact|alternat' "$repo_root/tests/round-robin.sh"; then
  echo "Round-robin tests must assert participation, not an exact distribution or alternation." >&2
  exit 1
fi
grep -q 'ApiManagementGatewayLogs' "$repo_root/tests/priority-routing.sh"
grep -q 'BackendUrl' "$repo_root/tests/priority-routing.sh"
grep -q 'MINI_PRIMARY_DEPLOYMENT_NAME' "$repo_root/tests/priority-routing.sh"
grep -q 'MINI_OVERFLOW_DEPLOYMENT_NAME' "$repo_root/tests/priority-routing.sh"
grep -q '/internal/priority-fault' "$repo_root/tests/priority-overflow.sh"
grep -q 'MINI_PRIMARY_BACKEND_ID' "$repo_root/tests/priority-overflow.sh"
grep -q 'MINI_OVERFLOW_DEPLOYMENT_NAME' "$repo_root/tests/priority-overflow.sh"
if grep -Eqi 'exact failover|fixed failover|request count|failover timing' \
  "$repo_root/tests/priority-routing.sh" "$repo_root/tests/priority-overflow.sh"; then
  echo "Priority tests must use eventual observations instead of exact failover counts or timing." >&2
  exit 1
fi

echo "Predeployment contract is valid."
