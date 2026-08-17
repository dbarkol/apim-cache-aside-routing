#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context

max_requests="${PRIORITY_OVERFLOW_MAX_REQUESTS:-12}"
if ! [[ "$max_requests" =~ ^[0-9]+$ ]] || ((max_requests < 1)); then
  echo "PRIORITY_OVERFLOW_MAX_REQUESTS must be a positive integer." >&2
  exit 1
fi

log_analytics_name="$(azd env get-value LOG_ANALYTICS_NAME)"
mini_primary_backend_id="$(azd env get-value MINI_PRIMARY_BACKEND_ID)"
mini_overflow_deployment_name="$(azd env get-value MINI_OVERFLOW_DEPLOYMENT_NAME)"
workspace_customer_id="$(
  az monitor log-analytics workspace show \
    --resource-group "$resource_group" \
    --workspace-name "$log_analytics_name" \
    --query customerId \
    --output tsv \
    --only-show-errors
)"
if [[ -z "$workspace_customer_id" ]]; then
  echo "The Log Analytics workspace customer ID could not be retrieved." >&2
  exit 1
fi

backend_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/backends/${mini_primary_backend_id}"
original_backend_file="$(mktemp)"
restore_backend_file="$(mktemp)"
fault_backend_file="$(mktemp)"
query_file="$(mktemp)"
backend_restored=false

az rest \
  --method get \
  --url "https://management.azure.com${backend_resource_id}?api-version=${api_version}" \
  --output json \
  --only-show-errors >"$original_backend_file"

jq '{properties: .properties}' "$original_backend_file" >"$restore_backend_file"
jq --arg fault_url "${gateway_url}/internal/priority-fault" '
  .properties.url = $fault_url
  | {properties: .properties}
' "$original_backend_file" >"$fault_backend_file"

restore_primary_backend() {
  az rest \
    --method put \
    --url "https://management.azure.com${backend_resource_id}?api-version=${api_version}" \
    --headers "Content-Type=application/json" \
    --body "@${restore_backend_file}" \
    --output none \
    --only-show-errors
  backend_restored=true
}

cleanup_priority_overflow() {
  if [[ "$backend_restored" != true ]]; then
    restore_primary_backend >/dev/null 2>&1 || true
  fi
  rm -f "$original_backend_file" "$restore_backend_file" "$fault_backend_file" "$query_file"
  cleanup_test_files
}
trap cleanup_priority_overflow EXIT

az rest \
  --method put \
  --url "https://management.azure.com${backend_resource_id}?api-version=${api_version}" \
  --headers "Content-Type=application/json" \
  --body "@${fault_backend_file}" \
  --output none \
  --only-show-errors

echo "Waiting for the induced priority-1 backend fault to propagate."
sleep 30

request_body='{"messages":[{"role":"user","content":"Reply with one word."}],"max_tokens":1,"temperature":0}'
fault_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
analytics_query="
ApiManagementGatewayLogs
| where TimeGenerated >= datetime(${fault_started_at})
| where OperationId == 'chat-completions'
| where IsRequestSuccess == true
| where BackendUrl has '/openai/deployments/${mini_overflow_deployment_name}'
| summarize Requests=count() by BackendUrl
| project BackendUrl, Requests
"

echo "Sending requests until APIM makes the priority-2 backend eligible."
for ((request_number = 1; request_number <= max_requests; request_number++)); do
  status_code="$(send_chat_request lob1-gpt4-1)" || status_code="000"

  az monitor log-analytics query \
    --workspace "$workspace_customer_id" \
    --analytics-query "$analytics_query" \
    --timespan PT1H \
    --output json \
    --only-show-errors >"$query_file"

  if jq -e '
    any(.[]; (.BackendUrl // "" | contains("/openai/deployments/")) and (.Requests | tonumber) > 0)
  ' "$query_file" >/dev/null; then
    restore_primary_backend
    echo "Priority overflow test passed: the priority-2 backend eventually served traffic."
    exit 0
  fi

  sleep 5
done

for attempt in {1..12}; do
  az monitor log-analytics query \
    --workspace "$workspace_customer_id" \
    --analytics-query "$analytics_query" \
    --timespan PT1H \
    --output json \
    --only-show-errors >"$query_file"

  if jq -e '
    any(.[]; (.BackendUrl // "" | contains("/openai/deployments/")) and (.Requests | tonumber) > 0)
  ' "$query_file" >/dev/null; then
    restore_primary_backend
    echo "Priority overflow test passed: the priority-2 backend eventually served traffic."
    exit 0
  fi

  sleep 15
done

echo "Gateway logs did not show successful priority-2 traffic after the induced primary fault." >&2
jq -c '.' "$query_file" >&2
exit 1
