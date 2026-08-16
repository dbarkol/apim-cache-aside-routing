# APIM cache-aside routing

This reference solution is being built in runnable slices. The first slice deploys a subscription-protected APIM Basic v2 chat operation that reaches one `gpt-4o-mini` deployment with APIM's system-assigned managed identity.

## Prerequisites

- Azure CLI authenticated with `az login`
- Azure Developer CLI
- `jq` and `xmllint`
- Permission to create role assignments and the resources in the selected subscription

## Deploy

```bash
azd auth login
azd env new
azd up
```

The repository defaults `AZURE_LOCATION` to `swedencentral`. To use another single region, set it before provisioning:

```bash
azd env set AZURE_LOCATION eastus2
```

The default model version is `2024-07-18`. Override it only with a version that the preflight reports as supporting `gpt-4o-mini` `GlobalStandard` in the selected region:

```bash
azd env set GPT4O_MINI_MODEL_VERSION 2024-07-18
```

The preprovision hook checks regional model availability and remaining quota before Azure deployment begins. It exits with corrective guidance and never selects a fallback region.

## Validate and smoke test

Run the fast local artifact check:

```bash
./scripts/validate.sh
```

After `azd up` completes, explicitly run the public black-box smoke path:

```bash
./scripts/smoke.sh
```

The smoke script retrieves the generated APIM subscription secret through the authenticated management API. No Foundry key or subscription secret is stored in source or emitted by Bicep.

Public endpoints are intentional in this reference slice. Private networking and production caller authentication are deferred. The subscription key protects sample access; later slices add Gateway Routing Profile selection and governance.
