#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_file=''
remove_template=false

if [[ "${1:-}" == "--template-out" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "--template-out requires a file path." >&2
    exit 1
  fi
  template_file="$2"
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--template-out <path>]" >&2
  exit 1
else
  template_file="$(mktemp)"
  remove_template=true
fi

cleanup() {
  if [[ "$remove_template" == true ]]; then
    rm -f "$template_file"
  fi
}
trap cleanup EXIT

for command_name in az azd jq xmllint; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command '$command_name' was not found." >&2
    exit 1
  fi
done

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$template_file" \
  --only-show-errors

xmllint --noout \
  "$repo_root/policies/chat/azure-openai-token-limit.xml" \
  "$repo_root/policies/chat/llm-token-limit.xml"
bash -n "$repo_root/scripts/preflight.sh"
bash -n "$repo_root/scripts/seed-profile.sh"
bash -n "$repo_root/scripts/smoke.sh"
bash -n "$repo_root/scripts/test.sh"
bash -n "$repo_root/tests/test-helpers.sh"
bash -n "$repo_root/tests/api-contract.sh"
bash -n "$repo_root/tests/faults.sh"
azd show --output json >/dev/null

echo "Azure Developer CLI, Bicep, policy XML, and scripts are valid."
