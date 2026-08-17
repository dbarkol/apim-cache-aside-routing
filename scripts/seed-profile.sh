#!/usr/bin/env bash
set -euo pipefail

for command_name in az azd curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command '$command_name' was not found." >&2
    exit 1
  fi
done

storage_account_name="$(azd env get-value STORAGE_ACCOUNT_NAME)"
profile_url="https://${storage_account_name}.table.core.windows.net/gatewayprofiles(PartitionKey='profiles-v1',RowKey='lob1-gpt4o-mini')"
profile='{"PartitionKey":"profiles-v1","RowKey":"lob1-gpt4o-mini","SchemaVersion":1,"SchemaVersion@odata.type":"Edm.Int32","BackendId":"gpt-4o-mini","MaxTpm":8000,"MaxTpm@odata.type":"Edm.Int32"}'

for attempt in {1..12}; do
  access_token="$(
    az account get-access-token \
      --resource https://storage.azure.com/ \
      --query accessToken \
      --output tsv \
      --only-show-errors
  )"
  request_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"

  if curl --fail-with-body --silent --show-error \
    --request PUT \
    --header "Authorization: Bearer ${access_token}" \
    --header "Content-Type: application/json" \
    --header "x-ms-date: ${request_date}" \
    --header "x-ms-version: 2019-02-02" \
    --data "$profile" \
    "$profile_url"; then
    echo "Gateway Routing Profile 'lob1-gpt4o-mini' is seeded."
    exit 0
  fi

  sleep 10
done

echo "Could not seed the Gateway Routing Profile after waiting for role propagation." >&2
exit 1
