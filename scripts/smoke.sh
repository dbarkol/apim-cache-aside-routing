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
trap 'rm -f "$response_file"' EXIT

request_body='{"messages":[{"role":"user","content":"Reply with exactly: tracer bullet ready"}],"max_tokens":20,"temperature":0}'

for attempt in {1..12}; do
  status_code="$(
    curl --silent --show-error \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST \
      --header "Content-Type: application/json" \
      --header "Ocp-Apim-Subscription-Key: ${subscription_key}" \
      --data "$request_body" \
      "${gateway_url}/openai/chat/completions"
  )"

  if [[ "$status_code" == "200" ]] &&
    jq -e '.choices[0].message.content | strings | length > 0' "$response_file" >/dev/null; then
    echo "Smoke test passed: APIM returned a model response."
    exit 0
  fi

  if [[ "$status_code" == "401" || "$status_code" == "403" ]]; then
    sleep 15
    continue
  fi

  echo "Smoke request failed with HTTP $status_code." >&2
  jq -c '{error: (.error.message // .error // "Unexpected response")}' "$response_file" >&2 || true
  exit 1
done

echo "APIM could not access the model after waiting for managed-identity role propagation." >&2
echo "Verify the Cognitive Services OpenAI User assignment on the Foundry resource and retry." >&2
exit 1
