# Test Coverage Reference

Per-test detail for the **8 mesh packages** (the 7 retail services + `load-gen`) — 80 pure/deterministic tests (no live DB or HTTP dependencies).

The repo has **15 Ballerina packages / 245 unit tests** total. The MCP-layer and agent packages are not enumerated test-by-test here — run `./tests/runUnitTests.sh` for the authoritative per-package counts. Current totals: `mcp-proxy` 81, `agent` 37, `splunk-mock-mcp` 8, `datadog-mock-mcp` 11, `apim-mcp` 11, `mi-mcp` 9, `is-mcp` 8. See `todo/phase-3-mcp.md` (proxy: federation/guardrail/skills), `todo/phase-4-agent.md` (agent: LLM loop, skill endpoints, the `run_runbook` approval gate), and `todo/phase-6-mcp-expansion.md` (the WSO2-product MCP servers) for what those cover.

---

## Customer Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedPositive` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedNegative` | Chaos token authentication is rejected with a wrong token |
| `testChaosErrorResponseStatusAndPayload` | Chaos error response has the correct HTTP status and payload shape |
| `testBuildCustomerShape` | Customer record is constructed with all expected fields |
| `testValidateNewCustomerAccepts` | Valid customer payload passes validation |
| `testValidateNewCustomerRejects` | Invalid payloads (blank name, empty email, malformed email) are rejected |
| `testIsValidCustomerId` | Customer ID validation accepts well-formed IDs and rejects malformed ones |

---

## Inventory Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedPositive` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedNegative` | Chaos token authentication is rejected with a wrong token |
| `testChaosErrorResponseStatusAndPayload` | Chaos error response has the correct HTTP status and payload shape |
| `testCacheKeyDerivation` | Cache key is generated with the expected `stock:` prefix |
| `testCanReserveAccepts` | Stock reservation is allowed when quantity is positive and stock is sufficient |
| `testCanReserveRejects` | Reservation is denied for zero/negative quantity or insufficient stock |

---

## Invoice Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrReturnsFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsEnvValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedAcceptsConfiguredToken` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedRejectsBadAndMissingToken` | Chaos token authentication is rejected when token is wrong or absent |
| `testChaosErrorResponseShape` | Chaos error response has the correct shape |
| `testValidateNewInvoiceAcceptsValidPayload` | Valid invoice request passes validation |
| `testValidateNewInvoiceRejectsEmptyOrderId` | Empty or whitespace order ID is rejected |
| `testValidateNewInvoiceRejectsNonPositiveAmount` | Zero or negative invoice amount is rejected |
| `testRowToInvoiceMapsAllFields` | DB row is correctly mapped to an Invoice record with all fields |
| `testNewIssuedInvoiceShape` | Newly created invoice has status `"issued"` and all expected fields |

---

## Order Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedPositive` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedNegative` | Chaos token authentication is rejected with a wrong token |
| `testChaosErrorResponseStatusAndPayload` | Chaos error response has the correct HTTP status and payload shape |
| `testBuildTraceparentFormat` | W3C `traceparent` header is formatted as `00-<traceId>-<spanId>-01` |
| `testBuildTraceparentEmptyIdsStillWellFormed` | `traceparent` is still well-formed even when trace/span IDs are empty strings |
| `testNewOrderIdFormat` | Order ID matches the `ORD-<millis>-<suffix>` format |
| `testNewOrderIdIsReasonablyUnique` | Two successive order IDs are not equal |

---

## Payment Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrReturnsFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsEnvValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedRejectsBadToken` | Chaos token is rejected when nil, empty, or incorrect |
| `testChaosAuthedAcceptsConfiguredToken` | Chaos token authentication succeeds with the correct token |
| `testChaosErrorResponseShape` | Chaos error response has the correct shape |
| `testChaosErrorResponsePropagatesArbitraryStatus` | Chaos error response correctly propagates arbitrary HTTP status codes |
| `testMockBankAuthorizeApprovesAndShapesNote` | Mock bank returns approved status, an `auth:` prefixed auth ID, and expected note content |
| `testMockBankAuthorizeProducesUniqueAuthIds` | Each mock bank authorization call produces a unique auth ID |
| `testChargeRequestDefaultsCurrencyToUsd` | Currency defaults to `"USD"` when omitted from a charge request |

---

## Store Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrReturnsFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedAcceptsConfiguredToken` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedRejectsWrongAndMissingToken` | Chaos token is rejected when wrong or absent |
| `testChaosErrorResponseShape` | Chaos error response has the correct shape |
| `testBuildProductDetailInStock` | Product detail record is built correctly when stock is available |
| `testBuildProductDetailOutOfStockAndUnknown` | Product detail correctly reflects out-of-stock and unknown inventory states |
| `testSkuValidAcceptsSeededSkus` | SKU validation accepts all seeded/known-valid SKUs |
| `testSkuValidRejectsMalformed` | SKU validation rejects empty strings, wrong length, wrong case/separator, and non-digit characters |

---

## Notification Service

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrReturnsFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsValueWhenSet` | `envOr` returns the actual env var value when it is set |
| `testChaosAuthedAcceptsMatchingToken` | Chaos token authentication succeeds with the correct token |
| `testChaosAuthedRejectsBadAndMissingToken` | Chaos token is rejected when wrong or absent |
| `testChaosErrorResponseStatusAndPayload` | Chaos error response has the correct HTTP status and payload shape |
| `testParseTraceparentValid` | A well-formed W3C `traceparent` header is parsed into its components |
| `testParseTraceparentMissingFieldReturnsEmpty` | Malformed `traceparent` (missing flags segment) returns empty result |
| `testParseTraceparentWrongVersionByteReturnsEmpty` | Invalid version byte in `traceparent` returns empty result |
| `testParseTraceparentNonHexCharsReturnsEmpty` | Non-hex characters in `traceparent` return empty result |
| `testParseTraceparentWrongTraceIdLengthReturnsEmpty` | Wrong-length trace ID returns empty result |
| `testParseTraceparentWrongSpanIdLengthReturnsEmpty` | Wrong-length span ID returns empty result |
| `testParseTraceparentEmptyStringReturnsEmpty` | Empty string input returns empty result |

---

## Load Generator

| Test Name | What It Tests |
|-----------|--------------|
| `testEnvOrFallbackWhenUnset` | `envOr` returns the fallback value when the env var is not set |
| `testEnvOrReturnsSetValueWhenPresent` | `envOr` returns the actual env var value when it is set |
| `testSelectPatternFromCliFlag` | `--pattern <name>` CLI flag selects the named load pattern |
| `testSelectPatternDefaultsToBaseline` | Pattern defaults to `"baseline"` when no flag is provided |
| `testSelectPatternIgnoresDanglingFlag` | A `--pattern` flag with no following value is treated as missing |
| `testLoadPatternBaselineParsesCleanly` | Baseline pattern parses to 5 RPS, 4 workers, and expected domain weights |
| `testLoadPatternSpikeHasSpikeWindow` | Spike pattern includes a spike-window config alongside the base settings |
| `testCurrentRpsBaselineIsConstant` | Baseline pattern returns the same RPS regardless of elapsed time |
| `testCurrentRpsHonorsSpikeWindow` | RPS increases to 25 during the spike window (60–120 s) and reverts outside it |
| `testPickDomainAtRespectsCumulativeWeights` | Weighted domain selection picks domains proportional to their configured weights |
| `testPickDomainAtZeroWeightsFallsBackToStore` | When all weights are zero the selector falls back to the `store` domain |
| `testPickDomainAtSkipsZeroWeightDomains` | Domains with zero weight are never selected when others have positive weight |
| `testRandIntStaysWithinInclusiveBounds` | Random integer generator always returns a value within the inclusive `[min, max]` range |
| `testRandSkuShapeAndRange` | Generated SKU matches the `SKU-00X` format with a valid numeric suffix |
