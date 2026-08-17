# APIM cache-aside routing

This reference solution deploys an APIM Basic v2 chat operation that resolves a version-one Gateway Routing Profile from Azure Table Storage, plus a separately protected Profile Refresh operation that validates and asynchronously replaces one cached profile.

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

The single backend and the two equivalent round-robin deployments default to `gpt-4o-mini` version `2024-07-18`. The priority pool uses two `gpt-4.1-mini` deployments at version `2025-04-14`. Model versions are configurable, and preflight requires every selected `GlobalStandard` model and the combined capacity in the chosen region:

```bash
azd env set GPT4O_MINI_MODEL_VERSION 2024-07-18
azd env set ROUND_ROBIN_MODEL_NAME gpt-4o-mini
azd env set ROUND_ROBIN_MODEL_VERSION 2024-07-18
azd env set PRIORITY_MODEL_VERSION 2025-04-14
```

The priority-1 backend circuit breaker defaults to three failures in one minute and remains open for 30 seconds. These are sample tuning points, not production recommendations:

```bash
azd env set MINI_PRIMARY_CIRCUIT_BREAKER_FAILURE_COUNT 3
azd env set MINI_PRIMARY_CIRCUIT_BREAKER_SAMPLING_INTERVAL PT1M
azd env set MINI_PRIMARY_CIRCUIT_BREAKER_TRIP_DURATION PT30S
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

Provisioning creates all model deployments sequentially. It registers managed-identity-authenticated APIM backends, adds the equivalent round-robin deployments to the equal-priority `nano-pool`, and adds the two mini deployments to `mini-pool` at priorities 1 and 2. The mini topology models PTU-to-pay-as-you-go overflow without provisioning real PTU.

Provisioning idempotently replaces these sample entities:

| PartitionKey | RowKey | SchemaVersion | BackendId | MaxTpm |
|---|---|---:|---|---:|
| `profiles-v1` | `test-nano` | 1 | `nano-pool` | 500 |
| `profiles-v1` | `lob1-gpt4-1` | 1 | `mini-pool` | 4000 |
| `profiles-v1` | `lob1-gpt4o-mini` | 1 | `gpt-4o-mini` | 8000 |

Unknown optional Table properties are ignored. The required fields are validated and normalized to `schemaVersion`, `backendId`, and `maxTpm` before the compact JSON is cached. Each row may configure any positive 32-bit integer `MaxTpm`; APIM applies that exact value to the row's token-limit counter.

## Refresh one profile

`POST /internal/profiles/{profileKey}/refresh` is available only through the dedicated `gateway-profile-admin` product and its separate sample subscription. The operation validates the Profile Key, point-reads Table Storage with managed identity, applies the same validation and normalization fragment as a runtime cache miss, and submits only the normalized profile to APIM's built-in cache.

A successful request returns `202 Accepted`. APIM cache storage is asynchronous, so the response does not claim that the replacement is immediately visible. The operation never writes to the source Table entity. Bulk warming remains external automation that invokes this single-key operation once per known key.

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

The suite retrieves the generated consumer and administrator APIM subscription secrets through the authenticated management API and uses temporary, uniquely named Table rows. It proves a model response, cache miss followed by cache hit, `gpt-4o-mini` backend selection, the 8000 TPM branch, Profile Key validation, malformed and missing profile rejection, unknown-backend failure, per-key cold-lookup throttling, sanitized errors, immediate recovery after a missing or invalid row is corrected, refresh authorization, source immutability, and eventual visibility of a refreshed profile. It also queries `ApiManagementGatewayLogs.BackendUrl` to prove participation by both healthy nano pool members and exclusive priority-1 routing for healthy mini traffic. Temporary rows and settings are restored during cleanup.

Fault testing temporarily replaces the APIM Table endpoint named value to verify the sanitized `503` contract. It also temporarily points the priority-1 mini backend at a test-only APIM endpoint that deterministically returns `503` with `Retry-After`, then eventually observes successful priority-2 traffic before restoring the original backend. The test does not assume a fixed failover request count or timing. Run the fault suite explicitly:

```bash
./scripts/test.sh --faults
```

Client-visible failures contain only a generic code and message plus the APIM correlation identifier. They do not expose Profile Keys, stored profile content, validation details, credentials, or backend configuration.

No Foundry key or subscription secret is stored in source or emitted by Bicep. Public endpoints are intentional in this reference slice. Private networking and production caller authentication are deferred.

The sample storage account carries the organization-defined `SecurityControl=Ignore` exemption so its public Table endpoint is not rewritten to disabled by the inherited storage-network policy. Remove that exemption when adapting the solution to private networking.
