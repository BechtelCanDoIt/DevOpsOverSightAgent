.DEFAULT_GOAL := help

COMPOSE_FILE := compose/docker-compose.yml
BAL_PACKAGES  := order payment inventory customer store invoice notification load-gen mcp-server splunk-mock-mcp datadog-mock-mcp agent

.PHONY: help demo-up demo-mock-up demo-down inject-chaos reset-chaos rehearse test-bal test-all mcp-inspect investigate

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

demo-up: ## Start the full stack (real Splunk/Datadog exporters — needs .env creds)
	docker compose -f $(COMPOSE_FILE) up -d
	docker compose -f $(COMPOSE_FILE) ps

demo-mock-up: ## Start stack with mock MCPs (no creds needed — good for local dev)
	@echo "==> Building Ballerina images sequentially (avoids JVM OOM with parallel builds)..."
	@for svc in store customer order inventory invoice payment notification load-gen mcp-server splunk-mock-mcp datadog-mock-mcp devops-agent; do \
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

rehearse: ## Full end-to-end demo rehearsal
	@echo "==> Starting stack..."
	$(MAKE) demo-up
	@echo "==> Waiting 15s for services to become healthy..."
	sleep 15
	@echo "==> Injecting chaos..."
	$(MAKE) inject-chaos
	@echo "==> Waiting 30s for alert to fire and agent to investigate..."
	sleep 30
	@echo "==> Resetting chaos..."
	$(MAKE) reset-chaos
	@echo "==> Rehearsal complete. Review Agent Manager trace at http://localhost:3000"

test-bal: ## Run bal test for all Ballerina packages
	@for pkg in $(BAL_PACKAGES); do \
		dir="generate/$$pkg"; \
		if [ -d "$$dir" ]; then \
			echo "==> Testing $$pkg ..."; \
			(cd "$$dir" && bal test) || echo "[FAIL] $$pkg"; \
		else \
			echo "[skip] $$pkg ($$dir not found)"; \
		fi; \
	done

test-all: test-bal ## Alias for test-bal

mcp-inspect: ## Launch MCP Inspector against the Ballerina MCP server (requires: mcp-server running)
	@echo "==> MCP Inspector starting. When the browser opens:"
	@echo "    1. Transport:  Streamable HTTP"
	@echo "    2. URL:        http://127.0.0.1:8290/mcp   <-- use 127.0.0.1, NOT localhost"
	@echo "    3. Click Connect, then browse Tools and call them."
	@echo "    (Node.js resolves 'localhost' to ::1/IPv6 which Docker does not forward)"
	npx @modelcontextprotocol/inspector

investigate: ## Trigger a test investigation against payment-service (requires: demo-mock-up + ANTHROPIC_API_KEY in .env)
	curl -s -X POST http://localhost:8082/investigate \
		-H "Content-Type: application/json" \
		-d '{"service":"payment-service","severity":"P1","description":"502 spike detected","id":"INC-TEST-1"}' \
		| jq .
