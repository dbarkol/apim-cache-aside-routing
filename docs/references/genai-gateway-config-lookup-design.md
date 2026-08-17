# GenAI Gateway — Per‑(LOB, Model) Config Lookup

**Design direction & test plan**

**Status:** Proposed / to be validated
**Scope:** APIM platform layer only (GenAI gateway). No application‑layer changes.

---

## 1. Decision

Store per‑(line‑of‑business, model) settings in **Azure Table Storage** as the source of truth, and resolve them at request time in APIM using the **cache‑aside pattern** backed by the **native (built‑in) APIM cache**.

- **Key:** LOB app + model, e.g. `lob1-gpt5`.
- **Value:** a small JSON record, e.g. `{ "backendpoolname": "pool1", "maxTpm": 4000 }` (fields may grow).
- **Default cache TTL:** **60 minutes (3600s)**, tunable via a named value without a policy edit.
- **External (Redis) cache:** out of scope. All caching uses the built‑in cache.

This replaces the earlier idea of storing the mappings directly in named values (see §2).

---

## 2. Why not named values

Named values can physically hold config, but they are the wrong primitive for an arbitrary keyed store at this scale:

- **The reference must be a static literal.** `{{name}}` is bound to a specific named value when the policy is saved. There is no way to compute the name at runtime and no accessor to fetch a named value by a dynamic key, so "look up the named value for `lob1-gpt5`" is not possible.
- **4,096‑character cap per value** forces sharding of any all‑in‑one JSON dictionary across ~8–12 base64 blobs for ~400 records.
- **Config‑deploy‑per‑change.** Every edit is an opaque blob redeploy, not a data write — poor diffs, poor audit trail.

Named values remain the right tool for **constant scaffolding** (prefixes, TTL, resource identifiers), which this design still uses.

---

## 3. Data model & how each field is consumed

The record carries two concerns that are **applied by different policies with different rules** — this is a key implementation detail:

| Field | Consumed by | Dynamic value allowed? | How it's applied |
|---|---|---|---|
| `backendpoolname` | `set-backend-service backend-id` | **Yes** — attribute accepts policy expressions | Applied directly from the looked‑up value |
| `maxTpm` | `llm-token-limit` (`tokens-per-minute` or `token-quota`) | **Unconfirmed** for `tokens-per-minute`; **Yes** for `token-quota` | See resolution order below |

`counter-key` on `llm-token-limit` accepts an expression, so the counter is always keyed dynamically. The open question is the **limit value**:

- **`tokens-per-minute` — expression support is undocumented.** The reference explicitly marks `counter-key`, `token-quota`, and `token-quota-period` as expression‑capable, and explicitly marks the header/variable‑name attributes as *not* expression‑capable. `tokens-per-minute` carries **no annotation either way**. Given the throttling‑policy family (`rate-limit`'s numeric `calls` requires a literal), it is *likely* literal‑only — but this is inference, not a documented guarantee. **Verify empirically** (see §8).
- **`token-quota` — expressions are documented as allowed.** If the requirement can be expressed as a quota over a window rather than a strict per‑minute rate, the looked‑up value applies directly (`token-quota="@(...)"`). The period floor is **Hourly**, so this is a windowed quota, not per‑minute smoothing.

**Resolution order:** (1) if the empirical test confirms `tokens-per-minute` accepts an expression, apply the looked‑up value directly; (2) else, if a windowed quota fits, use `token-quota` with an expression; (3) else, fall back to a `choose` selecting among static `tokens-per-minute` tiers (one arm per distinct value — few, so small). The fallback is guaranteed literal‑safe but is a workaround, not the goal.

---

## 4. Runtime lookup flow (cache‑aside)

1. Build the composite key from request artifacts (`lob` + `model`).
2. `cache-lookup-value` on `cfg-<key>`.
3. **Hit:** use the cached record.
4. **Miss:** `send-request` a point‑read to Table Storage → parse → `cache-store-value` with the 60‑minute TTL.
5. Apply: `backend-id` directly from the record; TPM per the §3 resolution order (direct expression if verified, else `token-quota`, else the static‑tier `choose` shown below).

### Policy sketch (illustrative)

```xml
<inbound>
  <base />

  <!-- 1. composite key -->
  <set-variable name="lookupKey" value="@{
      var lob   = context.Request.Headers.GetValueOrDefault("x-lob","");
      var model = context.Request.Headers.GetValueOrDefault("x-model","");
      return $"{lob}-{model}";
  }" />

  <!-- 2. try cache -->
  <cache-lookup-value key="@("cfg-" + (string)context.Variables["lookupKey"])"
                      variable-name="cfg" />

  <!-- 3. miss path: read-through from Table Storage -->
  <choose>
    <when condition="@(!context.Variables.ContainsKey("cfg"))">
      <emit-metric name="ConfigCache" value="1" namespace="apim-genai">
        <dimension name="Outcome" value="miss" />
      </emit-metric>

      <send-request mode="new" response-variable-name="tableResp" timeout="5" ignore-error="false">
        <set-url>@{
            var lob   = context.Request.Headers.GetValueOrDefault("x-lob","");
            var model = context.Request.Headers.GetValueOrDefault("x-model","");
            return $"https://{{StorageAccount}}.table.core.windows.net/ConfigTable(PartitionKey='{lob}',RowKey='{model}')";
        }</set-url>
        <set-method>GET</set-method>
        <set-header name="Accept" exists-action="override">
          <value>application/json;odata=nometadata</value>
        </set-header>
        <set-header name="x-ms-version" exists-action="override">
          <value>2019-02-02</value>
        </set-header>
        <authentication-managed-identity resource="https://storage.azure.com/" />
      </send-request>

      <set-variable name="cfg"
                    value="@(((IResponse)context.Variables["tableResp"]).Body.As<string>())" />

      <cache-store-value key="@("cfg-" + (string)context.Variables["lookupKey"])"
                         value="@((string)context.Variables["cfg"])"
                         duration="{{ConfigCacheTtlSeconds}}" />
    </when>
    <otherwise>
      <emit-metric name="ConfigCache" value="1" namespace="apim-genai">
        <dimension name="Outcome" value="hit" />
      </emit-metric>
    </otherwise>
  </choose>

  <!-- 4. parse record -->
  <set-variable name="poolName" value="@(Newtonsoft.Json.Linq.JObject.Parse((string)context.Variables["cfg"])["backendpoolname"].ToString())" />
  <set-variable name="tpm"      value="@(Newtonsoft.Json.Linq.JObject.Parse((string)context.Variables["cfg"])["maxTpm"].ToString())" />
  <set-variable name="ck"       value="@((string)context.Variables["lookupKey"])" />

  <!-- 5a. routing: value applied directly (expression allowed) -->
  <set-backend-service backend-id="@((string)context.Variables["poolName"])" />

  <!-- 5b. token limit.
       PREFERRED (once verified per §8) — single dynamic policy:
         <llm-token-limit counter-key="@((string)context.Variables["ck"])"
                          tokens-per-minute="@(int.Parse((string)context.Variables["tpm"]))"
                          estimate-prompt-tokens="true" />
       OR a windowed quota (token-quota IS documented to accept expressions):
         <llm-token-limit counter-key="@((string)context.Variables["ck"])"
                          token-quota="@(int.Parse((string)context.Variables["tpm"]))"
                          token-quota-period="Hourly" estimate-prompt-tokens="true" />
       FALLBACK (below) — static tiers, guaranteed literal-safe: -->
  <choose>
    <when condition="@((string)context.Variables["tpm"] == "4000")">
      <llm-token-limit counter-key="@((string)context.Variables["ck"])"
                       tokens-per-minute="4000" estimate-prompt-tokens="true" />
    </when>
    <when condition="@((string)context.Variables["tpm"] == "8000")">
      <llm-token-limit counter-key="@((string)context.Variables["ck"])"
                       tokens-per-minute="8000" estimate-prompt-tokens="true" />
    </when>
    <!-- one arm per distinct tier -->
  </choose>
</inbound>
```

### TTL as a tunable constant

Define a named value so the TTL can change without a policy rewrite:

- **Name:** `ConfigCacheTtlSeconds`
- **Value:** `3600`  (60 minutes)

---

## 5. Seed / warm operation

**Purpose:** proactively populate the cache — after a deploy (which flushes the cache, see §7), on a schedule, or on demand — so callers don't pay the first‑request Table round‑trip.

**Proposed endpoint:** `POST /config-cache/seed`
**Body:** `{ "all": true }` or `{ "keys": ["lob1-gpt5", "lob2-gpt4"] }`
**Access:** admin‑only — restrict to an internal product/subscription and/or IP allow‑list.

### Important constraint (shapes the implementation)

APIM policy is declarative and has **no `for-each` construct that repeats a policy element**. `cache-store-value` writes exactly one key per invocation, so a single operation execution **cannot fan out an arbitrary number of per‑key cache writes**. This drives the two implementation paths below.

### Path 1 — External driver (recommended; keeps the per‑key cache model)

The operation warms **one key per call** using the same read‑through logic as §4. A release‑pipeline step or script iterates the key collection (or enumerates the Table for `all`) and calls the operation once per key.

- Pros: keeps independent per‑key entries and TTLs; simple, robust; reuses the runtime miss path.
- Cons: the fan‑out loop lives in the pipeline, not in APIM.

```xml
<!-- POST /config-cache/seed/{key}  -> warms a single entry -->
<inbound>
  <base />
  <!-- restrict to admin subscription/product; optional ip-filter -->
  <set-variable name="lookupKey" value="@(context.Request.MatchedParameters["key"])" />
  <send-request mode="new" response-variable-name="tableResp" timeout="10">
    <set-url>@{
        var parts = ((string)context.Variables["lookupKey"]).Split(new[]{'-'}, 2);
        return $"https://{{StorageAccount}}.table.core.windows.net/ConfigTable(PartitionKey='{parts[0]}',RowKey='{parts[1]}')";
    }</set-url>
    <set-method>GET</set-method>
    <set-header name="Accept" exists-action="override"><value>application/json;odata=nometadata</value></set-header>
    <set-header name="x-ms-version" exists-action="override"><value>2019-02-02</value></set-header>
    <authentication-managed-identity resource="https://storage.azure.com/" />
  </send-request>
  <cache-store-value key="@("cfg-" + (string)context.Variables["lookupKey"])"
                     value="@(((IResponse)context.Variables["tableResp"]).Body.As<string>())"
                     duration="{{ConfigCacheTtlSeconds}}" />
  <return-response>
    <set-status code="200" reason="OK" />
  </return-response>
</inbound>
```

### Path 2 — Single‑object cache (self‑contained "read all" in one call)

Store the **entire** config set as one cache object (`cfg-all`) with a single `cache-store-value`; the runtime lookup reads `cfg-all` and indexes it by key in an expression. Seeding becomes one read‑all + one store, fully inside APIM with no external loop.

- Pros: seed operation is self‑contained; `all` is a single call; post‑deploy re‑warm is one request.
- Cons: changes the cache model to a single blob (one shared TTL); a miss re‑reads the whole Table (one query); for a few hundred small records the per‑request parse cost is negligible.

```xml
<!-- POST /config-cache/seed  {"all": true} -->
<send-request mode="new" response-variable-name="allRows" timeout="30">
  <set-url>@($"https://{{StorageAccount}}.table.core.windows.net/ConfigTable()")</set-url>
  <set-method>GET</set-method>
  <set-header name="Accept" exists-action="override"><value>application/json;odata=nometadata</value></set-header>
  <set-header name="x-ms-version" exists-action="override"><value>2019-02-02</value></set-header>
  <authentication-managed-identity resource="https://storage.azure.com/" />
</send-request>
<set-variable name="configMap" value="@{
    var body = ((IResponse)context.Variables["allRows"]).Body.As<Newtonsoft.Json.Linq.JObject>();
    var rows = (Newtonsoft.Json.Linq.JArray)body["value"];
    var map  = new Newtonsoft.Json.Linq.JObject();
    foreach (var r in rows) { map[r["PartitionKey"] + "-" + r["RowKey"]] = r; }
    return map.ToString(Newtonsoft.Json.Formatting.None);
}" />
<cache-store-value key="cfg-all" value="@((string)context.Variables["configMap"])"
                   duration="{{ConfigCacheTtlSeconds}}" />
```

> **Note on "read all" pagination:** Table Storage returns up to 1,000 entities per page and signals more via `x-ms-continuation-NextPartitionKey` / `x-ms-continuation-NextRowKey` response headers. ~400 rows fit in a single page; if the set grows past 1,000, the read‑all path must follow continuation tokens.

**Decision to make during the test:** Path 1 (per‑key entries, external fan‑out) vs Path 2 (single object, self‑contained seed). Path 1 is the default unless independent per‑key TTLs turn out not to matter.

---

## 6. Observability / cache metrics

**There is no native APIM metric for "objects stored" in the built‑in cache**, no policy accessor to enumerate cache contents, and no management API to list keys. Any self‑maintained counter would drift (it can't observe TTL expiry or platform eviction), so it should not be built.

The meaningful metrics come from two other places:

- **Config count = source‑of‑truth row count.** The bounded, enumerable keyspace lives in Table Storage. "How many configs exist" is a row count against the Table; the cache holds at most that many (a warm subset). This is the honest answer to the "how many objects are stored" question.
- **Cache effectiveness = emit‑metric hit/miss.** Because we use the `-value` variants, hit/miss is not auto‑logged — we emit it ourselves (see §4). This yields hit rate, lookup volume, and (if we also emit on `cache-store-value`) refresh/churn rate.

**Reporting:** "N configs in the Table; X% of lookups served warm; Y Table reads/min." Requires custom metrics enabled in the App Insights diagnostic setting; keep `emit-metric` dimensions low‑cardinality (e.g., `Outcome`, maybe `LOB` — never the full key).

---

## 7. Operational constraints & risks

- **Cache flush on inbound policy deploy.** Applying/updating an inbound policy clears the entire internal cache. Expect a Table‑read burst and a hit‑rate dip after each release; dashboards will show sawtooth around deploys (expected, not a regression). **The seed operation doubles as the post‑deploy re‑warm** — wire it into the release pipeline.
- **Cache is volatile and region‑scoped.** Shared only across units within a region, no cross‑region sharing; in classic tiers it's cleared gradually (up to 50% at a time) during service updates. In multi‑region, each region warms independently and hit rate is a per‑region measure.
- **Correctness never depends on the cache.** Cache‑aside treats it as pure optimization; on any cache failure the Table read still returns the answer. The SLO is about hit ratio and Table read latency, not cache residency.
- **Auth:** prefer `authentication-managed-identity` (system/user‑assigned) with the APIM identity granted **Storage Table Data Reader** on the account — no keys in policy. SAS is the fallback if managed identity isn't available.
- **`maxTpm` application depends on the §3 verification.** If `tokens-per-minute` accepts an expression (to be confirmed) or a `token-quota` window is acceptable, the looked‑up value applies directly. If neither holds, the static‑tier fallback means each new distinct TPM value needs a new `choose` arm (a policy change), unlike pool names which flow straight through.

---

## 8. Open questions / next steps

1. **Verify `tokens-per-minute` expression support.** Deploy a non‑prod policy with `tokens-per-minute="@(...)"` and confirm whether APIM accepts and honors it. The result decides the §3 resolution path (direct expression vs `token-quota` vs static tiers).
2. **Distinct cardinality:** how many distinct `backendpoolname` and `maxTpm` values sit behind the ~400 keys? Determines the `choose` tier count (if the fallback is used) and whether a compact map beats a full table.
3. **Key structure:** what does the trailing segment in `lob1-gpt4-1` represent (deployment index / version / priority)? Affects key assembly.
4. **Seed path choice:** Path 1 vs Path 2 (§5) — confirm during the test.
5. **Load test:** validate post‑deploy re‑warm behavior, Table read latency under cold cache, and hit rate at steady state.
6. **Auth wiring:** confirm managed identity + Table role assignment in the target environment.
