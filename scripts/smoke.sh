#!/usr/bin/env bash
set -euo pipefail

for command_name in az azd curl jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command '$command_name' was not found." >&2
    exit 1
  fi
done

resource_group="$(azd env get-value AZURE_RESOURCE_GROUP)"
apim_name="$(azd env get-value APIM_NAME)"
gateway_url="$(azd env get-value APIM_GATEWAY_URL)"
subscription_id="$(az account show --query id --output tsv --only-show-errors)"
api_version="2024-05-01"
subscription_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/subscriptions/gateway-consumer-sub"
debug_named_value_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/namedValues/EnableGatewayDebugHeaders"

subscription_key="$(
  az rest \
    --method post \
    --url "https://management.azure.com${subscription_resource_id}/listSecrets?api-version=${api_version}" \
    --query primaryKey \
    --output tsv \
    --only-show-errors
)"

if [[ -z "$subscription_key" ]]; then
  echo "The APIM consumer subscription key could not be retrieved." >&2
  exit 1
fi

response_file="$(mktemp)"
headers_file="$(mktemp)"
normalized_headers_file="$(mktemp)"
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
  rm -f "$response_file" "$headers_file" "$normalized_headers_file"
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

request_body='{"messages":[{"role":"user","content":"Reply with exactly: tracer bullet ready"}],"max_tokens":20,"temperature":0}'

send_chat_request() {
  curl --silent --show-error \
    --output "$response_file" \
    --dump-header "$headers_file" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Content-Type: application/json" \
    --header "Ocp-Apim-Subscription-Key: ${subscription_key}" \
    --header "x-profile-key: lob1-gpt4o-mini" \
    --data "$request_body" \
    "${gateway_url}/openai/chat/completions"
}

assert_profile_headers() {
  local expected_cache_outcome="$1"
  tr '[:upper:]' '[:lower:]' <"$headers_file" >"$normalized_headers_file"
  grep -q "x-profile-cache: ${expected_cache_outcome}" "$normalized_headers_file" &&
    grep -q 'x-backend-id: gpt-4o-mini' "$normalized_headers_file" &&
    grep -q 'x-token-limit-tpm: 8000' "$normalized_headers_file"
}

for attempt in {1..12}; do
  status_code="$(send_chat_request)"

  if assert_profile_headers miss; then
    break
  fi

  if [[ "$status_code" == "401" || "$status_code" == "403" || "$status_code" == "503" ]]; then
    sleep 15
    continue
  fi

  if [[ "$status_code" == "200" ]]; then
    echo "The cold request did not report the expected cache miss." >&2
    echo "Wait for the configured profile cache TTL to expire before rerunning the smoke test." >&2
    exit 1
  fi

  echo "Smoke request failed with HTTP $status_code." >&2
  jq -c '{error: (.error.message // .error // "Unexpected response")}' "$response_file" >&2 || true
  exit 1
done

if ! assert_profile_headers miss; then
  echo "APIM could not complete the cold profile lookup after waiting for role propagation." >&2
  exit 1
fi

for attempt in {1..10}; do
  status_code="$(send_chat_request)"
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
