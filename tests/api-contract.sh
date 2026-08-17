#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-helpers.sh
source "$repo_root/tests/test-helpers.sh"

initialize_test_context
created_profile_keys=()

cleanup() {
  local profile_key
  for profile_key in "${created_profile_keys[@]}"; do
    table_delete_profile "$profile_key"
  done
  cleanup_test_files
}
trap cleanup EXIT

suffix="$(date +%s)-${RANDOM}"
next_profile_key() {
  printf 'issue4-%s-%s' "$1" "$suffix"
}

track_profile() {
  created_profile_keys+=("$1")
}

assert_profile_failure() {
  local profile_key="$1"
  local profile_body="$2"
  shift 2
  echo "Testing fail-closed profile '$profile_key'."
  track_profile "$profile_key"
  table_upsert_profile "$profile_key" "$profile_body"
  status_code="$(send_chat_request "$profile_key")"
  assert_error_response 500 RoutingConfigurationUnavailable "$profile_key" "$@"
}

status_code="$(send_chat_request)"
assert_error_response 400 InvalidRequest

for invalid_key in "contains space" "contains/slash" "$(printf 'a%.0s' {1..129})"; do
  status_code="$(send_chat_request "$invalid_key")"
  assert_error_response 400 InvalidRequest "$invalid_key"
done

maximum_length_key="$(printf 'a%.0s' {1..128})"
status_code="$(send_chat_request "$maximum_length_key")"
assert_error_response 500 RoutingConfigurationUnavailable "$maximum_length_key"

unsupported_schema_key="$(next_profile_key unsupported-schema)"
unsupported_schema_body="$(jq -cn --arg key "$unsupported_schema_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 2,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
  MaxTpm: 8000, "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$unsupported_schema_key" "$unsupported_schema_body" "SchemaVersion"

missing_schema_key="$(next_profile_key missing-schema)"
missing_schema_body="$(jq -cn --arg key "$missing_schema_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, BackendId: "gpt-4o-mini",
  MaxTpm: 8000, "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$missing_schema_key" "$missing_schema_body" "SchemaVersion"

missing_backend_key="$(next_profile_key missing-backend)"
missing_backend_body="$(jq -cn --arg key "$missing_backend_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", MaxTpm: 8000,
  "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$missing_backend_key" "$missing_backend_body" "BackendId"

missing_tpm_key="$(next_profile_key missing-tpm)"
missing_tpm_body="$(jq -cn --arg key "$missing_tpm_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini"
}')"
assert_profile_failure "$missing_tpm_key" "$missing_tpm_body" "MaxTpm"

schema_type_key="$(next_profile_key schema-type)"
schema_type_body="$(jq -cn --arg key "$schema_type_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: "1",
  BackendId: "gpt-4o-mini", MaxTpm: 8000,
  "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$schema_type_key" "$schema_type_body" "SchemaVersion"

backend_type_key="$(next_profile_key backend-type)"
backend_type_body="$(jq -cn --arg key "$backend_type_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: 7,
  "BackendId@odata.type": "Edm.Int32", MaxTpm: 8000,
  "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$backend_type_key" "$backend_type_body" "BackendId"

malformed_backend_key="$(next_profile_key malformed-backend)"
malformed_backend_body="$(jq -cn --arg key "$malformed_backend_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "invalid/backend",
  MaxTpm: 8000, "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$malformed_backend_key" "$malformed_backend_body" "invalid/backend"

for invalid_tpm in 0 -1; do
  tpm_key="$(next_profile_key "tpm-${invalid_tpm#-}")"
  tpm_body="$(jq -cn --arg key "$tpm_key" --argjson max_tpm "$invalid_tpm" '{
    PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
    "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
    MaxTpm: $max_tpm, "MaxTpm@odata.type": "Edm.Int32"
  }')"
  assert_profile_failure "$tpm_key" "$tpm_body"
done

overflow_tpm_key="$(next_profile_key overflow-tpm)"
overflow_tpm_body="$(jq -cn --arg key "$overflow_tpm_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
  MaxTpm: "2147483648", "MaxTpm@odata.type": "Edm.Int64"
}')"
assert_profile_failure "$overflow_tpm_key" "$overflow_tpm_body" "2147483648"

typed_tpm_key="$(next_profile_key typed-tpm)"
typed_tpm_body="$(jq -cn --arg key "$typed_tpm_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
  MaxTpm: "8000"
}')"
assert_profile_failure "$typed_tpm_key" "$typed_tpm_body" "MaxTpm"

unknown_backend_key="$(next_profile_key unknown-backend)"
unknown_backend_body="$(jq -cn --arg key "$unknown_backend_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "backend-does-not-exist",
  MaxTpm: 8000, "MaxTpm@odata.type": "Edm.Int32"
}')"
assert_profile_failure "$unknown_backend_key" "$unknown_backend_body" "backend-does-not-exist"

# Missing rows are not negatively cached: newly created profiles are immediately eligible.
new_profile_key="$(next_profile_key newly-created)"
track_profile "$new_profile_key"
status_code="$(send_chat_request "$new_profile_key")"
assert_error_response 500 RoutingConfigurationUnavailable "$new_profile_key"
table_upsert_profile "$new_profile_key" "$(valid_profile_body "$new_profile_key")"
status_code="$(send_chat_request "$new_profile_key")"
assert_chat_success

# Invalid rows are not cached: corrected profiles are immediately eligible.
corrected_profile_key="$(next_profile_key corrected)"
track_profile "$corrected_profile_key"
corrected_invalid_body="$(jq -cn --arg key "$corrected_profile_key" '{
  PartitionKey: "profiles-v1", RowKey: $key, SchemaVersion: 1,
  "SchemaVersion@odata.type": "Edm.Int32", BackendId: "gpt-4o-mini",
  MaxTpm: "invalid"
}')"
table_upsert_profile "$corrected_profile_key" "$corrected_invalid_body"
status_code="$(send_chat_request "$corrected_profile_key")"
assert_error_response 500 RoutingConfigurationUnavailable "$corrected_profile_key" "invalid"
table_upsert_profile "$corrected_profile_key" "$(valid_profile_body "$corrected_profile_key")"
status_code="$(send_chat_request "$corrected_profile_key")"
assert_chat_success

rate_limited_key="$(next_profile_key rate-limited)"
for attempt in {1..10}; do
  status_code="$(send_chat_request "$rate_limited_key")"
  assert_error_response 500 RoutingConfigurationUnavailable "$rate_limited_key"
done
rate_limit_observed=false
for attempt in {1..5}; do
  status_code="$(send_chat_request "$rate_limited_key")"
  if [[ "$status_code" == "429" ]]; then
    assert_error_response 429 TooManyRequests "$rate_limited_key"
    rate_limit_observed=true
    break
  fi
  assert_error_response 500 RoutingConfigurationUnavailable "$rate_limited_key"
done
if [[ "$rate_limit_observed" != true ]]; then
  echo "The per-Profile-Key miss limit did not return HTTP 429." >&2
  exit 1
fi

echo "Deployed API contract passed for 400, 429, and fail-closed 500 responses."
