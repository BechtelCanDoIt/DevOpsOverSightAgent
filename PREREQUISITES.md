# Prerequisites

Verified on 2026-06-08, macOS (Darwin 25.5.0).

## Required tools

| Tool | Required version | Verified version | Install path | Notes |
|------|-----------------|-----------------|--------------|-------|
| Docker (Engine) | ≥ 24 | 29.0.2-rd | `/Users/scottbechtel/.rd/bin/docker` | Rancher Desktop |
| Docker Compose | ≥ 2.20 | v2.40.3 | bundled with Rancher Desktop | |
| Ballerina | 2201.x Swan Lake | 2201.13.3 (Swan Lake Update 13) | `/Library/Ballerina/bin/bal` | |
| kind | ≥ 0.23 | 0.32.0 | `/opt/homebrew/bin/kind` | `brew install kind` |
| kubectl | ≥ 1.28 | v1.34.3 | `/Users/scottbechtel/.rd/bin/kubectl` | Rancher Desktop |
| Helm | ≥ 3.12 | v3.19.1 | `/Users/scottbechtel/.rd/bin/helm` | Rancher Desktop |
| Python | ≥ 3.11 | 3.14.5 | system | Agent SDK requires 3.11+ |

> **Action required:** `kind` is not installed. Run `brew install kind` before starting Phase 0.3.

## Version commands (fresh-machine runbook)

```bash
docker --version
docker compose version
bal version
kind version
kubectl version --client
helm version --short
python3 --version
```

## Install on a fresh macOS machine

```bash
# Rancher Desktop (ships Docker, docker compose, kubectl, helm)
brew install --cask rancher

# Ballerina Swan Lake
# Download the macOS installer from https://ballerina.io/downloads/
# or: brew install ballerina

# kind
brew install kind

# Python 3.11+ (use pyenv or system Python)
brew install python@3.12   # 3.14 also works
```

## WSO2 Agent Manager (Phase 0.3 smoke test)

Agent Manager is bootstrapped via a self-contained Docker quick-start container (v0.16.0). It creates its own k3d cluster internally — this is separate from the `devops-agent` kind cluster used for Phase 4.

**macOS note:** Uses Colima internally (the container manages its own Colima profile named `agent-manager`). Rancher Desktop can be the host Docker runtime.

```bash
# Pull and run the quick-start (15–20 min; downloads k3d, OpenChoreo, Agent Manager)
docker run --rm -it --name amp-quick-start \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network=host \
  ghcr.io/wso2/amp-quick-start:v0.16.0 \
  ./install.sh

# Console: http://localhost:3000  (amp-admin / amp-admin)
# Observability gateway (traces): http://localhost:22893/otel
# Uninstall (keep cluster): run ./uninstall.sh inside the container
# Uninstall + delete cluster:  ./uninstall.sh --delete-cluster
```

## Secrets needed (not yet provisioned)

These are obtained when you're ready to test live SaaS connectivity (Phase 1 smoke test).

| Secret | Where to get it | Used by |
|--------|----------------|---------|
| `SPLUNK_HEC_ENDPOINT` | Splunk Cloud trial → Settings → Data Inputs → HTTP Event Collector | OTel Collector `splunk_hec` exporter |
| `SPLUNK_HEC_TOKEN` | Same screen — create a new HEC token | OTel Collector |
| `SPLUNK_MCP_TOKEN` | Splunkbase app 7931 (Splunk MCP) — generate a bearer token | Python agent |
| `DD_API_KEY` | Datadog → Organization Settings → API Keys | OTel Collector, Datadog Agent |
| `DD_APP_KEY` | Datadog → Organization Settings → Application Keys | Python agent |
| `DD_SITE` | Your Datadog site (e.g. `datadoghq.com`, `us5.datadoghq.com`) | OTel Collector, agent |
| `ANTHROPIC_API_KEY` | console.anthropic.com | Python agent (Claude Agent SDK) |
| `CHAOS_TOKEN` | Choose any strong random string | Mesh chaos endpoints |

See `.env.example` for the full template.

## .env.example

```bash
# Copy to .env and fill in values before running `docker compose --profile saas up`
POSTGRES_PASSWORD=pocpass
CHAOS_TOKEN=dev-chaos-token

# Splunk Cloud trial
SPLUNK_HEC_ENDPOINT=https://<your-instance>.splunkcloud.com:8088
SPLUNK_HEC_TOKEN=

# Datadog
DD_API_KEY=
DD_APP_KEY=
DD_SITE=datadoghq.com

# Anthropic
ANTHROPIC_API_KEY=
```
