# APIM cache-aside routing

This reference solution deploys a subscription-protected APIM Basic v2 chat operation that resolves a version-one Gateway Routing Profile from Azure Table Storage, caches its validated normalized form, and applies its backend and TPM configuration.

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

The profile cache TTL defaults to 300 seconds, and Table point reads time out after three seconds:

```bash
azd env set PROFILE_CACHE_TTL_SECONDS 300
azd env set PROFILE_LOOKUP_TIMEOUT_SECONDS 3
```

The compatibility token policy is deployed by default. The same profile schema can be deployed with the current policy:

```bash
azd env set TOKEN_LIMIT_POLICY_VARIANT llm-token-limit
```

The preprovision hook checks regional model availability and remaining quota before Azure deployment begins. It exits with corrective guidance and never selects a fallback region.

Provisioning idempotently replaces this sample entity:

| PartitionKey | RowKey | SchemaVersion | BackendId | MaxTpm |
|---|---|---:|---|---:|
| `profiles-v1` | `lob1-gpt4o-mini` | 1 | `gpt-4o-mini` | 8000 |

Unknown optional Table properties are ignored. The required fields are validated and normalized to `schemaVersion`, `backendId`, and `maxTpm` before the compact JSON is cached. Each row may configure any positive 32-bit integer `MaxTpm`; APIM applies that exact value to the row's token-limit counter.

## Validate and smoke test

Run the fast local artifact check:

```bash
./scripts/validate.sh
```

After `azd up` completes, explicitly run the public black-box smoke path:

```bash
./scripts/smoke.sh
```

The sample chat operation reads `x-profile-key` as a test adapter. It is not a production trust boundary; production callers should receive a Profile Key derived from validated identity and request context.

The smoke script retrieves the generated APIM subscription secret through the authenticated management API, temporarily enables non-secret diagnostic headers, and proves a model response, a cache miss followed by a hit, `gpt-4o-mini` backend selection, and the 8000 TPM branch. Run it immediately after deployment or after the configured cache TTL has expired.

No Foundry key or subscription secret is stored in source or emitted by Bicep. Public endpoints are intentional in this reference slice. Private networking and production caller authentication are deferred.

The sample storage account carries the organization-defined `SecurityControl=Ignore` exemption so its public Table endpoint is not rewritten to disabled by the inherited storage-network policy. Remove that exemption when adapting the solution to private networking.
