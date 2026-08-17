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

After `azd up` completes, explicitly run the core public black-box suite:

```bash
./scripts/test.sh
```

The sample chat operation reads `x-profile-key` as a test adapter. It is not a production trust boundary; production callers should receive a Profile Key derived from validated identity and request context.

The suite retrieves the generated APIM subscription secret through the authenticated management API and uses temporary, uniquely named Table rows. It proves a model response, cache miss followed by cache hit, `gpt-4o-mini` backend selection, the 8000 TPM branch, Profile Key validation, malformed and missing profile rejection, unknown-backend failure, per-key cold-lookup throttling, sanitized errors, and immediate recovery after a missing or invalid row is corrected. Temporary rows and settings are restored during cleanup.

Dependency-fault testing temporarily replaces the APIM Table endpoint named value, verifies the sanitized `503` contract, and restores the original value. Run the complete issue #4 error contract explicitly:

```bash
./scripts/test.sh --faults
```

Client-visible failures contain only a generic code and message plus the APIM correlation identifier. They do not expose Profile Keys, stored profile content, validation details, credentials, or backend configuration.

No Foundry key or subscription secret is stored in source or emitted by Bicep. Public endpoints are intentional in this reference slice. Private networking and production caller authentication are deferred.

The sample storage account carries the organization-defined `SecurityControl=Ignore` exemption so its public Table endpoint is not rewritten to disabled by the inherited storage-network policy. Remove that exemption when adapting the solution to private networking.
