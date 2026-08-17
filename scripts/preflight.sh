#!/usr/bin/env bash
set -euo pipefail

location="${AZURE_LOCATION:-swedencentral}"
gpt4o_mini_model_version="${GPT4O_MINI_MODEL_VERSION:-2024-07-18}"
round_robin_model_name="${ROUND_ROBIN_MODEL_NAME:-gpt-4o-mini}"
round_robin_model_version="${ROUND_ROBIN_MODEL_VERSION:-2024-07-18}"
priority_model_version="${PRIORITY_MODEL_VERSION:-2025-04-14}"

if [[ -z "${AZURE_LOCATION:-}" ]]; then
  azd env set AZURE_LOCATION "$location" >/dev/null
fi

if [[ -z "${GPT4O_MINI_MODEL_VERSION:-}" ]]; then
  azd env set GPT4O_MINI_MODEL_VERSION "$gpt4o_mini_model_version" >/dev/null
fi

if [[ -z "${ROUND_ROBIN_MODEL_NAME:-}" ]]; then
  azd env set ROUND_ROBIN_MODEL_NAME "$round_robin_model_name" >/dev/null
fi

if [[ -z "${ROUND_ROBIN_MODEL_VERSION:-}" ]]; then
  azd env set ROUND_ROBIN_MODEL_VERSION "$round_robin_model_version" >/dev/null
fi

if [[ -z "${PRIORITY_MODEL_VERSION:-}" ]]; then
  azd env set PRIORITY_MODEL_VERSION "$priority_model_version" >/dev/null
fi

if ! az account show --only-show-errors >/dev/null 2>&1; then
  echo "Azure CLI authentication is required. Run 'az login' and retry." >&2
  exit 1
fi

models_file="$(mktemp)"
usage_file="$(mktemp)"
trap 'rm -f "$models_file" "$usage_file"' EXIT

if ! az cognitiveservices model list \
  --location "$location" \
  --output json \
  --only-show-errors >"$models_file"; then
  echo "Unable to query model availability in '$location'. Verify the region and Microsoft.CognitiveServices provider registration." >&2
  exit 1
fi

check_model_availability() {
  local model_name="$1"
  local model_version="$2"

  if ! jq -e \
    --arg name "$model_name" \
    --arg version "$model_version" \
    'any(.[];
      .model.name == $name
      and .model.version == $version
      and any(.model.skus[]?; .name == "GlobalStandard")
    )' "$models_file" >/dev/null; then
    echo "$model_name version '$model_version' with GlobalStandard is unavailable in '$location'." >&2
    echo "Choose one region and supported version; provisioning will not move the model to another region." >&2
    exit 1
  fi
}

check_model_availability gpt-4o-mini "$gpt4o_mini_model_version"
if [[ "$round_robin_model_name" != "gpt-4o-mini" ||
  "$round_robin_model_version" != "$gpt4o_mini_model_version" ]]; then
  check_model_availability "$round_robin_model_name" "$round_robin_model_version"
fi
if [[ "$round_robin_model_name" != "gpt-4.1-mini" ||
  "$round_robin_model_version" != "$priority_model_version" ]]; then
  check_model_availability gpt-4.1-mini "$priority_model_version"
fi

if ! az cognitiveservices usage list \
  --location "$location" \
  --output json \
  --only-show-errors >"$usage_file"; then
  echo "Unable to query Cognitive Services quota in '$location'. Check subscription permissions and retry." >&2
  exit 1
fi

check_model_quota() {
  local model_name="$1"
  local required_capacity="$2"
  local quota_model_name="$model_name"
  local available_capacity

  if [[ "$quota_model_name" == gpt-4.1* ]]; then
    quota_model_name="${quota_model_name/gpt-4.1/gpt4.1}"
  fi

  available_capacity="$(
    jq -r \
      --arg quota_name "OpenAI.GlobalStandard.${quota_model_name}" '
    [
      .[]
      | select(.name.value == $quota_name)
      | (.limit - .currentValue)
    ]
    | if length == 0 then -1 else max end
  ' "$usage_file"
  )"

  if [[ "$available_capacity" == "-1" ]]; then
    echo "No GlobalStandard $model_name quota record was found in '$location'." >&2
    echo "Request model quota for the selected region before provisioning." >&2
    exit 1
  fi

  if ! awk "BEGIN { exit !($available_capacity >= $required_capacity) }"; then
    echo "Insufficient GlobalStandard $model_name quota in '$location': capacity $required_capacity is required." >&2
    echo "Free capacity or request a quota increase, then rerun 'azd up'." >&2
    exit 1
  fi
}

round_robin_required_capacity=2
priority_required_capacity=2
if [[ "$round_robin_model_name" == "gpt-4o-mini" ]]; then
  round_robin_required_capacity=3
  check_model_quota "$round_robin_model_name" "$round_robin_required_capacity"
  check_model_quota gpt-4.1-mini "$priority_required_capacity"
elif [[ "$round_robin_model_name" == "gpt-4.1-mini" ]]; then
  priority_required_capacity=4
  check_model_quota gpt-4o-mini 1
  check_model_quota gpt-4.1-mini "$priority_required_capacity"
else
  check_model_quota gpt-4o-mini 1
  check_model_quota gpt-4.1-mini "$priority_required_capacity"
  check_model_quota "$round_robin_model_name" "$round_robin_required_capacity"
fi

echo "Model availability and quota preflight passed for gpt-4o-mini, $round_robin_model_name, and gpt-4.1-mini in $location."
