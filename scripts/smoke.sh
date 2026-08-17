#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
debug_named_value_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/namedValues/EnableGatewayDebugHeaders"
debug_headers_original="$(
  az rest \
    --method get \
    --url "https://management.azure.com${debug_named_value_resource_id}?api-version=${api_version}" \
    --query properties.value \
    --output tsv \
    --only-show-errors
)"
smoke_profile_key="smoke-$(date +%s)-${RANDOM}"

cleanup() {
  az rest \
    --method put \
    --url "https://management.azure.com${debug_named_value_resource_id}?api-version=${api_version}" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"displayName\":\"EnableGatewayDebugHeaders\",\"secret\":false,\"value\":\"${debug_headers_original}\"}}" \
    --output none \
    --only-show-errors >/dev/null 2>&1 || true
  table_delete_profile "$smoke_profile_key"
  cleanup_test_files
}
trap cleanup EXIT

table_upsert_profile "$smoke_profile_key" "$(valid_profile_body "$smoke_profile_key")"

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
  tr '[:upper:]' '[:lower:]' <"$headers_file" >"$normalized_headers_file"
  grep -q "x-profile-cache: ${expected_cache_outcome}" "$normalized_headers_file" &&
    grep -q 'x-backend-id: gpt-4o-mini' "$normalized_headers_file" &&
    grep -q 'x-token-limit-tpm: 8000' "$normalized_headers_file"
}

for attempt in {1..12}; do
  status_code="$(send_chat_request "$smoke_profile_key")"

  if [[ "$status_code" == "200" ]] && assert_profile_headers miss; then
    break
  fi

  if [[ "$status_code" == "401" || "$status_code" == "403" || "$status_code" == "503" ]]; then
    sleep 15
    continue
  fi

  echo "Smoke request failed with HTTP $status_code." >&2
  jq -c '{error: (.error.message // .error // "Unexpected response")}' "$response_file" >&2 || true
  exit 1
done

if ! assert_profile_headers miss; then
  echo "APIM could not complete the cold profile lookup after waiting for propagation." >&2
  exit 1
fi

for attempt in {1..10}; do
  status_code="$(send_chat_request "$smoke_profile_key")"
  if [[ "$status_code" == "200" ]] &&
    jq -e '.choices[0].message.content | strings | length > 0' "$response_file" >/dev/null &&
    assert_profile_headers hit; then
    echo "Smoke test passed: model response, cache miss/hit, backend, and TPM selection are valid."
    exit 0
  fi
  sleep 2
done

echo "The repeated request did not observe the asynchronously stored profile cache entry." >&2
exit 1
