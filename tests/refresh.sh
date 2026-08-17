#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
admin_subscription_key="$(get_subscription_key gateway-profile-admin-sub)"
profile_key="issue5-refresh-$(date +%s)-${RANDOM}"
missing_profile_key="${profile_key}-missing"
invalid_profile_key="${profile_key}-invalid"
debug_named_value_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/namedValues/EnableGatewayDebugHeaders"
debug_headers_original="$(
  az rest \
    --method get \
    --url "https://management.azure.com${debug_named_value_resource_id}?api-version=${api_version}" \
    --query properties.value \
    --output tsv \
    --only-show-errors
)"

cleanup() {
  az rest \
    --method put \
    --url "https://management.azure.com${debug_named_value_resource_id}?api-version=${api_version}" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"displayName\":\"EnableGatewayDebugHeaders\",\"secret\":false,\"value\":\"${debug_headers_original}\"}}" \
    --output none \
    --only-show-errors >/dev/null 2>&1 || true
  table_delete_profile "$profile_key"
  table_delete_profile "$invalid_profile_key"
  cleanup_test_files
}
trap cleanup EXIT

az rest \
  --method put \
  --url "https://management.azure.com${debug_named_value_resource_id}?api-version=${api_version}" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{"displayName":"EnableGatewayDebugHeaders","secret":false,"value":"true"}}' \
  --output none \
  --only-show-errors

echo "Waiting for the temporary APIM debug-header setting to propagate."
sleep 30

assert_profile_headers() {
  local expected_cache_outcome="$1"
  local expected_tpm="$2"
  tr '[:upper:]' '[:lower:]' <"$headers_file" >"$normalized_headers_file"
  grep -q "x-profile-cache: ${expected_cache_outcome}" "$normalized_headers_file" &&
    grep -q "x-token-limit-tpm: ${expected_tpm}" "$normalized_headers_file"
}

wait_for_cached_profile_tpm() {
  local expected_tpm="$1"
  local attempt

  for attempt in {1..15}; do
    status_code="$(send_chat_request "$profile_key")"
    if [[ "$status_code" == "200" ]] && assert_profile_headers hit "$expected_tpm"; then
      return 0
    fi
    sleep 2
  done

  echo "The chat API did not observe TPM ${expected_tpm} for the refreshed profile." >&2
  cat "$response_file" >&2
  return 1
}

table_upsert_profile "$profile_key" "$(valid_profile_body "$profile_key" 8000)"
wait_for_cached_profile_tpm 8000

status_code="$(send_refresh_request "$consumer_subscription_key" "$profile_key")"
assert_error_response 403 Forbidden "$profile_key"

status_code="$(send_refresh_request "$admin_subscription_key" "contains%20space")"
assert_error_response 400 InvalidRequest "contains space"

status_code="$(send_refresh_request "$admin_subscription_key" "$missing_profile_key")"
assert_error_response 500 RoutingConfigurationUnavailable "$missing_profile_key"

invalid_profile_body="$(jq -cn --arg key "$invalid_profile_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
  MaxTpm: "invalid"
}')"
table_upsert_profile "$invalid_profile_key" "$invalid_profile_body"
status_code="$(send_refresh_request "$admin_subscription_key" "$invalid_profile_key")"
assert_error_response 500 RoutingConfigurationUnavailable "$invalid_profile_key" "invalid"

table_upsert_profile "$profile_key" "$(valid_profile_body "$profile_key" 9000)"
source_before_refresh="$(table_get_profile "$profile_key" | jq -S -c .)"

status_code="$(send_refresh_request "$admin_subscription_key" "$profile_key")"
if [[ "$status_code" != "202" ]] ||
  ! jq -e '
    .status == "accepted"
    and (.message | type == "string" and test("accepted"; "i"))
    and (.correlationId | type == "string" and length > 0)
    and ((keys | sort) == ["correlationId", "message", "status"])
  ' "$response_file" >/dev/null; then
  echo "Profile Refresh did not return the asynchronous 202 contract." >&2
  cat "$response_file" >&2
  exit 1
fi

source_after_refresh="$(table_get_profile "$profile_key" | jq -S -c .)"
if [[ "$source_after_refresh" != "$source_before_refresh" ]]; then
  echo "Profile Refresh modified the source Table entity." >&2
  exit 1
fi

wait_for_cached_profile_tpm 9000

echo "Profile Refresh passed authorization, 202, source immutability, and eventual cache replacement checks."
