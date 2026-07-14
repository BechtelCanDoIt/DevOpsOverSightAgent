# Phase 7 — Skills & smarter runbook selection

**Goal:** give the agent metadata-driven runbook selection and three "skills" (Health, Top5, deployment cache) that aggregate across all federated backends server-side, so remediation stops depending entirely on unaided LLM judgment and repeat investigations stop re-deriving facts the proxy already knows.

## Tasks

### 7.1 Runbook metadata + `suggest_runbooks`
- [x] `RunbookDef` (`code/mcp/mcp-proxy/runbooks.bal`) gains `string[] symptoms`, `string category` (remediation|mitigation|diagnostic|process), `int riskLevel` (1–3), `boolean automatable`; all 5 runbooks tagged
- [x] New runbook `scale-service` (k8s-only mitigation, `{service, replicas}`, stub unless `K8S_WRITE_ENABLED`)
- [x] New tool `topology__suggest_runbooks {service, diagnosis}` → top-3 ranked `{id, name, score, riskLevel, automatable, rationale, paramsSchema}`. Scoring implemented exactly as planned: applicability filter (skip runbooks not in `catalog[service].runbookIds` unless `category=process`) → +3 per exact symptom-word match, +2 name/description substring match, +1 five-char-stem match → +4 catalog-listed boost → +2 automatable boost → −2×(riskLevel−1) penalty → sort desc, tie-break lower riskLevel first
- [x] `topology__list_runbooks`/`run_runbook`/registry tools unchanged — this is additive

### 7.2 Real `restart-service` (+ `scale-service`)
- [x] Via `callBackendToolDirect` (Refactor R4.2): a connected `docker` backend restarts `${RESTART_CONTAINER_PREFIX:-devops-poc-}<short>-1`; else a connected `k8s` backend gated behind **`K8S_WRITE_ENABLED`** (default `false`) patches the Deployment (`resources_create_or_update`); else falls back to the pre-existing stub. Audit line records `path=docker|k8s|stub`.
- [x] **[not live-verified]** The k8s write path (annotation patch for restart, replica patch for scale) was NOT exercised against a real cluster in this session — same scope limitation as Phase 6.4's read-only k8s verification. Both write gates default OFF, so the demo path is unaffected; this only matters if an operator opts into `K8S_WRITE_ENABLED=true` with a real, disposable cluster.
- [x] `scale-service` uses the identical connected-backend → write-gate → stub fallback chain

### 7.3 `topology__health_report {product?}`
- [x] Returns `{overall: HEALTHY|DEGRADED|CRITICAL|UNKNOWN, generatedAt, sections:[{source,status,summary,details}]}` (`code/mcp/mcp-proxy/skills.bal`)
- [x] Server-side parallel fan-out via `start`/`wait` futures — one future per mesh service + per connected WSO2-product backend; a disconnected backend short-circuits to an `UNAVAILABLE` section with zero network cost (checked via `isBackendConnected` before ever calling `start`)
- [x] Shared `probeServiceHealth(ServiceInfo)` refactored out of `get_service_health` (both now call the same live-probe function — no behavior change to the existing tool, verified by the untouched `get_service_health` JSON shape)
- [x] Optional `product` filter (case-insensitive substring against a backend label or deployment/service name) shared with `top_issues` via `productMatches`

### 7.4 `topology__top_issues {count?=5, product?}`
- [x] Returns ranked `{source, severity, target, title, evidence, score}[]`, capped at `count` (max 20, via `capCount`)
- [x] Sources implemented: mesh DOWN probes (P1/10), Datadog alerting monitors (P1 if service SLA≥99.9% else P2/8) + Datadog error-tracking issues (P2/6), Splunk fixed-SPL error-count query (score `min(count/10, 7)`), APIM/MI/IS anomalies (P2/6 each, if connected — surfaces the Phase 6 seeded fixtures: `LegacyBillingAPI` BLOCKED, `order-retry-processor` INACTIVE, `SECONDARY` user store Disconnected), Kubernetes Warning events (P3/4, if connected)
- [x] **[best-effort, not live-verified]** The k8s Warning-events source calls a tool named `events_list` with a loosely-guessed event shape (`type`/`reason`/`involvedObjectName`) — this was NOT confirmed against `kubernetes-mcp-server`'s real tool surface in this session (see Phase 6.4's own honest scope note). A missing/renamed tool or different field names simply yields zero k8s issues rather than failing `top_issues` as a whole — every anomaly source is independently wrapped so one bad/absent backend can't take down the others.

### 7.5 `topology__list_deployments` + agent-side skills
- [x] New readonly `DEPLOYMENTS` map in `catalog.bal`: `{name, product, version, environment, endpoint, healthTool}` — wso2am/wso2mi/wso2is + the 7 mesh entries (mesh entries carry `healthTool: ""` since they're probed via `ServiceInfo.healthEndpoint`, not a backend tool call)
- [x] Chat commands (`Health` / `Health apim` / `Top5` / `Top5 10` / `Top5 mi`) — implemented and verified in Phase 4 §4.9 (`code/agent/devops_oversight_agent.bal` `parseSkillCommand`/`runSkillCommand`), not duplicated here

## Unit tests (`code/mcp/mcp-proxy/tests/runbooks_test.bal`, `skills_test.bal`)
- [x] `testSuggestRunbooksChaosSymptom` — "502 errors chaos injected" on payment-service ranks `disable-chaos` first
- [x] `testSuggestRunbooksMemorySymptom` — "memory leak OOM" ranks `restart-service` first
- [x] `testSuggestRunbooksApplicabilityFilter` — `clear-cache` excluded for payment-service, included for inventory-service
- [x] `testSuggestRunbooksProcessCategoryAlwaysEligible` — `freeze-deploys` survives the filter for any service
- [x] `testSuggestRunbooksRiskTieBreak` — equal keyword scores (`"crash latent"` on payment-service) → lower riskLevel (`disable-chaos`, risk 1) ranked before `restart-service` (risk 2)
- [x] `testExecuteRestartServiceStubFallback` / `testExecuteScaleServiceStubFallback` — no docker/k8s connected → steps + audit contain `path=stub`
- [x] `testComputeOverallAllUnavailable` → UNKNOWN; `testComputeOverallOneDown` → CRITICAL; `testComputeOverallAlerting` → DEGRADED; `testComputeOverallEmptyIsUnknown` → UNKNOWN
- [x] `testSortIssuesByScoreDesc`, `testCapCountWithinRange`/`AboveMaxClampsTo20`/`NegativeClampsToZero`
- [x] `testAppendApimAnomaliesFindsBlockedApi`, `testAppendMiAnomaliesFindsInactiveProcessor`, `testAppendIsAnomaliesFindsDisconnectedStore`, `testAppendK8sWarningsBestEffortParsing` + `...MalformedInputYieldsNoIssues` — pure JSON-parsing tests, no live backend needed
- [x] `testListDeploymentsHasThreeWso2Entries`, `testListDeploymentsHasSevenMeshEntries`
- [x] 81 mcp-proxy unit tests total (up from 50 pre-Phase-7), all passing

## Integration tests (extend `tests/runDockerConfigTests.sh`)
- [x] Test 8: `topology__suggest_runbooks {"service":"payment-service","diagnosis":"502 errors chaos injected"}` → first suggestion id `disable-chaos`
- [x] Test 9: `topology__health_report {}` → `overall` present, 10 sections present (7 mesh + 3 WSO2-product)
- [x] Test 10: `topology__top_issues {"count":3}` → ≤3 issues, each with source/severity/target
- [x] Full suite verified green: 11/11 assertions passing against the live compose stack

## Exit criteria
`make investigate` still proposes `disable-chaos` for the payment-service scenario, now via `suggest_runbooks` with a rationale string instead of unaided LLM judgment — **verified** via integration Test 8. `topology__health_report`/`topology__top_issues` return well-formed aggregate data with zero live credentials — **verified** via integration Tests 9–10. Chat command "Top5 mi" surfacing the seeded INACTIVE message processor — **verified live** (Phase 4 §4.9): `POST /chat {"message":"Top5 mi"}` returns the `order-retry-processor` INACTIVE anomaly as a markdown table with zero LLM calls.
