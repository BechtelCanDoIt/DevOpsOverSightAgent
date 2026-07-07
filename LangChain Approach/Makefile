# DevOps Observability POC — LangChain/A2A stack.
# Target names mirror the Ballerina sibling for muscle-memory.

COMPOSE := docker compose -f compose/docker-compose.yml
COMPOSE_SAAS := docker compose -f compose/docker-compose.yml -f compose/docker-compose.saas.yml
AGENT := http://localhost:18092

.PHONY: help demo-up demo-mock-up demo-saas-up demo-down inject-chaos reset-chaos \
        rehearse test test-py test-config test-a2a investigate logs ps

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

demo-up: ## Build + start the full stack (mesh + mocks + agents), creds-free
	$(COMPOSE) up -d --build

demo-mock-up: demo-up ## Alias for demo-up (mocks are the default backend)

demo-saas-up: ## Start with real Datadog/Splunk fan-out (needs creds in compose/.env)
	$(COMPOSE_SAAS) --profile saas up -d --build

demo-down: ## Stop and remove the stack
	$(COMPOSE) down

inject-chaos: ## Inject the headline chaos scenario into payment-service
	./demo/inject-chaos.sh payment-service 0.8 2000 300

reset-chaos: ## Clear chaos from all services
	./demo/reset.sh

investigate: ## Trigger an investigation of payment-service
	curl -s -X POST $(AGENT)/investigate -H 'Content-Type: application/json' \
	  -d '{"service":"payment-service","severity":"P1","description":"502 spike"}' | python3 -m json.tool

rehearse: ## Full 5-min demo run: baseline -> inject -> investigate -> reset
	$(COMPOSE) up -d --build
	@echo "waiting for orchestrator to be healthy..." && sleep 20
	./demo/inject-chaos.sh payment-service 0.8 2000 300
	@sleep 5
	$(MAKE) investigate
	@echo "Approve the proposed runbook via the sessionId in the summary, then: make reset-chaos"

test: test-py ## Run unit tests

test-py: ## Run the Python unit test suite (infra-free)
	./tests/runUnitTests.sh

test-config: ## Docker-config test: mesh health + mock MCP tools + chaos cycle
	./tests/runDockerConfigTests.sh

test-a2a: ## A2A config test: AgentCards resolvable + canned delegation
	./tests/runA2AConfigTests.sh

logs: ## Tail collector output (see telemetry flowing)
	$(COMPOSE) logs -f otel-collector

ps: ## Show stack status
	$(COMPOSE) ps
