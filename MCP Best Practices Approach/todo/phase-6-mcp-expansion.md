# Phase 6 — MCP expansion: WSO2-product servers + Kubernetes + Docker

**Goal:** federate three new Ballerina-authored WSO2-product MCP servers (mock-first, live-mode flag) plus two off-the-shelf infrastructure MCP servers (Kubernetes, Docker), and add an optional real-products Compose profile. Builds directly on Refactor R4 in `phase-3-mcp.md` — every backend here is just a new `BackendDef` entry; nothing in the proxy's routing, discovery, or the agent needs to change.

## Why these five backends

Splunk's MCP knows logs, Datadog's knows metrics/traces — neither knows anything about your WSO2 products or your Kubernetes/Docker runtime. Per Scott's napkin plan: the Customer's WSO2 versions (APIM 4.2, MI 4.2, IS 6.1) predate native MCP support, so Phase 1 here is hand-authored Ballerina wrappers over each product's *existing* REST/management APIs — deterministic mock fixtures by default (creds-free demo, matches the splunk/datadog pattern), with a `MODE=live` flag to call the real product once creds/URLs are supplied. Phase 2 (later, out of scope here) swaps these for the products' own native MCP once upgraded (APIM 4.6+) — a proxy-side env var change, same as any other backend.

## Tasks

### 6.1 apim-mcp (port 8402)
Wraps WSO2 API Manager 4.2's built-in Publisher/Admin REST APIs.
- [x] Clone `code/mcp/splunk-mock-mcp/` package shape → `code/mcp/apim-mcp/`
- [x] Tools: `apim_health`, `apim_list_apis`, `apim_get_api`, `apim_list_applications`, `apim_list_subscriptions`, `apim_gateway_status`
- [x] `mock_data.bal`: 3 APIs incl. one in `BLOCKED` lifecycle state (feeds §7.4 top_issues), 2 applications, subscriptions, gateway environments
- [x] `live_client.bal`: `envOrCfg("APIM_BASE_URL", ...)`; `apim_health` hits `/services/Version` (unauth); others via Publisher/Admin REST v4 behind OAuth2 (DCR → password grant, token cached in an isolated var)
- [x] Unit tests: mock fixture shape per tool, unknown-tool error, default mode is mock, health JSON includes `mode`

### 6.2 mi-mcp (port 8403)
Wraps WSO2 Micro Integrator 4.2's Management API.
- [x] Clone template → `code/mcp/mi-mcp/`
- [x] Tools: `mi_health`, `mi_list_proxy_services`, `mi_list_apis`, `mi_list_endpoints`, `mi_get_message_processors`, `mi_get_logs`
- [x] `mock_data.bal`: one message processor `INACTIVE` with a nonzero queue depth (the seeded stuck-queue anomaly)
- [x] `live_client.bal`: `:9164` `/healthz` (unauth), `/management/login` (basic) → JWT → Bearer on artifact endpoints
- [x] Unit tests mirroring 6.1

### 6.3 is-mcp (port 8404)
Wraps WSO2 Identity Server 6.1's Carbon health-check + server-management + SCIM2 APIs.
- [x] Clone template → `code/mcp/is-mcp/`
- [x] Tools: `is_health`, `is_server_info`, `is_list_applications`, `is_user_store_status`, `is_count_users`
- [x] `mock_data.bal`: secondary user store `Disconnected` (the seeded anomaly)
- [x] `live_client.bal`: `/api/health-check/v1.0/health` (unauth, default since IS 5.7), `/api/server/v1/*` (basic auth), SCIM2 `?count=0` → `totalResults`
- [x] Unit tests mirroring 6.1

### 6.4 Kubernetes MCP (off-the-shelf, `--profile infra-mcp`, port 8405)
- [x] Compose service: `ghcr.io/containers/kubernetes-mcp-server`, `command: ["--port","8405","--read-only","--stateless","--kubeconfig","/kubeconfig/config"]`
  - **[found during implementation]** `--stateless` is REQUIRED, not optional as originally written. Without it the server runs in stateful session mode and rejects a bare `tools/list` with `"method \"tools/list\" is invalid during session initialization"` — our `mcp_client.bal` is a one-shot POST-per-call client (no `Mcp-Session-Id` tracking), matching how every one of our OWN mock servers already behaves statelessly. `--stateless` makes this real external server behave the same way.
  - **[found during implementation — real bug, fixed]** A real, spec-compliant Streamable HTTP server also (a) requires the client to send `Accept: application/json, text/event-stream` on every POST (ours sent no `Accept` header at all → HTTP 400 `"Accept must contain both 'application/json' and 'text/event-stream'"`), and (b) may reply with an SSE-framed (`text/event-stream`) body — `event: message\ndata: {...}` — instead of bare JSON, even for a single request/response. Both were silently masked by our own lenient mocks (always `application/json`, no Accept enforcement) until tested against this real server. **Fixed in `code/mcp/mcp-proxy/mcp_client.bal` AND `code/agent/mcp_client.bal`** (kept identical): added the `Accept` header to every POST, and a `extractJsonBody()` helper that parses either response shape by inspecting `Content-Type`. This is a durable fix, not k8s-specific — it makes BOTH clients correct against any real external MCP server (WSO2's native ones, Phase 2, included).
- [x] New `scripts/prepare-kubeconfig.sh` — `kubectl config view --raw --minify --flatten` (defaults to your current context; accepts an explicit context name as `$1`), rewrites a `127.0.0.1`/`localhost` API server to `host.docker.internal` (this repo's existing Rancher-Desktop-reachability trick, same as `OLLAMA_BASE_URL`), drops the embedded CA data, and inserts `insecure-skip-tls-verify: true` (the rewritten host won't be in the original cert's SAN list). Output written to gitignored `compose/kubeconfig/config`.
- [x] No healthcheck (distroless image, no shell/wget) — relies on R4's per-backend retry back-off to self-heal
- [x] `Makefile` `infra-up` (+ `infra-down`) target: runs the script, then `docker compose --profile infra-mcp up -d`
- [x] **Verified end-to-end** (2026-07-14): built the image, ran it with a syntactically-valid but non-functional test kubeconfig (the user's real Kubernetes clusters — Rancher Desktop's own and a separate `kind` cluster — were both stopped this session; deliberately did NOT enable/start either, since Rancher Desktop's k8s is turned off on purpose in this environment). Confirmed via real `docker compose --profile infra-mcp up` + the real mcp-proxy: `GET /health` → `backends.k8s: true`; `discover_tools("kubernetes pods")` → returns `k8s__pods_get`, `k8s__pods_list`, `k8s__pods_list_in_namespace`; `tools/list` still hides all `k8s__*` (lazy loading holds, count unchanged at 12); calling `k8s__pods_list` through the proxy reaches the real k8s Go client inside the container (fails only with "connection refused" against the fake test address — proving discovery + routing + the backend's own live API call path all work correctly). **Not verified against a real cluster with real pods** — that requires the user's own reachable Kubernetes (`make infra-up` after enabling one).

### 6.5 Docker MCP — timeboxed spike, `--profile infra-mcp`, port 8406
- [x] Acceptance probe run against **(A)** Docker's official OSS `docker/mcp-gateway` (`--transport streaming --servers docker --allow-unauthenticated`, docker.sock mounted): it starts and serves the protocol correctly (same `--stateless`-equivalent session/Accept/SSE quirks as k8s-mcp, handled the same way once `Mcp-Session-Id` is tracked) — **but its entire "docker" catalog entry is ONE opaque tool**: `{"name":"docker","description":"use the docker cli","inputSchema":{"type":"object"}}` — a raw command passthrough with no defined parameters, not a set of discrete named operations.
- [x] **Decision: (C) defer.** This is an architectural mismatch, not a timeout or a connectivity failure: our write guardrail (Refactor R4.2) filters by tool NAME pattern (`allowTools`/`denyTools` globs) — there is nothing to allowlist against a single tool that can do anything. Wiring this in would mean either exposing full arbitrary docker-command execution to the agent (unacceptable — this is exactly the class of tool the whole guardrail design exists to prevent) or writing a bespoke argument-parsing filter just for this one tool's free-form input, which is out of scope for a "federate an off-the-shelf server" backend. Did not evaluate Option (B) (a stdio server bridged via `supergateway`) given the timebox and that Option A's fundamental tool-shape problem would likely recur with most generic "docker management" servers built the same way.
- [x] `DOCKER_MCP_URL` stays unset (already today's default) — **zero code impact**, exactly as designed: an unset backend URL is simply skipped by `ensureFederation()`. `restart-service` (Phase 7) falls back to its k8s path or the existing stub when no docker backend is connected.
- [ ] **Revisit if a better-shaped Docker MCP server appears** — one exposing discrete tools (`list_containers`, `get_logs`, `restart_container`, etc.) would fit this design cleanly; re-run the acceptance probe against it.

### 6.6 Real-products Compose profile (`--profile wso2`) — native-arm64, VERIFIED (2026-07)
The earlier amd64/emulation + WSO2-registry blockers are **resolved**: instead of pulling WSO2's amd64-only registry images, we build our own from locally-extracted product distributions on a **multi-arch Temurin 11 base**. WSO2 products are pure Java, so the images run **natively on arm64 or amd64 — no QEMU emulation**.
- [x] `compose/wso2/Dockerfile` — one parameterized Dockerfile (`PRODUCT_DIR` + `START_CMD` build args); `COPY`s an extracted distribution onto `eclipse-temurin:11-jdk-jammy`, non-root `wso2carbon` user, curl for healthchecks
- [x] `scripts/build-wso2-images.sh` (rewritten) — builds all three from `WSO2_SRC_DIR` (default `~/dev/wso2`; per-product `AM_DIR`/`IS_DIR`/`MI_DIR` overrides); `make wso2-build-images` wraps it. **Actually run + verified.**
- [x] `wso2mi` service: `devops-poc/wso2mi:4.3.0`, `mem_limit: 1g`, healthcheck `curl -sk https://localhost:9164/management/` (401=up, so no `-f`), publish **only** 9164 (never internal 8290 — collides with mcp-proxy's host port). **Uses MI 4.3.0**, not 4.2.0: the extracted 4.2.0 dir had a broken OSGi state (`FATAL {ServiceBusInitializer}` + observability bundle "could not resolve"; management API never started); 4.3.0 boots clean in ~3s.
- [x] `wso2am` (4.2.0) / `wso2is` (6.1.0) service blocks: `devops-poc/wso2am:4.2.0` / `devops-poc/wso2is:6.1.0`, `mem_limit: 2g`, `wso2is` on host `9446` (wso2am claims `9443`), `platform: linux/amd64` **removed** (native now)
- [x] **Verified boot + APIs native aarch64**: MI ~3s (`/management/login`→JWT→`message-processors`), IS ~25s (`/api/health-check/v1.0/health`→200), APIM ~51s (`/services/Version`→`WSO2 API Manager-4.2.0`, Publisher API→401)
- [x] **Live chain verified end-to-end for ALL THREE** (`proxy → <product>-mcp(MODE=live) → real product`), returning real data. Live-client bugs fixed while verifying (all in `live_client.bal`, mock path untouched):
  - **MI** (`mi-mcp`): login is `GET /management/login` + HTTP Basic (was POST+JSON → empty "No content"); health uses `/management/` 401=up (no unauth `/healthz`). Returns real message-processors.
  - **APIM** (`apim-mcp`): token request needed an explicit urlencoded string form-body (a `map<string>` serialized wrong → KeyNotFound); token scopes needed `apim:app_manage apim:subscribe` added (devportal returns **401**, not 403, without them); `apim_list_subscriptions` must scope by `applicationId` (unscoped = HTTP 400 "Either applicationId or apiId should be available") so it now aggregates per-application; added status-aware error surfacing (`apimGetList`). Returns real PizzaShackAPI / DefaultApplication / Default gateway.
  - **IS** (`is-mcp`): worked as written — all four tools return real data (Console app UUID, health 200, user stores, SCIM2 count).
- [x] `make wso2-up` = one-switch live path (sets `{APIM,MI,IS}_MCP_MODE=live` + `INCLUDE_WSO2_MCP=Y`, `--force-recreate`s the products + MCP servers + proxy); `make wso2-down` reverts to mock
- [x] `.env.example`: `WSO2_SRC_DIR`, the `INCLUDE_WSO2_MCP`/`INCLUDE_K8S_MCP` toggles, and the native-build/live-mode instructions documented inline
- [ ] **[content seeding — deferred]** A fresh real MI/APIM/IS has nothing deployed, so live-mode queries return empty (no INACTIVE processor / BLOCKED API to surface). Seeding a CAPP/API to reproduce the mock's demo anomalies is future work (the mock fixtures still carry the demo story creds-free).

## Integration tests (extend `tests/runDockerConfigTests.sh`)
- [x] Test 5: health-wait on 8402/8403/8404; `tools/list` still hides `apim__/mi__/is__` (lazy loading preserved)
- [x] Test 6: `discover_tools("APIM api list")` bundle contains `apim__apim_list_apis`
- [x] Test 7: `mi__mi_get_message_processors` routes to mock, response contains the INACTIVE processor
- [x] Opt-in `--with-infra` flag: Test 8i `discover_tools("kubernetes pods")` → `k8s__pods_list` (requires the user's own reachable kubeconfig prepared via `make infra-up` first — skipped with a clear message if `compose/kubeconfig/config` doesn't exist)
- [ ] Test 9i (docker write guardrail) — **N/A, Docker MCP deferred (6.5)**. Re-add if a discrete-tool-named Docker MCP server is wired in later.

## Pitfalls
- MI's internal management/passthrough port overlaps 8290 used by mcp-proxy — **never publish it**
- Rancher Desktop kubeconfig points at `127.0.0.1` and lacks a `host.docker.internal` TLS SAN — must rewrite, not just mount
- **(6.6)** WSO2's registry images (`docker.wso2.com`) are amd64-only, so DON'T pull them on arm64 — build native from an extracted distribution on the multi-arch Temurin base (`compose/wso2/Dockerfile`) instead. `repository.wso2.com` (multi-arch, per WSO2) is VPN/internal-gated and didn't resolve from the build host.
- **(6.6)** Extracted product dirs may be modified/incomplete dev copies — the local MI 4.2.0 had a broken OSGi state (management API dead). Prefer a pristine extraction; MI 4.3.0 was clean.
- **(6.6)** The Phase-6 live clients were written unverified and all needed real-instance fixes (now applied + verified): MI `GET+Basic` login; APIM urlencoded token form-body + devportal `app_manage`/`subscribe` scopes + per-application subscription scoping; IS was fine. Two recurring traps: (a) posting a `map<string>` as a form body serializes wrong in Ballerina — build the urlencoded string explicitly; (b) WSO2 devportal APIs answer **401** (not 403) when a scope is missing, which reads like an auth failure. Blind `check body.list` masks the real HTTP error — surface status+body instead.
- **(6.6)** AMP's k3d cluster (`k3d-amp-local-serverlb`) holds many host ports (3000/8080/8443/9000/9098/9243/19080/19443/…); avoid them when publishing WSO2 product host ports.

## Deliverables
- Three new Ballerina MCP packages (apim/mi/is), each mock-first with a live-mode flag, federated through the proxy with zero proxy code changes beyond a `BackendDef` row (already generic per R4)
- Kubernetes MCP federated read-only; Docker MCP federated or explicitly deferred per the spike outcome
- `--profile wso2` real-product compose services + `compose/wso2/Dockerfile` + `scripts/build-wso2-images.sh` — **built + runtime-verified native-arm64** (all three boot with responding APIs; MI live chain verified end-to-end through the proxy). MI on 4.3.0; APIM/IS live clients still need verification. Mock mode remains the default creds-free demo/CI path; `make wso2-up`/`wso2-down` toggle live vs mock.
- Proxy include toggles `INCLUDE_WSO2_MCP` / `INCLUDE_K8S_MCP` (Y|N) — hard on/off gate per backend group, verified by integration Test 12

## Exit criteria
With `--profile infra-mcp` up, `discover_tools("kubernetes pods")` surfaces `k8s__pods_list` and no destructive k8s/docker tool is discoverable or directly callable. With the base stack (`demo-mock-up`), `discover_tools("APIM api list")` surfaces `apim__apim_list_apis` with zero live credentials.
