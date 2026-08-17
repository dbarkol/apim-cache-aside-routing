# Use APIM built-in cache for profile resolution

The reference deployment uses APIM Basic v2 and its built-in key-value cache for Gateway Routing Profiles, rather than adding Azure Managed Redis. This prioritizes an out-of-the-box, low-dependency sample that demonstrates Table Storage cache-aside lookup and policy-driven routing; the trade-off is that cache behavior varies across APIM SKUs and deployment topologies, so external cache, multi-region, and broader SKU guidance are deferred to future work.
