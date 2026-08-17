# Future Considerations

These items are intentionally outside version one. They should not complicate the initial APIM Basic v2 reference deployment.

## Cache providers and APIM topology

- Add Azure Managed Redis as an optional external cache.
- Document runtime behavior when an external cache is configured but unavailable.
- Compare built-in cache persistence and availability across classic and v2 tiers.
- Cover Consumption and self-hosted gateways, which require an external cache.
- Cover multi-region APIM, where built-in caches are independent per region.
- Evaluate workspace limitations for external caches.
- Add region-aware warming and cache-effectiveness dashboards.

## Cache key evolution

Version one uses the Profile Key directly as the APIM cache key for simplicity.

A future version should consider a namespace and representation version:

```text
gateway-profile:v1:<Profile Key>
```

This would prevent collisions with other APIM cache users and permit a cached JSON migration without relying on TTL expiry.

## Token-governance evolution

- Move new deployments from `azure-openai-token-limit` to `llm-token-limit` when compatibility allows.
- Add a dynamic quota mode using `token-quota` and `token-quota-period`.
- Revalidate dynamic `tokens-per-minute` expressions when policy versions or APIM tiers change, because current Microsoft Learn attribute tables do not explicitly document this support.
- Account for gateway-local counters in multi-region and workspace deployments.
- Add production guidance for concurrent requests temporarily exceeding token limits.

## PTU integration

- Replace the simulated priority-1 GlobalStandard backend with a real provisioned-throughput deployment.
- Define PTU capacity discovery, quota validation, and cost approval.
- Tune circuit-breaker thresholds around actual PTU exhaustion behavior.
- Validate pay-as-you-go overflow and recovery under sustained traffic.

## Trusted Profile Key derivation

- Derive Profile Key from validated Entra client identity, APIM subscription, model route, request body, or trusted claims.
- Define authorization between a caller and the profiles it may select.
- Remove the sample `x-profile-key` adapter.
- Decide whether LOB and model remain one opaque key or separate identity dimensions.

## Private networking

- Add private endpoints for Storage and Foundry.
- Add APIM VNet integration where supported by the selected tier.
- Provide private DNS zones and network security rules.
- Define deployment-runner connectivity requirements.
- Revisit APIM tier requirements and cost.

## Profile management

- Add a profile authoring API or GitOps workflow.
- Add optimistic concurrency through Table ETags.
- Add schema migration tooling.
- Add profile history, approvals, and audit records.
- Add bulk refresh and enumeration only when profile-management authorization is defined.
- Consider short negative caching for repeated invalid keys after measuring abuse.

## Deployment and promotion

- Add CI/CD environment promotion.
- Evaluate the current APIOps successor for API and policy artifacts.
- Separate platform infrastructure from API-content promotion if multiple environments are introduced.
- Add pull-request policy validation and deployment previews.
- Pin and regularly refresh Foundry model versions.

## Resilience

- Add a controlled retry strategy for Table Storage after measuring failure modes.
- Consider a stale-profile fallback only if freshness and governance risks are acceptable.
- Add a degraded routing profile with an explicit operational approval process.
- Add chaos tests for cache loss, storage latency, APIM scale-out, and regional failure.

## Observability

- Build workbooks for hit ratio, Table reads, profile failures, backend distribution, and circuit-breaker events.
- Add alerts and service-level objectives.
- Evaluate custom metric cardinality and ingestion cost.
- Correlate profile outcomes with Foundry usage and model latency.
- Add per-region dashboards if multi-region support is introduced.

## Broader APIM SKU guidance

Create a dedicated guide that covers:

- supported cache behavior by APIM SKU;
- circuit-breaker availability;
- diagnostics and logging differences;
- networking capabilities;
- scaling and availability-zone options;
- migration from the Basic v2 sample to production tiers.
