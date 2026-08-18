#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
trap cleanup_test_files EXIT

sample_size="${PRIORITY_HEALTHY_SAMPLE_SIZE:-1}"
if ! [[ "$sample_size" =~ ^[0-9]+$ ]] || ((sample_size < 1)); then
  echo "PRIORITY_HEALTHY_SAMPLE_SIZE must be a positive integer." >&2
  exit 1
fi

log_analytics_name="$(azd env get-value LOG_ANALYTICS_NAME)"
mini_primary_deployment_name="$(azd env get-value MINI_PRIMARY_DEPLOYMENT_NAME)"
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

request_body='{"messages":[{"role":"user","content":"Reply with one word."}],"max_tokens":1,"temperature":0}'
sample_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "Sending $sample_size healthy requests through the lob1-gpt4-1 Gateway Routing Profile."
for ((request_number = 1; request_number <= sample_size; request_number++)); do
  status_code="$(send_chat_request lob1-gpt4-1)"
  assert_chat_success
  sleep 1
done

query_file="$(mktemp)"
cleanup_priority_routing() {
  rm -f "$query_file"
  cleanup_test_files
}
trap cleanup_priority_routing EXIT

analytics_query="
ApiManagementGatewayLogs
| where TimeGenerated >= datetime(${sample_started_at})
| where OperationId == 'chat-completions'
| where IsRequestSuccess == true
| where BackendUrl has '/openai/deployments/${mini_primary_deployment_name}'
    or BackendUrl has '/openai/deployments/${mini_overflow_deployment_name}'
| summarize Requests=count() by BackendUrl
| project BackendUrl, Requests
"

if wait_for_log_analytics_match \
  "$workspace_customer_id" \
  "$analytics_query" \
  "$query_file" \
  12 \
  15 \
  '
    any(.[]; (.BackendUrl // "" | contains($primary)) and (.Requests | tonumber) > 0)
    and (any(.[]; (.BackendUrl // "" | contains($overflow)) and (.Requests | tonumber) > 0) | not)
  ' \
  --arg primary "/openai/deployments/${mini_primary_deployment_name}" \
  --arg overflow "/openai/deployments/${mini_overflow_deployment_name}"; then
  echo "Priority routing test passed: healthy mini traffic used only the priority-1 backend."
  exit 0
fi

echo "Gateway logs did not show healthy mini traffic exclusively on the priority-1 backend." >&2
jq -c '.' "$query_file" >&2
exit 1
