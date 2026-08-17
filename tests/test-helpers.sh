#!/usr/bin/env bash

require_test_commands() {
  local command_name
  for command_name in az azd curl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Required command '$command_name' was not found." >&2
      exit 1
    fi
  done
}

initialize_test_context() {
  require_test_commands

  resource_group="$(azd env get-value AZURE_RESOURCE_GROUP)"
  apim_name="$(azd env get-value APIM_NAME)"
  gateway_url="$(azd env get-value APIM_GATEWAY_URL)"
  storage_account_name="$(azd env get-value STORAGE_ACCOUNT_NAME)"
  subscription_id="$(az account show --query id --output tsv --only-show-errors)"
  api_version="2024-05-01"
  consumer_subscription_key="$(get_subscription_key gateway-consumer-sub)"
  storage_access_token="$(
    az account get-access-token \
      --resource https://storage.azure.com/ \
      --query accessToken \
      --output tsv \
      --only-show-errors
  )"

  if [[ -z "$consumer_subscription_key" || -z "$storage_access_token" ]]; then
    echo "Required APIM or Table Storage test credentials could not be retrieved." >&2
    exit 1
  fi

  response_file="$(mktemp)"
  headers_file="$(mktemp)"
  normalized_headers_file="$(mktemp)"
  request_body='{"messages":[{"role":"user","content":"Reply with exactly: routing profile ready"}],"max_tokens":20,"temperature":0}'
}

get_subscription_key() {
  local subscription_name="$1"
  local subscription_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${apim_name}/subscriptions/${subscription_name}"

  az rest \
    --method post \
    --url "https://management.azure.com${subscription_resource_id}/listSecrets?api-version=${api_version}" \
    --query primaryKey \
    --output tsv \
    --only-show-errors
}

cleanup_test_files() {
  rm -f "$response_file" "$headers_file" "$normalized_headers_file"
}

profile_entity_url() {
  local profile_key="$1"
  printf "https://%s.table.core.windows.net/gatewayprofiles(PartitionKey='profiles-v1',RowKey='%s')" \
    "$storage_account_name" "$profile_key"
}

table_upsert_profile() {
  local profile_key="$1"
  local profile_body="$2"
  local request_date
  request_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"

  curl --fail-with-body --silent --show-error \
    --request PUT \
    --header "Authorization: Bearer ${storage_access_token}" \
    --header "Content-Type: application/json" \
    --header "x-ms-date: ${request_date}" \
    --header "x-ms-version: 2019-02-02" \
    --data "$profile_body" \
    "$(profile_entity_url "$profile_key")" >/dev/null
}

table_delete_profile() {
  local profile_key="$1"
  local request_date
  request_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"

  curl --silent --show-error \
    --request DELETE \
    --header "Authorization: Bearer ${storage_access_token}" \
    --header "If-Match: *" \
    --header "x-ms-date: ${request_date}" \
    --header "x-ms-version: 2019-02-02" \
    "$(profile_entity_url "$profile_key")" >/dev/null 2>&1 || true
}

table_get_profile() {
  local profile_key="$1"

  az rest \
    --method get \
    --url "$(profile_entity_url "$profile_key")" \
    --resource https://storage.azure.com/ \
    --headers "Accept=application/json;odata=nometadata" x-ms-version=2019-02-02 \
    --output json \
    --only-show-errors
}

valid_profile_body() {
  local profile_key="$1"
  local max_tpm="${2:-8000}"
  jq -cn --arg profile_key "$profile_key" --argjson max_tpm "$max_tpm" '{
    PartitionKey: "profiles-v1",
    RowKey: $profile_key,
    SchemaVersion: 1,
    "SchemaVersion@odata.type": "Edm.Int32",
    BackendId: "gpt-4o-mini",
    MaxTpm: $max_tpm,
    "MaxTpm@odata.type": "Edm.Int32"
  }'
}

send_chat_request() {
  local profile_key="${1:-}"
  local curl_arguments=(
    --silent
    --show-error
    --connect-timeout 15
    --max-time 45
    --output "$response_file"
    --dump-header "$headers_file"
    --write-out '%{http_code}'
    --request POST
    --header "Content-Type: application/json"
    --header "Ocp-Apim-Subscription-Key: ${consumer_subscription_key}"
    --data "$request_body"
  )

  if [[ -n "$profile_key" ]]; then
    curl_arguments+=(--header "x-profile-key: ${profile_key}")
  fi

  curl "${curl_arguments[@]}" "${gateway_url}/openai/chat/completions"
}

send_refresh_request() {
  local request_subscription_key="$1"
  local profile_key="$2"

  curl \
    --silent \
    --show-error \
    --connect-timeout 15 \
    --max-time 45 \
    --output "$response_file" \
    --dump-header "$headers_file" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Content-Type: application/json" \
    --header "Ocp-Apim-Subscription-Key: ${request_subscription_key}" \
    "${gateway_url}/internal/profiles/${profile_key}/refresh"
}

assert_error_response() {
  local expected_status="$1"
  local expected_code="$2"
  shift 2

  if [[ "$status_code" != "$expected_status" ]]; then
    echo "Expected HTTP $expected_status but received $status_code." >&2
    cat "$response_file" >&2
    exit 1
  fi

  if ! jq -e --arg expected_code "$expected_code" '
    .error.code == $expected_code
    and (.error.message | type == "string" and length > 0)
    and (.error.correlationId | type == "string" and length > 0)
    and ((.error | keys | sort) == ["code", "correlationId", "message"])
  ' "$response_file" >/dev/null; then
    echo "The HTTP $expected_status response did not match the sanitized error contract." >&2
    cat "$response_file" >&2
    exit 1
  fi

  tr '[:upper:]' '[:lower:]' <"$headers_file" >"$normalized_headers_file"
  if ! grep -q '^content-type: application/json' "$normalized_headers_file"; then
    echo "The HTTP $expected_status response was not JSON." >&2
    exit 1
  fi

  local sensitive_value
  for sensitive_value in "$@"; do
    if [[ -n "$sensitive_value" ]] && grep -Fq "$sensitive_value" "$response_file"; then
      echo "The HTTP $expected_status response exposed tested routing detail '$sensitive_value'." >&2
      exit 1
    fi
  done
}

assert_chat_success() {
  if [[ "$status_code" != "200" ]] ||
    ! jq -e '.choices[0].message.content | strings | length > 0' "$response_file" >/dev/null; then
    echo "Expected a successful model response but received HTTP $status_code." >&2
    cat "$response_file" >&2
    exit 1
  fi
}
