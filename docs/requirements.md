# Gateway Routing Profile Requirements

## Purpose

Build a deployable Azure API Management reference solution that retrieves a request-specific Gateway Routing Profile from Azure Table Storage, caches the validated profile in APIM's built-in cache, and applies its backend-routing and token-limit configuration.

The solution focuses on profile retrieval, caching, validation, and application. Production authentication and derivation of a trusted Profile Key are extension points.

## Source material

- [GenAI Gateway — Per-(LOB, Model) Config Lookup](./references/genai-gateway-config-lookup-design.md)
- [Azure API Management Cache-Aside Routing research](./research/investigate-azure-api-management-cache-aside-routi.md)
- [Domain language](../CONTEXT.md)

## Functional requirements

### Deployment

1. The repository must deploy through Azure Developer CLI and Bicep.
2. `azd` must default the deployment region to Sweden Central and allow the user to select another region.
3. All resources must deploy to the selected region.
4. Provisioning must fail clearly when a selected Foundry model or required quota is unavailable. It must not silently deploy a model to another region.
5. The reference environment must provision:
   - Azure API Management Basic v2.
   - A storage account and Azure Table Storage table.
   - One Microsoft Foundry resource and project.
   - Log Analytics and Application Insights.
   - APIM APIs, products, subscriptions, named values, backends, backend pools, policies, and diagnostics.
6. Public Azure endpoints must be used in version one.
7. APIM must authenticate to Table Storage and Foundry with managed identity.

### Foundry model deployments

1. Provision five `GlobalStandard` deployments with capacity `1`:
   - Two equivalent deployments for the configurable round-robin model.
   - Two `gpt-4.1-mini` deployments.
   - One `gpt-4o-mini` deployment.
2. Model versions must be configurable, with currently supported versions used as defaults.
3. Deployments must be created sequentially to reduce quota-allocation races.

### APIM backend topology

1. Create one APIM backend entity for each Foundry model deployment.
2. Create `nano-pool` from the two equivalent round-robin backends using round-robin balancing.
3. Create `mini-pool` from the two `gpt-4.1-mini` backends using priority-based routing:
   - Priority 1 represents the primary or PTU-like route.
   - Priority 2 represents pay-as-you-go overflow.
4. The sample must not provision real provisioned throughput.
5. Configure the priority-1 backend circuit breaker for `429` and `5xx` responses and honor `Retry-After`.
6. Circuit-breaker thresholds and durations must be deployment parameters or clearly marked tuning points.
7. Keep the `gpt-4o-mini` backend as a single backend entity.

### Gateway Routing Profile storage

1. Store profiles in one Azure Table Storage table.
2. Use `profiles-v1` as the fixed `PartitionKey`.
3. Use the normalized Profile Key as `RowKey`.
4. A typical Profile Key combines a LOB application and model, such as `lob1-gpt4-1`, but the lookup policy must treat its structure as opaque.
5. Accept Profile Keys containing 1–128 characters from letters, digits, `.`, `_`, and `-`.
6. Each profile entity must contain these normal Table properties:
   - `SchemaVersion`: integer, required, value `1`.
   - `BackendId`: string, required; may identify a single APIM backend or a backend pool.
   - `MaxTpm`: integer, required; must be greater than zero and no larger than `2147483647`.
7. Unknown optional properties must be ignored.
8. Unsupported schema versions, missing fields, invalid field types, non-positive or overflowing TPM values, and malformed backend IDs must fail validation.
9. Version one must not expose profile CRUD APIs.

### Seed profiles

Provisioning must idempotently upsert these rows:

| RowKey | BackendId | MaxTpm |
|---|---|---:|
| `test-nano` | `nano-pool` | 500 |
| `lob1-gpt4-1` | `mini-pool` | 4000 |
| `lob1-gpt4o-mini` | the single `gpt-4o-mini` backend ID | 8000 |

All rows use `PartitionKey=profiles-v1` and `SchemaVersion=1`.

### Profile lookup

1. Apply profile lookup at the GenAI API scope.
2. The reusable lookup contract accepts an already-normalized Profile Key.
3. The sample `POST /chat/completions` operation must read the Profile Key from `x-profile-key`.
4. Documentation must state that `x-profile-key` is a test adapter, not a production trust boundary.
5. Reject an absent or syntactically invalid Profile Key with `400 Bad Request`.
6. Use the Profile Key directly as the APIM cache key in version one.
7. Query the built-in cache with `cache-lookup-value`.
8. On a hit, parse and apply the cached normalized profile.
9. On a miss:
   - Apply a per-Profile-Key limit of 10 Table lookups per 60 seconds.
   - Perform a Table Storage point read using `PartitionKey=profiles-v1` and the Profile Key as `RowKey`.
   - Authenticate with APIM managed identity.
   - Use a configurable timeout with a default of three seconds.
   - Do not retry in version one.
10. Default to APIM's system-assigned identity and support an optional user-assigned identity client ID.

### Validation and caching

1. Validate the Table entity before routing, token enforcement, or caching.
2. Normalize a valid entity into compact JSON containing:
   - `schemaVersion`
   - `backendId`
   - `maxTpm`
3. Cache only validated profiles.
4. Do not negatively cache missing or invalid profiles.
5. Use `cache-store-value` with a configurable TTL that defaults to 300 seconds.
6. Continue the current request using the locally normalized profile without waiting for the asynchronous cache write.
7. Correctness must not depend on cache availability; a cache failure becomes a Table lookup.

### Applying a profile

1. Apply `BackendId` through `set-backend-service backend-id`.
2. Validate `BackendId` as nonempty and syntactically conservative before applying it.
3. Treat a nonexistent registered backend as an internal profile-application error.
4. Use the Profile Key as the shared token-limit counter key.
5. Apply the validated `MaxTpm` value directly to the selected token-limit policy at runtime.
6. Provide both token-limit policy variants:
   - `azure-openai-token-limit` for compatibility.
   - `llm-token-limit` for current implementations.
7. Default deployment to `azure-openai-token-limit`.
8. The Gateway Routing Profile schema must remain independent of the selected token-limit policy variant.

### APIs and products

1. Provision a sample chat API with `POST /chat/completions`.
2. Provision a separate internal Profile Refresh API.
3. Create separate APIM products and subscriptions:
   - `gateway-consumer` for the chat API.
   - `gateway-profile-admin` for the refresh API.
4. Both APIs must require their corresponding APIM subscription key.

### Profile Refresh

1. Expose a protected single-key refresh operation in the internal API.
2. A refresh must:
   - Validate the Profile Key.
   - Read the profile from Table Storage.
   - Validate and normalize it.
   - Submit the normalized value to the built-in cache.
3. Return `202 Accepted` after validation and asynchronous cache-store submission.
4. Bulk warming must remain external automation that invokes the single-key refresh operation once per key.

### Error contract

| Condition | Response |
|---|---|
| Missing or invalid request Profile Key | `400 Bad Request` |
| Profile row missing | `500 Internal Server Error` |
| Profile row invalid or unsupported | `500 Internal Server Error` |
| Backend ID cannot be applied | `500 Internal Server Error` |
| Table timeout or service failure | `503 Service Unavailable` |
| Cache-miss lookup limit exceeded | `429 Too Many Requests` |

Client errors must be generic, include a correlation ID, and expose neither the Profile Key nor internal validation details.

### Observability

1. Provision Log Analytics and Application Insights.
2. Enable APIM gateway resource logs and Application Insights diagnostics.
3. Emit one low-cardinality outcome metric with values including:
   - `hit`
   - `miss`
   - `missRateLimited`
   - `sourceFailure`
   - `notFound`
   - `invalidProfile`
   - `refreshAccepted`
4. Emit sanitized trace details for diagnosis.
5. Never include Profile Keys, profile contents, tokens, subscription keys, or storage credentials in custom telemetry.
6. Add a named-value-controlled test mode, disabled by default, that conditionally returns:
   - `X-Profile-Cache`
   - `X-Backend-Id`
7. `X-Backend-Id` represents the configured backend entity or pool, not the selected pool member.
8. Pool-member validation must use `BackendUrl` in `ApiManagementGatewayLogs`.

### Testing

1. Include one explicit on-demand command that reads the active azd environment and runs smoke and integration tests.
2. Do not run tests automatically after `azd provision`, `azd deploy`, or `azd up`.
3. Provide opt-in fault tests separately.
4. Automated tests must cover:
   - All three seeded profiles.
   - Cache miss followed by cache hit.
   - Profile validation failures.
   - Error status mapping.
   - Non-positive, overflowing, and invalid-type TPM rejection.
   - Single-backend routing.
   - Round-robin pool participation using aggregated gateway logs.
   - Priority-pool normal routing and overflow under an opt-in induced failure.
   - Profile Refresh returning `202`.
   - The consumer subscription being unable to invoke Profile Refresh.
   - Eventual observation of a refreshed cached profile without modifying its source row.
5. Round-robin tests must not assert strict alternation or an exact 50/50 split.
6. Priority tests must not assert an exact failover request count or timing because APIM circuit-breaker state is distributed and approximate.

## Nonfunctional requirements

1. Keep the sample understandable and deployable without private networking, PTU, or external Redis.
2. Use managed identity instead of storage keys or Foundry API keys.
3. Do not persist secrets in source control or Bicep outputs.
4. Keep policy telemetry low-cardinality.
5. Make resource names, model versions, region, timeout, TTL, identity client ID, circuit-breaker settings, and test-mode setting configurable.
6. Make post-provision profile seeding idempotent.
7. Keep the profile contract stable across token-policy variants and backend topology changes.

## Acceptance criteria

The design is accepted when:

1. `azd up` provisions the documented environment using APIM Basic v2.
2. All five model deployments and three routing targets are created or fail with actionable capacity guidance.
3. The three profile rows are present after provisioning.
4. A cold request reads Table Storage, returns a valid model response, and reports `miss` in test mode.
5. A repeated request uses the cached profile and reports `hit`.
6. The selected profile applies the expected backend ID and its row-specific TPM Limit.
7. Missing, invalid, throttled, and unavailable dependency scenarios return the documented status codes.
8. Profile Refresh validates the source and returns `202`.
9. Gateway logs can identify actual pool-member URLs.
10. The on-demand test command passes without requiring manual portal configuration.
