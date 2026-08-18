#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
trap cleanup_test_files EXIT

sample_size="${ROUND_ROBIN_SAMPLE_SIZE:-20}"
if ! [[ "$sample_size" =~ ^[0-9]+$ ]] || ((sample_size < 10)); then
  echo "ROUND_ROBIN_SAMPLE_SIZE must be an integer of at least 10." >&2
  exit 1
fi

log_analytics_name="$(azd env get-value LOG_ANALYTICS_NAME)"
round_robin_deployment_1_name="$(azd env get-value ROUND_ROBIN_DEPLOYMENT_1_NAME)"
round_robin_deployment_2_name="$(azd env get-value ROUND_ROBIN_DEPLOYMENT_2_NAME)"
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

echo "Sending $sample_size requests through the test-nano Gateway Routing Profile."
for ((request_number = 1; request_number <= sample_size; request_number++)); do
  status_code="$(send_chat_request test-nano)"
  assert_chat_success
  sleep 1
done

query_file="$(mktemp)"
cleanup_round_robin() {
  rm -f "$query_file"
  cleanup_test_files
}
trap cleanup_round_robin EXIT

analytics_query="
ApiManagementGatewayLogs
| where TimeGenerated >= datetime(${sample_started_at})
| where OperationId == 'chat-completions'
| where IsRequestSuccess == true
| where BackendUrl has '/openai/deployments/${round_robin_deployment_1_name}'
    or BackendUrl has '/openai/deployments/${round_robin_deployment_2_name}'
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
    any(.[]; (.BackendUrl // "" | contains($deployment_1)) and (.Requests | tonumber) > 0)
    and any(.[]; (.BackendUrl // "" | contains($deployment_2)) and (.Requests | tonumber) > 0)
  ' \
  --arg deployment_1 "/openai/deployments/${round_robin_deployment_1_name}" \
  --arg deployment_2 "/openai/deployments/${round_robin_deployment_2_name}"; then
  echo "Round-robin test passed: both healthy nano pool members served requests."
  exit 0
fi

echo "Gateway logs did not show nonzero participation by both nano pool members." >&2
jq -c '.' "$query_file" >&2
exit 1
