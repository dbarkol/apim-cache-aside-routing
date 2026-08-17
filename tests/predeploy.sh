#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_file="$(mktemp)"
trap 'rm -f "$template_file"' EXIT

"$repo_root/scripts/validate.sh" --template-out "$template_file"

jq -e '
  .parameters.location.defaultValue == "swedencentral"
  and .parameters.gpt4oMiniModelVersion.type == "string"
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].sku.name == "BasicV2")
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.Storage/storageAccounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.OperationalInsights/workspaces")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.Insights/components")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/deployments")][0].sku.name == "GlobalStandard")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/deployments")][0].sku.capacity == 1)
  and ([.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")] | length >= 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/namedValues")] | length >= 5)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis/operations")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/products")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/subscriptions")] | length == 1)
  and ([.outputs | to_entries[] | .key | ascii_downcase | test("key|secret|token")] | any | not)
' "$template_file" >/dev/null

grep -q 'resource="https://cognitiveservices.azure.com"' \
  "$repo_root/policies/chat/azure-openai-token-limit.xml"

for policy_file in \
  "$repo_root/policies/chat/azure-openai-token-limit.xml" \
  "$repo_root/policies/chat/llm-token-limit.xml"; do
  grep -q 'x-profile-key' "$policy_file"
  grep -q 'cache-lookup-value' "$policy_file"
  grep -q '<rate-limit-by-key calls="10" renewal-period="60"' "$policy_file"
  grep -q 'id="profile-miss-rate-limit"' "$policy_file"
  grep -q 'cache-store-value' "$policy_file"
  grep -q 'https://storage.azure.com/' "$policy_file"
  grep -q "PartitionKey='profiles-v1'" "$policy_file"
  grep -q 'schemaVersion' "$policy_file"
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
  if grep -q '<retry' "$policy_file"; then
    echo "Table profile reads must not retry: $policy_file" >&2
    exit 1
  fi
done

grep -q '<azure-openai-token-limit' \
  "$repo_root/policies/chat/azure-openai-token-limit.xml"
grep -q '<llm-token-limit' \
  "$repo_root/policies/chat/llm-token-limit.xml"

grep -q '"PartitionKey":"profiles-v1"' "$repo_root/scripts/seed-profile.sh"
grep -q '"RowKey":"lob1-gpt4o-mini"' "$repo_root/scripts/seed-profile.sh"
grep -q '"SchemaVersion@odata.type":"Edm.Int32"' "$repo_root/scripts/seed-profile.sh"
grep -q '"MaxTpm@odata.type":"Edm.Int32"' "$repo_root/scripts/seed-profile.sh"
grep -q 'get-access-token' "$repo_root/scripts/seed-profile.sh"
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
grep -q 'newly created profiles are immediately eligible' "$repo_root/tests/api-contract.sh"
grep -q 'corrected profiles are immediately eligible' "$repo_root/tests/api-contract.sh"
grep -q './scripts/smoke.sh' "$repo_root/scripts/test.sh"
grep -q './tests/api-contract.sh' "$repo_root/scripts/test.sh"

echo "Predeployment contract is valid."
