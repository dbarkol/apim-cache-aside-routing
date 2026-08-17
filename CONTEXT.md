# GenAI Gateway Configuration

This context defines how the gateway selects and applies request-specific routing and token-governance configuration.

## Language

**Gateway Routing Profile**:
The versioned configuration selected for a request that defines its backend-pool routing and token-governance limits, with room for additional gateway controls.
_Avoid_: Config row, mapping, settings blob

**Profile Key**:
An already-normalized identifier supplied to the configuration lookup module to select one Gateway Routing Profile. It commonly combines a LOB application and model, such as `lob1-gpt4-1`, but the lookup module treats its structure as opaque.
_Avoid_: LOB header, lookup key

**Profile Refresh**:
An administrative action that reloads and validates one Gateway Routing Profile from its source and replaces the cached copy.
_Avoid_: Seed, warm-all

**Backend Target**:
The registered APIM backend entity selected by a Gateway Routing Profile. Its `BackendId` may identify either a single backend or a backend pool.
_Avoid_: Backend pool name

**TPM Limit**:
The positive per-minute token allowance configured by one Gateway Routing Profile and shared by every request resolved to its Profile Key.
_Avoid_: Per-user quota, model capacity
