.DEFAULT_GOAL := help

COMPOSE_FILE := compose/docker-compose.yml

# Explicit paths under the new code/ layout
BAL_DIRS := \
  code/agent \
  code/mcp/mcp-proxy code/mcp/splunk-mock-mcp code/mcp/datadog-mock-mcp \
  code/generate/store code/generate/customer code/generate/order \
  code/generate/inventory code/generate/invoice code/generate/payment \
  code/generate/notification code/generate/load-gen

.PHONY: help demo-up demo-mock-up demo-down inject-chaos reset-chaos rehearse test-bal test-all mcp-inspect investigate test-proxy

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

demo-up: ## Start the full stack (real Splunk/Datadog exporters — needs .env creds)
	docker compose -f $(COMPOSE_FILE) up -d
	docker compose -f $(COMPOSE_FILE) ps

demo-mock-up: ## Start stack with mock MCPs (no creds needed — good for local dev)
	@echo "==> Building Ballerina images sequentially (avoids JVM OOM with parallel builds)..."
	@for svc in store customer order inventory invoice payment notification load-gen mcp-proxy splunk-mock-mcp datadog-mock-mcp devops-oversight-agent; do \
		echo "  -- building $$svc"; \
		docker compose -f $(COMPOSE_FILE) --profile mock build $$svc || exit 1; \
	done
	docker compose -f $(COMPOSE_FILE) --profile mock up -d
	docker compose -f $(COMPOSE_FILE) --profile mock ps

demo-down: ## Tear down the Docker Compose stack (volumes preserved)
	docker compose -f $(COMPOSE_FILE) --profile mock down

inject-chaos: ## Inject payment-service chaos (30% 502s, 2s latency, 5 min)
	bash demo/inject-chaos.sh

reset-chaos: ## Clear chaos from all 7 services
	bash demo/reset.sh

rehearse: ## Full end-to-end demo rehearsal (compose/mock path)
	@echo "==> Starting stack..."
	docker compose -f $(COMPOSE_FILE) up -d
	@echo "==> Waiting 15s for services to become healthy..."
	sleep 15
	@echo "==> Health check (expect UP from agent, topology, splunk-mock, datadog-mock):"
	@for p in 8092 8290 8400 8401; do echo -n "    $$p: "; curl -s http://localhost:$$p/health; echo; done
	@echo "==> Injecting chaos into payment-service..."
	$(MAKE) inject-chaos
	@echo "==> Triggering agent investigation (no auto-webhook in mock mode)..."
	$(MAKE) investigate
	@echo "==> Resetting chaos (simulates approved disable-chaos runbook)..."
	$(MAKE) reset-chaos
	@echo "==> Rehearsal complete. (Bonus: if AMP is up, review the agent trace at http://localhost:3000)"

test-bal: ## Run bal test for all Ballerina packages
	@for dir in $(BAL_DIRS); do \
		if [ -d "$$dir" ]; then \
			echo "==> Testing $$dir ..."; \
			(cd "$$dir" && bal test) || echo "[FAIL] $$dir"; \
		else \
			echo "[skip] $$dir (not found)"; \
		fi; \
	done

test-all: test-bal ## Alias for test-bal

mcp-inspect: ## Launch MCP Inspector against the MCP Proxy (requires: mcp-proxy running)
	@echo "==> MCP Inspector starting. When the browser opens:"
	@echo "    1. Transport:  Streamable HTTP"
	@echo "    2. URL:        http://127.0.0.1:8290/mcp   <-- use 127.0.0.1, NOT localhost"
	@echo "    3. Click Connect, then browse Tools and call them."
	@echo "    (Node.js resolves 'localhost' to ::1/IPv6 which Docker does not forward)"
	npx @modelcontextprotocol/inspector

test-proxy: ## Integration test: proxy federation + routing (no LLM or SaaS creds needed)
	bash tests/runDockerConfigTests.sh

investigate: ## Trigger a test investigation against payment-service (requires: demo-mock-up + ANTHROPIC_API_KEY in .env)
	curl -s -X POST http://localhost:8092/investigate \
		-H "Content-Type: application/json" \
		-d '{"service":"payment-service","severity":"P1","description":"502 spike detected","id":"INC-TEST-1"}' \
		| jq .
