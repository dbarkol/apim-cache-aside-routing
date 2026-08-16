#!/usr/bin/env bash
set -euo pipefail

location="${AZURE_LOCATION:-swedencentral}"
model_version="${GPT4O_MINI_MODEL_VERSION:-2024-07-18}"

if [[ -z "${AZURE_LOCATION:-}" ]]; then
  azd env set AZURE_LOCATION "$location" >/dev/null
fi

if [[ -z "${GPT4O_MINI_MODEL_VERSION:-}" ]]; then
  azd env set GPT4O_MINI_MODEL_VERSION "$model_version" >/dev/null
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

if ! jq -e \
  --arg version "$model_version" \
  'any(.[];
    .model.name == "gpt-4o-mini"
    and .model.version == $version
    and any(.model.skus[]?; .name == "GlobalStandard")
  )' "$models_file" >/dev/null; then
  echo "gpt-4o-mini version '$model_version' with GlobalStandard is unavailable in '$location'." >&2
  echo "Choose one region and supported version; provisioning will not move the model to another region." >&2
  exit 1
fi

if ! az cognitiveservices usage list \
  --location "$location" \
  --output json \
  --only-show-errors >"$usage_file"; then
  echo "Unable to query Cognitive Services quota in '$location'. Check subscription permissions and retry." >&2
  exit 1
fi

available_capacity="$(
  jq -r '
    [
      .[]
      | select(.name.value == "OpenAI.GlobalStandard.gpt-4o-mini")
      | (.limit - .currentValue)
    ]
    | if length == 0 then -1 else max end
  ' "$usage_file"
)"

if [[ "$available_capacity" == "-1" ]]; then
  echo "No GlobalStandard gpt-4o-mini quota record was found in '$location'." >&2
  echo "Request model quota for the selected region before provisioning." >&2
  exit 1
fi

if ! awk "BEGIN { exit !($available_capacity >= 1) }"; then
  echo "Insufficient GlobalStandard gpt-4o-mini quota in '$location': capacity 1 is required." >&2
  echo "Free capacity or request a quota increase, then rerun 'azd up'." >&2
  exit 1
fi

echo "Model availability and quota preflight passed for $location."
