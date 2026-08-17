#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
admin_subscription_key="$(get_subscription_key gateway-profile-admin-sub)"
profile_table_endpoint_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/namedValues/ProfileTableEndpoint"
original_table_endpoint="$(
  az rest \
    --method get \
    --url "https://management.azure.com${profile_table_endpoint_resource_id}?api-version=${api_version}" \
    --query properties.value \
    --output tsv \
    --only-show-errors
)"
table_endpoint_restored=false

restore_table_endpoint() {
  if [[ "$table_endpoint_restored" != true ]]; then
    az rest \
      --method put \
      --url "https://management.azure.com${profile_table_endpoint_resource_id}?api-version=${api_version}" \
      --headers "Content-Type=application/json" \
      --body "{\"properties\":{\"displayName\":\"ProfileTableEndpoint\",\"secret\":false,\"value\":\"${original_table_endpoint}\"}}" \
      --output none \
      --only-show-errors >/dev/null 2>&1 || true
  fi
  cleanup_test_files
}
trap restore_table_endpoint EXIT

az rest \
  --method put \
  --url "https://management.azure.com${profile_table_endpoint_resource_id}?api-version=${api_version}" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{"displayName":"ProfileTableEndpoint","secret":false,"value":"https://profile-source.invalid"}}' \
  --output none \
  --only-show-errors

echo "Waiting for the temporary Table endpoint fault to propagate."
sleep 30

fault_profile_key="issue4-source-failure-$(date +%s)-${RANDOM}"
status_code="$(send_chat_request "$fault_profile_key")"
assert_error_response 503 RoutingDependencyUnavailable "$fault_profile_key" "profile-source.invalid"
status_code="$(send_refresh_request "$admin_subscription_key" "$fault_profile_key")"
assert_error_response 503 RoutingDependencyUnavailable "$fault_profile_key" "profile-source.invalid"

az rest \
  --method put \
  --url "https://management.azure.com${profile_table_endpoint_resource_id}?api-version=${api_version}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"displayName\":\"ProfileTableEndpoint\",\"secret\":false,\"value\":\"${original_table_endpoint}\"}}" \
  --output none \
  --only-show-errors
restored_table_endpoint="$(
  az rest \
    --method get \
    --url "https://management.azure.com${profile_table_endpoint_resource_id}?api-version=${api_version}" \
    --query properties.value \
    --output tsv \
    --only-show-errors
)"
if [[ "$restored_table_endpoint" != "$original_table_endpoint" ]]; then
  echo "The ProfileTableEndpoint named value was not restored after fault testing." >&2
  exit 1
fi
table_endpoint_restored=true

echo "Deployed API fault contract passed for sanitized 503 responses."
