#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_faults=false

if [[ "${1:-}" == "--faults" ]]; then
  run_faults=true
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--faults]" >&2
  exit 1
fi

"$repo_root/tests/predeploy.sh"
"$repo_root/scripts/smoke.sh"
"$repo_root/tests/api-contract.sh"
"$repo_root/tests/refresh.sh"

if [[ "$run_faults" == true ]]; then
  "$repo_root/tests/faults.sh"
fi

echo "Gateway Routing Profile tests passed."
