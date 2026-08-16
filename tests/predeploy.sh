#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_file="$(mktemp)"
trap 'rm -f "$template_file"' EXIT

"$repo_root/scripts/validate.sh" --template-out "$template_file"

jq -e '
  .parameters.location.defaultValue == "swedencentral"
  and .parameters.gpt4oMiniModelVersion.type == "string"
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].sku.name == "BasicV2")
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.Storage/storageAccounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.OperationalInsights/workspaces")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.Insights/components")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/projects")][0].identity.type == "SystemAssigned")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/deployments")][0].sku.name == "GlobalStandard")
  and ([.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/deployments")][0].sku.capacity == 1)
  and ([.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")] | length >= 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/apis/operations")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/products")] | length == 1)
  and ([.. | objects | select(.type? == "Microsoft.ApiManagement/service/subscriptions")] | length == 1)
  and ([.outputs | to_entries[] | .key | ascii_downcase | test("key|secret|token")] | any | not)
' "$template_file" >/dev/null

grep -q 'resource="https://cognitiveservices.azure.com"' \
  "$repo_root/policies/chat/direct.xml"
grep -q '<set-backend-service backend-id="gpt-4o-mini" />' \
  "$repo_root/policies/chat/direct.xml"

echo "Predeployment contract is valid."
